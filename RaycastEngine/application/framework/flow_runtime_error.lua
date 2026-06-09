local Class = require("application.framework.class")
local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")

local module = {}

local function _safe_id(value)
    if value == nil then
        return nil
    end

    if type(value) == "table" or type(value) == "userdata" then
        local ok, result = pcall(function()
            return value:get()
        end)
        if ok then
            return result
        end
    end

    return value
end

local function _safe_text(value)
    if value == nil then
        return nil
    end

    local text = tostring(value)
    return text ~= "" and text or nil
end

local function _resolve_node(context)
    if type(context) ~= "table" then
        return nil
    end

    if context.node then
        return context.node
    end

    local pin = context.pin
    if pin and pin._owner_id then
        return GlobalContext.runtime_find_node(_safe_id(pin._owner_id))
    end

    return nil
end

local function _resolve_blueprint(context, node)
    if type(context) == "table" and context.blueprint then
        return context.blueprint
    end

    if node and node._blueprint then
        return node._blueprint
    end

    return GlobalContext.get_runtime_blueprint and GlobalContext.get_runtime_blueprint()
        or GlobalContext.current_blueprint
end

local function _resolve_flow_document(context, node, blueprint)
    if type(context) == "table" and context.flow_document then
        return context.flow_document
    end

    if node and node._flow_document then
        return node._flow_document
    end

    if blueprint then
        return blueprint
    end

    return GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document()
        or GlobalContext.current_flow_document
end

local function _merge_context(fallback_context, context)
    local merged = {}
    if type(fallback_context) == "table" then
        for key, value in pairs(fallback_context) do
            merged[key] = value
        end
    end
    if type(context) == "table" then
        for key, value in pairs(context) do
            merged[key] = value
        end
    end
    return merged
end

local function _get_text_anchor(context)
    if type(context) ~= "table" then
        return nil
    end

    local node = context.node
    local flow_document = context.flow_document
    return context.text_anchor
        or (node and node._flow_text_anchor)
        or (flow_document and flow_document.get_current_source_anchor and flow_document:get_current_source_anchor())
        or nil
end

local function _get_file_name(path)
    local text = _safe_text(path)
    if not text then
        return nil
    end
    return text:match("([^/\\]+)$") or text
end

local function _get_flow_document_name(flow_document, anchor)
    local document_name = _get_file_name(type(anchor) == "table" and anchor.path or nil)
    if document_name and tostring(document_name) ~= "" then
        return tostring(document_name)
    end

    document_name = _get_file_name(flow_document and flow_document._path or nil)
    if document_name and tostring(document_name) ~= "" then
        return tostring(document_name)
    end

    return _safe_text(flow_document and (flow_document._resource_id or flow_document._display_name or flow_document._id) or nil)
end

local function _format_text_location(anchor, flow_document)
    if type(anchor) ~= "table" then
        return nil
    end

    local document_name = _get_flow_document_name(flow_document, anchor)
    local line = tonumber(anchor.line) or 1
    local column = tonumber(anchor.column) or 1
    if document_name then
        return string.format("%s 第 %d 行，第 %d 列", document_name, line, column)
    end
    return string.format("第 %d 行，第 %d 列", line, column)
end

local function _format_flow_document_reference(context)
    if type(context) ~= "table" then
        return nil
    end

    local flow_document = context.flow_document
    local anchor = _get_text_anchor(context)
    if type(anchor) == "table" then
        return _format_text_location(anchor, flow_document)
    end

    return _get_flow_document_name(flow_document, anchor)
end

local function _append_flow_document_reference(message, context)
    local text = _safe_text(message)
    if not text then
        return message
    end

    local reference = _format_flow_document_reference(context)
    if not reference or text:find(reference, 1, true) then
        return text
    end

    return string.format("%s（%s）", text, reference)
end

local function _describe_text_command(context)
    if type(context) ~= "table" then
        return nil
    end

    local command = context.command
        or (context.node and context.node._flow_text_command)
        or nil
    if type(command) ~= "string" or command == "" then
        return nil
    end
    return string.format("@%s", command)
end

local function _strip_node_prefix(message)
    if type(message) ~= "string" then
        return message
    end

    local stripped = message:gsub("^节点%[#.-%][：:]?%s*", "", 1)
    stripped = stripped:gsub("输入引脚", "输入参数")
    stripped = stripped:gsub("输出引脚", "输出参数")
    stripped = stripped:gsub("流程引脚", "流程参数")
    stripped = stripped:gsub("未设置字体$", "未设置字体资源")
    return stripped
end

local function _humanize_text_runtime_message(payload, context)
    local flow_document = type(context) == "table" and context.flow_document or nil
    local anchor = _get_text_anchor(context)
    local command = _describe_text_command(context)
    local is_text_runtime = (flow_document and flow_document.kind == "text")
        or type(anchor) == "table"
        or command ~= nil
    if not is_text_runtime then
        return _safe_text(payload.message) or "流程运行时错误"
    end

    local location = _format_text_location(anchor, flow_document)
    local subject = command and string.format("文本命令 %s", command) or "文本剧本"
    local err = type(context.error) == "table" and context.error or nil
    local pin_name = context.pin and module.describe_pin(context.pin) or nil
    local expected_name = err and (err.expected_display_name or err.expected_type_id) or nil
    local message = nil

    if err and pin_name then
        if err.code == "resource_unset" and expected_name then
            message = string.format("%s 缺少参数“%s”所需的%s。", subject, pin_name, expected_name)
        elseif err.code == "resource_unavailable" and expected_name then
            local issue = err.issue and err.issue ~= "" and string.format("（%s）", err.issue) or ""
            message = string.format("%s 引用的参数“%s”所需%s当前不可用%s。", subject, pin_name, expected_name, issue)
        elseif err.code == "nil_value" and expected_name then
            message = string.format("%s 需要参数“%s”为%s，但当前为空。", subject, pin_name, expected_name)
        elseif err.code == "string_empty" then
            message = string.format("%s 需要参数“%s”为非空文本。", subject, pin_name)
        end
    end

    if not message then
        local raw_message = _strip_node_prefix(_safe_text(payload.message) or "文本剧本运行时错误")
        local invoke_name = raw_message:match("^命令执行失败：([A-Za-z_][A-Za-z0-9_]*)$")
        if invoke_name then
            raw_message = string.format("文本命令 @%s 执行失败。", invoke_name)
        elseif command and not raw_message:match("^文本命令 ") and not raw_message:match("^文本剧本") then
            raw_message = string.format("%s 执行失败：%s", subject, raw_message)
        elseif not command and not raw_message:match("^文本剧本") then
            raw_message = string.format("文本剧本运行时错误：%s", raw_message)
        end
        message = raw_message
    end

    if location and not message:find(location, 1, true) then
        message = string.format("%s（%s）", message, location)
    end

    return message
end

module.normalize_context = function(context)
    local normalized = {}
    if type(context) == "table" then
        for key, value in pairs(context) do
            normalized[key] = value
        end
    end

    normalized.node = _resolve_node(normalized)
    normalized.pin = normalized.pin
    normalized.blueprint = _resolve_blueprint(normalized, normalized.node)
    normalized.flow_document = _resolve_flow_document(normalized, normalized.node, normalized.blueprint)
    return normalized
end

module.build_nav_data = function(context)
    local normalized = module.normalize_context(context)
    local node = normalized.node
    local blueprint = normalized.blueprint
    local flow_document = normalized.flow_document
    local anchor = normalized.text_anchor
        or (node and node._flow_text_anchor)
        or (flow_document and flow_document.get_current_source_anchor and flow_document:get_current_source_anchor())
        or nil

    if (flow_document and flow_document.kind == "text") or type(anchor) == "table" then
        local flow_guid = anchor and anchor.flow_guid or (flow_document and flow_document._resource_guid) or nil
        if anchor and flow_guid then
            return
            {
                kind = "text",
                flow_guid = flow_guid,
                line = tonumber(anchor.line) or 1,
                column = tonumber(anchor.column) or 1,
            }
        end
    end

    if not node or not blueprint then
        return nil
    end

    local node_id = node._id and _safe_id(node._id) or nil
    local flow_guid = blueprint._resource_guid or blueprint._id or nil
    if not node_id or not flow_guid then
        return nil
    end

    return
    {
        kind = "node",
        flow_guid = flow_guid,
        node_id = node_id,
    }
end

module.describe_node = function(node)
    if not node then
        return "节点"
    end

    local title = node._title
        or (node._def and (node._def.title or node._def.name))
        or node._type_id
        or "节点"
    local node_id = node._id and _safe_id(node._id)
    if node_id ~= nil then
        return string.format("%s[#%s]", title, tostring(node_id))
    end
    return tostring(title)
end

module.describe_pin = function(pin)
    if not pin then
        return "引脚"
    end

    local name = pin.get_display_name and pin:get_display_name()
        or pin._name
        or (pin._def and pin._def.display_name)
        or (pin.get_key and pin:get_key())
        or pin._type_id
        or "引脚"
    return tostring(name)
end

module.raise = function(subtype, message, context)
    error(
    {
        kind = "flow_runtime_abort",
        subtype = subtype or "runtime_error",
        message = message or "流程运行时错误",
        context = module.normalize_context(context),
    }, 0)
end

module.capture = function(err)
    if type(err) == "table" and err.kind == "flow_runtime_abort" then
        err.context = module.normalize_context(err.context)
        return err
    end

    return
    {
        kind = "flow_runtime_abort",
        subtype = "node_runtime_error",
        message = type(err) == "string" and err or tostring(err),
        raw_error = err,
        traceback = debug.traceback("", 2),
        context = {},
    }
end

module.prepare = function(err, fallback_context)
    local payload = module.capture(err)
    local context = payload.context

    if fallback_context ~= nil then
        context = module.normalize_context(_merge_context(fallback_context, context))
    else
        context = module.normalize_context(context)
    end

    payload.context = context
    payload.message = _append_flow_document_reference(_humanize_text_runtime_message(payload, context), context)
    return payload
end

module.report = function(err, fallback_context)
    local payload = module.prepare(err, fallback_context)
    local context = payload.context
    local message = _safe_text(payload.message) or "流程运行时错误"
    LogManager.log(message, "error", module.build_nav_data(context))
    if payload.subtype == "node_runtime_error" and _safe_text(payload.traceback) then
        LogManager.log(payload.traceback, "debug")
    end

    return payload
end

module.handle = function(err, fallback_context)
    local payload = module.report(err, fallback_context)
    GlobalContext.stop_debug()
    return payload
end

module.get_class_name = function(value)
    return Class.get_class_name(value)
end

return module

local FlowDocMarkup = require("application.framework.flow_doc_markup")
local FlowDocNormalizer = require("application.framework.flow_doc_normalizer")
local FlowTextEditorContext = require("application.framework.flow_text_editor_context")
local FlowTextEditorSemantics = require("application.framework.flow_text_editor_semantics")
local NodeRegistry = require("application.framework.node_registry")
local PinRegistry = require("application.framework.pin_registry")
local ResourceBrowser = require("application.framework.resource_browser")

local module = {}

local function _normalize_hovered_word(context, hovered_word)
    local word = tostring(hovered_word or "")
    if word == "" or not context then
        return word
    end

    if context.kind == "directive" then
        return (word:gsub("^@@", ""))
    end
    if context.kind == "command" then
        return (word:gsub("^@", ""))
    end
    if context.kind == "resource_type" then
        return (word:gsub("^&", ""))
    end
    if context.kind == "label" then
        return (word:gsub("^#", ""))
    end
    return word
end

local function _copy_table(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[key] = _copy_table(item)
    end
    return result
end

local function _get_pin_label(type_id)
    local pin_def = PinRegistry.get(type_id)
    local display_name = pin_def and (pin_def.display_name or pin_def.name) or type_id
    if display_name and display_name ~= type_id then
        return string.format("%s / %s", display_name, tostring(type_id))
    end
    return tostring(type_id or "unknown")
end

local function _sanitize_signature_text(text)
    text = tostring(text or "")
    text = text:gsub('"(.-)"', '"..."')
    return text
end

local function _apply_signature_command_name(signature, command_name)
    command_name = tostring(command_name or "")
    if command_name == "" then
        return signature
    end
    return (tostring(signature or ""):gsub("^@([A-Za-z_][A-Za-z0-9_]*)", "@" .. command_name, 1))
end

local function _build_signature_text(entry, command_doc, display_name)
    local command_name = display_name or entry.name
    if command_doc and command_doc.usage and command_doc.usage[1] then
        return _apply_signature_command_name(_sanitize_signature_text(command_doc.usage[1]), command_name)
    end
    if entry.syntax and entry.syntax ~= "" then
        return _apply_signature_command_name(_sanitize_signature_text(entry.syntax), command_name)
    end

    local part_list = {}
    for _, item in ipairs(entry.signature or {}) do
        if item.positional then
            part_list[#part_list + 1] = tostring(item.name)
        else
            part_list[#part_list + 1] = string.format("%s: ...", tostring(item.name))
        end
    end
    return _sanitize_signature_text(string.format("@%s(%s)", tostring(command_name), table.concat(part_list, ", ")))
end

local function _build_output_list(entry, command_doc)
    return {}
end

local function _build_parameter_list(entry)
    local result = {}
    for _, item in ipairs(entry.signature or {}) do
        local pin_key = item.pin or item.name
        local pin_info = entry.schema and entry.schema.input_by_key and entry.schema.input_by_key[pin_key] or nil
        local doc = FlowDocNormalizer.normalize_param_doc(item.doc)
        local badges = {}
        if item.required then
            badges[#badges + 1] = {text = "必填", tone = "warning"}
        end
        if item.positional then
            badges[#badges + 1] = {text = "位置参数", tone = "muted"}
        end

        result[#result + 1] =
        {
            name = tostring(item.name),
            type_label = pin_info and _get_pin_label(pin_info.type_id) or "",
            brief = doc.brief,
            description = doc.description,
            default = doc.default,
            value_hint = doc.value_hint,
            example_list = doc.examples,
            alias_list = _copy_table(item.aliases or {}),
            badges = badges,
        }
    end
    return result
end

local function _build_status_badges(command_doc)
    local badge_list = {}
    local status = command_doc.status or {}
    if status.deprecated then
        badge_list[#badge_list + 1] = {text = "已弃用", tone = "danger"}
    end
    if status.experimental then
        badge_list[#badge_list + 1] = {text = "实验性", tone = "warning"}
    end
    return badge_list
end

local function _build_status_notes(command_doc)
    local note_list = _copy_table(command_doc.notes or {})
    local status = command_doc.status or {}
    if status.deprecated then
        note_list[#note_list + 1] =
        {
            kind = "danger",
            text = tostring(status.deprecated == true and "该命令已弃用。" or status.deprecated),
        }
    end
    if status.experimental then
        note_list[#note_list + 1] =
        {
            kind = "warning",
            text = tostring(status.experimental == true and "该命令仍在实验中。" or status.experimental),
        }
    end
    return note_list
end

local function _build_command_doc(entry, hovered_name)
    local node_definition = entry.type_id and NodeRegistry.get(entry.type_id) or nil
    local script_meta = node_definition and node_definition.script or {}
    local command_doc = FlowDocNormalizer.normalize_command_doc(script_meta,
    {
        brief = entry.summary,
        description = entry.detail,
    })

    return
    {
        kind = "command",
        title = "@" .. tostring(hovered_name or entry.name),
        subtitle = entry.category or "",
        subtitle_item_list = {},
        meta_list = {},
        badge_list = _build_status_badges(command_doc),
        signature = _build_signature_text(entry, command_doc, hovered_name or entry.name),
        brief = command_doc.brief,
        description = command_doc.description,
        parameter_list = _build_parameter_list(entry),
        note_list = _build_status_notes(command_doc),
        example_list = command_doc.examples,
        output_list = _build_output_list(entry, command_doc),
        see_also_list = command_doc.see_also,
    }
end

local function _build_parameter_doc(command_entry, parameter_name)
    local signature_item = nil
    for _, item in ipairs(command_entry and command_entry.signature or {}) do
        if item.name == parameter_name then
            signature_item = item
            break
        end
        for _, alias in ipairs(item.aliases or {}) do
            if alias == parameter_name then
                signature_item = item
                break
            end
        end
        if signature_item then
            break
        end
    end
    if not signature_item then
        return nil
    end

    local doc = FlowDocNormalizer.normalize_param_doc(signature_item.doc)
    local pin_key = signature_item.pin or signature_item.name
    local pin_info = command_entry.schema and command_entry.schema.input_by_key and command_entry.schema.input_by_key[pin_key] or nil
    local meta_list = {}
    if doc.default and doc.default ~= "" then
        meta_list[#meta_list + 1] = {label = "默认值", value = tostring(doc.default)}
    end
    if doc.value_hint and doc.value_hint ~= "" then
        meta_list[#meta_list + 1] = {label = "取值提示", value = tostring(doc.value_hint)}
    end

    local badge_list = {}
    if signature_item.required then
        badge_list[#badge_list + 1] = {text = "必填", tone = "warning"}
    end
    if signature_item.positional then
        badge_list[#badge_list + 1] = {text = "位置参数", tone = "muted"}
    end

    return
    {
        kind = "parameter",
        title = tostring(parameter_name),
        subtitle = pin_info and _get_pin_label(pin_info.type_id) or "",
        meta_list = meta_list,
        badge_list = badge_list,
        signature = signature_item.positional and tostring(signature_item.name) or string.format("%s: ...", tostring(signature_item.name)),
        brief = doc.brief,
        description = doc.description,
        example_list = doc.examples,
        parameter_list = {},
        note_list = {},
        output_list = {},
        see_also_list = {},
    }
end

local function _build_directive_doc(entry, directive_name)
    local example_list = {}
    if entry.example and entry.example ~= "" then
        example_list[#example_list + 1] =
        {
            title = "示例",
            language = "vns",
            code = _sanitize_signature_text(entry.example),
        }
    end

    return
    {
        kind = "directive",
        title = "@@" .. tostring(directive_name or entry.name),
        subtitle = "元指令",
        meta_list =
        {
            {label = "语法", value = _sanitize_signature_text(entry.syntax or "")},
        },
        badge_list = {},
        signature = _sanitize_signature_text(entry.syntax or ""),
        brief = entry.summary or "",
        description = FlowDocMarkup.to_plain_text(entry.declaration or ""),
        parameter_list = {},
        note_list = {},
        example_list = example_list,
        output_list = {},
        see_also_list = {},
    }
end

local function _build_resource_type_doc(entry, resource_name)
    local example_list =
    {
        {
            title = "示例",
            language = "vns",
            code = string.format('&%s("...")', tostring(entry.name)),
        },
    }

    return
    {
        kind = "resource_type",
        title = "&" .. tostring(resource_name or entry.name),
        subtitle = ResourceBrowser.get_type_label and ResourceBrowser.get_type_label(entry.name) or "资源类型",
        meta_list = {},
        badge_list = {},
        signature = string.format('&%s("...")', tostring(entry.name)),
        brief = entry.summary or "",
        description = FlowDocMarkup.to_plain_text(entry.declaration or ""),
        parameter_list = {},
        note_list = {},
        example_list = example_list,
        output_list = {},
        see_also_list = {},
    }
end

local function _build_label_doc(entry)
    return
    {
        kind = "label",
        title = "#" .. tostring(entry.name),
        subtitle = string.format("定义于第 %d 行", tonumber(entry.line) or 1),
        meta_list = {},
        badge_list = {},
        signature = "#" .. tostring(entry.name),
        brief = "跳转标签。",
        description = entry.declaration or "",
        parameter_list = {},
        note_list = {},
        example_list = {},
        output_list = {},
        see_also_list = {},
    }
end

module.build_doc_for_context = function(document, context, hovered_word)
    if not context then
        return nil
    end

    local word = _normalize_hovered_word(context, hovered_word)
    if context.kind == "command" then
        local entry = FlowTextEditorSemantics.find_command_entry(document, word ~= "" and word or context.prefix)
        return entry and _build_command_doc(entry, word ~= "" and word or entry.name) or nil
    end
    if context.kind == "parameter" then
        local command_entry = context.command_entry or FlowTextEditorSemantics.find_command_entry(document, context.command_name)
        if command_entry then
            return _build_parameter_doc(command_entry, word ~= "" and word or context.prefix)
        end
        return nil
    end
    if context.kind == "directive" then
        local entry = FlowTextEditorSemantics.find_directive_entry(document, word ~= "" and word or context.prefix)
        return entry and _build_directive_doc(entry, word ~= "" and word or entry.name) or nil
    end
    if context.kind == "resource_type" then
        local entry = FlowTextEditorSemantics.find_resource_type_entry(document, word ~= "" and word or context.prefix)
        return entry and _build_resource_type_doc(entry, word ~= "" and word or entry.name) or nil
    end
    if context.kind == "label" then
        local entry = FlowTextEditorSemantics.find_label_entry(document, word ~= "" and word or context.prefix)
        return entry and _build_label_doc(entry) or nil
    end
    return nil
end

module.resolve = function(document, line, column, hovered_word)
    local context = FlowTextEditorContext.analyze(document, line, column)
    if not context then
        return nil
    end

    local doc = module.build_doc_for_context(document, context, hovered_word)
    if not doc then
        return nil
    end

    return
    {
        context = context,
        doc = doc,
    }
end

module.build_command_doc = _build_command_doc
module.build_parameter_doc = _build_parameter_doc
module.build_directive_doc = _build_directive_doc
module.build_resource_type_doc = _build_resource_type_doc
module.build_label_doc = _build_label_doc

return module

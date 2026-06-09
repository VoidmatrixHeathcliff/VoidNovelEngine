local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local PinRegistry = require("application.framework.pin_registry")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local Style = require("application.framework.style")

local module = {}

local resource_preflight_pool =
{
    texture = function(value)
        return ResourcesManager.find_texture(value) ~= nil
    end,
    audio = function(value)
        return ResourcesManager.find_audio(value) ~= nil
    end,
    video = function(value)
        return ResourcesManager.find_video(value) ~= nil
    end,
    font = function(value)
        return ResourcesManager.find_font(value) ~= nil
    end,
    shader = function(value)
        return ResourcesManager.find_shader(value) ~= nil
    end,
    style = function(value)
        return ResourceIndex.resolve_guid("style", value) ~= nil
    end,
}

local function _ensure_runtime_context()
    local context = GlobalContext.runtime_style_context
    if type(context) ~= "table" then
        context =
        {
            active_style_guid = "",
            active_style_reference = nil,
            active_style_document = nil,
            compiled_sheet = nil,
            compiled_revision = 0,
            source_revision = 0,
            warning_pool = {},
        }
        GlobalContext.runtime_style_context = context
        return context
    end

    context.active_style_guid = type(context.active_style_guid) == "string" and context.active_style_guid or ""
    context.active_style_reference = ResourceIndex.make_reference("style", context.active_style_reference)
    context.active_style_document = type(context.active_style_document) == "table" and context.active_style_document or nil
    context.compiled_sheet = type(context.compiled_sheet) == "table" and context.compiled_sheet or nil
    context.compiled_revision = tonumber(context.compiled_revision) or 0
    context.source_revision = tonumber(context.source_revision) or 0
    context.warning_pool = type(context.warning_pool) == "table" and context.warning_pool or {}
    return context
end

local function _invalidate_context(context)
    context.active_style_document = nil
    context.compiled_sheet = nil
    context.warning_pool = {}
    context.compiled_revision = (context.compiled_revision or 0) + 1
    context.source_revision = (context.source_revision or 0) + 1
end

local function _warn_once(context, key, message)
    if type(message) ~= "string" or message == "" then
        return
    end
    if context.warning_pool[key] then
        return
    end
    context.warning_pool[key] = true
    LogManager.log(message, "warning")
end

local function _resolve_workspace_runtime_document(reference, options)
    local ok, manager = pcall(require, "application.framework.style_workspace_manager")
    if not ok or type(manager) ~= "table" or type(manager.resolve_runtime_document) ~= "function" then
        return nil, "workspace_unavailable"
    end
    return manager.resolve_runtime_document(reference, options)
end

local function _load_document_by_guid(guid, options)
    local runtime_info, runtime_err = _resolve_workspace_runtime_document(guid, options)
    if type(runtime_info) == "table" and type(runtime_info.document) == "table" then
        local meta = ResourceIndex.find_by_guid(runtime_info.guid or guid)
        return runtime_info.document, nil, meta, runtime_info
    end

    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return nil, runtime_err ~= "workspace_unavailable" and runtime_err or "找不到样式资源"
    end

    local document, err = Style.load(meta.path)
    if not document then
        return nil, err or "无法读取样式文件"
    end
    return document, nil, meta,
    {
        guid = guid,
        path = meta.path,
        document = document,
    }
end

local function _compile_document_by_guid(guid, options)
    local document, err, meta = _load_document_by_guid(guid, options)
    if not document then
        return nil, err
    end

    local compiled_sheet, compile_err = Style.compile_document(document,
    {
        document_guid = guid,
        cache_key = guid,
        resolve_parent_document = function(reference)
            local parent_info, parent_err = _resolve_workspace_runtime_document(reference, options)
            if type(parent_info) ~= "table" or type(parent_info.document) ~= "table" then
                return nil, parent_err or "无法加载父样式"
            end
            return parent_info
        end,
    })

    if not compiled_sheet then
        return nil, compile_err and compile_err.message or "无法编译样式"
    end

    for _, issue in ipairs(compiled_sheet.issues or {}) do
        if issue and issue.message then
            return nil, issue.message
        end
    end

    return compiled_sheet, nil, meta, document
end

local function _ensure_compiled_context(context)
    if context.active_style_guid == "" then
        return nil, "当前没有激活样式"
    end
    if context.compiled_sheet and context.active_style_document then
        return context.compiled_sheet, nil
    end

    local compiled_sheet, err, _, document = _compile_document_by_guid(context.active_style_guid,
    {
        allow_unsaved_snapshot = false,
    })
    if not compiled_sheet then
        return nil, err
    end

    context.compiled_sheet = compiled_sheet
    context.active_style_document = document
    return compiled_sheet, nil
end

local function _is_resource_type(type_id)
    return resource_preflight_pool[type_id] ~= nil
end

local function _resolve_expected_type(pin, binding, expectation)
    if type(expectation) == "table" and type(expectation.type_id) == "string" and expectation.type_id ~= "" then
        return expectation.type_id
    end
    if type(expectation) == "string" and expectation ~= "" then
        return expectation
    end
    if type(binding) == "table" and type(binding.type_id) == "string" and binding.type_id ~= "" then
        return binding.type_id
    end
    return pin and pin._type_id or nil
end

local function _get_field_from_sheet(sheet, domain_key, field_key)
    if type(sheet) ~= "table" or type(sheet.domains) ~= "table" then
        return nil
    end
    local domain = sheet.domains[domain_key]
    return domain and domain.fields and domain.fields[field_key] or nil
end

function module.reset_runtime_context()
    local context = _ensure_runtime_context()
    context.active_style_guid = ""
    context.active_style_reference = nil
    _invalidate_context(context)
end

function module.set_active_style(style_reference)
    local normalized_reference = ResourceIndex.make_reference("style", style_reference)
    local guid = ResourceIndex.resolve_guid("style", normalized_reference)
    if not guid then
        return false, "无效的样式资源引用"
    end

    local compiled_sheet, err = _compile_document_by_guid(guid,
    {
        allow_unsaved_snapshot = false,
    })
    if not compiled_sheet then
        return false, err or "无法激活样式"
    end

    local context = _ensure_runtime_context()
    context.active_style_guid = guid
    context.active_style_reference = normalized_reference
    context.active_style_document = nil
    context.compiled_sheet = compiled_sheet
    context.warning_pool = {}
    context.compiled_revision = (context.compiled_revision or 0) + 1
    context.source_revision = (context.source_revision or 0) + 1
    return true
end

function module.clear_active_style()
    local context = _ensure_runtime_context()
    if context.active_style_guid == "" and context.compiled_sheet == nil then
        return false
    end

    context.active_style_guid = ""
    context.active_style_reference = nil
    _invalidate_context(context)
    return true
end

function module.collect_runtime_state()
    local context = _ensure_runtime_context()
    return
    {
        schema_version = 1,
        active_style_guid = context.active_style_guid,
        active_style_reference = ResourceIndex.make_reference("style", context.active_style_reference),
    }
end

function module.apply_runtime_state(state)
    local snapshot = type(state) == "table" and state or {}
    local style_reference = snapshot.active_style_reference or snapshot.active_style_guid
    if style_reference == nil or style_reference == "" then
        module.reset_runtime_context()
        return true
    end

    local ok, err = module.set_active_style(style_reference)
    if not ok then
        return false, err
    end
    return true
end

function module.validate_runtime_state(state)
    local snapshot = type(state) == "table" and state or {}
    local style_reference = snapshot.active_style_reference or snapshot.active_style_guid
    if style_reference == nil or style_reference == "" then
        return true
    end

    local guid = ResourceIndex.resolve_guid("style", style_reference)
    if not guid then
        return false, "存档引用的样式资源已不存在"
    end

    local compiled_sheet, err = _compile_document_by_guid(guid,
    {
        allow_unsaved_snapshot = false,
    })
    if not compiled_sheet then
        return false, err or "存档引用的样式无法编译"
    end
    return true
end

function module.get_active_style_guid()
    return _ensure_runtime_context().active_style_guid
end

function module.get_active_style_reference()
    return ResourceIndex.make_reference("style", _ensure_runtime_context().active_style_reference)
end

function module.invalidate_by_guid(guid)
    local normalized_guid = ResourceIndex.resolve_guid("style", guid)
    local context = _ensure_runtime_context()
    if not normalized_guid or context.active_style_guid == "" then
        return false
    end

    local compiled_sheet = context.compiled_sheet
    local dependency_pool = compiled_sheet and compiled_sheet.dependency_guid_pool or nil
    if context.active_style_guid ~= normalized_guid
        and not (dependency_pool and dependency_pool[normalized_guid])
    then
        return false
    end

    _invalidate_context(context)
    return true
end

function module.try_get_raw_value(domain_key, field_key, expectation)
    local context = _ensure_runtime_context()
    local compiled_sheet, err = _ensure_compiled_context(context)
    if not compiled_sheet then
        return nil, false, err
    end

    local field = _get_field_from_sheet(compiled_sheet, domain_key, field_key)
    if not field or field.has_value ~= true then
        return nil, false, nil
    end

    local expected_type = _resolve_expected_type(nil, nil, expectation)
    if expected_type and field.type_id ~= expected_type then
        _warn_once(
            context,
            string.format("type:%s:%s:%s", compiled_sheet.parent_guid or context.active_style_guid, domain_key, field_key),
            string.format("样式字段类型不匹配：%s.%s 需要 %s，实际为 %s，已回退到节点本地值",
                tostring(domain_key), tostring(field_key), tostring(expected_type), tostring(field.type_id)))
        return nil, false, "type_mismatch"
    end

    if _is_resource_type(field.type_id) then
        local preflight = resource_preflight_pool[field.type_id]
        if preflight and not preflight(field.value) then
            _warn_once(
                context,
                string.format("resource:%s:%s:%s", context.active_style_guid, domain_key, field_key),
                string.format("样式字段引用的资源当前不可用：%s.%s，已回退到节点本地值", tostring(domain_key), tostring(field_key)))
            return nil, false, "resource_unavailable"
        end
    end

    return Style.clone(field.value), true, field
end

function module.try_resolve_pin_binding(pin, binding, expectation)
    if not pin or type(binding) ~= "table" then
        return nil, false, nil
    end

    local domain_key = binding.domain
    local field_key = binding.field
    if type(domain_key) ~= "string" or domain_key == "" or type(field_key) ~= "string" or field_key == "" then
        return nil, false, nil
    end

    local expected_type = _resolve_expected_type(pin, binding, expectation)
    return module.try_get_value(domain_key, field_key, expected_type)
end

function module.try_get_value(domain_key, field_key, expectation)
    local raw_value, ok, err_or_field = module.try_get_raw_value(domain_key, field_key, expectation)
    if not ok then
        return nil, false, err_or_field
    end

    local expected_type = _resolve_expected_type(nil, nil, expectation)
    local definition = expected_type and PinRegistry.get(expected_type) or nil
    local validator = definition and definition.runtime and definition.runtime.validate or nil
    if type(validator) ~= "function" then
        return raw_value, true, err_or_field
    end

    local ok_validate, normalized_value = validator(raw_value, {type_id = expected_type}, {})
    if ok_validate then
        return normalized_value, true, err_or_field
    end

    return nil, false, err_or_field
end

function module.get_compiled_sheet()
    local context = _ensure_runtime_context()
    return _ensure_compiled_context(context)
end

return module

local json = Engine.JSON

local NativeIO = require("application.framework.native_io")
local PinRegistry = require("application.framework.pin_registry")
local ResourceIndex = require("application.framework.resource_index")
local StyleDefaultValues = require("application.framework.style_default_values")
local StyleSchemaRegistry = require("application.framework.style_schema_registry")

local module = {}

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

local function _trim(text)
    if type(text) ~= "string" then
        return nil
    end

    local value = text:match("^%s*(.-)%s*$")
    if value == "" then
        return nil
    end
    return value
end

local function _normalize_document_version(version)
    version = tonumber(version)
    if version == nil or version < 1 then
        return 1
    end
    return math.floor(version)
end

local function _normalize_domain_key(domain_key)
    return _trim(domain_key)
end

local function _normalize_field_key(field_key)
    return _trim(field_key)
end

local deprecated_field_keys =
{
    shader =
    {
        image = true,
    },
}

local function _is_deprecated_field(domain_key, field_key)
    local normalized_domain_key = _normalize_domain_key(domain_key)
    local normalized_field_key = _normalize_field_key(field_key)
    local domain_rules = normalized_domain_key and deprecated_field_keys[normalized_domain_key] or nil
    return domain_rules ~= nil and normalized_field_key ~= nil and domain_rules[normalized_field_key] == true
end

local function _normalize_display_name(display_name, fallback)
    return _trim(display_name) or fallback
end

local function _resolve_domain_display_name(domain_key, display_name)
    local builtin_domain = StyleSchemaRegistry.get_domain(domain_key)
    if builtin_domain then
        return builtin_domain.display_name
    end
    return _normalize_display_name(display_name, domain_key)
end

local function _resolve_field_display_name(domain_key, field_key, display_name)
    local builtin_field = StyleSchemaRegistry.get_field(domain_key, field_key)
    if builtin_field then
        return builtin_field.display_name
    end
    return _normalize_display_name(display_name, field_key)
end

local function _normalize_reference(value)
    return ResourceIndex.make_reference("style", value)
end

local default_document_domain_list =
{
    "dialog_box",
    "subtitle",
    "choice_button",
    "shader",
}

local function _normalize_field_value(type_id, value)
    local definition = PinRegistry.get(type_id)
    local adapter = definition and definition.style_adapter or nil
    if adapter and type(adapter.normalize_value) == "function" then
        return adapter.normalize_value(value)
    end
    return _clone_value(value)
end

local function _clone_field_value(type_id, value)
    local definition = PinRegistry.get(type_id)
    local adapter = definition and definition.style_adapter or nil
    if adapter and type(adapter.clone_value) == "function" then
        return adapter.clone_value(value)
    end
    return _clone_value(value)
end

local function _normalize_field_entry(domain_key, field_key, raw_entry)
    local builtin_field = StyleSchemaRegistry.get_field(domain_key, field_key)
    if type(raw_entry) ~= "table" then
        raw_entry = {}
    end

    local type_id = _trim(raw_entry.type_id) or (builtin_field and builtin_field.type_id) or nil
    if not type_id then
        return nil
    end

    local display_name = _resolve_field_display_name(domain_key, field_key, raw_entry.display_name)
    local has_explicit_value = raw_entry.has_value == true or rawget(raw_entry, "value") ~= nil

    return
    {
        type_id = type_id,
        display_name = display_name,
        custom = builtin_field == nil or raw_entry.custom == true,
        has_value = has_explicit_value,
        value = has_explicit_value and _normalize_field_value(type_id, raw_entry.value) or nil,
    }
end

local function _normalize_domain_entry(domain_key, raw_entry)
    raw_entry = type(raw_entry) == "table" and raw_entry or {}
    local builtin_domain = StyleSchemaRegistry.get_domain(domain_key)
    local fields = {}

    for field_key, field_entry in pairs(raw_entry.fields or {}) do
        local normalized_key = _normalize_field_key(field_key)
        if normalized_key and not _is_deprecated_field(domain_key, normalized_key) then
            local normalized_entry = _normalize_field_entry(domain_key, normalized_key, field_entry)
            if normalized_entry then
                fields[normalized_key] = normalized_entry
            end
        end
    end

    return
    {
        display_name = _resolve_domain_display_name(domain_key, raw_entry.display_name),
        custom = builtin_domain == nil or raw_entry.custom == true,
        fields = fields,
    }
end

local function _apply_template_defaults(document, template_document)
    if type(document) ~= "table" or type(template_document) ~= "table" then
        return false
    end

    document.domains = document.domains or {}
    for domain_key, template_domain in pairs(template_document.domains or {}) do
        local normalized_domain_key = _normalize_domain_key(domain_key)
        if normalized_domain_key then
            local target_domain = document.domains[normalized_domain_key]
            if not target_domain then
                target_domain = _normalize_domain_entry(normalized_domain_key, template_domain)
                target_domain.fields = {}
                document.domains[normalized_domain_key] = target_domain
            end

            target_domain.display_name = _resolve_domain_display_name(normalized_domain_key,
                template_domain and template_domain.display_name or normalized_domain_key)
            target_domain.custom = StyleSchemaRegistry.get_domain(normalized_domain_key) == nil
                or (template_domain and template_domain.custom == true)
            target_domain.fields = target_domain.fields or {}

            for field_key, template_field in pairs(template_domain.fields or {}) do
                local normalized_field_key = _normalize_field_key(field_key)
                if normalized_field_key and not _is_deprecated_field(normalized_domain_key, normalized_field_key) then
                    local normalized_field = _normalize_field_entry(normalized_domain_key, normalized_field_key, template_field)
                    if normalized_field then
                        target_domain.fields[normalized_field_key] = normalized_field
                    end
                end
            end
        end
    end
    return true
end

local function _load_default_values_document()
    if type(StyleDefaultValues.get_document) ~= "function" then
        return nil
    end
    local document = StyleDefaultValues.get_document()
    if type(document) ~= "table" then
        return nil
    end
    return module.normalize_document(document)
end

function module.new_document(options)
    local create_options = type(options) == "table" and options or {}
    local document =
    {
        version = 1,
        parent = _normalize_reference(create_options.parent),
        domains = {},
    }

    if create_options.include_default_domains == true then
        local domain_list = create_options.default_domain_list or default_document_domain_list
        for _, domain_key in ipairs(domain_list) do
            local normalized_key = _normalize_domain_key(domain_key)
            if normalized_key then
                document.domains[normalized_key] = _normalize_domain_entry(normalized_key, {})
            end
        end
    end

    if create_options.use_default_values == true then
        _apply_template_defaults(document, _load_default_values_document())
    end

    return document
end

function module.clone(value)
    return _clone_value(value)
end

function module.is_deprecated_field(domain_key, field_key)
    return _is_deprecated_field(domain_key, field_key)
end

function module.normalize_document(raw_document)
    local document = module.new_document()
    raw_document = type(raw_document) == "table" and raw_document or {}

    document.version = _normalize_document_version(raw_document.version)
    document.parent = _normalize_reference(raw_document.parent)

    for domain_key, domain_entry in pairs(raw_document.domains or {}) do
        local normalized_domain_key = _normalize_domain_key(domain_key)
        if normalized_domain_key then
            document.domains[normalized_domain_key] = _normalize_domain_entry(normalized_domain_key, domain_entry)
        end
    end

    return document
end

function module.load(path)
    local content, err = NativeIO.read_text(path)
    if not content then
        return nil, err
    end

    local ok, data = json.ParseToLua(content)
    if not ok or type(data) ~= "table" then
        return nil, "无法解析样式文件"
    end

    return module.normalize_document(data)
end

function module.save(path, document)
    local normalized = module.normalize_document(document)
    local content = json.PrintFromLua(normalized)
    return NativeIO.write_text(path, content)
end

function module.get_domain(document, domain_key, create_if_missing)
    document.domains = document.domains or {}
    local normalized_key = _normalize_domain_key(domain_key)
    if not normalized_key then
        return nil, nil
    end

    local domain = document.domains[normalized_key]
    if not domain and create_if_missing then
        domain = _normalize_domain_entry(normalized_key, {})
        document.domains[normalized_key] = domain
    end
    return domain, normalized_key
end

function module.get_field(document, domain_key, field_key)
    local domain = module.get_domain(document, domain_key, false)
    if not domain then
        return nil
    end
    return domain.fields and domain.fields[_normalize_field_key(field_key)] or nil
end

function module.get_default_field(domain_key, field_key)
    local default_document = _load_default_values_document()
    local field = default_document and module.get_field(default_document, domain_key, field_key) or nil
    return field and _clone_value(field) or nil
end

function module.get_default_domain(domain_key)
    local default_document = _load_default_values_document()
    local domain = default_document and module.get_domain(default_document, domain_key, false) or nil
    return domain and _clone_value(domain) or nil
end

function module.apply_default_domain(document, domain_key)
    document.domains = document.domains or {}
    local normalized_key = _normalize_domain_key(domain_key)
    if not normalized_key then
        return false
    end

    local default_domain = module.get_default_domain(normalized_key)
    if default_domain then
        document.domains[normalized_key] = _normalize_domain_entry(normalized_key, default_domain)
        return true
    end

    return module.get_domain(document, normalized_key, true) ~= nil
end

function module.set_parent(document, parent_reference)
    document.parent = _normalize_reference(parent_reference)
    return document.parent
end

function module.set_domain_display_name(document, domain_key, display_name)
    local normalized_key = _normalize_domain_key(domain_key)
    if not normalized_key or StyleSchemaRegistry.get_domain(normalized_key) then
        return false
    end

    local domain = module.get_domain(document, normalized_key, true)
    if not domain then
        return false
    end

    domain.display_name = _resolve_domain_display_name(normalized_key, display_name)
    return true
end

function module.remove_domain(document, domain_key)
    local normalized_key = _normalize_domain_key(domain_key)
    if not normalized_key then
        return false
    end
    if StyleSchemaRegistry.get_domain(normalized_key) then
        return false
    end
    local domain = document.domains and document.domains[normalized_key] or nil
    if not domain or domain.custom ~= true then
        return false
    end
    document.domains[normalized_key] = nil
    return true
end

function module.set_field_entry(document, domain_key, field_key, entry)
    local normalized_domain_key = _normalize_domain_key(domain_key)
    local normalized_field_key = _normalize_field_key(field_key)
    if not normalized_domain_key or not normalized_field_key then
        return false
    end
    if _is_deprecated_field(normalized_domain_key, normalized_field_key) then
        return false
    end

    local normalized_entry = _normalize_field_entry(normalized_domain_key, normalized_field_key, entry)
    if not normalized_entry then
        return false
    end

    local domain = module.get_domain(document, normalized_domain_key, true)
    if not domain then
        return false
    end

    domain.fields[normalized_field_key] = normalized_entry
    return true
end

function module.clear_field_entry(document, domain_key, field_key)
    local normalized_domain_key = _normalize_domain_key(domain_key)
    local normalized_field_key = _normalize_field_key(field_key)
    if not normalized_domain_key or not normalized_field_key then
        return false
    end
    if _is_deprecated_field(normalized_domain_key, normalized_field_key) then
        return false
    end

    local domain = module.get_domain(document, normalized_domain_key, false)
    if not domain or not domain.fields or domain.fields[normalized_field_key] == nil then
        return false
    end
    domain.fields[normalized_field_key] = nil
    return true
end

function module.set_field_value(document, domain_key, field_key, value, options)
    local normalized_domain_key = _normalize_domain_key(domain_key)
    local normalized_field_key = _normalize_field_key(field_key)
    if not normalized_domain_key or not normalized_field_key then
        return false
    end
    if _is_deprecated_field(normalized_domain_key, normalized_field_key) then
        return false
    end

    local domain = module.get_domain(document, normalized_domain_key, true)
    if not domain then
        return false
    end

    local field = domain.fields[normalized_field_key]
    if not field then
        local builtin_field = StyleSchemaRegistry.get_field(normalized_domain_key, normalized_field_key)
        if builtin_field then
            field =
            {
                type_id = builtin_field.type_id,
                display_name = builtin_field.display_name,
                custom = false,
                has_value = false,
                value = nil,
            }
        else
            local setting_options = type(options) == "table" and options or {}
            local type_id = _trim(setting_options.type_id)
            if not type_id then
                return false
            end
            field =
            {
                type_id = type_id,
                display_name = _normalize_display_name(setting_options.display_name, normalized_field_key),
                custom = setting_options.custom ~= false,
                has_value = false,
                value = nil,
            }
        end
        domain.fields[normalized_field_key] = field
    end

    field.has_value = true
    field.value = _clone_field_value(field.type_id, value)
    return true
end

function module.clear_field_value(document, domain_key, field_key)
    local field = module.get_field(document, domain_key, field_key)
    if not field then
        return false
    end

    field.has_value = false
    field.value = nil
    return true
end

local function _create_compiled_domain(sheet, domain_key, domain_def)
    local domain = sheet.domains[domain_key]
    if domain then
        return domain
    end

    domain =
    {
        key = domain_key,
        display_name = domain_def and domain_def.display_name or domain_key,
        custom = domain_def and domain_def.builtin ~= true or true,
        fields = {},
    }
    sheet.domains[domain_key] = domain
    return domain
end

local function _ensure_schema_entries(sheet)
    for _, domain_def in ipairs(StyleSchemaRegistry.list_domains()) do
        local domain = _create_compiled_domain(sheet, domain_def.id, domain_def)
        domain.display_name = domain.display_name or domain_def.display_name
        domain.custom = domain_def.builtin ~= true and true or false

        for _, field_def in ipairs(domain_def.field_list or {}) do
            if not domain.fields[field_def.key] then
                domain.fields[field_def.key] =
                {
                    domain_key = domain_def.id,
                    key = field_def.key,
                    display_name = field_def.display_name,
                    type_id = field_def.type_id,
                    custom = false,
                    has_value = false,
                    value = nil,
                    source = "schema",
                    source_guid = nil,
                    local_override = false,
                }
            end
        end
    end
end

local function _clone_compiled_sheet(source_sheet)
    local copy =
    {
        parent_guid = source_sheet.parent_guid,
        dependency_guid_pool = _clone_value(source_sheet.dependency_guid_pool or {}),
        domains = {},
        issues = _clone_value(source_sheet.issues or {}),
    }

    for domain_key, domain in pairs(source_sheet.domains or {}) do
        local next_domain =
        {
            key = domain.key,
            display_name = domain.display_name,
            custom = domain.custom,
            fields = {},
        }
        for field_key, field in pairs(domain.fields or {}) do
            next_domain.fields[field_key] = _clone_value(field)
        end
        copy.domains[domain_key] = next_domain
    end

    return copy
end

local function _inherit_compiled_sheet(source_sheet)
    local copy = _clone_compiled_sheet(source_sheet)
    for _, domain in pairs(copy.domains or {}) do
        for _, field in pairs(domain.fields or {}) do
            field.source = field.source == "local" and "inherited" or field.source
            field.local_override = false
        end
    end
    return copy
end

local function _compile_document_internal(document, options, stack_pool, cache_pool)
    local document_guid = options.document_guid or "<anonymous>"
    local cache_key = options.cache_key or document_guid
    if cache_pool[cache_key] then
        return _clone_compiled_sheet(cache_pool[cache_key])
    end

    if stack_pool[document_guid] then
        return nil,
        {
            code = "inherit_cycle",
            message = "检测到样式继承循环",
        }
    end

    stack_pool[document_guid] = true

    local compiled_sheet =
    {
        parent_guid = nil,
        dependency_guid_pool = {},
        domains = {},
        issues = {},
    }

    if options.document_guid and options.document_guid ~= "" then
        compiled_sheet.dependency_guid_pool[options.document_guid] = true
    end

    if document.parent then
        local parent_info, parent_err = nil, nil
        if options.resolve_parent_document then
            parent_info, parent_err = options.resolve_parent_document(document.parent, options)
        end
        if type(parent_info) ~= "table" then
            parent_err = parent_info
            parent_info = nil
        end

        if parent_info then
            local parent_options =
            {
                document_guid = parent_info.guid or (document_guid .. "::parent"),
                cache_key = parent_info.guid or parent_info.path or (document_guid .. "::parent"),
                resolve_parent_document = options.resolve_parent_document,
            }
            local parent_sheet, err = _compile_document_internal(parent_info.document, parent_options, stack_pool, cache_pool)
            if not parent_sheet then
                table.insert(compiled_sheet.issues, err)
            else
                compiled_sheet = _inherit_compiled_sheet(parent_sheet)
                compiled_sheet.parent_guid = parent_info.guid
                compiled_sheet.dependency_guid_pool[parent_info.guid or parent_options.cache_key] = true
                if options.document_guid and options.document_guid ~= "" then
                    compiled_sheet.dependency_guid_pool[options.document_guid] = true
                end
            end
        else
            table.insert(compiled_sheet.issues,
            {
                code = "missing_parent",
                message = type(parent_err) == "string" and parent_err or "无法加载父样式",
            })
        end
    end

    _ensure_schema_entries(compiled_sheet)

    for domain_key, domain_entry in pairs(document.domains or {}) do
        local compiled_domain = _create_compiled_domain(compiled_sheet, domain_key, StyleSchemaRegistry.get_domain(domain_key))
        local builtin_domain = StyleSchemaRegistry.get_domain(domain_key)
        compiled_domain.display_name = _resolve_domain_display_name(domain_key, domain_entry.display_name)
        compiled_domain.custom = domain_entry.custom == true or (builtin_domain == nil)

        for field_key, field_entry in pairs(domain_entry.fields or {}) do
            local builtin_field = StyleSchemaRegistry.get_field(domain_key, field_key)
            local type_id = builtin_field and builtin_field.type_id or field_entry.type_id
            if type_id then
                compiled_domain.fields[field_key] =
                {
                    domain_key = domain_key,
                    key = field_key,
                    display_name = _resolve_field_display_name(domain_key, field_key, field_entry.display_name),
                    type_id = type_id,
                    custom = field_entry.custom == true or builtin_field == nil,
                    has_value = field_entry.has_value == true,
                    value = field_entry.has_value == true and _clone_field_value(type_id, field_entry.value) or nil,
                    source = "local",
                    source_guid = options.document_guid,
                    local_override = true,
                }
            end
        end
    end

    stack_pool[document_guid] = nil
    cache_pool[cache_key] = _clone_compiled_sheet(compiled_sheet)
    return _clone_compiled_sheet(compiled_sheet)
end

function module.compile_document(document, options)
    local normalized_document = module.normalize_document(document)
    local compile_options = type(options) == "table" and options or {}
    return _compile_document_internal(normalized_document, compile_options, {}, {})
end

return module

local NodeRegistry = require("application.framework.node_registry")
local LogManager = require("application.framework.log_manager")

local module = {}

local command_spec_by_name = {}
local command_spec_by_type = {}
local command_spec_list = {}
local exposed_name_list = {}
local cache_count = -1
local cache_revision = 0
local reserved_command_pool =
{
    node = true,
    jump = true,
    ["if"] = true,
    ["elif"] = true,
    ["else"] = true,
    ["end"] = true,
    choice = true,
}

local function _clone_table(value)
    if type(value) ~= "table" then
        return value
    end

    local clone = {}
    for key, item in pairs(value) do
        clone[key] = _clone_table(item)
    end
    return clone
end

local function _normalize_signature(signature)
    local normalized = {}
    local positional_order = 0
    local named_pool = {}

    for _, item in ipairs(signature or {}) do
        local entry = _clone_table(item)
        entry.name = entry.name or entry.key
        entry.pin = entry.pin or entry.name
        entry.required = entry.required == true
        entry.positional = entry.positional == true
        entry.aliases = entry.aliases or entry.legacy_names or {}
        if entry.positional then
            positional_order = positional_order + 1
            entry.positional_index = positional_order
        end
        normalized[#normalized + 1] = entry
        named_pool[entry.name] = entry
        for _, alias in ipairs(entry.aliases) do
            named_pool[alias] = entry
        end
    end

    return normalized, named_pool
end

local function _normalize_script_meta(definition)
    local has_script_meta = type(definition.script) == "table"
    local raw = has_script_meta and definition.script or {}
    local signature, named_lookup = _normalize_signature(raw.signature)
    local command = raw.command or definition.type_id
    local aliases = raw.aliases or {}
    local spec =
    {
        command = command,
        type_id = definition.type_id,
        aliases = aliases,
        expose = has_script_meta and raw.expose ~= false,
        default_flow_output = raw.default_flow_output,
        signature = signature,
        named_lookup = named_lookup,
        summary = raw.summary,
        detail = raw.detail,
        docs = _clone_table(raw.docs),
    }
    return spec
end

local function _rebuild_cache()
    command_spec_by_name = {}
    command_spec_by_type = {}
    command_spec_list = {}
    exposed_name_list = {}

    local definition_list = NodeRegistry.list()
    cache_count = #definition_list
    cache_revision = cache_revision + 1
    local registered_type_pool = {}

    local function register_command_name(name, spec)
        if type(name) ~= "string" or name == "" then
            return
        end

        if reserved_command_pool[name] then
            LogManager.log(
                string.format("文本命令名冲突：节点 [%s] 试图暴露保留命令 @%s，已忽略该脚本入口名", tostring(spec.type_id), name),
                "warning")
            return
        end

        local existing = command_spec_by_name[name]
        if existing and existing.type_id ~= spec.type_id then
            LogManager.log(
                string.format("文本命令名冲突：@%s 同时映射到 [%s] 与 [%s]，已保留先注册的定义", name, tostring(existing.type_id), tostring(spec.type_id)),
                "warning")
            return
        end

        command_spec_by_name[name] = spec
        table.insert(exposed_name_list,
        {
            name = name,
            canonical = spec.command,
            type_id = spec.type_id,
            is_alias = name ~= spec.command,
        })
    end

    for _, definition in ipairs(definition_list) do
        local spec = _normalize_script_meta(definition)
        command_spec_by_type[definition.type_id] = spec

        if spec.expose then
            if not registered_type_pool[definition.type_id] then
                registered_type_pool[definition.type_id] = true
                table.insert(command_spec_list, spec)
            end
            register_command_name(spec.command, spec)
            for _, alias in ipairs(spec.aliases or {}) do
                register_command_name(alias, spec)
            end
        end
    end

    table.sort(command_spec_list, function(left, right)
        return tostring(left.command) < tostring(right.command)
    end)
    table.sort(exposed_name_list, function(left, right)
        if tostring(left.canonical) ~= tostring(right.canonical) then
            return tostring(left.canonical) < tostring(right.canonical)
        end
        return tostring(left.name) < tostring(right.name)
    end)
end

local function _ensure_cache()
    local definition_list = NodeRegistry.list()
    if cache_count ~= #definition_list then
        _rebuild_cache()
    end
end

module.resolve = function(command_name)
    _ensure_cache()
    return command_spec_by_name[command_name]
end

module.get_by_type = function(type_id)
    _ensure_cache()
    return command_spec_by_type[type_id]
end

module.make_fallback_spec = function(type_id)
    _ensure_cache()
    local existing = command_spec_by_type[type_id]
    if existing then
        return existing
    end

    return
    {
        command = type_id,
        type_id = type_id,
        aliases = {},
        expose = true,
        default_flow_output = nil,
        signature = {},
        named_lookup = {},
    }
end

module.list = function()
    _ensure_cache()
    local result = {}
    for index, spec in ipairs(command_spec_list) do
        result[index] = _clone_table(spec)
    end
    return result
end

module.list_names = function()
    _ensure_cache()
    local result = {}
    for index, item in ipairs(exposed_name_list) do
        result[index] = _clone_table(item)
    end
    return result
end

module.get_revision = function()
    _ensure_cache()
    return cache_revision
end

module.invalidate = function()
    cache_count = -1
    cache_revision = cache_revision + 1
    command_spec_by_name = {}
    command_spec_by_type = {}
    command_spec_list = {}
    exposed_name_list = {}
end

return module

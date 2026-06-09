local module = {}

local def_pool = {}
local ordered_def_list = {}

local function _copy_table(src)
    local dst = {}
    if not src then return dst end
    for key, value in pairs(src) do
        dst[key] = value
    end
    return dst
end

local function _sort_def_list()
    table.sort(ordered_def_list, function(left, right)
        local order_left = left.order or 1000
        local order_right = right.order or 1000
        if order_left ~= order_right then
            return order_left < order_right
        end
        return left.type_id < right.type_id
    end)
end

module.clear = function()
    def_pool = {}
    ordered_def_list = {}
end

module.register = function(definition, source_path)
    assert(type(definition) == "table", "pin definition must be a table")
    assert(type(definition.type_id) == "string" and #definition.type_id > 0, "pin definition missing type_id")

    if def_pool[definition.type_id] then
        error(string.format("duplicate pin type id: %s", definition.type_id))
    end

    local def = _copy_table(definition)
    def.api_version = def.api_version or 1
    def.kind = "pin"
    def.display_name = def.display_name or def.name or def.type_id
    def.name = def.display_name
    def.order = def.order or 1000
    def.options_schema = def.options_schema or {}
    def.default_options = def.default_options or {}
    def.runtime = def.runtime or {}
    def.runtime.display_name = def.runtime.display_name or def.display_name
    def.source_path = source_path

    def_pool[def.type_id] = def
    table.insert(ordered_def_list, def)
    _sort_def_list()
    return def
end

module.get = function(type_id)
    return def_pool[type_id]
end

module.has = function(type_id)
    return def_pool[type_id] ~= nil
end

module.list = function()
    local result = {}
    for index, definition in ipairs(ordered_def_list) do
        result[index] = definition
    end
    return result
end

module.resolve_options = function(definition, options)
    local def = definition
    if type(definition) == "string" then
        def = module.get(definition)
    end

    local resolved = {}
    if def then
        for key, schema in pairs(def.options_schema or {}) do
            if schema and rawget(schema, "default") ~= nil then
                resolved[key] = schema.default
            end
        end
        for key, value in pairs(def.default_options or {}) do
            resolved[key] = value
        end
    end

    for key, value in pairs(options or {}) do
        resolved[key] = value
    end

    return resolved
end

local function _normalize_object_type(value)
    if type(value) ~= "string" then
        return nil
    end

    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" or trimmed == "any" then
        return nil
    end
    return trimmed
end

local function _get_object_type(pin)
    local options = type(pin and pin._options) == "table" and pin._options or nil
    if not options then
        return nil
    end

    return _normalize_object_type(options.object_type)
end

local function _check_object_type_link(pin_input, pin_output)
    local input_is_object = pin_input and pin_input._type_id == "object"
    local output_is_object = pin_output and pin_output._type_id == "object"
    if not input_is_object and not output_is_object then
        return nil
    end

    local input_object_type = _get_object_type(pin_input)
    local output_object_type = _get_object_type(pin_output)
    if input_is_object and output_is_object then
        if input_object_type and output_object_type and input_object_type ~= output_object_type then
            return false
        end
        return nil
    end

    if input_object_type or output_object_type then
        return false
    end

    return nil
end

module.can_link = function(pin_a, pin_b)
    if not pin_a or not pin_b then
        return false
    end

    local pin_input, pin_output = nil, nil
    if pin_a._is_output == pin_b._is_output then
        return false
    elseif pin_a._is_output then
        pin_output, pin_input = pin_a, pin_b
    else
        pin_output, pin_input = pin_b, pin_a
    end

    if not pin_input or not pin_output then
        return false
    end

    if pin_input._owner_id:get() == pin_output._owner_id:get() then
        return false
    end

    local object_type_result = _check_object_type_link(pin_input, pin_output)
    if object_type_result ~= nil then
        return object_type_result
    end

    if pin_input._type_id == pin_output._type_id then
        return true
    end

    local input_def = module.get(pin_input._type_id)
    local output_def = module.get(pin_output._type_id)
    local ctx =
    {
        input_pin = pin_input,
        output_pin = pin_output,
        input_def = input_def,
        output_def = output_def,
    }

    if input_def and input_def.can_accept then
        local result = input_def.can_accept(pin_input, pin_output, ctx)
        if result ~= nil then
            return result
        end
    end

    if output_def and output_def.can_connect_to then
        local result = output_def.can_connect_to(pin_input, pin_output, ctx)
        if result ~= nil then
            return result
        end
    end

    return false
end

return module

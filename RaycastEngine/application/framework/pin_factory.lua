local BlueprintPin = require("application.framework.blueprint_pin")
local PinRegistry = require("application.framework.pin_registry")

local module = {}

local function _normalize_pin_key(key)
    if type(key) ~= "string" then
        return nil
    end

    local trimmed = key:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function _normalize_pin_name(name)
    if type(name) ~= "string" then
        return name
    end

    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function _normalize_args(...)
    local first = select(1, ...)
    if type(first) == "table" then
        return first
    end

    local pin_type_id, id, owner_id, is_output, name, extra_args = ...
    return
    {
        type_id = pin_type_id,
        pin_id = id,
        owner_id = owner_id,
        direction = is_output and "output" or "input",
        name = name,
        options = extra_args,
    }
end

module.create = function(...)
    local args = _normalize_args(...)
    assert(type(args) == "table", "PinFactory.create expects a table")
    assert(type(args.type_id) == "string" and #args.type_id > 0, "PinFactory.create missing type_id")
    assert(args.pin_id ~= nil, "PinFactory.create missing pin_id")
    assert(args.owner_id ~= nil, "PinFactory.create missing owner_id")
    assert(args.direction == nil or args.direction == "input" or args.direction == "output" or type(args.is_output) == "boolean",
        "PinFactory.create invalid direction")

    local definition = PinRegistry.get(args.type_id)
    assert(definition, string.format("unknown pin type: %s", args.type_id))

    local is_output = args.direction == "output" or args.is_output == true
    local options = PinRegistry.resolve_options(definition, args.options)
    local pin_name = _normalize_pin_name(args.name)
    if pin_name == nil and rawget(definition, "default_name") ~= nil then
        pin_name = definition.default_name
    end

    local pin = BlueprintPin.new(
        args.pin_id,
        args.owner_id,
        is_output,
        args.type_id,
        definition.icon_type,
        pin_name,
        definition.color)

    pin._def = definition
    pin._options = options
    pin._key = _normalize_pin_key(args.key)
        or _normalize_pin_key(type(args.raw_data) == "table" and rawget(args.raw_data, "key") or nil)
    pin._legacy_index = args.legacy_index
    pin._style_binding = args.style_binding

    local ctx =
    {
        definition = definition,
        pin_id = args.pin_id,
        owner_id = args.owner_id,
        direction = is_output and "output" or "input",
        is_output = is_output,
        name = pin_name,
        options = options,
        raw_data = args.raw_data,
        key = pin._key,
        legacy_index = args.legacy_index,
        aliases = args.aliases,
        style_binding = args.style_binding,
        registry = PinRegistry,
    }

    definition.setup(pin, ctx)
    if args.raw_data then
        pin:on_load(args.raw_data)
    end

    return pin
end

return module

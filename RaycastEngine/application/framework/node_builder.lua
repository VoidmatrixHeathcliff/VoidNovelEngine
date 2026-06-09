local Class = require("application.framework.class")
local PinFactory = require("application.framework.pin_factory")

local NodeBuilder = Class.define("NodeBuilder")

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

local function _build_match_state(pin_list)
    return
    {
        list = type(pin_list) == "table" and pin_list or {},
        consumed = {},
        next_index = 1,
    }
end

local function _mark_consumed(state, index)
    if not state or type(index) ~= "number" then
        return
    end

    state.consumed[index] = true
    if index >= state.next_index then
        state.next_index = index + 1
    end
end

local function _consume_raw_pin_data(state, pin_data)
    if not state or type(pin_data) ~= "table" then
        return
    end

    for index, candidate in ipairs(state.list) do
        if candidate == pin_data then
            _mark_consumed(state, index)
            return
        end
    end
end

local function _find_match_by_key(state, key)
    if not state or not key then
        return nil, nil
    end

    for index, pin_data in ipairs(state.list) do
        if not state.consumed[index]
            and type(pin_data) == "table"
            and _normalize_pin_key(rawget(pin_data, "key")) == key
        then
            return index, pin_data
        end
    end

    return nil, nil
end

local function _find_match_by_aliases(state, aliases)
    if type(aliases) ~= "table" then
        return nil, nil
    end

    for _, alias in ipairs(aliases) do
        local index, pin_data = _find_match_by_key(state, _normalize_pin_key(alias))
        if index then
            return index, pin_data
        end
    end

    return nil, nil
end

local function _find_match_by_legacy_index(state, legacy_index)
    if not state or type(legacy_index) ~= "number" or legacy_index < 1 then
        return nil, nil
    end

    local pin_data = state.list[legacy_index]
    if not pin_data or state.consumed[legacy_index] then
        return nil, nil
    end

    if type(pin_data) == "table" and _normalize_pin_key(rawget(pin_data, "key")) == nil then
        return legacy_index, pin_data
    end

    return nil, nil
end

local function _find_match_by_sequence(state, spec)
    if not state then
        return nil, nil
    end

    local key = _normalize_pin_key(spec and spec.key or nil)
    local type_id = type(spec and spec.type_id) == "string" and spec.type_id or nil
    for index = state.next_index, #state.list do
        if not state.consumed[index] then
            local pin_data = state.list[index]
            if type(pin_data) ~= "table" then
                return index, pin_data
            end

            local candidate_key = _normalize_pin_key(rawget(pin_data, "key"))
            local candidate_type_id = type(rawget(pin_data, "type_id")) == "string" and rawget(pin_data, "type_id") or nil
            local key_compatible = key == nil or candidate_key == nil or candidate_key == key
            local type_compatible = type_id == nil or candidate_type_id == nil or candidate_type_id == type_id
            if key_compatible and type_compatible then
                return index, pin_data
            end
        end
    end

    return nil, nil
end

local function _resolve_pin_data(self, is_output, spec)
    if spec and spec.raw_data then
        local state = is_output and self._output_match_state or self._input_match_state
        _consume_raw_pin_data(state, spec.raw_data)
        return spec.raw_data
    end

    local state = is_output and self._output_match_state or self._input_match_state
    local key = _normalize_pin_key(spec and spec.key or nil)
    local index, pin_data = nil, nil

    if key then
        index, pin_data = _find_match_by_key(state, key)
    end
    if not pin_data then
        index, pin_data = _find_match_by_aliases(state, spec and spec.aliases or nil)
    end
    if not pin_data then
        index, pin_data = _find_match_by_legacy_index(state, spec and spec.legacy_index or nil)
    end
    if not pin_data then
        index, pin_data = _find_match_by_sequence(state, spec)
    end

    if index then
        _mark_consumed(state, index)
    end

    return pin_data
end

local function _apply_default_value(self, pin, spec, pin_data)
    if not pin or not spec or self._data ~= nil or pin_data ~= nil or not pin.set_val then
        return
    end

    if type(spec.default_factory) == "function" then
        pin:set_val(spec.default_factory())
        return
    end

    if rawget(spec, "default") ~= nil then
        pin:set_val(spec.default)
    end
end

function NodeBuilder:ctor(node, data)
    self._node = node
    self._data = data
    self._input_match_state = _build_match_state(data and data.input_pin_list or nil)
    self._output_match_state = _build_match_state(data and data.output_pin_list or nil)
end

function NodeBuilder:add_pin(spec)
    assert(type(spec) == "table", "builder:add_pin expects a table")
    assert(type(spec.type_id) == "string" and #spec.type_id > 0, "builder:add_pin missing type_id")

    local is_output = spec.direction == "output"
    local pin_key = _normalize_pin_key(spec.key)
    if rawget(spec, "key") ~= nil then
        assert(pin_key ~= nil, "builder:add_pin key must be a non-empty string when provided")
    end
    if rawget(spec, "legacy_index") ~= nil then
        assert(type(spec.legacy_index) == "number" and spec.legacy_index >= 1,
            "builder:add_pin legacy_index must be a positive integer")
    end

    local pin_data = _resolve_pin_data(self, is_output, spec)
    local pin_id = pin_data and pin_data.id or self._node._blueprint:gen_next_uid()
    local pin = PinFactory.create(
    {
        type_id = spec.type_id,
        pin_id = pin_id,
        owner_id = self._node._id,
        direction = is_output and "output" or "input",
        name = spec.name,
        options = spec.options,
        raw_data = pin_data,
        key = pin_key,
        legacy_index = spec.legacy_index,
        aliases = spec.aliases,
        style_binding = spec.style_binding,
    })

    if is_output then
        if pin_key then
            assert(self._node._output_pin_map[pin_key] == nil,
                string.format("duplicate output pin key on node [%s]: %s", tostring(self._node._type_id), pin_key))
            self._node._output_pin_map[pin_key] = pin
        end
        table.insert(self._node._output_pin_list, pin)
    else
        if pin_key then
            assert(self._node._input_pin_map[pin_key] == nil,
                string.format("duplicate input pin key on node [%s]: %s", tostring(self._node._type_id), pin_key))
            self._node._input_pin_map[pin_key] = pin
        end
        table.insert(self._node._input_pin_list, pin)
    end

    _apply_default_value(self, pin, spec, pin_data)
    return pin
end

function NodeBuilder:add_input(spec)
    spec = spec or {}
    spec.direction = "input"
    return self:add_pin(spec)
end

function NodeBuilder:add_output(spec)
    spec = spec or {}
    spec.direction = "output"
    return self:add_pin(spec)
end

function NodeBuilder:attach_legacy(pin_data, pin_type_id, is_output, name, extra_args)
    return self:add_pin(
    {
        type_id = pin_type_id,
        direction = is_output and "output" or "input",
        name = name,
        options = extra_args,
        raw_data = pin_data,
    })
end

return NodeBuilder

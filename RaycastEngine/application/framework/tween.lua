local module = {}

local GameObject = require("application.framework.game_object")

local function on_update(o, delta)
    if not o._valid then return end

    o._elapsed_time = o._elapsed_time + delta
    local t = o._ease_func(o._elapsed_time, o._duration)
    o._target[o._field] = o._from + (o._to - o._from) * t

    if o._elapsed_time >= o._duration then
        if rawget(o, "_callback") then o._callback() end
        o._valid = false
    end
end

local function _ease_linear(elapsed_time, duration)
    return math.clamp(elapsed_time / duration, 0, 1)
end

local function _ease_out(elapsed_time, duration)
    local t = math.clamp(elapsed_time / duration, 0, 1)
    local factor <const> = 10
    return (t >= 1) and 1 or (1 - 2 ^ (-factor * t))
end

local function _ease_in(elapsed_time, duration)
    local t = math.clamp(elapsed_time / duration, 0, 1)
    return t ^ 3
end

module.new = function(target, field, from, to, duration, callback, ease_type)
    local o = 
    {
        _metaname = "Tween",

        texture = nil,
        w = 0, h = 0,

        _target = target,
        _field = field,
        _from = from, _to = to,
        _duration = duration,
        _callback = callback,
        _elapsed_time = 0,
        _ease_func = _ease_linear,

        on_update = on_update,
    }
    if ease_type then
        if ease_type == "out" then
            o._ease_func = _ease_out
        elseif ease_type == "in" then
            o._ease_func = _ease_in
        elseif ease_type == "linear" then
            o._ease_func = _ease_linear
        else
            error(string.format("unknown ease type: %s", ease_type))
        end
    end
    setmetatable(o, GameObject.new())
    o.__index = o
    return o
end

return module
local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")

local Tween = Class.define("Tween", GameObject)

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

function Tween:ctor(target, field, from, to, duration, callback, ease_type)
    Class.call_super(Tween, self, "ctor")
    self._target = target
    self._field = field
    self._from = from
    self._to = to
    self._duration = duration
    self._callback = callback
    self._elapsed_time = 0
    self._ease_func = _ease_linear
    if ease_type then
        if ease_type == "out" then
            self._ease_func = _ease_out
        elseif ease_type == "in" then
            self._ease_func = _ease_in
        elseif ease_type == "linear" then
            self._ease_func = _ease_linear
        else
            error(string.format("unknown ease type: %s", ease_type))
        end
    end
end

Tween.on_update = on_update

return Tween

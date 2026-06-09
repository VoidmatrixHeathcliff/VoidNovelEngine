local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")

local Timer = Class.define("Timer", GameObject)

function Timer:ctor(wait_time, callback, one_shot)
    Class.call_super(Timer, self, "ctor")
    self._pass_time = 0
    self._wait_time = wait_time
    self._paused = false
    self._shotted = false
    self._one_shot = one_shot
    self._callback = callback
end

function Timer:restart()
    self._pass_time = 0
    self._paused = false
    self._shotted = false
end

function Timer:set_wait_time(val)
    self._wait_time = val
end

function Timer:set_one_shot(val)
    self._one_shot = val
end

function Timer:set_callback(callback)
    self._callback = callback
end

function Timer:pause()
    self._paused = true
end

function Timer:resume()
    self._paused = false
end

function Timer:on_update(delta)
    if self._paused then return end
    
    self._pass_time = self._pass_time + delta
    if self._pass_time >= self._wait_time then
        local can_shot = (not rawget(self, "_one_shot") or (rawget(self, "_one_shot") and not self._shotted))
        self._shotted = true
        if can_shot and rawget(self, "_callback") then
            self:_callback()
        end
        self._pass_time = self._pass_time - self._wait_time
    end
end

return Timer

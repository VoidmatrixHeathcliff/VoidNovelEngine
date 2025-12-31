local module = {}

local GameObject = require("application.framework.game_object")

local function restart(self)
    self._pass_time = 0
    self._paused = false
    self._shotted = false
end

local function set_wait_time(self, val)
    self._wait_time = val
end

local function set_one_shot(self, val)
    self._one_shot = val
end

local function set_callback(self, callback)
    self._callback = callback
end

local function pause(self)
    self._paused = true
end

local function resume(self)
    self._paused = false
end

local function on_update(self, delta)
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

module.new = function(wait_time, callback, one_shot)
    local o = 
    {
        _metaname = "Timer",

        _pass_time = 0,
        _wait_time = wait_time,
        _paused = false,
        _shotted = false,
        _one_shot = one_shot,
        _callback = callback,

        restart = restart,
        set_wait_time = set_wait_time,
        set_one_shot = set_one_shot,
        set_callback = set_callback,
        pause = pause,
        resume = resume,
        on_update = on_update,
    }
    setmetatable(o, GameObject.new())
    o.__index = o
    return o
end

return module
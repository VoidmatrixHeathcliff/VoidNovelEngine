local module = {}

local rl = Engine.Raylib

local Scene = require("application.framework.scene")

local function on_enter(self)

end

local function on_exit(self)

end

local function on_update(self, delta)
    self.interval = self.interval + delta
    self.scale = math.sin(self.interval)
    if rl.IsKeyPressed(rl.KeyboardKey.SPACE) then
        self._execute_next_node()
    end
end

local function on_render(self)
    rl.DrawCircle(1920 / 2, 1080 / 2, 200 + 100 * self.scale, rl.Color(45, 100, 215, 135))
    rl.DrawCircleLines(1920 / 2, 1080 / 2, 200 + 100 * self.scale, rl.Color(45, 100, 215, 215))
end

module.new = function()
    local o = 
    {
        scale = 0,
        interval = 0,

        on_enter = on_enter,
        on_exit = on_exit,
        on_update = on_update,
        on_render = on_render,
    }
    setmetatable(o, Scene.new())
    o.__index = o
    return o
end

return module

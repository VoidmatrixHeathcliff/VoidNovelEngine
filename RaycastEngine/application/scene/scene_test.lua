local rl = Engine.Raylib

local Class = require("application.framework.class")
local Scene = require("application.framework.scene")

local SceneTest = Class.define("SceneTest", Scene)

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

function SceneTest:ctor()
    Class.call_super(SceneTest, self, "ctor")
    self.scale = 0
    self.interval = 0
end

SceneTest.on_enter = on_enter
SceneTest.on_exit = on_exit
SceneTest.on_update = on_update
SceneTest.on_render = on_render

return SceneTest

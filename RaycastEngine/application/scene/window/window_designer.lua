local module = {}

local imgui = Engine.ImGUI

module.on_enter = function()

end

module.on_update = function(self, delta)
    imgui.Begin("界面视图")
        
    imgui.End()
end

return module
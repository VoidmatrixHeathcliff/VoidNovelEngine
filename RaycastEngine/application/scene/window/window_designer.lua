local module = {}

local imgui = Engine.ImGUI

module.on_enter = function()

end

module.on_update = function(self, delta)
    local is_open = imgui.Begin("界面视图")
    if is_open then
        
    end
    imgui.End()
end

return module

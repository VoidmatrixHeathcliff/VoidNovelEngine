local module = {}

local imgui = Engine.ImGUI

module.on_enter = function()

end

module.on_update = function(self, delta)
    imgui.Begin("界面设计视图")
        imgui.TextDisabled("当前版本暂不支持界面设计功能…")
    imgui.End()
end

return module
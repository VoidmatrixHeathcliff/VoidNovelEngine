local module = {}

local imgui = Engine.ImGUI

local LogManager = require("application.framework.log_manager")

local color_bg <const> = imgui.ImColor(5, 15, 25, 255)

module.on_enter = function()

end

module.on_update = function(self, delta)
    imgui.PushStyleColor(imgui.ImGuiCol.WindowBg, color_bg.value)
    imgui.Begin("控制台")
    imgui.PopStyleColor()
        LogManager.on_update()
        if imgui.GetScrollY() >= imgui.GetScrollMaxY() then
            imgui.SetScrollHereY(1)
        end
    imgui.End()
end

return module
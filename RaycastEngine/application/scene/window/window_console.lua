local module = {}

local imgui = Engine.ImGUI

local EditorThemeManager = require("application.framework.editor_theme_manager")
local LogManager = require("application.framework.log_manager")

local function _is_scroll_at_bottom()
    local scroll_y = tonumber(imgui.GetScrollY()) or 0
    local scroll_max_y = tonumber(imgui.GetScrollMaxY()) or 0
    return scroll_max_y <= 0 or scroll_y >= scroll_max_y - 1
end

module.on_enter = function()

end

module.on_update = function(self, delta)
    imgui.PushStyleColor(imgui.ImGuiCol.WindowBg, EditorThemeManager.get_console_bg_color())
    local is_open = imgui.Begin("控制台")
    imgui.PopStyleColor()
    if is_open then
        local was_at_bottom = _is_scroll_at_bottom()
        LogManager.on_update()
        if was_at_bottom then
            imgui.SetScrollHereY(1)
        end
    end
    imgui.End()
end

return module

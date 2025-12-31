local module = {}

local imgui = Engine.ImGUI

module.HoveredTooltip = function(text)
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
            imgui.TextDisabled(text)
        imgui.EndTooltip()
    end
end

module.PushRedButtonColors = function()
    imgui.PushStyleColor(imgui.ImGuiCol.Button, imgui.ImColor():from_hsv(0 / 7.0, 0.6, 0.6).value)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, imgui.ImColor():from_hsv(0 / 7.0, 0.7, 0.7).value)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, imgui.ImColor():from_hsv(0 / 7.0, 0.8, 0.8).value)
end

module.PushGreenButtonColors = function()
    imgui.PushStyleColor(imgui.ImGuiCol.Button, imgui.ImColor():from_hsv(2 / 7.0, 0.6, 0.6).value)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, imgui.ImColor():from_hsv(2 / 7.0, 0.7, 0.7).value)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, imgui.ImColor():from_hsv(2 / 7.0, 0.8, 0.8).value)
end

module.PopColorButtonColors = function()
    imgui.PopStyleColor(3)
end

return module
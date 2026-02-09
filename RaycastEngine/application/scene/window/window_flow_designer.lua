local module = {}

local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

local Blueprint = require("application.framework.blueprint")
local LogManager = require("application.framework.log_manager")
local ImGUIHelper = require("application.framework.imgui_helper")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")

local text_stop <const> = "停止调试"

module.on_enter = function()

end

module.on_update = function(self, delta)
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    if GlobalContext.is_debug_game then
        local blueprint = GlobalContext.current_blueprint
        while rawget(blueprint, "_next_node") do
            blueprint._current_node = blueprint._next_node
            blueprint._next_node = nil
            blueprint._current_node:on_exetute(blueprint._scene_context, rawget(blueprint, "_next_node_entry_pin"))
        end
        if GlobalContext.is_debug_game then
            blueprint._scene_context:on_update(delta)
            blueprint._current_node:on_exetute_update(blueprint._scene_context, delta)
        end
        GlobalContext.is_simulated_interaction = false
    end
    imgui.Begin("流程脚本视图")
        local pos_begin = imgui.GetCursorScreenPos()
        local size_content = imgui.GetContentRegionAvail()
        imgui.BeginDisabled(GlobalContext.is_debug_game)
            if imgui.BeginTabBar("TabBar_Blueprints", imgui.TabBarFlags.Reorderable | imgui.TabBarFlags.AutoSelectNewTabs) then
                for _, bp in ipairs(GlobalContext.blueprint_list) do
                    bp:on_update(delta)
                end
                imgui.EndTabBar()
            end
        imgui.EndDisabled()
        local pos_end = imgui.ImVec2(pos_begin.x + size_content.x, pos_begin.y + size_content.y)
        if GlobalContext.is_debug_game then
            local size_stop_icon <const> = imgui.ImVec2(24 * editor_zoom_ratio, 24 * editor_zoom_ratio)
            local size_stop_button <const> = imgui.ImVec2(122 * editor_zoom_ratio, 32 * editor_zoom_ratio)
            imgui.GetWindowDrawList():AddRectFilled(pos_begin, pos_end, imgui.ImColor(0, 0, 0, 150):to_u32())
            local position_stop_button = imgui.ImVec2(pos_begin.x + size_content.x / 2 - size_stop_button.x / 2, pos_begin.y + 40 * editor_zoom_ratio)
            imgui.SetCursorScreenPos(position_stop_button)
            ImGUIHelper.PushRedButtonColors()
            imgui.BeginChild("dummy_window")
                if imgui.Button("##stop_debug", size_stop_button) then
                    LogManager.log("调试中断", "warning")
                    GlobalContext.stop_debug()
                end
                imgui.SetCursorScreenPos(imgui.ImVec2(position_stop_button.x + 10 * editor_zoom_ratio, position_stop_button.y + size_stop_button.y / 2 - size_stop_icon.y / 2))
                imgui.Image(ResourcesManager.find_icon("forbid-line"), size_stop_icon, nil, nil, nil, nil)
                imgui.PushFont(GlobalContext.font_imgui, 22 * editor_zoom_ratio)
                    local size_text_stop <const> = imgui.CalcTextSize(text_stop)
                    imgui.SetCursorScreenPos(imgui.ImVec2(position_stop_button.x + 10 * editor_zoom_ratio + size_stop_icon.x + 8 * editor_zoom_ratio, 
                        position_stop_button.y + size_stop_button.y / 2 - size_text_stop.y / 2))
                    imgui.Text(text_stop)
                imgui.PopFont()
            imgui.EndChild()
            ImGUIHelper.PopColorButtonColors()
        end
    imgui.End()
end

module.on_render = function(self, delta)
    if GlobalContext.is_debug_game then
        GlobalContext.current_blueprint._scene_context:on_render()
    end
end

return module
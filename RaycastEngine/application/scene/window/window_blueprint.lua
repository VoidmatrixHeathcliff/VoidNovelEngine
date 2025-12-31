local module = {}

local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

local Blueprint = require("application.framework.blueprint")
local LogManager = require("application.framework.log_manager")
local ImGUIHelper = require("application.framework.imgui_helper")
local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")

local size_stop_icon <const> = imgui.ImVec2(24, 24)
local size_stop_button <const> = imgui.ImVec2(122, 32)
local text_stop <const> = "停止调试"
local size_text_stop = nil

module.on_enter = function()
    local path_list = rl.LoadDirectoryFilesEx("application\\blueprint", nil, true)
    for i = 1, path_list.count do
        local path = path_list:get(i - 1)
        local ext = string.lower(rl.GetFileExtension(path))
        if ext == ".bp" then
            table.insert(GlobalContext.blueprint_list, 
                Blueprint.new(util.GBKToUTF8(path)))
        end
    end
    rl.UnloadDirectoryFiles(path_list)
end

module.on_update = function(self, delta)
    if GlobalContext.is_debug_game then
        local blueprint = GlobalContext.current_blueprint
        while rawget(blueprint, "_next_node") do
            blueprint._current_node = blueprint._next_node
            blueprint._next_node = nil
            blueprint._current_node:on_exetute(blueprint._scene_context, rawget(blueprint, "_next_node_entry_pin"))
        end
        blueprint._scene_context:on_update(delta)
        blueprint._current_node:on_exetute_update(blueprint._scene_context, delta)
        GlobalContext.is_simulated_interaction = false
    end
    imgui.Begin("流程视图")
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
            imgui.GetWindowDrawList():AddRectFilled(pos_begin, pos_end, imgui.ImColor(0, 0, 0, 150):to_u32())
            local position_stop_button = imgui.ImVec2(pos_begin.x + size_content.x / 2 - size_stop_button.x / 2, pos_begin.y + 40)
            imgui.SetCursorScreenPos(position_stop_button)
            ImGUIHelper.PushRedButtonColors()
            imgui.BeginChild("dummy_window")
                if imgui.Button("##stop_debug", size_stop_button) then
                    LogManager.log("调试中断", "warning")
                    GlobalContext.stop_debug()
                end
                imgui.SetCursorScreenPos(imgui.ImVec2(position_stop_button.x + 10, position_stop_button.y + size_stop_button.y / 2 - size_stop_icon.y / 2))
                imgui.Image(ResourcesManager.find_icon("forbid-line"), size_stop_icon, nil, nil, nil, nil)
                imgui.PushFont(GlobalContext.font_imgui, 22)
                    if not size_text_stop then size_text_stop = imgui.CalcTextSize(text_stop) end
                    imgui.SetCursorScreenPos(imgui.ImVec2(position_stop_button.x + 10 + size_stop_icon.x + 8, position_stop_button.y + size_stop_button.y / 2 - size_text_stop.y / 2 - 1))
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
local module = {}

local imgui = Engine.ImGUI

local ImGUIHelper = require("application.framework.imgui_helper")
local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")

local log_obj_list = {}
local icon_config = 
{
    info = {icon_id = "information-2-fill", color = imgui.ImVec4(imgui.ImColor(44, 169, 225, 255).value)},
    warning = {icon_id = "alert-fill", color = imgui.ImVec4(imgui.ImColor(248, 181, 0, 255).value)},
    error = {icon_id = "close-circle-fill", color = imgui.ImVec4(imgui.ImColor(197, 61, 67, 255).value)},
    success = {icon_id = "checkbox-circle-fill", color = imgui.ImVec4(imgui.ImColor(104, 190, 141, 255).value)},
    debug = {icon_id = "bug-fill", color = imgui.ImVec4(imgui.ImColor(188, 100, 164, 255).value)},
}

local size_icon <const> = imgui.ImVec2(18, 18)
local size_button <const> = imgui.ImVec2(16, 16)

module.log = function(msg, type_msg, nav_data)
    table.insert(log_obj_list, 
    {
        msg = msg, type_msg = type_msg or "info",
        time = os.date("[%Y-%m-%d %H:%M:%S]"),
        nav_data = nav_data
    })
end

module.clear = function()
    log_obj_list = {}
end

module.on_update = function()
    local pos_wrap = imgui.GetContentRegionAvail().x
    for idx, log_obj in ipairs(log_obj_list) do
        local config = icon_config[log_obj.type_msg] or icon_config["info"]
        imgui.Image(ResourcesManager.find_icon(config.icon_id), size_icon, nil, nil, config.color, nil)
        imgui.SameLine()
        imgui.Text(log_obj.time)
        imgui.SameLine()
        if not log_obj.nav_data then
            imgui.PushTextWrapPos(pos_wrap)
                imgui.Text(log_obj.msg)
            imgui.PopTextWrapPos()
        else
            imgui.PushTextWrapPos(pos_wrap - size_button.x)
                imgui.Text(log_obj.msg)
            imgui.PopTextWrapPos()
            imgui.SameLine()
            if imgui.ImageButton(string.format("nav_btn_%d", idx), ResourcesManager.find_icon("navigation-fill"), size_button, nil, nil, nil, nil) then
                for _, blueprint in ipairs(GlobalContext.blueprint_list) do
                    if blueprint._id == log_obj.nav_data.blueprint then
                        blueprint._is_open.val = true
                        GlobalContext.bp_id_selected_next_frame = blueprint._id
                        imgui.NodeEditor.SetCurrentEditor(blueprint._context)
                        imgui.NodeEditor.SelectNode(imgui.NodeEditor.NodeId(log_obj.nav_data.id))
                        imgui.NodeEditor.NavigateToSelection()
                        break
                    end
                end
            end
            ImGUIHelper.HoveredTooltip("导航到该节点")
        end
    end
end

return module
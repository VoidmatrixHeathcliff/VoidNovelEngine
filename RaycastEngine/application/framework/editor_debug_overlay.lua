local imgui = Engine.ImGUI

local EditorThemeManager = require("application.framework.editor_theme_manager")
local GlobalContext = require("application.framework.global_context")
local ImGUIHelper = require("application.framework.imgui_helper")
local LogManager = require("application.framework.log_manager")
local ResourcesManager = require("application.framework.resources_manager")

local module = {}

local text_stop <const> = "停止调试"
local debug_overlay_dim_color_u32 <const> = imgui.ImColor(0, 0, 0, 150):to_u32()

local function _valid_host(host_pos, host_size)
    return host_pos ~= nil
        and host_size ~= nil
        and (tonumber(host_size.x) or 0) > 0
        and (tonumber(host_size.y) or 0) > 0
end

local function _make_uid(value)
    local uid = tostring(value or "current")
    uid = uid:gsub("[^%w_%-]", "_")
    if uid == "" then
        return "current"
    end
    return uid
end

function module.draw_stop_overlay(uid, host_pos, host_size, editor_zoom_ratio)
    if not _valid_host(host_pos, host_size) then
        return false
    end

    local zoom = tonumber(editor_zoom_ratio) or 1
    local safe_uid = _make_uid(uid)
    local panel_min = imgui.ImVec2(host_pos.x or 0, host_pos.y or 0)
    local panel_max = imgui.ImVec2(panel_min.x + (host_size.x or 0), panel_min.y + (host_size.y or 0))
    local draw_list = imgui.GetWindowDrawList()
    if draw_list then
        draw_list:AddRectFilled(panel_min, panel_max, debug_overlay_dim_color_u32)
    end

    local size_stop_icon <const> = imgui.ImVec2(24 * zoom, 24 * zoom)
    local size_stop_button <const> = imgui.ImVec2(122 * zoom, 32 * zoom)
    local position_stop_button = imgui.ImVec2(
        panel_min.x + (host_size.x or 0) / 2 - size_stop_button.x / 2,
        panel_min.y + 40 * zoom)
    local stop_palette = EditorThemeManager.get_semantic_button_palette("danger")
    local stop_icon_tint = EditorThemeManager.get_icon_on_color(stop_palette.button)
    local stop_text_color = EditorThemeManager.get_text_on_color(stop_palette.button)
    imgui.SetCursorScreenPos(position_stop_button)
    ImGUIHelper.PushRedButtonColors()
    imgui.BeginChild(
        string.format("debug_stop_overlay_button_%s", safe_uid),
        size_stop_button,
        nil,
        imgui.WindowFlags.NoBackground | imgui.WindowFlags.NoScrollbar | imgui.WindowFlags.NoScrollWithMouse)
        imgui.SetCursorScreenPos(position_stop_button)
        if imgui.Button(string.format("##stop_debug_%s", safe_uid), size_stop_button) then
            LogManager.log("调试中断", "warning")
            GlobalContext.stop_debug()
        end
        imgui.SetCursorScreenPos(imgui.ImVec2(
            position_stop_button.x + 10 * zoom,
            position_stop_button.y + size_stop_button.y / 2 - size_stop_icon.y / 2))
        imgui.Image(ResourcesManager.find_icon("forbid-line"), size_stop_icon, nil, nil, stop_icon_tint, nil)
        imgui.PushFont(GlobalContext.font_imgui, 22 * zoom)
            local size_text_stop <const> = imgui.CalcTextSize(text_stop)
            imgui.SetCursorScreenPos(imgui.ImVec2(
                position_stop_button.x + 10 * zoom + size_stop_icon.x + 8 * zoom,
                position_stop_button.y + size_stop_button.y / 2 - size_text_stop.y / 2))
            imgui.TextColored(stop_text_color, text_stop)
        imgui.PopFont()
    imgui.EndChild()
    ImGUIHelper.PopColorButtonColors()
    return true
end

return module

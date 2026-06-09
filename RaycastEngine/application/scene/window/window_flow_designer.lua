local module = {}

local imgui = Engine.ImGUI

local EditorThemeManager = require("application.framework.editor_theme_manager")
local EditorDebugOverlay = require("application.framework.editor_debug_overlay")
local FlowManager = require("application.framework.flow_manager")
local FlowRuntimeHost = require("application.framework.flow_runtime_host")
local ImGUIHelper = require("application.framework.imgui_helper")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")

local pending_window_focus_frames = 0
local flow_guard_overlay_should_display = false

local function _resolve_flow_guard_overlay_target()
    local current_blueprint = GlobalContext.current_blueprint
    if current_blueprint and current_blueprint.get_flow_guard_overlay_model then
        local current_model = current_blueprint:get_flow_guard_overlay_model()
        if current_model then
            return current_blueprint, current_model
        end
    end

    local fallback_blueprint = nil
    local fallback_model = nil
    for _, blueprint in ipairs(FlowManager.get_workspace_open_blueprints()) do
        if blueprint and blueprint.get_flow_guard_overlay_model then
            local next_model = blueprint:get_flow_guard_overlay_model()
            if next_model then
                fallback_blueprint = blueprint
                fallback_model = next_model
                if next_model.state == "protect" then
                    break
                end
            end
        end
    end

    return fallback_blueprint, fallback_model
end

local function _draw_flow_guard_overlay(editor_zoom_ratio)
    if not flow_guard_overlay_should_display then
        return
    end

    local overlay_blueprint, model = _resolve_flow_guard_overlay_target()
    if not overlay_blueprint or not model or not model.host_pos or not model.host_size then
        return
    end

    local state = model.state
    local panel_rounding = 9 * editor_zoom_ratio
    local border_thickness = math.max(1, math.floor(1.5 * editor_zoom_ratio + 0.5))
    local shadow_offset = math.max(2, math.floor(2 * editor_zoom_ratio + 0.5))
    local padding_x = math.max(10, math.floor(11 * editor_zoom_ratio + 0.5))
    local padding_y = math.max(6, math.floor(7 * editor_zoom_ratio + 0.5))
    local accent_width = math.max(3, math.floor(3 * editor_zoom_ratio + 0.5))
    local content_top_gap = math.max(4, math.floor(4 * editor_zoom_ratio + 0.5))
    local shadow_color = EditorThemeManager.with_alpha(EditorThemeManager.get_modal_overlay_color(), 0.24)

    local title_font_size = 17 * editor_zoom_ratio
    local body_font_size = 14 * editor_zoom_ratio
    local title_size
    imgui.PushFont(GlobalContext.font_imgui, title_font_size)
        title_size = imgui.CalcTextSize(model.title)
    imgui.PopFont()

    local suggestion_size
    imgui.PushFont(GlobalContext.font_imgui, body_font_size)
        suggestion_size = imgui.CalcTextSize(model.suggestion)
    imgui.PopFont()

    local content_width = math.max(title_size.x, suggestion_size.x)
    local body_height = suggestion_size.y
    local panel_size = imgui.ImVec2(
        content_width + padding_x * 2 + accent_width,
        title_size.y + body_height + padding_y * 2 + content_top_gap + 6 * editor_zoom_ratio)
    local overlay_margin = 10 * editor_zoom_ratio
    local overlay_pos = imgui.ImVec2(
        model.host_pos.x + overlay_margin,
        model.host_pos.y + overlay_margin)
    local overlay_size = imgui.ImVec2(panel_size.x + shadow_offset, panel_size.y + shadow_offset)
    local overlay_name = string.format("flow_guard_overlay_%s", overlay_blueprint._resource_guid or overlay_blueprint._id or "current")
    local overlay_flags = imgui.WindowFlags.NoDocking
        | imgui.WindowFlags.NoTitleBar
        | imgui.WindowFlags.NoCollapse
        | imgui.WindowFlags.NoResize
        | imgui.WindowFlags.NoMove
        | imgui.WindowFlags.NoScrollbar
        | imgui.WindowFlags.NoScrollWithMouse
        | imgui.WindowFlags.NoSavedSettings
        | imgui.WindowFlags.NoBackground
        | imgui.WindowFlags.NoInputs
        | imgui.WindowFlags.NoFocusOnAppearing
        | imgui.WindowFlags.NoNavFocus
    local viewport = imgui.GetMainViewport()

    imgui.SetNextWindowPos(overlay_pos, imgui.ImGuiCond.Always)
    imgui.SetNextWindowSize(overlay_size, imgui.ImGuiCond.Always)
    if viewport then
        imgui.SetNextWindowViewport(viewport.ID)
    end
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVar(imgui.StyleVar.WindowRounding, 0)
    imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 0)
    imgui.Begin(string.format("##%s", overlay_name), nil, overlay_flags)
        local draw_list = imgui.GetWindowDrawList()
        local panel_min = imgui.GetCursorScreenPos()
        local panel_max = imgui.ImVec2(panel_min.x + panel_size.x, panel_min.y + panel_size.y)
        local inner_min = imgui.ImVec2(panel_min.x + border_thickness, panel_min.y + border_thickness)
        local inner_max = imgui.ImVec2(panel_max.x - border_thickness, panel_max.y - border_thickness)
        local inner_rounding = math.max(0, panel_rounding - border_thickness)
        local title_bar_max = imgui.ImVec2(inner_max.x, inner_min.y + title_size.y + padding_y * 2)
        local shadow_min = imgui.ImVec2(panel_min.x + shadow_offset, panel_min.y + shadow_offset)
        local shadow_max = imgui.ImVec2(panel_max.x + shadow_offset, panel_max.y + shadow_offset)

        if draw_list then
            draw_list:AddRectFilled(shadow_min, shadow_max, imgui.ImColor(shadow_color):to_u32(), panel_rounding)
            draw_list:AddRectFilled(panel_min, panel_max, imgui.ImColor(EditorThemeManager.with_alpha(model.border_color, 0.92)):to_u32(), panel_rounding)
            draw_list:AddRectFilled(inner_min, inner_max, imgui.ImColor(model.panel_bg):to_u32(), inner_rounding)
            draw_list:AddRectFilled(inner_min, title_bar_max, imgui.ImColor(model.title_bg):to_u32(), inner_rounding, imgui.ImDrawFlags.RoundCornersTop)
            draw_list:AddRectFilled(
                imgui.ImVec2(inner_min.x, inner_min.y + inner_rounding),
                imgui.ImVec2(inner_min.x + accent_width, inner_max.y - inner_rounding),
                imgui.ImColor(EditorThemeManager.with_alpha(model.border_color, state == "protect" and 0.92 or 0.78)):to_u32())

            imgui.PushFont(GlobalContext.font_imgui, title_font_size)
                draw_list:AddText(
                    imgui.ImVec2(inner_min.x + padding_x + accent_width, inner_min.y + padding_y),
                    imgui.ImColor(model.title_color):to_u32(),
                    model.title)
            imgui.PopFont()

            local body_x = inner_min.x + padding_x + accent_width
            local body_y = title_bar_max.y + content_top_gap
            imgui.PushFont(GlobalContext.font_imgui, body_font_size)
                draw_list:AddText(imgui.ImVec2(body_x, body_y), imgui.ImColor(model.secondary_color):to_u32(), model.suggestion)
            imgui.PopFont()
        end
        imgui.Dummy(overlay_size)
    imgui.End()
    imgui.PopStyleVar(3)
end

module.on_enter = function()
    pending_window_focus_frames = 8
    flow_guard_overlay_should_display = false
end

module.on_exit = function()
    GlobalContext.is_flow_designer_window_focused = false
    pending_window_focus_frames = 0
    flow_guard_overlay_should_display = false
end

function module.open_flow_document(value, options)
    local document = type(value) == "table" and value or FlowManager.get_document(value, "flow_document_open")
    if not document or document.kind ~= "graph" then
        return nil
    end

    local open_options = options or {select = true}
    local opened_document = FlowManager.open_document_in_workspace(document, open_options)
    if opened_document and open_options.select ~= false then
        pending_window_focus_frames = math.max(pending_window_focus_frames, 2)
    end
    return opened_document
end

module.on_update = function(self, delta)
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    if pending_window_focus_frames > 0 and not GlobalContext.is_resource_modal_active then
        imgui.SetNextWindowFocus()
        pending_window_focus_frames = pending_window_focus_frames - 1
    end
    if GlobalContext.is_debug_game then
        FlowRuntimeHost.update(delta)
        GlobalContext.is_simulated_interaction = false
    end
    GlobalContext.is_flow_designer_window_focused = false
    local is_window_visible = imgui.Begin("流程脚本视图")
        GlobalContext.is_flow_designer_window_focused = imgui.IsWindowFocused(imgui.FocusedFlags.RootAndChildWindows)
        flow_guard_overlay_should_display = is_window_visible
        local pos_begin = imgui.GetCursorScreenPos()
        local size_content = imgui.GetContentRegionAvail()
        local tab_border_style = nil
        if ImGUIHelper.ShouldUseInHThemeCompensation() then
            tab_border_style = ImGUIHelper.PushSoftTabBorderStyle(editor_zoom_ratio)
        end
        if imgui.BeginTabBar("TabBar_Blueprints", imgui.TabBarFlags.Reorderable | imgui.TabBarFlags.AutoSelectNewTabs) then
            for _, bp in ipairs(FlowManager.get_workspace_open_blueprints()) do
                bp:on_update(delta)
            end
            imgui.EndTabBar()
        end
        if tab_border_style then
            ImGUIHelper.PopSoftTabBorderStyle(tab_border_style)
        end
        if GlobalContext.is_debug_game then
            EditorDebugOverlay.draw_stop_overlay("flow", pos_begin, size_content, editor_zoom_ratio)
        end
        FlowManager.sync_workspace_state()
    imgui.End()
    if not GlobalContext.is_debug_game then
        _draw_flow_guard_overlay(editor_zoom_ratio)
    end
end

module.on_render = function(self, delta)
    if GlobalContext.is_debug_game then
        FlowRuntimeHost.render()
    end
end

return module

local util = Engine.Util
local imgui = Engine.ImGUI
local sdl = Engine.SDL

local EditorThemeManager = require("application.framework.editor_theme_manager")
local GlobalContext = require("application.framework.global_context")
local ImGUIHelper = require("application.framework.imgui_helper")
local LogManager = require("application.framework.log_manager")
local ModifyManager = require("application.framework.modify_manager")
local ResourceIndex = require("application.framework.resource_index")
local ResourceReferenceField = require("application.framework.resource_reference_field")
local ResourcesManager = require("application.framework.resources_manager")
local SaveSlotGridModel = require("application.framework.save_slot_grid_model")
local SaveThumbnailCache = require("application.framework.save_thumbnail_cache")
local SettingsManager = require("application.framework.settings_manager")
local StyleAdapterFactory = require("application.framework.style_adapter_factory")
local TextWrapper = require("application.framework.text_wrapper")
local UI = require("application.framework.ui")
local UIRuntime = require("application.framework.ui_runtime")
local UIWidgetRegistry = require("application.framework.ui_widget_registry")
local UIWorkspaceManager = require("application.framework.ui_workspace_manager")
local UndoManager = require("application.framework.undo_manager")

local module = {}
module.Config = require("application.scene.window.ui_designer_config")

local selected_widget_by_guid = {}
local preview_state_by_guid = {}
local widget_clipboard = nil
local create_widget_request = nil
local pending_create_widget_popup = false
local tree_context_widget_by_guid = {}
local pending_tree_context_popup_by_guid = {}
local was_window_focused = false
local pending_tab_select_guid = nil
local pending_window_focus_frames = 0
local focus_reclaim_armed = false
local pending_open_error_text = nil

local int_adapter = StyleAdapterFactory.make_int_adapter()
local float_adapter = StyleAdapterFactory.make_float_adapter()
local bool_adapter = StyleAdapterFactory.make_bool_adapter()
local string_adapter = StyleAdapterFactory.make_string_adapter()
local vector2_adapter = StyleAdapterFactory.make_vector2_adapter()
local color_adapter = StyleAdapterFactory.make_color_adapter()
local resource_adapter_pool = {}
local function _get_preview_style_dependency_key(_, state)
    if state then
        state.style_dependency_reference_key = nil
        state.style_dependency_guid_list = {}
        state.style_dependency_index_revision = tonumber(GlobalContext.resource_index_revision) or 0
    end
    return "none"
end

local function _supports_click_auto_close(kind)
    return kind == "none"
        or kind == "close_ui"
        or kind == "open_ui"
        or kind == "quick_save"
        or kind == "quick_load"
end

local _clamp_preview_resize_edges
local _get_preview_state
local _draw_widget_position_panel
local _place_widget_in_parent_visible_area

local function _trim(text)
    if type(text) ~= "string" then
        return nil
    end
    local value = text:match("^%s*(.-)%s*$")
    if value == "" then
        return nil
    end
    return value
end

local function _get_project_canvas_size()
    local width = math.max(1, math.floor(tonumber(SettingsManager.get("width_game_window")) or 1920))
    local height = math.max(1, math.floor(tonumber(SettingsManager.get("height_game_window")) or 1080))
    return width, height
end

local function _get_canvas_mode_label(mode)
    local mode_id = tostring(mode or "fixed")
    for _, item in ipairs(module.Config.canvas_mode_list) do
        if item.id == mode_id then
            return item.label
        end
    end
    return "固定尺寸"
end

local function _get_click_action_label(kind)
    local kind_id = tostring(kind or "none")
    return module.Config.click_action_label_pool[kind_id] or kind_id
end

local function _normalize_click_action_kind(kind)
    local kind_id = _trim(kind) or "none"
    return module.Config.click_action_label_pool[kind_id] and kind_id or "none"
end

local function _get_reentry_policy_label(policy)
    local policy_id = tostring(policy or "repeatable")
    return module.Config.reentry_policy_label_pool[policy_id] or policy_id
end

local function _normalize_reentry_policy(value)
    local policy = _trim(value) or "repeatable"
    if policy == "ignore" then
        return "once"
    end
    if policy == "restart" or policy == "queue" then
        return "repeatable"
    end
    if policy ~= "once" and policy ~= "repeatable" then
        return "repeatable"
    end
    return policy
end

local function _normalize_auto_advance_interval(value)
    local interval = tonumber(value) or 1.0
    if interval < 0.1 then
        interval = 0.1
    end
    if interval > 60 then
        interval = 60
    end
    return interval
end

local function _get_property_enum_label(property_key, value)
    local value_id = tostring(value or "")
    local label_pool = module.Config.property_enum_label_pool[property_key]
    return label_pool and label_pool[value_id] or value_id
end

local function _get_runtime_image_fit_mode(runtime, widget)
    local mode = _trim(runtime and runtime.resolve_widget_prop and runtime:resolve_widget_prop(widget, "image_fit_mode") or nil)
    if mode == "fill" then
        return "fill"
    end
    if mode == "preserve_aspect" then
        return "preserve_aspect"
    end
    return "preserve_aspect"
end

local function _runtime_should_show_progress(runtime, widget)
    if widget and type(widget.props) == "table" and widget.props.show_progress ~= nil then
        return widget.props.show_progress == true
    end
    return runtime:resolve_widget_prop(widget, "show_progress") ~= false
end

local function _get_sdl_texture_size(texture)
    if not texture then
        return 0, 0
    end
    local ok, info = pcall(sdl.QueryTexture, texture)
    if ok and type(info) == "table" then
        return tonumber(info.w) or 0, tonumber(info.h) or 0
    end
    return 0, 0
end

local function _resolve_document_canvas_size(snapshot)
    local canvas = snapshot and snapshot.canvas or {}
    local mode = tostring(canvas.mode or "fixed")
    if mode == "project" or mode == "responsive" then
        return _get_project_canvas_size()
    end
    return math.max(1, tonumber(canvas.width) or 1920), math.max(1, tonumber(canvas.height) or 1080)
end

local function _clone_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[_clone_value(key, seen)] = _clone_value(item, seen)
    end
    return copy
end

local function _get_document_uid(document)
    return document._resource_guid or document._id
end

local function _with_document_context(document, callback)
    if not document or type(callback) ~= "function" then
        return false
    end

    local previous_modify_context = ModifyManager.get_context()
    local previous_undo_context = UndoManager.get_context()
    ModifyManager.set_context(document._modify_context)
    UndoManager.set_context(document._undo_context)
    local ok, result = pcall(callback, document)
    UndoManager.set_context(previous_undo_context)
    ModifyManager.set_context(previous_modify_context)
    if not ok then
        error(result)
    end
    return result
end

local function _get_selected_widget_id(document)
    local uid = _get_document_uid(document)
    local widget_id = selected_widget_by_guid[uid] or "root"
    local widget = document:get_widget(widget_id)
    if widget then
        return widget_id
    end
    selected_widget_by_guid[uid] = "root"
    return "root"
end

local function _set_selected_widget_id(document, widget_id)
    selected_widget_by_guid[_get_document_uid(document)] = widget_id or "root"
end

local function _normalize_vec2(value, default_x, default_y)
    if type(value) == "userdata" then
        return
        {
            x = tonumber(value.x) or default_x or 0,
            y = tonumber(value.y) or default_y or 0,
        }
    end

    if type(value) ~= "table" then
        return {x = default_x or 0, y = default_y or 0}
    end

    return
    {
        x = tonumber(value.x) or tonumber(value[1]) or default_x or 0,
        y = tonumber(value.y) or tonumber(value[2]) or default_y or 0,
    }
end

local function _normalize_padding(value)
    if type(value) ~= "table" then
        return {left = 0, top = 0, right = 0, bottom = 0}
    end

    return
    {
        left = tonumber(value.left) or tonumber(value[1]) or 0,
        top = tonumber(value.top) or tonumber(value[2]) or 0,
        right = tonumber(value.right) or tonumber(value[3]) or 0,
        bottom = tonumber(value.bottom) or tonumber(value[4]) or 0,
    }
end

local function _normalize_color(value, default_alpha)
    if type(value) == "userdata" then
        return
        {
            r = tonumber(value.x) or 1,
            g = tonumber(value.y) or 1,
            b = tonumber(value.z) or 1,
            a = tonumber(value.w) or default_alpha or 1,
        }
    end

    if type(value) ~= "table" then
        return {r = 1, g = 1, b = 1, a = default_alpha or 1}
    end

    return
    {
        r = tonumber(value.r) or tonumber(value.x) or tonumber(value[1]) or 1,
        g = tonumber(value.g) or tonumber(value.y) or tonumber(value[2]) or 1,
        b = tonumber(value.b) or tonumber(value.z) or tonumber(value[3]) or 1,
        a = tonumber(value.a) or tonumber(value.w) or tonumber(value[4]) or default_alpha or 1,
    }
end

local function _mul_alpha(color, alpha)
    local normalized = _normalize_color(color, 1)
    normalized.a = normalized.a * (alpha or 1)
    return normalized
end

local function _to_u32(color, alpha)
    local value = _mul_alpha(color, alpha or 1)
    return imgui.ImColor(
        math.max(0, math.min(255, math.floor(value.r * 255 + 0.5))),
        math.max(0, math.min(255, math.floor(value.g * 255 + 0.5))),
        math.max(0, math.min(255, math.floor(value.b * 255 + 0.5))),
        math.max(0, math.min(255, math.floor(value.a * 255 + 0.5)))):to_u32()
end

local function _clamp(value, min_value, max_value)
    local number = tonumber(value) or 0
    if number < min_value then
        return min_value
    end
    if number > max_value then
        return max_value
    end
    return number
end

local function _lerp(from, to, factor)
    return from + (to - from) * factor
end

local function _make_rect(x, y, w, h)
    return {x = x, y = y, w = w, h = h}
end

local function _make_rect_from_edges(left, top, right, bottom)
    return
    {
        x = left,
        y = top,
        w = right - left,
        h = bottom - top,
    }
end

local function _copy_rect(rect)
    if not rect then
        return nil
    end
    return
    {
        x = tonumber(rect.x) or 0,
        y = tonumber(rect.y) or 0,
        w = tonumber(rect.w) or 0,
        h = tonumber(rect.h) or 0,
    }
end

local function _expand_rect(rect, left, top, right, bottom)
    return
    {
        x = rect.x - left,
        y = rect.y - top,
        w = rect.w + left + right,
        h = rect.h + top + bottom,
    }
end

local function _union_rect(left, right)
    if not left then
        return _copy_rect(right)
    end
    if not right then
        return _copy_rect(left)
    end

    local min_x = math.min(left.x, right.x)
    local min_y = math.min(left.y, right.y)
    local max_x = math.max(left.x + left.w, right.x + right.w)
    local max_y = math.max(left.y + left.h, right.y + right.h)
    return _make_rect(min_x, min_y, max_x - min_x, max_y - min_y)
end

local function _rect_contains(rect, x, y)
    if not rect then
        return false
    end
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h
end

local function _rect_intersection(left, right)
    if not left then
        return _copy_rect(right)
    end
    if not right then
        return _copy_rect(left)
    end

    local x1 = math.max(left.x, right.x)
    local y1 = math.max(left.y, right.y)
    local x2 = math.min(left.x + left.w, right.x + right.w)
    local y2 = math.min(left.y + left.h, right.y + right.h)
    if x2 <= x1 or y2 <= y1 then
        return _make_rect(x1, y1, 0, 0)
    end
    return _make_rect(x1, y1, x2 - x1, y2 - y1)
end

local function _inset_rect(rect, left, top, right, bottom)
    return
    {
        x = rect.x + left,
        y = rect.y + top,
        w = math.max(0, rect.w - left - right),
        h = math.max(0, rect.h - top - bottom),
    }
end

local function _transform_rect(rect, preview_rect, scale)
    return
    {
        x = preview_rect.x + rect.x * scale,
        y = preview_rect.y + rect.y * scale,
        w = rect.w * scale,
        h = rect.h * scale,
    }
end

local function _get_preview_camera_rect(fit_rect, canvas_width, canvas_height, scale, pan_x, pan_y)
    local draw_width = canvas_width * scale
    local draw_height = canvas_height * scale
    return
    {
        x = fit_rect.x + (fit_rect.w - draw_width) * 0.5 + (pan_x or 0),
        y = fit_rect.y + (fit_rect.h - draw_height) * 0.5 + (pan_y or 0),
        w = draw_width,
        h = draw_height,
    }
end

local function _get_preview_pan_limit(fit_size, draw_size)
    local visible_margin = math.max(28, math.floor(math.min(fit_size * 0.16, 96) + 0.5))
    return math.max(0, (fit_size + draw_size) * 0.5 - visible_margin)
end

local function _clamp_preview_pan(fit_rect, draw_width, draw_height, pan_x, pan_y)
    local max_pan_x = _get_preview_pan_limit(fit_rect.w, draw_width)
    local max_pan_y = _get_preview_pan_limit(fit_rect.h, draw_height)
    return _clamp(pan_x, -max_pan_x, max_pan_x), _clamp(pan_y, -max_pan_y, max_pan_y)
end

local function _step_preview_view(preview_state)
    preview_state.view_zoom = _lerp(preview_state.view_zoom, preview_state.view_zoom_target, module.Config.preview_view_smooth_factor)
    if preview_state.view_pan_active then
        preview_state.view_pan_x = preview_state.view_pan_target_x
        preview_state.view_pan_y = preview_state.view_pan_target_y
    else
        preview_state.view_pan_x = _lerp(preview_state.view_pan_x, preview_state.view_pan_target_x, module.Config.preview_view_smooth_factor)
        preview_state.view_pan_y = _lerp(preview_state.view_pan_y, preview_state.view_pan_target_y, module.Config.preview_view_smooth_factor)
    end

    if math.abs(preview_state.view_zoom - preview_state.view_zoom_target) < 0.0005 then
        preview_state.view_zoom = preview_state.view_zoom_target
    end
    if math.abs(preview_state.view_pan_x - preview_state.view_pan_target_x) < 0.1 then
        preview_state.view_pan_x = preview_state.view_pan_target_x
    end
    if math.abs(preview_state.view_pan_y - preview_state.view_pan_target_y) < 0.1 then
        preview_state.view_pan_y = preview_state.view_pan_target_y
    end
end

local function _collect_preview_content_bounds(widget, bounds)
    if not widget or widget.visible == false then
        return bounds
    end

    if widget.id ~= "root" and widget.rect and widget.rect.w > 0 and widget.rect.h > 0 then
        bounds = _union_rect(bounds, widget.rect)
    end

    for _, child in ipairs(widget.children or {}) do
        bounds = _collect_preview_content_bounds(child, bounds)
    end
    return bounds
end

local function _get_preview_content_bounds(instance, canvas_width, canvas_height)
    local bounds = _collect_preview_content_bounds(instance and instance.root or nil, nil)
    if bounds and bounds.w > 0 and bounds.h > 0 then
        return bounds
    end
    return _make_rect(0, 0, canvas_width, canvas_height)
end

local function _focus_preview_to_content(preview_state, instance, fit_rect, canvas_width, canvas_height, fit_scale)
    if not preview_state or not fit_rect then
        return
    end

    local content_bounds = _get_preview_content_bounds(instance, canvas_width, canvas_height)
    local ui_zoom = tonumber(SettingsManager.get("editor_zoom_ratio")) or 1.0
    local screen_padding = math.max(20, math.floor(28 * ui_zoom + 0.5))
    local padded_bounds = _expand_rect(
        content_bounds,
        screen_padding / math.max(0.001, fit_scale),
        screen_padding / math.max(0.001, fit_scale),
        screen_padding / math.max(0.001, fit_scale),
        screen_padding / math.max(0.001, fit_scale))
    local available_scale = math.min(
        fit_rect.w / math.max(1, padded_bounds.w),
        fit_rect.h / math.max(1, padded_bounds.h))
    local clamped_scale = _clamp(
        available_scale,
        fit_scale * module.Config.preview_zoom_min,
        fit_scale * module.Config.preview_zoom_max)
    local target_zoom = _clamp(clamped_scale / math.max(0.001, fit_scale), module.Config.preview_zoom_min, module.Config.preview_zoom_max)
    local target_scale = fit_scale * target_zoom
    local center_x = padded_bounds.x + padded_bounds.w * 0.5
    local center_y = padded_bounds.y + padded_bounds.h * 0.5
    local pan_x = (canvas_width * 0.5 - center_x) * target_scale
    local pan_y = (canvas_height * 0.5 - center_y) * target_scale
    pan_x, pan_y = _clamp_preview_pan(
        fit_rect,
        canvas_width * target_scale,
        canvas_height * target_scale,
        pan_x,
        pan_y)

    preview_state.view_pan_active = false
    preview_state.view_pan_button = nil
    preview_state.view_pan_start_mouse = nil
    preview_state.view_zoom_target = target_zoom
    preview_state.view_pan_target_x = pan_x
    preview_state.view_pan_target_y = pan_y
end

local function _request_preview_focus_to_content(document)
    local state = _get_preview_state(document)
    state.request_focus_to_content = true
    state.drag = nil
    state.drag_did_move = false
    state.press_candidate_id = nil
    state.snap_guides = nil
    state.view_pan_active = false
    state.view_pan_button = nil
    state.view_pan_start_mouse = nil
end

local function _draw_outline(draw_list, rect, color_u32, thickness)
    local line = math.max(1, math.floor((thickness or 1) + 0.5))
    draw_list:AddRectFilled(imgui.ImVec2(rect.x, rect.y), imgui.ImVec2(rect.x + rect.w, rect.y + line), color_u32)
    draw_list:AddRectFilled(imgui.ImVec2(rect.x, rect.y + rect.h - line), imgui.ImVec2(rect.x + rect.w, rect.y + rect.h), color_u32)
    draw_list:AddRectFilled(imgui.ImVec2(rect.x, rect.y), imgui.ImVec2(rect.x + line, rect.y + rect.h), color_u32)
    draw_list:AddRectFilled(imgui.ImVec2(rect.x + rect.w - line, rect.y), imgui.ImVec2(rect.x + rect.w, rect.y + rect.h), color_u32)
end

local function _can_transform_widget(widget)
    if not widget or widget.id == "root" or widget.visible == false or not widget.parent then
        return false
    end
    if module.Config.preview_auto_layout_parent_pool[widget.parent.type] then
        return false
    end
    return true
end

local function _get_widget_parent_content_rect(widget, canvas_width, canvas_height)
    if widget and widget.layout_parent_rect then
        return _copy_rect(widget.layout_parent_rect)
    end
    if widget and widget.parent and widget.parent.content_rect then
        return _copy_rect(widget.parent.content_rect)
    end
    return _make_rect(0, 0, canvas_width, canvas_height)
end

local function _rect_to_offsets(rect, parent_rect, anchor_min, anchor_max)
    local left = tonumber(rect.x) or 0
    local top = tonumber(rect.y) or 0
    local right = left + (tonumber(rect.w) or 0)
    local bottom = top + (tonumber(rect.h) or 0)
    local parent_x = tonumber(parent_rect and parent_rect.x) or 0
    local parent_y = tonumber(parent_rect and parent_rect.y) or 0
    local parent_w = tonumber(parent_rect and parent_rect.w) or 0
    local parent_h = tonumber(parent_rect and parent_rect.h) or 0
    local anchor_min_x = tonumber(anchor_min and anchor_min.x) or 0
    local anchor_min_y = tonumber(anchor_min and anchor_min.y) or 0
    local anchor_max_x = tonumber(anchor_max and anchor_max.x) or 0
    local anchor_max_y = tonumber(anchor_max and anchor_max.y) or 0
    return
    {
        x = left - parent_x - parent_w * anchor_min_x,
        y = top - parent_y - parent_h * anchor_min_y,
    },
    {
        x = right - parent_x - parent_w * anchor_max_x,
        y = bottom - parent_y - parent_h * anchor_max_y,
    }
end

local function _get_resize_handle_screen_rect(screen_rect, handle)
    local ui_zoom = tonumber(SettingsManager.get("editor_zoom_ratio")) or 1.0
    local size = math.max(8, math.floor(module.Config.preview_resize_handle_visual_size * ui_zoom + 0.5))
    local center_x = screen_rect.x + screen_rect.w * handle.ox
    local center_y = screen_rect.y + screen_rect.h * handle.oy
    return _make_rect(center_x - size * 0.5, center_y - size * 0.5, size, size)
end

local function _pick_resize_handle(screen_rect, mouse_x, mouse_y)
    if not screen_rect or screen_rect.w <= 0 or screen_rect.h <= 0 then
        return nil
    end

    local ui_zoom = tonumber(SettingsManager.get("editor_zoom_ratio")) or 1.0
    local hit_padding = math.max(3, math.floor(module.Config.preview_resize_handle_hit_padding * ui_zoom + 0.5))
    for _, handle in ipairs(module.Config.preview_resize_handle_list) do
        local handle_rect = _get_resize_handle_screen_rect(screen_rect, handle)
        local hit_rect = _make_rect(
            handle_rect.x - hit_padding,
            handle_rect.y - hit_padding,
            handle_rect.w + hit_padding * 2,
            handle_rect.h + hit_padding * 2)
        if _rect_contains(hit_rect, mouse_x, mouse_y) then
            return handle.key
        end
    end
    return nil
end

local function _draw_resize_handles(draw_list, screen_rect, palette, hovered_handle_key)
    if not screen_rect or screen_rect.w <= 0 or screen_rect.h <= 0 then
        return
    end

    local normal_fill = module.Config.preview_transform_color
    local hover_fill = module.Config.preview_transform_color
    local outline_color = module.Config.preview_transform_color

    for _, handle in ipairs(module.Config.preview_resize_handle_list) do
        local handle_rect = _get_resize_handle_screen_rect(screen_rect, handle)
        local fill = hovered_handle_key == handle.key and hover_fill or normal_fill
        draw_list:AddRectFilled(
            imgui.ImVec2(handle_rect.x, handle_rect.y),
            imgui.ImVec2(handle_rect.x + handle_rect.w, handle_rect.y + handle_rect.h),
            _to_u32(fill, 1),
            0)
        _draw_outline(draw_list, handle_rect, _to_u32(outline_color, 1), 1)
    end
end

local function _pick_preview_widget_by_screen(instance, canvas_draw_rect, scale, mouse_x, mouse_y)
    if not instance or type(instance.ordered_widget_list) ~= "table" then
        return nil
    end

    for index = #instance.ordered_widget_list, 1, -1 do
        local widget = instance.ordered_widget_list[index]
        if widget and widget.visible and widget.id ~= "root" then
            local screen_rect = _transform_rect(widget.rect, canvas_draw_rect, scale)
            if _rect_contains(screen_rect, mouse_x, mouse_y) then
                return widget
            end
        end
    end
    return nil
end

local function _is_runtime_widget_related(widget, excluded_widget_id)
    if not widget or not excluded_widget_id then
        return false
    end
    if widget.id == excluded_widget_id then
        return true
    end

    local current = widget.parent
    while current do
        if current.id == excluded_widget_id then
            return true
        end
        current = current.parent
    end
    return false
end

local function _build_preview_snap_candidates(instance, excluded_widget_id, canvas_width, canvas_height)
    local candidates =
    {
        x =
        {
            {value = 0, source = "canvas"},
            {value = canvas_width * 0.5, source = "canvas"},
            {value = canvas_width, source = "canvas"},
        },
        y =
        {
            {value = 0, source = "canvas"},
            {value = canvas_height * 0.5, source = "canvas"},
            {value = canvas_height, source = "canvas"},
        },
    }

    for _, widget in ipairs(instance and instance.ordered_widget_list or {}) do
        if widget
            and widget.visible
            and widget.id ~= "root"
            and not _is_runtime_widget_related(widget, excluded_widget_id)
        then
            candidates.x[#candidates.x + 1] = {value = widget.rect.x, source = "widget", widget_id = widget.id}
            candidates.x[#candidates.x + 1] = {value = widget.rect.x + widget.rect.w * 0.5, source = "widget", widget_id = widget.id}
            candidates.x[#candidates.x + 1] = {value = widget.rect.x + widget.rect.w, source = "widget", widget_id = widget.id}
            candidates.y[#candidates.y + 1] = {value = widget.rect.y, source = "widget", widget_id = widget.id}
            candidates.y[#candidates.y + 1] = {value = widget.rect.y + widget.rect.h * 0.5, source = "widget", widget_id = widget.id}
            candidates.y[#candidates.y + 1] = {value = widget.rect.y + widget.rect.h, source = "widget", widget_id = widget.id}
        end
    end

    return candidates
end

local function _find_best_preview_snap(candidates, targets, threshold)
    local best = nil
    for _, target in ipairs(targets or {}) do
        for _, candidate in ipairs(candidates or {}) do
            local delta = (tonumber(candidate.value) or 0) - (tonumber(target.value) or 0)
            local distance = math.abs(delta)
            if distance <= threshold then
                if not best
                    or distance < best.distance
                    or (math.abs(distance - best.distance) < 0.0001 and candidate.source == "canvas" and best.guide.source ~= "canvas")
                then
                    best =
                    {
                        delta = delta,
                        distance = distance,
                        guide = candidate,
                        target = target,
                    }
                end
            end
        end
    end
    return best
end

local function _build_preview_snap_guide_list(best_x, best_y)
    local guide_list = {}
    if best_x then
        guide_list[#guide_list + 1] =
        {
            axis = "x",
            value = best_x.guide.value,
            source = best_x.guide.source,
            widget_id = best_x.guide.widget_id,
        }
    end
    if best_y then
        guide_list[#guide_list + 1] =
        {
            axis = "y",
            value = best_y.guide.value,
            source = best_y.guide.source,
            widget_id = best_y.guide.widget_id,
        }
    end
    return guide_list
end

local function _build_preview_rect_from_size(start_rect, target_width, target_height, handle_w, handle_e, handle_n, handle_s, center_resize)
    local left = start_rect.x
    local top = start_rect.y
    local right = start_rect.x + start_rect.w
    local bottom = start_rect.y + start_rect.h
    local center_x = start_rect.x + start_rect.w * 0.5
    local center_y = start_rect.y + start_rect.h * 0.5

    if center_resize then
        return _make_rect(center_x - target_width * 0.5, center_y - target_height * 0.5, target_width, target_height)
    end

    if handle_w and handle_n then
        left = right - target_width
        top = bottom - target_height
    elseif handle_e and handle_n then
        right = left + target_width
        top = bottom - target_height
    elseif handle_w and handle_s then
        left = right - target_width
        bottom = top + target_height
    elseif handle_e and handle_s then
        right = left + target_width
        bottom = top + target_height
    elseif handle_w or handle_e then
        if handle_w then
            left = right - target_width
        else
            right = left + target_width
        end
        top = center_y - target_height * 0.5
        bottom = center_y + target_height * 0.5
    elseif handle_n or handle_s then
        if handle_n then
            top = bottom - target_height
        else
            bottom = top + target_height
        end
        left = center_x - target_width * 0.5
        right = center_x + target_width * 0.5
    end

    return _make_rect_from_edges(left, top, right, bottom)
end

local function _apply_preview_move_snap(rect, drag, threshold)
    local best_x = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.x,
    {
        {value = rect.x, kind = "left"},
        {value = rect.x + rect.w * 0.5, kind = "center"},
        {value = rect.x + rect.w, kind = "right"},
    }, threshold)
    local best_y = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.y,
    {
        {value = rect.y, kind = "top"},
        {value = rect.y + rect.h * 0.5, kind = "center"},
        {value = rect.y + rect.h, kind = "bottom"},
    }, threshold)

    if best_x then
        rect.x = rect.x + best_x.delta
    end
    if best_y then
        rect.y = rect.y + best_y.delta
    end
    return rect, _build_preview_snap_guide_list(best_x, best_y)
end

local function _apply_preview_resize_snap(rect, drag, threshold)
    local handle = tostring(drag.handle or "")
    local handle_w = string.find(handle, "w", 1, true) ~= nil
    local handle_e = string.find(handle, "e", 1, true) ~= nil
    local handle_n = string.find(handle, "n", 1, true) ~= nil
    local handle_s = string.find(handle, "s", 1, true) ~= nil
    local io = imgui.GetIO()
    local center_resize = io and io.KeyCtrl == true
    local keep_aspect = io and io.KeyShift == true and drag.start_rect.w > 0.001 and drag.start_rect.h > 0.001
    local left = rect.x
    local top = rect.y
    local right = rect.x + rect.w
    local bottom = rect.y + rect.h

    if not keep_aspect then
        local best_x = nil
        local best_y = nil
        if handle_w then
            best_x = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.x, {{value = left, kind = "left"}}, threshold)
        elseif handle_e then
            best_x = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.x, {{value = right, kind = "right"}}, threshold)
        end
        if handle_n then
            best_y = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.y, {{value = top, kind = "top"}}, threshold)
        elseif handle_s then
            best_y = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.y, {{value = bottom, kind = "bottom"}}, threshold)
        end

        if best_x then
            if center_resize then
                if handle_w then
                    left = left + best_x.delta
                    right = right - best_x.delta
                else
                    left = left - best_x.delta
                    right = right + best_x.delta
                end
            elseif handle_w then
                left = left + best_x.delta
            else
                right = right + best_x.delta
            end
        end
        if best_y then
            if center_resize then
                if handle_n then
                    top = top + best_y.delta
                    bottom = bottom - best_y.delta
                else
                    top = top - best_y.delta
                    bottom = bottom + best_y.delta
                end
            elseif handle_n then
                top = top + best_y.delta
            else
                bottom = bottom + best_y.delta
            end
        end

        left, top, right, bottom = _clamp_preview_resize_edges(left, top, right, bottom, drag, center_resize, handle_w, handle_e, handle_n, handle_s)
        return _make_rect_from_edges(left, top, right, bottom), _build_preview_snap_guide_list(best_x, best_y)
    end

    local aspect_ratio = drag.start_rect.w / math.max(0.001, drag.start_rect.h)
    local best_x = nil
    local best_y = nil
    if handle_w then
        best_x = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.x, {{value = left, kind = "left"}}, threshold)
    elseif handle_e then
        best_x = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.x, {{value = right, kind = "right"}}, threshold)
    end
    if handle_n then
        best_y = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.y, {{value = top, kind = "top"}}, threshold)
    elseif handle_s then
        best_y = _find_best_preview_snap(drag.snap_candidates and drag.snap_candidates.y, {{value = bottom, kind = "bottom"}}, threshold)
    end

    local use_x = false
    local use_y = false
    if best_x and best_y then
        use_x = best_x.distance <= best_y.distance
        use_y = not use_x
    else
        use_x = best_x ~= nil
        use_y = best_y ~= nil
    end

    if not use_x and not use_y then
        return rect, nil
    end

    local target_width = rect.w
    local target_height = rect.h
    if use_x and best_x then
        if center_resize then
            local center_x = drag.start_rect.x + drag.start_rect.w * 0.5
            local snapped_edge = (handle_w and left or right) + best_x.delta
            target_width = math.abs(snapped_edge - center_x) * 2
        elseif handle_w then
            target_width = math.max(0, right - (left + best_x.delta))
        else
            target_width = math.max(0, (right + best_x.delta) - left)
        end
        target_height = target_width / math.max(0.001, aspect_ratio)
    else
        if center_resize then
            local center_y = drag.start_rect.y + drag.start_rect.h * 0.5
            local snapped_edge = (handle_n and top or bottom) + best_y.delta
            target_height = math.abs(snapped_edge - center_y) * 2
        elseif handle_n then
            target_height = math.max(0, bottom - (top + best_y.delta))
        else
            target_height = math.max(0, (bottom + best_y.delta) - top)
        end
        target_width = target_height * aspect_ratio
    end

    local min_width = math.max(module.Config.preview_min_widget_extent, tonumber(drag.min_size and drag.min_size.x) or 0)
    local min_height = math.max(module.Config.preview_min_widget_extent, tonumber(drag.min_size and drag.min_size.y) or 0)
    local scale = math.max(target_width / math.max(0.001, drag.start_rect.w), target_height / math.max(0.001, drag.start_rect.h))
    local min_scale = math.max(min_width / math.max(0.001, drag.start_rect.w), min_height / math.max(0.001, drag.start_rect.h))
    scale = math.max(scale, min_scale)
    target_width = drag.start_rect.w * scale
    target_height = drag.start_rect.h * scale

    local snapped_rect = _build_preview_rect_from_size(drag.start_rect, target_width, target_height, handle_w, handle_e, handle_n, handle_s, center_resize)
    return snapped_rect, _build_preview_snap_guide_list(use_x and best_x or nil, use_y and best_y or nil)
end

local function _draw_preview_snap_guides(draw_list, host_rect, canvas_draw_rect, scale, guide_list, palette)
    if type(guide_list) ~= "table" or #guide_list == 0 then
        return
    end

    local guide_color = _to_u32(EditorThemeManager.with_alpha(palette.selection, 0.92), 1)
    local line_thickness = math.max(1, math.floor((tonumber(SettingsManager.get("editor_zoom_ratio")) or 1.0) + 0.5))
    for _, guide in ipairs(guide_list) do
        if guide.axis == "x" then
            local screen_x = canvas_draw_rect.x + guide.value * scale
            draw_list:AddRectFilled(
                imgui.ImVec2(screen_x, host_rect.y),
                imgui.ImVec2(screen_x + line_thickness, host_rect.y + host_rect.h),
                guide_color)
        elseif guide.axis == "y" then
            local screen_y = canvas_draw_rect.y + guide.value * scale
            draw_list:AddRectFilled(
                imgui.ImVec2(host_rect.x, screen_y),
                imgui.ImVec2(host_rect.x + host_rect.w, screen_y + line_thickness),
                guide_color)
        end
    end
end

local function _make_inline_editor_label(label_text, unique_key)
    return string.format("%s##%s", label_text or "", unique_key or "")
end

local function _get_inspector_label_width(label_text, available_width, min_field_width)
    local text_size = imgui.CalcTextSize(label_text or "")
    local sample_size = imgui.CalcTextSize(module.Config.inspector_label_sample)
    local style = imgui.GetStyle()
    local gap = style and style.ItemInnerSpacing and style.ItemInnerSpacing.x or 4
    local min_label_width = math.max(1, sample_size.x)
    local wanted_width = math.max(min_label_width, text_size.x)
    local field_floor = math.min(
        math.max(1, min_field_width or module.Config.inspector_min_field_width),
        module.Config.inspector_hard_min_field_width)
    local usable_width = math.max(1, available_width or 0)
    local max_label_width = math.max(1, usable_width - field_floor - gap)
    local label_width = math.min(wanted_width, math.max(min_label_width, max_label_width))
    label_width = math.min(label_width, math.max(1, usable_width - gap))
    return label_width, text_size.x, gap
end

local function _draw_inspector_labeled_control(label_text, draw_control, min_field_width)
    local start_pos = imgui.GetCursorPos()
    local available_width = imgui.GetContentRegionAvail().x
    local label_width, text_width, gap = _get_inspector_label_width(label_text, available_width, min_field_width)
    local display_label = label_text or ""
    if text_width > label_width then
        display_label = ImGUIHelper.EllipsisHead(display_label, label_width)
        text_width = imgui.CalcTextSize(display_label).x
    end

    imgui.AlignTextToFramePadding()
    local label_pos = imgui.GetCursorPos()
    local label_offset_x = 0
    imgui.SetCursorPos(imgui.ImVec2(start_pos.x + label_offset_x, label_pos.y))
    imgui.TextColored(imgui.ImColor(206, 214, 226, 255).value, display_label)
    imgui.SameLine()

    local control_pos = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(start_pos.x + label_width + gap, control_pos.y))
    local field_width = math.max(1, imgui.GetContentRegionAvail().x)
    return draw_control(field_width)
end

_clamp_preview_resize_edges = function(left, top, right, bottom, drag, center_resize, handle_w, handle_e, handle_n, handle_s)
    local min_width = math.max(module.Config.preview_min_widget_extent, tonumber(drag.min_size and drag.min_size.x) or 0)
    local min_height = math.max(module.Config.preview_min_widget_extent, tonumber(drag.min_size and drag.min_size.y) or 0)

    if right - left < min_width then
        if center_resize then
            local center_x = (left + right) * 0.5
            left = center_x - min_width * 0.5
            right = center_x + min_width * 0.5
        elseif handle_w and not handle_e then
            left = right - min_width
        else
            right = left + min_width
        end
    end

    if bottom - top < min_height then
        if center_resize then
            local center_y = (top + bottom) * 0.5
            top = center_y - min_height * 0.5
            bottom = center_y + min_height * 0.5
        elseif handle_n and not handle_s then
            top = bottom - min_height
        else
            bottom = top + min_height
        end
    end

    return left, top, right, bottom
end

local function _build_preview_resize_rect(drag, delta_x, delta_y)
    local start_rect = drag.start_rect
    local start_left = start_rect.x
    local start_top = start_rect.y
    local start_right = start_rect.x + start_rect.w
    local start_bottom = start_rect.y + start_rect.h
    local start_center_x = start_rect.x + start_rect.w * 0.5
    local start_center_y = start_rect.y + start_rect.h * 0.5
    local handle = tostring(drag.handle or "")
    local handle_w = string.find(handle, "w", 1, true) ~= nil
    local handle_e = string.find(handle, "e", 1, true) ~= nil
    local handle_n = string.find(handle, "n", 1, true) ~= nil
    local handle_s = string.find(handle, "s", 1, true) ~= nil
    local io = imgui.GetIO()
    local center_resize = io and io.KeyCtrl == true
    local keep_aspect = io and io.KeyShift == true and start_rect.w > 0.001 and start_rect.h > 0.001

    local left = start_left
    local top = start_top
    local right = start_right
    local bottom = start_bottom

    if not keep_aspect then
        if handle_w then
            if center_resize then
                left = start_left + delta_x
                right = start_right - delta_x
            else
                left = start_left + delta_x
            end
        elseif handle_e then
            if center_resize then
                left = start_left - delta_x
                right = start_right + delta_x
            else
                right = start_right + delta_x
            end
        end

        if handle_n then
            if center_resize then
                top = start_top + delta_y
                bottom = start_bottom - delta_y
            else
                top = start_top + delta_y
            end
        elseif handle_s then
            if center_resize then
                top = start_top - delta_y
                bottom = start_bottom + delta_y
            else
                bottom = start_bottom + delta_y
            end
        end

        left, top, right, bottom = _clamp_preview_resize_edges(left, top, right, bottom, drag, center_resize, handle_w, handle_e, handle_n, handle_s)
        return _make_rect_from_edges(left, top, right, bottom)
    end

    local scale_x = nil
    local scale_y = nil
    if handle_w then
        scale_x = (start_rect.w - delta_x * (center_resize and 2 or 1)) / start_rect.w
    elseif handle_e then
        scale_x = (start_rect.w + delta_x * (center_resize and 2 or 1)) / start_rect.w
    end
    if handle_n then
        scale_y = (start_rect.h - delta_y * (center_resize and 2 or 1)) / start_rect.h
    elseif handle_s then
        scale_y = (start_rect.h + delta_y * (center_resize and 2 or 1)) / start_rect.h
    end

    local scale = 1.0
    if scale_x and scale_y then
        scale = math.abs(scale_x - 1.0) >= math.abs(scale_y - 1.0) and scale_x or scale_y
    else
        scale = scale_x or scale_y or 1.0
    end

    local min_scale = math.max(
        (tonumber(drag.min_size and drag.min_size.x) or module.Config.preview_min_widget_extent) / math.max(0.001, start_rect.w),
        (tonumber(drag.min_size and drag.min_size.y) or module.Config.preview_min_widget_extent) / math.max(0.001, start_rect.h))
    scale = math.max(scale, min_scale)

    local target_width = start_rect.w * scale
    local target_height = start_rect.h * scale

    if center_resize then
        left = start_center_x - target_width * 0.5
        right = start_center_x + target_width * 0.5
        top = start_center_y - target_height * 0.5
        bottom = start_center_y + target_height * 0.5
        return _make_rect_from_edges(left, top, right, bottom)
    end

    if handle_w and handle_n then
        right = start_right
        bottom = start_bottom
        left = right - target_width
        top = bottom - target_height
    elseif handle_e and handle_n then
        left = start_left
        bottom = start_bottom
        right = left + target_width
        top = bottom - target_height
    elseif handle_w and handle_s then
        right = start_right
        top = start_top
        left = right - target_width
        bottom = top + target_height
    elseif handle_e and handle_s then
        left = start_left
        top = start_top
        right = left + target_width
        bottom = top + target_height
    elseif handle_w or handle_e then
        if handle_w then
            right = start_right
            left = right - target_width
        else
            left = start_left
            right = left + target_width
        end
        top = start_center_y - target_height * 0.5
        bottom = start_center_y + target_height * 0.5
    elseif handle_n or handle_s then
        if handle_n then
            bottom = start_bottom
            top = bottom - target_height
        else
            top = start_top
            bottom = top + target_height
        end
        left = start_center_x - target_width * 0.5
        right = start_center_x + target_width * 0.5
    end

    return _make_rect_from_edges(left, top, right, bottom)
end

local function _get_resource_adapter(resource_type)
    resource_adapter_pool[resource_type] = resource_adapter_pool[resource_type] or StyleAdapterFactory.make_resource_adapter(resource_type)
    return resource_adapter_pool[resource_type]
end

local function _get_property_adapter(property)
    local type_id = property.type_id
    if type_id == "int" then
        return int_adapter
    end
    if type_id == "float" then
        return float_adapter
    end
    if type_id == "bool" then
        return bool_adapter
    end
    if type_id == "string" then
        return string_adapter
    end
    if type_id == "vec2" then
        return vector2_adapter
    end
    if type_id == "color" then
        return color_adapter
    end
    if type_id == "resource" and property.resource_type then
        return _get_resource_adapter(property.resource_type)
    end
    return nil
end

local function _get_theme_palette()
    return
    {
        text = imgui.GetStyleColor(imgui.ImGuiCol.Text),
        muted_text = imgui.GetStyleColor(imgui.ImGuiCol.TextDisabled),
        panel_bg = imgui.GetStyleColor(imgui.ImGuiCol.ChildBg),
        frame_bg = imgui.GetStyleColor(imgui.ImGuiCol.FrameBg),
        frame_hover = imgui.GetStyleColor(imgui.ImGuiCol.FrameBgHovered),
        border = imgui.GetStyleColor(imgui.ImGuiCol.Border),
        accent = imgui.GetStyleColor(imgui.ImGuiCol.ButtonHovered),
        accent_soft = imgui.GetStyleColor(imgui.ImGuiCol.HeaderHovered),
        selection = imgui.GetStyleColor(imgui.ImGuiCol.HeaderActive),
    }
end

local function _draw_warning_banner(text, color)
    if not text or text == "" then
        return
    end
    imgui.PushStyleColor(imgui.ImGuiCol.ChildBg, color)
    imgui.BeginChild(string.format("ui_warning_%s", text), imgui.ImVec2(0, 42), imgui.ChildFlags.Borders)
        if imgui.PushTextWrapPos then
            imgui.PushTextWrapPos(0)
        end
        imgui.Text(text)
        if imgui.PopTextWrapPos then
            imgui.PopTextWrapPos()
        end
    imgui.EndChild()
    imgui.PopStyleColor()
end

_get_preview_state = function(document)
    local uid = _get_document_uid(document)
    local state = preview_state_by_guid[uid]
    if state then
        return state
    end

    state =
    {
        runtime = UIRuntime.new(nil,
        {
            allow_actions = false,
            preview_mode = true,
        }),
        instance = nil,
        document_revision = -1,
        style_dependency_key = "none",
        style_dependency_reference_key = nil,
        style_dependency_guid_list = nil,
        style_dependency_index_revision = -1,
        hovered_widget_id = nil,
        hovered_widget_type = nil,
        snap_guides = nil,
        show_safe_area = true,
        show_guides = true,
        background_color = imgui.ImColor(0, 0, 0, 255),
        pointer_down_last_frame = false,
        press_candidate_id = nil,
        press_from_preview = false,
        drag = nil,
        drag_did_move = false,
        view_zoom = 1.0,
        view_zoom_target = 1.0,
        view_pan_x = 0,
        view_pan_y = 0,
        view_pan_target_x = 0,
        view_pan_target_y = 0,
        view_pan_active = false,
        view_pan_button = nil,
        view_pan_start_mouse = nil,
        view_pan_start_x = 0,
        view_pan_start_y = 0,
        scroll_y_by_widget_id = {},
        request_focus_to_content = false,
    }
    preview_state_by_guid[uid] = state
    return state
end

local function _dispose_preview_state(uid)
    local state = preview_state_by_guid[uid]
    if not state then
        return
    end
    if state.runtime and state.runtime.destroy then
        state.runtime:destroy()
    end
    preview_state_by_guid[uid] = nil
end

local function _sync_preview_instance(document)
    local state = _get_preview_state(document)
    local revision = document.get_document_revision and document:get_document_revision() or 0
    local style_dependency_key = _get_preview_style_dependency_key(document, state)
    if state.instance == nil then
        state.instance = state.runtime:open_document(document:get_document_snapshot(),
        {
            instance_id = string.format("ui_designer_preview_%s", _get_document_uid(document)),
        })
        state.document_revision = revision
        state.style_dependency_key = style_dependency_key
        state.drag = nil
        return state
    end

    if state.document_revision ~= revision
        or state.style_dependency_key ~= style_dependency_key
    then
        state.instance = state.runtime:reload_instance(state.instance, document:get_document_snapshot()) or state.instance
        state.document_revision = revision
        state.style_dependency_key = style_dependency_key
        state.drag = nil
    end

    return state
end

local function _apply_preview_scroll_offsets(state)
    local instance = state and state.instance or nil
    if not instance or type(state.scroll_y_by_widget_id) ~= "table" then
        return
    end

    for widget_id, scroll_y in pairs(state.scroll_y_by_widget_id) do
        local widget = instance.widget_by_id and instance.widget_by_id[widget_id] or nil
        if widget and widget.type == "ScrollView" and type(widget.props) == "table" then
            widget.props.scroll_y = math.max(0, tonumber(scroll_y) or 0)
        else
            state.scroll_y_by_widget_id[widget_id] = nil
        end
    end
end

local function _clear_preview_scroll_offset(document, widget_id)
    local state = preview_state_by_guid[_get_document_uid(document)]
    if state and type(state.scroll_y_by_widget_id) == "table" then
        state.scroll_y_by_widget_id[widget_id] = nil
    end
end

local function _is_widget_descendant(document, widget_id, candidate_id)
    local widget = document:get_widget(widget_id)
    if not widget then
        return false
    end

    local found = false
    local function walk(node)
        if not node or found then
            return
        end
        if node.id == candidate_id then
            found = true
            return
        end
        for _, child in ipairs(node.children or {}) do
            walk(child)
        end
    end

    for _, child in ipairs(widget.children or {}) do
        walk(child)
    end
    return found
end

local function _get_widget_display_label(widget)
    local name = _trim(widget and widget.name) or (widget and widget.id) or "未命名组件"
    local type_id = widget and widget.type or "Unknown"
    local definition = UIWidgetRegistry.get(type_id)
    local type_label = definition and definition.display_name or type_id
    return string.format("%s [%s]", name, type_label)
end

local function _get_widget_tree_label(widget)
    return _trim(widget and widget.name) or (widget and widget.id) or "未命名组件"
end

local function _get_widget_tree_marker_color(widget)
    local type_id = tostring(widget and widget.type or "")
    return module.Config.widget_tree_marker_color_pool[type_id] or module.Config.widget_tree_marker_default_color
end

local function _get_widget_tree_marker_icon()
    local icon_id = module.Config.widget_tree_marker_icon_id or "radio-button-fill"
    local ok, icon = pcall(ResourcesManager.find_icon, icon_id)
    if ok then
        return icon
    end
    return nil
end

local function _get_widget_tree_marker_radius(row_height)
    local available_height = math.max(1, (tonumber(row_height) or imgui.GetTextLineHeight()) - 1)
    return math.max(module.Config.widget_tree_marker_min_radius, available_height * 0.5)
end

local function _get_widget_tree_marker_diameter()
    return _get_widget_tree_marker_radius(imgui.GetTextLineHeight()) * 2
end

local function _push_widget_tree_font(editor_zoom_ratio)
    if not GlobalContext.font_imgui then
        return false
    end

    local zoom = tonumber(editor_zoom_ratio) or 1
    local font_scale = tonumber(module.Config.widget_tree_font_scale) or 1.5
    local font_size = math.max(1, math.floor(18 * zoom * font_scale + 0.5))
    imgui.PushFont(GlobalContext.font_imgui, font_size)
    return true
end

local function _draw_widget_tree_rect_segment(draw_list, x1, y1, x2, y2, color, thickness)
    if not draw_list or not draw_list.AddRectFilled then
        return
    end

    local left = math.min(x1, x2)
    local right = math.max(x1, x2)
    local top = math.min(y1, y2)
    local bottom = math.max(y1, y2)
    local half_thickness = math.max(0.5, (tonumber(thickness) or 1) * 0.5)
    if right - left < half_thickness then
        left = left - half_thickness
        right = right + half_thickness
    end
    if bottom - top < half_thickness then
        top = top - half_thickness
        bottom = bottom + half_thickness
    end

    draw_list:AddRectFilled(
        imgui.ImVec2(left, top),
        imgui.ImVec2(right, bottom),
        color,
        0,
        nil)
end

local function _draw_widget_tree_marker_fallback(draw_list, center_x, center_y, radius, color)
    if not draw_list or not draw_list.AddRectFilled then
        return
    end

    local inset = math.max(1, radius * 0.22)
    local rounding = math.max(1, radius * 0.28)
    draw_list:AddRectFilled(
        imgui.ImVec2(center_x - radius + inset, center_y - radius + inset),
        imgui.ImVec2(center_x + radius - inset, center_y + radius - inset),
        color,
        rounding,
        nil)
end

local function _draw_widget_tree_connector(draw_list, parent_marker, child_marker)
    if not draw_list or not parent_marker or not child_marker then
        return
    end
    if parent_marker.has_children ~= true then
        return
    end

    local color = module.Config.widget_tree_connector_color
    local thickness = math.max(1, tonumber(module.Config.widget_tree_connector_thickness) or 1)
    local gap = math.max(0, tonumber(module.Config.widget_tree_connector_gap) or 0)
    local parent_right_x = tonumber(parent_marker.right_x)
        or ((tonumber(parent_marker.center_x) or 0) + (tonumber(parent_marker.radius) or 0))
    local parent_y = tonumber(parent_marker.center_y)
    local child_y = tonumber(child_marker.center_y)
    local child_left_x = tonumber(child_marker.left_x)
        or ((tonumber(child_marker.center_x) or 0) - (tonumber(child_marker.radius) or 0))
    child_left_x = child_left_x - gap
    local branch_start_x = parent_right_x + gap
    if not parent_y or not child_y or child_left_x <= branch_start_x then
        return
    end

    local branch_length = math.max(1, tonumber(module.Config.widget_tree_connector_branch_length) or 1)
    local branch_x = math.min(branch_start_x + branch_length, child_left_x)
    _draw_widget_tree_rect_segment(draw_list, branch_start_x, parent_y, branch_x, parent_y, color, thickness)
    if child_y ~= parent_y then
        _draw_widget_tree_rect_segment(draw_list, branch_x, parent_y, branch_x, child_y, color, thickness)
    end
    if child_left_x > branch_x then
        _draw_widget_tree_rect_segment(draw_list, branch_x, child_y, child_left_x, child_y, color, thickness)
    end
end

local function _find_duplicate_widget_name(document, widget)
    local name = _trim(widget and widget.name)
    if not document or not widget or not name then
        return nil
    end

    local snapshot = document._document or document:get_document_snapshot()
    local duplicate_widget = nil
    UI.walk_widgets(snapshot, function(candidate)
        if candidate and candidate.id ~= widget.id and _trim(candidate.name) == name then
            duplicate_widget = candidate
            return true
        end
        return false
    end)
    return duplicate_widget
end

local function _get_tree_node_label_spacing()
    if type(imgui.GetTreeNodeToLabelSpacing) == "function" then
        return imgui.GetTreeNodeToLabelSpacing()
    end

    local style = imgui.GetStyle()
    local inner_spacing = style and style.ItemInnerSpacing and tonumber(style.ItemInnerSpacing.x) or 4
    return imgui.GetTextLineHeight() + inner_spacing
end

local function _get_widget_tree_arrow_marker_gap()
    return math.max(0, tonumber(module.Config.widget_tree_arrow_marker_gap) or 0)
end

local function _measure_widget_tree_content_width(widget, depth)
    if not widget then
        return 0
    end

    local style = imgui.GetStyle()
    local label_width = imgui.CalcTextSize(_get_widget_tree_label(widget)).x
    local marker_width = _get_widget_tree_marker_diameter() + module.Config.widget_tree_marker_gap
    local arrow_width = _get_tree_node_label_spacing() + _get_widget_tree_arrow_marker_gap()
    local indent_width = (tonumber(depth) or 0) * style.IndentSpacing
    local width = indent_width + marker_width + arrow_width + label_width + style.WindowPadding.x * 2

    for _, child in ipairs(widget.children or {}) do
        width = math.max(width, _measure_widget_tree_content_width(child, (depth or 0) + 1))
    end
    return width
end

local function _can_widget_accept_children(widget)
    local definition = widget and UIWidgetRegistry.get(widget.type) or nil
    return widget ~= nil and (definition == nil or definition.can_have_children ~= false)
end

local function _get_widget_tree_drop_mode(widget, item_min, item_max)
    if widget and widget.id == "root" then
        return "child"
    end

    local height = math.max(1, item_max.y - item_min.y)
    local ratio = _clamp((imgui.GetMousePos().y - item_min.y) / height, 0, 1)
    if _can_widget_accept_children(widget) then
        local sibling_edge_ratio = 0.12
        if ratio < sibling_edge_ratio then
            return "before"
        end
        if ratio > 1 - sibling_edge_ratio then
            return "after"
        end
        return "child"
    end

    return ratio < 0.5 and "before" or "after"
end

local function _move_widget_by_tree_drop(document, source_id, target_id, mode)
    if not document or not source_id or source_id == "root" or not target_id or source_id == target_id then
        return false
    end

    local source, source_parent, source_index = document:get_widget(source_id)
    local target, target_parent, target_index = document:get_widget(target_id)
    if not source or not target or not source_parent or not source_index then
        return false
    end
    if _is_widget_descendant(document, source_id, target_id) then
        return false
    end

    local drop_mode = mode
    if drop_mode ~= "before" and drop_mode ~= "after" and drop_mode ~= "child" then
        drop_mode = "child"
    end
    local new_parent_id = nil
    local insert_index = nil

    if drop_mode == "child" and _can_widget_accept_children(target) then
        new_parent_id = target.id
        insert_index = #(target.children or {}) + 1
    else
        if target.id == "root" then
            new_parent_id = "root"
            insert_index = #(target.children or {}) + 1
        else
            new_parent_id = target_parent and target_parent.id or "root"
            insert_index = (target_index or 1) + (drop_mode == "before" and 0 or 1)
        end
    end

    if source_parent.id == new_parent_id and source_index < insert_index then
        insert_index = insert_index - 1
    end
    if source_parent.id == new_parent_id and source_index == insert_index then
        return false
    end

    local parent_changed = source_parent.id ~= new_parent_id
    local moved = document:move_widget(source_id, new_parent_id, insert_index)
    if moved then
        if parent_changed and _place_widget_in_parent_visible_area then
            _place_widget_in_parent_visible_area(document, source_id)
        end
        _set_selected_widget_id(document, source_id)
        return true
    end
    return false
end

local function _insert_widget(document, parent_id, widget, index)
    local snapshot = document:get_document_snapshot()
    local next_document, inserted_widget = UI.insert_widget(snapshot, parent_id, widget, index)
    if not next_document then
        return nil
    end
    if document:set_document_snapshot(next_document) then
        if _place_widget_in_parent_visible_area then
            _place_widget_in_parent_visible_area(document, inserted_widget.id)
        end
        return inserted_widget
    end
    return nil
end

local function _queue_create_widget_popup(document, parent_id, index)
    create_widget_request =
    {
        document_uid = _get_document_uid(document),
        parent_id = parent_id or "root",
        index = index,
    }
    pending_create_widget_popup = true
end

local function _copy_selected_widget(document)
    local selected_widget_id = _get_selected_widget_id(document)
    if selected_widget_id == "root" then
        return false
    end

    local widget = document:get_widget(selected_widget_id)
    if not widget then
        return false
    end

    widget_clipboard =
    {
        source_type = "ui_widget",
        widget = UI.clone(widget),
    }
    return true
end

local function _paste_widget_from_clipboard(document)
    if not widget_clipboard or widget_clipboard.source_type ~= "ui_widget" or not widget_clipboard.widget then
        return false
    end

    local selected_widget_id = _get_selected_widget_id(document)
    local selected_widget, selected_parent, selected_index = document:get_widget(selected_widget_id)
    if not selected_widget then
        return false
    end

    local definition = UIWidgetRegistry.get(selected_widget.type)
    local parent_id = selected_widget_id
    local insert_index = nil
    if definition and definition.can_have_children == false then
        parent_id = selected_parent and selected_parent.id or "root"
        insert_index = (selected_index or 0) + 1
    end

    local inserted_widget = _insert_widget(document, parent_id, widget_clipboard.widget, insert_index)
    if inserted_widget then
        _set_selected_widget_id(document, inserted_widget.id)
        return true
    end
    return false
end

local function _duplicate_selected_widget(document)
    local selected_widget_id = _get_selected_widget_id(document)
    if selected_widget_id == "root" then
        return false
    end

    local widget, parent, index = document:get_widget(selected_widget_id)
    if not widget or not parent then
        return false
    end

    local inserted_widget = _insert_widget(document, parent.id, widget, (index or 0) + 1)
    if inserted_widget then
        _set_selected_widget_id(document, inserted_widget.id)
        return true
    end
    return false
end

local function _delete_selected_widget(document)
    local selected_widget_id = _get_selected_widget_id(document)
    if selected_widget_id == "root" then
        return false
    end

    local _, parent = document:get_widget(selected_widget_id)
    local ok = document:delete_widget(selected_widget_id)
    if ok then
        _set_selected_widget_id(document, parent and parent.id or "root")
    end
    return ok
end

local function _get_widget_tree_context_popup_id(document)
    return string.format("ui_widget_tree_context_%s", _get_document_uid(document))
end

local function _open_widget_tree_context_menu(document, widget_id, select_widget)
    local uid = _get_document_uid(document)
    local target_id = widget_id or _get_selected_widget_id(document)
    if not document:get_widget(target_id) then
        target_id = _get_selected_widget_id(document)
    end
    if select_widget ~= false then
        _set_selected_widget_id(document, target_id)
    end
    tree_context_widget_by_guid[uid] = target_id
    pending_tree_context_popup_by_guid[uid] = true
end

local function _open_widget_tree_context_menu_if_released(document, widget_id, select_widget)
    if imgui.IsItemHovered() and imgui.IsMouseReleased(1) then
        _open_widget_tree_context_menu(document, widget_id, select_widget)
        return true
    end
    return false
end

local function _draw_widget_tree_context_menu(document)
    local document_uid = _get_document_uid(document)
    local popup_id = _get_widget_tree_context_popup_id(document)

    if not imgui.BeginPopup(popup_id) then
        return
    end

    local widget_id = tree_context_widget_by_guid[document_uid] or _get_selected_widget_id(document)
    local widget, parent, index = document:get_widget(widget_id)
    if not widget then
        widget_id = _get_selected_widget_id(document)
        widget, parent, index = document:get_widget(widget_id)
    end

    local definition = widget and UIWidgetRegistry.get(widget.type) or nil
    local can_add_child = widget ~= nil and definition ~= nil and definition.can_have_children ~= false
    local can_add_sibling = widget_id ~= "root"
    local can_copy = widget_id ~= "root"
    local can_paste = widget_clipboard ~= nil
    local can_delete = widget_id ~= "root"

    if imgui.MenuItem("新增子项", nil, false, can_add_child) then
        _set_selected_widget_id(document, widget_id)
        _queue_create_widget_popup(document, widget_id)
    end
    if imgui.MenuItem("新增同级", nil, false, can_add_sibling) then
        _set_selected_widget_id(document, widget_id)
        _queue_create_widget_popup(document, parent and parent.id or "root", (index or 0) + 1)
    end

    imgui.Separator()
    if imgui.MenuItem("复制", "Ctrl+C", false, can_copy) then
        _set_selected_widget_id(document, widget_id)
        _copy_selected_widget(document)
    end
    if imgui.MenuItem("粘贴", "Ctrl+V", false, can_paste) then
        _set_selected_widget_id(document, widget_id)
        _paste_widget_from_clipboard(document)
    end

    imgui.Separator()
    if imgui.MenuItem("删除", "Delete", false, can_delete) then
        _set_selected_widget_id(document, widget_id)
        _delete_selected_widget(document)
    end

    imgui.EndPopup()
end

local function _apply_canvas_preset(document, preset)
    if not preset then
        return false
    end
    return document:set_canvas_size(preset.width, preset.height)
end

local function _get_document_click_action(widget)
    local event_action = type(widget.events) == "table" and widget.events.on_click or nil
    event_action = type(event_action) == "table" and _clone_value(event_action) or {}
    local kind = _normalize_click_action_kind(event_action.kind)
    return
    {
        kind = kind,
        target = _trim(event_action.target) or "self",
        message = _trim(event_action.message) or "",
        event_name = _trim(event_action.event_name) or "",
        ui = _clone_value(event_action.ui),
        flow = _clone_value(event_action.flow),
        entry = _trim(event_action.entry) or "",
        instance_id = _trim(event_action.instance_id) or "",
        slot_id = _trim(event_action.slot_id) or "",
        save_category = _trim(event_action.save_category) or "manual",
        auto_advance_interval = _normalize_auto_advance_interval(event_action.auto_advance_interval),
        auto_close_current = event_action.auto_close_current == true,
        reentry_policy = _normalize_reentry_policy(event_action.reentry_policy),
    }
end

local function _set_document_click_action(document, widget_id, action)
    local kind = _normalize_click_action_kind(action.kind)
    local message = ""
    if kind == "return_value" then
        message = _trim(action.message) or ""
    end
    local reentry_policy = _normalize_reentry_policy(action.reentry_policy)
    local next_action =
    {
        kind = kind,
        target = _trim(action.target) or "self",
        message = message,
        event_name = "",
        ui = _clone_value(action.ui),
        flow = _clone_value(action.flow),
        entry = _trim(action.entry) or "",
        instance_id = _trim(action.instance_id) or "",
        slot_id = "",
        save_category = "manual",
        auto_advance_interval = kind == "auto_advance"
            and _normalize_auto_advance_interval(action.auto_advance_interval)
            or 1.0,
        auto_close_current = action.auto_close_current == true,
        reentry_policy = reentry_policy,
    }
    return document:set_widget_event(widget_id, "on_click", next_action)
end

local function _draw_text_editor(document, state_key, current_value, label, width, on_commit, flags, height, live_commit)
    local state = document:get_ui_state(state_key)
    state.widget = state.widget or util.CString(current_value or "")
    local committed_value = current_value or ""
    if state.active ~= true or state.committed_value ~= committed_value then
        state.widget:set(committed_value)
        state.committed_value = committed_value
    end

    if width and width > 0 then
        imgui.SetNextItemWidth(width)
    end
    if height and height > 0 then
        local input_size = imgui.ImVec2(width and width > 0 and width or -1, height)
        local interacted = imgui.InputTextMultiline(label, state.widget, input_size, flags or imgui.InputTextFlags.None)
        state.interacted = interacted == true
    else
        local interacted = imgui.InputText(label, state.widget, flags or imgui.InputTextFlags.None)
        state.interacted = interacted == true
    end
    local deactivated = imgui.IsItemDeactivatedAfterEdit()
    state.active = imgui.IsItemActive()
    if (live_commit == true and state.interacted == true) or deactivated then
        local next_value = state.widget:get()
        if next_value ~= (state.committed_value or "") then
            state.committed_value = next_value
            on_commit(next_value)
        end
    end
end

local function _draw_padding_editor(document, widget, property, width, label_text)
    local state = document:get_ui_state(string.format("ui_widget_%s_%s", widget.id, property.key))
    state.lt = state.lt or imgui.ImVec2(0, 0)
    state.rb = state.rb or imgui.ImVec2(0, 0)
    local current = _normalize_padding(widget.props and widget.props[property.key] or nil)
    local current_signature = string.format("%.3f|%.3f|%.3f|%.3f", current.left, current.top, current.right, current.bottom)
    if state.active ~= true or state.committed_value ~= current_signature then
        state.lt.x = current.left
        state.lt.y = current.top
        state.rb.x = current.right
        state.rb.y = current.bottom
        state.committed_value = current_signature
    end

    local control_start = imgui.GetCursorPos()
    local function draw_padding_row(row_label, value, key)
        local row_pos = imgui.GetCursorPos()
        imgui.SetCursorPos(imgui.ImVec2(control_start.x, row_pos.y))
        local changed = _draw_inspector_labeled_control(row_label, function(field_width)
            imgui.SetNextItemWidth(field_width)
            return imgui.InputFloat2(_make_inline_editor_label("", key), value, "%.1f", nil)
        end, 92)
        return changed == true
    end

    local commit = draw_padding_row("左/上", state.lt, string.format("%s_%s_lt", widget.id, property.key))
    commit = commit or imgui.IsItemDeactivatedAfterEdit()
    local active = imgui.IsItemActive()
    commit = draw_padding_row("右/下", state.rb, string.format("%s_%s_rb", widget.id, property.key)) or commit
    commit = commit or imgui.IsItemDeactivatedAfterEdit()
    active = active or imgui.IsItemActive()
    state.active = active
    if commit then
        document:set_widget_property(widget.id, property.key,
        {
            left = state.lt.x,
            top = state.lt.y,
            right = state.rb.x,
            bottom = state.rb.y,
        })
    end
end

local function _get_widget_property_editor_value(widget, property)
    if widget and type(widget.props) == "table" and widget.props[property.key] ~= nil then
        return widget.props[property.key]
    end
    return property.default
end

local function _draw_corner_radius_editor(document, widget, property, label_text)
    local min_value = math.floor(tonumber(property.min) or 0)
    local max_value = math.floor(tonumber(property.max) or 100)
    local step = math.max(0.1, tonumber(property.step) or 1)
    local current_value = _clamp(math.floor((tonumber(_get_widget_property_editor_value(widget, property)) or 0) + 0.5), min_value, max_value)
    local state = document:get_ui_state(string.format("ui_widget_%s_%s", widget.id, property.key))
    state.widget = state.widget or imgui.Int(current_value)
    if state.active ~= true or state.committed_value ~= current_value then
        state.widget.val = current_value
        state.committed_value = current_value
    end

    local changed = _draw_inspector_labeled_control(label_text, function(field_width)
        if field_width and field_width > 0 then
            imgui.SetNextItemWidth(field_width)
        end
        local flags = imgui.SliderFlags and imgui.SliderFlags.AlwaysClamp or nil
        if imgui.SliderInt then
            return imgui.SliderInt(
                _make_inline_editor_label("", string.format("ui_widget_%s_%s", widget.id, property.key)),
                state.widget,
                min_value,
                max_value,
                "%d",
                flags)
        end
        if imgui.DragInt then
            return imgui.DragInt(
                _make_inline_editor_label("", string.format("ui_widget_%s_%s", widget.id, property.key)),
                state.widget,
                step,
                min_value,
                max_value,
                "%d",
                flags)
        end
        return imgui.InputInt(
            _make_inline_editor_label("", string.format("ui_widget_%s_%s", widget.id, property.key)),
            state.widget,
            1,
            10,
            nil,
            flags)
    end)
    local deactivated = imgui.IsItemDeactivatedAfterEdit()
    state.active = imgui.IsItemActive()
    if changed or deactivated then
        local next_value = _clamp(math.floor((tonumber(state.widget.val) or 0) + 0.5), min_value, max_value)
        if state.widget.val ~= next_value then
            state.widget.val = next_value
        end
        if state.committed_value ~= next_value then
            state.committed_value = next_value
            document:set_widget_property(widget.id, property.key, next_value)
        end
    end
end

local function _draw_enum_editor(document, widget, property, label_text)
    local current_value = tostring(_get_widget_property_editor_value(widget, property) or "")
    if _draw_inspector_labeled_control(label_text or property.display_name, function(field_width)
        imgui.SetNextItemWidth(field_width)
        return imgui.BeginCombo(
            _make_inline_editor_label("", string.format("ui_widget_%s_%s", widget.id, property.key)),
            _get_property_enum_label(property.key, current_value),
            imgui.ComboFlags.HeightRegular)
    end) then
        for _, option in ipairs(property.option_list or {}) do
            local option_text = tostring(option)
            local option_label = _get_property_enum_label(property.key, option_text)
            if imgui.Selectable(string.format("%s##%s", option_label, option_text), option_text == current_value) then
                document:set_widget_property(widget.id, property.key, option_text)
            end
        end
        imgui.EndCombo()
    end
end

local function _draw_widget_property_editor(document, widget, property)
    local label_text = property.display_name
    if property.key == "corner_radius" then
        _draw_corner_radius_editor(document, widget, property, label_text)
        return
    end

    if property.type_id == "multiline" then
        local flags = imgui.InputTextFlags.AllowTabInput | imgui.InputTextFlags.NoHorizontalScroll
        _draw_inspector_labeled_control(label_text, function(field_width)
            _draw_text_editor(
                document,
                string.format("ui_widget_%s_%s", widget.id, property.key),
                _get_widget_property_editor_value(widget, property) or "",
                _make_inline_editor_label("", string.format("ui_widget_%s_%s", widget.id, property.key)),
                field_width,
                function(value)
                    document:set_widget_property(widget.id, property.key, value)
                end,
                flags,
                math.max(88, math.floor(imgui.GetTextLineHeightWithSpacing() * 4.5 + 0.5)),
                true)
        end)
        return
    end

    if property.type_id == "padding" then
        _draw_inspector_labeled_control(label_text, function(field_width)
            _draw_padding_editor(document, widget, property, field_width, "")
        end)
        return
    end

    if property.type_id == "enum" then
        _draw_enum_editor(document, widget, property, label_text)
        return
    end

    local adapter = _get_property_adapter(property)
    if not adapter then
        imgui.TextDisabled("当前属性暂不支持编辑")
        return
    end

    local min_field_width = property.type_id == "bool" and module.Config.inspector_bool_field_width or nil
    local changed, value = _draw_inspector_labeled_control(label_text, function(field_width)
        return adapter.draw_editor(
        {
            id = _make_inline_editor_label("", string.format("ui_widget_%s_%s", widget.id, property.key)),
            state = document:get_ui_state(string.format("ui_widget_%s_%s", widget.id, property.key)),
            label_text = nil,
            value = _get_widget_property_editor_value(widget, property),
            width = field_width,
            disabled = false,
            allow_clear = property.allow_clear == true,
            live_commit = true,
        })
    end, min_field_width)
    if changed then
        if property.key == "scroll_y" then
            _clear_preview_scroll_offset(document, widget.id)
        end
        document:set_widget_property(widget.id, property.key, value)
    end
end

local function _draw_click_action_editor(document, widget)
    local action = _get_document_click_action(widget)
    local reentry_policy_list = {"once", "repeatable"}
    local supports_auto_close = _supports_click_auto_close(action.kind)

    if _draw_inspector_labeled_control("点击动作", function(field_width)
        imgui.SetNextItemWidth(field_width)
        return imgui.BeginCombo(
            _make_inline_editor_label("", string.format("ui_widget_click_kind_%s", widget.id)),
            _get_click_action_label(action.kind),
            imgui.ComboFlags.HeightRegular)
    end) then
        for _, kind in ipairs(module.Config.click_action_kind_list) do
            if imgui.Selectable(string.format("%s##%s", _get_click_action_label(kind), kind), kind == action.kind) then
                action.kind = kind
                action.target = "self"
                if not _supports_click_auto_close(kind) then
                    action.auto_close_current = false
                end
                _set_document_click_action(document, widget.id, action)
            end
        end
        imgui.EndCombo()
    end

    if _draw_inspector_labeled_control("重复点击", function(field_width)
        imgui.SetNextItemWidth(field_width)
        return imgui.BeginCombo(
            _make_inline_editor_label("", string.format("ui_widget_click_reentry_%s", widget.id)),
            _get_reentry_policy_label(action.reentry_policy),
            imgui.ComboFlags.HeightRegular)
    end) then
        for _, policy in ipairs(reentry_policy_list) do
            if imgui.Selectable(string.format("%s##%s", _get_reentry_policy_label(policy), policy), policy == action.reentry_policy) then
                action.reentry_policy = policy
                _set_document_click_action(document, widget.id, action)
            end
        end
        imgui.EndCombo()
    end

    if action.kind == "auto_advance" then
        _draw_inspector_labeled_control("时间间隔", function(field_width)
            local state_key = string.format("ui_widget_click_auto_advance_interval_%s", widget.id)
            local state = document:get_ui_state(state_key)
            local current_value = _normalize_auto_advance_interval(action.auto_advance_interval)
            state.widget = state.widget or imgui.Float(current_value)
            if state.active ~= true or math.abs((state.committed_value or 0) - current_value) > 0.00001 then
                state.widget.val = current_value
                state.committed_value = current_value
            end

            imgui.SetNextItemWidth(field_width)
            local interacted = imgui.InputFloat(_make_inline_editor_label("", state_key), state.widget)
            local deactivated = imgui.IsItemDeactivatedAfterEdit()
            state.active = imgui.IsItemActive()
            if deactivated then
                local next_value = _normalize_auto_advance_interval(state.widget.val)
                if math.abs(next_value - (state.committed_value or 0)) > 0.00001 then
                    state.committed_value = next_value
                    action.auto_advance_interval = next_value
                    _set_document_click_action(document, widget.id, action)
                else
                    action.auto_advance_interval = next_value
                end
                state.widget.val = next_value
            end
        end)
    end

    if action.kind == "open_ui" then
        local changed_value, changed = nil, false
        _draw_inspector_labeled_control("目标界面", function(field_width)
            changed_value, changed = ResourceReferenceField.draw(
            {
                popup_id = string.format("ui_widget_click_ui_%s", widget.id),
                asset_type = "ui",
                value = action.ui,
                width = field_width,
                allow_clear = true,
            })
        end)
        if changed then
            action.ui = changed_value
            _set_document_click_action(document, widget.id, action)
        end

    elseif action.kind == "return_value" then
        _draw_inspector_labeled_control("返回结果", function(field_width)
            _draw_text_editor(
                document,
                string.format("ui_widget_click_return_value_%s", widget.id),
                action.message,
                string.format("##ui_widget_click_return_value_%s", widget.id),
                field_width,
                function(value)
                    action.message = _trim(value) or ""
                    _set_document_click_action(document, widget.id, action)
                end)
        end)
    end

    if action.kind ~= "return_value" then
        local auto_close_toggle = imgui.Bool(action.auto_close_current == true and supports_auto_close)
        imgui.BeginDisabled(not supports_auto_close)
            _draw_inspector_labeled_control("点击后关闭界面", function()
                if imgui.Checkbox(string.format("##ui_widget_click_auto_close_%s", widget.id), auto_close_toggle) then
                    action.auto_close_current = supports_auto_close and auto_close_toggle.val == true or false
                    _set_document_click_action(document, widget.id, action)
                end
            end, module.Config.inspector_bool_field_width)
        imgui.EndDisabled()
    end
end
local function _draw_widget_tree_node(document, widget, selected_widget_id, parent_marker)
    local definition = UIWidgetRegistry.get(widget.type)
    local has_children = #(widget.children or {}) > 0
    local is_leaf = definition and definition.can_have_children == false or not has_children
    local flags = imgui.TreeNodeFlags.OpenOnArrow | imgui.TreeNodeFlags.SpanFullWidth
    if is_leaf then
        flags = flags | imgui.TreeNodeFlags.Leaf | imgui.TreeNodeFlags.NoTreePushOnOpen
    else
        flags = flags | imgui.TreeNodeFlags.DefaultOpen
    end
    if widget.id == selected_widget_id then
        flags = flags | imgui.TreeNodeFlags.Selected
    end

    local line_start = imgui.GetCursorScreenPos()
    local opened = imgui.TreeNode(string.format("##ui_widget_tree_%s", widget.id), flags)
    local item_min = imgui.GetItemRectMin()
    local item_max = imgui.GetItemRectMax()
    local draw_list = imgui.GetWindowDrawList()
    local text_height = imgui.GetTextLineHeight()
    local row_height = math.max(text_height, (item_max and item_min) and (item_max.y - item_min.y) or text_height)
    local marker_radius = _get_widget_tree_marker_radius(row_height)
    local marker_diameter = marker_radius * 2
    local marker_x = line_start.x + _get_tree_node_label_spacing() + _get_widget_tree_arrow_marker_gap()
    local marker_center_y = item_min.y + row_height * 0.5
    local marker_center_x = marker_x + marker_radius
    local marker_info =
    {
        center_x = marker_center_x,
        center_y = marker_center_y,
        radius = marker_radius,
        left_x = marker_center_x - marker_radius,
        right_x = marker_center_x + marker_radius,
        has_children = has_children,
    }
    local label_y = item_min.y + math.max(0, (row_height - text_height) * 0.5)
    local label_x = marker_x + marker_diameter + module.Config.widget_tree_marker_gap
    if draw_list then
        _draw_widget_tree_connector(draw_list, parent_marker, marker_info)
        local marker_color = _get_widget_tree_marker_color(widget)
        local marker_icon = _get_widget_tree_marker_icon()
        if marker_icon and type(draw_list.AddImage) == "function" then
            draw_list:AddImage(
                marker_icon,
                imgui.ImVec2(marker_center_x - marker_radius, marker_center_y - marker_radius),
                imgui.ImVec2(marker_center_x + marker_radius, marker_center_y + marker_radius),
                nil,
                nil,
                marker_color)
        else
            _draw_widget_tree_marker_fallback(draw_list, marker_center_x, marker_center_y, marker_radius, marker_color)
        end
        draw_list:AddText(
            imgui.ImVec2(label_x, label_y),
            imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.Text)):to_u32(),
            _get_widget_tree_label(widget))
    end
    if imgui.IsItemClicked() then
        _set_selected_widget_id(document, widget.id)
    end
    _open_widget_tree_context_menu_if_released(document, widget.id)

    if widget.id ~= "root" and imgui.BeginDragDropSource(imgui.DragDropFlags.SourceNoHoldToOpenOthers) then
        imgui.SetDragDropPayload(module.Config.widget_tree_drag_payload_type,
        {
            document_uid = _get_document_uid(document),
            widget_id = widget.id,
        })
        imgui.Text(_get_widget_display_label(widget))
        imgui.EndDragDropSource()
    end

    if imgui.BeginDragDropTarget() then
        local payload = imgui.AcceptDragDropPayload(module.Config.widget_tree_drag_payload_type)
        if payload and payload.document_uid == _get_document_uid(document) and imgui.IsMouseReleased(0) then
            local drop_mode = _get_widget_tree_drop_mode(widget, item_min, item_max)
            _move_widget_by_tree_drop(document, payload.widget_id, widget.id, drop_mode)
        end
        imgui.EndDragDropTarget()
    end

    if opened and not is_leaf then
        for _, child in ipairs(widget.children or {}) do
            _draw_widget_tree_node(document, child, selected_widget_id, marker_info)
        end
        imgui.TreePop()
    end
end

local function _draw_create_widget_popup(document)
    if not create_widget_request or create_widget_request.document_uid ~= _get_document_uid(document) then
        return
    end

    local popup_style = nil
    if ImGUIHelper.ShouldUseInHThemeCompensation() then
        popup_style = ImGUIHelper.PushCompactPopupStyle(SettingsManager.get("editor_zoom_ratio"))
    end
    if not imgui.BeginPopup("ui_designer_create_widget_popup") then
        if popup_style then
            ImGUIHelper.PopCompactPopupStyle(popup_style)
        end
        return
    end

    local category_pool = {}
    local extra_category_list = {}
    for _, category in ipairs(module.Config.create_widget_category_order) do
        category_pool[category] = {}
    end
    for _, definition in ipairs(UIWidgetRegistry.list()) do
        if definition.type_id ~= "Canvas" and definition.hidden_from_create ~= true then
            local category = tostring(definition.category or "基础")
            if not category_pool[category] then
                category_pool[category] = {}
                extra_category_list[#extra_category_list + 1] = category
            end
            table.insert(category_pool[category], definition)
        end
    end

    local function create_widget(definition)
        local inserted_widget = document:create_widget(create_widget_request.parent_id, definition.type_id, create_widget_request.index)
        if inserted_widget then
            if _place_widget_in_parent_visible_area then
                _place_widget_in_parent_visible_area(document, inserted_widget.id)
            end
            _set_selected_widget_id(document, inserted_widget.id)
        end
        create_widget_request = nil
        imgui.CloseCurrentPopup()
    end

    local function draw_category(category)
        local definition_list = category_pool[category]
        if type(definition_list) ~= "table" or #definition_list == 0 then
            return false
        end
        local flags = imgui.TreeNodeFlags.SpanFullWidth | imgui.TreeNodeFlags.DefaultOpen
        local created = false
        if imgui.TreeNode(string.format("%s##ui_create_widget_category_%s", category, category), flags) then
            for _, definition in ipairs(definition_list) do
                if imgui.MenuItem(string.format("%s##ui_create_widget_%s", definition.display_name, definition.type_id)) then
                    create_widget(definition)
                    created = true
                    break
                end
            end
            imgui.TreePop()
        end
        return created
    end

    for _, category in ipairs(module.Config.create_widget_category_order) do
        if draw_category(category) then
            break
        end
    end
    if create_widget_request then
        for _, category in ipairs(extra_category_list) do
            if draw_category(category) then
                break
            end
        end
    end

    if imgui.IsKeyPressed(imgui.ImGuiKey.Escape, false) then
        create_widget_request = nil
        imgui.CloseCurrentPopup()
    end
    imgui.EndPopup()
    if popup_style then
        ImGUIHelper.PopCompactPopupStyle(popup_style)
    end
end

local function _draw_widget_tree_panel(document)
    local selected_widget_id = _get_selected_widget_id(document)
    local document_uid = _get_document_uid(document)

    imgui.SeparatorText("组件树")

    if pending_create_widget_popup and create_widget_request and create_widget_request.document_uid == document_uid then
        imgui.OpenPopup("ui_designer_create_widget_popup")
        pending_create_widget_popup = false
    end

    local tree_font_pushed = _push_widget_tree_font(SettingsManager.get("editor_zoom_ratio"))
    local root = document._document and document._document.root or nil
    local tree_content_width = root and _measure_widget_tree_content_width(root, 0) or 0
    if root then
        _draw_widget_tree_node(document, root, selected_widget_id, nil)
    else
        imgui.TextDisabled("当前界面没有可用的根画布。")
    end

    if tree_content_width > 0 then
        imgui.Dummy(imgui.ImVec2(math.max(1, tree_content_width), 1))
    end

    local blank_region = imgui.GetContentRegionAvail()
    if blank_region.y > 1 then
        imgui.InvisibleButton(
            string.format("##ui_widget_tree_blank_%s", document_uid),
            imgui.ImVec2(math.max(1, blank_region.x, tree_content_width), math.max(32, blank_region.y)))
        _open_widget_tree_context_menu_if_released(document, selected_widget_id, false)
    end
    if tree_font_pushed then
        imgui.PopFont()
    end

    if pending_tree_context_popup_by_guid[document_uid] then
        imgui.OpenPopup(_get_widget_tree_context_popup_id(document))
        pending_tree_context_popup_by_guid[document_uid] = nil
    end
    _draw_widget_tree_context_menu(document)
    _draw_create_widget_popup(document)
end

local function _draw_document_meta_panel(document)
    local snapshot = document._document or document:get_document_snapshot()

    local project_width, project_height = _get_project_canvas_size()
    local canvas_mode = tostring(snapshot.canvas and snapshot.canvas.mode or "fixed")

    if _draw_inspector_labeled_control("画布模式", function(field_width)
        imgui.SetNextItemWidth(field_width)
        return imgui.BeginCombo("##ui_canvas_mode", _get_canvas_mode_label(canvas_mode), imgui.ComboFlags.HeightRegular)
    end) then
        for _, item in ipairs(module.Config.canvas_mode_list) do
            if imgui.Selectable(item.label, item.id == canvas_mode) then
                document:set_canvas_mode(item.id)
            end
        end
        imgui.EndCombo()
    end
    if canvas_mode == "fixed" and (snapshot.canvas.width ~= project_width or snapshot.canvas.height ~= project_height) then
        imgui.TextColored(imgui.ImColor(255, 184, 64, 255).value, "提示：固定尺寸与项目尺寸不一致，运行时可能和当前项目分辨率不一致。")
    end

    local canvas_state = document:get_ui_state("ui_canvas_size")
    canvas_state.width = canvas_state.width or imgui.Int(snapshot.canvas.width)
    canvas_state.height = canvas_state.height or imgui.Int(snapshot.canvas.height)
    if not canvas_state.active or canvas_state.committed_width ~= snapshot.canvas.width or canvas_state.committed_height ~= snapshot.canvas.height then
        canvas_state.width.val = snapshot.canvas.width
        canvas_state.height.val = snapshot.canvas.height
        canvas_state.committed_width = snapshot.canvas.width
        canvas_state.committed_height = snapshot.canvas.height
    end

    local commit = false
    local active = false
    _draw_inspector_labeled_control("画布尺寸", function(field_width)
        local style = imgui.GetStyle()
        local spacing = style and style.ItemSpacing and style.ItemSpacing.x or 4
        local frame_padding_x = style and style.FramePadding and style.FramePadding.x or 4
        local preset_button_width = math.max(58, imgui.CalcTextSize("预设").x + frame_padding_x * 2 + 18)
        if field_width > 0 then
            preset_button_width = math.min(preset_button_width, math.max(44, field_width * 0.34))
        end
        local input_total_width = math.max(1, field_width - preset_button_width - spacing)
        local column_width = math.max(1, (input_total_width - spacing) * 0.5)
        local preset_popup_id = string.format("ui_canvas_preset_popup_%s", _get_document_uid(document))
        imgui.SetNextItemWidth(column_width)
        imgui.InputInt("##ui_canvas_width", canvas_state.width, 0, 0)
        commit = imgui.IsItemDeactivatedAfterEdit()
        active = imgui.IsItemActive()
        imgui.SameLine()
        imgui.SetNextItemWidth(column_width)
        imgui.InputInt("##ui_canvas_height", canvas_state.height, 0, 0)
        commit = commit or imgui.IsItemDeactivatedAfterEdit()
        active = active or imgui.IsItemActive()
        imgui.SameLine()
        if imgui.Button(string.format("预设##ui_canvas_preset_button_%s", _get_document_uid(document)), imgui.ImVec2(preset_button_width, 0)) then
            imgui.OpenPopup(preset_popup_id)
        end
        if imgui.BeginPopup(preset_popup_id) then
            for _, preset in ipairs(module.Config.canvas_preset_list) do
                local selected = preset.width == canvas_state.width.val and preset.height == canvas_state.height.val
                if imgui.Selectable(
                    string.format("%s##ui_canvas_preset_%d_%d", preset.name, preset.width, preset.height),
                    selected) then
                    canvas_state.width.val = preset.width
                    canvas_state.height.val = preset.height
                    _apply_canvas_preset(document, preset)
                    imgui.CloseCurrentPopup()
                end
            end
            imgui.EndPopup()
        end
    end)
    canvas_state.active = active
    if commit then
        document:set_canvas_size(canvas_state.width.val, canvas_state.height.val)
    end

end

local function _draw_widget_inspector_panel(document)
    local selected_widget_id = _get_selected_widget_id(document)
    local widget = document:get_widget(selected_widget_id)
    if not widget then
        imgui.TextDisabled("当前没有选中的组件。")
        return
    end

    local definition = UIWidgetRegistry.get(widget.type)
    imgui.SeparatorText("当前组件")

    _draw_inspector_labeled_control("名称", function(field_width)
        _draw_text_editor(
            document,
            string.format("ui_widget_name_%s", widget.id),
            widget.name or "",
            string.format("##ui_widget_name_%s", widget.id),
            field_width,
            function(value)
                local next_name = _trim(value) or widget.name or widget.id
                document:set_widget_name(widget.id, next_name)
            end,
            nil,
            nil,
            true)
    end)
    local duplicate_widget = _find_duplicate_widget_name(document, widget)
    if duplicate_widget then
        imgui.TextColored(
            imgui.ImColor(255, 190, 72, 255).value,
            string.format("名称重复：%s。界面逻辑按组件名称监听时可能无法区分。", tostring(widget.name or "")))
    end

    if widget.id == "root" then
        imgui.Separator()
        _draw_document_meta_panel(document)
    end

    if _draw_widget_position_panel then
        _draw_widget_position_panel(document, widget)
    end

    if widget.type == "Button" or widget.type == "Toggle" then
        imgui.Separator()
        _draw_click_action_editor(document, widget)
    end

    imgui.Separator()
    imgui.SeparatorText("属性")

    local visible_property_count = 0
    for _, property in ipairs(definition and definition.property_list or {}) do
        if not module.Config.hidden_property_pool[property.key]
            and not ((widget.id == "root" or widget.type == "Text" or widget.type == "SaveSlotGrid") and property.key == "corner_radius")
        then
            imgui.PushID(string.format("ui_widget_prop_%s_%s", widget.id, property.key))
                _draw_widget_property_editor(document, widget, property)
                if property.description and imgui.IsItemHovered() then
                    imgui.SetTooltip(property.description)
                end
            imgui.PopID()
            visible_property_count = visible_property_count + 1
        end
    end

    if visible_property_count == 0 then
        imgui.TextDisabled("当前组件没有可编辑的基础属性。")
    end
end

local function _push_preview_clip_rect(draw_list, rect)
    if not rect or rect.w <= 0 or rect.h <= 0 then
        return nil
    end

    local min_pos = imgui.ImVec2(rect.x, rect.y)
    local max_pos = imgui.ImVec2(rect.x + rect.w, rect.y + rect.h)
    if draw_list and draw_list.PushClipRect and draw_list.PopClipRect then
        draw_list:PushClipRect(min_pos, max_pos, true)
        return "draw_list"
    end
    if imgui.PushClipRect and imgui.PopClipRect then
        imgui.PushClipRect(min_pos, max_pos, true)
        return "imgui"
    end
    return nil
end

local function _pop_preview_clip_rect(draw_list, token)
    if token == "draw_list" then
        draw_list:PopClipRect()
    elseif token == "imgui" then
        imgui.PopClipRect()
    end
end

local function _get_preview_widget_screen_clip(widget, canvas_draw_rect, scale)
    local clip_rect = widget and widget.clip_rect or nil
    local rect = widget and widget.rect or nil
    if not clip_rect or not rect then
        return nil
    end
    if math.abs((clip_rect.x or 0) - (rect.x or 0)) < 0.001
        and math.abs((clip_rect.y or 0) - (rect.y or 0)) < 0.001
        and math.abs((clip_rect.w or 0) - (rect.w or 0)) < 0.001
        and math.abs((clip_rect.h or 0) - (rect.h or 0)) < 0.001
    then
        return nil
    end
    return _transform_rect(clip_rect, canvas_draw_rect, scale)
end

local function _clip_preview_screen_rect(rect, clip_rect)
    if not rect or rect.w <= 0 or rect.h <= 0 then
        return nil
    end
    if not clip_rect then
        return rect
    end

    local clipped = _rect_intersection(rect, clip_rect)
    if not clipped or clipped.w <= 0 or clipped.h <= 0 then
        return nil
    end
    return clipped
end

local function _draw_preview_rect_filled(draw_list, rect, color_u32, clip_rect, radius)
    local rounding = math.max(0, tonumber(radius) or 0)
    if rounding > 0 and clip_rect then
        local clipped = _clip_preview_screen_rect(rect, clip_rect)
        if not clipped then
            return
        end
        local clip_token = _push_preview_clip_rect(draw_list, clip_rect)
        if clip_token then
            draw_list:AddRectFilled(
                imgui.ImVec2(rect.x, rect.y),
                imgui.ImVec2(rect.x + rect.w, rect.y + rect.h),
                color_u32,
                rounding)
            _pop_preview_clip_rect(draw_list, clip_token)
            return
        end
    end

    local clipped = _clip_preview_screen_rect(rect, clip_rect)
    if not clipped then
        return
    end
    draw_list:AddRectFilled(
        imgui.ImVec2(clipped.x, clipped.y),
        imgui.ImVec2(clipped.x + clipped.w, clipped.y + clipped.h),
        color_u32,
        rounding)
end

local function _draw_preview_outline_clipped(draw_list, rect, color_u32, thickness, clip_rect, radius)
    local rounding = math.max(0, tonumber(radius) or 0)
    if rounding > 0 and draw_list and draw_list.AddRect then
        if clip_rect then
            local clipped = _clip_preview_screen_rect(rect, clip_rect)
            if not clipped then
                return
            end
            local clip_token = _push_preview_clip_rect(draw_list, clip_rect)
            if clip_token then
                draw_list:AddRect(
                    imgui.ImVec2(rect.x, rect.y),
                    imgui.ImVec2(rect.x + rect.w, rect.y + rect.h),
                    color_u32,
                    rounding,
                    nil,
                    math.max(1, thickness or 1))
                _pop_preview_clip_rect(draw_list, clip_token)
                return
            end
        else
            draw_list:AddRect(
                imgui.ImVec2(rect.x, rect.y),
                imgui.ImVec2(rect.x + rect.w, rect.y + rect.h),
                color_u32,
                rounding,
                nil,
                math.max(1, thickness or 1))
            return
        end
    end

    if not clip_rect then
        _draw_outline(draw_list, rect, color_u32, thickness)
        return
    end

    local line = math.max(1, thickness or 1)
    _draw_preview_rect_filled(draw_list, _make_rect(rect.x, rect.y, rect.w, line), color_u32, clip_rect)
    _draw_preview_rect_filled(draw_list, _make_rect(rect.x, rect.y + rect.h - line, rect.w, line), color_u32, clip_rect)
    _draw_preview_rect_filled(draw_list, _make_rect(rect.x, rect.y, line, rect.h), color_u32, clip_rect)
    _draw_preview_rect_filled(draw_list, _make_rect(rect.x + rect.w - line, rect.y, line, rect.h), color_u32, clip_rect)
end

local function _draw_preview_image_region(draw_list, texture, image_rect, region_rect, tint_color, alpha, clip_rect)
    if not texture or not image_rect or image_rect.w <= 0 or image_rect.h <= 0 or not region_rect or region_rect.w <= 0 or region_rect.h <= 0 then
        return
    end

    local clipped = _clip_preview_screen_rect(region_rect, clip_rect)
    if not clipped then
        return
    end

    local uv0 = imgui.ImVec2(
        _clamp((clipped.x - image_rect.x) / image_rect.w, 0, 1),
        _clamp((clipped.y - image_rect.y) / image_rect.h, 0, 1))
    local uv1 = imgui.ImVec2(
        _clamp((clipped.x + clipped.w - image_rect.x) / image_rect.w, 0, 1),
        _clamp((clipped.y + clipped.h - image_rect.y) / image_rect.h, 0, 1))

    draw_list:AddImage(
        texture,
        imgui.ImVec2(clipped.x, clipped.y),
        imgui.ImVec2(clipped.x + clipped.w, clipped.y + clipped.h),
        uv0,
        uv1,
        _to_u32(tint_color or {r = 1, g = 1, b = 1, a = 1}, alpha))
end

local function _draw_preview_image_rounded_sliced(draw_list, texture, rect, tint_color, alpha, clip_rect, radius)
    local rounding = math.min(math.max(0, tonumber(radius) or 0), rect.w * 0.5, rect.h * 0.5)
    if rounding <= 0.01 then
        _draw_preview_image_region(draw_list, texture, rect, rect, tint_color, alpha, clip_rect)
        return
    end

    local center_height = rect.h - rounding * 2
    if center_height > 0 then
        _draw_preview_image_region(
            draw_list,
            texture,
            rect,
            _make_rect(rect.x, rect.y + rounding, rect.w, center_height),
            tint_color,
            alpha,
            clip_rect)
    end

    local steps = math.max(24, math.min(256, math.ceil(rounding / 0.35)))
    local radius_sq = rounding * rounding
    for index = 1, steps do
        local band_y1 = rect.y + rounding * (index - 1) / steps
        local band_y2 = rect.y + rounding * index / steps
        local sample_from_top = (band_y1 + band_y2) * 0.5 - rect.y
        local dy = rounding - sample_from_top
        local inset = rounding - math.sqrt(math.max(0, radius_sq - dy * dy))
        local width = math.max(0, rect.w - inset * 2)
        if width > 0.01 then
            _draw_preview_image_region(
                draw_list,
                texture,
                rect,
                _make_rect(rect.x + inset, band_y1, width, band_y2 - band_y1),
                tint_color,
                alpha,
                clip_rect)
        end

        local bottom_y1 = rect.y + rect.h - rounding * index / steps
        local bottom_y2 = rect.y + rect.h - rounding * (index - 1) / steps
        local sample_from_bottom = rect.y + rect.h - (bottom_y1 + bottom_y2) * 0.5
        dy = rounding - sample_from_bottom
        inset = rounding - math.sqrt(math.max(0, radius_sq - dy * dy))
        width = math.max(0, rect.w - inset * 2)
        if width > 0.01 then
            _draw_preview_image_region(
                draw_list,
                texture,
                rect,
                _make_rect(rect.x + inset, bottom_y1, width, bottom_y2 - bottom_y1),
                tint_color,
                alpha,
                clip_rect)
        end
    end
end

local function _draw_preview_image_clipped(draw_list, texture, rect, tint_color, alpha, clip_rect, radius)
    if not texture or not rect or rect.w <= 0 or rect.h <= 0 then
        return
    end

    local rounding = math.max(0, tonumber(radius) or 0)
    if rounding > 0 and draw_list and draw_list.AddImageRounded then
        local color_u32 = _to_u32(tint_color or {r = 1, g = 1, b = 1, a = 1}, alpha)
        if clip_rect then
            local clipped = _clip_preview_screen_rect(rect, clip_rect)
            if not clipped then
                return
            end
            local clip_token = _push_preview_clip_rect(draw_list, clip_rect)
            if clip_token then
                draw_list:AddImageRounded(
                    texture,
                    imgui.ImVec2(rect.x, rect.y),
                    imgui.ImVec2(rect.x + rect.w, rect.y + rect.h),
                    nil,
                    nil,
                    color_u32,
                    rounding,
                    nil)
                _pop_preview_clip_rect(draw_list, clip_token)
                return
            end
        else
            draw_list:AddImageRounded(
                texture,
                imgui.ImVec2(rect.x, rect.y),
                imgui.ImVec2(rect.x + rect.w, rect.y + rect.h),
                nil,
                nil,
                color_u32,
                rounding,
                nil)
            return
        end
    end

    if rounding > 0 then
        _draw_preview_image_rounded_sliced(draw_list, texture, rect, tint_color, alpha, clip_rect, rounding)
    else
        _draw_preview_image_region(draw_list, texture, rect, rect, tint_color, alpha, clip_rect)
    end
end

local function _resolve_preview_save_grid_options(runtime, widget)
    local instance_options = widget and widget.instance and widget.instance.options or {}
    local mode = _trim(instance_options.save_panel_mode)
        or _trim(runtime and runtime.resolve_widget_prop and runtime:resolve_widget_prop(widget, "mode"))
        or "save"
    if mode ~= "save" and mode ~= "load" then
        mode = "save"
    end

    local profile_options = SaveSlotGridModel.get_profile_options()
    local total_pages = math.max(1, math.floor(tonumber(profile_options.page_count) or 1))
    local page = _clamp(
        math.max(1, math.floor(tonumber(instance_options.save_page) or 1)),
        1,
        total_pages)
    local per_page = math.max(1, math.floor(tonumber(profile_options.slots_per_page) or 1))
    return mode, page, per_page, total_pages
end

local function _set_preview_save_grid_page(runtime, widget, page)
    local _, _, _, total_pages = _resolve_preview_save_grid_options(runtime, widget)
    local next_page = _clamp(math.max(1, math.floor(tonumber(page) or 1)), 1, total_pages)
    if widget and widget.instance then
        widget.instance.options = widget.instance.options or {}
        widget.instance.options.save_page = next_page
    end
    return next_page
end

local function _get_preview_save_grid_header_layout(runtime, widget)
    local rect = widget and (widget.content_rect or widget.rect) or nil
    if not rect or rect.w <= 0 or rect.h <= 0 then
        return nil
    end

    local font_size = tonumber(runtime:resolve_widget_prop(widget, "font_size")) or 22
    local header_h = math.max(34, font_size + 14)
    if rect.h < header_h + 96 then
        return nil
    end

    local gap = math.min(10, math.max(0, tonumber(runtime:resolve_widget_prop(widget, "gap")) or 12))
    local button_w = math.max(44, math.floor(header_h * 1.35 + 0.5))
    local header_rect = _make_rect(rect.x, rect.y, rect.w, header_h)
    local prev_rect = _make_rect(rect.x, rect.y, button_w, header_h)
    local next_rect = _make_rect(rect.x + rect.w - button_w, rect.y, button_w, header_h)
    local label_rect = _make_rect(prev_rect.x + prev_rect.w + gap, rect.y, math.max(0, rect.w - button_w * 2 - gap * 2), header_h)
    local card_rect = _make_rect(rect.x, rect.y + header_h + gap, rect.w, math.max(0, rect.h - header_h - gap))
    return header_rect, prev_rect, next_rect, label_rect, card_rect
end

local function _hit_preview_save_grid_nav(runtime, widget, x, y)
    local _, prev_rect, next_rect = _get_preview_save_grid_header_layout(runtime, widget)
    if prev_rect and _rect_contains(prev_rect, x, y) then
        return "prev"
    end
    if next_rect and _rect_contains(next_rect, x, y) then
        return "next"
    end
    return nil
end

local function _ensure_preview_text_wrapper_keyed(widget, key, text, font_size, color, wrap_len)
    if not widget or not GlobalContext.font_wrapper_sdl or type(GlobalContext.font_wrapper_sdl.get) ~= "function" then
        return nil
    end

    widget.text_wrapper_pool = widget.text_wrapper_pool or {}
    widget._text_signature_pool = widget._text_signature_pool or {}
    local resolved_font_size = math.max(1, math.floor(tonumber(font_size) or 1))
    local normalized_color = _normalize_color(color, 1)
    local resolved_wrap_len = TextWrapper.normalize_wrap_len(wrap_len)
    local signature = table.concat(
    {
        "preview_save_grid",
        tostring(text or ""),
        tostring(GlobalContext.font_wrapper_sdl),
        tostring(resolved_font_size),
        tostring(TextWrapper.get_wrap_signature_value(resolved_wrap_len)),
        tostring(normalized_color.r),
        tostring(normalized_color.g),
        tostring(normalized_color.b),
        tostring(normalized_color.a),
    }, "|")

    if widget._text_signature_pool[key] ~= signature then
        local old_wrapper = widget.text_wrapper_pool[key]
        if old_wrapper and old_wrapper.dispose then
            old_wrapper:dispose()
        end
        widget.text_wrapper_pool[key] = TextWrapper.new(
            GlobalContext.font_wrapper_sdl,
            tostring(text or ""),
            normalized_color,
            resolved_wrap_len,
            resolved_font_size)
        widget._text_signature_pool[key] = signature
    end

    return widget.text_wrapper_pool[key]
end

local function _draw_preview_text_keyed(draw_list, widget, key, text, rect, font_size, color, alpha, align_x, align_y, canvas_draw_rect, scale, clip_rect)
    if not draw_list or not rect or rect.w <= 0 or rect.h <= 0 then
        return
    end

    local wrapper = _ensure_preview_text_wrapper_keyed(
        widget,
        key,
        text,
        font_size,
        color,
        math.max(1, math.floor(rect.w + 0.5)))
    if not wrapper or not wrapper.preview_texture then
        return
    end

    local x = rect.x
    local y = rect.y
    if align_x == "center" then
        x = rect.x + (rect.w - wrapper.w) * 0.5
    elseif align_x == "end" then
        x = rect.x + rect.w - wrapper.w
    end
    if align_y == "center" then
        y = rect.y + (rect.h - wrapper.h) * 0.5
    elseif align_y == "end" then
        y = rect.y + rect.h - wrapper.h
    end

    local draw_rect = _transform_rect(_make_rect(x, y, wrapper.w, wrapper.h), canvas_draw_rect, scale)
    local text_clip = _transform_rect(rect, canvas_draw_rect, scale)
    if clip_rect then
        text_clip = _rect_intersection(text_clip, clip_rect)
    end
    _draw_preview_image_clipped(
        draw_list,
        wrapper.preview_texture,
        draw_rect,
        {r = 1, g = 1, b = 1, a = 1},
        alpha,
        text_clip,
        0)
end

local function _draw_preview_save_slot_grid(draw_list, runtime, widget, canvas_draw_rect, scale, alpha, clip_rect)
    if not draw_list or not runtime or not widget then
        return
    end

    local mode, page, per_page, total_pages = _resolve_preview_save_grid_options(runtime, widget)
    local entries = {}
    local ok_entries, result = pcall(function()
        return SaveSlotGridModel.list_page(page, per_page)
    end)
    if ok_entries and type(result) == "table" then
        entries = result
    end

    local font_size = tonumber(runtime:resolve_widget_prop(widget, "font_size")) or 22
    local text_color = _normalize_color(runtime:resolve_widget_prop(widget, "text_color"), 1)
    local muted_color = _normalize_color(runtime:resolve_widget_prop(widget, "muted_text_color"), 1)
    local bg_color = _normalize_color(runtime:resolve_widget_prop(widget, "background_color"), 1)
    local hover_color = _normalize_color(runtime:resolve_widget_prop(widget, "hover_color"), 1)
    local nav_background_color = _normalize_color(runtime:resolve_widget_prop(widget, "disabled_color"), 1)
    local border_color = _normalize_color(runtime:resolve_widget_prop(widget, "border_color"), 1)
    local border_thickness = tonumber(runtime:resolve_widget_prop(widget, "border_thickness")) or 0
    local gap = math.max(0, tonumber(runtime:resolve_widget_prop(widget, "gap")) or 12)
    local source_rect = widget.content_rect or widget.rect
    if not source_rect or source_rect.w <= 0 or source_rect.h <= 0 then
        return
    end

    local card_area = source_rect
    local pointer_x = widget.hovered and tonumber(widget._last_pointer_x) or nil
    local pointer_y = widget.hovered and tonumber(widget._last_pointer_y) or nil
    local hovered_nav = pointer_x and pointer_y and _hit_preview_save_grid_nav(runtime, widget, pointer_x, pointer_y) or nil
    local _, prev_rect, next_rect, label_rect, header_card_area = _get_preview_save_grid_header_layout(runtime, widget)
    if header_card_area then

        local function draw_nav_button(button_rect, text, enabled)
            local screen_rect = _transform_rect(button_rect, canvas_draw_rect, scale)
            local nav_key = text == "<" and "prev" or "next"
            local fill = enabled and hovered_nav == nav_key and hover_color or nav_background_color
            _draw_preview_rect_filled(draw_list, screen_rect, _to_u32(fill, alpha), clip_rect, 0)
            if border_thickness > 0 and border_color.a > 0.001 then
                _draw_preview_outline_clipped(draw_list, screen_rect, _to_u32(border_color, alpha), math.max(1, border_thickness * scale), clip_rect, 0)
            end
            _draw_preview_text_keyed(
                draw_list,
                widget,
                string.format("save_grid_nav_%s", text),
                text,
                button_rect,
                math.max(18, font_size),
                enabled and text_color or muted_color,
                alpha,
                "center",
                "center",
                canvas_draw_rect,
                scale,
                clip_rect)
        end

        local function draw_page_label(label_doc_rect, text)
            _draw_preview_text_keyed(
                draw_list,
                widget,
                "save_grid_nav_label",
                text,
                label_doc_rect,
                math.max(16, font_size - 1),
                text_color,
                alpha,
                "center",
                "center",
                canvas_draw_rect,
                scale,
                clip_rect)
        end

        draw_nav_button(prev_rect, "<", page > 1)
        draw_nav_button(next_rect, ">", page < total_pages)
        local page_text = total_pages > 1
            and string.format("%d/%d", page, total_pages)
            or tostring(page)
        draw_page_label(label_rect, page_text)

        card_area = header_card_area
    end

    local columns = math.min(2, per_page)
    local rows = math.max(1, math.ceil(per_page / columns))
    local card_w = (card_area.w - gap * (columns - 1)) / columns
    local card_h = (card_area.h - gap * (rows - 1)) / rows
    local title_font_size = math.max(14, font_size)
    local time_font_size = math.max(12, font_size - 4)

    for index = 1, per_page do
        local entry = entries[index] or {empty = true, category = "manual"}
        local is_empty = type(entry) ~= "table" or entry.empty == true
        local disabled = mode == "load" and is_empty
        local zero_index = index - 1
        local col = zero_index % columns
        local row = math.floor(zero_index / columns)
        local card_doc_rect = _make_rect(
            card_area.x + col * (card_w + gap),
            card_area.y + row * (card_h + gap),
            card_w,
            card_h)
        local card_rect = _transform_rect(card_doc_rect, canvas_draw_rect, scale)
        local hovered_card = pointer_x and pointer_y and _rect_contains(card_doc_rect, pointer_x, pointer_y)
        local fill = disabled and bg_color or (hovered_card and hover_color or bg_color)
        _draw_preview_rect_filled(draw_list, card_rect, _to_u32(fill, alpha), clip_rect, 0)
        if border_thickness > 0 and border_color.a > 0.001 then
            _draw_preview_outline_clipped(draw_list, card_rect, _to_u32(border_color, alpha), math.max(1, border_thickness * scale), clip_rect, 0)
        end

        local inset = math.max(8, math.floor(card_doc_rect.h * 0.06 + 0.5))
        local thumbnail_doc_area = _make_rect(
            card_doc_rect.x + inset,
            card_doc_rect.y + inset,
            math.max(0, card_doc_rect.w * 0.38),
            math.max(0, card_doc_rect.h - inset * 2))
        local text_doc_rect = _make_rect(
            thumbnail_doc_area.x + thumbnail_doc_area.w + inset,
            card_doc_rect.y + inset,
            math.max(0, card_doc_rect.x + card_doc_rect.w - thumbnail_doc_area.x - thumbnail_doc_area.w - inset * 2),
            math.max(0, card_doc_rect.h - inset * 2))
        local thumbnail_area = _transform_rect(thumbnail_doc_area, canvas_draw_rect, scale)
        local thumbnail_content_rect = SaveSlotGridModel.fit_16_9_rect(thumbnail_area) or thumbnail_area
        local view = SaveSlotGridModel.build_slot_view(entry, {page = page, index = index})

        _draw_preview_rect_filled(draw_list, thumbnail_area, _to_u32({r = 0, g = 0, b = 0, a = 1}, alpha), clip_rect, 0)
        if not is_empty and view.thumbnail_path then
            local texture = nil
            local ok_texture, loaded_texture = pcall(SaveThumbnailCache.get_sdl_texture, view.thumbnail_path)
            if ok_texture then
                texture = loaded_texture
            end
            if texture then
                local texture_width, texture_height = _get_sdl_texture_size(texture)
                local image_rect = SaveSlotGridModel.fit_rect_preserve_aspect(thumbnail_content_rect, texture_width, texture_height) or thumbnail_content_rect
                _draw_preview_image_clipped(draw_list, texture, image_rect, nil, alpha, clip_rect, 0)
            end
        end

        if is_empty then
            _draw_preview_text_keyed(
                draw_list,
                widget,
                string.format("save_grid_empty_%d", index),
                view.title,
                text_doc_rect,
                math.max(14, font_size - 2),
                muted_color,
                alpha,
                "center",
                "center",
                canvas_draw_rect,
                scale,
                clip_rect)
        else
            _draw_preview_text_keyed(
                draw_list,
                widget,
                string.format("save_grid_title_%d", index),
                view.title,
                _make_rect(text_doc_rect.x, text_doc_rect.y, text_doc_rect.w, math.min(text_doc_rect.h, title_font_size + 8)),
                title_font_size,
                disabled and muted_color or text_color,
                alpha,
                "start",
                "start",
                canvas_draw_rect,
                scale,
                clip_rect)
            _draw_preview_text_keyed(
                draw_list,
                widget,
                string.format("save_grid_time_%d", index),
                view.time_text,
                _make_rect(text_doc_rect.x, text_doc_rect.y + title_font_size + 12, text_doc_rect.w, math.max(0, text_doc_rect.h - title_font_size - 12)),
                time_font_size,
                muted_color,
                alpha,
                "start",
                "start",
                canvas_draw_rect,
                scale,
                clip_rect)
        end
    end
end

local function _get_preview_corner_radius(runtime, widget, rect)
    if not runtime or not widget or widget.type == "Canvas" or widget.type == "Text" or widget.type == "SaveSlotGrid" or not rect then
        return 0
    end
    local percent = _clamp(tonumber(runtime:resolve_widget_prop(widget, "corner_radius")) or 0, 0, 100)
    if percent <= 0 or rect.w <= 0 or rect.h <= 0 then
        return 0
    end
    return math.min(rect.w, rect.h) * 0.5 * percent / 100
end

local function _draw_preview_widget(draw_list, runtime, widget, canvas_draw_rect, scale, alpha, clip_rect)
    if not widget or not widget.visible then
        return
    end

    local rect = _transform_rect(widget.rect, canvas_draw_rect, scale)
    local opacity = math.max(0, math.min(1, tonumber(runtime:resolve_widget_prop(widget, "opacity")) or 1))
    local final_alpha = (alpha or 1) * opacity
    local corner_radius = _get_preview_corner_radius(runtime, widget, rect)

    local function draw_rect_filled(target_rect, color_u32, radius)
        _draw_preview_rect_filled(draw_list, target_rect, color_u32, clip_rect, radius or 0)
    end

    local function draw_outline(target_rect, color_u32, thickness, radius)
        _draw_preview_outline_clipped(draw_list, target_rect, color_u32, thickness, clip_rect, radius or 0)
    end

    local function draw_image(texture, source_rect, tint_color, radius)
        _draw_preview_image_clipped(draw_list, texture, source_rect, tint_color, final_alpha, clip_rect, radius or 0)
    end

    if widget.type == "Canvas" or widget.type == "Panel" then
        local background_color = _normalize_color(runtime:resolve_widget_prop(widget, "background_color"), 0)
        if background_color.a > 0.001 then
            draw_rect_filled(rect, _to_u32(background_color, final_alpha), corner_radius)
        end

        local border_thickness = tonumber(runtime:resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(runtime:resolve_widget_prop(widget, "border_color"), 0)
        if border_thickness > 0 and border_color.a > 0.001 then
            draw_outline(rect, _to_u32(border_color, final_alpha), math.max(1, border_thickness * scale), corner_radius)
        end
    elseif widget.type == "Image" then
        local texture = ResourcesManager.find_sdl_texture(runtime:resolve_widget_prop(widget, "texture"))
        if texture then
            local draw_rect = _clone_value(rect)
            local texture_width, texture_height = _get_sdl_texture_size(texture)
            if _get_runtime_image_fit_mode(runtime, widget) == "preserve_aspect" and texture_width > 0 and texture_height > 0 then
                local draw_scale = math.min(draw_rect.w / texture_width, draw_rect.h / texture_height)
                local draw_width = texture_width * draw_scale
                local draw_height = texture_height * draw_scale
                draw_rect.x = draw_rect.x + (draw_rect.w - draw_width) * 0.5
                draw_rect.y = draw_rect.y + (draw_rect.h - draw_height) * 0.5
                draw_rect.w = draw_width
                draw_rect.h = draw_height
            end
            draw_image(texture, draw_rect, nil, _get_preview_corner_radius(runtime, widget, draw_rect))
        end
    elseif widget.type == "Text" then
        local wrapper = widget.text_wrapper
        if wrapper and wrapper.preview_texture then
            local draw_x = widget.content_rect.x
            local draw_y = widget.content_rect.y
            local align_x = tostring(runtime:resolve_widget_prop(widget, "align_x") or "start")
            local align_y = tostring(runtime:resolve_widget_prop(widget, "align_y") or "start")
            if align_x == "center" then
                draw_x = widget.content_rect.x + (widget.content_rect.w - wrapper.w) * 0.5
            elseif align_x == "end" then
                draw_x = widget.content_rect.x + widget.content_rect.w - wrapper.w
            end
            if align_y == "center" then
                draw_y = widget.content_rect.y + (widget.content_rect.h - wrapper.h) * 0.5
            elseif align_y == "end" then
                draw_y = widget.content_rect.y + widget.content_rect.h - wrapper.h
            end
            draw_image(
                wrapper.preview_texture,
                _transform_rect(_make_rect(draw_x, draw_y, wrapper.w, wrapper.h), canvas_draw_rect, scale),
                _normalize_color(runtime:resolve_widget_prop(widget, "text_color"), 1))
        end
    elseif widget.type == "SaveSlotGrid" then
        _draw_preview_save_slot_grid(draw_list, runtime, widget, canvas_draw_rect, scale, final_alpha, clip_rect)
    elseif widget.type == "Button" then
        local background_color = runtime:resolve_widget_prop(widget, "background_color")
        if widget.pressed then
            background_color = runtime:resolve_widget_prop(widget, "pressed_color")
        elseif widget.hovered then
            background_color = runtime:resolve_widget_prop(widget, "hover_color")
        end
        draw_rect_filled(rect, _to_u32(_normalize_color(background_color, 1), final_alpha), corner_radius)

        local border_thickness = tonumber(runtime:resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(runtime:resolve_widget_prop(widget, "border_color"), 1)
        if border_thickness > 0 and border_color.a > 0.001 then
            draw_outline(rect, _to_u32(border_color, final_alpha), math.max(1, border_thickness * scale), corner_radius)
        end

        local wrapper = widget.text_wrapper
        if wrapper and wrapper.preview_texture then
            local padding = _normalize_padding(runtime:resolve_widget_prop(widget, "padding"))
            local text_rect = _inset_rect(widget.rect, padding.left, padding.top, padding.right, padding.bottom)
            local draw_x = text_rect.x + (text_rect.w - wrapper.w) * 0.5
            local draw_y = text_rect.y + (text_rect.h - wrapper.h) * 0.5
            draw_image(
                wrapper.preview_texture,
                _transform_rect(_make_rect(draw_x, draw_y, wrapper.w, wrapper.h), canvas_draw_rect, scale),
                _normalize_color(runtime:resolve_widget_prop(widget, "text_color"), 1))
        end
    elseif widget.type == "Toggle" then
        local is_checked = runtime:resolve_widget_prop(widget, "value") == true
        local background_color = is_checked and runtime:resolve_widget_prop(widget, "checked_color") or runtime:resolve_widget_prop(widget, "background_color")
        if widget.hovered then
            background_color = runtime:resolve_widget_prop(widget, "hover_color")
        end
        draw_rect_filled(rect, _to_u32(_normalize_color(background_color, 1), final_alpha), corner_radius)

        local border_thickness = tonumber(runtime:resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(runtime:resolve_widget_prop(widget, "border_color"), 1)
        if border_thickness > 0 and border_color.a > 0.001 then
            draw_outline(rect, _to_u32(border_color, final_alpha), math.max(1, border_thickness * scale), corner_radius)
        end

        local padding = _normalize_padding(runtime:resolve_widget_prop(widget, "padding"))
        local wrapper = widget.text_wrapper
        if wrapper and wrapper.preview_texture then
            local text_rect = _inset_rect(widget.rect, padding.left, padding.top, padding.right, padding.bottom)
            local draw_x = text_rect.x + (text_rect.w - wrapper.w) * 0.5
            local draw_y = text_rect.y + (text_rect.h - wrapper.h) * 0.5
            draw_image(
                wrapper.preview_texture,
                _transform_rect(_make_rect(draw_x, draw_y, wrapper.w, wrapper.h), canvas_draw_rect, scale),
                _normalize_color(runtime:resolve_widget_prop(widget, "text_color"), 1))
        end
    elseif widget.type == "ProgressBar" then
        local min_value = tonumber(runtime:resolve_widget_prop(widget, "min_value")) or 0
        local max_value = tonumber(runtime:resolve_widget_prop(widget, "max_value")) or 1
        local raw_value = tonumber(runtime:resolve_widget_prop(widget, "value")) or min_value
        local ratio = max_value ~= min_value and math.max(0, math.min(1, (raw_value - min_value) / (max_value - min_value))) or 0
        draw_rect_filled(rect, _to_u32(_normalize_color(runtime:resolve_widget_prop(widget, "background_color"), 1), final_alpha), corner_radius)
        local padding = _normalize_padding(runtime:resolve_widget_prop(widget, "padding"))
        local fill_rect = _inset_rect(widget.rect, padding.left, padding.top, padding.right, padding.bottom)
        fill_rect.w = fill_rect.w * ratio
        local fill_screen = _transform_rect(fill_rect, canvas_draw_rect, scale)
        draw_rect_filled(fill_screen, _to_u32(_normalize_color(runtime:resolve_widget_prop(widget, "fill_color"), 1), final_alpha), _get_preview_corner_radius(runtime, widget, fill_screen))
        local border_thickness = tonumber(runtime:resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(runtime:resolve_widget_prop(widget, "border_color"), 1)
        if border_thickness > 0 and border_color.a > 0.001 then
            draw_outline(rect, _to_u32(border_color, final_alpha), math.max(1, border_thickness * scale), corner_radius)
        end
        local wrapper = widget.text_wrapper
        if _runtime_should_show_progress(runtime, widget) and wrapper and wrapper.preview_texture then
            draw_image(
                wrapper.preview_texture,
                _transform_rect(_make_rect(widget.rect.x + (widget.rect.w - wrapper.w) * 0.5, widget.rect.y + (widget.rect.h - wrapper.h) * 0.5, wrapper.w, wrapper.h), canvas_draw_rect, scale),
                _normalize_color(runtime:resolve_widget_prop(widget, "text_color"), 1))
        end
    elseif widget.type == "Spacer" or widget.type == "VerticalContainer" or widget.type == "HorizontalContainer" or widget.type == "OverlayContainer" or widget.type == "ScrollView" or widget.type == "GridContainer" then
        local background_color = _normalize_color(runtime:resolve_widget_prop(widget, "background_color"), 0)
        if background_color.a > 0.001 then
            draw_rect_filled(rect, _to_u32(background_color, final_alpha), corner_radius)
        end

        local border_thickness = tonumber(runtime:resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(runtime:resolve_widget_prop(widget, "border_color"), 0)
        if border_thickness > 0 and border_color.a > 0.001 then
            draw_outline(rect, _to_u32(border_color, final_alpha), math.max(1, border_thickness * scale), corner_radius)
        end
    end

    if widget.type == "ScrollView" then
        local child_clip = _rect_intersection(widget.clip_rect, widget.content_rect)
        local screen_child_clip = child_clip and _transform_rect(child_clip, canvas_draw_rect, scale) or nil
        if clip_rect then
            screen_child_clip = _rect_intersection(clip_rect, screen_child_clip)
        end
        local clip_token = _push_preview_clip_rect(draw_list, screen_child_clip)
        for _, child in ipairs(widget.children or {}) do
            _draw_preview_widget(draw_list, runtime, child, canvas_draw_rect, scale, final_alpha, screen_child_clip)
        end
        _pop_preview_clip_rect(draw_list, clip_token)
        return
    end

    for _, child in ipairs(widget.children or {}) do
        _draw_preview_widget(draw_list, runtime, child, canvas_draw_rect, scale, final_alpha, clip_rect)
    end
end

local function _to_document_offset(widget, offset)
    local layout_scale = widget and widget.instance and widget.instance._responsive_layout_scale or nil
    if type(layout_scale) ~= "table" then
        return offset
    end
    return
    {
        x = (tonumber(offset and offset.x) or 0) / math.max(0.001, tonumber(layout_scale.x) or 1),
        y = (tonumber(offset and offset.y) or 0) / math.max(0.001, tonumber(layout_scale.y) or 1),
    }
end

local function _get_inspector_runtime_widget(document, widget_id)
    local preview_state = _sync_preview_instance(document)
    local runtime = preview_state and preview_state.runtime or nil
    local instance = preview_state and preview_state.instance or nil
    if not runtime or not instance then
        return nil
    end

    local snapshot = document._document or document:get_document_snapshot()
    local canvas_width, canvas_height = _resolve_document_canvas_size(snapshot)
    if runtime.set_canvas_size_override then
        runtime:set_canvas_size_override(canvas_width, canvas_height)
    end
    _apply_preview_scroll_offsets(preview_state)
    if runtime._update_layout then
        runtime:_update_layout()
    elseif runtime.update then
        runtime:update(0)
    end
    return instance.widget_by_id and instance.widget_by_id[widget_id] or nil, canvas_width, canvas_height
end

local function _set_widget_rect_from_runtime(document, widget_runtime, parent_content_rect, next_rect)
    if not document or not widget_runtime or not parent_content_rect or not next_rect then
        return false
    end

    local anchor_min = _normalize_vec2(widget_runtime.props and widget_runtime.props.anchor_min, 0, 0)
    local anchor_max = _normalize_vec2(widget_runtime.props and widget_runtime.props.anchor_max, 0, 0)
    local offset_min, offset_max = _rect_to_offsets(next_rect, parent_content_rect, anchor_min, anchor_max)
    offset_min = _to_document_offset(widget_runtime, offset_min)
    offset_max = _to_document_offset(widget_runtime, offset_max)

    local snapshot = document:get_document_snapshot()
    local widget = UI.find_widget(snapshot, widget_runtime.id)
    if not widget then
        return false
    end

    widget.props = widget.props or {}
    widget.props.offset_min = _clone_value(offset_min)
    widget.props.offset_max = _clone_value(offset_max)
    return document:set_document_snapshot(snapshot)
end

_place_widget_in_parent_visible_area = function(document, widget_id)
    if not document or not widget_id then
        return false
    end

    local widget, parent = document:get_widget(widget_id)
    if not widget or not parent or parent.type ~= "ScrollView" then
        return false
    end

    local widget_runtime, canvas_width, canvas_height = _get_inspector_runtime_widget(document, widget_id)
    if not widget_runtime or not widget_runtime.rect or not widget_runtime.parent or widget_runtime.parent.type ~= "ScrollView" then
        return false
    end

    local parent_content_rect = _get_widget_parent_content_rect(widget_runtime, canvas_width, canvas_height)
    local parent_runtime = widget_runtime.parent
    local next_rect = _copy_rect(widget_runtime.rect)
    next_rect.x = parent_runtime.content_rect.x
    next_rect.y = parent_runtime.content_rect.y
    return _set_widget_rect_from_runtime(document, widget_runtime, parent_content_rect, next_rect)
end

local function _draw_position_vec2_editor(document, state_key, label_text, x, y, on_commit)
    local state = document:get_ui_state(state_key)
    state.value = state.value or imgui.ImVec2(0, 0)
    local signature = string.format("%.3f|%.3f", tonumber(x) or 0, tonumber(y) or 0)
    if state.active ~= true or state.committed_value ~= signature then
        state.value.x = tonumber(x) or 0
        state.value.y = tonumber(y) or 0
        state.committed_value = signature
    end

    local changed = _draw_inspector_labeled_control(label_text, function(field_width)
        imgui.SetNextItemWidth(field_width)
        return imgui.InputFloat2(_make_inline_editor_label("", state_key), state.value, "%.1f", nil)
    end)
    local committed = changed == true or imgui.IsItemDeactivatedAfterEdit()
    state.active = imgui.IsItemActive()
    if committed and type(on_commit) == "function" then
        on_commit(state.value.x, state.value.y)
    end
end

_draw_widget_position_panel = function(document, widget)
    if not document or not widget or widget.id == "root" then
        return
    end

    local widget_runtime, canvas_width, canvas_height = _get_inspector_runtime_widget(document, widget.id)
    if not widget_runtime or not widget_runtime.rect then
        return
    end

    if not _can_transform_widget(widget_runtime) then
        imgui.TextDisabled("位置由父级容器控制")
        return
    end

    local parent_content_rect = _get_widget_parent_content_rect(widget_runtime, canvas_width, canvas_height)
    local current_rect = widget_runtime.rect
    local offset_x = current_rect.x - parent_content_rect.x
    local offset_y = current_rect.y - parent_content_rect.y
    local min_size = _normalize_vec2(widget_runtime.props and widget_runtime.props.min_size, 0, 0)
    local min_width = math.max(module.Config.preview_min_widget_extent, tonumber(min_size.x) or 0)
    local min_height = math.max(module.Config.preview_min_widget_extent, tonumber(min_size.y) or 0)

    imgui.SeparatorText("位置")
    _draw_position_vec2_editor(
        document,
        string.format("ui_widget_global_position_%s", widget.id),
        "全局位置",
        current_rect.x,
        current_rect.y,
        function(x, y)
            local next_rect = _copy_rect(current_rect)
            next_rect.x = tonumber(x) or current_rect.x
            next_rect.y = tonumber(y) or current_rect.y
            _set_widget_rect_from_runtime(document, widget_runtime, parent_content_rect, next_rect)
        end)

    _draw_position_vec2_editor(
        document,
        string.format("ui_widget_parent_offset_%s", widget.id),
        "父级偏移",
        offset_x,
        offset_y,
        function(x, y)
            local next_rect = _copy_rect(current_rect)
            next_rect.x = parent_content_rect.x + (tonumber(x) or offset_x)
            next_rect.y = parent_content_rect.y + (tonumber(y) or offset_y)
            _set_widget_rect_from_runtime(document, widget_runtime, parent_content_rect, next_rect)
        end)

    _draw_position_vec2_editor(
        document,
        string.format("ui_widget_rect_size_%s", widget.id),
        "长度宽度",
        current_rect.w,
        current_rect.h,
        function(width, height)
            local next_rect = _copy_rect(current_rect)
            next_rect.w = math.max(min_width, tonumber(width) or current_rect.w)
            next_rect.h = math.max(min_height, tonumber(height) or current_rect.h)
            _set_widget_rect_from_runtime(document, widget_runtime, parent_content_rect, next_rect)
        end)

    _draw_inspector_labeled_control("基于父级", function(field_width)
        local spacing = imgui.GetStyle().ItemSpacing.x
        local button_width = math.max(1, (field_width - spacing) * 0.5)
        if imgui.Button(string.format("水平居中##ui_widget_center_x_%s", widget.id), imgui.ImVec2(button_width, 0)) then
            local next_rect = _copy_rect(current_rect)
            next_rect.x = parent_content_rect.x + (parent_content_rect.w - current_rect.w) * 0.5
            _set_widget_rect_from_runtime(document, widget_runtime, parent_content_rect, next_rect)
        end
        imgui.SameLine()
        if imgui.Button(string.format("垂直居中##ui_widget_center_y_%s", widget.id), imgui.ImVec2(button_width, 0)) then
            local next_rect = _copy_rect(current_rect)
            next_rect.y = parent_content_rect.y + (parent_content_rect.h - current_rect.h) * 0.5
            _set_widget_rect_from_runtime(document, widget_runtime, parent_content_rect, next_rect)
        end
    end)
end

local function _apply_drag_preview(state, canvas_scale)
    local drag = state.drag
    if not drag or not drag.widget then
        state.snap_guides = nil
        return false
    end

    local current_mouse = imgui.GetMousePos()
    local delta_x = (current_mouse.x - drag.start_mouse.x) / canvas_scale
    local delta_y = (current_mouse.y - drag.start_mouse.y) / canvas_scale
    drag.delta_x = delta_x
    drag.delta_y = delta_y

    local next_rect = _copy_rect(drag.start_rect)
    if drag.mode == "resize" then
        next_rect = _build_preview_resize_rect(drag, delta_x, delta_y)
    else
        next_rect.x = drag.start_rect.x + delta_x
        next_rect.y = drag.start_rect.y + delta_y
    end

    local io = imgui.GetIO()
    if io and io.KeyAlt == true and drag.snap_candidates then
        local snap_threshold = module.Config.preview_snap_screen_threshold / math.max(0.001, canvas_scale)
        if drag.mode == "resize" then
            next_rect, state.snap_guides = _apply_preview_resize_snap(next_rect, drag, snap_threshold)
        else
            next_rect, state.snap_guides = _apply_preview_move_snap(next_rect, drag, snap_threshold)
        end
    else
        state.snap_guides = nil
    end

    local offset_min, offset_max = _rect_to_offsets(next_rect, drag.parent_content_rect, drag.anchor_min, drag.anchor_max)
    offset_min = _to_document_offset(drag.widget, offset_min)
    offset_max = _to_document_offset(drag.widget, offset_max)
    drag.current_rect = next_rect
    drag.current_offset_min = offset_min
    drag.current_offset_max = offset_max
    drag.widget.props.offset_min = _clone_value(offset_min)
    drag.widget.props.offset_max = _clone_value(offset_max)
    return true
end

local function _commit_drag_preview(document, state)
    local drag = state.drag
    if not drag or not drag.widget_id then
        return
    end

    local current_offset_min = drag.current_offset_min or drag.start_offset_min
    local current_offset_max = drag.current_offset_max or drag.start_offset_max
    local changed = math.abs((tonumber(current_offset_min.x) or 0) - (tonumber(drag.start_offset_min.x) or 0)) >= 0.001
        or math.abs((tonumber(current_offset_min.y) or 0) - (tonumber(drag.start_offset_min.y) or 0)) >= 0.001
        or math.abs((tonumber(current_offset_max.x) or 0) - (tonumber(drag.start_offset_max.x) or 0)) >= 0.001
        or math.abs((tonumber(current_offset_max.y) or 0) - (tonumber(drag.start_offset_max.y) or 0)) >= 0.001
    if not changed then
        state.drag = nil
        return
    end

    local snapshot = document:get_document_snapshot()
    local widget = UI.find_widget(snapshot, drag.widget_id)
    if widget then
        widget.props = widget.props or {}
        widget.props.offset_min = _clone_value(current_offset_min)
        widget.props.offset_max = _clone_value(current_offset_max)
        document:set_document_snapshot(snapshot)
    end
    state.drag = nil
    state.snap_guides = nil
end

local function _begin_preview_drag(state, runtime, widget_runtime, mode, handle_key, mouse_pos, canvas_width, canvas_height)
    if not _can_transform_widget(widget_runtime) then
        state.drag = nil
        return false
    end

    local min_size = _normalize_vec2(runtime:resolve_widget_prop(widget_runtime, "min_size"), 0, 0)
    state.drag =
    {
        mode = mode or "move",
        handle = handle_key,
        widget_id = widget_runtime.id,
        widget = widget_runtime,
        start_mouse = imgui.ImVec2(mouse_pos.x, mouse_pos.y),
        start_rect = _copy_rect(widget_runtime.rect),
        start_offset_min = _normalize_vec2(widget_runtime.props.offset_min, 0, 0),
        start_offset_max = _normalize_vec2(widget_runtime.props.offset_max, 0, 0),
        current_offset_min = _normalize_vec2(widget_runtime.props.offset_min, 0, 0),
        current_offset_max = _normalize_vec2(widget_runtime.props.offset_max, 0, 0),
        anchor_min = _normalize_vec2(widget_runtime.props.anchor_min, 0, 0),
        anchor_max = _normalize_vec2(widget_runtime.props.anchor_max, 0, 0),
        parent_content_rect = _get_widget_parent_content_rect(widget_runtime, canvas_width, canvas_height),
        min_size =
        {
            x = math.max(module.Config.preview_min_widget_extent, tonumber(min_size.x) or 0),
            y = math.max(module.Config.preview_min_widget_extent, tonumber(min_size.y) or 0),
        },
        snap_candidates = _build_preview_snap_candidates(widget_runtime.instance, widget_runtime.id, canvas_width, canvas_height),
        delta_x = 0,
        delta_y = 0,
    }
    return true
end

local function _draw_preview_panel(document)
    local preview_state = _sync_preview_instance(document)
    local runtime = preview_state.runtime
    local instance = preview_state.instance
    if not instance then
        imgui.TextDisabled("当前界面预览不可用。")
        return
    end

    local snapshot = document._document or document:get_document_snapshot()
    local canvas_width, canvas_height = _resolve_document_canvas_size(snapshot)
    if runtime.set_canvas_size_override then
        runtime:set_canvas_size_override(canvas_width, canvas_height)
    end
    local palette = _get_theme_palette()

    local header_padding_x = math.max(4, math.floor((tonumber(SettingsManager.get("editor_zoom_ratio")) or 1) * 6 + 0.5))
    local header_cursor = imgui.GetCursorPos()
    local header_start_x = header_cursor.x
    imgui.SetCursorPos(imgui.ImVec2(header_start_x + header_padding_x, header_cursor.y))
    imgui.SeparatorText("实时预览")
    header_cursor = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(header_start_x + header_padding_x, header_cursor.y))
    local safe_area_toggle = imgui.Bool(preview_state.show_safe_area == true)
    if imgui.Checkbox(string.format("安全区##ui_preview_safe_area_%s", _get_document_uid(document)), safe_area_toggle) then
        preview_state.show_safe_area = safe_area_toggle.val
    end
    imgui.SameLine()
    local guide_toggle = imgui.Bool(preview_state.show_guides == true)
    if imgui.Checkbox(string.format("辅助线##ui_preview_guides_%s", _get_document_uid(document)), guide_toggle) then
        preview_state.show_guides = guide_toggle.val
    end

    preview_state.background_color = preview_state.background_color or imgui.ImColor(0, 0, 0, 255)
    local background_color_width = imgui.GetContentRegionAvail().x
    if background_color_width >= 170 then
        imgui.SameLine()
        background_color_width = imgui.GetContentRegionAvail().x
    end
    imgui.SetNextItemWidth(math.max(136, math.min(190, background_color_width)))
    imgui.ColorEdit4(
        string.format("背景颜色##ui_preview_background_%s", _get_document_uid(document)),
        preview_state.background_color,
        imgui.ColorEditFlags.NoAlpha | imgui.ColorEditFlags.NoOptions)

    header_cursor = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(header_start_x, header_cursor.y))
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.BeginChild(
        string.format("ui_preview_canvas_panel_%s", _get_document_uid(document)),
        imgui.ImVec2(0, 0),
        imgui.ChildFlags.None,
        imgui.WindowFlags.NoScrollbar | imgui.WindowFlags.NoScrollWithMouse)
        local content_avail = imgui.GetContentRegionAvail()
        local host_size = imgui.ImVec2(math.max(32, content_avail.x), math.max(160, content_avail.y))
        local draw_list = imgui.GetWindowDrawList()

        imgui.InvisibleButton(string.format("##ui_preview_canvas_hitbox_%s", _get_document_uid(document)), host_size)
        local host_min = imgui.GetItemRectMin()
        local host_max = imgui.GetItemRectMax()
        local host_item_hovered = imgui.IsItemHovered()
        local host_item_active = imgui.IsItemActive()
        local host_rect = _make_rect(host_min.x, host_min.y, host_max.x - host_min.x, host_max.y - host_min.y)

        draw_list:AddRectFilled(
            imgui.ImVec2(host_rect.x, host_rect.y),
            imgui.ImVec2(host_rect.x + host_rect.w, host_rect.y + host_rect.h),
            preview_state.background_color:to_u32(),
            0)

        local padding = 0
        local fit_rect = _inset_rect(host_rect, padding, padding, padding, padding)
        local fit_scale = math.max(0.05, math.min(fit_rect.w / canvas_width, fit_rect.h / canvas_height))
        preview_state.view_zoom = _clamp(preview_state.view_zoom or 1.0, module.Config.preview_zoom_min, module.Config.preview_zoom_max)
        preview_state.view_zoom_target = _clamp(preview_state.view_zoom_target or preview_state.view_zoom or 1.0, module.Config.preview_zoom_min, module.Config.preview_zoom_max)
        preview_state.view_pan_x = tonumber(preview_state.view_pan_x) or 0
        preview_state.view_pan_y = tonumber(preview_state.view_pan_y) or 0
        preview_state.view_pan_target_x = tonumber(preview_state.view_pan_target_x) or 0
        preview_state.view_pan_target_y = tonumber(preview_state.view_pan_target_y) or 0

        local preview_scale = fit_scale * preview_state.view_zoom
        local canvas_draw_rect = _get_preview_camera_rect(
            fit_rect,
            canvas_width,
            canvas_height,
            preview_scale,
            preview_state.view_pan_x,
            preview_state.view_pan_y)

        local mouse_pos = imgui.GetMousePos()
        local host_hovered = host_item_hovered or host_item_active or preview_state.view_pan_active or preview_state.drag ~= nil
        local canvas_hovered = host_hovered and _rect_contains(canvas_draw_rect, mouse_pos.x, mouse_pos.y)
        local physical_mouse_down = imgui.IsMouseDown(0)
        local mouse_pressed = physical_mouse_down and not preview_state.pointer_down_last_frame
        local mouse_released = (not physical_mouse_down) and preview_state.pointer_down_last_frame
        local wheel_delta = host_item_hovered and (tonumber(imgui.GetIO().MouseWheel) or 0) or 0
        local selected_widget_id_for_wheel = _get_selected_widget_id(document)

        local canvas_mouse_x = -100000
        local canvas_mouse_y = -100000
        if canvas_hovered then
            canvas_mouse_x = (mouse_pos.x - canvas_draw_rect.x) / preview_scale
            canvas_mouse_y = (mouse_pos.y - canvas_draw_rect.y) / preview_scale
        end

        _apply_preview_scroll_offsets(preview_state)
        local input_capture_result = runtime:begin_frame(
        {
            mouse_x = canvas_mouse_x,
            mouse_y = canvas_mouse_y,
            mouse_down = canvas_hovered and physical_mouse_down,
            mouse_pressed = canvas_hovered and mouse_pressed,
            mouse_released = mouse_released,
            wheel_y = 0,
        })
        runtime:update(0)

        local wheel_consumed_by_selected_scroll = false
        if host_item_hovered and wheel_delta ~= 0 then
            local selected_scroll_widget = runtime:find_widget(instance, selected_widget_id_for_wheel)
            if selected_scroll_widget and selected_scroll_widget.visible and selected_scroll_widget.type == "ScrollView" then
                local current_scroll = math.max(0, tonumber(selected_scroll_widget.props and selected_scroll_widget.props.scroll_y) or 0)
                local max_scroll = math.max(0, tonumber(selected_scroll_widget.scroll_max_y_design or selected_scroll_widget.scroll_max_y) or 0)
                local speed = tonumber(runtime:resolve_widget_prop(selected_scroll_widget, "wheel_speed")) or 36
                local next_scroll = _clamp(current_scroll - wheel_delta * speed, 0, max_scroll)
                if math.abs(next_scroll - current_scroll) >= 0.001 then
                    selected_scroll_widget.props.scroll_y = next_scroll
                    preview_state.scroll_y_by_widget_id = preview_state.scroll_y_by_widget_id or {}
                    preview_state.scroll_y_by_widget_id[selected_scroll_widget.id] = next_scroll
                    runtime:update(0)
                end
                wheel_consumed_by_selected_scroll = true
            end
        end

        local wheel_consumed_by_runtime = (input_capture_result and input_capture_result.wheel_consumed == true)
            or wheel_consumed_by_selected_scroll
        if host_item_hovered and wheel_delta ~= 0 and not wheel_consumed_by_runtime then
            local target_scale_before = fit_scale * preview_state.view_zoom_target
            local target_rect_before = _get_preview_camera_rect(
                fit_rect,
                canvas_width,
                canvas_height,
                target_scale_before,
                preview_state.view_pan_target_x,
                preview_state.view_pan_target_y)
            local world_x = (mouse_pos.x - target_rect_before.x) / target_scale_before
            local world_y = (mouse_pos.y - target_rect_before.y) / target_scale_before
            local next_zoom_target = _clamp(
                preview_state.view_zoom_target * (1.15 ^ wheel_delta),
                module.Config.preview_zoom_min,
                module.Config.preview_zoom_max)
            local next_scale = fit_scale * next_zoom_target
            local next_pan_x = mouse_pos.x - world_x * next_scale - (fit_rect.x + (fit_rect.w - canvas_width * next_scale) * 0.5)
            local next_pan_y = mouse_pos.y - world_y * next_scale - (fit_rect.y + (fit_rect.h - canvas_height * next_scale) * 0.5)
            next_pan_x, next_pan_y = _clamp_preview_pan(
                fit_rect,
                canvas_width * next_scale,
                canvas_height * next_scale,
                next_pan_x,
                next_pan_y)
            preview_state.view_zoom_target = next_zoom_target
            preview_state.view_pan_target_x = next_pan_x
            preview_state.view_pan_target_y = next_pan_y
        end

        if preview_state.request_focus_to_content then
            _focus_preview_to_content(preview_state, instance, fit_rect, canvas_width, canvas_height, fit_scale)
            preview_state.request_focus_to_content = false
        end

        local pressed_pan_button = nil
        if host_item_hovered and not preview_state.drag and not physical_mouse_down then
            for _, mouse_button in ipairs(module.Config.preview_pan_mouse_button_list) do
                if imgui.IsMouseClicked(mouse_button, false) then
                    pressed_pan_button = mouse_button
                    break
                end
            end
        end

        if pressed_pan_button and not preview_state.view_pan_active then
            preview_state.view_pan_active = true
            preview_state.view_pan_button = pressed_pan_button
            preview_state.view_pan_start_mouse = imgui.ImVec2(mouse_pos.x, mouse_pos.y)
            preview_state.view_pan_start_x = preview_state.view_pan_target_x
            preview_state.view_pan_start_y = preview_state.view_pan_target_y
        end
        if preview_state.view_pan_active then
            local active_pan_button = tonumber(preview_state.view_pan_button)
            local pan_button_down = active_pan_button ~= nil and imgui.IsMouseDown(active_pan_button)
            local pan_button_released = active_pan_button ~= nil and imgui.IsMouseReleased(active_pan_button)
            if pan_button_down and preview_state.view_pan_start_mouse then
                local target_scale = fit_scale * preview_state.view_zoom_target
                local next_pan_x = preview_state.view_pan_start_x + (mouse_pos.x - preview_state.view_pan_start_mouse.x)
                local next_pan_y = preview_state.view_pan_start_y + (mouse_pos.y - preview_state.view_pan_start_mouse.y)
                next_pan_x, next_pan_y = _clamp_preview_pan(
                    fit_rect,
                    canvas_width * target_scale,
                    canvas_height * target_scale,
                    next_pan_x,
                    next_pan_y)
                preview_state.view_pan_target_x = next_pan_x
                preview_state.view_pan_target_y = next_pan_y
            end
            if pan_button_released or not pan_button_down then
                preview_state.view_pan_active = false
                preview_state.view_pan_button = nil
                preview_state.view_pan_start_mouse = nil
            end
        end

        do
            local target_scale = fit_scale * preview_state.view_zoom_target
            preview_state.view_pan_target_x, preview_state.view_pan_target_y = _clamp_preview_pan(
                fit_rect,
                canvas_width * target_scale,
                canvas_height * target_scale,
                preview_state.view_pan_target_x,
                preview_state.view_pan_target_y)
        end
        _step_preview_view(preview_state)
        preview_scale = fit_scale * preview_state.view_zoom
        preview_state.view_pan_x, preview_state.view_pan_y = _clamp_preview_pan(
            fit_rect,
            canvas_width * preview_scale,
            canvas_height * preview_scale,
            preview_state.view_pan_x,
            preview_state.view_pan_y)
        canvas_draw_rect = _get_preview_camera_rect(
            fit_rect,
            canvas_width,
            canvas_height,
            preview_scale,
            preview_state.view_pan_x,
            preview_state.view_pan_y)
        canvas_hovered = host_hovered and _rect_contains(canvas_draw_rect, mouse_pos.x, mouse_pos.y)

        canvas_mouse_x = -100000
        canvas_mouse_y = -100000
        if canvas_hovered then
            canvas_mouse_x = (mouse_pos.x - canvas_draw_rect.x) / preview_scale
            canvas_mouse_y = (mouse_pos.y - canvas_draw_rect.y) / preview_scale
        end

        local hovered_widget = nil
        if canvas_hovered then
            hovered_widget = runtime:pick_widget(instance, canvas_mouse_x, canvas_mouse_y, {allow_noninteractive = true})
        elseif host_hovered then
            hovered_widget = _pick_preview_widget_by_screen(instance, canvas_draw_rect, preview_scale, mouse_pos.x, mouse_pos.y)
        end
        preview_state.hovered_widget_id = hovered_widget and hovered_widget.id or nil
        preview_state.hovered_widget_type = hovered_widget and hovered_widget.type or nil
        if hovered_widget and hovered_widget.type == "SaveSlotGrid" and canvas_hovered then
            hovered_widget._last_pointer_x = canvas_mouse_x
            hovered_widget._last_pointer_y = canvas_mouse_y
            hovered_widget.hovered = true
        end

        local preview_interaction_consumed = false
        if mouse_pressed and canvas_hovered and hovered_widget and hovered_widget.type == "SaveSlotGrid" then
            local nav = _hit_preview_save_grid_nav(runtime, hovered_widget, canvas_mouse_x, canvas_mouse_y)
            if nav then
                local _, page, _, total_pages = _resolve_preview_save_grid_options(runtime, hovered_widget)
                if nav == "prev" and page > 1 then
                    _set_preview_save_grid_page(runtime, hovered_widget, page - 1)
                    runtime:update(0)
                elseif nav == "next" and page < total_pages then
                    _set_preview_save_grid_page(runtime, hovered_widget, page + 1)
                    runtime:update(0)
                end
                _set_selected_widget_id(document, hovered_widget.id)
                preview_state.press_candidate_id = nil
                preview_state.press_from_preview = false
                preview_interaction_consumed = true
            end
        end

        local selected_widget_id = _get_selected_widget_id(document)
        local selected_widget = runtime:find_widget(instance, selected_widget_id)
        local selected_widget_screen_rect = selected_widget and selected_widget.visible and _transform_rect(selected_widget.rect, canvas_draw_rect, preview_scale) or nil
        local hovered_resize_handle = nil
        if not preview_state.view_pan_active and not preview_state.drag and _can_transform_widget(selected_widget) then
            hovered_resize_handle = _pick_resize_handle(selected_widget_screen_rect, mouse_pos.x, mouse_pos.y)
        end

        if mouse_pressed and not preview_state.view_pan_active and not preview_interaction_consumed then
            preview_state.press_candidate_id = nil
            preview_state.press_from_preview = false
            local started_transform = false

            if hovered_resize_handle and selected_widget then
                started_transform = _begin_preview_drag(
                    preview_state,
                    runtime,
                    selected_widget,
                    "resize",
                    hovered_resize_handle,
                    mouse_pos,
                    canvas_width,
                    canvas_height)
                if started_transform then
                    preview_state.press_candidate_id = selected_widget_id
                    preview_state.press_from_preview = true
                end
            elseif host_item_hovered and (canvas_hovered or hovered_widget) then
                preview_state.press_candidate_id = hovered_widget and hovered_widget.id or "root"
                preview_state.press_from_preview = true
                if preview_state.press_candidate_id == selected_widget_id and _can_transform_widget(selected_widget) then
                    started_transform = _begin_preview_drag(
                        preview_state,
                        runtime,
                        selected_widget,
                        "move",
                        nil,
                        mouse_pos,
                        canvas_width,
                        canvas_height)
                end
            end

            if not started_transform then
                preview_state.drag = nil
                preview_state.snap_guides = nil
            end
        end

        if preview_state.drag and physical_mouse_down then
            if _apply_drag_preview(preview_state, preview_scale) then
                runtime:update(0)
                if canvas_hovered then
                    hovered_widget = runtime:pick_widget(instance, canvas_mouse_x, canvas_mouse_y, {allow_noninteractive = true})
                elseif host_hovered then
                    hovered_widget = _pick_preview_widget_by_screen(instance, canvas_draw_rect, preview_scale, mouse_pos.x, mouse_pos.y)
                else
                    hovered_widget = nil
                end
                preview_state.hovered_widget_id = hovered_widget and hovered_widget.id or nil
                preview_state.hovered_widget_type = hovered_widget and hovered_widget.type or nil
            end
        end

        if mouse_released then
            if preview_state.drag then
                _commit_drag_preview(document, preview_state)
            elseif preview_state.press_from_preview and preview_state.press_candidate_id then
                _set_selected_widget_id(document, preview_state.press_candidate_id)
            end
            preview_state.press_candidate_id = nil
            preview_state.press_from_preview = false
            preview_state.snap_guides = nil
        end

        draw_list:AddRectFilled(
            imgui.ImVec2(canvas_draw_rect.x, canvas_draw_rect.y),
            imgui.ImVec2(canvas_draw_rect.x + canvas_draw_rect.w, canvas_draw_rect.y + canvas_draw_rect.h),
            preview_state.background_color:to_u32(),
            0)
        local preview_border_color = imgui.ImColor(232, 232, 232, 218):to_u32()
        _draw_outline(draw_list, canvas_draw_rect, preview_border_color, 1)

        if preview_state.show_guides then
            local guide_color = imgui.ImColor(220, 220, 220, 190):to_u32()
            local middle_x = canvas_draw_rect.x + canvas_draw_rect.w * 0.5
            local middle_y = canvas_draw_rect.y + canvas_draw_rect.h * 0.5
            draw_list:AddRectFilled(imgui.ImVec2(middle_x, canvas_draw_rect.y), imgui.ImVec2(middle_x + 1, canvas_draw_rect.y + canvas_draw_rect.h), guide_color)
            draw_list:AddRectFilled(imgui.ImVec2(canvas_draw_rect.x, middle_y), imgui.ImVec2(canvas_draw_rect.x + canvas_draw_rect.w, middle_y + 1), guide_color)
        end

        if preview_state.show_safe_area then
            local safe_margin = canvas_draw_rect.h * (module.Config.preview_safe_area_letterbox_height / module.Config.preview_safe_area_reference_height)
            _draw_outline(
                draw_list,
                _inset_rect(canvas_draw_rect, safe_margin, safe_margin, safe_margin, safe_margin),
                _to_u32(EditorThemeManager.with_alpha(palette.accent, 0.55), 1),
                1)
        end

        _draw_preview_widget(draw_list, runtime, instance.root, canvas_draw_rect, preview_scale, 1)
        _draw_preview_snap_guides(draw_list, host_rect, canvas_draw_rect, preview_scale, preview_state.snap_guides, palette)

        selected_widget = runtime:find_widget(instance, selected_widget_id)
        selected_widget_screen_rect = selected_widget and selected_widget.visible and _transform_rect(selected_widget.rect, canvas_draw_rect, preview_scale) or nil
        if selected_widget and selected_widget.visible then
            local selected_clip_rect = _get_preview_widget_screen_clip(selected_widget, canvas_draw_rect, preview_scale)
            _draw_preview_outline_clipped(
                draw_list,
                selected_widget_screen_rect,
                _to_u32(module.Config.preview_transform_color, 1),
                2,
                selected_clip_rect)
            local clip_token = _push_preview_clip_rect(draw_list, selected_clip_rect)
            if _can_transform_widget(selected_widget) and (not selected_clip_rect or clip_token) then
                _draw_resize_handles(draw_list, selected_widget_screen_rect, palette, hovered_resize_handle)
            end
            _pop_preview_clip_rect(draw_list, clip_token)
        end
        if hovered_widget and hovered_widget ~= selected_widget and hovered_widget.visible then
            local hovered_clip_rect = _get_preview_widget_screen_clip(hovered_widget, canvas_draw_rect, preview_scale)
            _draw_preview_outline_clipped(
                draw_list,
                _transform_rect(hovered_widget.rect, canvas_draw_rect, preview_scale),
                _to_u32(EditorThemeManager.with_alpha(palette.selection, 0.78), 1),
                1,
                hovered_clip_rect)
        end

        preview_state.pointer_down_last_frame = physical_mouse_down
    imgui.EndChild()
    imgui.PopStyleVar()
end

local function _push_ui_designer_panel_style(editor_zoom_ratio, options)
    options = options or {}
    local style_var = imgui.StyleVar or {}
    local zoom = math.max(0.25, tonumber(editor_zoom_ratio) or 1)
    local pushed = 0
    local function push(style_id, value)
        if style_id == nil then
            return
        end
        imgui.PushStyleVar(style_id, value)
        pushed = pushed + 1
    end

    if options.window_padding_x ~= nil or options.window_padding_y ~= nil then
        push(
            style_var.WindowPadding,
            imgui.ImVec2(
                math.floor((tonumber(options.window_padding_x) or 0) * zoom + 0.5),
                math.floor((tonumber(options.window_padding_y) or 0) * zoom + 0.5)))
    end
    if options.frame_padding_x ~= nil or options.frame_padding_y ~= nil then
        push(
            style_var.FramePadding,
            imgui.ImVec2(
                math.floor((tonumber(options.frame_padding_x) or 0) * zoom + 0.5),
                math.floor((tonumber(options.frame_padding_y) or 0) * zoom + 0.5)))
    end
    if options.item_spacing_x ~= nil or options.item_spacing_y ~= nil then
        push(
            style_var.ItemSpacing,
            imgui.ImVec2(
                math.floor((tonumber(options.item_spacing_x) or 0) * zoom + 0.5),
                math.floor((tonumber(options.item_spacing_y) or 0) * zoom + 0.5)))
    end
    if options.item_inner_spacing_x ~= nil or options.item_inner_spacing_y ~= nil then
        push(
            style_var.ItemInnerSpacing,
            imgui.ImVec2(
                math.floor((tonumber(options.item_inner_spacing_x) or 0) * zoom + 0.5),
                math.floor((tonumber(options.item_inner_spacing_y) or 0) * zoom + 0.5)))
    end
    if options.frame_rounding ~= nil then
        push(style_var.FrameRounding, (tonumber(options.frame_rounding) or 0) * zoom)
    end
    if options.child_border_size ~= nil then
        push(style_var.ChildBorderSize, math.max(1, math.floor((tonumber(options.child_border_size) or 1) * zoom + 0.5)))
    end
    return pushed
end

local function _pop_ui_designer_panel_style(pushed)
    if pushed and pushed > 0 then
        imgui.PopStyleVar(pushed)
    end
end

local function _draw_document_body(document)
    if document._resource_missing then
        _draw_warning_banner("当前界面文件已从磁盘移除，保存前请确认路径是否仍然有效。", imgui.ImColor(196, 94, 94, 255).value)
    end
    if document._external_change_pending then
        if document:is_modified() then
            _draw_warning_banner("检测到磁盘中的界面文件发生变化，但当前文档存在未保存修改，已暂停自动同步。", imgui.ImColor(224, 168, 88, 255).value)
        else
            local auto_reload_ok = document:reload_from_disk({silent = true})
            if not auto_reload_ok then
                _draw_warning_banner("检测到磁盘中的界面文件发生变化，但自动同步失败，请检查控制台日志。", imgui.ImColor(214, 140, 82, 255).value)
            end
        end
    end

    local loaded_ok, load_err = document:ensure_document_loaded()
    if not loaded_ok then
        _draw_warning_banner(string.format("当前界面文件加载失败：%s", tostring(load_err or document:get_last_load_error() or "未知错误")), imgui.ImColor(196, 94, 94, 255).value)
        imgui.TextDisabled("无法加载当前界面文件。")
        return
    end

    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    local document_uid = _get_document_uid(document)
    local table_flags = imgui.TableFlags.Resizable
        | imgui.TableFlags.SizingStretchProp
        | imgui.TableFlags.BordersInnerV
    if imgui.BeginTable(string.format("ui_designer_columns_%s", document_uid), 3, table_flags, imgui.ImVec2(0, 0)) then
        imgui.TableSetupColumn("组件树", imgui.TableColumnFlags.WidthStretch, 0.23)
        imgui.TableSetupColumn("实时预览", imgui.TableColumnFlags.WidthStretch, 0.52)
        imgui.TableSetupColumn("参数", imgui.TableColumnFlags.WidthStretch, 0.25)
        imgui.TableNextRow()

        imgui.TableSetColumnIndex(0)
        local widget_tree_spacing_y = math.max(1, tonumber(module.Config.widget_tree_vertical_spacing_scale) or 2)
        local widget_tree_style = ImGUIHelper.PushCompactTreeStyle(editor_zoom_ratio,
        {
            include_window_padding = true,
            window_padding_x = 6,
            window_padding_y = 4,
            frame_padding_x = 2,
            frame_padding_y = widget_tree_spacing_y,
            item_spacing_x = 2,
            item_spacing_y = widget_tree_spacing_y,
            item_inner_spacing_x = 2,
            item_inner_spacing_y = widget_tree_spacing_y,
            indent_spacing = math.max(18, tonumber(module.Config.widget_tree_indent_spacing) or 36),
        })
        imgui.BeginChild(
            string.format("ui_widget_tree_panel_%s", document_uid),
            imgui.ImVec2(0, 0),
            imgui.ChildFlags.Borders,
            imgui.WindowFlags.HorizontalScrollbar)
            _draw_widget_tree_panel(document)
        imgui.EndChild()
        ImGUIHelper.PopCompactTreeStyle(widget_tree_style)

        imgui.TableSetColumnIndex(1)
        local preview_panel_style = _push_ui_designer_panel_style(editor_zoom_ratio,
        {
            window_padding_x = 0,
            window_padding_y = 0,
            child_border_size = 1,
        })
        imgui.BeginChild(string.format("ui_preview_root_panel_%s", document_uid), imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
            _draw_preview_panel(document)
        imgui.EndChild()
        _pop_ui_designer_panel_style(preview_panel_style)

        imgui.TableSetColumnIndex(2)
        local inspector_panel_style = _push_ui_designer_panel_style(editor_zoom_ratio,
        {
            window_padding_x = 6,
            window_padding_y = 4,
            frame_padding_x = 4,
            frame_padding_y = 2,
            item_spacing_x = 4,
            item_spacing_y = 5,
            item_inner_spacing_x = 3,
            item_inner_spacing_y = 2,
            frame_rounding = 3,
            child_border_size = 1,
        })
        imgui.BeginChild(string.format("ui_inspector_panel_%s", document_uid), imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
            _draw_widget_inspector_panel(document)
        imgui.EndChild()
        _pop_ui_designer_panel_style(inspector_panel_style)

        imgui.EndTable()
    end
end

local function _draw_document_tab(document)
    local previous_modify_context = ModifyManager.get_context()
    ModifyManager.set_context(document._modify_context)

    local flag = imgui.TabItemFlags.None
    if ModifyManager.is_modify() then
        flag = flag | imgui.TabItemFlags.UnsavedDocument
    end
    local should_restore_selection = pending_tab_select_guid ~= nil
        and pending_tab_select_guid ~= ""
        and pending_tab_select_guid == document._resource_guid
    if should_restore_selection then
        flag = flag | imgui.TabItemFlags.SetSelected
    end

    local tab_open = document._is_open
    if GlobalContext.is_debug_game then
        tab_open = nil
    end
    if imgui.BeginTabItem(document._tab_label or document._id, tab_open, flag) then
        if not GlobalContext.is_debug_game then
            UIWorkspaceManager.set_workspace_current_ui(document)
        end
        _with_document_context(document, function()
            _draw_document_body(document)
        end)
        imgui.EndTabItem()
    end
    if should_restore_selection then
        pending_tab_select_guid = nil
    end

    if tab_open and not tab_open.val then
        local document_uid = _get_document_uid(document)
        _dispose_preview_state(document_uid)
        selected_widget_by_guid[document_uid] = nil
        tree_context_widget_by_guid[document_uid] = nil
        pending_tree_context_popup_by_guid[document_uid] = nil
        UIWorkspaceManager.close_ui_in_workspace(document)
        pending_tab_select_guid = UIWorkspaceManager.get_workspace_current_guid()
    end

    ModifyManager.set_context(previous_modify_context)
end

local function _has_active_input_widget()
    return imgui.IsAnyItemActive() or imgui.IsAnyItemFocused()
end

function module.on_enter()
    UIWorkspaceManager.load()
    pending_open_error_text = nil
    pending_tab_select_guid = UIWorkspaceManager.get_workspace_current_guid()
    pending_window_focus_frames = 0
    focus_reclaim_armed = false
end

function module.on_exit()
    was_window_focused = false
    pending_open_error_text = nil
    pending_tab_select_guid = nil
    pending_window_focus_frames = 0
    focus_reclaim_armed = false
    create_widget_request = nil
    pending_create_widget_popup = false
    tree_context_widget_by_guid = {}
    pending_tree_context_popup_by_guid = {}
    for uid in pairs(preview_state_by_guid) do
        _dispose_preview_state(uid)
    end
end

function module.get_current_document()
    local document = UIWorkspaceManager.find_by_guid(UIWorkspaceManager.get_workspace_current_guid())
    if document and document._is_open and document._is_open.val then
        return document
    end
    return nil
end

function module.is_window_focused()
    return was_window_focused == true
end

function module.save_current_document()
    local document = module.get_current_document()
    if not document then
        return false
    end
    return _with_document_context(document, function(current_document)
        return current_document:save_document()
    end)
end

function module.undo_current_document()
    local document = module.get_current_document()
    if not document then
        return false
    end
    return _with_document_context(document, function()
        UndoManager.undo()
        return true
    end)
end

function module.redo_current_document()
    local document = module.get_current_document()
    if not document then
        return false
    end
    return _with_document_context(document, function()
        UndoManager.redo()
        return true
    end)
end

function module.open_ui_document(value, options)
    local open_options = options or {select = true}
    local document, err = UIWorkspaceManager.open_ui_in_workspace(value, open_options)
    if document then
        pending_open_error_text = nil
        if open_options.select ~= false then
            pending_tab_select_guid = document._resource_guid or nil
            pending_window_focus_frames = math.max(pending_window_focus_frames, 2)
        end
    elseif err and err ~= "" then
        local resource_name = nil
        if type(value) == "table" then
            resource_name = value._resource_id or value._display_name or value._path or value._id
        end
        if not resource_name then
            local guid = ResourceIndex.resolve_guid("ui", value)
            local meta = guid and ResourceIndex.find_by_guid(guid) or nil
            resource_name = meta and (meta.id or meta.display_name or meta.path) or nil
        end
        resource_name = resource_name or tostring(value)
        pending_open_error_text = string.format("打开界面文件失败：%s。详情请查看日志。", tostring(resource_name))
        pending_window_focus_frames = math.max(pending_window_focus_frames, 2)
        LogManager.log(string.format("打开界面文件失败：%s\n%s", tostring(resource_name), tostring(err or "未知错误")), "error")
    end
    return document, err
end

function module.on_update(self, delta)
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    if pending_window_focus_frames > 0 and not GlobalContext.is_resource_modal_active then
        imgui.SetNextWindowFocus()
        pending_window_focus_frames = pending_window_focus_frames - 1
    end
    local is_open = imgui.Begin("界面设计视图")
    local window_focused = imgui.IsWindowFocused(imgui.FocusedFlags.RootAndChildWindows)
    if is_open then
        local pos_begin = imgui.GetCursorScreenPos()
        local size_content = imgui.GetContentRegionAvail()
        do
            if pending_open_error_text and pending_open_error_text ~= "" then
                _draw_warning_banner(pending_open_error_text, imgui.ImColor(196, 94, 94, 255).value)
            end
            local tab_border_style = nil
            if ImGUIHelper.ShouldUseInHThemeCompensation() then
                tab_border_style = ImGUIHelper.PushSoftTabBorderStyle(editor_zoom_ratio)
            end
            if imgui.BeginTabBar("TabBar_UIDocuments", imgui.TabBarFlags.Reorderable | imgui.TabBarFlags.AutoSelectNewTabs) then
                local open_document_list = UIWorkspaceManager.get_workspace_open_documents()
                if #open_document_list == 0 then
                    imgui.TextDisabled("当前没有打开的界面文件，可从资产视图双击 .ui 文件打开。")
                end
                for _, document in ipairs(open_document_list) do
                    _draw_document_tab(document)
                end
                imgui.EndTabBar()
            else
                imgui.TextDisabled("当前没有打开的界面文件，可从资产视图双击 .ui 文件打开。")
            end
            if tab_border_style then
                ImGUIHelper.PopSoftTabBorderStyle(tab_border_style)
            end

            local current_document = module.get_current_document()
            local io = imgui.GetIO()
            local can_handle_shortcuts = window_focused
                and current_document ~= nil
                and not GlobalContext.is_debug_game
                and not GlobalContext.is_resource_modal_active
                and not _has_active_input_widget()
            if can_handle_shortcuts and io.KeyCtrl and not io.KeyShift and imgui.IsKeyPressed(imgui.ImGuiKey.S, false) then
                module.save_current_document()
            end
            if can_handle_shortcuts and io.KeyCtrl and imgui.IsKeyPressed(imgui.ImGuiKey.Z, false) then
                module.undo_current_document()
            end
            if can_handle_shortcuts and io.KeyCtrl and imgui.IsKeyPressed(imgui.ImGuiKey.Y, false) then
                module.redo_current_document()
            end
            if can_handle_shortcuts and imgui.IsKeyPressed(imgui.ImGuiKey.Delete, false) then
                _with_document_context(current_document, function()
                    _delete_selected_widget(current_document)
                end)
            end
            if can_handle_shortcuts and io.KeyCtrl and imgui.IsKeyPressed(imgui.ImGuiKey.C, false) then
                _with_document_context(current_document, function()
                    _copy_selected_widget(current_document)
                end)
            end
            if can_handle_shortcuts and io.KeyCtrl and imgui.IsKeyPressed(imgui.ImGuiKey.V, false) then
                _with_document_context(current_document, function()
                    _paste_widget_from_clipboard(current_document)
                end)
            end
            if can_handle_shortcuts and io.KeyCtrl and imgui.IsKeyPressed(imgui.ImGuiKey.D, false) then
                _with_document_context(current_document, function()
                    _duplicate_selected_widget(current_document)
                end)
            end
            if can_handle_shortcuts and io.KeyCtrl and imgui.IsKeyPressed(imgui.ImGuiKey.R, false) then
                _request_preview_focus_to_content(current_document)
            end
        end
    end
    if is_open and not GlobalContext.is_debug_game and window_focused and imgui.IsMouseDown(0) then
        focus_reclaim_armed = true
    elseif focus_reclaim_armed and is_open and not GlobalContext.is_debug_game and not window_focused and imgui.IsWindowDocked() and imgui.IsMouseReleased(0) then
        pending_window_focus_frames = math.max(pending_window_focus_frames, 2)
        focus_reclaim_armed = false
    elseif not imgui.IsMouseDown(0) then
        focus_reclaim_armed = false
    end
    imgui.End()
    was_window_focused = is_open and window_focused or false
    UIWorkspaceManager.sync_workspace_state()
end

function module.on_render()
end

return module

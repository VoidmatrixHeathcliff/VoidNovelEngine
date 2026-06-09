local module = {}

local imgui = Engine.ImGUI
local rl = Engine.Raylib

local GlobalContext = require("application.framework.global_context")

local INVALID_POINTER_VALUE <const> = -100000
local INPUT_ACTIVITY_GRACE_PERIOD <const> = 0.16

local state =
{
    mode_active = false,
    host_registered = false,
    window_focused = false,
    window_hovered = false,
    visual_focused = false,
    visual_hovered = false,
    image_hovered = false,
    keyboard_routable = false,
    pointer_routable = false,
    wheel_routable = false,
    pointer_capture_active = false,
    image_rect = nil,
    game_width = 0,
    game_height = 0,
    last_input_time = -1,
}

local function _is_mode_active()
    return GlobalContext.is_debug_game == true
        and GlobalContext.is_preview_in_editor == true
        and GlobalContext.is_resource_modal_active ~= true
end

local function _is_point_in_rect(rect, point)
    if not rect or not point then
        return false
    end

    return point.x >= rect.x and point.y >= rect.y
        and point.x < (rect.x + rect.w)
        and point.y < (rect.y + rect.h)
end

local function _is_point_in_any_rect(rect_list, point)
    if type(rect_list) ~= "table" then
        return false
    end

    for _, rect in ipairs(rect_list) do
        if _is_point_in_rect(rect, point) then
            return true
        end
    end
    return false
end

local function _touch_input_activity()
    state.last_input_time = rl.GetTime()
end

local function _reset_frame_visual_state()
    state.host_registered = false
    state.window_focused = false
    state.window_hovered = false
    state.visual_focused = false
    state.visual_hovered = false
    state.image_hovered = false
    state.keyboard_routable = false
    state.pointer_routable = false
    state.wheel_routable = false
    state.image_rect = nil
    state.game_width = 0
    state.game_height = 0
end

module.begin_frame = function()
    state.mode_active = _is_mode_active()

    if not state.mode_active then
        state.pointer_capture_active = false
    end

    _reset_frame_visual_state()
end

module.register_host = function(host)
    if not _is_mode_active() then
        state.mode_active = false
        state.pointer_capture_active = false
        _reset_frame_visual_state()
        return false
    end

    if state.mode_active ~= true then
        return false
    end

    host = type(host) == "table" and host or {}
    state.host_registered = true
    state.image_rect = host.image_rect
    state.game_width = tonumber(host.game_width) or 0
    state.game_height = tonumber(host.game_height) or 0

    local mouse_pos = imgui.GetMousePos()
    local mouse_down = imgui.IsMouseDown(0)
    local mouse_pressed = imgui.IsMouseClicked(0, false)
    local mouse_released = imgui.IsMouseReleased(0)
    local wheel_y = tonumber(imgui.GetIO().MouseWheel) or 0
    local was_pointer_capture_active = state.pointer_capture_active

    local window_hovered = host.window_hovered == true
    local window_focused = host.window_focused == true
    local image_hovered = _is_point_in_rect(state.image_rect, mouse_pos)
        and not _is_point_in_any_rect(host.blocked_rect_list, mouse_pos)
    local activation_click = window_hovered and image_hovered and mouse_pressed

    local next_pointer_capture_active = was_pointer_capture_active
    if next_pointer_capture_active and not mouse_down then
        next_pointer_capture_active = false
    end
    if activation_click then
        next_pointer_capture_active = true
    elseif mouse_pressed and not image_hovered then
        next_pointer_capture_active = false
    end
    state.pointer_capture_active = next_pointer_capture_active

    state.window_hovered = window_hovered
    state.window_focused = window_focused
    state.keyboard_routable = window_focused or activation_click
    state.visual_focused = state.keyboard_routable or was_pointer_capture_active or state.pointer_capture_active
    state.visual_hovered = state.visual_focused or window_hovered or image_hovered
    state.image_hovered = image_hovered
    state.pointer_routable = was_pointer_capture_active
        or state.pointer_capture_active
        or (image_hovered and state.visual_focused)
    state.wheel_routable = image_hovered and state.visual_focused

    if mouse_pressed or mouse_released or mouse_down or wheel_y ~= 0 then
        if state.pointer_routable or state.wheel_routable then
            _touch_input_activity()
        end
    end

    return true
end

module.should_override_runtime_input = function()
    return state.mode_active == true
        and _is_mode_active()
        and state.host_registered == true
        and state.image_rect ~= nil
end

module.get_runtime_host_state = function()
    if state.mode_active ~= true or state.host_registered ~= true or state.image_rect == nil then
        return nil
    end

    return state
end

module.should_block_editor_shortcuts = function()
    return state.mode_active == true and _is_mode_active() and state.visual_focused == true
end

module.is_preview_focused = function()
    return state.visual_focused == true
end

module.is_preview_hovered = function()
    return state.visual_hovered == true
end

module.is_preview_interaction_active = function()
    if state.mode_active ~= true or not _is_mode_active() then
        return false
    end

    if state.visual_focused or state.image_hovered or state.pointer_capture_active then
        return true
    end

    if state.last_input_time < 0 then
        return false
    end

    return (rl.GetTime() - state.last_input_time) <= INPUT_ACTIVITY_GRACE_PERIOD
end

module.get_invalid_pointer_value = function()
    return INVALID_POINTER_VALUE
end

return module

local rl = Engine.Raylib
local imgui = Engine.ImGUI

local EditorPreviewInput = require("application.framework.editor_preview_input")
local ScreenManager = require("application.framework.screen_manager")

local module = {}
local INVALID_POINTER_VALUE <const> = -100000

local key_spec_list <const> =
{
    {field = "space_pressed", name = "space", rl_key = rl.KeyboardKey.SPACE, imgui_key = imgui.ImGuiKey.Space},
    {field = "enter_pressed", name = "enter", rl_key = rl.KeyboardKey.ENTER, imgui_key = imgui.ImGuiKey.Enter},
    {field = "keypad_enter_pressed", name = "keypad_enter", rl_key = rl.KeyboardKey.KP_ENTER, imgui_key = imgui.ImGuiKey.KeypadEnter},
    {field = "escape_pressed", name = "escape", rl_key = rl.KeyboardKey.ESCAPE, imgui_key = imgui.ImGuiKey.Escape},
    {field = "tab_pressed", name = "tab", rl_key = rl.KeyboardKey.TAB, imgui_key = imgui.ImGuiKey.Tab},
    {field = "up_pressed", name = "up", rl_key = rl.KeyboardKey.UP, imgui_key = imgui.ImGuiKey.UpArrow},
    {field = "down_pressed", name = "down", rl_key = rl.KeyboardKey.DOWN, imgui_key = imgui.ImGuiKey.DownArrow},
    {field = "left_pressed", name = "left", rl_key = rl.KeyboardKey.LEFT, imgui_key = imgui.ImGuiKey.LeftArrow},
    {field = "right_pressed", name = "right", rl_key = rl.KeyboardKey.RIGHT, imgui_key = imgui.ImGuiKey.RightArrow},
}

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

local function _make_empty_state(source)
    return
    {
        source = source or "native",
        mouse_x = INVALID_POINTER_VALUE,
        mouse_y = INVALID_POINTER_VALUE,
        mouse_down = false,
        mouse_pressed = false,
        mouse_released = false,
        wheel_y = 0,
        space_pressed = false,
        enter_pressed = false,
        keypad_enter_pressed = false,
        escape_pressed = false,
        tab_pressed = false,
        up_pressed = false,
        down_pressed = false,
        left_pressed = false,
        right_pressed = false,
        key_down_map = {},
        key_pressed_map = {},
        key_released_map = {},
        submit_pressed = false,
    }
end

local function _apply_key_state(source, field, name, down, pressed, released)
    source[field] = pressed == true
    source.key_down_map[name] = down == true
    source.key_pressed_map[name] = pressed == true
    source.key_released_map[name] = released == true
end

local function _populate_native_key_state(source)
    for _, spec in ipairs(key_spec_list) do
        _apply_key_state(
            source,
            spec.field,
            spec.name,
            rl.IsKeyDown(spec.rl_key),
            rl.IsKeyPressed(spec.rl_key),
            rl.IsKeyReleased(spec.rl_key))
    end
end

local function _populate_editor_key_state(source, keyboard_routable)
    for _, spec in ipairs(key_spec_list) do
        local is_down = keyboard_routable and imgui.IsKeyDown(spec.imgui_key)
        local is_pressed = keyboard_routable and imgui.IsKeyPressed(spec.imgui_key, false)
        local is_released = keyboard_routable and imgui.IsKeyReleased(spec.imgui_key)
        _apply_key_state(source, spec.field, spec.name, is_down, is_pressed, is_released)
    end
end

local function _read_native_state()
    local mouse_x, mouse_y = ScreenManager.get_mouse_pos()
    local state = _make_empty_state("native")
    state.mouse_x = mouse_x
    state.mouse_y = mouse_y
    state.mouse_down = rl.IsMouseButtonDown(rl.MouseButton.LEFT)
    state.mouse_pressed = rl.IsMouseButtonPressed(rl.MouseButton.LEFT)
    state.mouse_released = rl.IsMouseButtonReleased(rl.MouseButton.LEFT)
    state.wheel_y = rl.GetMouseWheelMove()
    _populate_native_key_state(state)
    state.submit_pressed = state.space_pressed or state.enter_pressed or state.keypad_enter_pressed
    return state
end

local function _build_editor_preview_state(host_state)
    local state = _make_empty_state("editor_preview")
    if type(host_state) ~= "table" then
        return state
    end

    local keyboard_routable = host_state.keyboard_routable == true
    local pointer_routable = host_state.pointer_routable == true
    local wheel_routable = host_state.wheel_routable == true
    local image_rect = host_state.image_rect
    local image_width = image_rect and tonumber(image_rect.w) or 0
    local image_height = image_rect and tonumber(image_rect.h) or 0
    local game_width = math.max(1, tonumber(host_state.game_width) or 0)
    local game_height = math.max(1, tonumber(host_state.game_height) or 0)
    local mouse_pos = imgui.GetMousePos()

    if pointer_routable and image_rect and image_width > 0 and image_height > 0 then
        local normalized_x = (mouse_pos.x - image_rect.x) / image_width
        local normalized_y = (mouse_pos.y - image_rect.y) / image_height
        normalized_x = math.max(0, math.min(1, normalized_x))
        normalized_y = math.max(0, math.min(1, normalized_y))
        state.mouse_x = normalized_x * game_width
        state.mouse_y = normalized_y * game_height
        state.mouse_down = imgui.IsMouseDown(0)
        state.mouse_pressed = imgui.IsMouseClicked(0, false)
        state.mouse_released = imgui.IsMouseReleased(0)
    end

    if wheel_routable then
        state.wheel_y = tonumber(imgui.GetIO().MouseWheel) or 0
    end

    _populate_editor_key_state(state, keyboard_routable)
    state.submit_pressed = state.space_pressed or state.enter_pressed or state.keypad_enter_pressed
    return state
end

function module.make_empty_state(source)
    return _make_empty_state(source)
end

function module.clone_state(state)
    return _clone_value(state)
end

function module.normalize_state(state)
    local source = type(state) == "table" and state or _read_native_state()
    local normalized = _make_empty_state(source.source or "native")
    normalized.mouse_x = tonumber(source.mouse_x) or INVALID_POINTER_VALUE
    normalized.mouse_y = tonumber(source.mouse_y) or INVALID_POINTER_VALUE
    normalized.mouse_down = source.mouse_down == true
    normalized.mouse_pressed = source.mouse_pressed == true
    normalized.mouse_released = source.mouse_released == true
    normalized.wheel_y = tonumber(source.wheel_y) or 0
    normalized.space_pressed = source.space_pressed == true
    normalized.enter_pressed = source.enter_pressed == true
    normalized.keypad_enter_pressed = source.keypad_enter_pressed == true
    normalized.escape_pressed = source.escape_pressed == true
    normalized.tab_pressed = source.tab_pressed == true
    normalized.up_pressed = source.up_pressed == true
    normalized.down_pressed = source.down_pressed == true
    normalized.left_pressed = source.left_pressed == true
    normalized.right_pressed = source.right_pressed == true
    normalized.key_down_map = _clone_value(type(source.key_down_map) == "table" and source.key_down_map or {})
    normalized.key_pressed_map = _clone_value(type(source.key_pressed_map) == "table" and source.key_pressed_map or {})
    normalized.key_released_map = _clone_value(type(source.key_released_map) == "table" and source.key_released_map or {})
    normalized.submit_pressed = source.submit_pressed == true
        or normalized.space_pressed
        or normalized.enter_pressed
        or normalized.keypad_enter_pressed
    return normalized
end

function module.read_current_state()
    if EditorPreviewInput.should_override_runtime_input() then
        return module.normalize_state(_build_editor_preview_state(EditorPreviewInput.get_runtime_host_state()))
    end
    return module.normalize_state(_read_native_state())
end

function module.make_empty_capture_result()
    return
    {
        pointer_pressed_consumed = false,
        pointer_released_consumed = false,
        wheel_consumed = false,
        submit_consumed = false,
        focused_widget_id = nil,
        hovered_widget_id = nil,
    }
end

function module.normalize_capture_result(capture_result)
    local source = type(capture_result) == "table" and capture_result or {}
    return
    {
        pointer_pressed_consumed = source.pointer_pressed_consumed == true,
        pointer_released_consumed = source.pointer_released_consumed == true,
        wheel_consumed = source.wheel_consumed == true,
        submit_consumed = source.submit_consumed == true,
        focused_widget_id = source.focused_widget_id,
        hovered_widget_id = source.hovered_widget_id,
    }
end

return module

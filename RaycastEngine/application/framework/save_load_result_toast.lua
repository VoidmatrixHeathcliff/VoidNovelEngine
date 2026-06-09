local rl = Engine.Raylib

local GlobalContext = require("application.framework.global_context")
local TextWrapper = require("application.framework.text_wrapper")

local module = {}

local duration <const> = 2.4
local fade_in_duration <const> = 0.22
local fade_out_duration <const> = 0.55

local visual_pool =
{
    save_success =
    {
        text = "保存成功",
        foreground = {r = 52, g = 211, b = 92},
        background = {r = 6, g = 26, b = 14},
        icon = "check",
    },
    save_failed =
    {
        text = "保存失败",
        foreground = {r = 255, g = 99, b = 99},
        background = {r = 34, g = 12, b = 12},
        icon = "cross",
    },
    load_success =
    {
        text = "读档成功",
        foreground = {r = 52, g = 211, b = 92},
        background = {r = 6, g = 26, b = 14},
        icon = "check",
    },
    load_failed =
    {
        text = "读档失败",
        foreground = {r = 255, g = 99, b = 99},
        background = {r = 34, g = 12, b = 12},
        icon = "cross",
    },
}

local state =
{
    active = false,
    elapsed = duration,
    kind = "save_success",
    text_wrapper = nil,
    text_font_size = nil,
    text_key = nil,
}

local function _clamp(value, min_value, max_value)
    return math.min(math.max(value, min_value), max_value)
end

local function _smoothstep(value)
    local t = _clamp(value, 0, 1)
    return t * t * (3 - 2 * t)
end

local function _alpha()
    if not state.active then
        return 0
    end
    if state.elapsed <= fade_in_duration then
        return _smoothstep(state.elapsed / fade_in_duration)
    end
    local fade_out_start = duration - fade_out_duration
    if state.elapsed >= fade_out_start then
        return _smoothstep((duration - state.elapsed) / fade_out_duration)
    end
    return 1
end

local function _make_color(r, g, b, alpha)
    return rl.Color(r, g, b, _clamp(math.floor((alpha or 1) * 255 + 0.5), 0, 255))
end

local function _dispose_text()
    if state.text_wrapper and state.text_wrapper.dispose then
        state.text_wrapper:dispose()
    end
    state.text_wrapper = nil
    state.text_font_size = nil
    state.text_key = nil
end

local function _get_visual()
    return visual_pool[state.kind] or visual_pool.save_success
end

local function _ensure_text_wrapper(visual)
    local canvas_height = tonumber(GlobalContext.height_game_window) or 1080
    local font_size = _clamp(math.floor(canvas_height * 0.026 + 0.5), 18, 34)
    local text_key = string.format("%s:%d", visual.text, font_size)
    if state.text_wrapper and state.text_font_size == font_size and state.text_key == text_key then
        return state.text_wrapper
    end

    _dispose_text()
    if not GlobalContext.font_wrapper_sdl then
        return nil
    end

    state.text_wrapper = TextWrapper.new(
        GlobalContext.font_wrapper_sdl,
        visual.text,
        {r = visual.foreground.r, g = visual.foreground.g, b = visual.foreground.b, a = 255},
        nil,
        font_size)
    state.text_font_size = font_size
    state.text_key = text_key
    return state.text_wrapper
end

local function _draw_background(rect, visual, alpha)
    local bg = visual.background
    local background = _make_color(bg.r, bg.g, bg.b, alpha * 0.78)
    if type(rl.DrawRectangleRounded) == "function" then
        rl.DrawRectangleRounded(rect, 0.24, 12, background)
    else
        rl.DrawRectangle(rect.x, rect.y, rect.width, rect.height, background)
    end
end

local function _draw_status_icon(x, y, size, visual, alpha)
    local fg = visual.foreground
    local color = _make_color(fg.r, fg.g, fg.b, alpha)
    local center = rl.Vector2(x + size * 0.5, y + size * 0.5)
    local thickness = math.max(2, size * 0.11)

    rl.DrawRing(center, size * 0.39, size * 0.48, 0, 360, 40, color)
    if visual.icon == "cross" then
        rl.DrawLineEx(
            rl.Vector2(x + size * 0.32, y + size * 0.32),
            rl.Vector2(x + size * 0.68, y + size * 0.68),
            thickness,
            color)
        rl.DrawLineEx(
            rl.Vector2(x + size * 0.68, y + size * 0.32),
            rl.Vector2(x + size * 0.32, y + size * 0.68),
            thickness,
            color)
        return
    end

    rl.DrawLineEx(
        rl.Vector2(x + size * 0.27, y + size * 0.53),
        rl.Vector2(x + size * 0.43, y + size * 0.68),
        thickness,
        color)
    rl.DrawLineEx(
        rl.Vector2(x + size * 0.43, y + size * 0.68),
        rl.Vector2(x + size * 0.75, y + size * 0.33),
        thickness,
        color)
end

local function _notify(kind)
    state.active = true
    state.elapsed = 0
    state.kind = visual_pool[kind] and kind or "save_success"
end

function module.notify_saved()
    _notify("save_success")
end

function module.notify_save_failed()
    _notify("save_failed")
end

function module.notify_loaded()
    _notify("load_success")
end

function module.notify_load_failed()
    _notify("load_failed")
end

function module.update(delta)
    if not state.active then
        return
    end

    state.elapsed = state.elapsed + math.max(0, tonumber(delta) or 0)
    if state.elapsed >= duration then
        state.active = false
        state.elapsed = duration
    end
end

function module.render()
    local alpha = _alpha()
    if alpha <= 0 then
        return
    end

    local visual = _get_visual()
    local text_wrapper = _ensure_text_wrapper(visual)
    if not text_wrapper or not text_wrapper.texture then
        return
    end

    local canvas_width = tonumber(GlobalContext.width_game_window) or 1920
    local canvas_height = tonumber(GlobalContext.height_game_window) or 1080
    local margin = _clamp(math.floor(canvas_width * 0.018 + 0.5), 18, 36)
    local padding_x = _clamp(math.floor(canvas_width * 0.0075 + 0.5), 10, 16)
    local padding_y = _clamp(math.floor(canvas_height * 0.0075 + 0.5), 7, 12)
    local icon_size = _clamp(math.floor((state.text_font_size or 28) * 1.05 + 0.5), 20, 34)
    local gap = _clamp(math.floor(icon_size * 0.36 + 0.5), 7, 12)

    local content_height = math.max(icon_size, text_wrapper.h)
    local width = padding_x * 2 + icon_size + gap + text_wrapper.w
    local height = padding_y * 2 + content_height
    local x = math.max(margin, canvas_width - margin - width)
    local y = margin

    _draw_background(rl.Rectangle(x, y, width, height), visual, alpha)
    _draw_status_icon(x + padding_x, y + padding_y + (content_height - icon_size) * 0.5, icon_size, visual, alpha)

    local text_x = x + padding_x + icon_size + gap
    local text_y = y + padding_y + (content_height - text_wrapper.h) * 0.5
    rl.DrawTextureV(text_wrapper.texture, rl.Vector2(text_x, text_y), _make_color(255, 255, 255, alpha))
end

function module.shutdown()
    _dispose_text()
    state.active = false
    state.elapsed = duration
    state.kind = "save_success"
end

return module

local imgui = Engine.ImGUI

local EditorThemeManager = require("application.framework.editor_theme_manager")
local GlobalContext = require("application.framework.global_context")

local module = {}

local function _make_color(r, g, b, a)
    return imgui.ImVec4(imgui.ImColor(r, g, b, a or 255).value)
end

local function _copy_color(color, fallback)
    if color then
        return imgui.ImVec4(color)
    end
    if fallback then
        return imgui.ImVec4(fallback)
    end
    return _make_color(255, 255, 255, 255)
end

local function _clamp01(value)
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function _mix_color(left, right, factor)
    local lhs = _copy_color(left)
    local rhs = _copy_color(right)
    local t = _clamp01(factor or 0)
    local inv = 1 - t
    return imgui.ImVec4(
        lhs.x * inv + rhs.x * t,
        lhs.y * inv + rhs.y * t,
        lhs.z * inv + rhs.z * t,
        lhs.w * inv + rhs.w * t)
end

local function _with_alpha(color, alpha)
    local value = _copy_color(color)
    return imgui.ImVec4(value.x, value.y, value.z, _clamp01(alpha or value.w or 1))
end

module.build = function(editor_zoom_ratio)
    local zoom = tonumber(editor_zoom_ratio) or 1.0
    local current_theme = EditorThemeManager.get_current_theme and EditorThemeManager.get_current_theme() or {}
    local is_light = current_theme and current_theme.base_style == "light"

    local accent_primary = _copy_color(EditorThemeManager.get_token("accent_primary"), _make_color(79, 127, 196, 255))
    local accent_success = _copy_color(EditorThemeManager.get_token("accent_success"), _make_color(104, 190, 141, 255))
    local accent_warning = _copy_color(EditorThemeManager.get_token("accent_warning"), _make_color(248, 181, 0, 255))
    local accent_danger = _copy_color(EditorThemeManager.get_token("accent_danger"), _make_color(197, 61, 67, 255))
    local bg_0 = _copy_color(EditorThemeManager.get_token("bg_0"), is_light and _make_color(244, 247, 250, 255) or _make_color(18, 22, 28, 255))
    local bg_1 = _copy_color(EditorThemeManager.get_token("bg_1"), is_light and _make_color(251, 252, 254, 255) or _make_color(24, 28, 36, 255))
    local bg_2 = _copy_color(EditorThemeManager.get_token("bg_2"), is_light and _make_color(234, 239, 245, 255) or _make_color(34, 40, 50, 255))
    local fg = _copy_color(EditorThemeManager.get_token("fg"), is_light and _make_color(37, 42, 48, 255) or _make_color(232, 236, 242, 255))
    local fg_muted = _copy_color(EditorThemeManager.get_token("fg_muted"), is_light and _make_color(112, 121, 132, 255) or _make_color(150, 160, 175, 255))
    local border = _copy_color(EditorThemeManager.get_token("border"), is_light and _make_color(193, 203, 214, 255) or _make_color(62, 70, 82, 255))

    return
    {
        body_font = GlobalContext.font_imgui,
        code_font = GlobalContext.font_imgui_code or GlobalContext.font_imgui,
        title_font_size = math.max(20, math.floor(20 * zoom + 0.5)),
        section_title_font_size = math.max(14, math.floor(14 * zoom + 0.5)),
        small_font_size = math.max(13, math.floor(13 * zoom + 0.5)),
        body_font_size = math.max(16, math.floor(16 * zoom + 0.5)),
        code_font_size = math.max(15, math.floor(15 * zoom + 0.5)),
        compact_code_font_size = math.max(13, math.floor(13 * zoom + 0.5)),
        max_width = math.max(460, math.floor(520 * zoom + 0.5)),
        colors =
        {
            text = fg,
            text_emphasis = _mix_color(fg, accent_primary, is_light and 0.18 or 0.10),
            muted = fg_muted,
            accent = accent_primary,
            success = accent_success,
            warning = accent_warning,
            danger = accent_danger,
            link = _mix_color(accent_primary, fg, is_light and 0.08 or 0.02),
            border = border,
            panel_bg = _mix_color(bg_1, bg_2, 0.58),
            section_bg = _mix_color(bg_0, bg_2, is_light and 0.55 or 0.30),
            code_bg = _mix_color(bg_0, accent_primary, is_light and 0.06 or 0.10),
            code_border = _with_alpha(_mix_color(border, accent_primary, 0.24), is_light and 0.92 or 0.72),
            kbd_bg = _mix_color(bg_0, accent_primary, is_light and 0.18 or 0.24),
            kbd_border = _with_alpha(_mix_color(border, accent_primary, 0.46), is_light and 0.94 or 0.82),
            note_bg = _mix_color(bg_0, accent_primary, is_light and 0.10 or 0.14),
            note_border = _with_alpha(_mix_color(border, accent_primary, 0.34), is_light and 0.90 or 0.74),
            tip_bg = _mix_color(bg_0, accent_success, is_light and 0.12 or 0.18),
            tip_border = _with_alpha(_mix_color(border, accent_success, 0.40), is_light and 0.92 or 0.78),
            warning_bg = _mix_color(bg_0, accent_warning, is_light and 0.12 or 0.18),
            warning_border = _with_alpha(_mix_color(border, accent_warning, 0.42), is_light and 0.92 or 0.78),
            danger_bg = _mix_color(bg_0, accent_danger, is_light and 0.12 or 0.18),
            danger_border = _with_alpha(_mix_color(border, accent_danger, 0.44), is_light and 0.92 or 0.80),
            header_chip_bg = _mix_color(bg_0, bg_2, is_light and 0.62 or 0.34),
            header_chip_border = _with_alpha(_mix_color(border, fg_muted, is_light and 0.12 or 0.10), is_light and 0.88 or 0.74),
            header_chip_text = _mix_color(fg, fg_muted, is_light and 0.12 or 0.04),
            category_chip_bg = _mix_color(bg_0, accent_primary, is_light and 0.14 or 0.18),
            category_chip_border = _with_alpha(_mix_color(border, accent_primary, 0.44), is_light and 0.92 or 0.78),
            category_chip_text = _mix_color(accent_primary, fg, is_light and 0.06 or 0.04),
            special_chip_bg = _mix_color(bg_0, accent_warning, is_light and 0.14 or 0.20),
            special_chip_border = _with_alpha(_mix_color(border, accent_warning, 0.46), is_light and 0.92 or 0.80),
            special_chip_text = _mix_color(accent_warning, fg, is_light and 0.08 or 0.04),
        },
        spacing =
        {
            section_gap = math.max(8, math.floor(8 * zoom + 0.5)),
            tight_gap = math.max(1, math.floor(1 * zoom + 0.5)),
            item_gap = math.max(4, math.floor(4 * zoom + 0.5)),
            line_gap = math.max(3, math.floor(3 * zoom + 0.5)),
            inline_gap = math.max(2, math.floor(2 * zoom + 0.5)),
            code_panel_gap = math.max(6, math.floor(6 * zoom + 0.5)),
            compact_gap = math.max(2, math.floor(2 * zoom + 0.5)),
            chip_gap = math.max(6, math.floor(6 * zoom + 0.5)),
            code_header_gap = math.max(1, math.floor(1 * zoom + 0.5)),
        },
        metrics =
        {
            chip_rounding = math.max(4, math.floor(4 * zoom + 0.5)),
            inline_code_pad_x = math.max(4, math.floor(4 * zoom + 0.5)),
            inline_code_pad_y = math.max(2, math.floor(2 * zoom + 0.5)),
            inline_kbd_pad_x = math.max(5, math.floor(5 * zoom + 0.5)),
            inline_kbd_pad_y = math.max(2, math.floor(2 * zoom + 0.5)),
            code_block_pad_x = math.max(10, math.floor(10 * zoom + 0.5)),
            code_block_pad_y = math.max(3, math.floor(3 * zoom + 0.5)),
            compact_code_block_pad_x = math.max(8, math.floor(8 * zoom + 0.5)),
            compact_code_block_pad_y = math.max(1, math.floor(1 * zoom + 0.5)),
            header_chip_pad_x = math.max(8, math.floor(8 * zoom + 0.5)),
            header_chip_pad_y = math.max(3, math.floor(3 * zoom + 0.5)),
            note_icon_size = math.max(15, math.floor(15 * zoom + 0.5)),
            section_icon_size = math.max(14, math.floor(14 * zoom + 0.5)),
            underline_thickness = math.max(1, math.floor(1 * zoom + 0.5)),
            underline_offset = math.max(1, math.floor(1 * zoom + 0.5)),
        },
    }
end

return module

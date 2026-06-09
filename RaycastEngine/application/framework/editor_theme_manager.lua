local imgui = Engine.ImGUI

local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")
local EditorThemePresets = require("application.framework.editor_theme_presets")

local module = {}

local current_color_id = nil
local current_style_id = nil
local current_theme = nil
local current_style_preset = nil
local current_tokens = {}
local current_semantic = {}
local has_style_preset_api = type(imgui.StyleColorsDark) == "function"
    and type(imgui.StyleColorsLight) == "function"
    and type(imgui.StyleColorsClassic) == "function"
local has_set_style_color_api = type(imgui.SetStyleColor) == "function"
local has_node_editor_style_api = type(imgui.NodeEditor) == "table"
    and type(imgui.NodeEditor.SetCurrentEditor) == "function"
    and type(imgui.NodeEditor.SetStyleColor) == "function"
    and type(imgui.NodeEditor.StyleColor) == "table"
local has_node_editor_style_var_api = type(imgui.NodeEditor) == "table"
    and type(imgui.NodeEditor.SetStyleVar) == "function"
    and type(imgui.NodeEditor.StyleVar) == "table"

local function _clamp01(value)
    if value < 0 then
        return 0
    end
    if value > 1 then
        return 1
    end
    return value
end

local function _copy_color(color)
    if not color then
        return imgui.ImVec4(1, 1, 1, 1)
    end
    return imgui.ImVec4(color)
end

local function _make_color(r, g, b, a)
    return imgui.ImVec4(imgui.ImColor(r, g, b, a or 255).value)
end

local on_light_surface_text = _make_color(26, 30, 36, 255)
local on_dark_surface_text = _make_color(247, 249, 252, 255)
local _hex_to_color = nil

local function _make_vec2(value, fallback_x, fallback_y)
    if type(value) == "table" then
        return imgui.ImVec2(tonumber(value.x or value[1]) or fallback_x or 0, tonumber(value.y or value[2]) or fallback_y or 0)
    end
    return imgui.ImVec2(fallback_x or 0, fallback_y or 0)
end

local function _make_color_from_array(value)
    if type(value) == "string" then
        return _hex_to_color and _hex_to_color(value) or nil
    end
    if type(value) ~= "table" then
        return nil
    end
    return imgui.ImVec4(
        tonumber(value.r or value[1]) or 1,
        tonumber(value.g or value[2]) or 1,
        tonumber(value.b or value[3]) or 1,
        tonumber(value.a or value[4]) or 1)
end

local imgui_color_alias =
{
    TabActive = "TabSelected",
    TabUnfocused = "TabDimmed",
    TabUnfocusedActive = "TabDimmedSelected",
    NavHighlight = "NavCursor",
}

local function _resolve_imgui_color_id(name)
    if type(name) ~= "string" or type(imgui.ImGuiCol) ~= "table" then
        return nil
    end
    local alias = imgui_color_alias[name]
    return imgui.ImGuiCol[name] or (alias and imgui.ImGuiCol[alias] or nil)
end

local function _apply_imgui_color_overrides(colors, overrides)
    if type(colors) ~= "table" or type(overrides) ~= "table" then
        return
    end
    for name, value in pairs(overrides) do
        local color_id = _resolve_imgui_color_id(name)
        local color = _make_color_from_array(value)
        if color_id and color then
            colors[color_id] = color
        end
    end
end

local function _resolve_hex_digit(ch)
    local byte = string.byte(ch)
    if byte >= string.byte("0") and byte <= string.byte("9") then
        return byte - string.byte("0")
    end
    if byte >= string.byte("a") and byte <= string.byte("f") then
        return 10 + byte - string.byte("a")
    end
    if byte >= string.byte("A") and byte <= string.byte("F") then
        return 10 + byte - string.byte("A")
    end
    return 0
end

local function _parse_hex_pair(high, low)
    return _resolve_hex_digit(high) * 16 + _resolve_hex_digit(low)
end

_hex_to_color = function(hex, alpha_override)
    if type(hex) ~= "string" then
        return _make_color(255, 255, 255, alpha_override or 255)
    end

    local normalized = hex:gsub("#", "")
    if #normalized ~= 6 and #normalized ~= 8 then
        return _make_color(255, 255, 255, alpha_override or 255)
    end

    local r = _parse_hex_pair(normalized:sub(1, 1), normalized:sub(2, 2))
    local g = _parse_hex_pair(normalized:sub(3, 3), normalized:sub(4, 4))
    local b = _parse_hex_pair(normalized:sub(5, 5), normalized:sub(6, 6))
    local a = #normalized == 8 and _parse_hex_pair(normalized:sub(7, 7), normalized:sub(8, 8)) or 255
    if alpha_override ~= nil then
        a = alpha_override
    end

    return _make_color(r, g, b, a)
end

local function _mix_color(left, right, factor)
    local t = _clamp01(factor or 0)
    local inv = 1 - t
    return imgui.ImVec4(
        left.x * inv + right.x * t,
        left.y * inv + right.y * t,
        left.z * inv + right.z * t,
        left.w * inv + right.w * t)
end

local function _color_with_alpha(color, alpha)
    return imgui.ImVec4(color.x, color.y, color.z, _clamp01(alpha or color.w or 1))
end

local function _linearize_srgb_channel(value)
    local channel = _clamp01(tonumber(value) or 0)
    if channel <= 0.03928 then
        return channel / 12.92
    end
    return ((channel + 0.055) / 1.055) ^ 2.4
end

local function _get_color_luminance(color)
    if not color then
        return 1
    end

    return _linearize_srgb_channel(color.x) * 0.2126
        + _linearize_srgb_channel(color.y) * 0.7152
        + _linearize_srgb_channel(color.z) * 0.0722
end

local function _get_contrast_ratio(left_luminance, right_luminance)
    local lighter = math.max(left_luminance or 0, right_luminance or 0)
    local darker = math.min(left_luminance or 0, right_luminance or 0)
    return (lighter + 0.05) / (darker + 0.05)
end

local function _resolve_on_color(background_color)
    local background_luminance = _get_color_luminance(background_color)
    local light_text_contrast = _get_contrast_ratio(background_luminance, _get_color_luminance(on_dark_surface_text))
    local dark_text_contrast = _get_contrast_ratio(background_luminance, _get_color_luminance(on_light_surface_text))

    if light_text_contrast >= 3.0 and background_luminance <= 0.42 then
        return _copy_color(on_dark_surface_text)
    end
    if dark_text_contrast >= 3.0 then
        return _copy_color(on_light_surface_text)
    end
    return _copy_color(light_text_contrast >= dark_text_contrast and on_dark_surface_text or on_light_surface_text)
end

local function _resolve_secondary_on_color(background_color)
    local primary = _resolve_on_color(background_color)
    return _mix_color(primary, background_color or _make_color(0, 0, 0, 255), 0.34)
end

local function _apply_base_style(base_style)
    if not has_style_preset_api then
        return
    end

    if base_style == "light" then
        imgui.StyleColorsLight()
    elseif base_style == "classic" then
        imgui.StyleColorsClassic()
    else
        imgui.StyleColorsDark()
    end
end

local function _compile_node_editor_colors(tokens, is_light)
    if not has_node_editor_style_api then
        return {}
    end

    local style_color = imgui.NodeEditor.StyleColor
    return
    {
        [style_color.Bg] = tokens.node_canvas_bg,
        [style_color.Grid] = tokens.node_grid,
        [style_color.NodeBg] = tokens.node_bg,
        [style_color.NodeBorder] = tokens.node_border,
        [style_color.HoveredNodeBorder] = _copy_color(tokens.node_hover_highlight),
        [style_color.SelectedNodeBorder] = _copy_color(tokens.node_select_highlight),
        [style_color.NodeSelectionRect] = _color_with_alpha(tokens.node_selection_rect, is_light and 0.16 or 0.18),
        [style_color.NodeSelectionRectBorder] = _color_with_alpha(tokens.node_selection_rect, is_light and 0.88 or 0.92),
        [style_color.HoveredLinkBorder] = _color_with_alpha(tokens.node_hover_highlight, is_light and 0.82 or 0.90),
        [style_color.SelectedLinkBorder] = _color_with_alpha(tokens.node_select_highlight, is_light and 0.88 or 0.94),
        [style_color.HighlightLinkBorder] = _color_with_alpha(tokens.flow_animation, is_light and 0.88 or 0.94),
        [style_color.LinkSelectionRect] = _color_with_alpha(tokens.node_selection_rect, is_light and 0.12 or 0.16),
        [style_color.LinkSelectionRectBorder] = _color_with_alpha(tokens.node_selection_rect, is_light and 0.48 or 0.58),
        [style_color.PinRect] = _color_with_alpha(tokens.border, is_light and 0.18 or 0.14),
        [style_color.PinRectBorder] = _color_with_alpha(tokens.border, is_light and 0.42 or 0.36),
        [style_color.Flow] = _color_with_alpha(tokens.flow_animation, is_light and 0.94 or 0.98),
        [style_color.FlowMarker] = _copy_color(tokens.flow_animation_marker),
        [style_color.GroupBg] = _color_with_alpha(_mix_color(tokens.node_canvas_bg, tokens.accent_primary, is_light and 0.32 or 0.18), is_light and 0.30 or 0.08),
        [style_color.GroupBorder] = _color_with_alpha(_mix_color(tokens.border, tokens.accent_primary, is_light and 0.26 or 0.10), is_light and 0.82 or 0.36),
    }
end

local function _compile_node_editor_style_vars(is_light)
    if not has_node_editor_style_var_api then
        return {}
    end

    local style_var = imgui.NodeEditor.StyleVar
    return
    {
        [style_var.NodeBorderWidth] = is_light and 1.8 or 1.7,
        [style_var.HoveredNodeBorderWidth] = is_light and 6.2 or 5.8,
        [style_var.SelectedNodeBorderWidth] = is_light and 7.0 or 6.6,
        [style_var.HoveredNodeBorderOffset] = 0.0,
        [style_var.SelectedNodeBorderOffset] = 0.0,
    }
end

local function _compile_theme(color_preset, style_preset)
    local theme = color_preset or {}
    local style_mode = theme.base_style or "dark"
    local is_light = style_mode == "light"
    local token_defs = theme.tokens or {}
    local style_metrics = type(style_preset) == "table" and type(style_preset.metrics) == "table" and style_preset.metrics or {}

    local tokens =
    {
        bg_0 = _hex_to_color(token_defs.bg_0),
        bg_1 = _hex_to_color(token_defs.bg_1),
        bg_2 = _hex_to_color(token_defs.bg_2),
        bg_3 = _hex_to_color(token_defs.bg_3),
        fg = _hex_to_color(token_defs.fg),
        fg_muted = _hex_to_color(token_defs.fg_muted),
        border = _hex_to_color(token_defs.border),
        accent_primary = _hex_to_color(token_defs.accent_primary),
        accent_secondary = _hex_to_color(token_defs.accent_secondary),
        flow_pin = _hex_to_color(token_defs.flow_pin),
        accent_success = token_defs.accent_success and _hex_to_color(token_defs.accent_success) or _make_color(69, 178, 107, 255),
        accent_warning = token_defs.accent_warning and _hex_to_color(token_defs.accent_warning) or _make_color(232, 176, 72, 255),
        accent_danger = token_defs.accent_danger and _hex_to_color(token_defs.accent_danger) or _make_color(214, 72, 88, 255),
    }

    tokens.flow_link = token_defs.flow_link and _hex_to_color(token_defs.flow_link) or _copy_color(tokens.flow_pin)
    tokens.selection = token_defs.selection and _hex_to_color(token_defs.selection) or _color_with_alpha(tokens.accent_primary, is_light and 0.20 or 0.24)
    tokens.modal_overlay = token_defs.modal_overlay and _hex_to_color(token_defs.modal_overlay) or _make_color(0, 0, 0, is_light and 168 or 184)
    tokens.modal_panel_bg = token_defs.modal_panel_bg and _hex_to_color(token_defs.modal_panel_bg) or _copy_color(tokens.bg_1)
    tokens.modal_panel_border = token_defs.modal_panel_border and _hex_to_color(token_defs.modal_panel_border) or _copy_color(tokens.border)
    tokens.console_bg = token_defs.console_bg and _hex_to_color(token_defs.console_bg)
        or (is_light and _mix_color(tokens.bg_1, tokens.bg_3, 0.28) or _mix_color(tokens.bg_1, tokens.bg_0, 0.32))
    tokens.ui_icon = token_defs.ui_icon and _hex_to_color(token_defs.ui_icon)
        or _mix_color(tokens.fg, tokens.accent_primary, is_light and 0.08 or 0.12)
    tokens.ui_icon_disabled = token_defs.ui_icon_disabled and _hex_to_color(token_defs.ui_icon_disabled)
        or _mix_color(tokens.fg_muted, tokens.bg_2, is_light and 0.28 or 0.24)
    tokens.node_comment = token_defs.node_comment and _hex_to_color(token_defs.node_comment)
        or _mix_color(tokens.fg_muted, tokens.fg, is_light and 0.12 or 0.08)
    tokens.node_canvas_bg = token_defs.node_canvas_bg and _hex_to_color(token_defs.node_canvas_bg)
        or (is_light and _mix_color(tokens.bg_0, tokens.bg_3, 0.45) or _mix_color(tokens.bg_0, tokens.bg_1, 0.30))
    tokens.node_grid = token_defs.node_grid and _hex_to_color(token_defs.node_grid)
        or _color_with_alpha(_mix_color(tokens.border, tokens.accent_primary, is_light and 0.05 or 0.03), is_light and 0.24 or 0.14)
    local node_bg_alpha = is_light and 0.96 or 0.94
    local base_node_bg = token_defs.node_bg and _hex_to_color(token_defs.node_bg)
        or (is_light and _mix_color(tokens.bg_1, _make_color(255, 255, 255, 255), 0.40) or _mix_color(tokens.bg_2, tokens.bg_1, 0.25))
    tokens.node_bg = _color_with_alpha(base_node_bg, math.min(node_bg_alpha, base_node_bg.w or 1))
    tokens.node_border = token_defs.node_border and _hex_to_color(token_defs.node_border)
        or _mix_color(tokens.border, tokens.bg_3, is_light and 0.10 or 0.06)
    tokens.node_border_hovered = token_defs.node_border_hovered and _hex_to_color(token_defs.node_border_hovered)
        or _mix_color(tokens.node_border, tokens.accent_primary, is_light and 0.74 or 0.66)
    tokens.node_border_selected = token_defs.node_border_selected and _hex_to_color(token_defs.node_border_selected)
        or _mix_color(tokens.node_border, tokens.accent_secondary, is_light and 0.90 or 0.84)
    tokens.node_hover_highlight = token_defs.node_hover_highlight and _hex_to_color(token_defs.node_hover_highlight)
        or _mix_color(_make_color(50, 176, 255, 255), tokens.accent_primary, is_light and 0.18 or 0.26)
    tokens.node_select_highlight = token_defs.node_select_highlight and _hex_to_color(token_defs.node_select_highlight)
        or _mix_color(_make_color(255, 176, 50, 255), tokens.accent_secondary, is_light and 0.12 or 0.20)
    tokens.node_selection_rect = token_defs.node_selection_rect and _hex_to_color(token_defs.node_selection_rect)
        or _mix_color(_make_color(5, 130, 255, 255), tokens.accent_primary, is_light and 0.10 or 0.18)
    tokens.flow_animation = token_defs.flow_animation and _hex_to_color(token_defs.flow_animation)
        or _mix_color(_make_color(255, 128, 64, 255), tokens.accent_warning, is_light and 0.14 or 0.24)
    tokens.flow_animation_marker = token_defs.flow_animation_marker and _hex_to_color(token_defs.flow_animation_marker)
        or _mix_color(tokens.flow_animation, _make_color(255, 245, 230, 255), is_light and 0.26 or 0.14)
    tokens.tab_soft_border = token_defs.tab_soft_border and _hex_to_color(token_defs.tab_soft_border) or nil

    local colors =
    {
        [imgui.ImGuiCol.Text] = tokens.fg,
        [imgui.ImGuiCol.TextDisabled] = tokens.fg_muted,
        [imgui.ImGuiCol.WindowBg] = tokens.bg_1,
        [imgui.ImGuiCol.ChildBg] = tokens.bg_1,
        [imgui.ImGuiCol.PopupBg] = tokens.bg_2,
        [imgui.ImGuiCol.Border] = tokens.border,
        [imgui.ImGuiCol.FrameBg] = tokens.bg_2,
        [imgui.ImGuiCol.FrameBgHovered] = _mix_color(tokens.bg_2, tokens.accent_primary, is_light and 0.12 or 0.15),
        [imgui.ImGuiCol.FrameBgActive] = _mix_color(tokens.bg_2, tokens.accent_primary, is_light and 0.20 or 0.26),
        [imgui.ImGuiCol.TitleBg] = tokens.bg_0,
        [imgui.ImGuiCol.TitleBgActive] = _mix_color(tokens.bg_1, tokens.accent_primary, is_light and 0.10 or 0.14),
        [imgui.ImGuiCol.TitleBgCollapsed] = _color_with_alpha(tokens.bg_0, 0.88),
        [imgui.ImGuiCol.MenuBarBg] = tokens.bg_0,
        [imgui.ImGuiCol.ScrollbarBg] = tokens.bg_0,
        [imgui.ImGuiCol.ScrollbarGrab] = tokens.bg_3,
        [imgui.ImGuiCol.ScrollbarGrabHovered] = _mix_color(tokens.bg_3, tokens.accent_primary, is_light and 0.24 or 0.30),
        [imgui.ImGuiCol.ScrollbarGrabActive] = _mix_color(tokens.bg_3, tokens.accent_primary, is_light and 0.36 or 0.44),
        [imgui.ImGuiCol.CheckMark] = tokens.accent_primary,
        [imgui.ImGuiCol.SliderGrab] = tokens.accent_primary,
        [imgui.ImGuiCol.SliderGrabActive] = _mix_color(tokens.accent_primary, tokens.accent_secondary, 0.20),
        [imgui.ImGuiCol.Button] = _mix_color(tokens.bg_2, tokens.accent_primary, is_light and 0.16 or 0.22),
        [imgui.ImGuiCol.ButtonHovered] = _mix_color(tokens.bg_3, tokens.accent_primary, is_light and 0.28 or 0.42),
        [imgui.ImGuiCol.ButtonActive] = _mix_color(tokens.bg_3, tokens.accent_primary, is_light and 0.40 or 0.62),
        [imgui.ImGuiCol.Header] = _mix_color(tokens.bg_2, tokens.accent_primary, is_light and 0.10 or 0.16),
        [imgui.ImGuiCol.HeaderHovered] = _mix_color(tokens.bg_2, tokens.accent_primary, is_light and 0.18 or 0.26),
        [imgui.ImGuiCol.HeaderActive] = _mix_color(tokens.bg_3, tokens.accent_primary, is_light and 0.26 or 0.36),
        [imgui.ImGuiCol.Separator] = tokens.border,
        [imgui.ImGuiCol.SeparatorHovered] = _mix_color(tokens.border, tokens.accent_primary, 0.45),
        [imgui.ImGuiCol.SeparatorActive] = _mix_color(tokens.border, tokens.accent_primary, 0.65),
        [imgui.ImGuiCol.ResizeGrip] = _color_with_alpha(tokens.accent_primary, is_light and 0.22 or 0.18),
        [imgui.ImGuiCol.ResizeGripHovered] = _color_with_alpha(tokens.accent_primary, is_light and 0.52 or 0.45),
        [imgui.ImGuiCol.ResizeGripActive] = _color_with_alpha(tokens.accent_primary, is_light and 0.75 or 0.70),
        [imgui.ImGuiCol.Tab] = tokens.bg_2,
        [imgui.ImGuiCol.TabHovered] = _mix_color(tokens.bg_2, tokens.accent_primary, is_light and 0.18 or 0.30),
        [imgui.ImGuiCol.TabSelected] = _mix_color(tokens.bg_2, tokens.accent_primary, is_light and 0.28 or 0.50),
        [imgui.ImGuiCol.TabSelectedOverline] = tokens.accent_primary,
        [imgui.ImGuiCol.TabDimmed] = tokens.bg_0,
        [imgui.ImGuiCol.TabDimmedSelected] = _mix_color(tokens.bg_1, tokens.accent_primary, is_light and 0.15 or 0.22),
        [imgui.ImGuiCol.TabDimmedSelectedOverline] = _color_with_alpha(tokens.accent_primary, 0.65),
        [imgui.ImGuiCol.DockingPreview] = _color_with_alpha(tokens.accent_primary, 0.72),
        [imgui.ImGuiCol.DockingEmptyBg] = tokens.bg_0,
        [imgui.ImGuiCol.TableHeaderBg] = tokens.bg_2,
        [imgui.ImGuiCol.TableRowBgAlt] = _color_with_alpha(_mix_color(tokens.bg_1, tokens.accent_primary, 0.04), is_light and 0.12 or 0.10),
        [imgui.ImGuiCol.TextLink] = tokens.accent_secondary,
        [imgui.ImGuiCol.TextSelectedBg] = tokens.selection,
        [imgui.ImGuiCol.NavCursor] = tokens.accent_primary,
        [imgui.ImGuiCol.ModalWindowDimBg] = tokens.modal_overlay,
    }
    _apply_imgui_color_overrides(colors, theme.imgui_colors)
    colors[imgui.ImGuiCol.TextSelectedBg] = _make_color(0, 0, 0, 220)

    local style = {}
    for key, value in pairs(style_metrics) do
        style[key] = value
    end

    local semantic =
    {
        flow_pin = tokens.flow_pin,
        flow_link = tokens.flow_link,
        console_bg = tokens.console_bg,
        modal_overlay = tokens.modal_overlay,
        modal_panel_bg = tokens.modal_panel_bg,
        modal_panel_border = tokens.modal_panel_border,
        tab_soft_border = tokens.tab_soft_border
            or _color_with_alpha(_mix_color(tokens.border, tokens.accent_warning or tokens.accent_primary, 0.50), is_light and 0.62 or 0.54),
        ui_icon = tokens.ui_icon,
        ui_icon_disabled = tokens.ui_icon_disabled,
        node_comment = tokens.node_comment,
        node_editor = _compile_node_editor_colors(tokens, is_light),
        node_editor_style_vars = _compile_node_editor_style_vars(is_light),
        input_frame =
        {
            frame = colors[imgui.ImGuiCol.FrameBg],
            hovered = colors[imgui.ImGuiCol.FrameBgHovered],
            active = colors[imgui.ImGuiCol.FrameBgActive],
        },
        red_button =
        {
            button = _mix_color(tokens.bg_2, tokens.accent_danger, is_light and 0.20 or 0.24),
            hovered = _mix_color(tokens.bg_3, tokens.accent_danger, is_light and 0.34 or 0.42),
            active = _mix_color(tokens.bg_3, tokens.accent_danger, is_light and 0.48 or 0.60),
        },
        green_button =
        {
            button = _mix_color(tokens.bg_2, tokens.accent_success, is_light and 0.18 or 0.22),
            hovered = _mix_color(tokens.bg_3, tokens.accent_success, is_light and 0.30 or 0.38),
            active = _mix_color(tokens.bg_3, tokens.accent_success, is_light and 0.42 or 0.54),
        },
    }

    return
    {
        tokens = tokens,
        semantic = semantic,
        colors = colors,
        style = style,
    }
end

local function _apply_compiled_theme(theme, compiled)
    _apply_base_style(theme.base_style)

    if has_set_style_color_api then
        for color_id, color in pairs(compiled.colors or {}) do
            imgui.SetStyleColor(color_id, color)
        end
    end

    local style = imgui.GetStyle()
    for key, value in pairs(compiled.style or {}) do
        pcall(function()
            if type(value) == "table" then
                style[key] = _make_vec2(value)
            else
                style[key] = value
            end
        end)
    end
end

local function _sync_flow_pin_definition_color(flow_color)
    local builtin_pin_common = package.loaded["application.framework.builtin_pin_common"]
    if builtin_pin_common and builtin_pin_common.type_color_pool then
        builtin_pin_common.type_color_pool.flow = flow_color
    end

    local pin_registry = package.loaded["application.framework.pin_registry"]
    if pin_registry and pin_registry.get then
        local flow_def = pin_registry.get("flow")
        if flow_def then
            flow_def.color = flow_color
        end
    end
end

local function _broadcast_theme_changed(flow_color)
    for _, blueprint in ipairs(GlobalContext.blueprint_list or {}) do
        if blueprint and blueprint.mark_theme_dirty then
            blueprint:mark_theme_dirty(flow_color)
        end
    end
end

local function _apply_theme(color_id, style_id)
    local normalized_color_id = EditorThemePresets.normalize_color_id and EditorThemePresets.normalize_color_id(color_id) or EditorThemePresets.normalize_id(color_id)
    local normalized_style_id = EditorThemePresets.normalize_style_id and EditorThemePresets.normalize_style_id(style_id) or "classic_compact"
    local theme = EditorThemePresets.get_color and EditorThemePresets.get_color(normalized_color_id) or EditorThemePresets.get(normalized_color_id)
    local style_preset = EditorThemePresets.get_style and EditorThemePresets.get_style(normalized_style_id) or nil
    local compiled = _compile_theme(theme, style_preset)

    _apply_compiled_theme(theme, compiled)

    current_color_id = normalized_color_id
    current_style_id = normalized_style_id
    current_theme = theme
    current_style_preset = style_preset
    current_tokens = compiled.tokens
    current_semantic = compiled.semantic

    _sync_flow_pin_definition_color(current_semantic.flow_pin)
    _broadcast_theme_changed(current_semantic.flow_pin)
    return normalized_color_id, normalized_style_id
end

local function _get_danger_fallback()
    return
    {
        button = _make_color(153, 67, 74, 255),
        hovered = _make_color(176, 78, 86, 255),
        active = _make_color(198, 90, 98, 255),
    }
end

local function _get_success_fallback()
    return
    {
        button = _make_color(74, 145, 92, 255),
        hovered = _make_color(86, 163, 105, 255),
        active = _make_color(100, 181, 120, 255),
    }
end

module.list_presets = function()
    return EditorThemePresets.list_colors and EditorThemePresets.list_colors() or EditorThemePresets.list()
end

module.list_color_presets = function()
    return EditorThemePresets.list_colors and EditorThemePresets.list_colors() or EditorThemePresets.list()
end

module.list_style_presets = function()
    return EditorThemePresets.list_styles and EditorThemePresets.list_styles() or {}
end

module.get_current_theme_id = function()
    return current_color_id or (EditorThemePresets.get_default_color_id and EditorThemePresets.get_default_color_id() or EditorThemePresets.get_default_id())
end

module.get_current_color_id = function()
    return module.get_current_theme_id()
end

module.get_current_style_id = function()
    return current_style_id or (EditorThemePresets.get_default_style_id and EditorThemePresets.get_default_style_id() or "classic_compact")
end

module.get_current_theme = function()
    return current_theme or (EditorThemePresets.get_color and EditorThemePresets.get_color(module.get_current_color_id()) or EditorThemePresets.get(module.get_current_theme_id()))
end

module.get_current_style = function()
    if current_style_preset then
        return current_style_preset
    end
    if EditorThemePresets.get_style then
        return EditorThemePresets.get_style(module.get_current_style_id())
    end
    return nil
end

module.get_token = function(name)
    return current_tokens and current_tokens[name] or nil
end

module.get_flow_pin_color = function()
    return current_semantic.flow_pin or _make_color(255, 255, 255, 255)
end

module.get_flow_link_color = function()
    return current_semantic.flow_link or module.get_flow_pin_color()
end

module.get_console_bg_color = function()
    return current_semantic.console_bg or _make_color(5, 15, 25, 255)
end

module.get_modal_overlay_color = function()
    return current_semantic.modal_overlay or _make_color(0, 0, 0, 196)
end

module.get_modal_panel_bg_color = function()
    return current_semantic.modal_panel_bg or _make_color(28, 30, 34, 245)
end

module.get_modal_panel_border_color = function()
    return current_semantic.modal_panel_border or _make_color(66, 71, 78, 255)
end

module.get_tab_soft_border_color = function()
    return current_semantic.tab_soft_border or module.get_modal_panel_border_color()
end

module.get_icon_tint_color = function(disabled)
    if disabled then
        return current_semantic.ui_icon_disabled or _make_color(146, 150, 158, 255)
    end
    return current_semantic.ui_icon or _make_color(235, 239, 245, 255)
end

module.get_text_on_color = function(background_color)
    return _resolve_on_color(background_color)
end

module.get_secondary_text_on_color = function(background_color)
    return _resolve_secondary_on_color(background_color)
end

module.get_icon_on_color = function(background_color)
    return _resolve_on_color(background_color)
end

module.get_node_comment_color = function()
    return current_semantic.node_comment or _make_color(150, 150, 150, 255)
end

module.get_semantic_button_palette = function(kind)
    if kind == "success" then
        return current_semantic.green_button or _get_success_fallback()
    end
    return current_semantic.red_button or _get_danger_fallback()
end

module.get_input_frame_palette = function()
    local palette = current_semantic.input_frame or {}
    return
    {
        frame = palette.frame or _make_color(36, 44, 54, 255),
        hovered = palette.hovered or _make_color(48, 58, 70, 255),
        active = palette.active or _make_color(58, 70, 84, 255),
    }
end

module.with_alpha = function(color, alpha)
    if not color then
        return _make_color(255, 255, 255, math.floor(_clamp01(alpha or 1) * 255))
    end
    return _color_with_alpha(color, alpha)
end

module.apply_node_editor_theme_to_context = function(editor_context)
    if not has_node_editor_style_api or not editor_context then
        return false
    end

    imgui.NodeEditor.SetCurrentEditor(editor_context)
    for color_id, color in pairs(current_semantic.node_editor or {}) do
        imgui.NodeEditor.SetStyleColor(color_id, color)
    end
    for style_var_id, value in pairs(current_semantic.node_editor_style_vars or {}) do
        imgui.NodeEditor.SetStyleVar(style_var_id, value)
    end
    pcall(function()
        imgui.NodeEditor.SetCurrentEditor(nil)
    end)
    return true
end

module.apply_saved_theme = function()
    local color_id = SettingsManager.get_editor_theme_color_id and SettingsManager.get_editor_theme_color_id()
        or SettingsManager.get_editor_theme_id and SettingsManager.get_editor_theme_id()
        or (EditorThemePresets.get_default_color_id and EditorThemePresets.get_default_color_id() or EditorThemePresets.get_default_id())
    local style_id = SettingsManager.get_editor_theme_style_id and SettingsManager.get_editor_theme_style_id()
        or (EditorThemePresets.get_default_style_id and EditorThemePresets.get_default_style_id() or "classic_compact")
    return _apply_theme(color_id, style_id)
end

module.set_theme = function(theme_id, options)
    return module.set_color(theme_id, options)
end

module.set_color = function(color_id, options)
    local normalized_id = EditorThemePresets.normalize_color_id and EditorThemePresets.normalize_color_id(color_id) or EditorThemePresets.normalize_id(color_id)
    local change_options = options or {}
    local previous_id = current_color_id

    if previous_id ~= normalized_id or change_options.force == true then
        _apply_theme(normalized_id, module.get_current_style_id())
    end

    if change_options.persist ~= false then
        if SettingsManager.set_editor_theme_color_id then
            SettingsManager.set_editor_theme_color_id(normalized_id, {silent = change_options.silent == true})
        else
            SettingsManager.set_editor_theme_id(normalized_id, {silent = change_options.silent == true})
        end
    end

    return previous_id ~= normalized_id
end

module.set_style = function(style_id, options)
    local normalized_id = EditorThemePresets.normalize_style_id and EditorThemePresets.normalize_style_id(style_id) or "classic_compact"
    local change_options = options or {}
    local previous_id = current_style_id

    if previous_id ~= normalized_id or change_options.force == true then
        _apply_theme(module.get_current_color_id(), normalized_id)
    end

    if change_options.persist ~= false and SettingsManager.set_editor_theme_style_id then
        SettingsManager.set_editor_theme_style_id(normalized_id, {silent = change_options.silent == true})
    end

    return previous_id ~= normalized_id
end

module.ensure_theme_applied = function()
    if current_color_id == nil or current_style_id == nil then
        module.apply_saved_theme()
    end
end

return module

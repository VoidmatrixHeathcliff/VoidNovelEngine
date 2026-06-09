local module = {}

local util = Engine.Util
local imgui = Engine.ImGUI
local EditorThemeManager = require("application.framework.editor_theme_manager")

local function _zoom_value(editor_zoom_ratio)
    return math.max(0.25, tonumber(editor_zoom_ratio) or 1)
end

local function _scaled(value, editor_zoom_ratio)
    return value * _zoom_value(editor_zoom_ratio)
end

local function _push_style_var(scope, style_var, value)
    if style_var == nil then
        return
    end
    imgui.PushStyleVar(style_var, value)
    scope.var_count = scope.var_count + 1
end

local function _copy_style_value(value)
    if value ~= nil then
        local ok, x, y = pcall(function()
            return value.x, value.y
        end)
        if ok and type(x) == "number" and type(y) == "number" then
            return imgui.ImVec2(x, y)
        end
    end
    return value
end

local function _push_style_field(scope, field_name, value)
    local style = imgui.GetStyle()
    if type(field_name) ~= "string" or not style or style[field_name] == nil then
        return
    end
    scope.field_stack = scope.field_stack or {}
    table.insert(scope.field_stack,
    {
        name = field_name,
        value = _copy_style_value(style[field_name]),
    })
    style[field_name] = value
end

local function _push_style_var_or_field(scope, style_var, field_name, value)
    if style_var ~= nil then
        _push_style_var(scope, style_var, value)
    else
        _push_style_field(scope, field_name, value)
    end
end

local function _push_style_color(scope, color_id, color)
    if color_id == nil or color == nil then
        return
    end
    imgui.PushStyleColor(color_id, color)
    scope.color_count = scope.color_count + 1
end

local function _pop_style_scope(scope)
    if not scope then
        return
    end
    if scope.color_count and scope.color_count > 0 then
        imgui.PopStyleColor(scope.color_count)
    end
    if scope.field_stack then
        for index = #scope.field_stack, 1, -1 do
            local record = scope.field_stack[index]
            imgui.GetStyle()[record.name] = record.value
        end
    end
    if scope.var_count and scope.var_count > 0 then
        imgui.PopStyleVar(scope.var_count)
    end
end

local function _pop_stack_scope(stack, scope)
    if scope == nil then
        scope = table.remove(stack)
    elseif stack[#stack] == scope then
        table.remove(stack)
    end
    _pop_style_scope(scope)
end

local compact_tree_style_stack = {}
local compact_popup_style_stack = {}
local soft_tab_border_style_stack = {}

module.HoveredTooltip = function(text)
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
            imgui.TextDisabled(text)
        imgui.EndTooltip()
    end
end

module.PushRedButtonColors = function()
    local palette = EditorThemeManager.get_semantic_button_palette("danger")
    imgui.PushStyleColor(imgui.ImGuiCol.Button, palette.button)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, palette.hovered)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, palette.active)
end

module.PushGreenButtonColors = function()
    local palette = EditorThemeManager.get_semantic_button_palette("success")
    imgui.PushStyleColor(imgui.ImGuiCol.Button, palette.button)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, palette.hovered)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, palette.active)
end

module.PopColorButtonColors = function()
    imgui.PopStyleColor(3)
end

module.ShouldUseInHThemeCompensation = function()
    return EditorThemeManager.get_current_style_id and EditorThemeManager.get_current_style_id() == "moonlight"
end

module.PushCompactTreeStyle = function(editor_zoom_ratio, options)
    options = options or {}
    local scope = {var_count = 0, color_count = 0}
    local style_var = imgui.StyleVar or {}
    local zoom = _zoom_value(editor_zoom_ratio)
    local frame_padding_x = tonumber(options.frame_padding_x) or 4
    local frame_padding_y = tonumber(options.frame_padding_y) or 3
    local item_spacing_x = tonumber(options.item_spacing_x) or 6
    local item_spacing_y = tonumber(options.item_spacing_y) or 3
    local item_inner_spacing_x = tonumber(options.item_inner_spacing_x) or 4
    local item_inner_spacing_y = tonumber(options.item_inner_spacing_y) or 4
    local indent_spacing = tonumber(options.indent_spacing) or 21

    if options.include_window_padding == true then
        local window_padding_x = tonumber(options.window_padding_x) or 8
        local window_padding_y = tonumber(options.window_padding_y) or 6
        _push_style_var(scope, style_var.WindowPadding, imgui.ImVec2(_scaled(window_padding_x, zoom), _scaled(window_padding_y, zoom)))
    end

    _push_style_var(scope, style_var.FramePadding, imgui.ImVec2(_scaled(frame_padding_x, zoom), _scaled(frame_padding_y, zoom)))
    _push_style_var(scope, style_var.ItemSpacing, imgui.ImVec2(_scaled(item_spacing_x, zoom), _scaled(item_spacing_y, zoom)))
    _push_style_var(scope, style_var.ItemInnerSpacing, imgui.ImVec2(_scaled(item_inner_spacing_x, zoom), _scaled(item_inner_spacing_y, zoom)))
    _push_style_var(scope, style_var.IndentSpacing, _scaled(indent_spacing, zoom))

    table.insert(compact_tree_style_stack, scope)
    return scope
end

module.PopCompactTreeStyle = function(scope)
    _pop_stack_scope(compact_tree_style_stack, scope)
end

module.PushCompactPopupStyle = function(editor_zoom_ratio, options)
    options = options or {}
    local scope = {var_count = 0, color_count = 0}
    local style_var = imgui.StyleVar or {}
    local zoom = _zoom_value(editor_zoom_ratio)

    _push_style_var(scope, style_var.WindowPadding, imgui.ImVec2(_scaled(tonumber(options.window_padding_x) or 8, zoom), _scaled(tonumber(options.window_padding_y) or 8, zoom)))
    _push_style_var(scope, style_var.FramePadding, imgui.ImVec2(_scaled(tonumber(options.frame_padding_x) or 4, zoom), _scaled(tonumber(options.frame_padding_y) or 3, zoom)))
    _push_style_var(scope, style_var.ItemSpacing, imgui.ImVec2(_scaled(tonumber(options.item_spacing_x) or 8, zoom), _scaled(tonumber(options.item_spacing_y) or 4, zoom)))
    _push_style_var(scope, style_var.ItemInnerSpacing, imgui.ImVec2(_scaled(tonumber(options.item_inner_spacing_x) or 4, zoom), _scaled(tonumber(options.item_inner_spacing_y) or 4, zoom)))
    _push_style_var(scope, style_var.IndentSpacing, _scaled(tonumber(options.indent_spacing) or 21, zoom))
    _push_style_var(scope, style_var.PopupRounding, _scaled(tonumber(options.popup_rounding) or 5, zoom))
    _push_style_var(scope, style_var.PopupBorderSize, tonumber(options.popup_border_size) or 1)

    table.insert(compact_popup_style_stack, scope)
    return scope
end

module.PopCompactPopupStyle = function(scope)
    _pop_stack_scope(compact_popup_style_stack, scope)
end

module.PushSoftTabBorderStyle = function(editor_zoom_ratio, options)
    options = options or {}
    local scope = {var_count = 0, color_count = 0}
    local style_var = imgui.StyleVar or {}
    local color_id = imgui.ImGuiCol or {}
    local zoom = _zoom_value(editor_zoom_ratio)
    local border_size = tonumber(options.border_size) or 1
    local tab_rounding = options.tab_rounding
    local border_color = options.border_color or EditorThemeManager.get_tab_soft_border_color()
    local selected_fill = options.selected_fill or EditorThemeManager.with_alpha(border_color, 0.22)
    local selected_dimmed_fill = options.selected_dimmed_fill or EditorThemeManager.with_alpha(border_color, 0.16)
    local hovered_fill = options.hovered_fill or EditorThemeManager.with_alpha(border_color, 0.18)

    _push_style_var_or_field(scope, style_var.TabBorderSize, "TabBorderSize", math.max(1, math.floor(border_size * zoom + 0.5)))
    _push_style_var_or_field(scope, style_var.TabBarBorderSize, "TabBarBorderSize", math.max(1, math.floor(border_size * zoom + 0.5)))
    if tab_rounding ~= nil then
        _push_style_var(scope, style_var.TabRounding, _scaled(tonumber(tab_rounding) or 0, zoom))
    end

    _push_style_color(scope, color_id.TabHovered, hovered_fill)
    _push_style_color(scope, color_id.TabSelected or color_id.TabActive, selected_fill)
    _push_style_color(scope, color_id.TabDimmedSelected or color_id.TabUnfocusedActive, selected_dimmed_fill)
    _push_style_color(scope, color_id.TabSelectedOverline, border_color)
    _push_style_color(scope, color_id.TabDimmedSelectedOverline, EditorThemeManager.with_alpha(border_color, 0.70))

    table.insert(soft_tab_border_style_stack, scope)
    return scope
end

module.PopSoftTabBorderStyle = function(scope)
    _pop_stack_scope(soft_tab_border_style_stack, scope)
end

module.EllipsisTail = function(text, max_width)
    text = type(text) == "string" and text or ""
    if text == "" or not max_width or max_width <= 0 then
        return text
    end

    if imgui.CalcTextSize(text).x <= max_width then
        return text
    end

    local ellipsis = "..."
    if imgui.CalcTextSize(ellipsis).x >= max_width then
        return ellipsis
    end

    local utf8_len = util.UTF8Len(text)
    local low = 0
    local high = utf8_len
    local best = ellipsis

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local offset = math.max(0, utf8_len - mid)
        local suffix = util.UTF8Sub(text, offset, mid)
        local candidate = ellipsis .. suffix
        if imgui.CalcTextSize(candidate).x <= max_width then
            best = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return best
end

module.EllipsisHead = function(text, max_width)
    text = type(text) == "string" and text or ""
    if text == "" or not max_width or max_width <= 0 then
        return text
    end

    if imgui.CalcTextSize(text).x <= max_width then
        return text
    end

    local ellipsis = "..."
    if imgui.CalcTextSize(ellipsis).x >= max_width then
        return ellipsis
    end

    local utf8_len = util.UTF8Len(text)
    local low = 0
    local high = utf8_len
    local best = ellipsis

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local prefix = mid > 0 and util.UTF8Sub(text, 0, mid) or ""
        local candidate = prefix .. ellipsis
        if imgui.CalcTextSize(candidate).x <= max_width then
            best = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return best
end

module.EllipsisMiddle = function(text, max_width)
    text = type(text) == "string" and text or ""
    if text == "" or not max_width or max_width <= 0 then
        return text
    end

    if imgui.CalcTextSize(text).x <= max_width then
        return text
    end

    local ellipsis = "..."
    if imgui.CalcTextSize(ellipsis).x >= max_width then
        return ellipsis
    end

    local utf8_len = util.UTF8Len(text)
    local low = 0
    local high = utf8_len
    local best = ellipsis

    while low <= high do
        local mid = math.floor((low + high) / 2)
        local prefix_len = math.ceil(mid / 2)
        local suffix_len = math.floor(mid / 2)
        local prefix = prefix_len > 0 and util.UTF8Sub(text, 0, prefix_len) or ""
        local suffix_offset = math.max(0, utf8_len - suffix_len)
        local suffix = suffix_len > 0 and util.UTF8Sub(text, suffix_offset, suffix_len) or ""
        local candidate = prefix .. ellipsis .. suffix
        if imgui.CalcTextSize(candidate).x <= max_width then
            best = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end

    return best
end

return module

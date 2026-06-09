local imgui = Engine.ImGUI

local FlowDocMarkup = require("application.framework.flow_doc_markup")
local FlowDocTheme = require("application.framework.flow_doc_theme")

local module = {}

local render_serial = 0

local function _resolve_content_width(theme, options)
    local available_width = math.max(80, imgui.GetContentRegionAvail().x or 0)
    local preferred_width = tonumber(options and options.preferred_width) or 0
    local min_width = tonumber(options and options.min_width) or 0
    local max_width = tonumber(options and options.max_width) or 0
    local content_width = 0

    if preferred_width > 0 then
        content_width = preferred_width
    else
        content_width = math.min(available_width, theme.max_width)
    end

    if min_width > 0 then
        content_width = math.max(content_width, min_width)
    end
    if max_width > 0 then
        content_width = math.min(content_width, max_width)
    elseif preferred_width <= 0 then
        content_width = math.min(content_width, theme.max_width)
    end

    return math.max(80, content_width)
end

local function _get_effective_wrap_width(context)
    local available_width = math.max(80, imgui.GetContentRegionAvail().x or 0)
    if context and tonumber(context.local_width) and context.local_width > 0 then
        return math.max(80, context.local_width)
    end
    if context and context.enforce_width and tonumber(context.content_width) and context.content_width > 0 then
        return math.max(80, context.content_width)
    end
    local desired_width = context and context.content_width or available_width
    return math.max(80, math.min(desired_width, available_width))
end

local function _resolve_table_width(context, minimum_width)
    return math.max(tonumber(minimum_width) or 120, _get_effective_wrap_width(context))
end

local function _with_local_width(context, width, callback)
    if type(context) ~= "table" then
        return callback(context)
    end

    local previous_local_width = context.local_width
    local previous_enforce_width = context.enforce_width
    context.local_width = math.max(80, tonumber(width) or 0)
    context.enforce_width = false

    local ok, result = pcall(callback, context)
    context.local_width = previous_local_width
    context.enforce_width = previous_enforce_width

    if not ok then
        error(result, 0)
    end
    return result
end

local function _push_font(font, size)
    if font then
        imgui.PushFont(font, size)
        return true
    end
    return false
end

local function _pop_font(pushed)
    if pushed then
        imgui.PopFont()
    end
end

local function _to_u32(color)
    return imgui.ImColor(color):to_u32()
end

local function _render_wrapped_text(text, color, font, size, context)
    if not text or text == "" then
        return
    end

    local pushed_font = _push_font(font, size)
    imgui.PushStyleColor(imgui.ImGuiCol.Text, color)
    if imgui.PushTextWrapPos then
        local wrap_width = _get_effective_wrap_width(context)
        local cursor = imgui.GetCursorPos and imgui.GetCursorPos() or nil
        local wrap_local_pos = (cursor and cursor.x or 0) + wrap_width
        imgui.PushTextWrapPos(wrap_local_pos)
    end
    imgui.Text(text)
    if imgui.PopTextWrapPos then
        imgui.PopTextWrapPos()
    end
    imgui.PopStyleColor()
    _pop_font(pushed_font)
end

local function _render_plain_text(text, color, font, size)
    if not text or text == "" then
        return
    end

    local pushed_font = _push_font(font, size)
    imgui.PushStyleColor(imgui.ImGuiCol.Text, color)
    imgui.Text(text)
    imgui.PopStyleColor()
    _pop_font(pushed_font)
end

local function _measure_text(text, font, size, cache)
    local cache_key = string.format("%s|%s|%s", tostring(font), tostring(size), tostring(text))
    if cache[cache_key] then
        return cache[cache_key]
    end

    local pushed_font = _push_font(font, size)
    local measured = imgui.CalcTextSize(text or "")
    _pop_font(pushed_font)

    local result =
    {
        x = measured.x or 0,
        y = measured.y or 0,
    }
    cache[cache_key] = result
    return result
end

local function _count_lines(text)
    local normalized = tostring(text or "")
    local _, count = normalized:gsub("\n", "\n")
    return count + 1
end

local function _iter_codepoints(text, callback)
    local success = pcall(function()
        for _, codepoint in utf8.codes(text) do
            callback(utf8.char(codepoint), codepoint)
        end
    end)
    if success then
        return
    end

    for index = 1, #text do
        callback(text:sub(index, index), string.byte(text, index))
    end
end

local function _is_ascii_word_codepoint(codepoint)
    return (codepoint >= 48 and codepoint <= 57)
        or (codepoint >= 65 and codepoint <= 90)
        or (codepoint >= 97 and codepoint <= 122)
        or codepoint == 95
        or codepoint == 45
        or codepoint == 46
        or codepoint == 47
        or codepoint == 58
        or codepoint == 64
        or codepoint == 35
        or codepoint == 38
        or codepoint == 37
        or codepoint == 43
        or codepoint == 61
end

local function _style_signature(style)
    if type(style) ~= "table" then
        return ""
    end

    local key_list =
    {
        "bold",
        "italic",
        "underline",
        "code",
        "kbd",
        "color",
        "url",
        "semantic_kind",
    }
    local part_list = {}
    for _, key in ipairs(key_list) do
        local value = style[key]
        if value ~= nil and value ~= false then
            part_list[#part_list + 1] = string.format("%s=%s", key, tostring(value))
        end
    end
    return table.concat(part_list, ";")
end

local function _resolve_inline_appearance(style, theme)
    local appearance =
    {
        font = theme.body_font,
        font_size = theme.body_font_size,
        text_color = theme.colors.text,
        background_color = nil,
        border_color = nil,
        pad_x = 0,
        pad_y = 0,
        underline = false,
        bold = false,
        italic = false,
    }

    style = type(style) == "table" and style or {}
    local semantic_kind = style.semantic_kind
    if semantic_kind == "command" or semantic_kind == "directive" then
        appearance.font = theme.code_font
        appearance.font_size = theme.code_font_size
        appearance.text_color = theme.colors.accent
    elseif semantic_kind == "type" then
        appearance.font = theme.code_font
        appearance.font_size = theme.code_font_size
        appearance.text_color = theme.colors.success
    elseif semantic_kind == "param" or semantic_kind == "pin" then
        appearance.font = theme.code_font
        appearance.font_size = theme.code_font_size
        appearance.text_color = theme.colors.warning
    elseif semantic_kind == "label" then
        appearance.font = theme.code_font
        appearance.font_size = theme.code_font_size
        appearance.text_color = theme.colors.danger
    end

    if style.color and theme.colors[style.color] then
        appearance.text_color = theme.colors[style.color]
    end
    if style.url then
        appearance.text_color = theme.colors.link or theme.colors.accent
        appearance.underline = true
    end
    if style.code then
        appearance.font = theme.code_font
        appearance.font_size = theme.code_font_size
        appearance.background_color = theme.colors.code_bg
        appearance.border_color = theme.colors.code_border
        appearance.pad_x = theme.metrics.inline_code_pad_x
        appearance.pad_y = theme.metrics.inline_code_pad_y
    elseif style.kbd then
        appearance.font = theme.code_font
        appearance.font_size = theme.code_font_size
        appearance.background_color = theme.colors.kbd_bg
        appearance.border_color = theme.colors.kbd_border
        appearance.pad_x = theme.metrics.inline_kbd_pad_x
        appearance.pad_y = theme.metrics.inline_kbd_pad_y
    end

    if style.bold then
        appearance.bold = true
        appearance.text_color = appearance.text_color or theme.colors.text_emphasis
    end
    if style.italic then
        appearance.italic = true
        if appearance.text_color == theme.colors.text then
            appearance.text_color = theme.colors.text_emphasis
        end
    end
    if style.underline then
        appearance.underline = true
    end

    appearance.signature = _style_signature(style)
    return appearance
end

local function _split_text_units(text, style)
    local result = {}
    local source = tostring(text or "")
    local atomic = style
        and (style.code
            or style.kbd
            or style.url
            or style.semantic_kind ~= nil)
    if atomic then
        result[1] = {text = source, is_space = false}
        return result
    end

    local word_buffer = {}
    local space_buffer = {}

    local function flush_word()
        if #word_buffer == 0 then
            return
        end
        result[#result + 1] =
        {
            text = table.concat(word_buffer),
            is_space = false,
        }
        word_buffer = {}
    end

    local function flush_space()
        if #space_buffer == 0 then
            return
        end
        result[#result + 1] =
        {
            text = table.concat(space_buffer),
            is_space = true,
        }
        space_buffer = {}
    end

    _iter_codepoints(source, function(char, codepoint)
        if char == " " then
            flush_word()
            space_buffer[#space_buffer + 1] = char
        elseif char == "\t" then
            flush_word()
            space_buffer[#space_buffer + 1] = "    "
        elseif type(codepoint) == "number" and codepoint < 128 and _is_ascii_word_codepoint(codepoint) then
            flush_space()
            word_buffer[#word_buffer + 1] = char
        else
            flush_word()
            flush_space()
            result[#result + 1] =
            {
                text = char,
                is_space = false,
            }
        end
    end)

    flush_word()
    flush_space()
    return result
end

local function _layout_inline_chunks(chunk_list, theme, context)
    local measure_cache = {}
    local max_width = _get_effective_wrap_width(context)
    local base_height = _measure_text("国", theme.body_font, theme.body_font_size, measure_cache).y
    local lines =
    {
        {
            items = {},
            width = 0,
            height = base_height,
        },
    }

    local function current_line()
        return lines[#lines]
    end

    local function new_line()
        lines[#lines + 1] =
        {
            items = {},
            width = 0,
            height = base_height,
        }
    end

    for _, chunk in ipairs(chunk_list or {}) do
        if chunk.kind == "line_break" then
            new_line()
        elseif chunk.kind == "text" then
            local appearance = _resolve_inline_appearance(chunk.style, theme)
            for _, unit in ipairs(_split_text_units(chunk.text, chunk.style)) do
                local line = current_line()
                if unit.is_space and line.width <= 0 then
                    goto continue
                end

                local measured = _measure_text(unit.text, appearance.font, appearance.font_size, measure_cache)
                local width = measured.x + appearance.pad_x * 2
                local height = measured.y + appearance.pad_y * 2

                if not unit.is_space and line.width > 0 and (line.width + width) > max_width then
                    new_line()
                    line = current_line()
                end

                if unit.is_space and line.width <= 0 then
                    goto continue
                end

                line.items[#line.items + 1] =
                {
                    text = unit.text,
                    is_space = unit.is_space,
                    x = line.width,
                    width = width,
                    height = height,
                    text_height = measured.y,
                    appearance = appearance,
                }
                line.width = line.width + width
                line.height = math.max(line.height, height)

                ::continue::
            end
        end
    end

    while #lines > 1 and #lines[#lines].items == 0 do
        table.remove(lines, #lines)
    end

    local total_height = 0
    local total_width = 0
    for index, line in ipairs(lines) do
        total_width = math.max(total_width, line.width)
        total_height = total_height + line.height
        if index < #lines then
            total_height = total_height + theme.spacing.line_gap
        end
    end

    return
    {
        lines = lines,
        width = total_width,
        height = total_height,
    }
end

local function _draw_inline_layout(layout, theme)
    if not layout or not layout.lines or #layout.lines == 0 then
        return
    end

    local draw_list = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()
    local current_y = origin.y

    for line_index, line in ipairs(layout.lines) do
        for _, item in ipairs(line.items) do
            local appearance = item.appearance or {}
            local rect_min = imgui.ImVec2(origin.x + item.x, current_y + (line.height - item.height) * 0.5)
            local rect_max = imgui.ImVec2(rect_min.x + item.width, rect_min.y + item.height)
            local text_pos = imgui.ImVec2(rect_min.x + (appearance.pad_x or 0), rect_min.y + (appearance.pad_y or 0))

            if draw_list and appearance.border_color and appearance.background_color then
                draw_list:AddRectFilled(rect_min, rect_max, _to_u32(appearance.border_color), theme.metrics.chip_rounding)
                draw_list:AddRectFilled(
                    imgui.ImVec2(rect_min.x + 1, rect_min.y + 1),
                    imgui.ImVec2(rect_max.x - 1, rect_max.y - 1),
                    _to_u32(appearance.background_color),
                    math.max(0, theme.metrics.chip_rounding - 1))
            elseif draw_list and appearance.background_color then
                draw_list:AddRectFilled(rect_min, rect_max, _to_u32(appearance.background_color), theme.metrics.chip_rounding)
            end

            local pushed_font = _push_font(appearance.font, appearance.font_size)
            if draw_list then
                draw_list:AddText(text_pos, _to_u32(appearance.text_color), item.text)
                if appearance.bold then
                    draw_list:AddText(
                        imgui.ImVec2(text_pos.x + 0.55, text_pos.y),
                        _to_u32(appearance.text_color),
                        item.text)
                end
                if appearance.underline then
                    local underline_y = rect_max.y - theme.metrics.underline_offset
                    draw_list:AddRectFilled(
                        imgui.ImVec2(text_pos.x, underline_y),
                        imgui.ImVec2(text_pos.x + math.max(1, item.width - (appearance.pad_x or 0) * 2), underline_y + theme.metrics.underline_thickness),
                        _to_u32(appearance.text_color))
                end
            end
            _pop_font(pushed_font)
        end

        current_y = current_y + line.height
        if line_index < #layout.lines then
            current_y = current_y + theme.spacing.line_gap
        end
    end

    imgui.Dummy(imgui.ImVec2(math.max(1, layout.width), math.max(1, layout.height)))
end

local function _render_inline_chunks(chunk_list, theme, context)
    local layout = _layout_inline_chunks(chunk_list, theme, context)
    _draw_inline_layout(layout, theme)
end

local function _render_section_title(title, theme)
    if not title or title == "" then
        return
    end

    local pushed_font = _push_font(theme.body_font, theme.section_title_font_size)
    imgui.TextDisabled(title)
    _pop_font(pushed_font)
    imgui.Separator()
end

local function _render_lozenge_text(text, palette, theme, options)
    if not text or text == "" then
        return
    end

    options = type(options) == "table" and options or {}
    local font = options.font or theme.body_font
    local font_size = options.font_size or theme.small_font_size
    local pad_x = tonumber(options.pad_x) or math.max(6, theme.metrics.inline_code_pad_x + 1)
    local pad_y = tonumber(options.pad_y) or math.max(2, theme.metrics.inline_code_pad_y)
    local rounding = tonumber(options.rounding) or theme.metrics.chip_rounding

    local measure_cache = {}
    local text_size = _measure_text(text, font, font_size, measure_cache)
    local width = text_size.x + pad_x * 2
    local height = text_size.y + pad_y * 2
    local draw_list = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()

    if draw_list and palette and palette.border and palette.bg then
        local border_thickness = 1
        draw_list:AddRectFilled(
            origin,
            imgui.ImVec2(origin.x + width, origin.y + height),
            _to_u32(palette.border),
            rounding)
        draw_list:AddRectFilled(
            imgui.ImVec2(origin.x + border_thickness, origin.y + border_thickness),
            imgui.ImVec2(origin.x + width - border_thickness, origin.y + height - border_thickness),
            _to_u32(palette.bg),
            math.max(0, rounding - border_thickness))
    elseif draw_list and palette and palette.bg then
        draw_list:AddRectFilled(
            origin,
            imgui.ImVec2(origin.x + width, origin.y + height),
            _to_u32(palette.bg),
            rounding)
    elseif draw_list and palette and palette.border then
        draw_list:AddRectFilled(
            origin,
            imgui.ImVec2(origin.x + width, origin.y + height),
            _to_u32(palette.border),
            rounding)
    end

    imgui.Dummy(imgui.ImVec2(width, height))

    local pushed_font = _push_font(font, font_size)
    if draw_list then
        draw_list:AddText(
            imgui.ImVec2(origin.x + pad_x, origin.y + pad_y),
            _to_u32(palette and palette.text or theme.colors.text),
            text)
    end
    _pop_font(pushed_font)
end

local function _render_inline_token(text, theme, context)
    if not text or text == "" then
        return
    end

    _render_lozenge_text(
        tostring(text),
        {
            text = theme.colors.text,
            bg = theme.colors.code_bg,
            border = theme.colors.code_border,
        },
        theme,
        {
            font = theme.code_font,
            font_size = theme.compact_code_font_size,
            pad_x = math.max(4, theme.metrics.inline_code_pad_x),
            pad_y = math.max(2, theme.metrics.inline_code_pad_y),
        })
end

local function _render_inline_token_list(value_list, theme, context)
    for index, value in ipairs(value_list or {}) do
        if index > 1 then
            imgui.Dummy(imgui.ImVec2(0, theme.spacing.compact_gap))
        end
        _render_inline_token(value, theme, context)
    end
end

local function _render_meta_value(item, theme, context)
    if item.value_list and #item.value_list > 0 then
        if item.value_mode == "code" then
            _render_inline_token_list(item.value_list, theme, context)
        else
            for index, value in ipairs(item.value_list) do
                if index > 1 then
                    imgui.Dummy(imgui.ImVec2(0, theme.spacing.compact_gap))
                end
                _render_wrapped_text(tostring(value), theme.colors.text, theme.body_font, theme.small_font_size, context)
            end
        end
        return
    end

    if item.value and item.value ~= "" then
        if item.value_mode == "code" then
            _render_inline_token(tostring(item.value), theme, context)
        else
            _render_wrapped_text(tostring(item.value), theme.colors.text, theme.body_font, theme.small_font_size, context)
        end
    end
end

local function _render_meta_list(meta_list, theme, context)
    if not meta_list or #meta_list == 0 then
        return
    end

    local table_width = _resolve_table_width(context, 220)
    local measure_cache = {}
    local max_label_width = 0
    for _, item in ipairs(meta_list) do
        local label = tostring(item.label or "")
        if label ~= "" then
            max_label_width = math.max(
                max_label_width,
                _measure_text(label, theme.body_font, theme.small_font_size, measure_cache).x)
        end
    end

    local label_column_width = math.min(
        math.max(50, max_label_width + 6),
        math.max(68, math.floor(table_width * 0.18 + 0.5)))

    local table_flags = imgui.TableFlags.NoSavedSettings
        | imgui.TableFlags.SizingStretchProp
        | imgui.TableFlags.NoBordersInBody
        | imgui.TableFlags.NoPadOuterX
        | (imgui.TableFlags.NoPadInnerX or 0)

    local pushed_cell_padding = false
    if imgui.StyleVar and imgui.StyleVar.CellPadding then
        imgui.PushStyleVar(imgui.StyleVar.CellPadding, imgui.ImVec2(math.max(2, theme.spacing.inline_gap), theme.spacing.tight_gap))
        pushed_cell_padding = true
    end

    if not imgui.BeginTable(string.format("flow_doc_meta_%d", context.render_id), 2, table_flags, imgui.ImVec2(table_width, 0)) then
        if pushed_cell_padding then
            imgui.PopStyleVar()
        end
        return
    end

    imgui.TableSetupColumn("标签", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, label_column_width)
    imgui.TableSetupColumn("内容", imgui.TableColumnFlags.WidthStretch, 1.0)

    for _, item in ipairs(meta_list) do
        local has_values = (item.value and item.value ~= "") or (item.value_list and #item.value_list > 0)
        if item.label and item.label ~= "" and has_values then
            imgui.TableNextRow()
            imgui.TableSetColumnIndex(0)
            _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
                _render_wrapped_text(tostring(item.label), theme.colors.muted, theme.body_font, theme.small_font_size, local_context)
            end)
            imgui.TableSetColumnIndex(1)
            _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
                _render_meta_value(item, theme, local_context)
            end)
        end
    end

    imgui.EndTable()
    if pushed_cell_padding then
        imgui.PopStyleVar()
    end
end

local function _get_badge_palette(tone, theme)
    if tone == "success" then
        return {text = theme.colors.success, bg = theme.colors.tip_bg}
    end
    if tone == "warning" then
        return {text = theme.colors.warning, bg = theme.colors.warning_bg}
    end
    if tone == "danger" then
        return {text = theme.colors.danger, bg = theme.colors.danger_bg}
    end
    if tone == "muted" then
        return {text = theme.colors.muted, bg = theme.colors.note_bg}
    end
    return {text = theme.colors.accent, bg = theme.colors.note_bg}
end

local function _render_pill_text(text, tone, theme)
    _render_lozenge_text(text, _get_badge_palette(tone, theme), theme)
end

local function _render_badge_line(badge_list, theme)
    if not badge_list or #badge_list == 0 then
        return
    end

    for index, badge in ipairs(badge_list) do
        if index > 1 then
            imgui.SameLine(0, theme.spacing.item_gap)
        end
        _render_pill_text(tostring(badge.text or ""), badge.tone or "accent", theme)
    end
end

local function _get_subtitle_palette(kind, theme)
    if kind == "category" then
        return
        {
            text = theme.colors.category_chip_text,
            bg = theme.colors.category_chip_bg,
            border = theme.colors.category_chip_border,
        }
    end
    if kind == "special" then
        return
        {
            text = theme.colors.special_chip_text,
            bg = theme.colors.special_chip_bg,
            border = theme.colors.special_chip_border,
        }
    end
    return
    {
        text = theme.colors.header_chip_text,
        bg = theme.colors.header_chip_bg,
        border = theme.colors.header_chip_border,
    }
end

local function _render_subtitle_item_list(item_list, theme)
    if not item_list or #item_list == 0 then
        return
    end

    for index, item in ipairs(item_list) do
        if index > 1 then
            imgui.SameLine(0, theme.spacing.chip_gap)
        end
        _render_lozenge_text(
            tostring(item.text or ""),
            _get_subtitle_palette(item.kind, theme),
            theme,
            {
                font = theme.body_font,
                font_size = theme.small_font_size,
                pad_x = theme.metrics.header_chip_pad_x,
                pad_y = theme.metrics.header_chip_pad_y,
                rounding = theme.metrics.chip_rounding + 2,
            })
    end
end

local function _render_code_panel(text, language, title, theme, context, options)
    if not text or text == "" then
        return
    end

    options = type(options) == "table" and options or {}
    local compact = options.compact == true
    local code_font_size = compact and theme.compact_code_font_size or theme.code_font_size
    local pad_x = compact and theme.metrics.compact_code_block_pad_x or theme.metrics.code_block_pad_x
    local pad_y = compact and theme.metrics.compact_code_block_pad_y or theme.metrics.code_block_pad_y
    local has_title = title and title ~= ""
    local has_language = language and language ~= ""
    local header_font_size = theme.small_font_size

    local measure_cache = {}
    local code_line_height = _measure_text("Ag国", theme.code_font, code_font_size, measure_cache).y
    local header_stack_gap = (has_title and has_language) and (compact and 0 or theme.spacing.tight_gap) or 0
    local body_gap = (has_title or has_language) and math.max(compact and 1 or 2, pad_y - 1) or 0
    local bottom_gap = math.max(compact and 3 or 4, body_gap + 2)
    local top_gap = math.max(compact and 1 or 2, pad_y)

    local header_height = 0
    if has_title then
        header_height = header_height + _measure_text(title, theme.body_font, header_font_size, measure_cache).y
    end
    if has_language then
        header_height = header_height + _measure_text(string.upper(language), theme.body_font, header_font_size, measure_cache).y
    end
    if has_title and has_language then
        header_height = header_height + header_stack_gap
    end
    local line_count = _count_lines(text)
    local code_text_size = _measure_text(text, theme.code_font, code_font_size, measure_cache)
    local code_content_height = math.max(code_text_size.y, code_line_height * line_count)

    local child_height = math.max(
        top_gap + header_height + body_gap + code_content_height + bottom_gap,
        top_gap + code_line_height + bottom_gap)

    imgui.PushStyleColor(imgui.ImGuiCol.ChildBg, theme.colors.code_bg)
    imgui.PushStyleColor(imgui.ImGuiCol.Border, theme.colors.code_border)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(pad_x, 0))
    imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(theme.spacing.inline_gap, 0))
    imgui.PushStyleVar(imgui.StyleVar.ChildRounding, theme.metrics.chip_rounding + 2)
    imgui.PushStyleVar(imgui.StyleVar.ChildBorderSize, 1)
    context.code_block_index = (context.code_block_index or 0) + 1
    imgui.BeginChild(
        string.format("flow_doc_code_%d_%d", context.render_id, context.code_block_index),
        imgui.ImVec2(0, child_height),
        imgui.ChildFlags.Borders | imgui.ChildFlags.AlwaysUseWindowPadding)
        _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
            if top_gap > 0 then
                imgui.Dummy(imgui.ImVec2(0, top_gap))
            end
            if has_title then
                _render_wrapped_text(title, theme.colors.text_emphasis, theme.body_font, header_font_size, local_context)
            end
            if has_title and has_language and header_stack_gap > 0 then
                imgui.Dummy(imgui.ImVec2(0, header_stack_gap))
            end
            if has_language then
                _render_wrapped_text(string.upper(language), theme.colors.muted, theme.body_font, header_font_size, local_context)
            end
            if (has_title or has_language) and body_gap > 0 then
                imgui.Dummy(imgui.ImVec2(0, body_gap))
            end
            _render_plain_text(text, theme.colors.success, theme.code_font, code_font_size)
            if bottom_gap > 0 then
                imgui.Dummy(imgui.ImVec2(0, bottom_gap))
            end
        end)
    imgui.EndChild()
    imgui.PopStyleVar(4)
    imgui.PopStyleColor(2)
end

local function _render_markup(text, theme, context)
    if not text or text == "" then
        return
    end

    for block_index, block in ipairs(FlowDocMarkup.parse(text)) do
        if block_index > 1 then
            imgui.Dummy(imgui.ImVec2(0, theme.spacing.item_gap))
        end

        if block.kind == "paragraph" then
            _render_inline_chunks(FlowDocMarkup.flatten_inline(block.children), theme, context)
        elseif block.kind == "codeblock" then
            _render_code_panel(block.text or "", block.language or "", nil, theme, context)
        end
    end
end

local function _get_note_visual(note, theme)
    if note and note.kind == "tip" then
        return
        {
            label = "提示",
            palette =
            {
                text = theme.colors.success,
                bg = theme.colors.tip_bg,
                border = theme.colors.tip_border,
            },
        }
    end
    if note and note.kind == "warning" then
        return
        {
            label = "警告",
            palette =
            {
                text = theme.colors.warning,
                bg = theme.colors.warning_bg,
                border = theme.colors.warning_border,
            },
        }
    end
    if note and note.kind == "danger" then
        return
        {
            label = "注意",
            palette =
            {
                text = theme.colors.danger,
                bg = theme.colors.danger_bg,
                border = theme.colors.danger_border,
            },
        }
    end
    return
    {
            label = "说明",
            palette =
            {
                text = theme.colors.accent,
                bg = theme.colors.note_bg,
                border = theme.colors.note_border,
            },
    }
end

local function _render_parameter_list(parameter_list, theme, context)
    if not parameter_list or #parameter_list == 0 then
        return
    end

    _render_section_title("参数", theme)
    local table_width = _resolve_table_width(context, 280)
    local has_alias_column = false
    for _, item in ipairs(parameter_list) do
        if item.alias_list and #item.alias_list > 0 then
            has_alias_column = true
            break
        end
    end

    local name_column_width = math.min(152, math.max(116, math.floor(table_width * (has_alias_column and 0.26 or 0.30) + 0.5)))
    local alias_column_width = has_alias_column
        and math.min(148, math.max(110, math.floor(table_width * 0.24 + 0.5)))
        or 0

    local table_flags = imgui.TableFlags.NoSavedSettings
        | imgui.TableFlags.Borders
        | imgui.TableFlags.RowBg
        | imgui.TableFlags.SizingStretchProp

    local column_count = has_alias_column and 3 or 2
    if not imgui.BeginTable(string.format("flow_doc_params_%d", context.render_id), column_count, table_flags, imgui.ImVec2(table_width, 0)) then
        return
    end

    imgui.TableSetupColumn("参数", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, name_column_width)
    if has_alias_column then
        imgui.TableSetupColumn("别名", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, alias_column_width)
    end
    imgui.TableSetupColumn("说明", imgui.TableColumnFlags.WidthStretch, 1.0)

    for _, item in ipairs(parameter_list) do
        imgui.TableNextRow()

        imgui.TableSetColumnIndex(0)
        _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
            local has_badges = item.badges and #item.badges > 0
            if has_badges then
                imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(theme.spacing.item_gap, 0))
            end
            _render_wrapped_text(tostring(item.name or ""), theme.colors.accent, theme.code_font, theme.code_font_size, local_context)
            if has_badges then
                _render_badge_line(item.badges, theme)
                imgui.PopStyleVar()
            end
        end)

        local description_column_index = 1
        if has_alias_column then
            description_column_index = 2
            imgui.TableSetColumnIndex(1)
            _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
                if item.alias_list and #item.alias_list > 0 then
                    _render_inline_token_list(item.alias_list, theme, local_context)
                end
            end)
        end

        imgui.TableSetColumnIndex(description_column_index)
        _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
            local has_type_label = item.type_label and item.type_label ~= ""
            local has_brief = item.brief and item.brief ~= ""
            if has_type_label and has_brief then
                imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(theme.spacing.item_gap, 0))
            end
            if has_type_label then
                _render_wrapped_text(string.format("类型: %s", tostring(item.type_label)), theme.colors.muted, theme.body_font, theme.small_font_size, local_context)
            end
            if has_brief then
                _render_wrapped_text(item.brief, theme.colors.text, theme.body_font, theme.body_font_size, local_context)
            end
            if has_type_label and has_brief then
                imgui.PopStyleVar()
            end
            if item.description and item.description ~= "" then
                if has_type_label or has_brief then
                    imgui.Dummy(imgui.ImVec2(0, theme.spacing.tight_gap))
                end
                _render_markup(item.description, theme, local_context)
            end
            if item.default and item.default ~= "" then
                imgui.Dummy(imgui.ImVec2(0, theme.spacing.tight_gap))
                _render_wrapped_text(string.format("默认值: %s", tostring(item.default)), theme.colors.muted, theme.body_font, theme.small_font_size, local_context)
            end
            if item.value_hint and item.value_hint ~= "" then
                if item.default and item.default ~= "" then
                    imgui.Dummy(imgui.ImVec2(0, theme.spacing.tight_gap))
                end
                _render_wrapped_text(string.format("取值提示: %s", tostring(item.value_hint)), theme.colors.muted, theme.body_font, theme.small_font_size, local_context)
            end
            if item.example_list and #item.example_list > 0 then
                for _, example in ipairs(item.example_list) do
                    if type(example) == "table" and example.code and example.code ~= "" then
                        imgui.Dummy(imgui.ImVec2(0, theme.spacing.tight_gap))
                        if example.title and example.title ~= "" then
                            _render_wrapped_text(example.title, theme.colors.muted, theme.body_font, theme.small_font_size, local_context)
                            imgui.Dummy(imgui.ImVec2(0, theme.spacing.tight_gap))
                        end
                        _render_code_panel(example.code, example.language or example.lang or "", nil, theme, local_context,
                        {
                            compact = true,
                        })
                    elseif type(example) == "string" and example ~= "" then
                        imgui.Dummy(imgui.ImVec2(0, theme.spacing.tight_gap))
                        _render_code_panel(example, "", nil, theme, local_context,
                        {
                            compact = true,
                        })
                    end
                end
            end
        end)
    end

    imgui.EndTable()
end

local function _render_notes(note_list, theme, context)
    if not note_list or #note_list == 0 then
        return
    end

    _render_section_title("提示", theme)
    for index, note in ipairs(note_list) do
        local visual = _get_note_visual(note, theme)
        imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(theme.spacing.inline_gap, theme.spacing.tight_gap))
        _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
            _render_lozenge_text(
                visual.label,
                visual.palette,
                theme,
                {
                    font = theme.body_font,
                    font_size = theme.small_font_size,
                    pad_x = math.max(6, theme.metrics.inline_code_pad_x + 1),
                    pad_y = math.max(1, theme.metrics.inline_code_pad_y - 1),
                    rounding = theme.metrics.chip_rounding + 1,
                })

            if note.text and note.text ~= "" then
                imgui.SameLine(0, theme.spacing.inline_gap)
                _with_local_width(local_context, math.max(80, imgui.GetContentRegionAvail().x), function(note_context)
                    _render_wrapped_text(
                        tostring(note.text or ""),
                        theme.colors.text,
                        theme.body_font,
                        theme.body_font_size,
                        note_context)
                end)
            end
        end)
        imgui.PopStyleVar()
        if index < #note_list then
            imgui.Dummy(imgui.ImVec2(0, theme.spacing.compact_gap))
        end
    end
end

local function _render_examples(example_list, theme, context)
    if not example_list or #example_list == 0 then
        return
    end

    _render_section_title("示例", theme)
    for index, example in ipairs(example_list) do
        if example.title and example.title ~= "" then
            _render_wrapped_text(example.title, theme.colors.text_emphasis, theme.body_font, theme.small_font_size, context)
            imgui.Dummy(imgui.ImVec2(0, theme.spacing.tight_gap))
        end
        _render_code_panel(
            example.code or "",
            example.language or example.lang or "",
            nil,
            theme,
            context)
        if index < #example_list then
            imgui.Dummy(imgui.ImVec2(0, theme.spacing.code_panel_gap))
        end
    end
end

local function _render_outputs(output_list, theme, context)
    if not output_list or #output_list == 0 then
        return
    end

    _render_section_title("输出", theme)
    local table_width = _resolve_table_width(context, 240)
    local pin_column_width = math.min(132, math.max(100, math.floor(table_width * 0.26 + 0.5)))

    local table_flags = imgui.TableFlags.NoSavedSettings
        | imgui.TableFlags.Borders
        | imgui.TableFlags.RowBg
        | imgui.TableFlags.SizingStretchProp

    if not imgui.BeginTable(string.format("flow_doc_outputs_%d", context.render_id), 2, table_flags, imgui.ImVec2(table_width, 0)) then
        return
    end

    imgui.TableSetupColumn("输出名", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, pin_column_width)
    imgui.TableSetupColumn("说明", imgui.TableColumnFlags.WidthStretch, 1.0)

    for _, item in ipairs(output_list) do
        imgui.TableNextRow()
        imgui.TableSetColumnIndex(0)
        _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
            _render_wrapped_text(tostring(item.pin or ""), theme.colors.accent, theme.code_font, theme.code_font_size, local_context)
        end)
        imgui.TableSetColumnIndex(1)
        _with_local_width(context, imgui.GetContentRegionAvail().x, function(local_context)
            _render_wrapped_text(tostring(item.brief or ""), theme.colors.text, theme.body_font, theme.body_font_size, local_context)
        end)
    end

    imgui.EndTable()
end

local function _render_see_also(item_list, theme, context)
    if not item_list or #item_list == 0 then
        return
    end

    _render_section_title("相关", theme)
    local markup_list = {}
    for _, item in ipairs(item_list) do
        if item.kind == "command" then
            markup_list[#markup_list + 1] = string.format("[command %s]", tostring(item.target))
        elseif item.kind == "directive" then
            markup_list[#markup_list + 1] = string.format("[directive %s]", tostring(item.target))
        elseif item.kind == "type" then
            markup_list[#markup_list + 1] = string.format("[type %s]", tostring(item.target))
        elseif item.kind == "label" then
            markup_list[#markup_list + 1] = string.format("[label %s]", tostring(item.target))
        elseif item.label and item.label ~= "" then
            markup_list[#markup_list + 1] = item.label
        elseif item.target and item.target ~= "" then
            markup_list[#markup_list + 1] = tostring(item.target)
        end
    end
    _render_markup(table.concat(markup_list, "  "), theme, context)
end

module.render = function(doc, options)
    if not doc then
        return
    end

    render_serial = render_serial + 1
    local context =
    {
        render_id = render_serial,
        code_block_index = 0,
    }
    local theme = FlowDocTheme.build((options and options.font_zoom_ratio) or (options and options.editor_zoom_ratio) or 1.0)
    context.content_width = _resolve_content_width(theme, options)
    context.enforce_width = options and options.enforce_width == true

    if context.enforce_width and imgui.GetCursorPos and imgui.SetCursorPos then
        local anchor_pos = imgui.GetCursorPos()
        imgui.Dummy(imgui.ImVec2(context.content_width, 0))
        imgui.SetCursorPos(anchor_pos)
    end

    local pushed_title_font = _push_font(theme.body_font, theme.title_font_size)
    _render_wrapped_text(doc.title or "", theme.colors.text, nil, nil, context)
    _pop_font(pushed_title_font)

    if doc.badge_list and #doc.badge_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.item_gap))
        _render_badge_line(doc.badge_list, theme)
    end

    if doc.subtitle_item_list and #doc.subtitle_item_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.item_gap))
        _render_subtitle_item_list(doc.subtitle_item_list, theme)
    elseif doc.subtitle and doc.subtitle ~= "" then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.item_gap))
        _render_wrapped_text(doc.subtitle, theme.colors.muted, theme.body_font, theme.small_font_size, context)
    end

    if doc.meta_list and #doc.meta_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.item_gap))
        _render_meta_list(doc.meta_list, theme, context)
    end

    if doc.signature and doc.signature ~= "" then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_section_title("签名", theme)
        _render_code_panel(doc.signature, "vns", nil, theme, context)
    end

    if doc.brief and doc.brief ~= "" then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_wrapped_text(doc.brief, theme.colors.text, theme.body_font, theme.body_font_size, context)
    end

    if doc.description and doc.description ~= "" then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_section_title("说明", theme)
        _render_markup(doc.description, theme, context)
    end

    if doc.parameter_list and #doc.parameter_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_parameter_list(doc.parameter_list, theme, context)
    end

    if doc.note_list and #doc.note_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_notes(doc.note_list, theme, context)
    end

    if doc.example_list and #doc.example_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_examples(doc.example_list, theme, context)
    end

    if doc.output_list and #doc.output_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_outputs(doc.output_list, theme, context)
    end

    if doc.see_also_list and #doc.see_also_list > 0 then
        imgui.Dummy(imgui.ImVec2(0, theme.spacing.section_gap))
        _render_see_also(doc.see_also_list, theme, context)
    end
end

return module

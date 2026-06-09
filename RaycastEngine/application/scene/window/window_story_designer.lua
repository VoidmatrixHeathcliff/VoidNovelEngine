local imgui = Engine.ImGUI
local rl = Engine.Raylib
local util = Engine.Util

local EditorThemeManager = require("application.framework.editor_theme_manager")
local FlowTextCompletionProvider = require("application.framework.flow_text_completion_provider")
local FlowTextEditorContext = require("application.framework.flow_text_editor_context")
local FlowTextEditorSemantics = require("application.framework.flow_text_editor_semantics")
local FlowTextHoverProvider = require("application.framework.flow_text_hover_provider")
local FlowManager = require("application.framework.flow_manager")
local GlobalContext = require("application.framework.global_context")
local ImGUIHelper = require("application.framework.imgui_helper")
local ResourcesManager = require("application.framework.resources_manager")
local SettingsManager = require("application.framework.settings_manager")

local module = {}

local was_window_focused = false
local pending_tab_select_guid = nil
local pending_window_focus_frames = 0
local STORY_TEXT_EDITOR_NATIVE_CONFIG_REVISION = "vns_highlight_pipeline.dev7"
local STORY_HOVER_TOOLTIP_DELAY_SECONDS = 0.18
local STORY_TEXT_EDITOR_LINE_SPACING = 1.3
local STORY_TOOLTIP_POPUP_SCALE = 1.5
local STORY_COMPLETION_POPUP_SCALE = 1.5
local _is_mouse_in_rect
local _apply_story_editor_input_mode
local _get_story_search_state
local _sync_story_search_to_editor
local _close_story_search_panel
local _open_story_search_panel
local _draw_story_search_panel
local _close_completion_popup
local _build_completion_popup_palette

local STORY_TEXT_ZOOM_OPTION_LIST =
{
    {value = 0.50, label = "50%"},
    {value = 0.75, label = "75%"},
    {value = 1.00, label = "100%"},
    {value = 1.25, label = "125%"},
    {value = 1.50, label = "150%"},
    {value = 2.00, label = "200%"},
}

local TEXT_EDITOR_PALETTE_INDEX =
{
    Default = 1,
    Keyword = 2,
    Number = 3,
    String = 4,
    CharLiteral = 5,
    Punctuation = 6,
    Preprocessor = 7,
    Identifier = 8,
    KnownIdentifier = 9,
    PreprocIdentifier = 10,
    Comment = 11,
    MultiLineComment = 12,
    Background = 13,
    Cursor = 14,
    Selection = 15,
    ErrorMarker = 16,
    Breakpoint = 17,
    LineNumber = 18,
    CurrentLineFill = 19,
    CurrentLineFillInactive = 20,
    CurrentLineEdge = 21,
    ResourceIdentifier = 22,
}

local function _get_document_uid(document)
    return document and (document._resource_guid or document._id) or ""
end

local function _should_suppress_story_tooltip()
    return GlobalContext.is_debug_game == true
end

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

local function _clamp_int(value, min_value, max_value)
    local numeric = math.floor(tonumber(value) or 0)
    if numeric < min_value then
        return min_value
    end
    if numeric > max_value then
        return max_value
    end
    return numeric
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

local function _get_story_text_zoom_ratio()
    if SettingsManager.get_story_text_zoom_ratio then
        return SettingsManager.get_story_text_zoom_ratio()
    end
    return tonumber(SettingsManager.get("story_text_zoom_ratio")) or 1.0
end

local function _set_story_text_zoom_ratio(value)
    if SettingsManager.set_story_text_zoom_ratio then
        return SettingsManager.set_story_text_zoom_ratio(value)
    end
    SettingsManager.set("story_text_zoom_ratio", value)
    return true
end

local function _get_story_text_zoom_label(value)
    local current_value = tonumber(value) or 1.0
    for _, option in ipairs(STORY_TEXT_ZOOM_OPTION_LIST) do
        if math.abs(option.value - current_value) < 0.001 then
            return option.label
        end
    end
    return "100%"
end

local function _get_story_text_zoom_index(value)
    local current_value = tonumber(value) or 1.0
    for index, option in ipairs(STORY_TEXT_ZOOM_OPTION_LIST) do
        if math.abs(option.value - current_value) < 0.001 then
            return index
        end
    end
    return 3
end

local function _show_story_text_zoom_hint(state, ratio)
    state.story_text_zoom_hint_label = _get_story_text_zoom_label(ratio)
    state.story_text_zoom_hint_until = (rl.GetTime() or 0) + 1.35
end

local function _reset_story_hover_tooltip_tracking(state)
    if not state then
        return
    end
    state.hover_tooltip_pending_key = nil
    state.hover_tooltip_pending_since = nil
end

local function _step_story_text_zoom(state, step)
    local current_index = _get_story_text_zoom_index(_get_story_text_zoom_ratio())
    local target_index = _clamp_int(current_index + step, 1, #STORY_TEXT_ZOOM_OPTION_LIST)
    if target_index == current_index then
        return false
    end

    local target_ratio = STORY_TEXT_ZOOM_OPTION_LIST[target_index].value
    if _set_story_text_zoom_ratio(target_ratio) then
        _show_story_text_zoom_hint(state, target_ratio)
        return true
    end
    return false
end

local function _get_story_editor_font()
    return GlobalContext.font_imgui_story_editor or GlobalContext.font_imgui_code or GlobalContext.font_imgui
end

local function _handle_story_text_zoom_shortcuts(state)
    if not state or not state.handle then
        return false
    end

    local io = imgui.GetIO()
    local is_ctrl_down = io and io.KeyCtrl
    if not is_ctrl_down then
        state.story_text_zoom_wheel_accum = 0
        return false
    end

    local is_editor_target = imgui.TextEditor.IsFocused(state.handle)
        or _is_mouse_in_rect(state.last_editor_rect, imgui.GetMousePos())
    if not is_editor_target then
        state.story_text_zoom_wheel_accum = 0
        return false
    end

    local changed = false
    if imgui.IsKeyPressed(imgui.ImGuiKey.Equal, false) or imgui.IsKeyPressed(imgui.ImGuiKey.KeypadAdd, false) then
        changed = _step_story_text_zoom(state, 1) or changed
    end
    if imgui.IsKeyPressed(imgui.ImGuiKey.Minus, false) or imgui.IsKeyPressed(imgui.ImGuiKey.KeypadSubtract, false) then
        changed = _step_story_text_zoom(state, -1) or changed
    end

    local wheel_delta = tonumber(io.MouseWheel) or 0
    if wheel_delta == 0 then
        state.story_text_zoom_wheel_accum = 0
        return changed
    end

    io.MouseWheel = 0
    state.story_text_zoom_wheel_accum = (tonumber(state.story_text_zoom_wheel_accum) or 0) + wheel_delta
    local threshold = 1.0
    while math.abs(state.story_text_zoom_wheel_accum) >= threshold do
        local direction = state.story_text_zoom_wheel_accum > 0 and 1 or -1
        changed = _step_story_text_zoom(state, direction) or changed
        state.story_text_zoom_wheel_accum = state.story_text_zoom_wheel_accum - direction * threshold
    end

    return changed
end

local function _destroy_editor_handle(document)
    if not document or not document.get_ui_state then
        return
    end
    local state = document:get_ui_state("story_editor")
    if state.handle then
        imgui.TextEditor.Destroy(state.handle)
        state.handle = nil
    end
end

local function _build_error_markers(document)
    local markers = {}
    for _, diagnostic in ipairs(document:get_diagnostics() or {}) do
        local diagnostic_guid = diagnostic.flow_guid
        local same_document = diagnostic_guid == nil or diagnostic_guid == document._resource_guid
        if same_document and (diagnostic.severity == "error" or diagnostic.severity == "warning") then
            table.insert(markers,
            {
                line = diagnostic.line or 1,
                message = diagnostic.message or diagnostic.code or "diagnostic",
            })
        end
    end
    return markers
end

local function _count_diagnostics(document)
    local error_count = 0
    local warning_count = 0
    for _, diagnostic in ipairs(document:get_diagnostics() or {}) do
        if diagnostic.severity == "error" then
            error_count = error_count + 1
        elseif diagnostic.severity == "warning" then
            warning_count = warning_count + 1
        end
    end
    return error_count, warning_count
end

local function _navigate_to_diagnostic(document, diagnostic)
    if not diagnostic then
        return
    end

    local target_guid = diagnostic.flow_guid or document._resource_guid
    if target_guid and target_guid ~= document._resource_guid then
        local target_document = FlowManager.get_document(target_guid, "flow_document_open")
        if target_document and target_document.kind == "text" then
            module.open_story_document(target_document, {select = true})
            target_document:request_navigate_to_line(diagnostic.line, diagnostic.column)
            return
        end
    end

    document:request_navigate_to_line(diagnostic.line, diagnostic.column)
end

local function _format_diagnostic_location(document, diagnostic)
    local location = string.format("行:%d, 列:%d", diagnostic.line or 1, diagnostic.column or 1)
    if diagnostic.flow_guid and diagnostic.flow_guid ~= document._resource_guid then
        local target_document = FlowManager.find_by_guid and FlowManager.find_by_guid(diagnostic.flow_guid) or nil
        local target_name = target_document and (target_document._resource_id or target_document._id)
            or diagnostic.path
            or tostring(diagnostic.flow_guid)
        return string.format("%s / %s", tostring(target_name), location)
    end
    return location
end

local function _navigate_to_outline_item(document, item)
    if not document or not item then
        return
    end
    document:request_navigate_to_line(item.line, item.column)
end

local function _ellipsis_text_end(text, max_width)
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
        local prefix = util.UTF8Sub(text, 0, mid)
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

local function _get_table_cell_region()
    return
    {
        min = imgui.GetCursorScreenPos(),
        width = math.max(0, imgui.GetContentRegionAvail().x),
    }
end

local function _draw_centered_text_in_rect(draw_list, rect, text, color_u32, align_right, padding_left, padding_right)
    text = type(text) == "string" and text or ""
    local text_size = imgui.CalcTextSize(text)
    local left = tonumber(padding_left) or 0
    local right = tonumber(padding_right) or 0
    local x = rect.min.x
    if align_right then
        x = rect.min.x + math.max(left, rect.width - text_size.x - right)
    else
        x = rect.min.x + left
    end
    local y = rect.min.y + math.max(0, ((rect.max.y - rect.min.y) - text_size.y) * 0.5)
    draw_list:AddText(imgui.ImVec2(x, y), color_u32, text)
end

local function _make_cell_draw_rect(cell_region, row_rect)
    return
    {
        min = imgui.ImVec2(cell_region.min.x, row_rect.min.y),
        max = imgui.ImVec2(cell_region.min.x + cell_region.width, row_rect.max.y),
        width = cell_region.width,
    }
end

local function _build_text_editor_palette()
    local current_theme = EditorThemeManager.get_current_theme and EditorThemeManager.get_current_theme() or {}
    local is_light = current_theme and current_theme.base_style == "light"

    local bg_0 = _copy_color(EditorThemeManager.get_token("bg_0"), is_light and _make_color(244, 247, 250, 255) or _make_color(18, 22, 28, 255))
    local bg_1 = _copy_color(EditorThemeManager.get_token("bg_1"), is_light and _make_color(251, 252, 254, 255) or _make_color(24, 28, 36, 255))
    local bg_2 = _copy_color(EditorThemeManager.get_token("bg_2"), is_light and _make_color(234, 239, 245, 255) or _make_color(34, 40, 50, 255))
    local fg = _copy_color(EditorThemeManager.get_token("fg"), is_light and _make_color(37, 42, 48, 255) or _make_color(232, 236, 242, 255))
    local fg_muted = _copy_color(EditorThemeManager.get_token("fg_muted"), is_light and _make_color(112, 121, 132, 255) or _make_color(150, 160, 175, 255))
    local border = _copy_color(EditorThemeManager.get_token("border"), is_light and _make_color(193, 203, 214, 255) or _make_color(62, 70, 82, 255))
    local accent_primary = _copy_color(EditorThemeManager.get_token("accent_primary"), _make_color(79, 127, 196, 255))
    local accent_secondary = _copy_color(EditorThemeManager.get_token("accent_secondary"), _make_color(110, 154, 207, 255))
    local accent_success = _copy_color(EditorThemeManager.get_token("accent_success"), _make_color(104, 190, 141, 255))
    local accent_warning = _copy_color(EditorThemeManager.get_token("accent_warning"), _make_color(248, 181, 0, 255))
    local accent_danger = _copy_color(EditorThemeManager.get_token("accent_danger"), _make_color(197, 61, 67, 255))
    local selection = _copy_color(EditorThemeManager.get_token("selection"), _with_alpha(accent_primary, is_light and 0.20 or 0.24))

    local editor_bg =
        is_light
        and _mix_color(bg_1, bg_2, 0.58)
        or _mix_color(bg_0, bg_2, 0.30)
    local punctuation = _mix_color(fg, fg_muted, is_light and 0.10 or 0.06)
    local comment_color = _mix_color(fg_muted, editor_bg, is_light and 0.04 or 0.06)
    local line_number_color = _mix_color(fg_muted, editor_bg, is_light and 0.08 or 0.04)
    local current_line_fill = _with_alpha(_mix_color(editor_bg, bg_2, is_light and 0.22 or 0.38), is_light and 0.56 or 0.30)
    local current_line_fill_inactive = _with_alpha(_mix_color(editor_bg, bg_2, is_light and 0.10 or 0.24), is_light and 0.42 or 0.16)
    local current_line_edge = _with_alpha(border, is_light and 0.58 or 0.34)
    local resource_identifier = _mix_color(
        _mix_color(accent_primary, accent_danger, 0.56),
        fg,
        is_light and 0.42 or 0.30)
    local palette = {}
    palette[TEXT_EDITOR_PALETTE_INDEX.Default] = fg
    palette[TEXT_EDITOR_PALETTE_INDEX.Keyword] = accent_secondary
    palette[TEXT_EDITOR_PALETTE_INDEX.Number] = _mix_color(accent_secondary, fg, is_light and 0.18 or 0.08)
    palette[TEXT_EDITOR_PALETTE_INDEX.String] = accent_success
    palette[TEXT_EDITOR_PALETTE_INDEX.CharLiteral] = _mix_color(accent_danger, fg, is_light and 0.08 or 0.14)
    palette[TEXT_EDITOR_PALETTE_INDEX.Punctuation] = punctuation
    palette[TEXT_EDITOR_PALETTE_INDEX.Preprocessor] = accent_warning
    palette[TEXT_EDITOR_PALETTE_INDEX.Identifier] = fg
    palette[TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier] = accent_primary
    palette[TEXT_EDITOR_PALETTE_INDEX.PreprocIdentifier] = _mix_color(accent_warning, accent_primary, 0.16)
    palette[TEXT_EDITOR_PALETTE_INDEX.Comment] = comment_color
    palette[TEXT_EDITOR_PALETTE_INDEX.MultiLineComment] = comment_color
    palette[TEXT_EDITOR_PALETTE_INDEX.Background] = editor_bg
    palette[TEXT_EDITOR_PALETTE_INDEX.Cursor] = accent_primary
    palette[TEXT_EDITOR_PALETTE_INDEX.Selection] = selection
    palette[TEXT_EDITOR_PALETTE_INDEX.ErrorMarker] = _with_alpha(accent_danger, is_light and 0.18 or 0.22)
    palette[TEXT_EDITOR_PALETTE_INDEX.Breakpoint] = _with_alpha(accent_warning, is_light and 0.18 or 0.22)
    palette[TEXT_EDITOR_PALETTE_INDEX.LineNumber] = line_number_color
    palette[TEXT_EDITOR_PALETTE_INDEX.CurrentLineFill] = current_line_fill
    palette[TEXT_EDITOR_PALETTE_INDEX.CurrentLineFillInactive] = current_line_fill_inactive
    palette[TEXT_EDITOR_PALETTE_INDEX.CurrentLineEdge] = current_line_edge
    palette[TEXT_EDITOR_PALETTE_INDEX.ResourceIdentifier] = resource_identifier
    return palette
end

local function _build_story_search_highlight_colors()
    local current_theme = EditorThemeManager.get_current_theme and EditorThemeManager.get_current_theme() or {}
    local is_light = current_theme and current_theme.base_style == "light"
    local bg_1 = _copy_color(EditorThemeManager.get_token("bg_1"), is_light and _make_color(251, 252, 254, 255) or _make_color(24, 28, 36, 255))
    local bg_2 = _copy_color(EditorThemeManager.get_token("bg_2"), is_light and _make_color(234, 239, 245, 255) or _make_color(34, 40, 50, 255))
    local search_accent = _make_color(72, 128, 206, 255)
    local match_color = _with_alpha(
        _mix_color(search_accent, bg_2, is_light and 0.36 or 0.26),
        is_light and 0.40 or 0.26)
    local current_match_color = _with_alpha(
        _mix_color(search_accent, _mix_color(bg_1, bg_2, is_light and 0.30 or 0.22), is_light and 0.24 or 0.30),
        is_light and 0.60 or 0.44)
    return match_color, current_match_color
end

local function _get_theme_revision()
    local current_theme = EditorThemeManager.get_current_theme and EditorThemeManager.get_current_theme() or {}
    local color_id = EditorThemeManager.get_current_color_id and EditorThemeManager.get_current_color_id() or EditorThemeManager.get_current_theme_id() or ""
    local style_id = EditorThemeManager.get_current_style_id and EditorThemeManager.get_current_style_id() or ""
    return string.format("%s:%s:%s", color_id, style_id, current_theme.base_style or "")
end

local function _ensure_editor_state(document)
    local state = document:get_ui_state("story_editor")
    if not state.handle then
        state.handle = imgui.TextEditor.Create()
        state.synced_revision = -1
        state.marker_revision = -1
        state.palette_revision = ""
        state.symbol_revision = ""
        state.language_id = ""
        state.completion = {}
        if state.search then
            state.search.applied_query = nil
            state.search.applied_case_sensitive = nil
            state.search.applied_whole_word = nil
        end
    end

    if state.native_config_revision ~= STORY_TEXT_EDITOR_NATIVE_CONFIG_REVISION then
        state.native_config_revision = STORY_TEXT_EDITOR_NATIVE_CONFIG_REVISION
        state.synced_revision = -1
        state.marker_revision = -1
        state.palette_revision = ""
        state.symbol_revision = ""
        state.language_id = ""
        state.hover_tooltip_revision = ""
        _reset_story_hover_tooltip_tracking(state)
        if state.search then
            state.search.applied_query = nil
            state.search.applied_case_sensitive = nil
            state.search.applied_whole_word = nil
        end
    end

    if state.language_id ~= "vns" then
        imgui.TextEditor.SetLanguage(state.handle, "vns")
        state.language_id = "vns"
        state.symbol_revision = ""
    end

    imgui.TextEditor.SetShowBuiltInTooltips(state.handle, false)
    imgui.TextEditor.SetLineSpacing(state.handle, STORY_TEXT_EDITOR_LINE_SPACING)

    local semantics = FlowTextEditorSemantics.ensure_cache(document)
    if state.symbol_revision ~= (semantics.semantic_revision or "") then
        imgui.TextEditor.SetLanguageSymbols(state.handle, state.language_id, semantics.symbol_payload)
        state.symbol_revision = semantics.semantic_revision or ""
    end

    local theme_revision = _get_theme_revision()
    if state.palette_revision ~= theme_revision then
        imgui.TextEditor.SetPalette(state.handle, _build_text_editor_palette())
        local match_color, current_match_color = _build_story_search_highlight_colors()
        imgui.TextEditor.SetSearchHighlightColors(state.handle, match_color, current_match_color)
        state.palette_revision = theme_revision
    end

    if state.synced_revision ~= document._source_revision then
        imgui.TextEditor.SetText(state.handle, document:get_source_text())
        state.synced_revision = document._source_revision
    end

    local marker_revision = string.format("%d:%d", document._compiled_revision or 0, #(document:get_diagnostics() or {}))
    if state.marker_revision ~= marker_revision then
        imgui.TextEditor.SetErrorMarkers(state.handle, _build_error_markers(document))
        state.marker_revision = marker_revision
    end

    imgui.TextEditor.SetReadOnly(state.handle, GlobalContext.is_debug_game or false)
    _sync_story_search_to_editor(state, false)
    _apply_story_editor_input_mode(state, not GlobalContext.is_debug_game)
    return state
end

local function _apply_pending_navigation(document, state)
    local pending = document:consume_pending_navigation()
    if pending and state.handle then
        imgui.TextEditor.SetCursorPosition(state.handle, pending.line or 1, pending.column or 1)
    end
end

local function _get_completion_state(state)
    state.completion = state.completion or {}
    state.completion.is_open = state.completion.is_open == true
    state.completion.selected_index = tonumber(state.completion.selected_index) or 1
    state.completion.hovered_index = tonumber(state.completion.hovered_index)
    state.completion.list_start_index = tonumber(state.completion.list_start_index) or 1
    state.completion.candidates = state.completion.candidates or {}
    state.completion.context = state.completion.context or nil
    state.completion.popup_hovered = state.completion.popup_hovered == true
    state.completion.detail_doc_size = state.completion.detail_doc_size or nil
    state.completion.detail_doc_cache = state.completion.detail_doc_cache or {}
    return state.completion
end

_get_story_search_state = function(state)
    state.search = state.search or {}
    local search = state.search
    search.is_open = search.is_open == true
    search.mode = search.mode == "replace" and "replace" or "find"
    search.query_text = type(search.query_text) == "string" and search.query_text or ""
    search.replace_text = type(search.replace_text) == "string" and search.replace_text or ""
    search.query_widget = search.query_widget or util.CString(search.query_text)
    search.replace_widget = search.replace_widget or util.CString(search.replace_text)
    search.case_sensitive = search.case_sensitive == true
    search.whole_word = search.whole_word == true
    search.focus_query = search.focus_query == true
    search.panel_hovered = search.panel_hovered == true
    search.current_index = tonumber(search.current_index) or 0
    search.result_count = tonumber(search.result_count) or 0
    return search
end

_sync_story_search_to_editor = function(state, reveal_current)
    if not state or not state.handle then
        return
    end

    local search = _get_story_search_state(state)
    local query_text = search.is_open and (search.query_widget:get() or "") or ""
    local case_sensitive = search.case_sensitive == true
    local whole_word = search.whole_word == true
    local query_changed = search.applied_query ~= query_text
    local option_changed = search.applied_case_sensitive ~= case_sensitive or search.applied_whole_word ~= whole_word
    local should_reveal = reveal_current == true

    if option_changed then
        imgui.TextEditor.SetSearchOptions(state.handle, case_sensitive, whole_word, false)
        search.applied_case_sensitive = case_sensitive
        search.applied_whole_word = whole_word
    end

    if query_changed or should_reveal then
        imgui.TextEditor.SetSearchQuery(state.handle, query_text, should_reveal)
        search.applied_query = query_text
    end

    search.result_count = imgui.TextEditor.GetSearchResultCount(state.handle)
    search.current_index = imgui.TextEditor.GetCurrentSearchResultIndex(state.handle)
end

_close_story_search_panel = function(state)
    if not state then
        return
    end

    local search = _get_story_search_state(state)
    search.is_open = false
    search.panel_hovered = false
    search.focus_query = false
    search.result_count = 0
    search.current_index = 0
    if state.handle then
        imgui.TextEditor.SetSearchQuery(state.handle, "", false)
    end
    search.applied_query = ""
    search.applied_case_sensitive = search.case_sensitive == true
    search.applied_whole_word = search.whole_word == true
    _reset_story_hover_tooltip_tracking(state)
    _apply_story_editor_input_mode(state, not GlobalContext.is_debug_game)
end

_open_story_search_panel = function(document, state, mode)
    if not state or not state.handle then
        return
    end

    local search = _get_story_search_state(state)
    local was_open = search.is_open == true
    search.is_open = true
    search.mode = mode == "replace" and "replace" or "find"
    search.focus_query = true
    search.panel_hovered = false

    if not was_open then
        local selected_text = imgui.TextEditor.GetSelectedText(state.handle)
        if selected_text ~= "" and not selected_text:find("[\r\n]") then
            search.query_text = selected_text
            search.query_widget:set(selected_text)
        end
    end

    _close_completion_popup(state)
    _reset_story_hover_tooltip_tracking(state)
    _sync_story_search_to_editor(state, true)
    _apply_story_editor_input_mode(state, not GlobalContext.is_debug_game)
end

_apply_story_editor_input_mode = function(state, allow_input)
    if not state or not state.handle then
        return
    end
    local enabled = allow_input == true
    imgui.TextEditor.SetHandleMouseInputs(state.handle, enabled)
    imgui.TextEditor.SetHandleKeyboardInputs(state.handle, enabled)
end

_close_completion_popup = function(state)
    local completion = _get_completion_state(state)
    completion.is_open = false
    completion.context = nil
    completion.candidates = {}
    completion.selected_index = 1
    completion.hovered_index = nil
    completion.list_start_index = 1
    completion.popup_hovered = false
    completion.detail_doc_size = nil
    if state.handle then
        imgui.TextEditor.SetCompletionPopupActive(state.handle, false)
    end
    _apply_story_editor_input_mode(state, not GlobalContext.is_debug_game)
end

local function _sync_document_text_from_editor(document, state)
    local next_text = imgui.TextEditor.GetText(state.handle)
    if document:set_source_text(next_text) then
        state.synced_revision = document._source_revision
        return true
    end
    return false
end

local function _should_draw_story_hover_tooltip(state)
    if not state or not state.handle or _should_suppress_story_tooltip() then
        return false
    end

    local completion = _get_completion_state(state)
    if completion.is_open then
        return false
    end

    if not imgui.TextEditor.IsFocused(state.handle) and not state.last_editor_hovered then
        return false
    end

    if imgui.IsMouseDown(0) or imgui.IsMouseDown(1) then
        return false
    end

    return true
end

local function _get_story_doc_display_bounds(editor_zoom_ratio)
    local margin = math.max(8, math.floor(10 * editor_zoom_ratio + 0.5))
    local viewport = imgui.GetMainViewport()
    if viewport and viewport.WorkPos and viewport.WorkSize then
        local work_pos_x = tonumber(viewport.WorkPos.x) or 0
        local work_pos_y = tonumber(viewport.WorkPos.y) or 0
        local work_size_x = tonumber(viewport.WorkSize.x) or 0
        local work_size_y = tonumber(viewport.WorkSize.y) or 0
        if work_size_x > 0 and work_size_y > 0 then
            return
            {
                min = imgui.ImVec2(work_pos_x + margin, work_pos_y + margin),
                max = imgui.ImVec2(
                    work_pos_x + math.max(margin, work_size_x - margin),
                    work_pos_y + math.max(margin, work_size_y - margin)),
            }
        end
    end

    local io = imgui.GetIO()
    local display_width = io and io.DisplaySize and tonumber(io.DisplaySize.x) or 0
    local display_height = io and io.DisplaySize and tonumber(io.DisplaySize.y) or 0
    return
    {
        min = imgui.ImVec2(margin, margin),
        max = imgui.ImVec2(
            math.max(margin, display_width - margin),
            math.max(margin, display_height - margin)),
    }
end

local function _normalize_compact_doc_text(value)
    if value == nil then
        return ""
    end

    local text = tostring(value)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[ \t]+", " ")
    text = text:match("^%s*(.-)%s*$") or ""
    return text
end

local function _calc_story_doc_text_width(text, font, font_size)
    text = _normalize_compact_doc_text(text)
    if text == "" then
        return 0
    end

    if font and font_size then
        imgui.PushFont(font, font_size)
    end
    local size = imgui.CalcTextSize(text)
    if font and font_size then
        imgui.PopFont()
    end
    return size and tonumber(size.x) or 0
end

local function _draw_story_doc_wrapped_text(text, color, font, font_size)
    text = _normalize_compact_doc_text(text)
    if text == "" then
        return
    end

    imgui.PushFont(font or GlobalContext.font_imgui, font_size)
    imgui.PushStyleColor(imgui.ImGuiCol.Text, color)
    if imgui.PushTextWrapPos then
        imgui.PushTextWrapPos(0)
    end
    imgui.TextUnformatted(text)
    if imgui.PopTextWrapPos then
        imgui.PopTextWrapPos()
    end
    imgui.PopStyleColor()
    imgui.PopFont()
end

local function _is_story_hover_ascii_space(char)
    return char ~= "" and char:match("^%s$") ~= nil
end

local function _is_story_hover_identifier_start(char)
    return char ~= "" and char:match("^[A-Za-z_]$") ~= nil
end

local function _is_story_hover_identifier_part(char)
    return char ~= "" and char:match("^[A-Za-z0-9_]$") ~= nil
end

local function _is_story_hover_label_identifier_start(char)
    local byte = char ~= "" and char:byte(1) or nil
    return _is_story_hover_identifier_start(char) or (byte ~= nil and byte >= 0x80)
end

local function _is_story_hover_label_identifier_part(char)
    local byte = char ~= "" and char:byte(1) or nil
    return _is_story_hover_identifier_part(char) or (byte ~= nil and byte >= 0x80)
end

local function _is_story_hover_hex_digit(char)
    return char ~= "" and char:match("^[0-9A-Fa-f]$") ~= nil
end

local function _find_story_hover_first_non_space_position(text, stop_position)
    local cursor = 1
    local limit = math.min(#text + 1, math.max(1, math.floor(tonumber(stop_position) or (#text + 1))))
    while cursor < limit do
        if not _is_story_hover_ascii_space(text:sub(cursor, cursor)) then
            return cursor
        end
        cursor = cursor + 1
    end
    return limit
end

local function _find_story_hover_previous_non_space_char(text, position)
    local cursor = math.min(#text, math.floor(tonumber(position) or 1) - 1)
    while cursor >= 1 do
        local char = text:sub(cursor, cursor)
        if not _is_story_hover_ascii_space(char) then
            return char, cursor
        end
        cursor = cursor - 1
    end
    return nil, nil
end

local function _is_story_hover_first_non_space_position(text, position)
    return _find_story_hover_first_non_space_position(text, position) == position
end

local function _is_story_hover_label_context(text, hash_position)
    if _is_story_hover_first_non_space_position(text, hash_position) then
        return true
    end

    local previous_char, previous_position = _find_story_hover_previous_non_space_char(text, hash_position)
    return previous_char == ">" and previous_position > 1 and text:sub(previous_position - 1, previous_position - 1) == "-"
end

local function _scan_story_hover_identifier_end(text, cursor)
    local length = #text
    if cursor > length or not _is_story_hover_identifier_start(text:sub(cursor, cursor)) then
        return cursor
    end

    cursor = cursor + 1
    while cursor <= length and _is_story_hover_identifier_part(text:sub(cursor, cursor)) do
        cursor = cursor + 1
    end
    return cursor
end

local function _scan_story_hover_dotted_identifier_end(text, cursor)
    cursor = _scan_story_hover_identifier_end(text, cursor)
    while cursor <= #text and text:sub(cursor, cursor) == "." do
        local next_cursor = _scan_story_hover_identifier_end(text, cursor + 1)
        if next_cursor == cursor + 1 then
            break
        end
        cursor = next_cursor
    end
    return cursor
end

local function _scan_story_hover_label_identifier_end(text, cursor)
    local length = #text
    if cursor > length or not _is_story_hover_label_identifier_start(text:sub(cursor, cursor)) then
        return cursor
    end

    cursor = cursor + 1
    while cursor <= length and _is_story_hover_label_identifier_part(text:sub(cursor, cursor)) do
        cursor = cursor + 1
    end
    return cursor
end

local function _scan_story_hover_string_end(text, cursor)
    if text:sub(cursor, cursor) ~= '"' then
        return cursor
    end

    cursor = cursor + 1
    while cursor <= #text do
        local char = text:sub(cursor, cursor)
        if char == "\\" then
            cursor = math.min(cursor + 2, #text + 1)
        elseif char == '"' then
            return cursor + 1
        else
            cursor = cursor + 1
        end
    end
    return cursor
end

local function _scan_story_hover_hex_color_end(text, hash_position)
    local cursor = hash_position + 1
    local hex_count = 0
    while cursor <= #text and _is_story_hover_hex_digit(text:sub(cursor, cursor)) and hex_count < 8 do
        cursor = cursor + 1
        hex_count = hex_count + 1
    end

    local next_char = text:sub(cursor, cursor)
    if (hex_count == 6 or hex_count == 8)
        and (next_char == "" or (not _is_story_hover_identifier_part(next_char) and next_char ~= ".")) then
        return cursor
    end
    return nil
end

local function _is_story_hover_control_keyword(token)
    return token == "if" or token == "elif" or token == "else" or token == "end" or token == "choice"
end

local function _build_story_hover_signature_symbol_sets(document)
    local sets =
    {
        keywords = {},
        identifiers = {},
        preproc_identifiers = {},
    }
    if not document then
        return sets
    end

    local cache = FlowTextEditorSemantics.ensure_cache(document)
    local payload = cache and cache.symbol_payload or nil
    if type(payload) ~= "table" then
        return sets
    end

    local function fill(target, list)
        for _, item in ipairs(type(list) == "table" and list or {}) do
            local name = type(item) == "table" and item.name or item
            if type(name) == "string" and name ~= "" then
                target[name] = true
            end
        end
    end

    fill(sets.keywords, payload.keywords)
    fill(sets.identifiers, payload.identifiers)
    fill(sets.preproc_identifiers, payload.preproc_identifiers)
    return sets
end

local function _apply_story_hover_identifier_symbol_palette(token, palette_index, symbol_sets)
    if palette_index ~= TEXT_EDITOR_PALETTE_INDEX.Identifier then
        return palette_index
    end
    if symbol_sets and symbol_sets.keywords[token] then
        return TEXT_EDITOR_PALETTE_INDEX.Keyword
    end
    if symbol_sets and symbol_sets.identifiers[token] then
        return TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier
    end
    if symbol_sets and symbol_sets.preproc_identifiers[token] then
        return TEXT_EDITOR_PALETTE_INDEX.PreprocIdentifier
    end
    return palette_index
end

local function _tokenize_story_hover_signature(text, symbol_sets)
    local token_list = {}
    local cursor = 1
    local length = #text

    local function push_token(token, palette_index, next_cursor)
        token_list[#token_list + 1] =
        {
            text = token,
            palette_index = _apply_story_hover_identifier_symbol_palette(token, palette_index, symbol_sets),
        }
        cursor = math.max(cursor + 1, next_cursor or (cursor + #token))
    end

    while cursor <= length do
        local char = text:sub(cursor, cursor)

        if _is_story_hover_ascii_space(char) then
            local next_cursor = cursor + 1
            while next_cursor <= length and _is_story_hover_ascii_space(text:sub(next_cursor, next_cursor)) do
                next_cursor = next_cursor + 1
            end
            push_token(text:sub(cursor, next_cursor - 1), TEXT_EDITOR_PALETTE_INDEX.Default, next_cursor)
        elseif char == ";" then
            push_token(text:sub(cursor), TEXT_EDITOR_PALETTE_INDEX.Comment, length + 1)
        elseif char == "/" and text:sub(cursor + 1, cursor + 1) == "/" then
            push_token(text:sub(cursor), TEXT_EDITOR_PALETTE_INDEX.Comment, length + 1)
        elseif char == '"' then
            local next_cursor = _scan_story_hover_string_end(text, cursor)
            push_token(text:sub(cursor, next_cursor - 1), TEXT_EDITOR_PALETTE_INDEX.String, next_cursor)
        else
            if char == "@" and text:sub(cursor + 1, cursor + 1) == "@" then
                push_token("@@", TEXT_EDITOR_PALETTE_INDEX.CharLiteral, cursor + 2)
            elseif char == "@" then
                push_token("@", TEXT_EDITOR_PALETTE_INDEX.Preprocessor, cursor + 1)
            elseif char == "&" then
                push_token("&", TEXT_EDITOR_PALETTE_INDEX.ResourceIdentifier, cursor + 1)
            elseif char == "-" and text:sub(cursor + 1, cursor + 1) == ">" then
                push_token("->", TEXT_EDITOR_PALETTE_INDEX.Preprocessor, cursor + 2)
            elseif char == "#" then
                if _is_story_hover_label_context(text, cursor)
                    and _is_story_hover_label_identifier_start(text:sub(cursor + 1, cursor + 1)) then
                    push_token("#", TEXT_EDITOR_PALETTE_INDEX.Punctuation, cursor + 1)
                else
                    local hex_end = _scan_story_hover_hex_color_end(text, cursor)
                    if hex_end then
                        push_token(text:sub(cursor, hex_end - 1), TEXT_EDITOR_PALETTE_INDEX.Number, hex_end)
                    elseif _is_story_hover_label_identifier_start(text:sub(cursor + 1, cursor + 1)) then
                        push_token("#", TEXT_EDITOR_PALETTE_INDEX.Punctuation, cursor + 1)
                    else
                        push_token(char, TEXT_EDITOR_PALETTE_INDEX.Default, cursor + 1)
                    end
                end
            elseif char == "$" and _is_story_hover_identifier_start(text:sub(cursor + 1, cursor + 1)) then
                local next_cursor = _scan_story_hover_dotted_identifier_end(text, cursor + 1)
                push_token(text:sub(cursor, next_cursor - 1), TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier, next_cursor)
            elseif text:sub(cursor, cursor + 6) == "global."
                and _is_story_hover_identifier_start(text:sub(cursor + 7, cursor + 7)) then
                local next_cursor = _scan_story_hover_dotted_identifier_end(text, cursor + 7)
                push_token(text:sub(cursor, next_cursor - 1), TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier, next_cursor)
            elseif text:sub(cursor, cursor + 4) == "temp."
                and _is_story_hover_identifier_start(text:sub(cursor + 5, cursor + 5)) then
                local next_cursor = _scan_story_hover_dotted_identifier_end(text, cursor + 5)
                push_token(text:sub(cursor, next_cursor - 1), TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier, next_cursor)
            elseif char:match("^%d$") or (char == "-" and text:sub(cursor + 1, cursor + 1):match("^%d$")) then
                local next_cursor = cursor
                if text:sub(next_cursor, next_cursor) == "-" then
                    next_cursor = next_cursor + 1
                end
                while next_cursor <= length and text:sub(next_cursor, next_cursor):match("^%d$") do
                    next_cursor = next_cursor + 1
                end
                if text:sub(next_cursor, next_cursor) == "." then
                    next_cursor = next_cursor + 1
                    while next_cursor <= length and text:sub(next_cursor, next_cursor):match("^%d$") do
                        next_cursor = next_cursor + 1
                    end
                end
                push_token(text:sub(cursor, next_cursor - 1), TEXT_EDITOR_PALETTE_INDEX.Number, next_cursor)
            else
                local previous_char, previous_position = _find_story_hover_previous_non_space_char(text, cursor)
                if previous_char == "#" and _is_story_hover_label_context(text, previous_position)
                    and _is_story_hover_label_identifier_start(char) then
                    local next_cursor = _scan_story_hover_label_identifier_end(text, cursor)
                    push_token(text:sub(cursor, next_cursor - 1), TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier, next_cursor)
                elseif _is_story_hover_identifier_start(char) then
                    local next_cursor = _scan_story_hover_identifier_end(text, cursor)
                    local token_text = text:sub(cursor, next_cursor - 1)
                    local token_palette_index = TEXT_EDITOR_PALETTE_INDEX.Identifier
                    if previous_char == "&" then
                        token_palette_index = TEXT_EDITOR_PALETTE_INDEX.ResourceIdentifier
                    elseif previous_char == "@" then
                        local is_double_at = previous_position and previous_position > 1
                            and text:sub(previous_position - 1, previous_position - 1) == "@"
                        token_palette_index = is_double_at
                            and TEXT_EDITOR_PALETTE_INDEX.CharLiteral
                            or (_is_story_hover_control_keyword(token_text)
                                and TEXT_EDITOR_PALETTE_INDEX.Keyword
                                or TEXT_EDITOR_PALETTE_INDEX.PreprocIdentifier)
                    elseif previous_char == "#" and _is_story_hover_label_context(text, previous_position) then
                        token_palette_index = TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier
                    else
                        local after_identifier = next_cursor
                        while after_identifier <= length
                            and _is_story_hover_ascii_space(text:sub(after_identifier, after_identifier)) do
                            after_identifier = after_identifier + 1
                        end
                        if text:sub(after_identifier, after_identifier) == ":" then
                            token_palette_index = TEXT_EDITOR_PALETTE_INDEX.KnownIdentifier
                        end
                    end
                    push_token(token_text, token_palette_index, next_cursor)
                elseif char == "(" or char == ")" or char == "[" or char == "]"
                    or char == "{" or char == "}" or char == ":" or char == "," or char == "." then
                    push_token(char, TEXT_EDITOR_PALETTE_INDEX.Punctuation, cursor + 1)
                else
                    push_token(char, TEXT_EDITOR_PALETTE_INDEX.Default, cursor + 1)
                end
            end
        end
    end

    return token_list
end

local function _draw_story_doc_signature_text(text, font_size, document)
    text = _normalize_compact_doc_text(text)
    if text == "" then
        return
    end

    local editor_palette = _build_text_editor_palette()
    local draw_list = imgui.GetWindowDrawList()
    local origin = imgui.GetCursorScreenPos()
    local cursor_x = origin.x
    local cursor_y = origin.y
    local available_width = math.max(1, tonumber(imgui.GetContentRegionAvail().x) or 0)
    local max_width = 1
    local line_height = 1
    local signature_font = GlobalContext.font_imgui
    local pushed_font = false
    if signature_font then
        imgui.PushFont(signature_font, font_size)
        pushed_font = true
    end
    local space_size = imgui.CalcTextSize(" ")
    line_height = math.max(line_height, space_size and space_size.y or 0)

    local symbol_sets = _build_story_hover_signature_symbol_sets(document)
    local token_list = _tokenize_story_hover_signature(text, symbol_sets)
    for _, token in ipairs(token_list) do
        local token_text = token.text or ""
        local token_size = imgui.CalcTextSize(token_text)
        local token_width = token_size and token_size.x or 0
        local token_height = token_size and token_size.y or 0
        line_height = math.max(line_height, token_height)
        if token_text:match("^%s+$") then
            cursor_x = cursor_x + token_width
        else
            if cursor_x > origin.x and (cursor_x - origin.x + token_width) > available_width then
                max_width = math.max(max_width, cursor_x - origin.x)
                cursor_x = origin.x
                cursor_y = cursor_y + line_height
                line_height = math.max(1, token_height)
            end
            if draw_list then
                draw_list:AddText(
                    imgui.ImVec2(cursor_x, cursor_y),
                    imgui.ImColor(editor_palette[token.palette_index] or editor_palette[TEXT_EDITOR_PALETTE_INDEX.Default]):to_u32(),
                    token_text)
            end
            cursor_x = cursor_x + token_width
        end
    end

    if pushed_font then
        imgui.PopFont()
    end
    max_width = math.max(max_width, cursor_x - origin.x)
    local total_height = math.max(1, cursor_y - origin.y + line_height)
    imgui.Dummy(imgui.ImVec2(math.max(1, math.min(available_width, max_width)), total_height))
end

local function _measure_story_doc_tooltip_width(doc, tooltip_zoom_ratio, max_width, signature_safe_padding)
    local signature = _normalize_compact_doc_text(doc.signature)
    local brief = _normalize_compact_doc_text(doc.brief)
    local description = _normalize_compact_doc_text(doc.description)
    local signature_font_size = math.max(13, math.floor(13 * tooltip_zoom_ratio + 0.5))
    local body_font_size = math.max(12, math.floor(12 * tooltip_zoom_ratio + 0.5))
    local horizontal_padding = math.max(24, math.floor(28 * tooltip_zoom_ratio + 0.5))
    signature_safe_padding = math.max(0, tonumber(signature_safe_padding) or 0)
    local min_width = math.min(max_width, math.max(260, math.floor(220 * tooltip_zoom_ratio + 0.5)))
    local content_width = 0

    if signature ~= "" then
        content_width = math.max(
            content_width,
            _calc_story_doc_text_width(signature, GlobalContext.font_imgui, signature_font_size) + signature_safe_padding)
    end
    content_width = math.max(content_width, _calc_story_doc_text_width(brief ~= "" and brief or description, GlobalContext.font_imgui, body_font_size))

    if content_width <= 0 then
        content_width = _calc_story_doc_text_width("暂无说明", GlobalContext.font_imgui, body_font_size)
    end

    return math.max(min_width, math.min(max_width, math.ceil(content_width + horizontal_padding)))
end

local function _draw_story_doc_tooltip(doc, editor_zoom_ratio, options)
    if not doc then
        return false, nil
    end

    options = type(options) == "table" and options or {}
    local tooltip_zoom_ratio = editor_zoom_ratio * STORY_TOOLTIP_POPUP_SCALE
    local display_bounds = options.display_bounds or _get_story_doc_display_bounds(editor_zoom_ratio)
    local tooltip_extra_width = 50
    local signature_safe_padding = options.position and 0 or math.max(12, math.floor(14 * tooltip_zoom_ratio + 0.5))
    local tooltip_max_width = math.max(
        320 * STORY_TOOLTIP_POPUP_SCALE + tooltip_extra_width,
        math.floor(380 * tooltip_zoom_ratio + 0.5) + tooltip_extra_width)
    if display_bounds and display_bounds.min and display_bounds.max then
        local available_width = math.floor((tonumber(display_bounds.max.x) or 0) - (tonumber(display_bounds.min.x) or 0))
        if available_width > 0 then
            tooltip_max_width = math.max(1, math.min(tooltip_max_width, available_width))
        end
    end
    local tooltip_width = _measure_story_doc_tooltip_width(doc, tooltip_zoom_ratio, tooltip_max_width, signature_safe_padding)
    local max_height = tonumber(options.max_height) or 0
    if max_height <= 0 then
        local available_height = display_bounds and display_bounds.min and display_bounds.max
            and math.floor((tonumber(display_bounds.max.y) or 0) - (tonumber(display_bounds.min.y) or 0))
            or 0
        max_height = available_height > 0
            and math.min(available_height, math.max(240 * STORY_TOOLTIP_POPUP_SCALE, math.floor(300 * tooltip_zoom_ratio + 0.5)))
            or (240 * STORY_TOOLTIP_POPUP_SCALE)
    end
    if options.position then
        local position_x = tonumber(options.position.x) or 0
        local position_y = tonumber(options.position.y) or 0
        if display_bounds and display_bounds.min and display_bounds.max then
            local min_x = tonumber(display_bounds.min.x) or position_x
            local max_x = tonumber(display_bounds.max.x) or (position_x + tooltip_width)
            position_x = math.max(min_x, math.min(position_x, max_x - tooltip_width))
            position_y = math.max(tonumber(display_bounds.min.y) or position_y, position_y)
        end
        imgui.SetNextWindowPos(imgui.ImVec2(position_x, position_y), imgui.ImGuiCond.Always)
    end
    imgui.SetNextWindowSizeConstraints(
        imgui.ImVec2(tooltip_width, 0),
        imgui.ImVec2(tooltip_width, max_height))
    local window_hovered = false
    local window_size = nil
    local tooltip_palette = _build_completion_popup_palette(doc.kind, tooltip_zoom_ratio)
    local tooltip_padding = imgui.ImVec2(
        math.max(10, math.floor(11 * tooltip_zoom_ratio + 0.5)),
        math.max(8, math.floor(9 * tooltip_zoom_ratio + 0.5)))
    imgui.PushStyleColor(imgui.ImGuiCol.PopupBg, tooltip_palette.panel_bg)
    imgui.PushStyleColor(imgui.ImGuiCol.WindowBg, tooltip_palette.panel_bg)
    imgui.PushStyleColor(imgui.ImGuiCol.Border, tooltip_palette.panel_outline)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, tooltip_padding)
    imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 1)
    if imgui.BeginTooltip() then
        local colors =
        {
            text = tooltip_palette.item_label,
            muted = tooltip_palette.item_meta,
        }
        local signature = _normalize_compact_doc_text(doc.signature)
        local brief = _normalize_compact_doc_text(doc.brief)
        local description = _normalize_compact_doc_text(doc.description)
        local signature_font_size = math.max(13, math.floor(13 * tooltip_zoom_ratio + 0.5))
        local body_font_size = math.max(12, math.floor(12 * tooltip_zoom_ratio + 0.5))
        local has_content = false

        if signature ~= "" then
            has_content = true
            _draw_story_doc_signature_text(signature, signature_font_size, options.document)
        end

        local summary = ""
        if brief ~= "" then
            summary = brief
        elseif description ~= "" then
            summary = description
        end

        if summary ~= "" then
            if has_content then
                imgui.Dummy(imgui.ImVec2(0, math.max(3, math.floor(4 * tooltip_zoom_ratio + 0.5))))
            end
            has_content = true
            _draw_story_doc_wrapped_text(summary, colors.text, GlobalContext.font_imgui, body_font_size)
        end

        if not has_content then
            imgui.PushFont(GlobalContext.font_imgui, body_font_size)
            imgui.TextColored(colors.muted, "暂无说明")
            imgui.PopFont()
        end

        window_hovered = imgui.IsWindowHovered(imgui.HoveredFlags.RootAndChildWindows | imgui.HoveredFlags.AllowWhenBlockedByActiveItem)
        window_size = imgui.GetWindowSize()
        imgui.EndTooltip()
    end
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(3)
    return window_hovered, window_size
end

local function _draw_story_hover_tooltip(document, state, editor_zoom_ratio)
    if not _should_draw_story_hover_tooltip(state) then
        _reset_story_hover_tooltip_tracking(state)
        return
    end

    local hovered_coords = imgui.TextEditor.GetHoveredCoordinates(state.handle)
    local hovered_line = math.floor(hovered_coords.x or 0)
    local hovered_column = math.floor(hovered_coords.y or 0)
    if hovered_line <= 0 or hovered_column <= 0 then
        _reset_story_hover_tooltip_tracking(state)
        return
    end

    local hovered_word = imgui.TextEditor.GetHoveredWord(state.handle)
    if not hovered_word or hovered_word == "" then
        _reset_story_hover_tooltip_tracking(state)
        return
    end

    local hover_result = FlowTextHoverProvider.resolve(document, hovered_line, hovered_column, hovered_word)
    if not hover_result or not hover_result.doc then
        _reset_story_hover_tooltip_tracking(state)
        return
    end

    local hover_key = string.format(
        "%s|%s|%d|%s",
        tostring(hover_result.context and hover_result.context.kind or ""),
        tostring(hover_result.doc.title or ""),
        tonumber(hovered_line) or 0,
        tostring(hovered_word))
    local now = rl.GetTime and rl.GetTime() or 0
    if state.hover_tooltip_pending_key ~= hover_key then
        state.hover_tooltip_pending_key = hover_key
        state.hover_tooltip_pending_since = now
        return
    end
    if (now - (tonumber(state.hover_tooltip_pending_since) or now)) < STORY_HOVER_TOOLTIP_DELAY_SECONDS then
        return
    end

    _draw_story_doc_tooltip(hover_result.doc, editor_zoom_ratio, {document = document})
end

local function _apply_completion_candidate(document, state, completion, candidate)
    if not candidate or not completion.context then
        return false
    end

    local context = completion.context
    imgui.TextEditor.SetSelection(
        state.handle,
        context.line,
        context.replace_start_col,
        context.line,
        context.replace_end_col)
    imgui.TextEditor.InsertText(state.handle, candidate.insert_text or "")
    local target_column = (context.replace_start_col or 1) + (candidate.cursor_offset or 0)
    imgui.TextEditor.SetCursorPosition(state.handle, context.line, target_column)
    _sync_document_text_from_editor(document, state)
    _close_completion_popup(state)
    return true
end

local function _refresh_completion_popup(document, state, force_open)
    local completion = _get_completion_state(state)
    local cursor = imgui.TextEditor.GetCursorPosition(state.handle)
    local context = FlowTextEditorContext.analyze(document, math.floor(cursor.x or 1), math.floor(cursor.y or 1))
    if not context then
        _close_completion_popup(state)
        return nil
    end

    local candidates = FlowTextCompletionProvider.get_candidates(document, context)
    if #candidates == 0 then
        _close_completion_popup(state)
        return nil
    end

    if not force_open and not completion.is_open and context.auto_trigger ~= true then
        return nil
    end

    local previous_name = completion.candidates[completion.selected_index] and completion.candidates[completion.selected_index].name or nil
    completion.is_open = true
    completion.context = context
    completion.candidates = candidates
    completion.selected_index = 1
    completion.hovered_index = nil
    completion.list_start_index = 1
    if previous_name then
        for index, item in ipairs(candidates) do
            if item.name == previous_name then
                completion.selected_index = index
                break
            end
        end
    end

    return completion
end

local function _prepare_completion_before_render(document, state)
    local completion = _get_completion_state(state)
    local search = _get_story_search_state(state)
    if search.is_open then
        if completion.is_open then
            _close_completion_popup(state)
        end
        if state.handle then
            imgui.TextEditor.SetCompletionPopupActive(state.handle, false)
        end
        _apply_story_editor_input_mode(state, not GlobalContext.is_debug_game)
        return
    end
    local io = imgui.GetIO()
    local manual_trigger = io.KeyShift and not io.KeyCtrl and imgui.IsKeyPressed(imgui.ImGuiKey.Tab, false)
    state.block_completion_keys_this_frame = manual_trigger
    if manual_trigger then
        _refresh_completion_popup(document, state, true)
    end

    if state.handle then
        imgui.TextEditor.SetCompletionPopupActive(state.handle, completion.is_open == true or manual_trigger)
    end
    _apply_story_editor_input_mode(state, not GlobalContext.is_debug_game)
end

local function _resolve_completion_popup_position(state, editor_rect, popup_width, popup_height, editor_zoom_ratio)
    local fallback_x = editor_rect.min.x + math.max(12, math.floor(14 * editor_zoom_ratio + 0.5))
    local fallback_y = editor_rect.min.y + math.max(12, math.floor(14 * editor_zoom_ratio + 0.5))
    local x = fallback_x
    local y = fallback_y
    local margin = math.max(8, math.floor(10 * editor_zoom_ratio + 0.5))

    if state.handle then
        local cursor_screen_pos = imgui.TextEditor.GetCursorScreenPosition(state.handle)
        if cursor_screen_pos and ((cursor_screen_pos.x or 0) > 0 or (cursor_screen_pos.y or 0) > 0) then
            local line_height = tonumber(imgui.GetTextLineHeightWithSpacing and imgui.GetTextLineHeightWithSpacing()) or math.max(18, 20 * editor_zoom_ratio)
            x = (cursor_screen_pos.x or x)
            y = (cursor_screen_pos.y or y) + line_height + math.max(2, math.floor(2 * editor_zoom_ratio + 0.5))
        end
    end

    if x + popup_width > editor_rect.max.x - margin then
        x = math.max(editor_rect.min.x + margin, editor_rect.max.x - popup_width - margin)
    end
    if y + popup_height > editor_rect.max.y - margin then
        local line_height = tonumber(imgui.GetTextLineHeightWithSpacing and imgui.GetTextLineHeightWithSpacing()) or math.max(18, 20 * editor_zoom_ratio)
        local above_y = y - popup_height - line_height - math.max(4, math.floor(4 * editor_zoom_ratio + 0.5))
        if above_y >= editor_rect.min.y + margin then
            y = above_y
        else
            y = math.max(editor_rect.min.y + margin, editor_rect.max.y - popup_height - margin)
        end
    end

    return imgui.ImVec2(x, y)
end

local function _get_completion_popup_accent(kind, fallback_primary, fallback_secondary, fallback_warning, fallback_success, fallback_danger)
    if kind == "command" then
        return _make_color(72, 128, 206, 255)
    end
    if kind == "directive" then
        return _copy_color(fallback_danger, _make_color(204, 84, 89, 255))
    end
    if kind == "parameter" then
        return _copy_color(fallback_primary, _make_color(79, 127, 196, 255))
    end
    if kind == "label" then
        return _copy_color(fallback_success, _make_color(96, 184, 139, 255))
    end
    if kind == "resource_type" then
        return _mix_color(_copy_color(fallback_secondary, _make_color(115, 147, 209, 255)), _copy_color(fallback_danger, _make_color(174, 94, 178, 255)), 0.46)
    end
    if kind == "flow_locator" then
        return _mix_color(_copy_color(fallback_primary, _make_color(79, 127, 196, 255)), _copy_color(fallback_success, _make_color(96, 184, 139, 255)), 0.32)
    end
    return _copy_color(fallback_secondary or fallback_primary, _make_color(110, 154, 207, 255))
end

_build_completion_popup_palette = function(kind, editor_zoom_ratio)
    local current_theme = EditorThemeManager.get_current_theme and EditorThemeManager.get_current_theme() or {}
    local is_light = current_theme and current_theme.base_style == "light"
    local bg_0 = _copy_color(EditorThemeManager.get_token("bg_0"), is_light and _make_color(244, 247, 250, 255) or _make_color(18, 22, 28, 255))
    local bg_1 = _copy_color(EditorThemeManager.get_token("bg_1"), is_light and _make_color(251, 252, 254, 255) or _make_color(24, 28, 36, 255))
    local bg_2 = _copy_color(EditorThemeManager.get_token("bg_2"), is_light and _make_color(234, 239, 245, 255) or _make_color(34, 40, 50, 255))
    local fg = _copy_color(EditorThemeManager.get_token("fg"), is_light and _make_color(37, 42, 48, 255) or _make_color(232, 236, 242, 255))
    local fg_muted = _copy_color(EditorThemeManager.get_token("fg_muted"), is_light and _make_color(112, 121, 132, 255) or _make_color(150, 160, 175, 255))
    local border = _copy_color(EditorThemeManager.get_token("border"), is_light and _make_color(193, 203, 214, 255) or _make_color(62, 70, 82, 255))
    local accent_primary = _copy_color(EditorThemeManager.get_token("accent_primary"), _make_color(79, 127, 196, 255))
    local accent_secondary = _copy_color(EditorThemeManager.get_token("accent_secondary"), _make_color(110, 154, 207, 255))
    local accent_success = _copy_color(EditorThemeManager.get_token("accent_success"), _make_color(104, 190, 141, 255))
    local accent_warning = _copy_color(EditorThemeManager.get_token("accent_warning"), _make_color(248, 181, 0, 255))
    local accent_danger = _copy_color(EditorThemeManager.get_token("accent_danger"), _make_color(197, 61, 67, 255))
    local accent = _get_completion_popup_accent(kind, accent_primary, accent_secondary, accent_warning, accent_success, accent_danger)

    return
    {
        is_light = is_light,
        accent = accent,
        panel_bg = _with_alpha(_mix_color(bg_1, bg_2, is_light and 0.18 or 0.24), is_light and 0.98 or 0.94),
        panel_outline = _with_alpha(_mix_color(border, accent, is_light and 0.08 or 0.12), is_light and 0.62 or 0.48),
        header_line = _with_alpha(_mix_color(border, accent, is_light and 0.10 or 0.14), is_light and 0.72 or 0.44),
        title_text = fg,
        count_text = _with_alpha(fg_muted, is_light and 0.96 or 0.94),
        hint_text = _with_alpha(fg_muted, is_light and 0.88 or 0.86),
        list_bg = _with_alpha(bg_1, is_light and 0.04 or 0.10),
        item_hover_bg = _with_alpha(_mix_color(bg_1, accent, is_light and 0.05 or 0.10), is_light and 0.82 or 0.36),
        item_selected_bg = _with_alpha(_mix_color(bg_1, accent, is_light and 0.11 or 0.18), is_light and 0.94 or 0.54),
        item_strip = _with_alpha(accent, is_light and 0.90 or 0.78),
        item_label = fg,
        item_label_selected = fg,
        item_meta = _with_alpha(fg_muted, is_light and 0.92 or 0.90),
        item_tag = _mix_color(fg_muted, accent, is_light and 0.14 or 0.20),
        item_tag_bg = _with_alpha(_mix_color(bg_2, accent, is_light and 0.06 or 0.10), is_light and 0.88 or 0.46),
        item_separator = _with_alpha(border, is_light and 0.24 or 0.16),
        scrollbar_grab = _with_alpha(border, is_light and 0.54 or 0.42),
        scrollbar_grab_hovered = _with_alpha(_mix_color(border, accent, is_light and 0.12 or 0.18), is_light and 0.72 or 0.56),
        scrollbar_grab_active = _with_alpha(_mix_color(border, accent, is_light and 0.18 or 0.26), is_light and 0.86 or 0.68),
        rounding = math.max(7, math.floor(8 * editor_zoom_ratio + 0.5)),
    }
end

local function _begin_story_popup_window(window_id, position, size, editor_zoom_ratio, palette, extra_flags)
    local popup_flags = imgui.WindowFlags.NoTitleBar
        | imgui.WindowFlags.NoResize
        | imgui.WindowFlags.NoMove
        | imgui.WindowFlags.NoSavedSettings
        | imgui.WindowFlags.NoDocking
        | imgui.WindowFlags.NoFocusOnAppearing
        | imgui.WindowFlags.NoNavFocus
    if extra_flags ~= nil then
        popup_flags = popup_flags | extra_flags
    end

    local window_bg = palette and palette.panel_bg or _mix_color(EditorThemeManager.get_token("bg_1"), EditorThemeManager.get_token("bg_2"), 0.58)
    local border_color = palette and palette.panel_outline or _copy_color(EditorThemeManager.get_token("border"), _make_color(84, 92, 104, 255))
    local window_padding = imgui.ImVec2(
        math.max(10, math.floor(11 * editor_zoom_ratio + 0.5)),
        math.max(10, math.floor(11 * editor_zoom_ratio + 0.5)))
    local window_rounding = palette and palette.rounding or math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))

    imgui.SetNextWindowPos(position, imgui.ImGuiCond.Always)
    imgui.SetNextWindowSize(size, imgui.ImGuiCond.Always)
    imgui.PushStyleColor(imgui.ImGuiCol.WindowBg, window_bg)
    imgui.PushStyleColor(imgui.ImGuiCol.Border, border_color)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, window_padding)
    imgui.PushStyleVar(imgui.StyleVar.WindowRounding, window_rounding)
    imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 1)
    local is_open = imgui.Begin(window_id, nil, popup_flags)
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(2)
    return is_open
end

local function _draw_story_search_panel_header(title_text, count_text, editor_zoom_ratio, palette)
    local header_min = imgui.GetCursorScreenPos()
    local header_width = math.max(1, imgui.GetContentRegionAvail().x)
    local header_font_size = math.max(13, math.floor(13 * editor_zoom_ratio + 0.5))
    local header_height = math.max(18, math.floor(20 * editor_zoom_ratio + 0.5))
    local pad_x = math.max(1, math.floor(2 * editor_zoom_ratio + 0.5))
    local draw_list = imgui.GetWindowDrawList()

    imgui.PushFont(GlobalContext.font_imgui, header_font_size)
    local title_size = imgui.CalcTextSize(title_text)
    local count_size = imgui.CalcTextSize(count_text)
    draw_list:AddText(
        imgui.ImVec2(header_min.x + pad_x, header_min.y + math.max(0, (header_height - title_size.y) * 0.5)),
        imgui.ImColor(palette.title_text):to_u32(),
        title_text)
    draw_list:AddText(
        imgui.ImVec2(header_min.x + math.max(0, header_width - pad_x - count_size.x), header_min.y + math.max(0, (header_height - count_size.y) * 0.5)),
        imgui.ImColor(palette.count_text):to_u32(),
        count_text)
    imgui.PopFont()

    draw_list:AddRectFilled(
        imgui.ImVec2(header_min.x, header_min.y + header_height + math.max(2, math.floor(2 * editor_zoom_ratio + 0.5))),
        imgui.ImVec2(header_min.x + header_width, header_min.y + header_height + math.max(3, math.floor(3 * editor_zoom_ratio + 0.5))),
        imgui.ImColor(palette.header_line):to_u32())
    imgui.Dummy(imgui.ImVec2(header_width, header_height + math.max(5, math.floor(6 * editor_zoom_ratio + 0.5))))
end

local function _draw_story_search_icon_button(id, icon_id, size, active, tooltip, palette)
    local accent = active and palette.accent or palette.count_text
    local button_bg = active
        and _with_alpha(_mix_color(palette.panel_bg, palette.accent, palette.is_light and 0.18 or 0.28), palette.is_light and 0.96 or 0.92)
        or _with_alpha(_mix_color(palette.panel_bg, palette.list_bg, palette.is_light and 0.46 or 0.60), palette.is_light and 0.92 or 0.78)
    local button_hover = _with_alpha(_mix_color(button_bg, palette.accent, palette.is_light and 0.14 or 0.22), palette.is_light and 0.98 or 0.96)
    local button_active = _with_alpha(_mix_color(button_bg, palette.accent, palette.is_light and 0.22 or 0.30), 1.0)
    local button_border = active
        and _with_alpha(_mix_color(palette.panel_outline, palette.accent, palette.is_light and 0.42 or 0.38), palette.is_light and 0.94 or 0.88)
        or _with_alpha(palette.panel_outline, palette.is_light and 0.60 or 0.42)

    imgui.PushStyleColor(imgui.ImGuiCol.Button, button_bg)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, button_hover)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, button_active)
    imgui.PushStyleColor(imgui.ImGuiCol.Border, button_border)
    imgui.PushStyleVar(imgui.StyleVar.FrameBorderSize, 1)
    imgui.PushStyleVar(imgui.StyleVar.FrameRounding, math.max(4, math.floor((tonumber(size and size.y) or 20) * 0.24 + 0.5)))
    local clicked = imgui.ImageButton(id, ResourcesManager.find_icon(icon_id), size, nil, nil, nil, accent)
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(4)

    if tooltip and imgui.IsItemHovered(imgui.HoveredFlags.ForTooltip) then
        local tooltip_font_size = math.max(14, math.floor((tonumber(size and size.y) or 18) * 0.82 + 0.5))
        imgui.BeginTooltip()
            imgui.PushFont(GlobalContext.font_imgui, tooltip_font_size)
            imgui.TextUnformatted(tooltip)
            imgui.PopFont()
        imgui.EndTooltip()
    end

    return clicked
end

_draw_story_search_panel = function(document, state, editor_rect, editor_zoom_ratio)
    local search = _get_story_search_state(state)
    if not search.is_open or not state.handle or not editor_rect or not editor_rect.min or not editor_rect.max then
        return
    end

    if was_window_focused and imgui.IsKeyPressed(imgui.ImGuiKey.Escape, false) then
        _close_story_search_panel(state)
        return
    end

    local panel_palette = _build_completion_popup_palette("parameter", editor_zoom_ratio)
    local margin = math.max(8, math.floor(10 * editor_zoom_ratio + 0.5))
    local desired_width = math.max(320, math.floor(388 * editor_zoom_ratio + 0.5))
    local available_width = math.max(1, math.floor((editor_rect.max.x - editor_rect.min.x) - margin * 2))
    local panel_width = math.min(desired_width, available_width)
    if panel_width <= 0 then
        panel_width = desired_width
    end
    local panel_height = search.mode == "replace"
        and math.max(108, math.floor(120 * editor_zoom_ratio + 0.5))
        or math.max(72, math.floor(82 * editor_zoom_ratio + 0.5))
    local panel_position = imgui.ImVec2(
        math.max(editor_rect.min.x + margin, editor_rect.max.x - panel_width - margin),
        editor_rect.min.y + margin)
    local panel_id = string.format("story_search_panel_%s", _get_document_uid(document))

    local is_open = _begin_story_popup_window(panel_id, panel_position, imgui.ImVec2(panel_width, panel_height), editor_zoom_ratio, panel_palette)
    if not is_open then
        imgui.End()
        return
    end

    search.panel_hovered = imgui.IsWindowHovered(imgui.HoveredFlags.RootAndChildWindows | imgui.HoveredFlags.AllowWhenBlockedByActiveItem)

    local button_size = imgui.ImVec2(
        math.max(20, math.floor(22 * editor_zoom_ratio + 0.5)),
        math.max(20, math.floor(22 * editor_zoom_ratio + 0.5)))
    local query_icon_size = imgui.ImVec2(
        math.max(15, math.floor(16 * editor_zoom_ratio + 0.5)),
        math.max(15, math.floor(16 * editor_zoom_ratio + 0.5)))
    local row_spacing = math.max(4, math.floor(5 * editor_zoom_ratio + 0.5))
    local frame_padding_x = math.max(6, math.floor(7 * editor_zoom_ratio + 0.5))
    local frame_padding_y = math.max(3, math.floor(3 * editor_zoom_ratio + 0.5))

    imgui.PushStyleColor(imgui.ImGuiCol.FrameBg, _with_alpha(_mix_color(panel_palette.panel_bg, panel_palette.list_bg, panel_palette.is_light and 0.58 or 0.74), panel_palette.is_light and 0.96 or 0.84))
    imgui.PushStyleColor(imgui.ImGuiCol.FrameBgHovered, _with_alpha(_mix_color(panel_palette.panel_bg, panel_palette.accent, panel_palette.is_light and 0.10 or 0.16), panel_palette.is_light and 0.98 or 0.90))
    imgui.PushStyleColor(imgui.ImGuiCol.FrameBgActive, _with_alpha(_mix_color(panel_palette.panel_bg, panel_palette.accent, panel_palette.is_light and 0.14 or 0.20), 1.0))
    imgui.PushStyleColor(imgui.ImGuiCol.Border, _with_alpha(panel_palette.panel_outline, panel_palette.is_light and 0.64 or 0.46))
    imgui.PushStyleVar(imgui.StyleVar.FrameBorderSize, 1)
    imgui.PushStyleVar(imgui.StyleVar.FrameRounding, math.max(5, math.floor(6 * editor_zoom_ratio + 0.5)))
    imgui.PushStyleVar(imgui.StyleVar.FramePadding, imgui.ImVec2(frame_padding_x, frame_padding_y))
    imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(row_spacing, row_spacing))

    local count_text = string.format("第%d项，共%d项", search.current_index or 0, search.result_count or 0)
    _draw_story_search_panel_header(search.mode == "replace" and "替换" or "查找", count_text, editor_zoom_ratio, panel_palette)

    local search_icon = ResourcesManager.find_icon("search-line")
    if search_icon then
        imgui.Image(search_icon, query_icon_size, nil, nil, panel_palette.accent, nil)
        imgui.SameLine(0, row_spacing)
    end

    local query_button_total_width = button_size.x * 4 + row_spacing * 3
    local query_input_width = math.max(96, imgui.GetContentRegionAvail().x - query_button_total_width)
    if search.focus_query then
        imgui.SetKeyboardFocusHere()
        search.focus_query = false
    end
    imgui.SetNextItemWidth(query_input_width)
    imgui.InputText(string.format("##story_search_query_%s", _get_document_uid(document)), search.query_widget)
    local query_active = imgui.IsItemActive()
    search.query_text = search.query_widget:get() or ""

    imgui.SameLine(0, row_spacing)
    local case_toggled = _draw_story_search_icon_button(
        string.format("##story_search_case_%s", _get_document_uid(document)),
        "font-size",
        button_size,
        search.case_sensitive == true,
        "区分大小写",
        panel_palette)
    if case_toggled then
        search.case_sensitive = not search.case_sensitive
    end

    imgui.SameLine(0, row_spacing)
    local whole_word_toggled = _draw_story_search_icon_button(
        string.format("##story_search_whole_%s", _get_document_uid(document)),
        "letter-spacing-2",
        button_size,
        search.whole_word == true,
        "全字匹配",
        panel_palette)
    if whole_word_toggled then
        search.whole_word = not search.whole_word
    end

    _sync_story_search_to_editor(state, false)

    local has_query = search.query_text ~= ""
    local has_results = has_query and (search.result_count or 0) > 0
    local previous_clicked = false
    local next_clicked = false
    imgui.SameLine(0, row_spacing)
    imgui.BeginDisabled(not has_results)
        previous_clicked = _draw_story_search_icon_button(
            string.format("##story_search_prev_%s", _get_document_uid(document)),
            "arrow-up-long-line",
            button_size,
            false,
            "上一项",
            panel_palette)
        imgui.SameLine(0, row_spacing)
        next_clicked = _draw_story_search_icon_button(
            string.format("##story_search_next_%s", _get_document_uid(document)),
            "arrow-down-long-line",
            button_size,
            false,
            "下一项",
            panel_palette)
    imgui.EndDisabled()

    if query_active and has_results and imgui.IsKeyPressed(imgui.ImGuiKey.Enter, false) then
        local io = imgui.GetIO()
        if io and io.KeyShift then
            imgui.TextEditor.FindPreviousSearchResult(state.handle)
        else
            imgui.TextEditor.FindNextSearchResult(state.handle)
        end
        _sync_story_search_to_editor(state, false)
    elseif previous_clicked then
        imgui.TextEditor.FindPreviousSearchResult(state.handle)
        _sync_story_search_to_editor(state, false)
    elseif next_clicked then
        imgui.TextEditor.FindNextSearchResult(state.handle)
        _sync_story_search_to_editor(state, false)
    end

    if search.mode == "replace" then
        local replace_button_total_width = button_size.x * 2 + row_spacing
        imgui.SetNextItemWidth(math.max(96, imgui.GetContentRegionAvail().x - replace_button_total_width))
        imgui.InputText(string.format("##story_replace_query_%s", _get_document_uid(document)), search.replace_widget)
        search.replace_text = search.replace_widget:get() or ""

        local replace_current_clicked = false
        local replace_all_clicked = false
        imgui.SameLine(0, row_spacing)
        imgui.BeginDisabled(not has_results)
            replace_current_clicked = _draw_story_search_icon_button(
                string.format("##story_search_replace_current_%s", _get_document_uid(document)),
                "find-replace-line",
                button_size,
                false,
                "替换当前匹配",
                panel_palette)
            imgui.SameLine(0, row_spacing)
            replace_all_clicked = _draw_story_search_icon_button(
                string.format("##story_search_replace_all_%s", _get_document_uid(document)),
                "menu-search-line",
                button_size,
                false,
                "全部替换",
                panel_palette)
        imgui.EndDisabled()

        local replaced = false
        if replace_current_clicked then
            replaced = imgui.TextEditor.ReplaceCurrentSearchResult(state.handle, search.replace_text or "") == true
        elseif replace_all_clicked then
            replaced = (tonumber(imgui.TextEditor.ReplaceAllSearchResults(state.handle, search.replace_text or "")) or 0) > 0
        end

        if replaced then
            _sync_document_text_from_editor(document, state)
            _reset_story_hover_tooltip_tracking(state)
            _sync_story_search_to_editor(state, false)
        end
    end

    imgui.PopStyleVar(4)
    imgui.PopStyleColor(4)
    imgui.End()
end

_draw_story_search_panel_header = function(title_text, count_text, editor_zoom_ratio, palette)
    local header_min = imgui.GetCursorScreenPos()
    local header_width = math.max(1, imgui.GetContentRegionAvail().x)
    local title_font_size = math.max(16, math.floor(17 * editor_zoom_ratio + 0.5))
    local count_font_size = math.max(12, math.floor(12 * editor_zoom_ratio + 0.5))
    local header_height = math.max(22, math.floor(24 * editor_zoom_ratio + 0.5))
    local pad_x = math.max(2, math.floor(3 * editor_zoom_ratio + 0.5))
    local draw_list = imgui.GetWindowDrawList()

    imgui.PushFont(GlobalContext.font_imgui, title_font_size)
    local title_size = imgui.CalcTextSize(title_text)
    imgui.PopFont()
    imgui.PushFont(GlobalContext.font_imgui, count_font_size)
    local count_size = imgui.CalcTextSize(count_text)
    imgui.PopFont()

    imgui.PushFont(GlobalContext.font_imgui, title_font_size)
    draw_list:AddText(
        imgui.ImVec2(header_min.x + pad_x, header_min.y + math.max(0, (header_height - title_size.y) * 0.5)),
        imgui.ImColor(palette.title_text):to_u32(),
        title_text)
    imgui.PopFont()

    imgui.PushFont(GlobalContext.font_imgui, count_font_size)
    draw_list:AddText(
        imgui.ImVec2(header_min.x + math.max(0, header_width - pad_x - count_size.x), header_min.y + math.max(0, (header_height - count_size.y) * 0.5)),
        imgui.ImColor(palette.count_text):to_u32(),
        count_text)
    imgui.PopFont()

    draw_list:AddRectFilled(
        imgui.ImVec2(header_min.x, header_min.y + header_height + math.max(2, math.floor(2 * editor_zoom_ratio + 0.5))),
        imgui.ImVec2(header_min.x + header_width, header_min.y + header_height + math.max(3, math.floor(3 * editor_zoom_ratio + 0.5))),
        imgui.ImColor(palette.header_line):to_u32())
    imgui.Dummy(imgui.ImVec2(header_width, header_height + math.max(5, math.floor(5 * editor_zoom_ratio + 0.5))))
end

_draw_story_search_panel = function(document, state, editor_rect, editor_zoom_ratio)
    local search = _get_story_search_state(state)
    if not search.is_open or not state.handle or not editor_rect or not editor_rect.min or not editor_rect.max then
        return
    end

    if was_window_focused and imgui.IsKeyPressed(imgui.ImGuiKey.Escape, false) then
        _close_story_search_panel(state)
        return
    end

    local panel_palette = _build_completion_popup_palette("parameter", editor_zoom_ratio)
    local margin_x = math.max(18, math.floor(22 * editor_zoom_ratio + 0.5))
    local margin_y = math.max(10, math.floor(12 * editor_zoom_ratio + 0.5))
    local desired_width = math.max(336, math.floor(352 * editor_zoom_ratio + 0.5))
    local available_width = math.max(1, math.floor((editor_rect.max.x - editor_rect.min.x) - margin_x * 2))
    local panel_width = math.min(desired_width, available_width)
    if panel_width <= 0 then
        panel_width = desired_width
    end

    local row_spacing = math.max(4, math.floor(4 * editor_zoom_ratio + 0.5))
    local frame_padding = math.max(4, math.floor(4 * editor_zoom_ratio + 0.5))
    local window_padding_y = math.max(10, math.floor(11 * editor_zoom_ratio + 0.5))
    local header_height = math.max(22, math.floor(24 * editor_zoom_ratio + 0.5))
    local header_gap = math.max(5, math.floor(5 * editor_zoom_ratio + 0.5))
    local footer_gap = math.max(3, math.floor(4 * editor_zoom_ratio + 0.5))
    local footer_font_size = math.max(11, math.floor(11 * editor_zoom_ratio + 0.5))
    local footer_text_height = math.max(footer_font_size + 1, math.floor(12 * editor_zoom_ratio + 0.5))
    local widget_height = math.max(22, math.floor((tonumber(imgui.GetTextLineHeight()) or 0) + frame_padding * 2 + 2.5))
    local panel_content_height = header_height + header_gap + widget_height + footer_gap + row_spacing + footer_text_height
    if search.mode == "replace" then
        panel_content_height = panel_content_height + row_spacing + widget_height
    end
    local panel_height = window_padding_y * 2 + panel_content_height
    local panel_position = imgui.ImVec2(
        math.max(editor_rect.min.x + margin_x, editor_rect.max.x - panel_width - margin_x),
        editor_rect.min.y + margin_y)
    local panel_id = string.format("story_search_panel_%s", _get_document_uid(document))
    local panel_window_flags = imgui.WindowFlags.NoScrollbar | imgui.WindowFlags.NoScrollWithMouse

    local is_open = _begin_story_popup_window(
        panel_id,
        panel_position,
        imgui.ImVec2(panel_width, panel_height),
        editor_zoom_ratio,
        panel_palette,
        panel_window_flags)
    if not is_open then
        imgui.End()
        return
    end

    search.panel_hovered = imgui.IsWindowHovered(imgui.HoveredFlags.RootAndChildWindows | imgui.HoveredFlags.AllowWhenBlockedByActiveItem)
    local panel_focused = imgui.IsWindowFocused(imgui.FocusedFlags.RootAndChildWindows)

    imgui.PushStyleColor(imgui.ImGuiCol.FrameBg, _with_alpha(_mix_color(panel_palette.panel_bg, panel_palette.list_bg, panel_palette.is_light and 0.58 or 0.74), panel_palette.is_light and 0.96 or 0.84))
    imgui.PushStyleColor(imgui.ImGuiCol.FrameBgHovered, _with_alpha(_mix_color(panel_palette.panel_bg, panel_palette.accent, panel_palette.is_light and 0.10 or 0.16), panel_palette.is_light and 0.98 or 0.90))
    imgui.PushStyleColor(imgui.ImGuiCol.FrameBgActive, _with_alpha(_mix_color(panel_palette.panel_bg, panel_palette.accent, panel_palette.is_light and 0.14 or 0.20), 1.0))
    imgui.PushStyleColor(imgui.ImGuiCol.Border, _with_alpha(panel_palette.panel_outline, panel_palette.is_light and 0.64 or 0.46))
    imgui.PushStyleVar(imgui.StyleVar.FrameBorderSize, 1)
    imgui.PushStyleVar(imgui.StyleVar.FrameRounding, math.max(5, math.floor(6 * editor_zoom_ratio + 0.5)))
    imgui.PushStyleVar(imgui.StyleVar.FramePadding, imgui.ImVec2(frame_padding, frame_padding))
    imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(row_spacing, row_spacing))

    local button_extent = math.max(22, math.floor(imgui.GetFrameHeight() + 0.5))
    local button_image_extent = math.max(12, button_extent - frame_padding * 2)
    local button_size = imgui.ImVec2(button_image_extent, button_image_extent)
    local compact_row_width = button_extent * 4 + row_spacing * 4
    local query_input_width = math.max(
        96,
        math.min(
            math.max(96, imgui.GetContentRegionAvail().x - compact_row_width),
            math.max(176, math.floor(192 * editor_zoom_ratio + 0.5))))

    local count_text = string.format("第%d项，共%d项", search.current_index or 0, search.result_count or 0)
    _draw_story_search_panel_header(search.mode == "replace" and "替换" or "查找", count_text, editor_zoom_ratio, panel_palette)

    if search.focus_query then
        imgui.SetKeyboardFocusHere()
        search.focus_query = false
    end
    imgui.SetNextItemWidth(query_input_width)
    imgui.InputText(string.format("##story_search_query_%s", _get_document_uid(document)), search.query_widget)
    local query_active = imgui.IsItemActive() or imgui.IsItemFocused()
    search.query_text = search.query_widget:get() or ""

    imgui.SameLine(0, row_spacing)
    local case_toggled = _draw_story_search_icon_button(
        string.format("##story_search_case_%s", _get_document_uid(document)),
        "font-size",
        button_size,
        search.case_sensitive == true,
        "区分大小写",
        panel_palette)
    if case_toggled then
        search.case_sensitive = not search.case_sensitive
    end

    imgui.SameLine(0, row_spacing)
    local whole_word_toggled = _draw_story_search_icon_button(
        string.format("##story_search_whole_%s", _get_document_uid(document)),
        "letter-spacing-2",
        button_size,
        search.whole_word == true,
        "全字匹配",
        panel_palette)
    if whole_word_toggled then
        search.whole_word = not search.whole_word
    end

    _sync_story_search_to_editor(state, false)

    local has_query = search.query_text ~= ""
    local has_results = has_query and (search.result_count or 0) > 0
    local previous_clicked = false
    local next_clicked = false

    imgui.SameLine(0, row_spacing)
    imgui.BeginDisabled(not has_results)
        previous_clicked = _draw_story_search_icon_button(
            string.format("##story_search_prev_%s", _get_document_uid(document)),
            "arrow-up-long-line",
            button_size,
            false,
            "上一项",
            panel_palette)
        imgui.SameLine(0, row_spacing)
        next_clicked = _draw_story_search_icon_button(
            string.format("##story_search_next_%s", _get_document_uid(document)),
            "arrow-down-long-line",
            button_size,
            false,
            "下一项",
            panel_palette)
    imgui.EndDisabled()

    if query_active and has_results and imgui.IsKeyPressed(imgui.ImGuiKey.Enter, false) then
        local io = imgui.GetIO()
        if io and io.KeyShift then
            imgui.TextEditor.FindPreviousSearchResult(state.handle)
        else
            imgui.TextEditor.FindNextSearchResult(state.handle)
        end
        _sync_story_search_to_editor(state, false)
    elseif previous_clicked then
        imgui.TextEditor.FindPreviousSearchResult(state.handle)
        _sync_story_search_to_editor(state, false)
    elseif next_clicked then
        imgui.TextEditor.FindNextSearchResult(state.handle)
        _sync_story_search_to_editor(state, false)
    end

    local replace_active = false
    if search.mode == "replace" then
        imgui.SetNextItemWidth(query_input_width)
        imgui.InputText(string.format("##story_replace_query_%s", _get_document_uid(document)), search.replace_widget)
        replace_active = imgui.IsItemActive() or imgui.IsItemFocused()
        search.replace_text = search.replace_widget:get() or ""

        local replace_current_clicked = false
        local replace_all_clicked = false
        imgui.SameLine(0, row_spacing)
        imgui.BeginDisabled(not has_results)
            replace_current_clicked = _draw_story_search_icon_button(
                string.format("##story_search_replace_current_%s", _get_document_uid(document)),
                "find-replace-line",
                button_size,
                false,
                "替换当前匹配",
                panel_palette)
            imgui.SameLine(0, row_spacing)
            replace_all_clicked = _draw_story_search_icon_button(
                string.format("##story_search_replace_all_%s", _get_document_uid(document)),
                "menu-search-line",
                button_size,
                false,
                "全部替换",
                panel_palette)
        imgui.EndDisabled()

        local replaced = false
        if replace_current_clicked then
            replaced = imgui.TextEditor.ReplaceCurrentSearchResult(state.handle, search.replace_text or "") == true
        elseif replace_all_clicked then
            replaced = (tonumber(imgui.TextEditor.ReplaceAllSearchResults(state.handle, search.replace_text or "")) or 0) > 0
        end

        if replaced then
            _sync_document_text_from_editor(document, state)
            _reset_story_hover_tooltip_tracking(state)
            _sync_story_search_to_editor(state, false)
        end
    end

    local io = imgui.GetIO()
    if not query_active and not replace_active and io and io.KeyCtrl and not io.KeyShift and not io.KeyAlt then
        if imgui.IsKeyPressed(imgui.ImGuiKey.Z, false) and imgui.TextEditor.CanUndo(state.handle) then
            imgui.TextEditor.Undo(state.handle)
            _sync_document_text_from_editor(document, state)
            _reset_story_hover_tooltip_tracking(state)
            _sync_story_search_to_editor(state, false)
        elseif imgui.IsKeyPressed(imgui.ImGuiKey.Y, false) and imgui.TextEditor.CanRedo(state.handle) then
            imgui.TextEditor.Redo(state.handle)
            _sync_document_text_from_editor(document, state)
            _reset_story_hover_tooltip_tracking(state)
            _sync_story_search_to_editor(state, false)
        end
    end

    imgui.Dummy(imgui.ImVec2(0, footer_gap))
    imgui.PushFont(GlobalContext.font_imgui, footer_font_size)
    imgui.TextDisabled("Esc 收起面板")
    imgui.PopFont()

    if panel_focused then
        local draw_list = imgui.GetWindowDrawList()
        local focus_color = imgui.ImColor(_with_alpha(panel_palette.accent, panel_palette.is_light and 0.72 or 0.58)):to_u32()
        local focus_thickness = math.max(1, math.floor(1 * editor_zoom_ratio + 0.5))
        local panel_max = imgui.ImVec2(panel_position.x + panel_width, panel_position.y + panel_height)
        draw_list:AddRectFilled(
            panel_position,
            imgui.ImVec2(panel_max.x, panel_position.y + focus_thickness),
            focus_color)
        draw_list:AddRectFilled(
            imgui.ImVec2(panel_position.x, panel_max.y - focus_thickness),
            panel_max,
            focus_color)
        draw_list:AddRectFilled(
            panel_position,
            imgui.ImVec2(panel_position.x + focus_thickness, panel_max.y),
            focus_color)
        draw_list:AddRectFilled(
            imgui.ImVec2(panel_max.x - focus_thickness, panel_position.y),
            panel_max,
            focus_color)
    end

    imgui.PopStyleVar(4)
    imgui.PopStyleColor(4)
    imgui.End()
end

_is_mouse_in_rect = function(rect, position)
    return rect and rect.min and rect.max
        and position.x >= rect.min.x and position.x <= rect.max.x
        and position.y >= rect.min.y and position.y <= rect.max.y
end

local function _draw_completion_popup_refined(document, state, editor_rect, editor_zoom_ratio)
    local completion = _get_completion_state(state)
    if not completion.is_open or not editor_rect or not editor_rect.min or not editor_rect.max then
        return
    end
    completion.popup_hovered = false

    if #completion.candidates == 0 then
        _close_completion_popup(state)
        return
    end

    local popup_id = string.format("story_completion_popup_%s", _get_document_uid(document))
    local completion_zoom_ratio = editor_zoom_ratio * STORY_COMPLETION_POPUP_SCALE
    local popup_palette = _build_completion_popup_palette(completion.context and completion.context.kind, completion_zoom_ratio)
    local candidate_count = #completion.candidates
    completion.selected_index = _clamp_int(completion.selected_index, 1, candidate_count)

    if imgui.IsKeyPressed(imgui.ImGuiKey.UpArrow, false) then
        completion.selected_index = completion.selected_index - 1
        if completion.selected_index < 1 then
            completion.selected_index = candidate_count
        end
    elseif imgui.IsKeyPressed(imgui.ImGuiKey.DownArrow, false) then
        completion.selected_index = completion.selected_index + 1
        if completion.selected_index > candidate_count then
            completion.selected_index = 1
        end
    elseif imgui.IsKeyPressed(imgui.ImGuiKey.Escape, false) then
        _close_completion_popup(state)
        return
    elseif imgui.IsKeyPressed(imgui.ImGuiKey.Enter, false) or imgui.IsKeyPressed(imgui.ImGuiKey.Tab, false) then
        if _apply_completion_candidate(document, state, completion, completion.candidates[completion.selected_index]) then
            return
        end
    end

    local label_font_size = math.max(13, math.floor(13 * completion_zoom_ratio + 0.5))
    local row_padding_x = math.max(9, math.floor(10 * completion_zoom_ratio + 0.5))
    local window_padding_x = math.max(4, math.floor(5 * completion_zoom_ratio + 0.5))
    local window_padding_y = math.max(4, math.floor(5 * completion_zoom_ratio + 0.5))
    local row_height = math.max(22, math.floor(24 * completion_zoom_ratio + 0.5))
    local visible_count = math.min(candidate_count, 8)
    local max_start_index = math.max(1, candidate_count - visible_count + 1)
    local start_index = _clamp_int(completion.list_start_index or 1, 1, max_start_index)
    if completion.selected_index < start_index then
        start_index = completion.selected_index
    elseif completion.selected_index > start_index + visible_count - 1 then
        start_index = completion.selected_index - visible_count + 1
    end
    start_index = _clamp_int(start_index, 1, max_start_index)
    completion.list_start_index = start_index
    local end_index = math.min(candidate_count, start_index + visible_count - 1)

    imgui.PushFont(GlobalContext.font_imgui, label_font_size)
    local longest_visible_width = 0
    for index = start_index, end_index do
        local candidate = completion.candidates[index]
        local label_text = tostring(candidate and (candidate.label or candidate.name) or "")
        longest_visible_width = math.max(longest_visible_width, imgui.CalcTextSize(label_text ~= "" and label_text or " ").x)
    end
    imgui.PopFont()

    local margin = math.max(8, math.floor(10 * completion_zoom_ratio + 0.5))
    local min_popup_width = math.max(190, math.floor(210 * completion_zoom_ratio + 0.5))
    local max_popup_width = math.max(
        min_popup_width,
        math.min(editor_rect.max.x - editor_rect.min.x - margin * 2, math.floor(430 * completion_zoom_ratio + 0.5)))
    local popup_width = math.max(
        min_popup_width,
        math.min(max_popup_width, math.ceil(longest_visible_width + row_padding_x * 2 + window_padding_x * 2)))
    local popup_height = window_padding_y * 2 + row_height * visible_count
    local popup_position = _resolve_completion_popup_position(state, editor_rect, popup_width, popup_height, completion_zoom_ratio)
    local popup_flags = imgui.WindowFlags.NoTitleBar
        | imgui.WindowFlags.NoResize
        | imgui.WindowFlags.NoMove
        | imgui.WindowFlags.NoSavedSettings
        | imgui.WindowFlags.NoDocking
        | imgui.WindowFlags.NoFocusOnAppearing
        | imgui.WindowFlags.NoNavFocus
        | imgui.WindowFlags.NoScrollbar
        | imgui.WindowFlags.NoScrollWithMouse

    imgui.SetNextWindowPos(popup_position, imgui.ImGuiCond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(popup_width, popup_height), imgui.ImGuiCond.Always)
    imgui.PushStyleColor(imgui.ImGuiCol.WindowBg, popup_palette.panel_bg)
    imgui.PushStyleColor(imgui.ImGuiCol.Border, popup_palette.panel_outline)
    imgui.PushStyleColor(imgui.ImGuiCol.Header, _make_color(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.ImGuiCol.HeaderHovered, _make_color(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.ImGuiCol.HeaderActive, _make_color(0, 0, 0, 0))
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(window_padding_x, window_padding_y))
    imgui.PushStyleVar(imgui.StyleVar.WindowRounding, math.max(4, math.floor(5 * completion_zoom_ratio + 0.5)))
    imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 1)
    imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0))

    local is_open = imgui.Begin(popup_id, nil, popup_flags)
    if not is_open then
        imgui.PopStyleVar(4)
        imgui.PopStyleColor(5)
        imgui.End()
        return
    end

    completion.popup_hovered = imgui.IsWindowHovered(imgui.HoveredFlags.RootAndChildWindows | imgui.HoveredFlags.AllowWhenBlockedByActiveItem)
    completion.hovered_index = nil

    imgui.PushFont(GlobalContext.font_imgui, label_font_size)
    local draw_list = imgui.GetWindowDrawList()
    local text_color = imgui.ImColor(popup_palette.item_label):to_u32()
    local selected_text_color = imgui.ImColor(popup_palette.item_label_selected):to_u32()
    local separator_color = imgui.ImColor(_with_alpha(popup_palette.item_separator, popup_palette.is_light and 0.18 or 0.12)):to_u32()
    for index = start_index, end_index do
        local candidate = completion.candidates[index]
        local selected = index == completion.selected_index
        local row_id = string.format("##story_completion_minimal_%s_%d", _get_document_uid(document), index)
        local activated = imgui.Selectable(row_id, selected, 0, imgui.ImVec2(0, row_height))
        local hovered = imgui.IsItemHovered()
        local row_min = imgui.GetItemRectMin()
        local row_max = imgui.GetItemRectMax()
        local row_bg = selected and popup_palette.item_selected_bg or hovered and popup_palette.item_hover_bg or nil
        if row_bg then
            draw_list:AddRectFilled(row_min, row_max, imgui.ImColor(row_bg):to_u32(), math.max(2, math.floor(3 * completion_zoom_ratio + 0.5)))
        end

        local label_text = tostring(candidate and (candidate.label or candidate.name) or "")
        local label_max_width = math.max(24, (row_max.x - row_min.x) - row_padding_x * 2)
        local display_label = _ellipsis_text_end(label_text, label_max_width)
        local label_size = imgui.CalcTextSize(display_label ~= "" and display_label or " ")
        draw_list:AddText(
            imgui.ImVec2(row_min.x + row_padding_x, row_min.y + math.max(0, (row_height - label_size.y) * 0.5)),
            selected and selected_text_color or text_color,
            display_label)
        if index < end_index then
            draw_list:AddRectFilled(
                imgui.ImVec2(row_min.x + row_padding_x, row_max.y - 1),
                imgui.ImVec2(row_max.x - row_padding_x, row_max.y),
                separator_color)
        end

        if hovered then
            completion.selected_index = index
            completion.hovered_index = index
        end
        if activated then
            if _apply_completion_candidate(document, state, completion, candidate) then
                imgui.PopFont()
                imgui.PopStyleVar(4)
                imgui.PopStyleColor(5)
                imgui.End()
                return
            end
        end
    end
    imgui.PopFont()

    completion.popup_hovered = completion.popup_hovered
        or imgui.IsWindowHovered(imgui.HoveredFlags.RootAndChildWindows | imgui.HoveredFlags.AllowWhenBlockedByActiveItem)

    imgui.PopStyleVar(4)
    imgui.PopStyleColor(5)
    imgui.End()

    if not completion.popup_hovered and
        ((imgui.IsMouseReleased(0) or imgui.IsMouseReleased(1))
            or (imgui.IsMouseDown(0) or imgui.IsMouseDown(1)))
    then
        _close_completion_popup(state)
    end
end

local function _get_diagnostic_visual(diagnostic)
    if diagnostic and diagnostic.severity == "error" then
        return
        {
            icon_id = "close-circle-fill",
            tint = _copy_color(EditorThemeManager.get_token("accent_danger"), _make_color(197, 61, 67, 255)),
            label = "错误",
        }
    end

    if diagnostic and diagnostic.severity == "warning" then
        return
        {
            icon_id = "alert-fill",
            tint = _copy_color(EditorThemeManager.get_token("accent_warning"), _make_color(248, 181, 0, 255)),
            label = "警告",
        }
    end

    return
    {
        icon_id = "information-2-fill",
        tint = _copy_color(EditorThemeManager.get_token("accent_primary"), _make_color(44, 169, 225, 255)),
        label = "信息",
    }
end

local function _draw_inline_icon_text(icon_id, tint, text, editor_zoom_ratio, disabled, base_line_y, line_block_height)
    local icon = ResourcesManager.find_icon(icon_id)
    local line_origin = imgui.GetCursorPos()
    local text_line_height = imgui.GetTextLineHeight()
    local frame_height = imgui.GetFrameHeight()
    local icon_extent = math.max(14 * editor_zoom_ratio, text_line_height)
    local icon_size = imgui.ImVec2(icon_extent, icon_extent)
    local content_height = math.max(text_line_height, icon_extent)
    local block_height = math.max(content_height, tonumber(line_block_height) or frame_height)
    local block_top_y = base_line_y or line_origin.y
    local line_y = block_top_y + math.max(0, (block_height - content_height) * 0.5)
    local icon_offset_y = math.max(0, (content_height - icon_size.y) * 0.5)
    local spacing = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))

    if icon then
        imgui.SetCursorPos(imgui.ImVec2(line_origin.x, line_y + icon_offset_y))
        imgui.Image(icon, icon_size, nil, nil, tint or EditorThemeManager.get_icon_tint_color(), nil)
        imgui.SameLine(0, spacing)
    end

    local text_cursor = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(text_cursor.x, line_y + math.max(0, (content_height - text_line_height) * 0.5)))
    if disabled == false then
        imgui.Text(text)
    else
        imgui.TextDisabled(text)
    end
end

local function _draw_outline_list(document, editor_zoom_ratio)
    local outline_items = document:get_outline_items() or {}
    if #outline_items == 0 then
        imgui.TextDisabled("当前脚本暂无可导航的大纲项")
        return
    end

    local table_flags = imgui.TableFlags.NoSavedSettings
        | imgui.TableFlags.NoPadOuterX
        | imgui.TableFlags.NoBordersInBody
        | imgui.TableFlags.SizingStretchProp
    local label_padding_left = math.max(8, math.floor(8 * editor_zoom_ratio + 0.5))
    local label_padding_right = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))
    local line_padding_right = math.max(8, math.floor(8 * editor_zoom_ratio + 0.5))
    local line_column_width = math.max(62 * editor_zoom_ratio, 72)
    for _, item in ipairs(outline_items) do
        line_column_width = math.max(
            line_column_width,
            imgui.CalcTextSize(string.format("行:%d", item.line or 1)).x + math.max(8, 10 * editor_zoom_ratio))
    end
    local row_height = math.max(imgui.GetFrameHeight(), math.floor(22 * editor_zoom_ratio + 0.5))

    if not imgui.BeginTable(string.format("story_outline_table_%s", _get_document_uid(document)), 2, table_flags) then
        return
    end
    imgui.TableSetupColumn("大纲标题", imgui.TableColumnFlags.WidthStretch | imgui.TableColumnFlags.NoResize)
    imgui.TableSetupColumn("行号", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, line_column_width)

    for index, item in ipairs(outline_items) do
        imgui.TableNextRow(nil, row_height)

        imgui.TableSetColumnIndex(0)
        local name_region = _get_table_cell_region()
        local raw_name = tostring(item.name or item.kind or "item")
        local label_max_width = math.max(48, name_region.width - label_padding_left - label_padding_right)
        local display_name = _ellipsis_text_end(raw_name, label_max_width)
        imgui.TableSetColumnIndex(1)
        local line_region = _get_table_cell_region()
        local line_label = string.format("行:%d", item.line or 1)

        imgui.TableSetColumnIndex(0)
        local activated = imgui.Selectable(
            string.format("##outline_row_%s_%d", _get_document_uid(document), index),
            false,
            imgui.SelectableFlags.SpanAllColumns,
            imgui.ImVec2(0, row_height))
        local hovered = imgui.IsItemHovered()
        if activated then
            _navigate_to_outline_item(document, item)
        end

        local row_rect =
        {
            min = imgui.GetItemRectMin(),
            max = imgui.GetItemRectMax(),
        }
        local draw_list = imgui.GetWindowDrawList()
        local text_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.Text)):to_u32()
        local line_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.TextDisabled)):to_u32()
        imgui.TableSetColumnIndex(0)
        _draw_centered_text_in_rect(
            draw_list,
            _make_cell_draw_rect(name_region, row_rect),
            display_name,
            text_color,
            false,
            label_padding_left,
            label_padding_right)
        imgui.TableSetColumnIndex(1)
        _draw_centered_text_in_rect(
            draw_list,
            _make_cell_draw_rect(line_region, row_rect),
            line_label,
            line_color,
            true,
            label_padding_left,
            line_padding_right)

        if display_name ~= raw_name and hovered and not _should_suppress_story_tooltip() then
            imgui.BeginTooltip()
                imgui.Text(raw_name)
            imgui.EndTooltip()
        end
    end

    imgui.EndTable()
end

local function _draw_diagnostic_counter(icon_id, tint, label, count, editor_zoom_ratio, base_line_y, line_block_height)
    _draw_inline_icon_text(icon_id, tint, string.format("%s %d", label, count), editor_zoom_ratio, true, base_line_y, line_block_height)
end

local function _draw_panel_title_bar(title, editor_zoom_ratio, draw_extra_content)
    local current_theme = EditorThemeManager.get_current_theme and EditorThemeManager.get_current_theme() or {}
    local is_light = current_theme and current_theme.base_style == "light"
    local header_height = math.max(imgui.GetFrameHeight(), 30 * editor_zoom_ratio)
    local header_padding_x = math.max(10, math.floor(11 * editor_zoom_ratio + 0.5))
    local header_padding_y = math.max(4, math.floor((header_height - imgui.GetTextLineHeight()) * 0.5))
    local separator_gap_left = math.max(18, math.floor(20 * editor_zoom_ratio + 0.5))
    local separator_gap_right = math.max(14, math.floor(14 * editor_zoom_ratio + 0.5))
    local separator_margin_y = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))
    local body_gap = math.max(4, math.floor(4 * editor_zoom_ratio + 0.5))
    local header_min = imgui.GetCursorScreenPos()
    local header_width = imgui.GetContentRegionAvail().x
    local header_max = imgui.ImVec2(header_min.x + header_width, header_min.y + header_height)
    local header_bg = _mix_color(
        EditorThemeManager.get_token("bg_2"),
        EditorThemeManager.get_token("accent_primary"),
        is_light and 0.08 or 0.14)
    local border_color = _copy_color(EditorThemeManager.get_token("border"), _make_color(70, 78, 90, 255))
    local draw_list = imgui.GetWindowDrawList()

    draw_list:AddRectFilled(header_min, header_max, imgui.ImColor(header_bg):to_u32())
    draw_list:AddRectFilled(
        imgui.ImVec2(header_min.x, header_max.y - 1),
        header_max,
        imgui.ImColor(border_color):to_u32())

    local title_position = imgui.ImVec2(header_min.x + header_padding_x, header_min.y + header_padding_y)
    imgui.SetCursorScreenPos(title_position)
    imgui.Text(title)
    if draw_extra_content then
        local title_size = imgui.CalcTextSize(title)
        local separator_x = title_position.x + title_size.x + separator_gap_left
        local separator_color = imgui.ImColor(_with_alpha(border_color, is_light and 0.85 or 0.72)):to_u32()
        draw_list:AddRectFilled(
            imgui.ImVec2(separator_x, header_min.y + separator_margin_y),
            imgui.ImVec2(separator_x + 1, header_max.y - separator_margin_y),
            separator_color)
        imgui.SetCursorScreenPos(imgui.ImVec2(separator_x + separator_gap_right, header_min.y))
        draw_extra_content(editor_zoom_ratio, header_height)
    end

    imgui.SetCursorScreenPos(imgui.ImVec2(header_min.x, header_max.y + body_gap))
end

local function _begin_panel_body(panel_body_id, title, editor_zoom_ratio, draw_extra_content)
    _draw_panel_title_bar(title, editor_zoom_ratio, draw_extra_content)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.BeginChild(panel_body_id, imgui.ImVec2(0, 0), imgui.ChildFlags.None)
    imgui.PopStyleVar()
end

local function _end_panel_body()
    imgui.EndChild()
end

local function _begin_panel_content(content_id, editor_zoom_ratio)
    local content_padding_x = math.max(8, math.floor(9 * editor_zoom_ratio + 0.5))
    local content_padding_y = math.max(4, math.floor(5 * editor_zoom_ratio + 0.5))
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(content_padding_x, content_padding_y))
    imgui.BeginChild(content_id, imgui.ImVec2(0, 0), imgui.ChildFlags.AlwaysUseWindowPadding)
    imgui.PopStyleVar()
end

local function _end_panel_content()
    imgui.EndChild()
end

local function _draw_diagnostic_item(document, diagnostic, index, editor_zoom_ratio)
    local visual = _get_diagnostic_visual(diagnostic)
    local icon = ResourcesManager.find_icon(visual.icon_id)
    local icon_size = imgui.ImVec2(18 * editor_zoom_ratio, 18 * editor_zoom_ratio)
    local location_text = _format_diagnostic_location(document, diagnostic)
    local message_text = diagnostic.message or diagnostic.code or "diagnostic"
    local row_height = math.max(imgui.GetFrameHeight(), math.floor(22 * editor_zoom_ratio + 0.5))
    local location_padding_left = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))
    local location_padding_right = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))
    local message_padding_left = math.max(8, math.floor(8 * editor_zoom_ratio + 0.5))
    local message_padding_right = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))

    local icon_region = _get_table_cell_region()
    imgui.TableSetColumnIndex(1)
    local location_region = _get_table_cell_region()
    local location_max_width = math.max(48, location_region.width - location_padding_left - location_padding_right)
    local location_display = ImGUIHelper.EllipsisTail(location_text, location_max_width)

    imgui.TableSetColumnIndex(2)
    local message_region = _get_table_cell_region()
    local message_width = math.max(48, message_region.width - message_padding_left - message_padding_right)
    local message_display = _ellipsis_text_end(message_text, message_width)

    imgui.TableSetColumnIndex(0)
    local activated = imgui.Selectable(
        string.format("##diag_row_%s_%d", _get_document_uid(document), index),
        false,
        imgui.SelectableFlags.SpanAllColumns,
        imgui.ImVec2(0, row_height))
    local hovered = imgui.IsItemHovered()
    if activated then
        _navigate_to_diagnostic(document, diagnostic)
    end

    local row_rect =
    {
        min = imgui.GetItemRectMin(),
        max = imgui.GetItemRectMax(),
    }
    local draw_list = imgui.GetWindowDrawList()
    local text_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.Text)):to_u32()
    local sub_text_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.TextDisabled)):to_u32()

    if icon then
        imgui.TableSetColumnIndex(0)
        local icon_rect = _make_cell_draw_rect(icon_region, row_rect)
        local icon_x = icon_rect.min.x + math.max(0, (icon_rect.width - icon_size.x) * 0.5)
        local icon_y = icon_rect.min.y + math.max(0, ((icon_rect.max.y - icon_rect.min.y) - icon_size.y) * 0.5)
        draw_list:AddImage(
            icon,
            imgui.ImVec2(icon_x, icon_y),
            imgui.ImVec2(icon_x + icon_size.x, icon_y + icon_size.y),
            nil,
            nil,
            imgui.ImColor(visual.tint):to_u32())
    end
    imgui.TableSetColumnIndex(1)
    _draw_centered_text_in_rect(
        draw_list,
        _make_cell_draw_rect(location_region, row_rect),
        location_display,
        sub_text_color,
        false,
        location_padding_left,
        location_padding_right)
    imgui.TableSetColumnIndex(2)
    _draw_centered_text_in_rect(
        draw_list,
        _make_cell_draw_rect(message_region, row_rect),
        message_display,
        text_color,
        false,
        message_padding_left,
        message_padding_right)

    if hovered and not _should_suppress_story_tooltip() then
        imgui.BeginTooltip()
            imgui.PushTextWrapPos(420 * editor_zoom_ratio)
                imgui.TextColored(visual.tint, message_text)
                imgui.Separator()
                imgui.TextDisabled(location_text)
                if diagnostic.path and diagnostic.path ~= document._path then
                    imgui.TextDisabled(diagnostic.path)
                end
            imgui.PopTextWrapPos()
        imgui.EndTooltip()
    end
end

local function _draw_diagnostics_list(document, editor_zoom_ratio)
    local diagnostics = document:get_diagnostics() or {}
    if #diagnostics == 0 then
        imgui.TextDisabled("当前脚本没有诊断信息")
        return
    end

    local location_column_width = math.max(112 * editor_zoom_ratio, 132)
    local content_width = imgui.GetContentRegionAvail().x
    for _, diagnostic in ipairs(diagnostics) do
        location_column_width = math.max(
            location_column_width,
            imgui.CalcTextSize(_format_diagnostic_location(document, diagnostic)).x + math.max(10, 12 * editor_zoom_ratio))
    end
    location_column_width = math.min(location_column_width, math.max(140 * editor_zoom_ratio, content_width * 0.42))

    local table_flags = imgui.TableFlags.NoSavedSettings
        | imgui.TableFlags.NoPadOuterX
        | imgui.TableFlags.NoBordersInBody
        | imgui.TableFlags.SizingStretchProp
    local icon_column_width = math.max(24 * editor_zoom_ratio, 28)
    local row_height = math.max(imgui.GetFrameHeight(), math.floor(22 * editor_zoom_ratio + 0.5))

    if not imgui.BeginTable(string.format("story_diagnostics_table_%s", _get_document_uid(document)), 3, table_flags) then
        return
    end
    imgui.TableSetupColumn("级别", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, icon_column_width)
    imgui.TableSetupColumn("位置", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, location_column_width)
    imgui.TableSetupColumn("消息", imgui.TableColumnFlags.WidthStretch | imgui.TableColumnFlags.NoResize)

    for index, diagnostic in ipairs(diagnostics) do
        imgui.TableNextRow(nil, row_height)
        imgui.TableSetColumnIndex(0)
        _draw_diagnostic_item(document, diagnostic, index, editor_zoom_ratio)
    end

    imgui.EndTable()
end

local function _draw_cursor_overlay(state, editor_rect, editor_zoom_ratio)
    if not state.handle or not editor_rect or not editor_rect.max then
        return
    end

    if (tonumber(state.story_text_zoom_hint_until) or 0) <= (rl.GetTime() or 0) then
        return
    end

    local label = string.format(
        "缩放 %s",
        state.story_text_zoom_hint_label or _get_story_text_zoom_label(_get_story_text_zoom_ratio()))
    local text_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.TextDisabled)):to_u32()
    local style = imgui.GetStyle()
    local scrollbar_size = (style and style.ScrollbarSize) or math.max(14, imgui.GetFrameHeight())
    local padding = math.max(10, math.floor(10 * editor_zoom_ratio + 0.5))
    local left_inset = padding + math.max(6, math.floor(8 * editor_zoom_ratio + 0.5))
    local scrollbar_gap = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))
    local right_gap = math.max(12, math.floor(16 * editor_zoom_ratio + 0.5))
    local right_inset = padding + scrollbar_size + right_gap
    local bottom_inset = padding + scrollbar_size + scrollbar_gap
    local right_edge_x = editor_rect.max.x - right_inset
    local max_width = math.max(32, right_edge_x - (editor_rect.min.x + left_inset))
    label = _ellipsis_text_end(label, max_width)
    local text_size = imgui.CalcTextSize(label)
    local position = imgui.ImVec2(
        math.max(editor_rect.min.x + left_inset, right_edge_x - text_size.x),
        editor_rect.max.y - text_size.y - bottom_inset)

    local draw_list = imgui.GetWindowDrawList()
    draw_list:AddText(position, text_color, label)
end

local function _draw_editor_region(document, state, editor_zoom_ratio)
    local content_size = imgui.GetContentRegionAvail()
    local story_text_zoom_ratio = _get_story_text_zoom_ratio()
    local font_size = math.max(10, math.floor(18 * editor_zoom_ratio * story_text_zoom_ratio + 0.5))
    local completion = _get_completion_state(state)
    local story_editor_font = _get_story_editor_font()

    _handle_story_text_zoom_shortcuts(state)

    _prepare_completion_before_render(document, state)

    if story_editor_font then
        imgui.PushFont(story_editor_font, font_size)
    end

    local changed = imgui.TextEditor.Render(state.handle, string.format("story_editor_%s", _get_document_uid(document)), content_size)
    local editor_rect =
    {
        min = imgui.GetItemRectMin(),
        max = imgui.GetItemRectMax(),
    }

    if story_editor_font then
        imgui.PopFont()
    end

    state.last_editor_rect = editor_rect
    state.last_editor_hovered = _is_mouse_in_rect(editor_rect, imgui.GetMousePos())

    if changed then
        _sync_document_text_from_editor(document, state)
    end

    local cursor = imgui.TextEditor.GetCursorPosition(state.handle)
    local cursor_signature = string.format("%d:%d", math.floor(cursor.x or 1), math.floor(cursor.y or 1))
    local cursor_changed = state.last_cursor_signature ~= cursor_signature
    state.last_cursor_signature = cursor_signature
    if changed then
        _refresh_completion_popup(document, state, false)
    elseif completion.is_open and cursor_changed then
        _close_completion_popup(state)
    end

    if was_window_focused and not GlobalContext.is_debug_game then
        local io = imgui.GetIO()
        if io and io.KeyCtrl and not io.KeyShift then
            if imgui.IsKeyPressed(imgui.ImGuiKey.F, false) then
                _open_story_search_panel(document, state, "find")
            elseif imgui.IsKeyPressed(imgui.ImGuiKey.R, false) then
                _open_story_search_panel(document, state, "replace")
            end
        end
    end

    _draw_cursor_overlay(state, editor_rect, editor_zoom_ratio)
    _draw_story_search_panel(document, state, editor_rect, editor_zoom_ratio)
    _draw_completion_popup_refined(document, state, editor_rect, editor_zoom_ratio)
    _draw_story_hover_tooltip(document, state, editor_zoom_ratio)

    local refreshed_completion = _get_completion_state(state)
    if refreshed_completion.is_open and not imgui.TextEditor.IsFocused(state.handle) and not refreshed_completion.popup_hovered then
        _close_completion_popup(state)
    end
end

local function _draw_outline_panel(document, editor_zoom_ratio)
    _begin_panel_body(
        string.format("story_outline_body_%s", _get_document_uid(document)),
        "大纲",
        editor_zoom_ratio)
        _begin_panel_content(string.format("story_outline_list_%s", _get_document_uid(document)), editor_zoom_ratio)
            _draw_outline_list(document, editor_zoom_ratio)
        _end_panel_content()
    _end_panel_body()
end

local function _draw_editor_panel(document, state, editor_zoom_ratio)
    _draw_editor_region(document, state, editor_zoom_ratio)
end

local function _draw_diagnostics_panel(document, editor_zoom_ratio)
    local error_count, warning_count = _count_diagnostics(document)
    local error_visual = _get_diagnostic_visual({severity = "error"})
    local warning_visual = _get_diagnostic_visual({severity = "warning"})

    _begin_panel_body(
        string.format("story_diagnostic_body_%s", _get_document_uid(document)),
        "诊断",
        editor_zoom_ratio,
        function(current_zoom_ratio, header_height)
            local counter_row_y = imgui.GetCursorPos().y
            local counter_spacing = math.max(16, math.floor(18 * current_zoom_ratio + 0.5))
            _draw_diagnostic_counter(error_visual.icon_id, error_visual.tint, "错误", error_count, current_zoom_ratio, counter_row_y, header_height)
            imgui.SameLine(0, counter_spacing)
            _draw_diagnostic_counter(warning_visual.icon_id, warning_visual.tint, "警告", warning_count, current_zoom_ratio, counter_row_y, header_height)
        end)
        _begin_panel_content(string.format("story_diagnostic_list_%s", _get_document_uid(document)), editor_zoom_ratio)
            _draw_diagnostics_list(document, editor_zoom_ratio)
        _end_panel_content()
    _end_panel_body()
end

local function _draw_document_tab(document, editor_zoom_ratio)
    local flag = imgui.TabItemFlags.None
    if document:is_modified() then
        flag = flag | imgui.TabItemFlags.UnsavedDocument
    end

    local should_restore_selection = pending_tab_select_guid ~= nil
        and pending_tab_select_guid ~= ""
        and pending_tab_select_guid == document._resource_guid
    if should_restore_selection then
        flag = flag | imgui.TabItemFlags.SetSelected
    end

    local is_open_ref = document._is_open
    if GlobalContext.is_debug_game then
        is_open_ref = nil
    end

    local visible, active = imgui.BeginTabItem(document._tab_label or document._id, is_open_ref, flag)
    if should_restore_selection then
        pending_tab_select_guid = nil
    end
    if not visible then
        return
    end

    if not GlobalContext.is_debug_game and (active or visible) then
        GlobalContext.current_flow_document = document
        FlowManager.set_workspace_current_document(document)
    end

    if document._resource_missing and not document:is_document_loaded() then
        imgui.TextColored(_copy_color(EditorThemeManager.get_token("accent_danger"), _make_color(197, 61, 67, 255)), "该文本剧本文件已从磁盘删除或暂时不可用。")
        imgui.EndTabItem()
        return
    end

    if not document:ensure_document_loaded() then
        imgui.TextColored(_copy_color(EditorThemeManager.get_token("accent_danger"), _make_color(197, 61, 67, 255)), "无法加载当前文本剧本文档，请检查控制台日志。")
        imgui.EndTabItem()
        return
    end

    if document._resource_missing then
        imgui.TextColored(_copy_color(EditorThemeManager.get_token("accent_danger"), _make_color(197, 61, 67, 255)), "该文本剧本文件已从磁盘删除或暂时不可用，当前显示的是内存中的旧内容。")
        imgui.Separator()
    elseif document._external_change_pending then
        imgui.TextColored(_copy_color(EditorThemeManager.get_token("accent_warning"), _make_color(248, 181, 0, 255)), "磁盘中的文本剧本文件已发生外部修改。")
        imgui.SameLine()
        if imgui.SmallButton(string.format("从磁盘重载##story_reload_%s", _get_document_uid(document))) then
            document:reload_from_disk()
        end
        imgui.SameLine()
        if imgui.SmallButton(string.format("忽略提醒##story_ignore_%s", _get_document_uid(document))) then
            document._external_change_pending = false
        end
        imgui.Separator()
    end

    local state = _ensure_editor_state(document)
    _apply_pending_navigation(document, state)
    if GlobalContext.is_debug_game then
        _close_completion_popup(state)
    end

    local document_uid = _get_document_uid(document)
    local table_flags = imgui.TableFlags.Resizable
        | imgui.TableFlags.SizingStretchProp
        | imgui.TableFlags.BordersInnerV
    if imgui.BeginTable(string.format("story_columns_%s", document_uid), 2, table_flags, imgui.ImVec2(0, 0)) then
        imgui.TableSetupColumn("大纲", imgui.TableColumnFlags.WidthStretch, 0.24)
        imgui.TableSetupColumn("编辑区", imgui.TableColumnFlags.WidthStretch, 0.76)
        imgui.TableNextRow()

        imgui.TableSetColumnIndex(0)
        imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.BeginChild(string.format("story_outline_panel_%s", document_uid), imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
        imgui.PopStyleVar()
            _draw_outline_panel(document, editor_zoom_ratio)
        imgui.EndChild()

        imgui.TableSetColumnIndex(1)
        imgui.BeginChild(string.format("story_main_panel_%s", document_uid), imgui.ImVec2(0, 0), imgui.ChildFlags.None)
            local editor_panel_height = math.max(240 * editor_zoom_ratio, imgui.GetContentRegionAvail().y * 0.68)
            local editor_panel_flags = imgui.ChildFlags.Borders | imgui.ChildFlags.ResizeY | imgui.ChildFlags.AlwaysUseWindowPadding
            imgui.BeginChild(string.format("story_editor_panel_%s", document_uid), imgui.ImVec2(0, editor_panel_height), editor_panel_flags)
                _draw_editor_panel(document, state, editor_zoom_ratio)
            imgui.EndChild()

            local diagnostics_panel_flags = imgui.ChildFlags.Borders
            imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
            imgui.BeginChild(string.format("story_diagnostics_panel_%s", document_uid), imgui.ImVec2(0, 0), diagnostics_panel_flags)
            imgui.PopStyleVar()
                _draw_diagnostics_panel(document, editor_zoom_ratio)
            imgui.EndChild()
        imgui.EndChild()

        imgui.EndTable()
    end

    imgui.EndTabItem()
end

function module.on_enter()
    pending_tab_select_guid = FlowManager.get_workspace_current_text_guid and FlowManager.get_workspace_current_text_guid() or nil
    pending_window_focus_frames = 0
end

function module.on_exit()
    was_window_focused = false
    pending_tab_select_guid = nil
    pending_window_focus_frames = 0
    for _, document in ipairs(FlowManager.get_workspace_open_text_documents()) do
        _destroy_editor_handle(document)
    end
end

function module.open_story_document(value, options)
    local document = type(value) == "table" and value or FlowManager.get_document(value, "flow_document_open")
    if not document or document.kind ~= "text" then
        return nil
    end
    local open_options = options or {select = true}
    local opened_document = FlowManager.open_document_in_workspace(document, open_options)
    if opened_document and open_options.select ~= false then
        pending_tab_select_guid = document._resource_guid or nil
        pending_window_focus_frames = math.max(pending_window_focus_frames, 2)
    end
    return opened_document
end

function module.get_current_document()
    local document = FlowManager.get_workspace_current_document and FlowManager.get_workspace_current_document("text") or nil
    if document and document._is_open and document._is_open.val then
        return document
    end
    return nil
end

function module.is_window_focused()
    return was_window_focused == true
end

local function _has_active_input_widget()
    return (imgui.IsAnyItemActive and imgui.IsAnyItemActive())
        or (imgui.IsAnyItemFocused and imgui.IsAnyItemFocused())
end

function module.save_current_document()
    local document = module.get_current_document()
    if not document then
        return false
    end
    local state = document:get_ui_state("story_editor")
    if state and state.completion then
        _close_completion_popup(state)
    end
    return document:save_document()
end

function module.undo_current_document()
    local document = module.get_current_document()
    if not document or not document:ensure_document_loaded() then
        return false
    end

    local state = _ensure_editor_state(document)
    _close_completion_popup(state)
    if imgui.TextEditor.CanUndo(state.handle) then
        imgui.TextEditor.Undo(state.handle)
        _sync_document_text_from_editor(document, state)
        return true
    end
    return false
end

function module.redo_current_document()
    local document = module.get_current_document()
    if not document or not document:ensure_document_loaded() then
        return false
    end

    local state = _ensure_editor_state(document)
    _close_completion_popup(state)
    if imgui.TextEditor.CanRedo(state.handle) then
        imgui.TextEditor.Redo(state.handle)
        _sync_document_text_from_editor(document, state)
        return true
    end
    return false
end

function module.on_update(self, delta)
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    if pending_window_focus_frames > 0 and not GlobalContext.is_resource_modal_active then
        imgui.SetNextWindowFocus()
        pending_window_focus_frames = pending_window_focus_frames - 1
    end
    local is_open = imgui.Begin("剧本设计视图")
    was_window_focused = is_open and imgui.IsWindowFocused(imgui.FocusedFlags.RootAndChildWindows) or false

    if is_open then
        local window_pos_begin = imgui.GetCursorScreenPos()
        local window_size_content = imgui.GetContentRegionAvail()
        do
            local tab_border_style = nil
            if ImGUIHelper.ShouldUseInHThemeCompensation() then
                tab_border_style = ImGUIHelper.PushSoftTabBorderStyle(editor_zoom_ratio)
            end
            if imgui.BeginTabBar("TabBar_StoryDocuments", imgui.TabBarFlags.Reorderable | imgui.TabBarFlags.AutoSelectNewTabs) then
                for _, document in ipairs(FlowManager.get_workspace_open_text_documents()) do
                    if document.update_compile_state then
                        document:update_compile_state()
                    end
                    _draw_document_tab(document, editor_zoom_ratio)
                end
                imgui.EndTabBar()
            else
                imgui.TextDisabled("当前没有打开的文本剧本文档")
            end
            if tab_border_style then
                ImGUIHelper.PopSoftTabBorderStyle(tab_border_style)
            end

            local current_document = module.get_current_document()
            local can_handle_shortcuts = was_window_focused
                and current_document ~= nil
                and not GlobalContext.is_debug_game
                and not _has_active_input_widget()
            local io = imgui.GetIO()
            if can_handle_shortcuts and io.KeyCtrl and not io.KeyShift and imgui.IsKeyPressed(imgui.ImGuiKey.S, false) then
                module.save_current_document()
            end
        end
    end

    imgui.End()
    FlowManager.sync_workspace_state()
end

return module

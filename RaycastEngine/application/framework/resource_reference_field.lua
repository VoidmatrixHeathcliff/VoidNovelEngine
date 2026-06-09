local imgui = Engine.ImGUI

local EditorThemeManager = require("application.framework.editor_theme_manager")
local ImGUIHelper = require("application.framework.imgui_helper")
local ResourceBrowser = require("application.framework.resource_browser")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local SettingsManager = require("application.framework.settings_manager")

local module = {}

local state_pool = {}
local queued_overlay_tooltip_text = nil
local overlay_tooltip_active_last_frame = false
local overlay_tooltip_close_grace_frames <const> = 2
local overlay_tooltip_keepalive_frames = 0
local popup_size <const> = imgui.ImVec2(720, 380)

local function _get_state(popup_id)
    local state = state_pool[popup_id]
    if state then
        return state
    end

    state = ResourceBrowser.create_state()
    state.is_popup_open = false
    state.overlay_active = false
    state.overlay_popup_requested = false
    state.overlay_hovered = false
    state.overlay_asset_type = nil
    state.overlay_value = nil
    state.overlay_display_text = ""
    state.overlay_tooltip_text = ""
    state.pending_commit = nil
    state.sync_selection_to_value = false
    state.button_text_cache = {}
    state.scope_text_cache = {}
    state.active_width = nil
    state.asset_list_clipper = imgui.ListClipper()
    state_pool[popup_id] = state
    return state
end

local function _get_cached_ellipsis_text(cache, text, width, mode)
    text = type(text) == "string" and text or ""
    width = math.max(0, math.floor((width or 0) + 0.5))
    mode = mode == "head" and "head" or "tail"
    local line_height = imgui.GetTextLineHeight()
    if cache.source_text ~= text or cache.width ~= width or cache.line_height ~= line_height or cache.mode ~= mode then
        cache.source_text = text
        cache.width = width
        cache.line_height = line_height
        cache.mode = mode
        if mode == "head" then
            cache.result = ImGUIHelper.EllipsisHead(text, width)
        else
            cache.result = ImGUIHelper.EllipsisTail(text, width)
        end
    end
    return cache.result or text
end

local function _get_button_display_text(asset_type, value, empty_text)
    if value == nil or value == "" then
        return empty_text or "选择资源..."
    end

    local display_text = ResourceIndex.get_display_path(asset_type, value)
    if display_text ~= "" then
        return display_text
    end

    if type(value) == "table" then
        return value.path_hint or value.guid or "选择资源..."
    end

    return tostring(value)
end

local function _get_popup_browser_options(asset_type)
    local options = ResourceBrowser.get_default_folder_draw_options()
    options.allowed_types = {[asset_type] = true}
    options.root_label = "resources"
    return options
end

local function _get_popup_tree_options(asset_type)
    local options = ResourceBrowser.get_default_folder_draw_options()
    options.allowed_types = {[asset_type] = true}
    options.root_label = "resources"
    options.hide_dirs_without_allowed_assets = true
    return options
end

local function _get_style_vec_x(style, field_name, fallback)
    local value = style and style[field_name] or nil
    if value and type(value.x) == "number" then
        return value.x
    end
    return fallback or 0
end

local function _get_clear_button_width(style)
    local icon_size = imgui.GetTextLineHeight()
    return icon_size + _get_style_vec_x(style, "FramePadding", 0) * 2
end

local function _get_clear_button_reserve(style)
    return _get_clear_button_width(style) + _get_style_vec_x(style, "ItemSpacing", 0)
end

local function _get_button_text_width(button_width, style)
    if not button_width or button_width <= 0 then
        return 0
    end
    local frame_padding_x = _get_style_vec_x(style, "FramePadding", 4)
    return math.max(0, button_width - math.max(20, frame_padding_x * 2 + 4))
end

local function _resolve_stable_width(state, width)
    if not width or width <= 0 then
        state.active_width = nil
        return width
    end

    local rounded_width = math.max(1, math.floor(width + 0.5))
    if state.is_popup_open and type(state.active_width) == "number" then
        state.active_width = math.max(state.active_width, rounded_width)
        return state.active_width
    end

    state.active_width = rounded_width
    return rounded_width
end

local function _sync_state_with_value(state, asset_type, value)
    if not state.sync_selection_to_value or ResourceBrowser.is_filtering(state) then
        return
    end

    local guid = ResourceIndex.resolve_guid(asset_type, value)
    if not guid then
        state.sync_selection_to_value = false
        return
    end

    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        state.sync_selection_to_value = false
        return
    end

    local target_dir = meta.relative_dir or ""
    if ResourceBrowser.find_tree_node(target_dir) then
        state.selected_dir = target_dir
    end
    state.sync_selection_to_value = false
end

local function _draw_popup_asset_item(meta, popup_id, index, is_selected, editor_zoom_ratio)
    local pos = imgui.GetCursorPos()
    local activated = imgui.Selectable(
        string.format("##pick_%s_%d", popup_id, index),
        is_selected,
        imgui.SelectableFlags.SpanAllColumns)

    ResourceBrowser.handle_asset_hover_preview(meta,
    {
        editor_zoom_ratio = editor_zoom_ratio,
        show_editor_open_hint = false,
    })

    imgui.SetCursorPos(pos)
    ResourceBrowser.draw_asset_label(
    meta,
    {
        display_name = meta.file_name or meta.relative_path or meta.display_name,
        max_text_width = math.max(80, imgui.GetContentRegionAvail().x - imgui.GetTextLineHeight() * 2),
    })
    return activated
end

local function _draw_popup_content(popup_id, state, asset_type, value)
    local picked_value = nil
    local did_pick = false
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    local browser_options = _get_popup_browser_options(asset_type)
    local tree_options = _get_popup_tree_options(asset_type)
    local popup_tree_style = nil

    _sync_state_with_value(state, asset_type, value)

    imgui.Text(string.format("搜索%s资源：", ResourceBrowser.get_type_label(asset_type)))
    imgui.SameLine()
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    imgui.InputText(string.format("##filter_%s", popup_id), state.filter)

    imgui.Columns(2, string.format("picker_columns_%s", popup_id), true)
    if not state.is_layout_initialized or state.layout_zoom_ratio ~= editor_zoom_ratio then
        imgui.SetColumnWidth(0, 240 * editor_zoom_ratio)
        state.is_layout_initialized = true
        state.layout_zoom_ratio = editor_zoom_ratio
    end

    if ImGUIHelper.ShouldUseInHThemeCompensation() then
        popup_tree_style = ImGUIHelper.PushCompactTreeStyle(editor_zoom_ratio,
        {
            include_window_padding = true,
            item_spacing_x = 4,
            indent_spacing = 21,
        })
    end

    tree_options.indent_spacing = math.max(21, math.floor(21 * editor_zoom_ratio + 0.5))
    imgui.BeginChild(string.format("popup_dir_%s", popup_id), imgui.ImVec2(0, 280), imgui.ChildFlags.Borders)
        ResourceBrowser.draw_directory_tree(state, tree_options)
    imgui.EndChild()

    if popup_tree_style then
        ImGUIHelper.PopCompactTreeStyle(popup_tree_style)
    end

    imgui.NextColumn()

    imgui.BeginChild(string.format("popup_assets_%s", popup_id), imgui.ImVec2(0, 280), imgui.ChildFlags.Borders)
        local asset_list = ResourceBrowser.collect_visible_assets(state, browser_options)
        local selected_guid = ResourceIndex.resolve_guid(asset_type, value)
        local scope_text = ResourceBrowser.get_scope_text(state, "resources")
        local scope_width = imgui.GetContentRegionAvail().x

        imgui.TextDisabled(_get_cached_ellipsis_text(state.scope_text_cache, scope_text, math.max(80, scope_width)))
        ImGUIHelper.HoveredTooltip(scope_text)
        imgui.Separator()

        state.asset_list_clipper:Begin(#asset_list)
        while state.asset_list_clipper:Step() do
            local display_start = state.asset_list_clipper:GetDisplayStart() + 1
            local display_end = state.asset_list_clipper:GetDisplayEnd()
            for index = display_start, display_end do
                local meta = asset_list[index]
                if meta then
                    local is_selected = selected_guid == meta.guid
                    if _draw_popup_asset_item(meta, popup_id, index, is_selected, editor_zoom_ratio) then
                        picked_value =
                        {
                            guid = meta.guid,
                            path_hint = meta.relative_path,
                        }
                        did_pick = true
                        break
                    end
                end
            end
            if did_pick then
                break
            end
        end
        state.asset_list_clipper:End()

        if not did_pick and #asset_list == 0 then
            imgui.TextDisabled("当前筛选条件下没有匹配资源")
        end
    imgui.EndChild()

    imgui.Columns(1)
    return picked_value, did_pick
end

module.draw = function(config)
    local popup_id = assert(config.popup_id, "resource reference field missing popup_id")
    local asset_type = assert(config.asset_type, "resource reference field missing asset_type")
    local width = config.width
    local suffix_label = config.suffix_label
    local empty_text = type(config.empty_text) == "string" and config.empty_text or nil
    local allow_clear = config.allow_clear ~= false
    local disabled = config.disabled == true
    local value = config.value
    local use_node_editor_overlay = config.use_node_editor_overlay == true
    local alert_text = config.alert_text
    local state = _get_state(popup_id)
    width = _resolve_stable_width(state, width)

    local changed = false
    local new_value = nil
    local invalid_payload = nil

    if use_node_editor_overlay and state.pending_commit then
        changed = true
        new_value = state.pending_commit
        state.pending_commit = nil
    end

    local display_text = _get_button_display_text(asset_type, value, empty_text)
    local button_text = display_text
    local popup_requested = false
    local hovered = false
    local clear_hovered = false
    local label_hovered = false

    local button_width = width
    local style = imgui.GetStyle()
    if width and width > 0 then
        local clear_reserve = allow_clear and not disabled and _get_clear_button_reserve(style) or 0
        local label_reserve = 0
        if suffix_label and suffix_label ~= "" then
            local label_size = imgui.CalcTextSize(suffix_label)
            label_reserve = label_size.x + _get_style_vec_x(style, "ItemSpacing", 0)
        end
        button_width = math.max(72, width - label_reserve - clear_reserve)
    end

    if button_width and button_width > 0 then
        button_text = _get_cached_ellipsis_text(state.button_text_cache, display_text,
            math.max(32, _get_button_text_width(button_width, style)), "head")
    end

    imgui.BeginDisabled(disabled)
        local input_frame_palette = EditorThemeManager.get_input_frame_palette()
        imgui.PushStyleColor(imgui.ImGuiCol.Button, input_frame_palette.frame)
        imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, input_frame_palette.hovered)
        imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, input_frame_palette.active)
        if imgui.Button(string.format("%s##btn_%s", button_text, popup_id), button_width and imgui.ImVec2(button_width, 0) or nil) then
            if use_node_editor_overlay then
                popup_requested = true
            else
                state.sync_selection_to_value = true
                imgui.OpenPopup(popup_id)
            end
        end
        imgui.PopStyleColor(3)

        hovered = imgui.IsItemHovered()

        if imgui.BeginDragDropTarget() then
            local payload = imgui.AcceptDragDropPayload("asset")
            if payload then
                if payload.type == asset_type then
                    changed = true
                    new_value =
                    {
                        guid = payload.guid,
                        path_hint = payload.relative_path or payload.path_hint,
                    }
                else
                    invalid_payload = payload
                end
            end
            imgui.EndDragDropTarget()
        end

        if suffix_label and suffix_label ~= "" then
            imgui.SameLine()
            imgui.TextDisabled(suffix_label)
            label_hovered = imgui.IsItemHovered()
        end
    imgui.EndDisabled()

    if allow_clear and not disabled then
        imgui.SameLine()
        imgui.BeginDisabled(value == nil)
            local icon_size = imgui.GetTextLineHeight()
            if imgui.ImageButton(
                string.format("clear_%s", popup_id),
                ResourcesManager.find_icon("delete-bin-5-line"),
                imgui.ImVec2(icon_size, icon_size),
                nil,
                nil,
                nil,
                EditorThemeManager.get_icon_tint_color()) then
                changed = true
                new_value = nil
            end
            clear_hovered = imgui.IsItemHovered()
            if not use_node_editor_overlay then
                ImGUIHelper.HoveredTooltip("清空资源引用")
            end
        imgui.EndDisabled()
    end

    if use_node_editor_overlay then
        state.overlay_active = true
        state.overlay_popup_requested = state.overlay_popup_requested or popup_requested
        state.overlay_hovered = hovered or clear_hovered or label_hovered
        state.overlay_asset_type = asset_type
        state.overlay_value = value
        state.overlay_display_text = display_text
        if clear_hovered then
            state.overlay_tooltip_text = "清空资源引用"
        else
            state.overlay_tooltip_text = alert_text or display_text
        end
    else
        if (hovered or label_hovered) and not state.is_popup_open then
            if imgui.BeginTooltip() then
                imgui.Text(alert_text or display_text)
                imgui.EndTooltip()
            end
        end

        state.is_popup_open = false
        imgui.SetNextWindowSize(popup_size, imgui.ImGuiCond.Always)
        if imgui.BeginPopup(popup_id) then
            state.is_popup_open = true
            local selected_value, picked = _draw_popup_content(popup_id, state, asset_type, value)
            if picked then
                changed = true
                new_value = selected_value
                imgui.CloseCurrentPopup()
            end
            imgui.EndPopup()
        end
    end

    if not use_node_editor_overlay then
        ResourceBrowser.finish_hover_preview_frame()
    end
    return new_value, changed, invalid_payload
end

module.queue_overlay_tooltip = function(text)
    if type(text) ~= "string" or text == "" then
        return
    end
    queued_overlay_tooltip_text = text
end

module.flush_overlay = function()
    local tooltip_text = queued_overlay_tooltip_text
    local popup_open = false
    local tooltip_active = false

    for popup_id, state in pairs(state_pool) do
        if state.overlay_active then
            if state.overlay_popup_requested then
                state.sync_selection_to_value = true
                imgui.OpenPopup(popup_id)
            end

            if state.overlay_hovered and not state.overlay_popup_requested and not state.is_popup_open and not tooltip_text then
                tooltip_text = state.overlay_tooltip_text
            end

            state.is_popup_open = false
            imgui.SetNextWindowSize(popup_size, imgui.ImGuiCond.Always)
            if imgui.BeginPopup(popup_id) then
                state.is_popup_open = true
                popup_open = true
                local selected_value, picked = _draw_popup_content(
                    popup_id,
                    state,
                    state.overlay_asset_type,
                    state.overlay_value)
                if picked then
                    state.pending_commit = selected_value
                    imgui.CloseCurrentPopup()
                end
                imgui.EndPopup()
            end
        else
            state.is_popup_open = false
        end

        state.overlay_active = false
        state.overlay_popup_requested = false
        state.overlay_hovered = false
        state.overlay_asset_type = nil
        state.overlay_value = nil
        state.overlay_display_text = ""
        state.overlay_tooltip_text = ""
    end

    if tooltip_text and not popup_open then
        tooltip_active = true
        if imgui.BeginTooltip() then
            imgui.TextDisabled(tooltip_text)
            imgui.EndTooltip()
        end
    end

    if tooltip_active then
        overlay_tooltip_keepalive_frames = overlay_tooltip_close_grace_frames
    elseif overlay_tooltip_keepalive_frames > 0 then
        overlay_tooltip_keepalive_frames = overlay_tooltip_keepalive_frames - 1
    end

    overlay_tooltip_active_last_frame = tooltip_active or overlay_tooltip_keepalive_frames > 0
    queued_overlay_tooltip_text = nil
    ResourceBrowser.finish_hover_preview_frame()
end

module.has_open_popup = function()
    if overlay_tooltip_active_last_frame then
        return true
    end

    for _, state in pairs(state_pool) do
        if state.is_popup_open or state.overlay_popup_requested then
            return true
        end
    end
    return false
end

return module

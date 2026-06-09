local util = Engine.Util
local imgui = Engine.ImGUI

local EditorThemeManager = require("application.framework.editor_theme_manager")
local GlobalContext = require("application.framework.global_context")
local ImGUIHelper = require("application.framework.imgui_helper")
local LogManager = require("application.framework.log_manager")
local ModifyManager = require("application.framework.modify_manager")
local PinRegistry = require("application.framework.pin_registry")
local ResourceIndex = require("application.framework.resource_index")
local ResourceReferenceField = require("application.framework.resource_reference_field")
local ResourcesManager = require("application.framework.resources_manager")
local SettingsManager = require("application.framework.settings_manager")
local Style = require("application.framework.style")
local StyleSchemaRegistry = require("application.framework.style_schema_registry")
local StyleWorkspaceManager = require("application.framework.style_workspace_manager")
local UndoManager = require("application.framework.undo_manager")

local module = {}

local selected_domain_by_guid = {}
local selected_field_by_guid = {}
local inline_create_domain_by_guid = {}
local inline_create_domain_focus_by_guid = {}
local inline_create_domain_active_by_guid = {}
local inline_create_domain_was_active_by_guid = {}
local inline_create_domain_error_by_guid = {}
local pending_create_field_popup = false
local create_field_key = nil
local create_field_display_name = nil
local create_field_type_index = 1
local create_field_type_list = nil

local _draw_create_field_popup
local was_window_focused = false
local pending_tab_select_guid = nil
local pending_window_focus_frames = 0
local focus_reclaim_armed = false
local pending_open_error_text = nil

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

local function _get_document_uid(document)
    return document._resource_guid or document._id
end

local function _get_type_list()
    if not create_field_type_list then
        create_field_type_list = StyleSchemaRegistry.list_styleable_pin_types()
    end
    return create_field_type_list
end

local function _get_type_display_name(type_id)
    local definition = PinRegistry.get(type_id)
    return definition and (definition.display_name or definition.name) or type_id
end

local function _draw_warning_banner(text, color)
    if not text or text == "" then
        return
    end
    imgui.PushStyleColor(imgui.ImGuiCol.ChildBg, EditorThemeManager.with_alpha(color, 0.16))
    imgui.BeginChild(string.format("style_warning_%s", text), imgui.ImVec2(0, 42), true)
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

local function _get_style_vec_x(style, field_name, fallback)
    local value = style and style[field_name] or nil
    if value and type(value.x) == "number" then
        return value.x
    end
    return fallback or 0
end

local function _get_style_vec_y(style, field_name, fallback)
    local value = style and style[field_name] or nil
    if value and type(value.y) == "number" then
        return value.y
    end
    return fallback or 0
end

local function _get_toolbar_icon_tint_color()
    return EditorThemeManager.get_icon_tint_color()
end

local function _get_icon_button_size()
    local size = math.max(16, imgui.GetTextLineHeight())
    return imgui.ImVec2(size, size)
end

local function _get_icon_button_width()
    local size = _get_icon_button_size()
    return size.x + _get_style_vec_x(imgui.GetStyle(), "FramePadding", 4) * 2
end

local function _get_icon_button_column_width(fallback)
    local style = imgui.GetStyle()
    return math.max(fallback or 40,
        math.ceil(_get_icon_button_width()
            + _get_style_vec_x(style, "CellPadding", 4) * 2
            + 4))
end

local function _draw_icon_button(button_id, icon_id, tooltip, disabled, tint_color)
    local clicked = false
    local tint = tint_color or _get_toolbar_icon_tint_color()
    imgui.BeginDisabled(disabled == true)
        clicked = imgui.ImageButton(
            button_id,
            ResourcesManager.find_icon(icon_id),
            _get_icon_button_size(),
            nil,
            nil,
            nil,
            tint)
        ImGUIHelper.HoveredTooltip(tooltip)
    imgui.EndDisabled()
    return clicked
end

local function _to_u32(color)
    return imgui.ImColor(color):to_u32()
end

local function _get_field_table_palette()
    return
    {
        selected_border = _get_toolbar_icon_tint_color(),
    }
end

local function _push_field_table_clip(draw_list, clip_min, clip_max)
    if not clip_min or not clip_max then
        return nil
    end

    if draw_list and draw_list.PushClipRect and draw_list.PopClipRect then
        draw_list:PushClipRect(clip_min, clip_max, false)
        return "draw_list"
    end
    if imgui.PushClipRect and imgui.PopClipRect then
        imgui.PushClipRect(clip_min, clip_max, false)
        return "imgui"
    end
    return nil
end

local function _pop_field_table_clip(draw_list, token)
    if token == "draw_list" then
        draw_list:PopClipRect()
    elseif token == "imgui" then
        imgui.PopClipRect()
    end
end

local function _draw_field_table_row_selection(draw_list, row_min, row_max, palette, clip_min, clip_max)
    if not draw_list or not row_min or not row_max or not palette then
        return
    end

    local clip_token = _push_field_table_clip(draw_list, clip_min, clip_max)
    draw_list:AddRect(row_min, row_max, _to_u32(palette.selected_border), 0, nil, 2)
    _pop_field_table_clip(draw_list, clip_token)
end

local function _make_field_table_row_rect(row_min, row_max, table_min_x, table_max_x, row_height)
    if not row_min or not row_max then
        return row_min, row_max
    end

    local cell_padding_y = _get_style_vec_y(imgui.GetStyle(), "CellPadding", 4)
    local row_top = row_min.y - cell_padding_y
    local row_bottom = row_height and (row_top + row_height) or row_max.y
    return imgui.ImVec2(table_min_x or row_min.x, row_top),
        imgui.ImVec2(table_max_x or row_max.x, row_bottom)
end

local function _align_field_table_cell(row_min, row_height, item_height)
    if not row_min or not row_height or not item_height or not imgui.GetCursorScreenPos or not imgui.SetCursorScreenPos then
        return
    end

    local cursor = imgui.GetCursorScreenPos()
    local next_y = row_min.y + math.max(0, (row_height - item_height) * 0.5)
    imgui.SetCursorScreenPos(imgui.ImVec2(cursor.x, next_y))
end

local function _center_field_table_action(row_min, row_height)
    _align_field_table_cell(row_min, row_height, imgui.GetFrameHeight())
    if not imgui.GetCursorScreenPos or not imgui.SetCursorScreenPos then
        return
    end

    local available_width = imgui.GetContentRegionAvail().x
    local button_width = _get_icon_button_width()
    local cursor = imgui.GetCursorScreenPos()
    imgui.SetCursorScreenPos(imgui.ImVec2(
        cursor.x + math.max(0, (available_width - button_width) * 0.5),
        cursor.y))
end

local function _is_point_in_rect(point, rect_min, rect_max)
    if not point or not rect_min or not rect_max then
        return false
    end

    local x = tonumber(point.x)
    local y = tonumber(point.y)
    local min_x = tonumber(rect_min.x)
    local min_y = tonumber(rect_min.y)
    local max_x = tonumber(rect_max.x)
    local max_y = tonumber(rect_max.y)
    if not x or not y or not min_x or not min_y or not max_x or not max_y then
        return false
    end

    return x >= min_x and x <= max_x and y >= min_y and y <= max_y
end

local function _select_field(document, domain_key, field_key)
    if not document or not domain_key or not field_key then
        return
    end
    selected_field_by_guid[_get_document_uid(document)] =
    {
        domain_key = domain_key,
        field_key = field_key,
    }
end

local function _get_selected_field_key(document, domain_key, field_list)
    local selected = selected_field_by_guid[_get_document_uid(document)]
    if not selected or selected.domain_key ~= domain_key then
        return nil
    end

    for _, field_meta in ipairs(field_list or {}) do
        if field_meta.key == selected.field_key then
            return selected.field_key, field_meta
        end
    end

    selected_field_by_guid[_get_document_uid(document)] = nil
    return nil
end

local function _extend_rect_with_last_item(row_min, row_max)
    if not imgui.GetItemRectMin or not imgui.GetItemRectMax then
        return row_min, row_max
    end

    local item_min = imgui.GetItemRectMin()
    local item_max = imgui.GetItemRectMax()
    if not item_min or not item_max then
        return row_min, row_max
    end

    if not row_min or not row_max then
        return imgui.ImVec2(item_min.x, item_min.y), imgui.ImVec2(item_max.x, item_max.y)
    end

    row_min.x = math.min(row_min.x, item_min.x)
    row_min.y = math.min(row_min.y, item_min.y)
    row_max.x = math.max(row_max.x, item_max.x)
    row_max.y = math.max(row_max.y, item_max.y)
    return row_min, row_max
end

local function _is_row_left_clicked(row_min, row_max)
    if not row_min or not row_max or not imgui.GetMousePos or not imgui.IsMouseClicked then
        return false
    end
    return imgui.IsMouseClicked(0, false) == true
        and _is_point_in_rect(imgui.GetMousePos(), row_min, row_max)
end

local function _draw_text_editor(document, state_key, current_value, label, width, on_commit)
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
    imgui.InputText(label, state.widget)
    local deactivated = imgui.IsItemDeactivatedAfterEdit()
    local committed = false
    state.active = imgui.IsItemActive()
    if deactivated then
        local next_value = _trim(state.widget:get()) or ""
        if next_value ~= (state.committed_value or "") then
            state.committed_value = next_value
            on_commit(next_value)
            committed = true
        end
    end
    return state.active == true, committed
end

local function _get_domain_list(document, compiled_sheet)
    local ordered = {}

    for domain_key, local_domain in pairs(document._document.domains or {}) do
        local compiled_domain = compiled_sheet.domains and compiled_sheet.domains[domain_key] or nil
        local schema_domain = StyleSchemaRegistry.get_domain(domain_key)
        table.insert(ordered,
        {
            key = domain_key,
            display_name = (compiled_domain and compiled_domain.display_name)
                or (local_domain and local_domain.display_name)
                or (schema_domain and schema_domain.display_name)
                or domain_key,
            order = schema_domain and schema_domain.order or 1000,
            local_domain = local_domain,
            can_delete = local_domain and local_domain.custom == true and schema_domain == nil,
        })
    end

    table.sort(ordered, function(left, right)
        if left.order ~= right.order then
            return left.order < right.order
        end
        return left.key < right.key
    end)

    return ordered
end

local function _get_selected_domain(document, compiled_sheet)
    local domain_list = _get_domain_list(document, compiled_sheet)
    local document_uid = _get_document_uid(document)
    local selected_domain = selected_domain_by_guid[document_uid]

    for _, domain in ipairs(domain_list) do
        if domain.key == selected_domain then
            return selected_domain, domain_list
        end
    end

    selected_domain = domain_list[1] and domain_list[1].key or nil
    selected_domain_by_guid[document_uid] = selected_domain
    return selected_domain, domain_list
end

local function _get_domain_meta(domain_list, domain_key)
    if not domain_key then
        return nil
    end

    for _, domain_meta in ipairs(domain_list or {}) do
        if domain_meta.key == domain_key then
            return domain_meta
        end
    end
    return nil
end

local function _get_field_list(document, domain_key, compiled_domain)
    local ordered = {}
    local seen = {}
    local local_domain = Style.get_domain(document._document, domain_key, false)
    local local_fields = local_domain and local_domain.fields or {}
    for _, field_def in ipairs(StyleSchemaRegistry.list_fields(domain_key)) do
        local local_field = local_fields[field_def.key]
        local field = local_field and compiled_domain and compiled_domain.fields and compiled_domain.fields[field_def.key] or local_field
        if local_field and field then
            seen[field_def.key] = true
            table.insert(ordered,
            {
                key = field_def.key,
                display_name = field.display_name or field_def.display_name,
                type_id = field.type_id or field_def.type_id,
                builtin = true,
                can_delete = false,
                order = field_def.order or 1000,
            })
        end
    end

    for field_key, field in pairs(local_fields) do
        if not seen[field_key] then
            table.insert(ordered,
            {
                key = field_key,
                display_name = field.display_name or field_key,
                type_id = field.type_id,
                builtin = false,
                can_delete = field.custom == true and StyleSchemaRegistry.get_field(domain_key, field_key) == nil,
                order = 1000,
            })
        end
    end

    table.sort(ordered, function(left, right)
        if left.order ~= right.order then
            return left.order < right.order
        end
        return left.key < right.key
    end)

    return ordered
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

local function _open_inline_create_domain(document)
    local document_uid = _get_document_uid(document)
    inline_create_domain_by_guid[document_uid] = inline_create_domain_by_guid[document_uid] or util.CString()
    inline_create_domain_by_guid[document_uid]:set("")
    inline_create_domain_focus_by_guid[document_uid] = true
    inline_create_domain_active_by_guid[document_uid] = true
    inline_create_domain_was_active_by_guid[document_uid] = false
    inline_create_domain_error_by_guid[document_uid] = nil
end

local function _make_unique_custom_domain_name(document, display_name)
    local base_key = _trim(display_name) or "自定义域"
    if Style.get_domain(document._document, base_key, false) == nil
        and StyleSchemaRegistry.get_domain(base_key) == nil then
        return base_key
    end

    local index = 2
    while true do
        local key = string.format("%s%d", base_key, index)
        if Style.get_domain(document._document, key, false) == nil
            and StyleSchemaRegistry.get_domain(key) == nil then
            return key
        end
        index = index + 1
    end
end

local function _commit_inline_create_domain(document)
    local document_uid = _get_document_uid(document)
    local input = inline_create_domain_by_guid[document_uid]
    local display_name = _trim(input and input:get()) or "自定义域"
    local domain_key = _make_unique_custom_domain_name(document, display_name)
    display_name = domain_key

    if document:set_domain_display_name(domain_key, display_name) then
        selected_domain_by_guid[document_uid] = domain_key
        selected_field_by_guid[document_uid] = nil
        inline_create_domain_active_by_guid[document_uid] = nil
        inline_create_domain_focus_by_guid[document_uid] = nil
        inline_create_domain_was_active_by_guid[document_uid] = nil
        inline_create_domain_error_by_guid[document_uid] = nil
        if input then
            input:set("")
        end
        return domain_key
    end

    inline_create_domain_error_by_guid[document_uid] = "无法创建样式域"
    return nil
end

local function _open_create_field_popup()
    if create_field_key then
        create_field_key:set("")
    end
    if create_field_display_name then
        create_field_display_name:set("")
    end
    create_field_type_index = 1
    pending_create_field_popup = true
end

local function _delete_selected_domain(document, current_domain_key, domain_list)
    local document_uid = _get_document_uid(document)
    if not current_domain_key then
        return nil
    end

    local domain_meta = _get_domain_meta(domain_list, current_domain_key)
    if not domain_meta or domain_meta.can_delete ~= true then
        return current_domain_key
    end

    if not document:remove_domain(current_domain_key) then
        return current_domain_key
    end

    selected_domain_by_guid[document_uid] = nil
    selected_field_by_guid[document_uid] = nil
    return nil
end

local function _draw_inline_create_domain_row(document)
    local document_uid = _get_document_uid(document)
    if inline_create_domain_active_by_guid[document_uid] ~= true then
        return nil
    end

    local input = inline_create_domain_by_guid[document_uid]
    input = input or util.CString()
    inline_create_domain_by_guid[document_uid] = input

    if inline_create_domain_focus_by_guid[document_uid] == true then
        imgui.SetKeyboardFocusHere()
        inline_create_domain_focus_by_guid[document_uid] = nil
    end
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    local input_flags = (imgui.InputTextFlags and imgui.InputTextFlags.EnterReturnsTrue)
        or (imgui.InputTextFlags and imgui.InputTextFlags.None)
        or 0
    local submitted = imgui.InputText(
        string.format("##style_inline_create_domain_%s", document_uid),
        input,
        input_flags)
    local active = imgui.IsItemActive()
    local deactivated = imgui.IsItemDeactivatedAfterEdit()
    local should_commit_on_blur = inline_create_domain_was_active_by_guid[document_uid] == true and not active
    inline_create_domain_was_active_by_guid[document_uid] = active
    if submitted or deactivated or should_commit_on_blur then
        return _commit_inline_create_domain(document)
    end
    if active then
        inline_create_domain_error_by_guid[document_uid] = nil
    end
    if inline_create_domain_error_by_guid[document_uid] then
        imgui.TextColored(imgui.ImColor(214, 92, 92, 255).value, inline_create_domain_error_by_guid[document_uid])
    end
    return nil
end

local function _draw_domain_panel(document, compiled_sheet, panel_width)
    local current_domain_key, domain_list = _get_selected_domain(document, compiled_sheet)
    local document_uid = _get_document_uid(document)
    local width = panel_width ~= nil and panel_width or 250

    imgui.BeginChild(string.format("style_domains_%s", document_uid), imgui.ImVec2(width, 0), imgui.ChildFlags.Borders)
        local current_domain_meta = _get_domain_meta(domain_list, current_domain_key)
        local can_delete_current_domain = current_domain_meta and current_domain_meta.can_delete == true
        imgui.AlignTextToFramePadding()
        imgui.TextDisabled("样式域")
        local style = imgui.GetStyle()
        local button_width = _get_icon_button_width()
        local button_gap = _get_style_vec_x(style, "ItemSpacing", 8)
        local actions_width = button_width * 2 + button_gap
        local start_pos = imgui.GetCursorPos()
        local available_width = imgui.GetContentRegionAvail().x
        imgui.SameLine(start_pos.x + math.max(0, available_width - actions_width))
        local toolbar_icon_tint = _get_toolbar_icon_tint_color()
        if _draw_icon_button(
            string.format("style_domain_add_btn_%s", document_uid),
            "add-fill",
            "新增样式域",
            false,
            toolbar_icon_tint) then
            _open_inline_create_domain(document)
        end
        imgui.SameLine()
        if _draw_icon_button(
            string.format("style_domain_delete_btn_%s", document_uid),
            "delete-bin-5-line",
            "删除当前样式域",
            not can_delete_current_domain,
            toolbar_icon_tint) then
            current_domain_key = _delete_selected_domain(document, current_domain_key, domain_list)
        end
        imgui.SetCursorPos(start_pos)
        imgui.Separator()
        if #domain_list == 0 then
            imgui.TextDisabled("当前样式还没有修改项。")
        end

        for _, domain in ipairs(domain_list) do
            local is_selected = current_domain_key == domain.key
            if imgui.Selectable(string.format("%s##domain_%s", domain.display_name, domain.key), is_selected) then
                selected_domain_by_guid[document_uid] = domain.key
                selected_field_by_guid[document_uid] = nil
                current_domain_key = domain.key
            end
        end

        local created_domain_key = _draw_inline_create_domain_row(document)
        if created_domain_key then
            current_domain_key = created_domain_key
        end

        local blank_region = imgui.GetContentRegionAvail()
        if blank_region.y > 1 then
            imgui.InvisibleButton(
                string.format("##style_domain_blank_%s", document_uid),
                imgui.ImVec2(math.max(1, blank_region.x), math.max(32, blank_region.y)))
        end
    imgui.EndChild()

    return current_domain_key
end

_draw_create_field_popup = function(document, current_domain_key, compiled_domain)
    imgui.SetNextWindowSize(imgui.ImVec2(500, 0), imgui.ImGuiCond.Appearing)
    if imgui.BeginPopup("style_popup_create_field") then
        local type_list = _get_type_list()
        local type_entry = type_list[create_field_type_index] or type_list[1]
        local field_key = _trim(create_field_key:get())
        local display_name = _trim(create_field_display_name:get()) or field_key
        local field_exists = field_key ~= nil and compiled_domain and compiled_domain.fields and compiled_domain.fields[field_key] ~= nil
        local field_deprecated = field_key ~= nil and Style.is_deprecated_field(current_domain_key, field_key)

        local border_color = EditorThemeManager.get_tab_soft_border_color()
        imgui.PushStyleColor(imgui.ImGuiCol.ChildBg, EditorThemeManager.with_alpha(border_color, 0.08))
        imgui.PushStyleColor(imgui.ImGuiCol.Border, border_color)
        imgui.PushStyleVar(imgui.StyleVar.ChildBorderSize, 1)
        imgui.PushStyleVar(imgui.StyleVar.ChildRounding, 4)
        imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(10, 8))
        imgui.BeginChild(
            "style_create_custom_field_frame",
            imgui.ImVec2(0, math.max(188, imgui.GetTextLineHeightWithSpacing() * 8.5)),
            imgui.ChildFlags.Borders | imgui.ChildFlags.AlwaysUseWindowPadding)
            imgui.TextDisabled("内部标识")
            imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
            imgui.InputText("##style_create_field_key", create_field_key)
            ImGUIHelper.HoveredTooltip("用于保存和脚本匹配")

            imgui.TextDisabled("名称")
            imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
            imgui.InputText("##style_create_field_display_name", create_field_display_name)
            ImGUIHelper.HoveredTooltip("留空则使用内部标识")

            if type_entry then
                imgui.TextDisabled("字段类型")
                imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
                if imgui.BeginCombo("##style_field_type", type_entry.display_name) then
                    for index, item in ipairs(type_list) do
                        if imgui.Selectable(item.display_name, create_field_type_index == index) then
                            create_field_type_index = index
                        end
                    end
                    imgui.EndCombo()
                end
            end

            if field_key ~= nil and field_exists then
                imgui.TextColored(imgui.ImColor(214, 92, 92, 255).value, "该字段已存在。")
            elseif field_deprecated then
                imgui.TextColored(imgui.ImColor(214, 92, 92, 255).value, "该字段已废弃，不能创建。")
            end
        imgui.EndChild()
        imgui.PopStyleVar(3)
        imgui.PopStyleColor(2)

        local can_create = current_domain_key ~= nil
            and field_key ~= nil
            and type_entry ~= nil
            and not field_exists
            and not field_deprecated

        imgui.BeginDisabled(not can_create)
            if imgui.Button("创建字段", imgui.ImVec2(-1, 0)) then
                document:set_field_entry(current_domain_key, field_key,
                {
                    type_id = type_entry.type_id,
                    display_name = display_name,
                    custom = true,
                    has_value = false,
                })
                _select_field(document, current_domain_key, field_key)
                create_field_key:set("")
                create_field_display_name:set("")
                create_field_type_index = 1
                imgui.CloseCurrentPopup()
            end
        imgui.EndDisabled()
        imgui.EndPopup()
        return true
    end
    return false
end

local function _commit_field_display_name(document, current_domain_key, field_key, field, local_field, next_display_name)
    if not current_domain_key or not field_key or not field or field.custom ~= true then
        return
    end

    local normalized_display_name = _trim(next_display_name) or field_key
    if local_field == nil and normalized_display_name == (field.display_name or field_key) then
        return
    end

    document:set_field_entry(current_domain_key, field_key,
    {
        type_id = field.type_id,
        display_name = normalized_display_name,
        custom = field.custom == true,
        has_value = field.has_value == true,
        value = field.value,
    })
end

local function _draw_field_editor(document, domain_key, field_key, field, local_field)
    local definition = PinRegistry.get(field.type_id)
    local adapter = definition and definition.style_adapter or nil
    if not adapter or type(adapter.draw_editor) ~= "function" then
        imgui.TextDisabled("当前类型暂不支持在样式设计器中编辑。")
        return
    end

    local value = field.has_value == true and field.value or nil
    local state = document:get_ui_state(string.format("field_editor:%s/%s", domain_key, field_key))
    local changed, new_value = adapter.draw_editor(
    {
        id = string.format("##style_field_%s_%s_%s", _get_document_uid(document), domain_key, field_key),
        value = value,
        width = math.max(180, imgui.GetContentRegionAvail().x - 4),
        state = state,
        allow_clear = false,
    })
    if changed then
        document:set_field_value(domain_key, field_key, new_value,
        {
            type_id = field.type_id,
            display_name = field.display_name,
            custom = field.custom == true,
        })
    end
    return changed == true
        or (imgui.IsItemActive and imgui.IsItemActive() == true)
        or (imgui.IsItemFocused and imgui.IsItemFocused() == true)
end

local function _delete_selected_field(document, domain_key, field_list)
    local field_key, field_meta = _get_selected_field_key(document, domain_key, field_list)
    if not field_key then
        return false
    end

    if not field_meta or field_meta.can_delete ~= true then
        return false
    end

    if not document:remove_field_entry(domain_key, field_key) then
        return false
    end

    selected_field_by_guid[_get_document_uid(document)] = nil
    return true
end

local function _draw_field_panel_actions(document, domain_key, field_list)
    local document_uid = _get_document_uid(document)
    local selected_field_key, selected_field_meta = _get_selected_field_key(document, domain_key, field_list)
    local can_delete_selected_field = selected_field_meta and selected_field_meta.can_delete == true
    local style = imgui.GetStyle()
    local button_width = _get_icon_button_width()
    local total_width = button_width * 2 + _get_style_vec_x(style, "ItemSpacing", 8)
    local start_pos = imgui.GetCursorPos()
    local available_width = imgui.GetContentRegionAvail().x
    imgui.SameLine(start_pos.x + math.max(0, available_width - total_width))

    local toolbar_icon_tint = _get_toolbar_icon_tint_color()
    if _draw_icon_button(
        string.format("style_field_add_btn_%s_%s", document_uid, domain_key),
        "add-fill",
        "新增字段",
        false,
        toolbar_icon_tint) then
        _open_create_field_popup()
    end
    imgui.SameLine()
    local deleted = false
    if _draw_icon_button(
            string.format("style_field_delete_btn_%s_%s", document_uid, domain_key),
            "delete-bin-5-line",
            "删除当前字段",
            not can_delete_selected_field,
            toolbar_icon_tint) then
        deleted = _delete_selected_field(document, domain_key, field_list)
    end
    imgui.SetCursorPos(start_pos)

    return deleted
end

local function _is_background_image_clear_field(domain_key, field_key, field)
    if field_key ~= "background_image" then
        return false
    end
    if domain_key ~= "dialog_box" and domain_key ~= "choice_button" then
        return false
    end
    return field == nil or field.type_id == "texture"
end

local function _draw_field_action_button(document, domain_key, field_key, field, local_field)
    local can_reset = local_field ~= nil and (field == nil or field.custom ~= true or local_field.has_value == true)
    local hover_color = EditorThemeManager.with_alpha(EditorThemeManager.get_tab_soft_border_color(), 0.36)
    local active_color = EditorThemeManager.with_alpha(EditorThemeManager.get_tab_soft_border_color(), 0.48)
    local clicked = false
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, hover_color)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, active_color)
    imgui.PushStyleColor(imgui.ImGuiCol.Button, EditorThemeManager.with_alpha(EditorThemeManager.get_tab_soft_border_color(), 0.12))
    imgui.BeginDisabled(not can_reset)
        clicked = imgui.ImageButton(
            string.format("style_reset_%s_%s", domain_key, field_key),
            ResourcesManager.find_icon("arrow-go-back-fill"),
            _get_icon_button_size(),
            nil,
            nil,
            nil,
            _get_toolbar_icon_tint_color())
        if clicked then
            if _is_background_image_clear_field(domain_key, field_key, field) then
                document:clear_field_value(domain_key, field_key)
            elseif field and field.type_id == "shader" then
                document:clear_field_value(domain_key, field_key)
            elseif field and field.custom == true then
                document:clear_field_value(domain_key, field_key)
            else
                local default_field = Style.get_default_field(domain_key, field_key)
                if default_field and default_field.has_value == true then
                    document:set_field_entry(domain_key, field_key, default_field)
                else
                    document:remove_field_entry(domain_key, field_key)
                end
            end
        end
        ImGUIHelper.HoveredTooltip("重置")
    imgui.EndDisabled()
    imgui.PopStyleColor(3)
    return clicked
end

local function _draw_domain_header(document, current_domain_key, compiled_domain)
    imgui.AlignTextToFramePadding()
    imgui.TextDisabled(compiled_domain.display_name or current_domain_key)
    if imgui.IsItemHovered() then
        imgui.SetTooltip(string.format("内部标识：%s", current_domain_key))
    end
end

local function _draw_field_panel(document, compiled_sheet, current_domain_key)
    local compiled_domain = current_domain_key and compiled_sheet.domains and compiled_sheet.domains[current_domain_key] or nil
    local current_document = document._document
    local document_uid = _get_document_uid(document)

    imgui.BeginChild(string.format("style_fields_%s", document_uid), imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
        if not current_domain_key or not compiled_domain then
            imgui.TextDisabled("当前没有可用的样式域。")
        else
            _draw_domain_header(document, current_domain_key, compiled_domain)

            local field_list = _get_field_list(document, current_domain_key, compiled_domain)
            if _draw_field_panel_actions(document, current_domain_key, field_list) then
                field_list = _get_field_list(document, current_domain_key, compiled_domain)
            end
            if pending_create_field_popup then
                imgui.OpenPopup("style_popup_create_field")
                pending_create_field_popup = false
            end
            local create_field_popup_was_open = type(imgui.IsPopupOpen) == "function"
                and imgui.IsPopupOpen("style_popup_create_field") == true
            local create_field_popup_open = _draw_create_field_popup(document, current_domain_key, compiled_domain) == true
            local block_field_row_mouse = create_field_popup_was_open or create_field_popup_open

            if #field_list == 0 then
                imgui.TextDisabled("当前域没有符合条件的字段。")
                local blank_region = imgui.GetContentRegionAvail()
                if blank_region.y > 1 then
                    imgui.InvisibleButton(
                        string.format("##style_field_blank_%s_%s", document_uid, current_domain_key),
                        imgui.ImVec2(math.max(1, blank_region.x), math.max(32, blank_region.y)))
                end
            else
                local table_flags = imgui.TableFlags.Resizable
                    | imgui.TableFlags.Borders
                    | imgui.TableFlags.SizingStretchProp
                    | imgui.TableFlags.NoSavedSettings
                local field_row_height = math.max(42,
                    math.ceil(imgui.GetFrameHeight()
                        + _get_style_vec_y(imgui.GetStyle(), "CellPadding", 4) * 2
                        + 4))
                local header_field_gap = 4
                local available_table_height = math.max(160, imgui.GetContentRegionAvail().y)
                local natural_table_height = math.ceil(
                    imgui.GetTextLineHeight() + header_field_gap + #field_list * field_row_height + 2)
                local needs_table_scroll = natural_table_height > available_table_height
                if needs_table_scroll then
                    table_flags = table_flags | imgui.TableFlags.ScrollY
                end
                local table_height = needs_table_scroll and available_table_height or 0
                local table_clip_height = needs_table_scroll and available_table_height or natural_table_height
                local action_column_width = _get_icon_button_column_width(48)
                local table_screen_min = imgui.GetCursorScreenPos()
                local table_screen_max = imgui.ImVec2(
                    table_screen_min.x + math.max(1, imgui.GetContentRegionAvail().x),
                    table_screen_min.y + table_clip_height)
                local table_cell_padding_x = _get_style_vec_x(imgui.GetStyle(), "CellPadding", 4)
                imgui.PushStyleVar(imgui.StyleVar.CellPadding, imgui.ImVec2(table_cell_padding_x, 0))
                if block_field_row_mouse then
                    imgui.PushStyleVar(imgui.StyleVar.DisabledAlpha, 1)
                end
                imgui.BeginDisabled(block_field_row_mouse)
                if imgui.BeginTable(string.format("style_fields_table_%s_%s", document_uid, current_domain_key), 4, table_flags, imgui.ImVec2(0, table_height)) then
                    local draw_list = imgui.GetWindowDrawList()
                    local table_palette = _get_field_table_palette()
                    imgui.TableSetupColumn("名称", imgui.TableColumnFlags.WidthFixed, 190)
                    imgui.TableSetupColumn("类型", imgui.TableColumnFlags.WidthFixed, 130)
                    imgui.TableSetupColumn("值", imgui.TableColumnFlags.WidthStretch, 0)
                    imgui.TableSetupColumn("操作", imgui.TableColumnFlags.WidthFixed | imgui.TableColumnFlags.NoResize, action_column_width)
                    imgui.TableHeadersRow()
                    imgui.TableNextRow(nil, header_field_gap)
                    for gap_column = 0, 3 do
                        imgui.TableSetColumnIndex(gap_column)
                        imgui.Dummy(imgui.ImVec2(1, 0))
                    end

                    local selected_field_key = _get_selected_field_key(document, current_domain_key, field_list)
                    for _, field_meta in ipairs(field_list) do
                        local field = compiled_domain.fields[field_meta.key]
                        local local_field = Style.get_field(current_document, current_domain_key, field_meta.key)
                        local row_min = nil
                        local row_max = nil
                        local row_interacted = false
                        local is_selected = selected_field_key == field_meta.key
                        imgui.PushID(string.format("%s/%s", current_domain_key, field_meta.key))
                            imgui.TableNextRow(nil, field_row_height)

                            imgui.TableSetColumnIndex(0)
                            local row_cursor = imgui.GetCursorPos()
                            local selectable_flags = imgui.SelectableFlags.SpanAllColumns
                                | (imgui.SelectableFlags.AllowOverlap or 0)
                            imgui.PushStyleColor(imgui.ImGuiCol.Header, imgui.ImColor(0, 0, 0, 0).value)
                            imgui.PushStyleColor(imgui.ImGuiCol.HeaderHovered, imgui.ImColor(0, 0, 0, 0).value)
                            imgui.PushStyleColor(imgui.ImGuiCol.HeaderActive, imgui.ImColor(0, 0, 0, 0).value)
                                local row_clicked = imgui.Selectable(
                                    "##style_field_row",
                                    false,
                                    selectable_flags,
                                    imgui.ImVec2(0, field_row_height))
                                if row_clicked and not block_field_row_mouse then
                                    row_interacted = true
                                end
                            imgui.PopStyleColor(3)
                            row_min, row_max = _extend_rect_with_last_item(row_min, row_max)
                            row_min, row_max = _make_field_table_row_rect(row_min, row_max, table_screen_min.x, table_screen_max.x, field_row_height)
                            if row_interacted then
                                _select_field(document, current_domain_key, field_meta.key)
                                selected_field_key = field_meta.key
                                is_selected = true
                            end
                            imgui.SetCursorPos(row_cursor)

                            local display_name = field.display_name or field_meta.display_name or field_meta.key
                            if field.custom == true then
                                _align_field_table_cell(row_min, field_row_height, imgui.GetFrameHeight())
                                local name_active, name_committed = _draw_text_editor(document,
                                    string.format("field_display_name:%s/%s", current_domain_key, field_meta.key),
                                    display_name,
                                    string.format("##style_field_display_name_%s_%s", current_domain_key, field_meta.key),
                                    math.max(100, imgui.GetContentRegionAvail().x - 4),
                                    function(next_value)
                                        _commit_field_display_name(document, current_domain_key, field_meta.key, field, local_field, next_value)
                                    end)
                                row_interacted = row_interacted or name_active or name_committed
                            else
                                _align_field_table_cell(row_min, field_row_height, imgui.GetTextLineHeight())
                                imgui.Text(display_name)
                            end
                            row_min, row_max = _extend_rect_with_last_item(row_min, row_max)
                            if imgui.IsItemHovered() then
                                if field.custom == true then
                                    imgui.SetTooltip(string.format("字段名称\n内部标识：%s", field_meta.key))
                                else
                                    imgui.SetTooltip(string.format("内部标识：%s", field_meta.key))
                                end
                            end

                            imgui.TableSetColumnIndex(1)
                            _align_field_table_cell(row_min, field_row_height, imgui.GetTextLineHeight())
                            imgui.TextDisabled(_get_type_display_name(field.type_id))
                            row_min, row_max = _extend_rect_with_last_item(row_min, row_max)

                            imgui.TableSetColumnIndex(2)
                            _align_field_table_cell(row_min, field_row_height, imgui.GetFrameHeight())
                            row_interacted = _draw_field_editor(document, current_domain_key, field_meta.key, field, local_field) or row_interacted
                            row_min, row_max = _extend_rect_with_last_item(row_min, row_max)

                            imgui.TableSetColumnIndex(3)
                            _center_field_table_action(row_min, field_row_height)
                            row_interacted = _draw_field_action_button(document, current_domain_key, field_meta.key, field, local_field) or row_interacted
                            row_min, row_max = _extend_rect_with_last_item(row_min, row_max)

                            local row_left_clicked = not block_field_row_mouse and _is_row_left_clicked(row_min, row_max)
                            if row_left_clicked or (row_interacted and not block_field_row_mouse) then
                                _select_field(document, current_domain_key, field_meta.key)
                                selected_field_key = field_meta.key
                                is_selected = true
                            end
                            if is_selected then
                                _draw_field_table_row_selection(draw_list, row_min, row_max, table_palette, table_screen_min, table_screen_max)
                            end
                        imgui.PopID()
                    end
                    imgui.EndTable()
                end
                imgui.EndDisabled()
                if block_field_row_mouse then
                    imgui.PopStyleVar()
                end
                imgui.PopStyleVar()

                local blank_region = imgui.GetContentRegionAvail()
                if blank_region.y > 1 then
                    imgui.InvisibleButton(
                        string.format("##style_field_blank_%s_%s", document_uid, current_domain_key),
                        imgui.ImVec2(math.max(1, blank_region.x), math.max(32, blank_region.y)))
                end
            end
        end
    imgui.EndChild()
end

local function _draw_toolbar(document)
    imgui.Text("父样式")
    imgui.SameLine()
    local parent_reference = document._document and document._document.parent or nil
    local reference_width = math.min(360, math.max(220, imgui.GetContentRegionAvail().x - 90))
    local changed_parent_value, changed_parent = ResourceReferenceField.draw(
    {
        popup_id = string.format("style_parent_picker_%s", _get_document_uid(document)),
        asset_type = "style",
        value = parent_reference,
        width = reference_width,
        allow_clear = true,
    })
    if changed_parent then
        local next_guid = ResourceIndex.resolve_guid("style", changed_parent_value)
        if next_guid and next_guid == document._resource_guid then
            document:set_parent(nil)
        else
            document:set_parent(changed_parent_value)
        end
    end
end

local function _draw_document_body(document)
    if document._resource_missing then
        _draw_warning_banner("当前样式文件已从磁盘移除，保存前请确认路径是否仍然有效。", imgui.ImColor(196, 94, 94, 255).value)
    end
    if document._external_change_pending then
        if document:is_modified() then
            _draw_warning_banner("检测到磁盘中的样式文件发生变化，但当前文档存在未保存修改，已暂不自动同步。", imgui.ImColor(224, 168, 88, 255).value)
        else
            local auto_reload_ok = document:reload_from_disk({silent = true})
            if not auto_reload_ok then
                _draw_warning_banner("检测到磁盘中的样式文件发生变化，但自动同步失败，请检查控制台日志。", imgui.ImColor(214, 140, 82, 255).value)
            end
        end
    end

    local loaded_ok, load_err = document:ensure_document_loaded()
    if not loaded_ok then
        _draw_warning_banner(string.format("当前样式文件加载失败：%s", tostring(load_err or document:get_last_load_error() or "未知错误")), imgui.ImColor(196, 94, 94, 255).value)
        imgui.TextDisabled("无法加载当前样式文件。")
        return
    end

    local compiled_sheet, err = document:get_compiled_sheet(
    {
        allow_unsaved_snapshot = true,
    })
    if not compiled_sheet then
        imgui.TextColored(imgui.ImColor(214, 92, 92, 255).value, err or "无法编译当前样式。")
        return
    end

    if compiled_sheet.issues and #compiled_sheet.issues > 0 then
        local issue = compiled_sheet.issues[1]
        _draw_warning_banner(issue and issue.message or "当前样式存在编译问题。", imgui.ImColor(214, 140, 82, 255).value)
    end

    local current_domain_key = _get_selected_domain(document, compiled_sheet)
    _draw_toolbar(document)
    imgui.Separator()

    local table_flags = imgui.TableFlags.Resizable
        | imgui.TableFlags.SizingStretchProp
        | imgui.TableFlags.BordersInnerV
    if imgui.BeginTable(string.format("style_columns_%s", _get_document_uid(document)), 2, table_flags, imgui.ImVec2(0, 0)) then
        imgui.TableSetupColumn("样式域", imgui.TableColumnFlags.WidthStretch, 0.24)
        imgui.TableSetupColumn("字段", imgui.TableColumnFlags.WidthStretch, 0.76)
        imgui.TableNextRow()

        imgui.TableSetColumnIndex(0)
        current_domain_key = _draw_domain_panel(document, compiled_sheet, 0)

        imgui.TableSetColumnIndex(1)
        _draw_field_panel(document, compiled_sheet, current_domain_key)

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
    local visible, active = imgui.BeginTabItem(document._tab_label or document._id, tab_open, flag)
    if should_restore_selection then
        pending_tab_select_guid = nil
    end
    if visible then
        if not GlobalContext.is_debug_game and (active or visible) then
            StyleWorkspaceManager.set_workspace_current_style(document)
        end
        _with_document_context(document, function()
            _draw_document_body(document)
        end)
        imgui.EndTabItem()
    end

    if tab_open and not tab_open.val then
        StyleWorkspaceManager.close_style_in_workspace(document)
        pending_tab_select_guid = StyleWorkspaceManager.get_workspace_current_guid()
    end

    ModifyManager.set_context(previous_modify_context)
end

function module.on_enter()
    create_field_key = create_field_key or util.CString()
    create_field_display_name = create_field_display_name or util.CString()
    create_field_type_list = nil
    pending_create_field_popup = false
    pending_window_focus_frames = 0
    focus_reclaim_armed = false
    pending_open_error_text = nil
    StyleWorkspaceManager.load()
    pending_tab_select_guid = StyleWorkspaceManager.get_workspace_current_guid()
end

function module.on_exit()
    pending_create_field_popup = false
    pending_tab_select_guid = nil
    pending_window_focus_frames = 0
    focus_reclaim_armed = false
    pending_open_error_text = nil
end

function module.get_current_document()
    local document = StyleWorkspaceManager.find_by_guid(StyleWorkspaceManager.get_workspace_current_guid())
    if document and document._is_open and document._is_open.val then
        return document
    end
    return nil
end

local function _has_active_input_widget()
    return imgui.IsAnyItemActive() or imgui.IsAnyItemFocused()
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

function module.open_style_document(value, options)
    local open_options = options or {select = true}
    local document, err = StyleWorkspaceManager.open_style_in_workspace(value, open_options)
    if document then
        pending_open_error_text = nil
        if open_options.select ~= false then
            pending_tab_select_guid = document._resource_guid or nil
            pending_window_focus_frames = math.max(pending_window_focus_frames, 2)
        end
    elseif not document and err and err ~= "" then
        local resource_name = nil
        if type(value) == "table" then
            resource_name = value._resource_id or value._display_name or value._path or value._id
        end
        if not resource_name then
            local guid = ResourceIndex.resolve_guid("style", value)
            local meta = guid and ResourceIndex.find_by_guid(guid) or nil
            resource_name = meta and (meta.id or meta.display_name or meta.path) or nil
        end
        resource_name = resource_name or tostring(value)
        pending_open_error_text = string.format("打开样式文件失败：%s。详情请查看日志。", tostring(resource_name))
        pending_window_focus_frames = math.max(pending_window_focus_frames, 2)
        LogManager.log(string.format("打开样式文件失败：%s\n%s", tostring(resource_name), tostring(err or "未知错误")), "error")
    end
    return document, err
end

function module.create_style_file(path)
    local empty_document = Style.new_document({include_default_domains = true, use_default_values = true})
    local ok, err = Style.save(path, empty_document)
    if not ok then
        return false, err
    end

    ResourceIndex.scan()
    StyleWorkspaceManager.reconcile()
    local document, open_err = module.open_style_document(ResourceIndex.find_guid_by_path(path), {select = true})
    return document ~= nil, document or open_err or "无法打开新建的样式文件"
end

function module.on_update(self, delta)
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    if pending_window_focus_frames > 0 and not GlobalContext.is_resource_modal_active then
        imgui.SetNextWindowFocus()
        pending_window_focus_frames = pending_window_focus_frames - 1
    end
    local is_open = imgui.Begin("样式设计视图")
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
            if imgui.BeginTabBar("TabBar_Styles", imgui.TabBarFlags.Reorderable | imgui.TabBarFlags.AutoSelectNewTabs) then
                local open_document_list = StyleWorkspaceManager.get_workspace_open_documents()
                if #open_document_list == 0 then
                    imgui.TextDisabled("当前没有打开的样式文件，可从资产视图双击 .style 文件打开。")
                end
                for _, document in ipairs(open_document_list) do
                    _draw_document_tab(document)
                end
                imgui.EndTabBar()
            else
                imgui.TextDisabled("当前没有打开的样式文件，可从资产视图双击 .style 文件打开。")
            end
            if tab_border_style then
                ImGUIHelper.PopSoftTabBorderStyle(tab_border_style)
            end

            local io = imgui.GetIO()
            local can_handle_shortcuts = window_focused
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
    was_window_focused = window_focused
    StyleWorkspaceManager.sync_workspace_state()
end

return module

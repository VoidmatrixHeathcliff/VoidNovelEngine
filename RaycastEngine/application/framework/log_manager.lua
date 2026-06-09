local module = {}

local imgui = Engine.ImGUI
local sdl = Engine.SDL

local EditorThemeManager = require("application.framework.editor_theme_manager")
local ImGUIHelper = require("application.framework.imgui_helper")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")

SettingsManager.set_logger(module)

local log_obj_list = {}
local log_text_bytes = 0
local dropped_log_count = 0
local max_log_count <const> = 3000
local max_log_text_bytes <const> = 1024 * 1024
local icon_config =
{
    info = {icon_id = "information-2-fill", color = imgui.ImVec4(imgui.ImColor(44, 169, 225, 255).value)},
    warning = {icon_id = "alert-fill", color = imgui.ImVec4(imgui.ImColor(248, 181, 0, 255).value)},
    error = {icon_id = "close-circle-fill", color = imgui.ImVec4(imgui.ImColor(197, 61, 67, 255).value)},
    success = {icon_id = "checkbox-circle-fill", color = imgui.ImVec4(imgui.ImColor(104, 190, 141, 255).value)},
    debug = {icon_id = "bug-fill", color = imgui.ImVec4(imgui.ImColor(188, 100, 164, 255).value)},
}
local log_type_label_map =
{
    info = "INFO",
    warning = "WARNING",
    error = "ERROR",
    success = "SUCCESS",
    debug = "DEBUG",
}

local function _get_flow_manager()
    return require("application.framework.flow_manager")
end

local function _open_story_document(value, options)
    return require("application.scene.window.window_story_designer").open_story_document(value, options)
end

local function _open_flow_document(value, options)
    return require("application.scene.window.window_flow_designer").open_flow_document(value, options)
end

local function _get_menu_icon_tint()
    return EditorThemeManager.get_icon_tint_color()
end

local function _menu_item_with_icon(icon_id, text, enabled)
    local height = imgui.GetTextLineHeight()
    local size_icon = imgui.ImVec2(height, height)
    imgui.Image(ResourcesManager.find_icon(icon_id), size_icon, nil, nil, _get_menu_icon_tint(), nil)
    imgui.SameLine()
    return imgui.MenuItem(text, nil, false, enabled == nil and true or enabled)
end

local function _is_mouse_in_rect(min, max, position)
    if not (min and max and position) then
        return false
    end
    return position.x >= min.x and position.x <= max.x and position.y >= min.y and position.y <= max.y
end

local function _get_log_type_label(type_msg)
    local key = tostring(type_msg or "info")
    return log_type_label_map[key] or string.upper(key)
end

local function _format_log_line(log_obj)
    return string.format("[%s] %s %s",
        _get_log_type_label(log_obj and log_obj.type_msg),
        tostring(log_obj and log_obj.time or ""),
        tostring(log_obj and log_obj.msg or ""))
end

local function _format_all_logs()
    local line_list = {}
    for _, log_obj in ipairs(log_obj_list) do
        line_list[#line_list + 1] = _format_log_line(log_obj)
    end
    return table.concat(line_list, "\n")
end

local function _estimate_log_bytes(log_obj)
    if not log_obj then
        return 0
    end
    return #tostring(log_obj.msg or "")
        + #tostring(log_obj.type_msg or "")
        + #tostring(log_obj.time or "")
        + 64
end

local function _trim_log_list()
    while #log_obj_list > max_log_count or log_text_bytes > max_log_text_bytes do
        local removed = table.remove(log_obj_list, 1)
        if not removed then
            log_text_bytes = 0
            break
        end
        log_text_bytes = math.max(0, log_text_bytes - _estimate_log_bytes(removed))
        dropped_log_count = dropped_log_count + 1
    end
end

local function _set_clipboard_text(text)
    if sdl and sdl.SetClipboardText then
        sdl.SetClipboardText(tostring(text or ""))
    end
end

local function _navigate_log_target(nav_data)
    if not nav_data then
        return
    end

    local FlowManager = _get_flow_manager()
    local flow_guid = nav_data.flow_guid or nav_data.blueprint
    if not flow_guid then
        return
    end

    local document = FlowManager.get_document(flow_guid, "flow_document_open")
    if not document then
        return
    end

    if document.kind == "text" then
        document = _open_story_document(document, {select = true})
    else
        document = _open_flow_document(document, {select = true})
    end
    if not document then
        return
    end

    if document.kind == "text" then
        if document.request_navigate_to_line then
            document:request_navigate_to_line(nav_data.line, nav_data.column)
        end
        return
    end

    local node_id = nav_data.node_id or nav_data.id
    if document.request_navigate_to_node then
        document:request_navigate_to_node(node_id)
        return
    end

    if document._context and node_id ~= nil then
        imgui.NodeEditor.SetCurrentEditor(document._context)
        imgui.NodeEditor.SelectNode(imgui.NodeEditor.NodeId(node_id))
        imgui.NodeEditor.NavigateToSelection()
    end
end

module.log = function(msg, type_msg, nav_data)
    local log_obj =
    {
        msg = msg,
        type_msg = type_msg or "info",
        time = os.date("[%Y-%m-%d %H:%M:%S]"),
        nav_data = nav_data,
    }
    table.insert(log_obj_list, log_obj)
    log_text_bytes = log_text_bytes + _estimate_log_bytes(log_obj)
    _trim_log_list()
end

module.clear = function()
    log_obj_list = {}
    log_text_bytes = 0
end

module.get_stats = function()
    return
    {
        count = #log_obj_list,
        dropped_count = dropped_log_count,
        text_bytes = log_text_bytes,
        max_count = max_log_count,
        max_text_bytes = max_log_text_bytes,
    }
end

local function _draw_log_row(log_obj, idx, editor_zoom_ratio)
    local config = icon_config[log_obj.type_msg] or icon_config.info
    local row_min = imgui.GetCursorScreenPos()
    local row_width = math.max(1, tonumber(imgui.GetContentRegionAvail().x) or 0)
    local text_line_height = tonumber(imgui.GetTextLineHeight()) or (14 * editor_zoom_ratio)
    local outer_padding_x = math.max(6, math.floor(8 * editor_zoom_ratio + 0.5))
    local outer_padding_y = math.max(2, math.floor(2 * editor_zoom_ratio + 0.5))
    local item_gap = math.max(6, math.floor(6 * editor_zoom_ratio + 0.5))
    local size_icon = imgui.ImVec2(
        math.max(16, math.floor(18 * editor_zoom_ratio + 0.5)),
        math.max(16, math.floor(18 * editor_zoom_ratio + 0.5)))
    local button_padding = math.max(0, math.floor(1 * editor_zoom_ratio + 0.5))
    local button_extent = math.max(12, math.floor(math.min(size_icon.y, text_line_height + button_padding * 2) + 0.5))
    local size_button = imgui.ImVec2(button_extent, button_extent)
    local time_text = tostring(log_obj.time or "")
    local message_text = tostring(log_obj.msg or "")
    local time_size = imgui.CalcTextSize(time_text)
    local button_reserved_width = log_obj.nav_data and (size_button.x + button_padding * 2 + item_gap) or 0
    local message_x = row_min.x + outer_padding_x + size_icon.x + item_gap + time_size.x + item_gap
    local message_wrap_width = math.max(
        80,
        row_width - (message_x - row_min.x) - outer_padding_x - button_reserved_width)
    local message_size = imgui.CalcTextSize(message_text ~= "" and message_text or " ", false, message_wrap_width)
    local first_line_height = math.max(
        text_line_height,
        size_icon.y,
        log_obj.nav_data and size_button.y or 0)
    local content_height = math.max(first_line_height, tonumber(message_size.y) or text_line_height)
    local row_height = math.max(
        content_height + outer_padding_y * 2,
        text_line_height + outer_padding_y * 2)
    local row_max = imgui.ImVec2(row_min.x + row_width, row_min.y + row_height)
    local first_line_top_y = row_min.y + outer_padding_y
    local mouse_position = imgui.GetMousePos()
    local popup_id = string.format("log_context_%d", idx)
    local hovered = imgui.IsWindowHovered() and _is_mouse_in_rect(row_min, row_max, mouse_position)

    if hovered and imgui.IsMouseReleased(1) then
        imgui.OpenPopup(popup_id)
    end

    local popup_open = imgui.IsPopupOpen(popup_id)
    if hovered or popup_open then
        local draw_list = imgui.GetWindowDrawList()
        local fill_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.HeaderHovered)):to_u32()
        local border_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.Border)):to_u32()
        local row_rounding = math.max(4, math.floor(4 * editor_zoom_ratio + 0.5))
        local border_thickness = math.max(1, math.floor(1 * editor_zoom_ratio + 0.5))
        draw_list:AddRectFilled(row_min, row_max, border_color, row_rounding)
        draw_list:AddRectFilled(
            imgui.ImVec2(row_min.x + border_thickness, row_min.y + border_thickness),
            imgui.ImVec2(row_max.x - border_thickness, row_max.y - border_thickness),
            fill_color,
            math.max(0, row_rounding - border_thickness))
    end

    imgui.SetCursorScreenPos(imgui.ImVec2(
        row_min.x + outer_padding_x,
        first_line_top_y + math.max(0, (text_line_height - size_icon.y) * 0.5)))
    imgui.Image(ResourcesManager.find_icon(config.icon_id), size_icon, nil, nil, config.color, nil)

    imgui.SetCursorScreenPos(imgui.ImVec2(
        row_min.x + outer_padding_x + size_icon.x + item_gap,
        first_line_top_y + math.max(0, (text_line_height - time_size.y) * 0.5)))
    imgui.Text(time_text)

    imgui.SetCursorScreenPos(imgui.ImVec2(message_x, first_line_top_y))
    local message_cursor = imgui.GetCursorPos()
    local message_wrap_pos = (tonumber(message_cursor.x) or 0) + message_wrap_width
    imgui.PushTextWrapPos(message_wrap_pos)
    imgui.Text(message_text)
    imgui.PopTextWrapPos()

    if log_obj.nav_data then
        imgui.SetCursorScreenPos(imgui.ImVec2(
            row_max.x - outer_padding_x - size_button.x,
            first_line_top_y + math.max(0, (text_line_height - size_button.y) * 0.5)))
        imgui.PushStyleVar(imgui.StyleVar.FramePadding, imgui.ImVec2(button_padding, button_padding))
        if imgui.ImageButton(
            string.format("nav_btn_%d", idx),
            ResourcesManager.find_icon("navigation-fill"),
            size_button,
            nil,
            nil,
            nil,
            _get_menu_icon_tint()) then
            _navigate_log_target(log_obj.nav_data)
        end
        imgui.PopStyleVar()
        ImGUIHelper.HoveredTooltip(log_obj.nav_data.kind == "text" and "导航到该脚本位置" or "导航到该节点")
    end

    local action = nil
    if imgui.BeginPopup(popup_id) then
        if _menu_item_with_icon("file-copy-line", "复制本行日志") then
            action = {kind = "copy_line", log_obj = log_obj}
            imgui.CloseCurrentPopup()
        end
        if _menu_item_with_icon("file-copy-fill", "复制全部日志", #log_obj_list > 0) then
            action = {kind = "copy_all"}
            imgui.CloseCurrentPopup()
        end
        if _menu_item_with_icon("delete-bin-5-fill", "清空控制台", #log_obj_list > 0) then
            action = {kind = "clear"}
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end

    imgui.SetCursorScreenPos(row_min)
    local style = imgui.GetStyle()
    local next_row_spacing_y = math.max(1, math.floor(1 * editor_zoom_ratio + 0.5))
    imgui.PushStyleVar(imgui.StyleVar.ItemSpacing, imgui.ImVec2(style.ItemSpacing.x, next_row_spacing_y))
    imgui.Dummy(imgui.ImVec2(row_width, row_height))
    imgui.PopStyleVar()
    return action
end

module.on_update = function()
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    local clipboard_text = nil
    local should_clear = false

    for idx, log_obj in ipairs(log_obj_list) do
        local action = _draw_log_row(log_obj, idx, editor_zoom_ratio)
        if action then
            if action.kind == "copy_line" then
                clipboard_text = _format_log_line(action.log_obj)
            elseif action.kind == "copy_all" then
                clipboard_text = _format_all_logs()
            elseif action.kind == "clear" then
                should_clear = true
            end
        end
    end

    if clipboard_text ~= nil then
        _set_clipboard_text(clipboard_text)
    end
    if should_clear then
        module.clear()
    end
end

return module

local sdl = Engine.SDL
local imgui = Engine.ImGUI

local GlobalContext = require("application.framework.global_context")
local SaveSlotGridModel = require("application.framework.save_slot_grid_model")
local SaveManager = require("application.framework.save_manager")
local SaveThumbnailCache = require("application.framework.save_thumbnail_cache")
local SaveLocation = require("application.framework.save_location")

local module = {}

local slot_list_cache = {}
local slot_status_cache = {}
local selected_slot_id = nil
local slot_context_slot_id = nil
local slot_context_popup_pos = nil
local pending_slot_context_popup = false
local slot_grid_page = 1
local was_window_focused = false
local observed_profile_guid = ""
local observed_profile_signature = ""

local _sync_slot_grid_to_slot

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

local function _get_button_width_for_text(text, min_width, extra_padding)
    local text_size = imgui.CalcTextSize(tostring(text or ""))
    local style = imgui.GetStyle()
    local frame_padding_x = style and style.FramePadding and style.FramePadding.x or 8
    local safe_padding = tonumber(extra_padding) or 20
    return math.max(tonumber(min_width) or 0, math.ceil((text_size and text_size.x or 0) + frame_padding_x * 2 + safe_padding))
end

local function _safe_get_effective_storage_info()
    local ok, info = pcall(SaveManager.get_effective_storage_info)
    if ok and type(info) == "table" then
        return info
    end
    return
    {
        is_writable = false,
        write_error = tostring(info or "无法读取当前生效存档目录"),
    }
end

local function _trim_slot_number(text)
    local value = tostring(text or ""):gsub("^0+", "")
    return value ~= "" and value or "0"
end

local function _format_slot_id_for_user(slot_id, category)
    if SaveManager.get_slot_display_name then
        local display_name = SaveManager.get_slot_display_name(slot_id, category)
        if _trim(display_name) then
            return display_name
        end
    end

    local slot_text = tostring(slot_id or "")
    local category_id = _trim(category) or ""
    local manual_index = slot_text:match("^manual_(%d+)$")
    if category_id == "manual" or manual_index then
        return manual_index and string.format("手动存档 %s", _trim_slot_number(manual_index)) or "手动存档"
    end

    return _trim(slot_text) or "未命名存档"
end

local function _format_slot_label(manifest, status)
    local slot_id = tostring(manifest and manifest.slot_id or "")
    local title = _trim(manifest and manifest.title)
    local category_text = SaveSlotGridModel.format_type_label(manifest)
    local display_name = _trim(manifest and manifest.slot_display_name)
        or _format_slot_id_for_user(slot_id, manifest and manifest.category)
    local base_text = title and title ~= slot_id and title or display_name
    local label = string.format("%s：%s", category_text, base_text)
    if status and status.valid ~= true then
        label = label .. "（不可恢复）"
    end
    return label
end

local function _get_slot_grid_profile_options()
    return SaveSlotGridModel.get_profile_options()
end

local function _get_slot_grid_total_pages()
    return _get_slot_grid_profile_options().page_count
end

local function _get_slot_grid_slots_per_page()
    return _get_slot_grid_profile_options().slots_per_page
end

local function _clamp_slot_grid_page(page)
    return SaveSlotGridModel.normalize_page(page, _get_slot_grid_total_pages())
end

local function _get_slot_location(slot_id, manifest)
    if not slot_id then
        return nil
    end

    local source = type(manifest) == "table" and (manifest.location or manifest.slot_id) or slot_id
    local category = type(manifest) == "table" and manifest.category or nil
    local ok, location = pcall(SaveManager.normalize_location, source, {category = category})
    if ok and type(location) == "table" then
        return location
    end
    return nil
end

_sync_slot_grid_to_slot = function(slot_id)
    if not slot_id then
        slot_grid_page = 1
        return
    end

    local ok, manifest = pcall(SaveManager.get_slot_manifest, slot_id)
    local location = _get_slot_location(slot_id, ok and manifest or nil)
    if not location then
        return
    end

    if SaveLocation.normalize_category(location.category) == "manual" then
        slot_grid_page = _clamp_slot_grid_page(location.page)
    end
end

local function _refresh_slot_list()
    local ok, slots = pcall(SaveManager.list_slots)
    if not ok then
        slot_list_cache = {}
        slot_status_cache = {}
        selected_slot_id = nil
        _sync_slot_grid_to_slot(nil)
        return false, tostring(slots or "无法读取存档列表")
    end

    slot_list_cache = type(slots) == "table" and slots or {}
    slot_status_cache = {}
    if selected_slot_id ~= nil then
        local found = false
        for _, item in ipairs(slot_list_cache) do
            if item.slot_id == selected_slot_id then
                found = true
                break
            end
        end
        if not found then
            selected_slot_id = slot_list_cache[1] and slot_list_cache[1].slot_id or nil
        end
    elseif slot_list_cache[1] then
        selected_slot_id = slot_list_cache[1].slot_id
    end
    if selected_slot_id then
        _sync_slot_grid_to_slot(selected_slot_id)
    else
        _sync_slot_grid_to_slot(nil)
    end
    return true
end

local function _get_storage_notice(info)
    if type(info) ~= "table" then
        return nil, nil
    end

    if info.is_writable == false then
        return "error", string.format("当前无法访问生效存档目录：%s", tostring(info.write_error or info.root_path or "未记录"))
    end
    if info.fallback_applied == true then
        return "warning", string.format("当前主存档目录不可写，调试器正在使用回退目录：%s", tostring(info.root_path or "未记录"))
    end
    return nil, nil
end

local function _draw_storage_notice(info)
    local kind, text = _get_storage_notice(info)
    if not kind or not text then
        return
    end

    local color = kind == "error"
        and imgui.ImColor(197, 61, 67, 255).value
        or imgui.ImColor(219, 162, 64, 255).value
    if imgui.PushTextWrapPos then
        imgui.PushTextWrapPos(0)
    end
    imgui.TextColored(color, text)
    if imgui.PopTextWrapPos then
        imgui.PopTextWrapPos()
    end
    imgui.Separator()
end

local function _get_slot_status(slot_id)
    if not slot_id then
        return nil
    end
    local status = slot_status_cache[slot_id]
    if status == nil then
        local ok, result = pcall(SaveManager.get_slot_runtime_status, slot_id)
        if ok and type(result) == "table" then
            status = result
        else
            status =
            {
                slot_id = slot_id,
                valid = false,
                error = tostring(result or "无法预检存档"),
            }
        end
        slot_status_cache[slot_id] = status
    end
    return status
end

local function _open_flow_document(value, options)
    return require("application.scene.window.window_flow_designer").open_flow_document(value, options)
end

local function _open_story_document(value, options)
    return require("application.scene.window.window_story_designer").open_story_document(value, options)
end

local function _set_action_feedback(kind, text)
    local message = tostring(text or "")
    if message == "" then
        return
    end

    local flags = nil
    if kind == "error" then
        flags = sdl.MessageBoxFlags.ERROR
    elseif kind == "warning" then
        flags = sdl.MessageBoxFlags.WARNING
    end

    if flags and sdl and sdl.ShowSimpleMessageBox then
        sdl.ShowSimpleMessageBox(flags, "存档调试器", message, GlobalContext.window)
    end
end

local function _find_selected_manifest()
    if not selected_slot_id then
        return nil
    end
    local ok, manifest = pcall(SaveManager.get_slot_manifest, selected_slot_id)
    return ok and manifest or nil
end

local function _find_selected_state()
    if not selected_slot_id then
        return nil
    end
    local ok, state = pcall(SaveManager.get_slot_state, selected_slot_id)
    return ok and state or nil
end

local function _resolve_manifest_thumbnail_path(manifest)
    if type(manifest) ~= "table" or not SaveManager.resolve_thumbnail_path then
        return nil
    end
    local ok, thumbnail_path = pcall(SaveManager.resolve_thumbnail_path, manifest.location or manifest.slot_id)
    return ok and _trim(thumbnail_path) or nil
end

local function _draw_summary_row(label, value)
    imgui.TextDisabled(label)
    imgui.SameLine()
    if imgui.PushTextWrapPos then
        imgui.PushTextWrapPos(0)
    end
    imgui.Text(tostring(value ~= nil and value ~= "" and value or "未记录"))
    if imgui.PopTextWrapPos then
        imgui.PopTextWrapPos()
    end
end

local function _navigate_to_target(target)
    if not target or not target.document then
        return false, "error", "无法定位存档对应的流程文档"
    end

    local document = target.document
    if document.kind == "text" then
        document = _open_story_document(document, {select = true})
    else
        document = _open_flow_document(document, {select = true})
    end
    if not document then
        return false, "error", "无法打开存档对应的流程文档"
    end

    local anchor = type(target.anchor) == "table" and target.anchor or {}
    if document.kind == "text" then
        local line = tonumber(anchor.line)
        if line and document.request_navigate_to_line then
            document:request_navigate_to_line(line, tonumber(anchor.column) or 1)
            return true, "success", "已定位到剧本文本存档位置"
        end
        return true, "warning", "已打开目标剧本文档，当前存档未记录精确行号"
    end

    local node_id = tonumber(anchor.node_id)
    if node_id and document.request_navigate_to_node and document:request_navigate_to_node(node_id,
        {
            stabilize_view = true,
            duration = 0.22,
            focus_rect_scale = 1.8,
        }) then
        return true, "success", "已定位到流程图存档节点"
    end
    return true, "warning", "已打开目标流程，但存档节点已失效，无法精确定位"
end

local function _locate_slot(slot_id)
    if not slot_id then
        return false, "error", "请先选择存档"
    end

    local status = _get_slot_status(slot_id)
    local target = status and status.target or nil
    local err = status and status.error or nil
    if not target then
        return false, "error", tostring(err or "无法解析存档目标")
    end
    return _navigate_to_target(target)
end

local function _handle_locate_action(slot_id)
    local call_ok, ok, kind, message = pcall(_locate_slot, slot_id)
    if not call_ok then
        _set_action_feedback("error", tostring(ok or "定位存档失败"))
        return false
    end
    _set_action_feedback(kind, message)
    return ok
end

local function _handle_take_over_action(slot_id)
    if not slot_id then
        _set_action_feedback("error", "请先选择存档")
        return false
    end

    local call_ok, ok, result = pcall(SaveManager.take_over_slot, slot_id,
    {})
    if not call_ok then
        _set_action_feedback("error", tostring(ok or "接管存档失败"))
        return false
    end
    if ok ~= true then
        _set_action_feedback("error", tostring(result or "接管存档失败"))
        return false
    end

    local nav_call_ok, nav_ok, nav_kind, nav_message = pcall(_navigate_to_target, result)
    if not nav_call_ok then
        local error_message = tostring(nav_ok or "无法同步定位到编辑器视图")
        nav_ok = false
        nav_kind = "warning"
        nav_message = error_message
    end
    if nav_ok then
        if nav_kind == "success" then
            _set_action_feedback("success", "已接管运行时，并定位到存档位置")
        else
            _set_action_feedback("success", string.format("已接管运行时。%s", nav_message))
        end
    else
        _set_action_feedback("warning", "已接管运行时，但未能同步定位到编辑器视图")
    end
    return true
end

local function _delete_slot(slot_id)
    if not slot_id then
        return false
    end

    local call_ok, ok, err = pcall(SaveManager.delete_slot, slot_id)
    if not call_ok then
        local error_message = tostring(ok or "删除存档失败")
        ok = false
        err = error_message
    end
    if ok == false then
        _set_action_feedback("error", tostring(err or "删除存档失败"))
        return false
    end

    _set_action_feedback("success", "已删除所选存档")
    slot_context_slot_id = nil
    slot_context_popup_pos = nil
    _refresh_slot_list()
    return true
end

local function _open_slot_context_menu(slot_id)
    if not slot_id then
        return
    end

    selected_slot_id = slot_id
    _sync_slot_grid_to_slot(slot_id)
    slot_context_slot_id = slot_id
    local mouse_pos = imgui.GetMousePos and imgui.GetMousePos() or nil
    slot_context_popup_pos = mouse_pos and {x = mouse_pos.x, y = mouse_pos.y} or nil
    pending_slot_context_popup = true
end

local function _draw_slot_context_menu()
    if pending_slot_context_popup then
        imgui.OpenPopup("save_debugger_slot_context")
        pending_slot_context_popup = false
    end

    if slot_context_popup_pos then
        imgui.SetNextWindowPos(imgui.ImVec2(slot_context_popup_pos.x, slot_context_popup_pos.y), imgui.ImGuiCond.Always)
    end
    if not imgui.BeginPopup("save_debugger_slot_context") then
        slot_context_slot_id = nil
        slot_context_popup_pos = nil
        return
    end

    local slot_id = slot_context_slot_id or selected_slot_id
    if imgui.MenuItem("删除存档", nil, false, slot_id ~= nil) then
        _delete_slot(slot_id)
        imgui.CloseCurrentPopup()
    end
    imgui.EndPopup()
end

local function _draw_slot_list_panel(info)
    imgui.BeginChild("save_debugger_slot_list", imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
        for _, manifest in ipairs(slot_list_cache) do
            local status = slot_status_cache[manifest.slot_id]
            local is_invalid = status and status.valid ~= true
            local label = _format_slot_label(manifest, status)
            local selectable_flags = imgui.SelectableFlags.AllowDoubleClick
            if is_invalid then
                imgui.PushStyleColor(imgui.ImGuiCol.Text, imgui.ImColor(197, 61, 67, 255).value)
                imgui.PushStyleColor(imgui.ImGuiCol.TextDisabled, imgui.ImColor(197, 61, 67, 255).value)
            end
            local activated = imgui.Selectable(string.format("%s##%s", label, manifest.slot_id), selected_slot_id == manifest.slot_id, selectable_flags)
            if is_invalid then
                imgui.PopStyleColor(2)
            end
            if activated then
                if selected_slot_id ~= manifest.slot_id then
                    selected_slot_id = manifest.slot_id
                    _sync_slot_grid_to_slot(manifest.slot_id)
                end
                if imgui.IsMouseDoubleClicked(0) then
                    if not is_invalid then
                        _handle_locate_action(manifest.slot_id)
                    else
                        _set_action_feedback("error", tostring(status and status.error or "当前存档无法定位"))
                    end
                end
            end
            if imgui.IsItemHovered() and imgui.IsMouseReleased(1) then
                _open_slot_context_menu(manifest.slot_id)
            end
        end
        if #slot_list_cache == 0 then
            if info and info.is_writable == false then
                imgui.TextColored(imgui.ImColor(197, 61, 67, 255).value, "当前无法访问存档目录，暂时无法列出存档位置。")
                if imgui.PushTextWrapPos then
                    imgui.PushTextWrapPos(0)
                end
                imgui.TextDisabled(tostring(info.write_error or info.root_path or "未记录"))
                if imgui.PopTextWrapPos then
                    imgui.PopTextWrapPos()
                end
            else
                imgui.TextDisabled("当前没有任何存档。")
            end
        end
        _draw_slot_context_menu()
    imgui.EndChild()
end

local function _draw_summary_panel(manifest, state, slot_status)
    if not manifest then
        imgui.TextDisabled("请选择一个存档。")
        return
    end

    _draw_summary_row("类型：", SaveSlotGridModel.format_type_label(manifest))
    _draw_summary_row("来源：", SaveSlotGridModel.format_source(manifest, state))
    _draw_summary_row("时间：", SaveSlotGridModel.format_time_short(manifest.updated_at or manifest.created_at))
end

local function _get_sdl_texture_size(texture)
    if not texture then
        return 0, 0
    end
    local ok, info = pcall(sdl.QueryTexture, texture)
    if ok and type(info) == "table" then
        return tonumber(info.w) or 0, tonumber(info.h) or 0
    end
    return 0, 0
end

local function _draw_sdl_texture_letterboxed(id, texture, width, height, placeholder_text)
    local size = imgui.ImVec2(width, height)
    local drew_image = false
    imgui.PushStyleColor(imgui.ImGuiCol.ChildBg, imgui.ImColor(0, 0, 0, 255).value)
    imgui.BeginChild(id, size, imgui.ChildFlags.Borders, imgui.WindowFlags.NoScrollbar | imgui.WindowFlags.NoScrollWithMouse)
        if texture then
            local texture_width, texture_height = _get_sdl_texture_size(texture)
            local draw_rect = SaveSlotGridModel.fit_rect_preserve_aspect(
            {
                x = 0,
                y = 0,
                w = width,
                h = height,
            }, texture_width, texture_height) or {x = 0, y = 0, w = width, h = height}
            imgui.SetCursorPos(imgui.ImVec2(draw_rect.x, draw_rect.y))
            local ok_image = pcall(imgui.Image, texture, imgui.ImVec2(draw_rect.w, draw_rect.h), nil, nil, nil, nil)
            drew_image = ok_image == true
        elseif placeholder_text and placeholder_text ~= "" then
            local text_size = imgui.CalcTextSize(placeholder_text)
            imgui.SetCursorPos(imgui.ImVec2(
                math.max(0, (width - text_size.x) * 0.5),
                math.max(0, (height - text_size.y) * 0.5)))
            imgui.TextDisabled(placeholder_text)
        end
    imgui.EndChild()
    imgui.PopStyleColor()
    return drew_image
end

local function _draw_thumbnail_panel(manifest)
    imgui.Separator()
    imgui.TextDisabled("切片画面：")
    local available_width = math.max(220, imgui.GetContentRegionAvail().x)
    local preview_width = math.min(480, available_width)
    local preview_height = math.floor(preview_width * 9 / 16 + 0.5)
    local thumbnail_path = _resolve_manifest_thumbnail_path(manifest)
    local texture = nil
    if thumbnail_path and SaveThumbnailCache.get_sdl_texture then
        local ok_texture, loaded_texture = pcall(SaveThumbnailCache.get_sdl_texture, thumbnail_path)
        if ok_texture then
            texture = loaded_texture
        end
    end

    local drew_thumbnail = false
    if texture then
        if _draw_sdl_texture_letterboxed("save_debugger_thumbnail", texture, preview_width, preview_height, nil) then
            drew_thumbnail = true
        elseif thumbnail_path then
            SaveThumbnailCache.release(thumbnail_path)
        end
    end

    if not drew_thumbnail then
        _draw_sdl_texture_letterboxed("save_debugger_thumbnail_placeholder", nil, preview_width, preview_height, "无切片画面")
    end
end

local function _draw_grid_thumbnail(entry, width, height)
    local thumbnail_path = type(entry) == "table" and _resolve_manifest_thumbnail_path(entry) or nil
    local texture = nil
    if thumbnail_path and SaveThumbnailCache.get_sdl_texture then
        local ok_texture, loaded_texture = pcall(SaveThumbnailCache.get_sdl_texture, thumbnail_path)
        if ok_texture then
            texture = loaded_texture
        end
    end

    if texture then
        if _draw_sdl_texture_letterboxed("thumb", texture, width, height, nil) then
            return
        elseif thumbnail_path then
            SaveThumbnailCache.release(thumbnail_path)
        end
    end

    _draw_sdl_texture_letterboxed("thumb_placeholder", nil, width, height, nil)
end

local function _draw_grid_card_text(text)
    if imgui.PushTextWrapPos then
        imgui.PushTextWrapPos(0)
    end
    imgui.TextWrapped(tostring(text or ""))
    if imgui.PopTextWrapPos then
        imgui.PopTextWrapPos()
    end
end

local function _draw_save_slot_grid_card(entry, card_size, selected, page, index)
    local is_empty = type(entry) ~= "table" or entry.empty == true
    local border_color = selected
        and imgui.ImColor(255, 217, 94, 255).value
        or imgui.ImColor(92, 112, 128, 225).value
    local background_color = is_empty
        and imgui.ImColor(18, 21, 26, 210).value
        or imgui.ImColor(32, 40, 48, 235).value
    local muted_color = imgui.ImColor(164, 176, 188, 255).value

    imgui.PushStyleColor(imgui.ImGuiCol.ChildBg, background_color)
    imgui.PushStyleColor(imgui.ImGuiCol.Border, border_color)
    imgui.PushStyleVar(imgui.StyleVar.ChildBorderSize, selected and 2 or 1)
    imgui.BeginChild(string.format("slot_grid_card_%s", tostring(entry and entry.slot_id or "empty")), card_size, imgui.ChildFlags.Borders)
        local style = imgui.GetStyle()
        local inner_width = math.max(1, imgui.GetContentRegionAvail().x)
        local inner_height = math.max(1, imgui.GetContentRegionAvail().y)
        local thumbnail_area_width = math.max(72, math.floor(inner_width * 0.34 + 0.5))
        local thumbnail_area_height = math.max(1, inner_height)
        local thumbnail_rect = SaveSlotGridModel.fit_16_9_rect(
        {
            x = 0,
            y = 0,
            w = thumbnail_area_width,
            h = thumbnail_area_height,
        }) or {w = thumbnail_area_width, h = math.max(1, math.floor(thumbnail_area_width * 9 / 16 + 0.5))}
        local thumbnail_width = math.max(1, thumbnail_rect.w)
        local thumbnail_height = math.max(1, thumbnail_rect.h)

        _draw_grid_thumbnail(entry, thumbnail_width, thumbnail_height)
        imgui.SameLine()
        imgui.BeginGroup()
            if is_empty then
                local empty_text = string.format("空存档%d-%d", tonumber(page) or 1, tonumber(index) or 1)
                local text_size = imgui.CalcTextSize(empty_text)
                local cursor = imgui.GetCursorPos()
                local available = imgui.GetContentRegionAvail()
                imgui.SetCursorPos(imgui.ImVec2(
                    cursor.x + math.max(0, (available.x - text_size.x) * 0.5),
                    cursor.y + math.max(0, (available.y - text_size.y) * 0.5)))
                imgui.TextDisabled(empty_text)
            else
                local view = SaveSlotGridModel.build_slot_view(entry, {page = page, index = index})

                imgui.Text(view.title)
                imgui.PushStyleColor(imgui.ImGuiCol.Text, muted_color)
                    _draw_grid_card_text(view.time_text)
                imgui.PopStyleColor()
            end
        imgui.EndGroup()

        if selected then
            imgui.SetCursorPos(imgui.ImVec2(style.WindowPadding.x, math.max(style.WindowPadding.y, inner_height - imgui.GetTextLineHeightWithSpacing())))
            imgui.TextColored(imgui.ImColor(255, 217, 94, 255).value, "当前选择")
        end
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)
end

local function _is_last_item_hovered_by_rect()
    if imgui.IsItemHovered and imgui.IsItemHovered() then
        return true
    end
    if not (imgui.GetItemRectMin and imgui.GetItemRectMax and imgui.GetMousePos) then
        return false
    end

    local item_min = imgui.GetItemRectMin()
    local item_max = imgui.GetItemRectMax()
    local mouse_pos = imgui.GetMousePos()
    if not item_min or not item_max or not mouse_pos then
        return false
    end
    return mouse_pos.x >= item_min.x
        and mouse_pos.x <= item_max.x
        and mouse_pos.y >= item_min.y
        and mouse_pos.y <= item_max.y
end

local function _draw_save_slot_grid_preview()
    imgui.Separator()
    imgui.TextDisabled("存档网格：")

    local panel_height = math.max(320, math.min(430, imgui.GetContentRegionAvail().y))
    imgui.BeginChild("save_debugger_slot_grid_preview", imgui.ImVec2(0, panel_height), imgui.ChildFlags.Borders)
        local total_pages = _get_slot_grid_total_pages()
        slot_grid_page = _clamp_slot_grid_page(slot_grid_page)

        local style = imgui.GetStyle()
        local spacing_x = style and style.ItemSpacing and style.ItemSpacing.x or 8
        local button_width = math.max(
            _get_button_width_for_text("前一页", 112, 24),
            _get_button_width_for_text("后一页", 112, 24))
        local row_start = imgui.GetCursorPos()
        local row_available_width = imgui.GetContentRegionAvail().x
        imgui.BeginDisabled(slot_grid_page <= 1)
            if imgui.Button("前一页##save_debugger_grid_prev", imgui.ImVec2(button_width, 0)) then
                slot_grid_page = _clamp_slot_grid_page(slot_grid_page - 1)
            end
        imgui.EndDisabled()

        local label = total_pages > 1
            and string.format("第 %d / %d 页", slot_grid_page, total_pages)
            or string.format("第 %d 页", slot_grid_page)
        local label_width = imgui.CalcTextSize(label).x
        local row_width = math.max(button_width * 2 + label_width + spacing_x * 2, row_available_width)
        local min_label_x = row_start.x + button_width + spacing_x
        local max_label_x = row_start.x + math.max(button_width + spacing_x, row_width - button_width - spacing_x - label_width)
        local label_x = row_start.x + (row_width - label_width) * 0.5
        label_x = math.max(min_label_x, math.min(label_x, max_label_x))
        imgui.SameLine()
        imgui.SetCursorPos(imgui.ImVec2(label_x, row_start.y))
        imgui.TextDisabled(label)

        local next_button_x = row_start.x + math.max(button_width + spacing_x, row_width - button_width)
        imgui.SetCursorPos(imgui.ImVec2(next_button_x, row_start.y))
        imgui.BeginDisabled(slot_grid_page >= total_pages)
            if imgui.Button("后一页##save_debugger_grid_next", imgui.ImVec2(button_width, 0)) then
                slot_grid_page = _clamp_slot_grid_page(slot_grid_page + 1)
            end
        imgui.EndDisabled()

        local slots_per_page = _get_slot_grid_slots_per_page()
        local ok, entries = pcall(SaveSlotGridModel.list_page, slot_grid_page, slots_per_page)
        entries = ok and type(entries) == "table" and entries or {}

        imgui.Separator()
        local style = imgui.GetStyle()
        local spacing_x = style.ItemSpacing and style.ItemSpacing.x or 8
        local spacing_y = style.ItemSpacing and style.ItemSpacing.y or 4
        local columns = math.min(2, slots_per_page)
        local rows = math.max(1, math.ceil(slots_per_page / columns))
        local available = imgui.GetContentRegionAvail()
        local card_width = math.max(180, math.floor((available.x - spacing_x * (columns - 1)) / columns + 0.5))
        local card_height = math.max(88, math.floor((available.y - spacing_y * (rows - 1)) / rows + 0.5))

        for index = 1, slots_per_page do
            local entry = entries[index] or
            {
                empty = true,
                slot_id = string.format("empty_%d", index),
                slot_display_name = string.format("第 %d 位", index),
            }
            local selected = selected_slot_id ~= nil and entry.slot_id == selected_slot_id
            imgui.PushID(string.format("save_debugger_grid_%d_%s", index, tostring(entry.slot_id or "")))
                _draw_save_slot_grid_card(entry, imgui.ImVec2(card_width, card_height), selected, slot_grid_page, index)
                if type(entry) == "table" and entry.empty ~= true and entry.slot_id ~= nil then
                    local hovered = _is_last_item_hovered_by_rect()
                    local double_clicked = hovered and imgui.IsMouseDoubleClicked and imgui.IsMouseDoubleClicked(0)
                    local clicked = double_clicked or (hovered and imgui.IsMouseReleased and imgui.IsMouseReleased(0))
                    if clicked then
                        selected_slot_id = entry.slot_id
                        _sync_slot_grid_to_slot(entry.slot_id)
                        if double_clicked then
                            local status = slot_status_cache[entry.slot_id]
                            if not status or status.valid == true then
                                _handle_locate_action(entry.slot_id)
                            else
                                _set_action_feedback("error", tostring(status.error or "当前存档无法定位"))
                            end
                        end
                    end
                    if hovered and imgui.IsMouseReleased(1) then
                        _open_slot_context_menu(entry.slot_id)
                    end
                end
            imgui.PopID()
            if index % columns ~= 0 then
                imgui.SameLine()
            end
        end
    imgui.EndChild()
end

local function _refresh_from_profile_change_if_needed(info)
    local active_profile_guid = tostring(info and info.profile_guid or "")
    local active_profile_signature = string.format("%s|%s|%s",
        active_profile_guid,
        tostring(info and info.root_path or ""),
        tostring(info and info.profile_load_error or ""))
    local should_refresh = false

    if observed_profile_guid ~= active_profile_guid then
        observed_profile_guid = active_profile_guid
        should_refresh = true
    end
    if observed_profile_signature ~= active_profile_signature then
        observed_profile_signature = active_profile_signature
        should_refresh = true
    end

    if should_refresh then
        _refresh_slot_list()
    end
    return should_refresh
end

function module.on_enter()
    module._ui_state_pool = {}
    _refresh_slot_list()
    local info = _safe_get_effective_storage_info()
    observed_profile_guid = tostring(info and info.profile_guid or "")
    observed_profile_signature = string.format("%s|%s|%s",
        observed_profile_guid,
        tostring(info and info.root_path or ""),
        tostring(info and info.profile_load_error or ""))
end

function module.on_exit()
    was_window_focused = false
end

function module.is_window_focused()
    return was_window_focused == true
end

function module.on_update(self, delta)
    local is_open = imgui.Begin("存档调试器")
    local previous_window_focused = was_window_focused == true
    was_window_focused = is_open and imgui.IsWindowFocused(imgui.FocusedFlags.RootAndChildWindows) or false
    local info = _safe_get_effective_storage_info()
    if is_open then
        _refresh_from_profile_change_if_needed(info)
        info = _safe_get_effective_storage_info()
    end
    if was_window_focused and not previous_window_focused then
        _refresh_slot_list()
    end
    if is_open then
        if imgui.Button("刷新", imgui.ImVec2(80, 0)) then
            local refresh_ok, refresh_err = _refresh_slot_list()
            local refreshed_info = _safe_get_effective_storage_info()
            local notice_kind, notice_text = _get_storage_notice(refreshed_info)
            if refresh_ok == false then
                _set_action_feedback("error", tostring(refresh_err or "存档列表刷新失败"))
            elseif notice_kind then
                _set_action_feedback(notice_kind, notice_text)
            else
                _set_action_feedback("info", "存档列表已刷新")
            end
        end
        imgui.SameLine()
        local open_directory_button_width = _get_button_width_for_text("打开目录", 128, 28)
        if imgui.Button("打开目录##save_debugger_open_directory", imgui.ImVec2(open_directory_button_width, 0)) then
            local call_ok, ok, err = pcall(SaveManager.open_save_directory)
            if not call_ok then
                local error_message = tostring(ok or "无法打开存档目录")
                ok = false
                err = error_message
            end
            if not ok then
                _set_action_feedback("error", tostring(err or "无法打开存档目录"))
            end
        end
        imgui.Separator()

        local manifest = _find_selected_manifest()
        local state = _find_selected_state()
        local slot_status = selected_slot_id and slot_status_cache[selected_slot_id] or nil
        local can_restore_selected = selected_slot_id ~= nil and (slot_status == nil or slot_status.valid == true)

        local table_flags = imgui.TableFlags.Resizable
            | imgui.TableFlags.SizingStretchProp
            | imgui.TableFlags.BordersInnerV
        if imgui.BeginTable("save_debugger_columns", 2, table_flags, imgui.ImVec2(0, 0)) then
            imgui.TableSetupColumn("存档列表", imgui.TableColumnFlags.WidthStretch, 0.28)
            imgui.TableSetupColumn("存档详情", imgui.TableColumnFlags.WidthStretch, 0.72)
            imgui.TableNextRow()

            imgui.TableSetColumnIndex(0)
            _draw_slot_list_panel(info)

            imgui.TableSetColumnIndex(1)
            imgui.BeginChild("save_debugger_structured", imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
                _draw_storage_notice(info)
                _draw_summary_panel(manifest, state, slot_status)
                imgui.Separator()
                imgui.BeginDisabled(not can_restore_selected)
                    if imgui.Button("定位", imgui.ImVec2(96, 0)) then
                        _handle_locate_action(selected_slot_id)
                    end
                    imgui.SameLine()
                    if imgui.Button("接管", imgui.ImVec2(96, 0)) then
                        _handle_take_over_action(selected_slot_id)
                    end
                imgui.EndDisabled()
                _draw_thumbnail_panel(manifest)
                _draw_save_slot_grid_preview()
            imgui.EndChild()
            imgui.EndTable()
        end
    end
    imgui.End()
end

return module

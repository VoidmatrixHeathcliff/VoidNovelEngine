local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

local EditorThemeManager = require("application.framework.editor_theme_manager")
local GlobalContext = require("application.framework.global_context")
local ImGUIHelper = require("application.framework.imgui_helper")
local ResourceReferenceField = require("application.framework.resource_reference_field")
local ResourcesManager = require("application.framework.resources_manager")
local SettingsManager = require("application.framework.settings_manager")

local window_size = {x = imgui.Int(0), y = imgui.Int(0)}
local save_custom_root = util.CString()
local fixed_save_subdirectory_name <const> = "save"
local project_guid_refresh_confirm_popup_id <const> = "重新生成项目标识##project_guid_refresh_confirm"

local idx_filter_mode = 1
local filter_mode_list = 
{
    {name = "临近采样", val = rl.TextureFilter.POINT},
    {name = "双线性过滤", val = rl.TextureFilter.BILINEAR},
    {name = "三线性过滤", val = rl.TextureFilter.TRILINEAR},
}

local idx_save_storage_mode = 1
local save_storage_mode_list =
{
    {name = "默认", val = "auto"},
    {name = "自定义", val = "custom"},
}

local canvas_size_preset_list =
{
    {name = "1080p 16:9", width = 1920, height = 1080},
    {name = "720p 16:9", width = 1280, height = 720},
    {name = "1080p 9:16", width = 1080, height = 1920},
    {name = "720p 9:16", width = 720, height = 1280},
    {name = "1080p 1:1", width = 1080, height = 1080},
    {name = "720p 1:1", width = 720, height = 720},
}

local function _refresh_save_storage_mode_index()
    local current_mode = SettingsManager.get("save_storage_mode")
    for index, item in ipairs(save_storage_mode_list) do
        if item.val == current_mode then
            idx_save_storage_mode = index
            return
        end
    end
    idx_save_storage_mode = 1
end

local function _refresh_save_storage_state()
    save_custom_root:set(SettingsManager.get("save_custom_root") or "")
    _refresh_save_storage_mode_index()
end

local function _get_save_storage_mode_tooltip()
    return string.format([[控制存档根目录的解析规则
    * 默认：当前目录下的 %s
    * 自定义：使用填写的目录]], fixed_save_subdirectory_name)
end

local function _normalize_path_part(path)
    if type(path) ~= "string" then
        return nil
    end
    local value = path:gsub("\\", "/"):match("^%s*(.-)%s*$")
    if value == "" then
        return nil
    end
    return value:gsub("/+$", "")
end

local function _join_display_path(...)
    local result = nil
    for index = 1, select("#", ...) do
        local part = _normalize_path_part(select(index, ...))
        if part then
            if result == nil or result == "" then
                result = part
            else
                result = string.format("%s/%s", result, part:gsub("^/+", ""))
            end
        end
    end
    return result or ""
end

local function _get_single_file_auto_save_path()
    local project_guid = SettingsManager.get("project_guid")
    if type(project_guid) ~= "string" or project_guid == "" then
        project_guid = "<内部项目标识>"
    end
    return _join_display_path(GlobalContext.get_pref_path(), "runtime", project_guid)
end

local function _get_default_save_path()
    local game_dir = rl.GetApplicationDirectory and rl.GetApplicationDirectory() or nil
    if type(game_dir) ~= "string" or game_dir == "" then
        game_dir = rl.GetWorkingDirectory and rl.GetWorkingDirectory() or nil
    end
    if type(game_dir) ~= "string" or game_dir == "" then
        return fixed_save_subdirectory_name
    end
    return _join_display_path(game_dir, fixed_save_subdirectory_name)
end

local function _draw_project_guid_refresh_confirm_popup()
    local popup_width <const> = 440
    local viewport = imgui.GetMainViewport()
    if viewport then
        imgui.SetNextWindowPos(
            imgui.ImVec2(viewport.WorkPos.x + viewport.WorkSize.x * 0.5, viewport.WorkPos.y + viewport.WorkSize.y * 0.5 + 40),
            imgui.ImGuiCond.Appearing,
            imgui.ImVec2(0.5, 0.5))
    end
    imgui.SetNextWindowSizeConstraints(imgui.ImVec2(popup_width, 0), imgui.ImVec2(popup_width, 10000))
    imgui.SetNextWindowSize(imgui.ImVec2(popup_width, 0), imgui.ImGuiCond.Appearing)

    if not imgui.BeginPopupModal(project_guid_refresh_confirm_popup_id, nil, imgui.WindowFlags.AlwaysAutoResize | imgui.WindowFlags.NoSavedSettings) then
        return
    end

    imgui.PushTextWrapPos(0)
    imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, "重新生成后会使用新的存档目录。")
    imgui.TextWrapped("旧目录不会删除，也不会自动迁移。确认继续？")
    imgui.PopTextWrapPos()
    imgui.Dummy(imgui.ImVec2(0, 6))

    local button_width <const> = 120
    local button_gap = imgui.GetStyle().ItemSpacing.x
    local button_row_width = button_width * 2 + button_gap
    local button_row_pos = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(
        button_row_pos.x + math.max(0, (imgui.GetContentRegionAvail().x - button_row_width) * 0.5),
        button_row_pos.y))

    if imgui.Button("重新生成", imgui.ImVec2(button_width, 0)) then
        SettingsManager.set("project_guid", util.NewGuidString())
        _refresh_save_storage_state()
        imgui.CloseCurrentPopup()
    end
    imgui.SameLine(0, button_gap)
    if imgui.Button("取消", imgui.ImVec2(button_width, 0)) then
        imgui.CloseCurrentPopup()
    end

    imgui.EndPopup()
end

local function _show_need_restart_msg()
    imgui.TextDisabled("* 需要重启以应用变更")
end

local function _set_canvas_size(width, height)
    local next_width = math.max(1, math.floor(tonumber(width) or window_size.x.val or 1920))
    local next_height = math.max(1, math.floor(tonumber(height) or window_size.y.val or 1080))
    window_size.x.val = next_width
    window_size.y.val = next_height
    SettingsManager.set("width_game_window", next_width)
    SettingsManager.set("height_game_window", next_height)
end

local function _get_canvas_size_preview_text()
    local width = tonumber(window_size.x.val) or SettingsManager.get("width_game_window") or 1920
    local height = tonumber(window_size.y.val) or SettingsManager.get("height_game_window") or 1080
    for _, preset in ipairs(canvas_size_preset_list) do
        if preset.width == width and preset.height == height then
            return preset.name
        end
    end
    return string.format("自定义  %d x %d", width, height)
end

local function _show_full_text_tooltip(text)
    if not imgui.IsItemHovered() then
        return
    end

    imgui.BeginTooltip()
        imgui.Text(tostring(text or ""))
    imgui.EndTooltip()
end

local function _draw_inline_icon_button(button_id, icon_name, tooltip, disabled)
    local clicked = false
    local icon_size = imgui.GetTextLineHeight()
    local icon = ResourcesManager.find_icon(icon_name)
    imgui.BeginDisabled(disabled == true or icon == nil)
        if icon then
            clicked = imgui.ImageButton(
                button_id,
                icon,
                imgui.ImVec2(icon_size, icon_size),
                nil,
                nil,
                nil,
                EditorThemeManager.get_icon_tint_color())
        else
            clicked = imgui.Button(string.format("##%s_missing", button_id), imgui.ImVec2(imgui.GetFrameHeight(), imgui.GetFrameHeight()))
        end
        ImGUIHelper.HoveredTooltip(tooltip)
    imgui.EndDisabled()
    return clicked
end

local function _draw_inline_text_with_actions(text, ellipsis_fn, button_list)
    local full_text = tostring(text or "")
    local buttons = button_list or {}
    local style = imgui.GetStyle()
    local available_width = imgui.GetContentRegionAvail().x
    local icon_size = imgui.GetTextLineHeight()
    local button_width = icon_size + style.FramePadding.x * 2
    local gap = style.ItemSpacing.x
    local reserved_width = 0
    if #buttons > 0 then
        reserved_width = #buttons * button_width + math.max(0, #buttons - 1) * gap + gap
    end
    local text_max_width = math.max(0, available_width - reserved_width)
    local display_text = full_text
    if text_max_width > 0 then
        display_text = (ellipsis_fn or ImGUIHelper.EllipsisMiddle)(full_text, text_max_width)
    elseif #buttons > 0 then
        display_text = ""
    end

    if display_text ~= "" then
        imgui.AlignTextToFramePadding()
        imgui.Text(display_text)
        if display_text ~= full_text then
            _show_full_text_tooltip(full_text)
        end
    else
        imgui.Dummy(imgui.ImVec2(0, imgui.GetFrameHeight()))
    end

    if #buttons > 0 then
        imgui.SameLine()
        for index, button in ipairs(buttons) do
            if index > 1 then
                imgui.SameLine()
            end
            if _draw_inline_icon_button(button.id, button.icon_name, button.tooltip, button.disabled) and button.on_click then
                button.on_click()
            end
        end
    end
end

module.on_enter = function()
    window_size.x.val = SettingsManager.get("width_game_window")
    window_size.y.val = SettingsManager.get("height_game_window")
    local filter_mode = SettingsManager.get("filter_mode")
    for idx, mode in ipairs(filter_mode_list) do
        if mode.val == filter_mode then
            idx_filter_mode = idx
            break
        end
    end
    _refresh_save_storage_state()
end

module.on_update = function(self, delta)
    local is_open = imgui.Begin("项目设置")
    if is_open then
        imgui.SeparatorText("基础")
        imgui.Columns(2, "基础")

        imgui.Text("画布尺寸")
        ImGUIHelper.HoveredTooltip("定义游戏渲染的基础分辨率，并作为游戏窗口的默认初始大小")
        imgui.NextColumn()
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
        imgui.InputInt2("##窗口尺寸", window_size.x, window_size.y)
        if imgui.IsItemDeactivatedAfterEdit() then
            _set_canvas_size(window_size.x.val, window_size.y.val)
        end
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
        if imgui.BeginCombo("##画布尺寸预设", _get_canvas_size_preview_text(), imgui.ComboFlags.HeightRegular) then
            for _, preset in ipairs(canvas_size_preset_list) do
                if imgui.Selectable(
                    preset.name,
                    preset.width == window_size.x.val and preset.height == window_size.y.val) then
                    _set_canvas_size(preset.width, preset.height)
                end
            end
            imgui.EndCombo()
        end
        _show_need_restart_msg()
        imgui.NextColumn()

        imgui.Columns(1)

        imgui.SeparatorText("渲染")
        imgui.Columns(2, "渲染")

        imgui.Text("采样模式")
        ImGUIHelper.HoveredTooltip([[控制纹理在缩放等情况下的像素插值策略，影响游戏画面的视觉质量和渲染性能
    * 临近采样：缩放时保持原始像素的锐利边缘和清晰轮廓，适合像素风格游戏，性能开销最低
    * 双线性过滤：放大时产生轻微模糊效果边缘更平滑，缩小时产生轻微锯齿感，性能开销中等
    * 三线性过滤：在缩放时表现更加平滑自然，提供最佳的视觉效果，性能开销较高]])
        imgui.NextColumn()
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
        if imgui.BeginCombo("##采样模式", filter_mode_list[idx_filter_mode].name) then
            for idx, mode in ipairs(filter_mode_list) do
                if imgui.Selectable(mode.name, idx_filter_mode == idx) then
                    idx_filter_mode = idx
                    SettingsManager.set("filter_mode", mode.val)
                end
            end
            imgui.EndCombo()
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            SettingsManager.set("width_game_window", window_size.x.val)
            SettingsManager.set("height_game_window", window_size.y.val)
        end
        _show_need_restart_msg()
        imgui.NextColumn()
        
        imgui.Columns(1)

        imgui.SeparatorText("存档")
        imgui.Columns(2, "存档")

        imgui.Text("存档位置模式")
        ImGUIHelper.HoveredTooltip(_get_save_storage_mode_tooltip())
        imgui.NextColumn()
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
        if imgui.BeginCombo("##save_storage_mode", save_storage_mode_list[idx_save_storage_mode].name) then
            for index, item in ipairs(save_storage_mode_list) do
                if imgui.Selectable(item.name, idx_save_storage_mode == index) then
                    idx_save_storage_mode = index
                    SettingsManager.set("save_storage_mode", item.val)
                    _refresh_save_storage_state()
                end
            end
            imgui.EndCombo()
        end
        imgui.NextColumn()

        if SettingsManager.get("save_storage_mode") == "custom" then
            imgui.Text("自定义目录")
        else
            imgui.TextDisabled("自定义目录")
        end
        ImGUIHelper.HoveredTooltip("仅在自定义模式下生效")
        imgui.NextColumn()
        imgui.BeginDisabled(SettingsManager.get("save_storage_mode") ~= "custom")
            imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
            imgui.InputText("##save_custom_root", save_custom_root)
            if imgui.IsItemDeactivatedAfterEdit() then
                SettingsManager.set("save_custom_root", save_custom_root:get())
                _refresh_save_storage_state()
            end
        imgui.EndDisabled()
        imgui.NextColumn()

        imgui.Text("存档配置资源")
        ImGUIHelper.HoveredTooltip("设置存档显示字段和自定义数据")
        imgui.NextColumn()
        local save_profile_ref, save_profile_changed = ResourceReferenceField.draw(
        {
            popup_id = "settings_save_profile_picker",
            asset_type = "save_profile",
            value = SettingsManager.get("save_profile_guid"),
            width = imgui.GetContentRegionAvail().x,
        })
        if save_profile_changed then
            SettingsManager.set("save_profile_guid", save_profile_ref and save_profile_ref.guid or "")
            _refresh_save_storage_state()
        end
        imgui.NextColumn()

        imgui.Text("默认存档位置")
        ImGUIHelper.HoveredTooltip("默认存档目录的完整路径")
        imgui.NextColumn()
        _draw_inline_text_with_actions(
            _get_default_save_path(),
            ImGUIHelper.EllipsisMiddle,
            {})
        imgui.NextColumn()

        imgui.Text("单文件发布存档位置")
        ImGUIHelper.HoveredTooltip("单文件发布时使用的存档目录")
        imgui.NextColumn()
        _draw_inline_text_with_actions(_get_single_file_auto_save_path(), ImGUIHelper.EllipsisMiddle,
        {
            {
                id = "single_file_save_path_refresh_project_guid",
                icon_name = "loop-right-fill",
                tooltip = "重新生成项目存档标识",
                on_click = function()
                    imgui.OpenPopup(project_guid_refresh_confirm_popup_id)
                end,
            },
            {
                id = "single_file_save_path_copy",
                icon_name = "file-copy-line",
                tooltip = "复制单文件发布存档目录",
                on_click = function()
                    sdl.SetClipboardText(_get_single_file_auto_save_path())
                end,
            },
        })
        imgui.NextColumn()

        imgui.Columns(1)
        _draw_project_guid_refresh_confirm_popup()
    end
    imgui.End()
end

return module

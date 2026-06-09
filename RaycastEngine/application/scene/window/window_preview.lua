local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local imgui = Engine.ImGUI

local ImGUIHelper = require("application.framework.imgui_helper")
local TextWrapper = require("application.framework.text_wrapper")
local ColorHelper = require("application.framework.color_helper")
local EditorPreviewInput = require("application.framework.editor_preview_input")
local EditorThemeManager = require("application.framework.editor_theme_manager")
local GlobalContext = require("application.framework.global_context")
local ScreenManager = require("application.framework.screen_manager")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")
local SnapshotCoordinator = require("application.framework.snapshot_coordinator")

local texture_preview = nil

local size_text = nil
local text_tip = "已切换至独立窗口预览，点击左上角按钮切换预览模式"

local text_obj_dummy = nil
local preview_copy_interval_idle <const> = 1 / 30
local preview_copy_interval_active <const> = 1 / 60
local last_preview_copy_time = -1

local function _make_rect(min_pos, max_pos)
    if not min_pos or not max_pos then
        return nil
    end

    return
    {
        x = min_pos.x,
        y = min_pos.y,
        w = math.max(0, max_pos.x - min_pos.x),
        h = math.max(0, max_pos.y - min_pos.y),
    }
end

local function _draw_border(draw_list, rect, color, thickness)
    if not draw_list or not rect or rect.w <= 0 or rect.h <= 0 then
        return
    end

    local line_thickness = math.max(1, thickness or 1)
    draw_list:AddRectFilled(
        imgui.ImVec2(rect.x, rect.y),
        imgui.ImVec2(rect.x + rect.w, rect.y + line_thickness),
        imgui.ImColor(color):to_u32())
    draw_list:AddRectFilled(
        imgui.ImVec2(rect.x, rect.y + rect.h - line_thickness),
        imgui.ImVec2(rect.x + rect.w, rect.y + rect.h),
        imgui.ImColor(color):to_u32())
    draw_list:AddRectFilled(
        imgui.ImVec2(rect.x, rect.y + line_thickness),
        imgui.ImVec2(rect.x + line_thickness, rect.y + rect.h - line_thickness),
        imgui.ImColor(color):to_u32())
    draw_list:AddRectFilled(
        imgui.ImVec2(rect.x + rect.w - line_thickness, rect.y + line_thickness),
        imgui.ImVec2(rect.x + rect.w, rect.y + rect.h - line_thickness),
        imgui.ImColor(color):to_u32())
end

local function _draw_preview_focus_visual(image_rect, editor_zoom_ratio)
    if not image_rect or image_rect.w <= 0 or image_rect.h <= 0 then
        return
    end

    local draw_list = imgui.GetWindowDrawList()
    local accent = EditorThemeManager.get_token("accent_primary") or imgui.ImVec4(imgui.ImColor(88, 156, 255, 255).value)
    local is_focused = EditorPreviewInput.is_preview_focused()
    local is_hovered = EditorPreviewInput.is_preview_hovered()
    if not is_hovered and not is_focused then
        return
    end

    local border_alpha = is_focused and 0.92 or 0.48
    local border_thickness = math.max(2, math.floor((is_focused and 3 or 2) * editor_zoom_ratio + 0.5))
    local border_color = EditorThemeManager.with_alpha(accent, border_alpha)

    _draw_border(draw_list, image_rect, border_color, border_thickness)

    local badge_text = is_focused and "运行时输入已接管" or "点击以接管输入"
    local badge_padding_x = math.max(8, math.floor(10 * editor_zoom_ratio + 0.5))
    local badge_padding_y = math.max(4, math.floor(6 * editor_zoom_ratio + 0.5))
    local badge_text_size = imgui.CalcTextSize(badge_text)
    local badge_w = badge_text_size.x + badge_padding_x * 2
    local badge_h = badge_text_size.y + badge_padding_y * 2
    local badge_margin = math.max(10, math.floor(12 * editor_zoom_ratio + 0.5))
    local badge_rect =
    {
        x = math.max(image_rect.x + badge_margin, image_rect.x + image_rect.w - badge_w - badge_margin),
        y = image_rect.y + badge_margin,
        w = badge_w,
        h = badge_h,
    }
    local badge_bg = EditorThemeManager.with_alpha(
        EditorThemeManager.get_token("bg_2") or imgui.ImVec4(imgui.ImColor(28, 30, 34, 255).value),
        is_focused and 0.92 or 0.82)
    local badge_text_color = EditorThemeManager.get_text_on_color(badge_bg)

    draw_list:AddRectFilled(
        imgui.ImVec2(badge_rect.x, badge_rect.y),
        imgui.ImVec2(badge_rect.x + badge_rect.w, badge_rect.y + badge_rect.h),
        imgui.ImColor(badge_bg):to_u32(),
        badge_rect.h * 0.5)
    draw_list:AddText(
        imgui.ImVec2(badge_rect.x + badge_padding_x, badge_rect.y + badge_padding_y),
        imgui.ImColor(badge_text_color):to_u32(),
        badge_text)
end

local function _draw_save_status_inline()
    local text = "未运行"
    local tooltip = "调试时显示存档状态"
    local bg_color = imgui.ImColor(52, 56, 64, 220).value
    local text_color = imgui.ImColor(190, 198, 208, 255).value

    if GlobalContext.is_debug_game ~= true then
    else
        local ok_status, status = pcall(SnapshotCoordinator.get_save_availability,
        {
            source = "runtime",
        })
        if not ok_status then
            status = nil
        end
        local available = status and status.available == true
        text = available and "可存档" or "不可存档"
        tooltip = available and "当前可存档" or "当前不可存档"
        bg_color = available
            and imgui.ImColor(33, 82, 51, 230).value
            or imgui.ImColor(98, 67, 24, 230).value
        text_color = available
            and imgui.ImColor(207, 244, 216, 255).value
            or imgui.ImColor(255, 228, 177, 255).value
    end

    local scale = tonumber(SettingsManager.get("editor_zoom_ratio")) or 1
    local padding_x = math.max(8, math.floor(10 * scale + 0.5))
    local padding_y = math.max(3, math.floor(4 * scale + 0.5))
    local text_size = imgui.CalcTextSize(text)
    local pos = imgui.GetCursorScreenPos()
    local width = text_size.x + padding_x * 2
    local height = text_size.y + padding_y * 2
    local draw_list = imgui.GetWindowDrawList()
    draw_list:AddRectFilled(
        pos,
        imgui.ImVec2(pos.x + width, pos.y + height),
        imgui.ImColor(bg_color):to_u32(),
        height * 0.5)
    draw_list:AddText(
        imgui.ImVec2(pos.x + padding_x, pos.y + padding_y),
        imgui.ImColor(text_color):to_u32(),
        text)
    imgui.Dummy(imgui.ImVec2(width, height))
    ImGUIHelper.HoveredTooltip(tooltip)
    return _make_rect(imgui.GetItemRectMin(), imgui.GetItemRectMax())
end

module.on_enter = function()
    if texture_preview then
        sdl.DestroyTexture(texture_preview)
    end
    if text_obj_dummy and text_obj_dummy.dispose then
        text_obj_dummy:dispose()
    end
    texture_preview = sdl.CreateTexture(GlobalContext.renderer, sdl.PixelFormat.ABGR8888,
        sdl.TextureAccess.STREAMING, GlobalContext.width_game_window, GlobalContext.height_game_window)
    sdl.SetTextureScaleMode(texture_preview, sdl.ScaleMode.BEST)
    size_text = imgui.CalcTextSize(text_tip)
    text_obj_dummy = TextWrapper.new(GlobalContext.font_wrapper_sdl, "启动调试以预览画面内容", sdl.Color(200, 200, 200, 255), nil, 75)
    last_preview_copy_time = -1
end

module.on_exit = function()
    if texture_preview then
        sdl.DestroyTexture(texture_preview)
        texture_preview = nil
    end
    if text_obj_dummy and text_obj_dummy.dispose then
        text_obj_dummy:dispose()
        text_obj_dummy = nil
    end
end

local function _sync_preview_texture(force_sync)
    if not texture_preview then
        return
    end

    local preview_copy_interval = EditorPreviewInput.is_preview_interaction_active()
        and preview_copy_interval_active
        or preview_copy_interval_idle
    local now = rl.GetTime()
    if not force_sync and last_preview_copy_time >= 0 and (now - last_preview_copy_time) < preview_copy_interval then
        return
    end

    local source_texture = ScreenManager.get_texture and ScreenManager.get_texture() or nil
    if not source_texture then
        return
    end
    if rl.IsTextureValid then
        local ok_valid, is_valid = pcall(rl.IsTextureValid, source_texture)
        if not ok_valid or is_valid ~= true then
            return
        end
    end

    local ok_image, image = pcall(rl.LoadImageFromTexture, source_texture)
    if not ok_image or not image then
        return
    end
    if rl.IsImageValid then
        local ok_valid_image, is_valid_image = pcall(rl.IsImageValid, image)
        if not ok_valid_image or is_valid_image ~= true then
            if image and rl.UnloadImage then
                pcall(rl.UnloadImage, image)
            end
            return
        end
    end

    if image.format ~= rl.PixelFormat.UNCOMPRESSED_R8G8B8A8 then
        local ok_format = pcall(rl.ImageFormat, image, rl.PixelFormat.UNCOMPRESSED_R8G8B8A8)
        if not ok_format then
            pcall(rl.UnloadImage, image)
            return
        end
    end

    local source_pitch = math.max(1, math.floor((tonumber(image.width) or GlobalContext.width_game_window) * 4))
    local ok_update, update_result = pcall(sdl.UpdateTexture, texture_preview, nil, image.data, source_pitch)
    if ok_update and update_result == 0 then
        last_preview_copy_time = now
    end
    pcall(rl.UnloadImage, image)
end

module.on_update = function(self, delta)
    local is_open = imgui.Begin("预览视图")
    if is_open then
        local pos_begin = imgui.GetCursorPos()
        local size_content = imgui.GetContentRegionAvail()
        local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
        local image_rect = nil
        local blocked_rect_list = {}
        local show_editor_preview = GlobalContext.is_preview_in_editor == true
        if show_editor_preview then
            _sync_preview_texture(false)
        end
        if show_editor_preview and texture_preview then
            local scale = math.min(size_content.x / GlobalContext.width_game_window, size_content.y / GlobalContext.height_game_window)
            local size_image = imgui.ImVec2(GlobalContext.width_game_window * scale, GlobalContext.height_game_window * scale)
            imgui.SetCursorPos(imgui.ImVec2(pos_begin.x + (size_content.x - size_image.x) / 2, pos_begin.y + (size_content.y - size_image.y) / 2))
            imgui.Image(texture_preview, size_image, imgui.ImVec2(0, 1), imgui.ImVec2(1, 0), nil, nil)
            image_rect = _make_rect(imgui.GetItemRectMin(), imgui.GetItemRectMax())
        else
            imgui.SetCursorPos(imgui.ImVec2((size_content.x - size_text.x) / 2, (size_content.y - size_text.y) / 2))
            imgui.TextDisabled(text_tip)
        end
        imgui.SetCursorPos(imgui.ImVec2(pos_begin.x + 10, pos_begin.y + 10))
        local id_icon = "file-copy-line" if not GlobalContext.is_preview_in_editor then id_icon = "file-copy-fill" end
        if imgui.ImageButton("preview_in_editor", ResourcesManager.find_icon(id_icon),
            imgui.ImVec2(20 * editor_zoom_ratio, 20 * editor_zoom_ratio), nil, nil, nil, EditorThemeManager.get_icon_tint_color()) then
            GlobalContext.toggle_preview_mode()
            if GlobalContext.is_preview_in_editor then
                _sync_preview_texture(true)
            end
        end
        blocked_rect_list[#blocked_rect_list + 1] = _make_rect(imgui.GetItemRectMin(), imgui.GetItemRectMax())
        local text_on_hovered = "切换为独立窗口预览"
        if not GlobalContext.is_preview_in_editor then text_on_hovered = "切换为编辑器内预览" end
        ImGUIHelper.HoveredTooltip(text_on_hovered)
        imgui.SameLine()
        local status_rect = _draw_save_status_inline()
        if status_rect then
            blocked_rect_list[#blocked_rect_list + 1] = status_rect
        end

        EditorPreviewInput.register_host(
        {
            window_focused = imgui.IsWindowFocused(imgui.FocusedFlags.RootAndChildWindows),
            window_hovered = imgui.IsWindowHovered(imgui.HoveredFlags.RootAndChildWindows | imgui.HoveredFlags.AllowWhenBlockedByActiveItem),
            image_rect = image_rect,
            blocked_rect_list = blocked_rect_list,
            game_width = GlobalContext.width_game_window,
            game_height = GlobalContext.height_game_window,
        })

        if GlobalContext.is_preview_in_editor then
            _draw_preview_focus_visual(image_rect, editor_zoom_ratio)
        end
    end
    imgui.End()
end

module.on_render = function()
    if not GlobalContext.is_debug_game then
        local position = rl.Vector2(GlobalContext.width_game_window / 2 - text_obj_dummy.w / 2,
            GlobalContext.height_game_window / 2 - text_obj_dummy.h / 2)
        rl.DrawTextureV(text_obj_dummy.texture, position, ColorHelper.WHITE)
        return
    end
end

return module

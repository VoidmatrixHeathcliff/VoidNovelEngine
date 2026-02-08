local module = {}

local sdl = Engine.SDL
local ut = Engine.Util
local rl = Engine.Raylib
local imgui = Engine.ImGUI

local ImGUIHelper = require("application.framework.imgui_helper")
local TextWrapper = require("application.framework.text_wrapper")
local ColorHelper = require("application.framework.color_helper")
local GlobalContext = require("application.framework.global_context")
local ScreenManager = require("application.framework.screen_manager")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")

local texture_preview = nil

local size_text = nil
local text_tip = "已切换至独立窗口预览，点击左上角按钮切换预览模式"

local text_obj_dummy = nil

module.on_enter = function()
    texture_preview = sdl.CreateTexture(GlobalContext.renderer, sdl.PixelFormat.ABGR8888, 
        sdl.TextureAccess.STREAMING, GlobalContext.width_game_window, GlobalContext.height_game_window)
    sdl.SetTextureScaleMode(texture_preview, sdl.ScaleMode.BEST)
    size_text = imgui.CalcTextSize(text_tip)
    text_obj_dummy = TextWrapper.new(GlobalContext.font_wrapper_sdl:get(75), "启动调试以预览画面内容", sdl.Color(200, 200, 200, 255))
end

module.on_update = function(self, delta)
    if GlobalContext.is_preview_in_editor then
        -- 从Raylib渲染缓冲拷贝内容到SDL纹理
        local image = rl.LoadImageFromTexture(ScreenManager.get_texture())
        local result = sdl.LockResult()
        sdl.LockTexture(texture_preview, result)
        ut.Memcpy(result.data, image.data, result.pitch * GlobalContext.height_game_window)
        sdl.UnlockTexture(texture_preview)
        rl.UnloadImage(image)
    end

    imgui.Begin("预览视图")
        local pos_begin = imgui.GetCursorPos()
        local size_content = imgui.GetContentRegionAvail()
        local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
        if GlobalContext.is_preview_in_editor then
            local scale = math.min(size_content.x / GlobalContext.width_game_window, size_content.y / GlobalContext.height_game_window)
            local size_image = imgui.ImVec2(GlobalContext.width_game_window * scale, GlobalContext.height_game_window * scale)
            imgui.SetCursorPos(imgui.ImVec2(pos_begin.x + (size_content.x - size_image.x) / 2, pos_begin.y + (size_content.y - size_image.y) / 2))
            imgui.Image(texture_preview, size_image, imgui.ImVec2(0, 1), imgui.ImVec2(1, 0), nil, nil)    -- Y轴翻转
        else
            imgui.SetCursorPos(imgui.ImVec2((size_content.x - size_text.x) / 2, (size_content.y - size_text.y) / 2))
            imgui.TextDisabled(text_tip)
        end
        imgui.SetCursorPos(imgui.ImVec2(pos_begin.x + 10, pos_begin.y + 10))
        local id_icon = "file-copy-line" if not GlobalContext.is_preview_in_editor then id_icon = "file-copy-fill" end
        if imgui.ImageButton("preview_in_editor", ResourcesManager.find_icon(id_icon), 
            imgui.ImVec2(20 * editor_zoom_ratio, 20 * editor_zoom_ratio), nil, nil, nil, nil) then
            GlobalContext.toggle_preview_mode()
        end
        local text_on_hovered = "切换为独立窗口预览"
        if not GlobalContext.is_preview_in_editor then text_on_hovered = "切换为编辑器内预览" end
        ImGUIHelper.HoveredTooltip(text_on_hovered)
        imgui.SameLine()
        imgui.BeginDisabled(not GlobalContext.is_debug_game)
            if imgui.ImageButton("simulate_interaction", ResourcesManager.find_icon("hand"), 
                imgui.ImVec2(20 * editor_zoom_ratio, 20 * editor_zoom_ratio), nil, nil, nil, nil) then
                GlobalContext.is_simulated_interaction = true
            end
            ImGUIHelper.HoveredTooltip("点击模拟互动")
        imgui.EndDisabled()
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
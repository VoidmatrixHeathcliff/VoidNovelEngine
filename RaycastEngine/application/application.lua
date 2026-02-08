local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

require("application.framework.math_ext")
local LogManager = require("application.framework.log_manager")
local FlowManager = require("application.framework.flow_manager")
local FontWrapper = require("application.framework.font_wrapper")
local ColorHelper = require("application.framework.color_helper")
local SceneManager = require("application.framework.scene_manager")
local ScreenManager = require("application.framework.screen_manager")
local GlobalContext = require("application.framework.global_context")
local ModifyManager = require("application.framework.modify_manager")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")

local SceneEditor = require("application.scene.scene_editor")
local SceneReleased = require("application.scene.scene_released")

local event = sdl.Event()

local function _check_feature(exe_path, feature)
    if not rl.FileExists(exe_path) then 
        LogManager.log(string.format("无法定位工具：%s，%s功能可能无法正常使用", exe_path, feature), "warning")
    end
end

local function _check_document_unsaved()
    local unsaved_document_list = {}
    for _, blueprint in ipairs(GlobalContext.blueprint_list) do
        ModifyManager.set_context(blueprint._modify_context)
        if ModifyManager.is_modify() then
            table.insert(unsaved_document_list, blueprint)
        end
        ModifyManager.set_context()
    end
    if #unsaved_document_list == 0 then return end
    local str_list = "\n"
    for _, blueprint in ipairs(unsaved_document_list) do
        str_list = str_list.."\n    •  "..blueprint._id
    end
    local msg = "如下文档修改后未保存："..str_list.."\n\n是否需要保存？"
    if sdl.ShowConfirmBox(sdl.MessageBoxFlags.WARNING, "未保存", msg, GlobalContext.window, "保存后退出", "放弃修改") then
        for _, blueprint in ipairs(unsaved_document_list) do
            blueprint:save_document()
        end
    end
end

module.init = function()
    os.execute("chcp 65001")
    SettingsManager.load()
    local is_release_mode = SettingsManager.get("release_mode")
    GlobalContext.width_game_window = SettingsManager.get("width_game_window")
    GlobalContext.height_game_window = SettingsManager.get("height_game_window")
    if not GlobalContext.debug or is_release_mode then util.SetConsoleShown(false) end
    rl.SetConfigFlags(rl.ConfigFlags.VSYNC_HINT | rl.ConfigFlags.WINDOW_RESIZABLE)
    rl.SetTraceLogLevel(rl.TraceLogLevel.ERROR)
    
    assert(sdl.Init(sdl.SubSystem.EVERYTHING) == 0, sdl.GetError())
    assert(sdl.InitIMG(sdl.IMGInitFlags.JPG | sdl.IMGInitFlags.PNG 
        | sdl.IMGInitFlags.TIF | sdl.IMGInitFlags.WEBP | sdl.IMGInitFlags.AVIF) ~= 0, sdl.GetError())
    assert(sdl.InitMIX(sdl.MIXInitFlags.FLAC | sdl.MIXInitFlags.MOD | sdl.MIXInitFlags.MP3 
        | sdl.MIXInitFlags.OGG | sdl.MIXInitFlags.MID | sdl.MIXInitFlags.OPUS | sdl.MIXInitFlags.WAVPACK) ~= 0, sdl.GetError())
    assert(sdl.InitTTF() == 0, sdl.GetError())
    assert(sdl.InitNET() == 0, sdl.GetError())

    sdl.SetHint("SDL_IME_SHOW_UI", "1")

    local size_window_default = {w = 1920, h = 1080}
    local mode = sdl.GetDesktopDisplayMode(0)
    if mode.w < 1536 then
        size_window_default.w, size_window_default.h = 640, 360
    elseif mode.w < 2048 then
        size_window_default.w, size_window_default.h = 1280, 720
    end

    rl.InitWindow(GlobalContext.width_game_window, GlobalContext.height_game_window, SettingsManager.get("title"))
    local img_icon = rl.LoadImage(SettingsManager.get("icon_path"))
    rl.SetWindowIcon(img_icon) rl.UnloadImage(img_icon)
    if is_release_mode then
        rl.SetWindowState(rl.ConfigFlags.WINDOW_ALWAYS_RUN)
        if SettingsManager.get("default_fullscreen") then
            rl.ToggleBorderlessWindowed()
        end
    else
        rl.SetWindowState(rl.ConfigFlags.WINDOW_HIDDEN | rl.ConfigFlags.WINDOW_ALWAYS_RUN)
    end

    if not is_release_mode then
        GlobalContext.window = sdl.CreateWindow(string.format("VoidNovelEngine - %s", GlobalContext.version), 
            sdl.WindowPosition.CENTERED, sdl.WindowPosition.CENTERED, size_window_default.w, size_window_default.h, sdl.WindowFlags.RESIZABLE)
        GlobalContext.renderer = sdl.CreateRenderer(GlobalContext.window, -1, sdl.RendererFlags.ACCELERATED)

        imgui.sdlImGuiSetup(GlobalContext.window, GlobalContext.renderer)

        local path_sys_font <const> = "C:\\Windows\\Fonts\\msyh.ttc"
        GlobalContext.font_wrapper_sdl = FontWrapper.new(path_sys_font)
        GlobalContext.font_imgui = imgui.AddFontFromFileTTF(path_sys_font)
        imgui.GetIO().ConfigFlags = imgui.GetIO().ConfigFlags | imgui.ConfigFlags.DockingEnable

        local style = imgui.GetStyle()
        style.WindowRounding, style.TabBorderSize = 4, 1
        style.FrameRounding, style.FrameBorderSize = 4, 1
        style.PopupRounding = 4
    end

    ScreenManager.init(GlobalContext.width_game_window, GlobalContext.height_game_window)

    assert(sdl.OpenAudio(44100, sdl.AudioFormat.DEFAULT, 2, 2048) == 0, sdl.GetError())

    if not is_release_mode then
        local essential_path_list = 
        {
            "application/resources",
            "application/flow",
            "application/style",
            "application/ui",
        }
        for _, path in ipairs(essential_path_list) do
            if not rl.DirectoryExists(path) then
                rl.MakeDirectory(path)
            end
        end
        _check_feature("application/external/luac54.exe", "脚本编译")
        _check_feature("application/external/rcedit.exe", "发布程序图标和元信息生成")
        _check_feature("application/external/ffmpeg.exe", "视频播放")
        _check_feature("application/external/ImageMagick/magick.exe", "发布程序图标生成")
        _check_feature("application/external/EnigmaVirtualBox/enigmavb.exe", "单文件发布")
        _check_feature("application/external/EnigmaVirtualBox/enigmavbconsole.exe", "单文件发布")
    end

    ResourcesManager.load()
    FlowManager.load()

    rl.SetTargetFPS(144)

    if is_release_mode then
        SceneManager.add_scene(SceneReleased.new(), "main_scene")
    else
        SceneManager.add_scene(SceneEditor.new(), "main_scene")
    end
    SceneManager.switch_to("main_scene")

    return module
end

module.run = function()
    local is_quit = false
    local is_release_mode = SettingsManager.get("release_mode")

    while not is_quit do
        if rl.WindowShouldClose() then
            if is_release_mode then
                is_quit = true
            else
                GlobalContext.toggle_preview_mode()
            end
        end
        if rl.IsKeyPressed(rl.KeyboardKey.F11) then
            rl.ToggleBorderlessWindowed()
        end
        if not is_release_mode then
            while sdl.PollEvent(event) == 1 do
                imgui.sdlImGuiProcessEvent(event)
                if event.type == sdl.EventType.QUIT then
                    _check_document_unsaved()
                    is_quit = true
                end
            end
        end

        rl.BeginDrawing()
        if not is_release_mode then
            imgui.sdlImGuiBegin()
            imgui.PushFont(GlobalContext.font_imgui, math.floor(18 * SettingsManager.get("editor_zoom_ratio")))
        end

        ScreenManager.on_update()
        local delta = rl.GetFrameTime()
        if delta < 0.3 then SceneManager.on_update(delta) end

        ScreenManager.begin_render()
        SceneManager.on_render()
        ScreenManager.end_render()
        
        rl.ClearBackground(ColorHelper.BLACK)
        if not is_release_mode then sdl.RenderClear(GlobalContext.renderer) end
        ScreenManager.on_render()

        if not is_release_mode then
            imgui.PopFont()
            imgui.sdlImGuiEnd(GlobalContext.renderer)
            sdl.RenderPresent(GlobalContext.renderer)
        end
        rl.EndDrawing()
    end
    rl.CloseWindow()
    GlobalContext.stop_debug()
    if not is_release_mode then
        sdl.DestroyRenderer(GlobalContext.renderer)
        sdl.DestroyWindow(GlobalContext.window)
    end
end

return module
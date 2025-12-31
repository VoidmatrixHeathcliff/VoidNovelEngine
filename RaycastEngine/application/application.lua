local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

require("application.framework.math_ext")
local FontWrapper = require("application.framework.font_wrapper")
local ColorHelper = require("application.framework.color_helper")
local SceneManager = require("application.framework.scene_manager")
local ScreenManager = require("application.framework.screen_manager")
local GlobalContext = require("application.framework.global_context")
local ModifyManager = require("application.framework.modify_manager")
local ResourcesManager = require("application.framework.resources_manager")

local SceneEditor = require("application.scene.scene_editor")

local event = sdl.Event()

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
    if not GlobalContext.debug then util.SetConsoleShown(false) end
    rl.SetConfigFlags(rl.ConfigFlags.VSYNC_HINT | rl.ConfigFlags.WINDOW_RESIZABLE)
    rl.SetTraceLogLevel(rl.TraceLogLevel.ERROR)

    rl.InitWindow(GlobalContext.width_game_window, GlobalContext.height_game_window, "VoidNovelEngine - Debug Window")
    rl.SetWindowState(rl.ConfigFlags.WINDOW_HIDDEN | rl.ConfigFlags.WINDOW_ALWAYS_RUN)

    assert(sdl.Init(sdl.SubSystem.EVERYTHING) == 0, sdl.GetError())
    assert(sdl.InitIMG(sdl.IMGInitFlags.JPG | sdl.IMGInitFlags.PNG | sdl.IMGInitFlags.TIF 
        | sdl.IMGInitFlags.WEBP | sdl.IMGInitFlags.JXL | sdl.IMGInitFlags.AVIF) ~= 0, sdl.GetError())
    assert(sdl.InitMIX(sdl.MIXInitFlags.FLAC | sdl.MIXInitFlags.MOD | sdl.MIXInitFlags.MP3 
        | sdl.MIXInitFlags.OGG | sdl.MIXInitFlags.MID | sdl.MIXInitFlags.OPUS | sdl.MIXInitFlags.WAVPACK) ~= 0, sdl.GetError())
    assert(sdl.InitTTF() == 0, sdl.GetError())
    assert(sdl.InitNET() == 0, sdl.GetError())

    sdl.SetHint("SDL_IME_SHOW_UI", "1")

    GlobalContext.window = sdl.CreateWindow("VoidNovelEngine", sdl.WindowPosition.CENTERED, sdl.WindowPosition.CENTERED, 1920, 1080, sdl.WindowFlags.RESIZABLE)
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

    ScreenManager.init(GlobalContext.width_game_window, GlobalContext.height_game_window)

    assert(sdl.OpenAudio(44100, sdl.AudioFormat.DEFAULT, 2, 2048) == 0, sdl.GetError())

    local essential_path_list = 
    {
        "application/resources",
        "application/blueprint",
    }
    for _, path in ipairs(essential_path_list) do
        if not rl.DirectoryExists(path) then
            rl.MakeDirectory(path)
        end
    end

    ResourcesManager.load()

    rl.SetTargetFPS(144)

    SceneManager.add_scene(SceneEditor.new(), "editor")
    SceneManager.switch_to("editor")

    return module
end

module.run = function()
    local is_quit = false
    while not is_quit do
        if rl.WindowShouldClose() then
            GlobalContext.toggle_preview_mode()
        end
        if rl.IsKeyPressed(rl.KeyboardKey.F11) then
            rl.ToggleBorderlessWindowed()
        end

        while sdl.PollEvent(event) == 1 do
            imgui.sdlImGuiProcessEvent(event)
            if event.type == sdl.EventType.QUIT then
                _check_document_unsaved()
                is_quit = true
            end
        end

        rl.BeginDrawing()
        imgui.sdlImGuiBegin()
        imgui.PushFont(GlobalContext.font_imgui, 18)

        ScreenManager.on_update()
        local delta = rl.GetFrameTime()
        if delta < 0.3 then SceneManager.on_update(delta) end

        ScreenManager.begin_render()
        SceneManager.on_render()
        ScreenManager.end_render()
        
        rl.ClearBackground(ColorHelper.BLACK)
        sdl.RenderClear(GlobalContext.renderer)
        ScreenManager.on_render()

        imgui.PopFont()
        imgui.sdlImGuiEnd(GlobalContext.renderer)
        sdl.RenderPresent(GlobalContext.renderer)
        rl.EndDrawing()
    end
    rl.CloseWindow()
    GlobalContext.stop_debug()
    sdl.DestroyRenderer(GlobalContext.renderer)
    sdl.DestroyWindow(GlobalContext.window)
end

return module
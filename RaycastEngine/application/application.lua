local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

require("application.framework.math_ext")
local AudioPlaybackManager = require("application.framework.audio_playback_manager")
local LogManager = require("application.framework.log_manager")
local FlowManager = require("application.framework.flow_manager")
local DefinitionLoader = require("application.framework.definition_loader")
local FontWrapper = require("application.framework.font_wrapper")
local ColorHelper = require("application.framework.color_helper")
local SceneManager = require("application.framework.scene_manager")
local ScreenManager = require("application.framework.screen_manager")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")
local ResourceIndex = require("application.framework.resource_index")
local ResourceHotReload = require("application.framework.resource_hot_reload")
local VideoPlaybackManager = require("application.framework.video_playback_manager")
local VideoImporter = require("application.framework.video_importer")
local NativeIO = require("application.framework.native_io")
local SaveLoadResultToast = require("application.framework.save_load_result_toast")
local SaveThumbnailCache = require("application.framework.save_thumbnail_cache")

local SceneBootstrapLoading = require("application.scene.scene_bootstrap_loading")
local SceneReleased = require("application.scene.scene_released")

local event = sdl.Event()
local path_sys_font <const> = "C:\\Windows\\Fonts\\msyh.ttc"
local path_sys_code_font <const> = "C:\\Windows\\Fonts\\simsun.ttc"
local path_sys_story_editor_font <const> = "C:\\Windows\\Fonts\\consola.ttf"
local path_sys_code_font_no <const> = 1
local story_editor_cjk_glyph_offset_y <const> = 2.0
local default_window_icon_path <const> = "application/resources/texture/icon.png"
local save_manager_module = false
local editor_preview_input_module = false
local modify_manager_module = false
local editor_theme_manager_module = false
local style_workspace_manager_module = false
local ui_workspace_manager_module = false
local scene_editor_module = false
local release_imgui_ini_cleanup_elapsed = 0
local lua_gc_configured = false
local next_lua_gc_step_time = 0
local lua_gc_step_interval_seconds <const> = 0.5

local function _configure_lua_gc()
    if lua_gc_configured then
        return
    end
    lua_gc_configured = true
    if type(collectgarbage) == "function" then
        pcall(collectgarbage, "generational")
    end
end

local function _step_lua_gc()
    if type(collectgarbage) ~= "function" then
        return
    end
    local now_time = rl.GetTime()
    if now_time < next_lua_gc_step_time then
        return
    end
    next_lua_gc_step_time = now_time + lua_gc_step_interval_seconds
    pcall(collectgarbage, "step", 128)
end

local function _get_editor_window_flags()
    if SettingsManager.get("release_mode")
        or not GlobalContext.window
        or type(sdl.GetWindowFlags) ~= "function" then
        return 0
    end

    local ok, flags = pcall(sdl.GetWindowFlags, GlobalContext.window)
    if not ok or type(flags) ~= "number" then
        return 0
    end
    return flags
end

local function _is_editor_window_minimized()
    local minimized_flag = sdl.WindowFlags and sdl.WindowFlags.MINIMIZED or 0
    return minimized_flag ~= 0 and (_get_editor_window_flags() & minimized_flag) ~= 0
end

local function _is_editor_window_event(event, ...)
    if not event
        or event.type ~= sdl.EventType.WINDOWEVENT
        or type(sdl.GetWindowEventID) ~= "function"
        or not sdl.WindowEventID then
        return false
    end

    local event_id = sdl.GetWindowEventID(event)
    for _, expected_id in ipairs({...}) do
        if event_id == expected_id then
            return true
        end
    end
    return false
end

local function _handle_editor_window_event(event)
    if not _is_editor_window_event(event,
        sdl.WindowEventID.RESIZED,
        sdl.WindowEventID.SIZE_CHANGED,
        sdl.WindowEventID.MINIMIZED,
        sdl.WindowEventID.MAXIMIZED,
        sdl.WindowEventID.RESTORED)
    then
        return
    end

    GlobalContext.render_target_reset_revision = (GlobalContext.render_target_reset_revision or 0) + 1
end

local function _get_save_manager()
    if save_manager_module == false then
        save_manager_module = require("application.framework.save_manager")
    end
    return save_manager_module
end

local function _get_editor_preview_input()
    if editor_preview_input_module == false then
        editor_preview_input_module = require("application.framework.editor_preview_input")
    end
    return editor_preview_input_module
end

local function _get_modify_manager()
    if modify_manager_module == false then
        modify_manager_module = require("application.framework.modify_manager")
    end
    return modify_manager_module
end

local function _get_editor_theme_manager()
    if editor_theme_manager_module == false then
        editor_theme_manager_module = require("application.framework.editor_theme_manager")
    end
    return editor_theme_manager_module
end

local function _get_style_workspace_manager()
    if style_workspace_manager_module == false then
        style_workspace_manager_module = require("application.framework.style_workspace_manager")
    end
    return style_workspace_manager_module
end

local function _get_ui_workspace_manager()
    if ui_workspace_manager_module == false then
        ui_workspace_manager_module = require("application.framework.ui_workspace_manager")
    end
    return ui_workspace_manager_module
end

local function _get_scene_editor()
    if scene_editor_module == false then
        scene_editor_module = require("application.scene.scene_editor")
    end
    return scene_editor_module
end

local function _resolve_existing_font_path(...)
    local candidate_list = {...}
    for _, candidate in ipairs(candidate_list) do
        if type(candidate) == "string" and candidate ~= "" and NativeIO.file_exists(candidate) then
            return candidate
        end
    end
    return path_sys_font
end

local function _load_story_editor_font(code_font_path, code_font_no, default_font_path)
    if not NativeIO.file_exists(path_sys_story_editor_font) then
        return GlobalContext.font_imgui_code or GlobalContext.font_imgui
    end

    if not imgui.AddMergedFontFromFileTTF then
        return GlobalContext.font_imgui_code or GlobalContext.font_imgui
    end

    local fallback_font_path = _resolve_existing_font_path(code_font_path, default_font_path)
    local fallback_font_no = fallback_font_path == code_font_path and code_font_no or 0
    local font = imgui.AddMergedFontFromFileTTF(
        path_sys_story_editor_font,
        0,
        fallback_font_path,
        fallback_font_no,
        story_editor_cjk_glyph_offset_y)
    if font then
        return font
    end
    if fallback_font_path ~= default_font_path and NativeIO.file_exists(default_font_path) then
        return imgui.AddMergedFontFromFileTTF(path_sys_story_editor_font, 0, default_font_path, 0, story_editor_cjk_glyph_offset_y)
    end
    return nil
end

local function _disable_imgui_ini_persistence()
    local io = imgui.GetIO and imgui.GetIO() or nil
    if not io then
        return
    end

    local ok = pcall(function()
        io.IniFilename = nil
    end)
    if not ok then
        pcall(function()
            io.IniFilename = ""
        end)
    end
end

local function _collect_release_imgui_ini_candidate_list()
    local result = {}
    local path_pool = {}
    local function _join_child_path(directory, file_name)
        if type(directory) ~= "string" or directory == "" then
            return nil
        end
        local suffix = directory:sub(-1)
        if suffix ~= "/" and suffix ~= "\\" then
            directory = directory .. "\\"
        end
        return directory .. file_name
    end
    local function add_path(path)
        if type(path) == "string" and path ~= "" and not path_pool[path] then
            path_pool[path] = true
            table.insert(result, path)
        end
    end

    local base_path = sdl.GetBasePath and sdl.GetBasePath() or nil
    if type(base_path) == "string" and base_path ~= "" then
        add_path(_join_child_path(base_path, "imgui.ini"))
    end

    local application_directory = rl.GetApplicationDirectory and rl.GetApplicationDirectory() or nil
    if type(application_directory) == "string" and application_directory ~= "" then
        add_path(_join_child_path(application_directory, "imgui.ini"))
    end

    return result
end

local function _cleanup_release_imgui_ini()
    for _, path in ipairs(_collect_release_imgui_ini_candidate_list()) do
        if NativeIO.file_exists(path) then
            NativeIO.remove_file(path)
        end
    end
end

local function _check_feature(exe_path, feature)
    if not NativeIO.file_exists(exe_path) then
        LogManager.log(string.format("无法定位工具：%s，%s功能可能无法正常使用", exe_path, feature), "warning")
    end
end

local function _check_document_unsaved()
    local unsaved_document_list = {}
    for _, document in ipairs(FlowManager.get_all_documents()) do
        local is_modified = false
        if document.is_modified then
            is_modified = document:is_modified()
        elseif document._modify_context then
            local ModifyManager = _get_modify_manager()
            local previous_context = ModifyManager.get_context()
            ModifyManager.set_context(document._modify_context)
            is_modified = ModifyManager.is_modify()
            ModifyManager.set_context(previous_context)
        end

        if is_modified then
            local kind = document.kind == "text" and "story" or "flow"
            table.insert(unsaved_document_list,
            {
                kind = kind,
                name = document._resource_id or document._id,
                save = function()
                    document:save_document()
                end,
            })
        end
    end
    for _, document in ipairs(_get_style_workspace_manager().get_all_documents()) do
        if document.is_modified and document:is_modified() then
            table.insert(unsaved_document_list,
            {
                kind = "style",
                name = document._resource_id or document._id,
                save = function()
                    document:save_document()
                end,
            })
        end
    end
    for _, document in ipairs(_get_ui_workspace_manager().get_all_documents()) do
        if document.is_modified and document:is_modified() then
            table.insert(unsaved_document_list,
            {
                kind = "ui",
                name = document._resource_id or document._id,
                save = function()
                    document:save_document()
                end,
            })
        end
    end
    if #unsaved_document_list == 0 then return end
    local str_list = "\n"
    for _, item in ipairs(unsaved_document_list) do
        local prefix = "[流程] "
        if item.kind == "style" then
            prefix = "[样式] "
        elseif item.kind == "story" then
            prefix = "[剧本] "
        elseif item.kind == "ui" then
            prefix = "[界面] "
        end
        str_list = str_list.."\n    •  "..prefix..(item.name or "<unknown>")
    end
    local msg = "如下文档修改后未保存："..str_list.."\n\n是否需要保存？"
    if sdl.ShowConfirmBox(sdl.MessageBoxFlags.WARNING, "未保存", msg, GlobalContext.window, "保存后退出", "放弃修改") then
        for _, item in ipairs(unsaved_document_list) do
            item.save()
        end
    end
end

local function _apply_window_icon(icon_path, allow_missing)
    local target_path = icon_path or default_window_icon_path
    if not NativeIO.file_exists(target_path) then
        if allow_missing then
            return false
        end
        error(string.format("无法读取窗口图标：%s", target_path))
    end

    local icon_buffer, icon_err = NativeIO.read_bytes(target_path)
    if not icon_buffer then
        if allow_missing then
            return false
        end
        error(string.format("无法读取窗口图标：%s\n%s", target_path, icon_err or "未知错误"))
    end

    local icon_image = rl.LoadImageFromMemory(string.lower(rl.GetFileExtension(target_path)), icon_buffer)
    if not rl.IsImageValid(icon_image) then
        NativeIO.dispose_buffer(icon_buffer)
        if allow_missing then
            return false
        end
        error(string.format("无法解析窗口图标：%s", target_path))
    end

    rl.SetWindowIcon(icon_image)
    rl.UnloadImage(icon_image)
    NativeIO.dispose_buffer(icon_buffer)
    return true
end

module.init = function()
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

    if not is_release_mode then
        local essential_path_list =
        {
            "application/node",
            "application/node/builtin",
            "application/node/custom",
            "application/pin",
            "application/pin/builtin",
            "application/pin/custom",
            "application/resources",
            "application/resources/flow",
            "application/resources/shader",
            "application/resources/style",
            "application/resources/ui",
            ".cache",
            ".cache/video",
        }
        for _, path in ipairs(essential_path_list) do
            if not NativeIO.directory_exists(path) then
                local ok, err = NativeIO.create_directories(path)
                if not ok then
                    error(string.format("无法创建目录：%s\n%s", path, err or "未知错误"))
                end
            end
        end
        _check_feature("application/external/luac54.exe", "脚本编译")
        _check_feature("application/external/rcedit.exe", "发布程序图标和元信息生成")
        _check_feature("application/external/ffmpeg.exe", "视频导入与自动转码")
        _check_feature("application/external/ImageMagick/magick.exe", "发布程序图标生成")
        _check_feature("application/external/EnigmaVirtualBox/enigmavb.exe", "单文件发布")
        _check_feature("application/external/EnigmaVirtualBox/enigmavbconsole.exe", "单文件发布")
    end

    ResourceIndex.set_logger(LogManager)

    local size_window_default = {w = 1920, h = 1080}
    local mode = sdl.GetDesktopDisplayMode(0)
    if mode.w < 1536 then
        size_window_default.w, size_window_default.h = 640, 360
    elseif mode.w < 2048 then
        size_window_default.w, size_window_default.h = 1280, 720
    end

    rl.InitWindow(GlobalContext.width_game_window, GlobalContext.height_game_window, SettingsManager.get("title"))
    _apply_window_icon(default_window_icon_path, true)
    if is_release_mode then
        rl.SetWindowState(rl.ConfigFlags.WINDOW_ALWAYS_RUN)
        if SettingsManager.get("default_fullscreen") then
            rl.ToggleBorderlessWindowed()
        end
    else
        rl.SetWindowState(rl.ConfigFlags.WINDOW_HIDDEN | rl.ConfigFlags.WINDOW_ALWAYS_RUN)
    end

    local default_font_path = _resolve_existing_font_path(path_sys_font, path_sys_code_font)
    local code_font_path = _resolve_existing_font_path(path_sys_code_font, default_font_path)
    local code_font_no = code_font_path == path_sys_code_font and path_sys_code_font_no or 0
    GlobalContext.font_wrapper_sdl = FontWrapper.new(default_font_path)

    if not is_release_mode then
        GlobalContext.window = sdl.CreateWindow(string.format("VoidNovelEngine - %s", GlobalContext.version), 
            sdl.WindowPosition.CENTERED, sdl.WindowPosition.CENTERED, size_window_default.w, size_window_default.h, sdl.WindowFlags.RESIZABLE)
        GlobalContext.renderer = sdl.CreateRenderer(GlobalContext.window, -1, sdl.RendererFlags.ACCELERATED)

        assert(imgui.sdlImGuiSetup(GlobalContext.window, GlobalContext.renderer), "ImGui SDL backend setup failed")

        GlobalContext.font_imgui = imgui.AddFontFromFileTTF(default_font_path)
        GlobalContext.font_imgui_code = imgui.AddFontFromFileTTF(code_font_path, code_font_no) or GlobalContext.font_imgui
        GlobalContext.font_imgui_story_editor = _load_story_editor_font(code_font_path, code_font_no, default_font_path)
            or GlobalContext.font_imgui_code
            or GlobalContext.font_imgui
        imgui.GetIO().ConfigFlags = imgui.GetIO().ConfigFlags | imgui.ConfigFlags.DockingEnable

        local style = imgui.GetStyle()
        style.WindowRounding, style.TabBorderSize = 4, 1
        style.FrameRounding, style.FrameBorderSize = 4, 1
        style.PopupRounding = 4
        _get_editor_theme_manager().apply_saved_theme()
    else
        imgui.rlImGuiSetup(true)
        _disable_imgui_ini_persistence()
        _cleanup_release_imgui_ini()
        GlobalContext.font_imgui = imgui.AddFontFromFileTTF(default_font_path)
        GlobalContext.font_imgui_code = imgui.AddFontFromFileTTF(code_font_path, code_font_no) or GlobalContext.font_imgui
        GlobalContext.font_imgui_story_editor = _load_story_editor_font(code_font_path, code_font_no, default_font_path)
            or GlobalContext.font_imgui_code
            or GlobalContext.font_imgui
    end

    GlobalContext.refresh_window_icon = function()
        local resolved_path = SettingsManager.get_window_icon_path()
        if _apply_window_icon(resolved_path, true) then
            return true
        end
        return _apply_window_icon(default_window_icon_path, true)
    end

    ScreenManager.init(GlobalContext.width_game_window, GlobalContext.height_game_window)

    assert(sdl.OpenAudio(44100, sdl.AudioFormat.DEFAULT, 2, 2048) == 0, sdl.GetError())
    if not rl.IsAudioDeviceReady() then
        rl.InitAudioDevice()
    end

    rl.SetTargetFPS(144)

    SceneManager.add_scene(SceneBootstrapLoading.new(is_release_mode and "released_scene" or "editor_scene"), "bootstrap_scene")
    if not is_release_mode then
        SceneManager.add_scene(_get_scene_editor().new(), "editor_scene")
    end
    SceneManager.add_scene(SceneReleased.new(), "released_scene")
    SceneManager.switch_to("bootstrap_scene")

    return module
end

module.run = function()
    local is_quit = false
    local is_release_mode = SettingsManager.get("release_mode")
    _configure_lua_gc()

    while not is_quit do
        if rl.WindowShouldClose() then
            if is_release_mode then
                is_quit = true
            else
                GlobalContext.toggle_preview_mode()
            end
        end
        if rl.IsKeyPressed(rl.KeyboardKey.F11)
            and (is_release_mode or not _get_editor_preview_input().should_block_editor_shortcuts())
        then
            rl.ToggleBorderlessWindowed()
        end
        if not is_release_mode then
            while sdl.PollEvent(event) == 1 do
                imgui.sdlImGuiProcessEvent(event)
                if event.type == sdl.EventType.QUIT then
                    _check_document_unsaved()
                    is_quit = true
                elseif event.type == sdl.EventType.RENDER_TARGETS_RESET
                    or event.type == sdl.EventType.RENDER_DEVICE_RESET then
                    GlobalContext.render_target_reset_revision = GlobalContext.render_target_reset_revision + 1
                else
                    _handle_editor_window_event(event)
                end
            end
        end

        rl.BeginDrawing()
        if not is_release_mode then
            imgui.sdlImGuiBegin()
            if GlobalContext.font_imgui then
                imgui.PushFont(GlobalContext.font_imgui, math.floor(18 * SettingsManager.get("editor_zoom_ratio")))
            end
        else
            imgui.rlImGuiBegin()
            if GlobalContext.font_imgui then
                imgui.PushFont(GlobalContext.font_imgui, math.floor(18 * SettingsManager.get("editor_zoom_ratio")))
            end
        end

        ScreenManager.on_update()
        local delta = rl.GetFrameTime()
        if delta < 0.3 then
            if is_release_mode then
                release_imgui_ini_cleanup_elapsed = release_imgui_ini_cleanup_elapsed + delta
                if release_imgui_ini_cleanup_elapsed >= 0.5 then
                    release_imgui_ini_cleanup_elapsed = 0
                    _cleanup_release_imgui_ini()
                end
            end
            AudioPlaybackManager.update(delta)
            ResourcesManager.update(delta)
            SaveThumbnailCache.update(delta)
            FlowManager.collect_garbage()
            _step_lua_gc()
            SceneManager.on_update(delta)
            _get_save_manager().update(delta)
            SaveLoadResultToast.update(delta)
        end

        ScreenManager.begin_render()
        SceneManager.on_render()
        SaveLoadResultToast.render()
        ScreenManager.end_render()
        
        rl.ClearBackground(ColorHelper.BLACK)
        local editor_window_presentable = is_release_mode or not _is_editor_window_minimized()
        if not is_release_mode and editor_window_presentable then sdl.RenderClear(GlobalContext.renderer) end
        ScreenManager.on_render()

        if not is_release_mode then
            if GlobalContext.font_imgui then
                imgui.PopFont()
            end
            imgui.sdlImGuiEnd(GlobalContext.renderer)
            if editor_window_presentable then
                sdl.RenderPresent(GlobalContext.renderer)
            end
        else
            if GlobalContext.font_imgui then
                imgui.PopFont()
            end
            imgui.rlImGuiEnd()
        end
        rl.EndDrawing()
    end
    GlobalContext.stop_debug()
    AudioPlaybackManager.shutdown()
    VideoPlaybackManager.shutdown_all()
    VideoImporter.shutdown()
    ResourceHotReload.stop()
    SceneManager.shutdown()
    FlowManager.unload()
    if ui_workspace_manager_module and ui_workspace_manager_module.unload then
        ui_workspace_manager_module.unload()
    end
    DefinitionLoader.unload()
    ResourcesManager.unload()
    SaveThumbnailCache.clear()
    SaveLoadResultToast.shutdown()
    if GlobalContext.font_wrapper_sdl and GlobalContext.font_wrapper_sdl.dispose then
        GlobalContext.font_wrapper_sdl:dispose()
        GlobalContext.font_wrapper_sdl = nil
    end
    if type(collectgarbage) == "function" then
        pcall(collectgarbage, "collect")
    end
    if not is_release_mode then
        imgui.sdlImGuiShutdown()
    else
        imgui.rlImGuiShutdown()
        _cleanup_release_imgui_ini()
    end
    ScreenManager.shutdown()
    if rl.IsAudioDeviceReady() then
        rl.CloseAudioDevice()
    end
    rl.CloseWindow()
    if not is_release_mode then
        sdl.DestroyRenderer(GlobalContext.renderer)
        sdl.DestroyWindow(GlobalContext.window)
    end
end

return module

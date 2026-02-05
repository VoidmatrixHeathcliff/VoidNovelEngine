-- ========================================
-- 文件: export_builder.lua
-- 放置位置: application/framework/export_builder.lua  
-- 功能: 游戏项目导出构建器核心逻辑
-- ========================================

local module = {}

local rl = Engine.Raylib
local util = Engine.Util
local json = Engine.JSON

local LogManager = require("application.framework.log_manager")
local GlobalContext = require("application.framework.global_context")

-- ========================================
-- 运行时启动脚本模板
-- ========================================
local RUNTIME_TEMPLATE = [[-- ========================================
-- 自动生成的游戏运行时启动脚本
-- 由 VoidNovelEngine %s 导出
-- ========================================

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util

-- 全局上下文配置
local GlobalContext = {
    debug = %s,                                     -- 是否启用调试模式
    width_game_window = %d,                         -- 游戏窗口宽度
    height_game_window = %d,                        -- 游戏窗口高度
    filter_mode = rl.TextureFilter.BILINEAR,        -- 纹理过滤模式
    color_theme = rl.Color(104, 163, 68, 225),      -- 主题颜色
    window = nil,
    renderer = nil,
    runtime_global_context = {},                    -- 运行时全局变量
    is_debug_game = true,                           -- 游戏运行标志
    current_blueprint = nil,                        -- 当前蓝图引用
}

-- ========================================
-- 初始化引擎子系统
-- ========================================
local function init_engine()
    -- 设置控制台显示(非调试模式隐藏)
    if not GlobalContext.debug then
        util.SetConsoleShown(false)
    end
    
    -- 初始化Raylib图形系统
    rl.SetConfigFlags(rl.ConfigFlags.VSYNC_HINT | rl.ConfigFlags.WINDOW_RESIZABLE)
    rl.SetTraceLogLevel(rl.TraceLogLevel.ERROR)
    rl.InitWindow(GlobalContext.width_game_window, GlobalContext.height_game_window, "%s")
    rl.SetTargetFPS(60)
    
    -- 初始化SDL子系统
    assert(sdl.Init(sdl.SubSystem.EVERYTHING) == 0, sdl.GetError())
    assert(sdl.InitIMG(sdl.IMGInitFlags.JPG | sdl.IMGInitFlags.PNG) ~= 0, sdl.GetError())
    assert(sdl.InitMIX(sdl.MIXInitFlags.MP3 | sdl.MIXInitFlags.OGG | sdl.MIXInitFlags.FLAC) ~= 0, sdl.GetError())
    assert(sdl.InitTTF() == 0, sdl.GetError())
    
    -- 打开音频设备
    assert(sdl.OpenAudio(44100, sdl.AudioFormat.DEFAULT, 2, 2048) == 0, sdl.GetError())
end

-- ========================================
-- 加载框架模块
-- ========================================
local ResourcesManager = require("application.framework.resources_manager")
local ScreenManager = require("application.framework.screen_manager")
local Blueprint = require("application.framework.blueprint")

-- 初始化屏幕管理器
ScreenManager.init(GlobalContext.width_game_window, GlobalContext.height_game_window)

-- 加载资源
ResourcesManager.load("application/resources")

-- 加载入口蓝图
local entry_blueprint = Blueprint.new("application/blueprint/%s")

-- ========================================
-- 运行时辅助函数
-- ========================================
GlobalContext.runtime_find_node = function(id)
    return GlobalContext.current_blueprint._node_pool[id]
end

GlobalContext.runtime_find_pin = function(id)
    return GlobalContext.current_blueprint._pin_pool[id]
end

GlobalContext.stop_debug = function()
    GlobalContext.runtime_global_context = {}
    GlobalContext.is_debug_game = false
    sdl.HaltChannel(-1)
end

-- ========================================
-- 主游戏循环
-- ========================================
local function main_loop()
    init_engine()
    
    -- 设置当前蓝图并开始执行
    GlobalContext.current_blueprint = entry_blueprint
    entry_blueprint:execute()
    
    local event = sdl.Event()
    
    -- 游戏主循环
    while not rl.WindowShouldClose() do
        -- 事件处理
        while sdl.PollEvent(event) == 1 do
            if event.type == sdl.EventType.QUIT then
                break
            end
        end
        
        -- 计算帧时间
        local delta = rl.GetFrameTime()
        if delta < 0.3 then  -- 防止帧时间过大导致异常
            -- 执行蓝图节点逻辑
            while rawget(entry_blueprint, "_next_node") do
                entry_blueprint._current_node = entry_blueprint._next_node
                entry_blueprint._next_node = nil
                entry_blueprint._current_node:on_exetute(
                    entry_blueprint._scene_context, 
                    rawget(entry_blueprint, "_next_node_entry_pin")
                )
            end
            
            -- 更新场景逻辑
            entry_blueprint._scene_context:on_update(delta)
            entry_blueprint._current_node:on_exetute_update(entry_blueprint._scene_context, delta)
        end
        
        -- 渲染画面
        rl.BeginDrawing()
        rl.ClearBackground(rl.Color(0, 0, 0, 255))
        
        ScreenManager.begin_render()
        entry_blueprint._scene_context:on_render()
        ScreenManager.end_render()
        
        ScreenManager.on_render()
        rl.EndDrawing()
    end
    
    -- 清理资源
    rl.CloseWindow()
    sdl.Quit()
end

-- ========================================
-- 错误处理
-- ========================================
local function traceback(err)
    if GlobalContext.debug then
        print(debug.traceback(err))
    else
        sdl.ShowSimpleMessageBox(
            sdl.MessageBoxFlags.ERROR,
            "游戏运行错误", 
            debug.traceback(err), 
            nil
        )
    end
    rl.CloseWindow()
    sdl.Quit()
end

-- ========================================
-- 启动游戏
-- ========================================
xpcall(main_loop, traceback)
]]

-- ========================================
-- 辅助函数: 拷贝文件
-- ========================================
local function _copy_file(src, dest)
    -- 确保目标目录存在
    local dest_dir = rl.GetDirectoryPath(dest)
    if not rl.DirectoryExists(dest_dir) then
        rl.MakeDirectory(dest_dir)
    end
    
    -- 读取源文件数据
    local data = rl.LoadFileData(src)
    if not data then
        return false, string.format("无法读取文件: %s", src)
    end
    
    -- 写入目标文件
    local success = rl.SaveFileData(dest, data.data, data.size)
    rl.UnloadFileData(data)
    
    if not success then
        return false, string.format("无法写入文件: %s", dest)
    end
    
    return true
end

-- ========================================
-- 辅助函数: 递归拷贝目录
-- ========================================
local function _copy_directory(src, dest, filter_fn)
    -- 创建目标目录
    if not rl.DirectoryExists(dest) then
        rl.MakeDirectory(dest)
    end
    
    -- 遍历源目录
    local file_list = rl.LoadDirectoryFilesEx(src, nil, true)
    for i = 1, file_list.count do
        local src_path = file_list:get(i - 1)
        local relative_path = string.sub(src_path, #src + 2)  -- 去掉源路径前缀
        local dest_path = dest .. "\\" .. relative_path
        
        -- 应用过滤器
        if not filter_fn or filter_fn(src_path, relative_path) then
            if rl.DirectoryExists(src_path) then
                -- 递归创建子目录
                if not rl.DirectoryExists(dest_path) then
                    rl.MakeDirectory(dest_path)
                end
            else
                -- 拷贝文件
                local success, err = _copy_file(src_path, dest_path)
                if not success then
                    rl.UnloadDirectoryFiles(file_list)
                    return false, err
                end
            end
        end
    end
    rl.UnloadDirectoryFiles(file_list)
    
    return true
end

-- ========================================
-- 辅助函数: 收集蓝图引用的资源
-- ========================================
local function _collect_blueprint_resources(blueprint_path)
    local resources = {
        textures = {},
        audios = {},
        fonts = {},
        shaders = {},
    }
    
    -- 读取蓝图JSON文件
    local json_str = rl.LoadFileText(blueprint_path)
    if not json_str then
        LogManager.log(string.format("无法读取蓝图文件: %s", blueprint_path), "warning")
        return resources
    end
    
    local bp_data = json.decode(json_str)
    rl.UnloadFileText(json_str)
    
    if not bp_data or not bp_data.nodes then
        return resources
    end
    
    -- 遍历所有节点,提取资源引用
    for _, node in ipairs(bp_data.nodes) do
        if node.pins then
            for _, pin in ipairs(node.pins) do
                -- 检查引脚默认值中的资源引用
                if pin.default_value and type(pin.default_value) == "string" then
                    local value = pin.default_value
                    
                    -- 根据引脚类型判断资源类型
                    if pin.type == "Texture" then
                        resources.textures[value] = true
                    elseif pin.type == "Audio" then
                        resources.audios[value] = true
                    elseif pin.type == "Font" then
                        resources.fonts[value] = true
                    elseif pin.type == "Shader" then
                        resources.shaders[value] = true
                    end
                end
            end
        end
    end
    
    return resources
end

-- ========================================
-- 主导出函数
-- ========================================
module.export_game = function(config, status)
    -- 使用协程避免阻塞UI
    local export_coroutine = coroutine.create(function()
        local output_dir = config.output_dir:get()
        local game_dir = output_dir .. "\\Game"
        
        -- ========== 步骤1: 创建导出目录结构 ==========
        status.current_task = "创建目录结构..."
        status.progress = 0.05
        coroutine.yield()
        
        local dirs_to_create = {
            game_dir,
            game_dir .. "\\application",
            game_dir .. "\\application\\blueprint",
            game_dir .. "\\application\\resources",
            game_dir .. "\\application\\icon",
            game_dir .. "\\application\\framework",
        }
        
        for _, dir in ipairs(dirs_to_create) do
            if not rl.DirectoryExists(dir) then
                rl.MakeDirectory(dir)
            end
        end
        
        LogManager.log("目录结构创建完成", "info")
        
        -- ========== 步骤2: 生成运行时启动脚本 ==========
        status.current_task = "生成运行时脚本..."
        status.progress = 0.15
        coroutine.yield()
        
        local runtime_script = string.format(
            RUNTIME_TEMPLATE,
            GlobalContext.version,                          -- 引擎版本号
            tostring(config.include_debug_files.val),       -- 调试模式
            config.window_width,                            -- 窗口宽度
            config.window_height,                           -- 窗口高度
            config.game_title:get(),                        -- 游戏标题
            config.entry_blueprint                          -- 入口蓝图文件名
        )
        
        rl.SaveFileText(game_dir .. "\\main.lua", runtime_script)
        LogManager.log("运行时脚本生成完成", "info")
        
        -- ========== 步骤3: 拷贝框架代码 ==========
        status.current_task = "拷贝框架文件..."
        status.progress = 0.30
        coroutine.yield()
        
        local success, err = _copy_directory(
            "application\\framework", 
            game_dir .. "\\application\\framework",
            function(src_path, relative_path)
                -- 排除编辑器专用文件
                local file_name = rl.GetFileName(src_path)
                if string.find(file_name, "export_builder") then
                    return false  -- 不拷贝导出器自身
                end
                return true
            end
        )
        
        if not success then
            status.error_message = err or "框架文件拷贝失败"
            status.is_completed = true
            status.is_exporting = false
            return
        end
        
        LogManager.log("框架文件拷贝完成", "info")
        
        -- ========== 步骤4: 拷贝蓝图文件 ==========
        status.current_task = "拷贝蓝图文件..."
        status.progress = 0.45
        coroutine.yield()
        
        local bp_src = "application\\blueprint\\" .. config.entry_blueprint
        local bp_dest = game_dir .. "\\application\\blueprint\\" .. config.entry_blueprint
        
        local success, err = _copy_file(bp_src, bp_dest)
        if not success then
            status.error_message = err or "蓝图文件拷贝失败"
            status.is_completed = true
            status.is_exporting = false
            return
        end
        
        LogManager.log(string.format("已拷贝蓝图: %s", config.entry_blueprint), "info")
        
        -- ========== 步骤5: 收集并拷贝资源文件 ==========
        status.current_task = "收集资源文件..."
        status.progress = 0.55
        coroutine.yield()
        
        local collected_resources = {}
        if config.auto_collect_resources.val then
            collected_resources = _collect_blueprint_resources(bp_src)
            LogManager.log("资源自动收集完成", "info")
        end
        
        -- 拷贝资源文件
        status.current_task = "拷贝资源文件..."
        status.progress = 0.70
        coroutine.yield()
        
        local resources_dir = "application\\resources"
        if rl.DirectoryExists(resources_dir) then
            local file_list = rl.LoadDirectoryFilesEx(resources_dir, nil, true)
            
            for i = 1, file_list.count do
                local src_path = file_list:get(i - 1)
                
                if not rl.DirectoryExists(src_path) then
                    local file_name = rl.GetFileNameWithoutExt(src_path)
                    local ext = string.lower(rl.GetFileExtension(src_path))
                    
                    -- 判断是否需要拷贝此资源
                    local should_copy = false
                    if config.auto_collect_resources.val then
                        -- 检查是否在收集列表中
                        if (ext == ".png" or ext == ".jpg") and collected_resources.textures[file_name] then
                            should_copy = true
                        elseif (ext == ".wav" or ext == ".mp3" or ext == ".ogg" or ext == ".flac") and collected_resources.audios[file_name] then
                            should_copy = true
                        elseif (ext == ".ttf" or ext == ".otf") and collected_resources.fonts[file_name] then
                            should_copy = true
                        elseif (ext == ".glsl" or ext == ".fs") and collected_resources.shaders[file_name] then
                            should_copy = true
                        end
                    else
                        -- 拷贝所有资源
                        should_copy = true
                    end
                    
                    if should_copy then
                        local relative_path = string.sub(src_path, #resources_dir + 2)
                        local dest_path = game_dir .. "\\application\\resources\\" .. relative_path
                        
                        local success, err = _copy_file(src_path, dest_path)
                        if not success then
                            rl.UnloadDirectoryFiles(file_list)
                            status.error_message = err or "资源文件拷贝失败"
                            status.is_completed = true
                            status.is_exporting = false
                            return
                        end
                    end
                end
            end
            rl.UnloadDirectoryFiles(file_list)
        end
        
        LogManager.log("资源文件拷贝完成", "info")
        
        -- ========== 步骤6: 拷贝图标资源 ==========
        status.current_task = "拷贝图标资源..."
        status.progress = 0.80
        coroutine.yield()
        
        if rl.DirectoryExists("application\\icon") then
            _copy_directory(
                "application\\icon",
                game_dir .. "\\application\\icon"
            )
            LogManager.log("图标资源拷贝完成", "info")
        end
        
        -- ========== 步骤7: 拷贝引擎运行时 ==========
        status.current_task = "拷贝引擎运行时..."
        status.progress = 0.90
        coroutine.yield()
        
        local runtime_files = {
            "VoidNovelEngine.exe",
            "lua54.dll",
            "raylib.dll",
            "SDL2.dll",
            "SDL2_image.dll",
            "SDL2_mixer.dll",
            "SDL2_ttf.dll",
        }
        
        for _, file in ipairs(runtime_files) do
            if rl.FileExists(file) then
                local success, err = _copy_file(file, game_dir .. "\\" .. file)
                if not success then
                    LogManager.log(string.format("警告: 无法拷贝运行时文件 %s", file), "warning")
                end
            end
        end
        
        LogManager.log("运行时文件拷贝完成", "info")
        
        -- ========== 步骤8: 创建启动说明文件 ==========
        status.current_task = "生成说明文件..."
        status.progress = 0.95
        coroutine.yield()
        
        local readme_content = string.format([[
========================================
  %s
========================================

游戏启动方法:
  双击 VoidNovelEngine.exe 即可运行游戏

系统要求:
  - 操作系统: Windows 10/11 (64位)
  - 内存: 至少 2GB RAM
  - 显卡: 支持OpenGL 3.3+

注意事项:
  1. 请勿删除任何DLL文件
  2. 首次运行可能被防火墙拦截,请添加信任
  3. 如果提示缺少运行库,请安装 VC++ Redistributable

技术支持:
  - GitHub: https://github.com/VoidmatrixHeathcliff/VoidNovelEngine
  - QQ群: 932941346

本游戏使用 VoidNovelEngine %s 制作
]], config.game_title:get(), GlobalContext.version)
        
        rl.SaveFileText(game_dir .. "\\README.txt", readme_content)
        
        -- ========== 完成 ==========
        status.current_task = "导出完成!"
        status.progress = 1.0
        status.is_completed = true
        status.is_exporting = false
        
        LogManager.log(string.format("游戏导出成功: %s", game_dir), "info")
    end)
    
    -- 启动协程
    coroutine.resume(export_coroutine)
    
    -- 注册更新回调
    local function update_export()
        if coroutine.status(export_coroutine) == "suspended" then
            coroutine.resume(export_coroutine)
        end
    end
    
    -- 将更新函数注入到全局
    _G._export_update_callback = update_export
end

return module

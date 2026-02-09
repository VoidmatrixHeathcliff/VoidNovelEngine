
-- ========================================
-- 文件: window_exporter.lua
-- 放置位置: application/scene/window/window_exporter.lua
-- 功能: 游戏项目导出向导窗口
-- ========================================

local module = {}

local rl = Engine.Raylib
local sdl = Engine.SDL
local util = Engine.Util
local imgui = Engine.ImGUI

local ImGUIHelper = require("application.framework.imgui_helper")
local LogManager = require("application.framework.log_manager")
local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")
local ExportBuilder = require("application.framework.export_builder")

-- ========================================
-- 导出配置数据结构
-- ========================================
local export_config = {
    -- 基础配置
    game_title = util.CString("我的游戏"),              -- 游戏标题
    window_width = 1920,                                -- 窗口宽度
    window_height = 1080,                               -- 窗口高度
    entry_blueprint = "",                               -- 入口蓝图文件名(不含路径)
    output_dir = util.CString(""),                      -- 导出目录
    
    -- 导出选项
    compress_resources = imgui.Bool(false),             -- 是否压缩资源(待实现)
    include_debug_files = imgui.Bool(false),            -- 是否包含调试文件
    auto_collect_resources = imgui.Bool(true),          -- 是否自动收集资源
}

-- 当前导出步骤 (1=基础配置, 2=资源选择, 3=导出进度)
local current_step = 1

-- 是否显示导出窗口
local is_window_open = imgui.Bool(false)

-- 导出状态
local export_status = {
    is_exporting = false,                               -- 是否正在导出
    progress = 0.0,                                     -- 导出进度(0-1)
    current_task = "",                                  -- 当前任务描述
    is_completed = false,                               -- 是否完成
    error_message = "",                                 -- 错误信息
}

-- 蓝图选择下拉列表选中索引
local selected_bp_index = 0

-- ========================================
-- 辅助函数: 获取所有蓝图列表
-- ========================================
local function _get_blueprint_list()
    local bp_list = {}
    for _, bp in ipairs(GlobalContext.blueprint_list) do
        -- 只保留文件名,去掉路径前缀
        local file_name = rl.GetFileName(bp._id)
        table.insert(bp_list, file_name)
    end
    return bp_list
end

-- ========================================
-- 辅助函数: 验证配置是否有效
-- ========================================
local function _validate_config()
    -- 检查游戏标题
    if export_config.game_title:empty() then
        return false, "游戏标题不能为空"
    end
    
    -- 检查分辨率
    if export_config.window_width < 640 or export_config.window_height < 480 then
        return false, "窗口分辨率不能小于 640x480"
    end
    
    -- 检查入口蓝图
    if export_config.entry_blueprint == "" then
        return false, "请选择入口蓝图"
    end
    
    -- 检查导出目录
    if export_config.output_dir:empty() then
        return false, "请选择导出目录"
    end
    
    return true, ""
end

-- ========================================
-- UI绘制: 步骤1 - 基础配置
-- ========================================
local function _draw_step1_basic_config()
    imgui.TextColored(imgui.ImColor(104, 163, 68, 255).value, "步骤 1/3: 基础配置")
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 10))
    
    -- 游戏标题输入
    imgui.AlignTextToFramePadding()
    imgui.Text("游戏标题:")
    imgui.SameLine()
    imgui.SetNextItemWidth(300)
    imgui.InputText("##game_title", export_config.game_title)
    if imgui.IsItemHovered() then
        imgui.SetTooltip("导出游戏的窗口标题")
    end
    
    imgui.Dummy(imgui.ImVec2(0, 5))
    
    -- 窗口分辨率设置
    imgui.AlignTextToFramePadding()
    imgui.Text("窗口分辨率:")
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    imgui.InputInt("##width", export_config, "window_width")
    imgui.SameLine()
    imgui.Text("×")
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    imgui.InputInt("##height", export_config, "window_height")
    if imgui.IsItemHovered() then
        imgui.SetTooltip("游戏窗口的初始分辨率")
    end
    
    imgui.Dummy(imgui.ImVec2(0, 5))
    
    -- 入口蓝图选择
    imgui.AlignTextToFramePadding()
    imgui.Text("入口蓝图:")
    imgui.SameLine()
    imgui.SetNextItemWidth(300)
    local bp_list = _get_blueprint_list()
    if #bp_list > 0 then
        if imgui.BeginCombo("##entry_bp", export_config.entry_blueprint) then
            for i, bp_file_name in ipairs(bp_list) do
                local is_selected = (selected_bp_index == i)
                if imgui.Selectable(bp_file_name, is_selected) then
                    selected_bp_index = i
                    export_config.entry_blueprint = bp_file_name
                end
                if is_selected then
                    imgui.SetItemDefaultFocus()
                end
            end
            imgui.EndCombo()
        end
    else
        imgui.TextDisabled("(无可用蓝图,请先创建蓝图)")
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("游戏启动时首先执行的蓝图脚本")
    end
    
    imgui.Dummy(imgui.ImVec2(0, 5))
    
    -- 导出目录选择
    imgui.AlignTextToFramePadding()
    imgui.Text("导出目录:")
    imgui.SameLine()
    imgui.SetNextItemWidth(250)
    imgui.InputText("##output_dir", export_config.output_dir, imgui.InputTextFlags.ReadOnly)
    imgui.SameLine()
    if imgui.Button("浏览...##output") then
        -- 打开文件夹选择对话框
        local work_dir = rl.GetWorkingDirectory()
        local default_export_dir = work_dir .. "\\Export"
        
        -- 尝试使用系统文件夹选择
        -- 注意: 这里需要你在 module_util.cpp 中实现 SelectFolder 函数
        -- 如果没有实现,可以暂时让用户手动输入
        if util.SelectFolder then
            local selected_path = util.SelectFolder("选择导出目录")
            if selected_path and selected_path ~= "" then
                export_config.output_dir:set(selected_path)
            end
        else
            -- 备用方案: 使用默认路径
            export_config.output_dir:set(default_export_dir)
            LogManager.log("文件夹选择功能未实现,使用默认导出目录", "warning")
        end
    end
    if imgui.IsItemHovered() then
        imgui.SetTooltip("游戏文件将被导出到此目录")
    end
    
    imgui.Dummy(imgui.ImVec2(0, 15))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 5))
    
    -- 导出选项复选框
    imgui.Checkbox("自动收集引用资源", export_config.auto_collect_resources)
    if imgui.IsItemHovered() then
        imgui.SetTooltip("自动分析蓝图并收集所有被引用的资源文件")
    end
    
    imgui.Checkbox("包含调试文件", export_config.include_debug_files)
    if imgui.IsItemHovered() then
        imgui.SetTooltip("包含控制台和调试信息 (仅用于测试)")
    end
    
    -- 底部按钮
    imgui.Dummy(imgui.ImVec2(0, 20))
    local button_width = 120
    imgui.SetCursorPosX(imgui.GetContentRegionAvail().x - button_width)
    if imgui.Button("下一步 >", imgui.ImVec2(button_width, 30)) then
        local is_valid, error_msg = _validate_config()
        if is_valid then
            current_step = 2
        else
            LogManager.log(error_msg, "error")
        end
    end
end

-- ========================================
-- UI绘制: 步骤2 - 资源确认
-- ========================================
local function _draw_step2_resource_confirmation()
    imgui.TextColored(imgui.ImColor(104, 163, 68, 255).value, "步骤 2/3: 资源确认")
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 10))
    
    if export_config.auto_collect_resources.val then
        imgui.TextWrapped("✓ 已启用自动资源收集")
        imgui.TextWrapped("将自动打包蓝图中引用的所有资源文件")
    else
        imgui.TextWrapped("将打包 application/resources/ 目录下的所有资源")
    end
    
    imgui.Dummy(imgui.ImVec2(0, 10))
    imgui.TextDisabled("以下内容将被导出:")
    imgui.Dummy(imgui.ImVec2(0, 5))
    
    -- 显示将要导出的内容列表
    imgui.BeginChild("export_content_list", imgui.ImVec2(0, 200), true)
        imgui.BulletText(string.format("入口蓝图: %s", export_config.entry_blueprint))
        imgui.BulletText("引擎运行时文件 (VoidNovelEngine.exe 及 DLL)")
        imgui.BulletText("框架代码 (framework/)")
        if export_config.auto_collect_resources.val then
            imgui.BulletText("蓝图引用的资源文件")
        else
            imgui.BulletText("所有资源文件 (resources/)")
        end
        imgui.BulletText("图标资源 (icon/)")
    imgui.EndChild()
    
    -- 底部按钮
    imgui.Dummy(imgui.ImVec2(0, 20))
    local button_width = 120
    if imgui.Button("< 上一步", imgui.ImVec2(button_width, 30)) then
        current_step = 1
    end
    imgui.SameLine()
    imgui.SetCursorPosX(imgui.GetContentRegionAvail().x - button_width)
    if imgui.Button("开始导出 >", imgui.ImVec2(button_width, 30)) then
        current_step = 3
        export_status.is_exporting = true
        export_status.progress = 0.0
        export_status.is_completed = false
        export_status.error_message = ""
        
        -- 调用导出构建器
        ExportBuilder.export_game(export_config, export_status)
    end
end

-- ========================================
-- UI绘制: 步骤3 - 导出进度
-- ========================================
local function _draw_step3_export_progress()
    imgui.TextColored(imgui.ImColor(104, 163, 68, 255).value, "步骤 3/3: 导出进度")
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, 20))
    
    if export_status.is_exporting then
        -- 显示进度条
        imgui.Text(string.format("正在导出: %s", export_status.current_task))
        imgui.ProgressBar(export_status.progress, imgui.ImVec2(-1, 30))
        imgui.Dummy(imgui.ImVec2(0, 10))
        imgui.TextDisabled("请稍候,导出过程可能需要几分钟...")
    elseif export_status.is_completed then
        if export_status.error_message == "" then
            -- 导出成功
            imgui.TextColored(imgui.ImColor(62, 179, 112, 255).value, "✓ 导出完成!")
            imgui.Dummy(imgui.ImVec2(0, 10))
            imgui.TextWrapped(string.format("游戏文件已成功导出到:\n%s", export_config.output_dir:get()))
            imgui.Dummy(imgui.ImVec2(0, 20))
            
            if imgui.Button("打开导出目录", imgui.ImVec2(-1, 30)) then
                util.ShellExecute("open", export_config.output_dir:get())
            end
        else
            -- 导出失败
            imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, "✗ 导出失败")
            imgui.Dummy(imgui.ImVec2(0, 10))
            imgui.TextWrapped(string.format("错误信息: %s", export_status.error_message))
        end
        
        imgui.Dummy(imgui.ImVec2(0, 20))
        if imgui.Button("关闭", imgui.ImVec2(-1, 30)) then
            is_window_open.val = false
            current_step = 1
            export_status.is_exporting = false
            export_status.is_completed = false
        end
    end
end

-- ========================================
-- 模块初始化
-- ========================================
module.on_enter = function()
    -- 初始化默认导出目录
    local work_dir = rl.GetWorkingDirectory()
    export_config.output_dir:set(work_dir .. "\\Export")
    
    -- 如果有打开的蓝图,默认选择第一个
    local bp_list = _get_blueprint_list()
    if #bp_list > 0 then
        selected_bp_index = 1
        export_config.entry_blueprint = bp_list[1]
    end
end

-- ========================================
-- 主更新函数
-- ========================================
module.on_update = function(self, delta)
    -- 更新导出进度(如果正在导出)
    if _G._export_update_callback then
        _G._export_update_callback()
    end
    
    -- 绘制导出窗口
    if is_window_open.val then
        local window_flags = imgui.WindowFlags.NoCollapse
        imgui.SetNextWindowSize(imgui.ImVec2(600, 500), imgui.Cond.FirstUseEver)
        
        if imgui.Begin("导出游戏项目", is_window_open, window_flags) then
            -- 根据当前步骤绘制对应界面
            if current_step == 1 then
                _draw_step1_basic_config()
            elseif current_step == 2 then
                _draw_step2_resource_confirmation()
            elseif current_step == 3 then
                _draw_step3_export_progress()
            end
        end
        imgui.End()
    end
end

-- ========================================
-- 打开导出窗口
-- ========================================
module.open_window = function()
    is_window_open.val = true
    current_step = 1
    
    -- 重新初始化配置
    local bp_list = _get_blueprint_list()
    if #bp_list > 0 then
        selected_bp_index = 1
        export_config.entry_blueprint = bp_list[1]
    end
end

-- ========================================
-- 重置导出向导状态
-- ========================================
module.reset = function()
    current_step = 1
    export_status.is_exporting = false
    export_status.is_completed = false
    export_status.error_message = ""
end

return module

local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

local LogManager = require("application.framework.log_manager")
local ImGUIHelper = require("application.framework.imgui_helper")
local ColorHelper = require("application.framework.color_helper")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")

local str_window_title = util.CString()

local idx_platform = 1
local platform_list = {}

local idx_entry_flow = -1
local cstr_window_title = util.CString()
local cstr_window_icon_path = util.CString()
local is_default_fullscreen = imgui.Bool()
local is_single_file = imgui.Bool()
local cstr_developer = util.CString()
local cstr_file_description = util.CString()
local cstr_release_version = util.CString()

local reset_folder = function(path)
    os.execute(string.format("rmdir /s /q \"%s\"", path))
    os.execute(string.format("mkdir \"%s\"", path))
end

local on_update_windows = function()
    imgui.SeparatorText("运行")
    imgui.Columns(2, "运行")

    imgui.Text("入口流程")
    ImGUIHelper.HoveredTooltip("游戏启动时自动加载并执行的流程脚本文档")
    imgui.NextColumn()
    local entry_flow = GlobalContext.blueprint_list[idx_entry_flow]
    local combo_text = entry_flow and entry_flow._path or ""
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    if imgui.BeginCombo("##入口流程", combo_text) then
        for idx, flow in ipairs(GlobalContext.blueprint_list) do
            if imgui.Selectable(flow._path, idx_entry_flow == idx) then
                idx_entry_flow = idx
                SettingsManager.set("entry_flow", flow._path)
            end
        end
        imgui.EndCombo()
    end
    imgui.NextColumn()

    imgui.Columns(1)

    imgui.SeparatorText("窗口")
    imgui.Columns(2, "窗口")

    imgui.Text("标题")
    imgui.NextColumn()
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    imgui.InputText("##标题", cstr_window_title)
    if imgui.IsItemDeactivatedAfterEdit() then
        SettingsManager.set("title", cstr_window_title:get())
    end
    imgui.NextColumn()

    imgui.Text("图标")
    ImGUIHelper.HoveredTooltip("游戏程序和窗口图标图片文件的完整路径")
    imgui.NextColumn()
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    imgui.InputText("##图标", cstr_window_icon_path)
    if imgui.IsItemDeactivatedAfterEdit() then
        SettingsManager.set("icon_path", cstr_window_icon_path:get())
    end
    imgui.NextColumn()

    imgui.Text("默认全屏")
    ImGUIHelper.HoveredTooltip("游戏启动后窗口默认占据玩家整个屏幕大小")
    imgui.NextColumn()
    if imgui.Checkbox("##默认全屏", is_default_fullscreen) then
        SettingsManager.set("default_fullscreen", is_default_fullscreen.val)
    end
    imgui.NextColumn()

    imgui.Columns(1)

    imgui.SeparatorText("文件")
    imgui.Columns(2, "文件")
    
    imgui.Text("单文件")
    ImGUIHelper.HoveredTooltip("游戏程序仅包含单个可执行文件，需要更长时间来执行发布流程")
    imgui.NextColumn()
    if imgui.Checkbox("##单文件", is_single_file) then
        SettingsManager.set("single_file", is_single_file.val)
    end
    imgui.NextColumn()

    imgui.Text("开发者")
    imgui.NextColumn()
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    imgui.InputText("##开发者", cstr_developer)
    if imgui.IsItemDeactivatedAfterEdit() then
        SettingsManager.set("developer", cstr_developer:get())
    end
    imgui.NextColumn()

    imgui.Text("文件描述")
    imgui.NextColumn()
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    imgui.InputText("##文件描述", cstr_file_description)
    if imgui.IsItemDeactivatedAfterEdit() then
        SettingsManager.set("file_description", cstr_file_description:get())
    end
    imgui.NextColumn()

    imgui.Text("发布版本")
    imgui.NextColumn()
    imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
    imgui.InputText("##发布版本", cstr_release_version)
    if imgui.IsItemDeactivatedAfterEdit() then
        SettingsManager.set("release_version", cstr_release_version:get())
    end
    imgui.NextColumn()

    imgui.Columns(1)
end

local on_export_windows = function()
    LogManager.log("正在执行Windows平台游戏发布流程...", "info")
    LogManager.log("正在构建发布目录...", "info")
    -- 重置当前平台包目录
    local target_folder <const> = "release\\Windows"
    reset_folder(target_folder)
    -- 创建缓存目录
    local temp_folder <const> = target_folder.."\\"..".temp"
    -- 根据是否需要单文件包决定拷贝目标目录
    local copy_dst_folder = target_folder
    if SettingsManager.get("single_file") then
        copy_dst_folder = target_folder.."\\.temp"
        os.execute(string.format("mkdir \"%s\"", copy_dst_folder))
    end
    -- 拷贝目录和必要的文件
    local essential_folder_list = 
    {
        "application\\blueprint",
        "application\\extension",
        "application\\flow",
        "application\\framework",
        "application\\resources",
        "application\\scene",
        "application\\style",
        "application\\ui",
    }
    local essential_file_list = 
    {
        "application\\external\\ffmpeg.exe",
        "application\\application.lua",
        "main.lua", 
    }
    local exe_file_name = rl.GetFileName(util.GetExeFilePath())
    table.insert(essential_file_list, exe_file_name)
    for _, folder in ipairs(essential_folder_list) do
        os.execute(string.format("xcopy \"%s\" \"%s\" /I /Y /E >nul 2>&1", folder, copy_dst_folder.."\\"..folder))
    end
    for _, file in ipairs(essential_file_list) do
        os.execute(string.format("robocopy \"%s\" \"%s\" \"%s\" >nul 2>&1", 
            rl.GetDirectoryPath(file), copy_dst_folder.."\\"..rl.GetDirectoryPath(file), rl.GetFileName(file)))
    end
    -- 将脚本编译为字节码形式
    LogManager.log("正在编译脚本...", "info")
    local script_path_list = rl.LoadDirectoryFilesEx(copy_dst_folder, ".lua", true)
    local luac_path <const> = "application\\external\\luac54.exe"
    for i = 1, script_path_list.count do
        local path = script_path_list:get(i - 1)
        os.execute(string.format("%s -o \"%s\" \"%s\"", luac_path, path, path))
    end
    rl.UnloadDirectoryFiles(script_path_list)
    -- 生成工程信息
    local copy_data = SettingsManager.copy()
    copy_data.release_mode = true
    SettingsManager.save(copy_dst_folder.."\\project.vne", copy_data)   
    -- 生成文件元信息
    LogManager.log("正在生成文件元信息...", "info")
    local target_exe_file_name = "VoidNovelEngineGame.exe"
    local icon_file_path = target_folder.."\\".."icon.ico"
    os.rename(copy_dst_folder.."\\"..exe_file_name, copy_dst_folder.."\\"..target_exe_file_name)
    os.execute(string.format("%s \"%s\" -define icon:auto-resize=256,128,64,48,32,16 \"%s\"", 
        "application\\external\\ImageMagick\\magick.exe", SettingsManager.get("icon_path"), icon_file_path))
    os.execute(string.format([[%s "%s" --set-icon "%s" --set-version-string "CompanyName" "%s"]], 
        "application\\external\\rcedit.exe", copy_dst_folder.."\\"..target_exe_file_name,
        icon_file_path, util.UTF8ToGBK(SettingsManager.get("developer"))))
    os.execute(string.format([[%s "%s" --set-version-string "FileDescription" "%s"]], 
        "application\\external\\rcedit.exe", copy_dst_folder.."\\"..target_exe_file_name, util.UTF8ToGBK(SettingsManager.get("file_description"))))
    os.execute(string.format([[%s "%s" --set-file-version "%s"]], 
        "application\\external\\rcedit.exe", copy_dst_folder.."\\"..target_exe_file_name, util.UTF8ToGBK(SettingsManager.get("release_version"))))
    os.remove(icon_file_path)
    -- 处理单文件打包
    if SettingsManager.get("single_file") then
        LogManager.log("正在打包为单文件...", "info")
        local base_path = sdl.GetBasePath()
        local enigma_path <const> = base_path.."application\\external\\EnigmaVirtualBox\\enigmavbconsole.exe"
        local source_dir = base_path..copy_dst_folder
        local main_exe_name = target_exe_file_name
        local output_file = base_path..target_folder.."\\"..target_exe_file_name
        local evb_project_file = base_path..target_folder.."\\".."temp.evb"        
        local evb_gen_template = require("application.framework.evb_gen_template")
        local ps_content = string.format(
        [[
$EnigmaPath = "%s"
$SourceDir  = "%s"
$MainExeName = "%s"
$OutputFile = "%s"
$EvbProjectFile = "%s"
%s
        ]], enigma_path, source_dir, main_exe_name, output_file, evb_project_file, evb_gen_template)
        local ps_file_path <const> = "application\\external\\EnigmaVirtualBox\\evb_pack.ps1"
        local ps_file = io.open(ps_file_path, "w")
        if not ps_file then
            LogManager.log("打包为单文件失败，发布流程终止", "error")
            return
        end
        ps_file:write(ps_content) ps_file:flush() ps_file:close()
        os.execute(string.format("PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File \"%s\"", ps_file_path))
        LogManager.log("正在清理临时文件...", "info")
        os.remove(ps_file_path)
        os.execute(string.format("rmdir /s /q \"%s\"", copy_dst_folder))
    end
    LogManager.log("已完成Windows平台游戏发布", "success")
end

local on_update_unsupported_platform = function()
    imgui.TextDisabled("* 当前版本暂不支持发布到该平台")
end

module.on_enter = function()
    table.insert(platform_list, {icon = "windows-fill", name = "Windows", on_update = on_update_windows, on_export = on_export_windows})
    table.insert(platform_list, {icon = "android-fill", name = "Android", on_update = on_update_unsupported_platform})
    table.insert(platform_list, {icon = "apple-fill", name = "macOS", on_update = on_update_unsupported_platform})
    table.insert(platform_list, {icon = "ubuntu-fill", name = "Linux", on_update = on_update_unsupported_platform})
    table.insert(platform_list, {icon = "html5-fill", name = "Web", on_update = on_update_unsupported_platform})
    local entry_flow = SettingsManager.get("entry_flow")
    for idx, flow in ipairs(GlobalContext.blueprint_list) do
        if entry_flow == flow._path then
            idx_entry_flow = idx
            break
        end
    end
    cstr_window_title:set(SettingsManager.get("title"))
    cstr_window_icon_path:set(SettingsManager.get("icon_path"))
    is_default_fullscreen.val = SettingsManager.get("default_fullscreen")
    is_single_file.val = SettingsManager.get("single_file")
    cstr_developer:set(SettingsManager.get("developer"))
    cstr_file_description:set(SettingsManager.get("file_description"))
    cstr_release_version:set(SettingsManager.get("release_version"))
end

module.on_update = function(self, delta)
    imgui.Begin("发布设置")
        local size_icon = imgui.ImVec2(imgui.GetTextLineHeight(), imgui.GetTextLineHeight())
        local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
        imgui.Text("发布平台：")
        imgui.SameLine()
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x - 18 * editor_zoom_ratio - 16)
        if imgui.BeginCombo("##发布平台", platform_list[idx_platform].name) then
            for idx, platform in ipairs(platform_list) do
                local pos = imgui.GetCursorPos()
                if imgui.Selectable("##"..idx, idx == idx_platform, imgui.SelectableFlags.SpanAllColumns) then
                    idx_platform = idx
                end
                imgui.SetCursorPos(pos)
                imgui.Image(ResourcesManager.find_icon(platform.icon), size_icon, nil, nil, ColorHelper.IMGUI_WHITE, nil)
                imgui.SameLine()
                imgui.Text(platform.name)
            end
            imgui.EndCombo()
        end
        imgui.SameLine()
        local current_platform = platform_list[idx_platform]
        imgui.BeginDisabled(not current_platform.on_export)
        if imgui.ImageButton("export", ResourcesManager.find_icon("upload-2-fill"), 
            imgui.ImVec2(18 * editor_zoom_ratio, 18 * editor_zoom_ratio), nil, nil, nil, nil) then
            current_platform.on_export()
        end
        imgui.EndDisabled()
        ImGUIHelper.HoveredTooltip("发布到当前平台")
        imgui.BeginChild("发布设置内容", nil, imgui.ChildFlags.Borders)
            current_platform.on_update()
        imgui.EndChild()
    imgui.End()
end

return module


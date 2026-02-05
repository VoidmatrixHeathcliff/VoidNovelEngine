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

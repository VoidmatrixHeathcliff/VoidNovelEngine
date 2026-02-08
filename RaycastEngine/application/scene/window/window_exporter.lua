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
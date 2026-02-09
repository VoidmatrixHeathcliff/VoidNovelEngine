local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

local Scene = require("application.framework.scene")
local Blueprint = require("application.framework.blueprint")
local LogManager = require("application.framework.log_manager")
local UndoManager = require("application.framework.undo_manager")
local ModifyManager = require("application.framework.modify_manager")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")
local ResourcesManager = require("application.framework.resources_manager")

local window_assets = require("application.scene.window.window_assets")
local window_console = require("application.scene.window.window_console")
local window_monitor = require("application.scene.window.window_monitor")
local window_preview = require("application.scene.window.window_preview")
local window_settings = require("application.scene.window.window_settings")
local window_exporter = require("application.scene.window.window_exporter")
local window_ui_designer = require("application.scene.window.window_ui_designer")
local window_flow_designer = require("application.scene.window.window_flow_designer")
local window_style_designer = require("application.scene.window.window_style_designer")

local flag_window_main_docker <const> = imgui.WindowFlags.NoDocking | imgui.WindowFlags.NoTitleBar | imgui.WindowFlags.MenuBar 
    | imgui.WindowFlags.NoCollapse | imgui.WindowFlags.NoResize | imgui.WindowFlags.NoMove | imgui.WindowFlags.NoBringToFrontOnFocus | imgui.WindowFlags.NoNavFocus

local cstr_file_name = util.CString()

local function _menu_with_icon(icon_id, text)
    local height <const> = imgui.GetTextLineHeight()
    local size_icon <const> = imgui.ImVec2(height, height)
    imgui.Image(ResourcesManager.find_icon(icon_id), size_icon, nil, nil, nil, nil)
    imgui.SameLine()
    return imgui.BeginMenu(text)
end

local function _menu_item_with_icon(icon_id, text, shortcut, selected)
    local height <const> = imgui.GetTextLineHeight()
    local size_icon <const> = imgui.ImVec2(height, height)
    imgui.Image(ResourcesManager.find_icon(icon_id), size_icon, nil, nil, nil, nil)
    imgui.SameLine()
    return imgui.MenuItem(text, shortcut, selected)
end

local function _menu_item_font_zoom(zoom)
    if imgui.MenuItem(string.format("%d%%", zoom * 100), nil, SettingsManager.get("editor_zoom_ratio") == zoom) then
        SettingsManager.set("editor_zoom_ratio", zoom)
    end
end

local function _is_current_blueprint_valid()
    return GlobalContext.current_blueprint and GlobalContext.current_blueprint._is_open.val
end

local function _run_debug()
    if GlobalContext.is_debug_game or not _is_current_blueprint_valid() then return end
    GlobalContext.is_debug_game = true
    GlobalContext.current_blueprint:execute()
end

local function _save_all_doc()
    for _, blueprint in ipairs(GlobalContext.blueprint_list) do
        blueprint:save_document()
    end
end

local function _on_create_file(type_name, ext, path_folder, on_create)
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    imgui.Text(string.format("%s路径：", type_name))
    imgui.AlignTextToFramePadding()
    imgui.Text(path_folder)
    imgui.SameLine()
    imgui.SetNextItemWidth(75 * editor_zoom_ratio)
    imgui.InputText("##file_name", cstr_file_name)
    imgui.SameLine()
    imgui.Text(ext)
    local can_create = true
    local path = string.format("%s%s%s", path_folder, cstr_file_name:get(), ext)
    if cstr_file_name:empty() or not rl.IsFileNameValid(cstr_file_name:get()) then
        imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, string.format("+ 不合法的%s文件名", type_name))
        can_create = false
    elseif rl.FileExists(util.UTF8ToGBK(path)) then
        imgui.TextColored(imgui.ImColor(243, 152, 0, 255).value, string.format("+ 已存在同名%s文件", type_name))
        can_create = false
    else
        imgui.TextColored(imgui.ImColor(62, 179, 112, 255).value, string.format("+ 合法的%s文件名", type_name))
    end
    imgui.Dummy(imgui.ImVec2(0, 5 * editor_zoom_ratio))
    imgui.BeginDisabled(not can_create)
        if imgui.Button("创 建 文 件", imgui.ImVec2(imgui.GetContentRegionAvail().x, 0)) then
            cstr_file_name:set("")  on_create(path)
            LogManager.log(string.format("创建%s文件：%s", type_name, path), "info")
        end
    imgui.EndDisabled()
end

local function _on_tick_menu_bar()
    if imgui.BeginMenuBar() then
        if imgui.BeginMenu(" 文件 ") then
            if _menu_with_icon("flow-chart", "新建流程脚本") then
                _on_create_file("流程脚本", ".flow", "application/flow/", function(path)
                    table.insert(GlobalContext.blueprint_list, Blueprint.new(path))
                end)
                imgui.EndMenu()
            end
            if _menu_with_icon("folder-open-line", "打开流程脚本") then
                for _, blueprint in ipairs(GlobalContext.blueprint_list) do
                    if _menu_item_with_icon("file-paper-2-line", blueprint._id, nil, blueprint._is_open.val) then
                        blueprint._is_open.val = not blueprint._is_open.val
                    end
                end
                imgui.EndMenu()
            end
            if _menu_with_icon("layout-3-line", "新建界面设计") then
                _on_create_file("界面设计", ".ui", "application/ui/", function(path)
                    -- table.insert(GlobalContext.blueprint_list, Blueprint.new(path))
                end)
                imgui.EndMenu()
            end
            if _menu_with_icon("palette-line", "新建样式设计") then
                _on_create_file("样式设计", ".style", "application/style/", function(path)
                    -- table.insert(GlobalContext.blueprint_list, Blueprint.new(path))
                end)
                imgui.EndMenu()
            end
            imgui.Separator()
            if _menu_item_with_icon("save-3-fill", "全部保存", "Ctrl+Shift+S") then
                _save_all_doc()
            end
            imgui.EndMenu()
        end
        if imgui.BeginMenu(" 编辑 ") then
            imgui.BeginDisabled(not _is_current_blueprint_valid())
                if _menu_item_with_icon("arrow-go-back-fill", "撤销", "Ctrl+Z") then
                    ModifyManager.set_context(GlobalContext.current_blueprint._modify_context)
                    UndoManager.set_context(GlobalContext.current_blueprint._undo_context)
                        UndoManager.undo()
                    UndoManager.set_context()
                    ModifyManager.set_context()
                end
                if _menu_item_with_icon("arrow-go-forward-fill", "重做", "Ctrl+Y") then
                    ModifyManager.set_context(GlobalContext.current_blueprint._modify_context)
                    UndoManager.set_context(GlobalContext.current_blueprint._undo_context)
                        UndoManager.redo()
                    UndoManager.set_context()
                    ModifyManager.set_context()
                end
            imgui.EndDisabled()
            imgui.EndMenu()
        end
        if imgui.BeginMenu(" 视图 ") then
            imgui.BeginDisabled(not _is_current_blueprint_valid())
                if _menu_item_with_icon("git-commit-line", "显示流程", nil, GlobalContext.is_show_flow.val) then
                    GlobalContext.is_show_flow.val = not GlobalContext.is_show_flow.val
                end
                if _menu_item_with_icon("hashtag", "显示所有节点ID", nil, GlobalContext.is_show_all_node_id.val) then
                    GlobalContext.is_show_all_node_id.val = not GlobalContext.is_show_all_node_id.val
                end
                if _menu_item_with_icon("navigation-fill", "导航到全部内容", "Ctrl+R") then
                    imgui.NodeEditor.SetCurrentEditor(GlobalContext.current_blueprint._context)
                    imgui.NodeEditor.NavigateToContent()
                end
            imgui.EndDisabled()
            if _menu_with_icon("zoom-in-line", "编辑器界面缩放") then
                _menu_item_font_zoom(0.50)
                _menu_item_font_zoom(0.75)
                _menu_item_font_zoom(1.00)
                _menu_item_font_zoom(1.25)
                _menu_item_font_zoom(1.50)
                _menu_item_font_zoom(2.00)
                imgui.EndMenu()
            end
            imgui.EndMenu()
        end
        if imgui.BeginMenu(" 调试 ") then
            if _menu_item_with_icon("delete-bin-5-fill", "清空控制台") then
                LogManager.clear()
            end
            imgui.BeginDisabled(GlobalContext.is_debug_game or not _is_current_blueprint_valid())
                if _menu_item_with_icon("bug-fill", "从当前流程调试", "F5") then
                    _run_debug()
                end
            imgui.EndDisabled()
            if _menu_item_with_icon("timer-flash-line", "显示调试窗口帧率", nil, SettingsManager.get("is_show_debug_fps")) then
                SettingsManager.set("is_show_debug_fps", not SettingsManager.get("is_show_debug_fps"))
            end
            imgui.EndMenu()
        end
        if imgui.BeginMenu(" 帮助 ") then
                if _menu_item_with_icon("qq-fill", "反馈与交流...") then
                    util.ShellExecute("open", "https://qun.qq.com/universal-share/share?ac=1&authKey=c9GNKInVZCVqtwwPd91MlcAyLKuoUcejnVgwfzx5O%2FC40r7wo9gxizghKBPLscRO&busi_data=eyJncm91cENvZGUiOiI5MzI5NDEzNDYiLCJ0b2tlbiI6Im0vWktZcmlsS0VyMkY4dmhQM2E2dUltYjZMTUZQcFViTCt6TTVENDdHbGVNaEZyR01yMWFuOW1hLzd4ckM4cUYiLCJ1aW4iOiIxODA4NDY5MTU1In0%3D&data=YqhIvkP8oUejNypvckzqpEvGefu1H6Uhnxx7FIsLJVN41xlSedIF854M_CBCh2dbeNkD7ybVdgpxE5Qj7laAKg&svctype=4&tempid=h5_group_info")
                end
                if _menu_item_with_icon("hand-heart-fill", "赞助与支持...") then
                    util.ShellExecute("open", "https://afdian.com/a/Voidmatrix")
                end
                if _menu_item_with_icon("bilibili-fill", "前往作者主页...") then
                    util.ShellExecute("open", "https://space.bilibili.com/25864506")
                end
                if _menu_item_with_icon("github-fill", "访问GitHub页面...") then
                    util.ShellExecute("open", "https://github.com/VoidmatrixHeathcliff/VoidNovelEngine")
                end
                if _menu_item_with_icon("question-fill", "关于VoidNovelEngine...") then
                    sdl.ShowSimpleMessageBox(sdl.MessageBoxFlags.INFORMATION, "关于VoidNovelEngine...", 
                        string.format([[
VoidNovelEngine 视觉小说引擎
版本号：%s
- By Voidmatrix
                        ]], GlobalContext.version), GlobalContext.window)
                end
            imgui.EndMenu()
        end
        imgui.EndMenuBar()
    end
end

local function on_enter(self)
    window_assets.on_enter()
    window_console.on_enter()
    window_monitor.on_enter()
    window_preview.on_enter()
    window_settings.on_enter()
    window_flow_designer.on_enter()
    window_ui_designer.on_enter()
    window_style_designer.on_enter()
    window_exporter.on_enter()
end

local function on_exit(self)

end

local function on_update(self, delta)
    local viewport = imgui.GetMainViewport()
    imgui.SetNextWindowPos(viewport.WorkPos)
    imgui.SetNextWindowSize(viewport.WorkSize)
    imgui.SetNextWindowViewport(viewport.ID)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVar(imgui.StyleVar.WindowRounding, 0)
    imgui.Begin("DockerWindow", nil, flag_window_main_docker)
        imgui.PopStyleVar(2)
        imgui.DockSpace(imgui.GetID("MainDockSpace"))
        _on_tick_menu_bar()
        window_assets:on_update(delta)
        window_console:on_update(delta)
        window_monitor:on_update(delta)
        window_preview:on_update(delta)
        window_settings:on_update(delta)
        window_exporter:on_update(delta)
        window_ui_designer:on_update(delta)
        window_style_designer:on_update(delta)
        window_flow_designer:on_update(delta)
        -- 处理Ctrl+Shift+S全部保存
        if imgui.GetIO().KeyCtrl and imgui.GetIO().KeyShift and imgui.IsKeyPressed(imgui.ImGuiKey.S, false) then
            _save_all_doc()
        end
        -- 处理F5运行调试
        if imgui.IsKeyPressed(imgui.ImGuiKey.F5, false) then
            _run_debug()
        end
    imgui.End()
end

local function on_render(self)
    if window_assets.on_render then window_assets:on_render() end
    if window_console.on_render then window_console:on_render() end
    if window_monitor.on_render then window_monitor:on_render() end
    if window_preview.on_render then window_preview:on_render() end
    if window_settings.on_render then window_settings:on_render() end
    if window_exporter.on_render then window_exporter:on_render() end
    if window_flow_designer.on_render then window_flow_designer:on_render() end
    if window_ui_designer.on_render then window_ui_designer:on_render() end
    if window_style_designer.on_render then window_style_designer:on_render() end
end

module.new = function()
    local o = 
    {
        on_enter = on_enter,
        on_exit = on_exit,
        on_update = on_update,
        on_render = on_render,
    }
    setmetatable(o, Scene.new())
    o.__index = o
    return o
end


return module
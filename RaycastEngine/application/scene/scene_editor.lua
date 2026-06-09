local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI

local Class = require("application.framework.class")
local Scene = require("application.framework.scene")
local EditorResourceDialog = require("application.framework.editor_resource_dialog")
local FlowManager = require("application.framework.flow_manager")
local FlowRuntimeHost = require("application.framework.flow_runtime_host")
local LogManager = require("application.framework.log_manager")
local UndoManager = require("application.framework.undo_manager")
local ModifyManager = require("application.framework.modify_manager")
local GlobalContext = require("application.framework.global_context")
local EditorPreviewInput = require("application.framework.editor_preview_input")
local ResourceHotReload = require("application.framework.resource_hot_reload")
local SettingsManager = require("application.framework.settings_manager")
local EditorThemeManager = require("application.framework.editor_theme_manager")
local ResourcesManager = require("application.framework.resources_manager")
local StyleWorkspaceManager = require("application.framework.style_workspace_manager")
local UIWorkspaceManager = require("application.framework.ui_workspace_manager")

local window_assets = require("application.scene.window.window_assets")
local window_console = require("application.scene.window.window_console")
local window_monitor = require("application.scene.window.window_monitor")
local window_preview = require("application.scene.window.window_preview")
local window_settings = require("application.scene.window.window_settings")
local window_exporter = require("application.scene.window.window_exporter")
local window_ui_designer = require("application.scene.window.window_ui_designer")
local window_save_debugger = require("application.scene.window.window_save_debugger")
local window_flow_designer = require("application.scene.window.window_flow_designer")
local window_story_designer = require("application.scene.window.window_story_designer")
local window_style_designer = require("application.scene.window.window_style_designer")

local flag_window_main_docker <const> = imgui.WindowFlags.NoDocking | imgui.WindowFlags.NoTitleBar | imgui.WindowFlags.MenuBar
    | imgui.WindowFlags.NoCollapse | imgui.WindowFlags.NoResize | imgui.WindowFlags.NoMove | imgui.WindowFlags.NoBringToFrontOnFocus | imgui.WindowFlags.NoNavFocus

local SceneEditor = Class.define("SceneEditor", Scene)
local save_manager_module = false
local active_dock_view_id = "flow"
local pending_editor_save_request = nil

local function _get_save_manager()
    if save_manager_module == false then
        save_manager_module = require("application.framework.save_manager")
    end
    return save_manager_module
end

local function _normalize_active_dock_view_id(view_id)
    return view_id or "flow"
end

local function _resolve_active_dock_view_id()
    if window_story_designer.is_window_focused and window_story_designer.is_window_focused() then
        return "story"
    end
    if window_ui_designer.is_window_focused and window_ui_designer.is_window_focused() then
        return "ui"
    end
    if window_style_designer.is_window_focused and window_style_designer.is_window_focused() then
        return "style"
    end
    if window_save_debugger.is_window_focused and window_save_debugger.is_window_focused() then
        return "save_debugger"
    end
    if GlobalContext.is_flow_designer_window_focused then
        return "flow"
    end
    return _normalize_active_dock_view_id(active_dock_view_id)
end

local function _update_primary_dock_windows(delta)
    local entry_list =
    {
        {id = "ui", run = function() window_ui_designer:on_update(delta) end},
        {id = "style", run = function() window_style_designer:on_update(delta) end},
        {id = "save_debugger", run = function() window_save_debugger:on_update(delta) end},
        {id = "story", run = function() window_story_designer:on_update(delta) end},
        {id = "flow", run = function() window_flow_designer:on_update(delta) end},
    }
    local active_id = _normalize_active_dock_view_id(active_dock_view_id)
    for _, entry in ipairs(entry_list) do
        if entry.id ~= active_id then
            entry.run()
        end
    end
    for _, entry in ipairs(entry_list) do
        if entry.id == active_id then
            entry.run()
            break
        end
    end

    active_dock_view_id = _resolve_active_dock_view_id()
end
local function _get_menu_icon_tint()
    return EditorThemeManager.get_icon_tint_color()
end

local function _menu_with_icon(icon_id, text)
    local height <const> = imgui.GetTextLineHeight()
    local size_icon <const> = imgui.ImVec2(height, height)
    local ok_icon, icon = pcall(ResourcesManager.find_icon, icon_id)
    if ok_icon and icon then
        imgui.Image(icon, size_icon, nil, nil, _get_menu_icon_tint(), nil)
        imgui.SameLine()
    end
    return imgui.BeginMenu(text)
end

local function _menu_item_with_icon(icon_id, text, shortcut, selected, enabled)
    local height <const> = imgui.GetTextLineHeight()
    local size_icon <const> = imgui.ImVec2(height, height)
    local ok_icon, icon = pcall(ResourcesManager.find_icon, icon_id)
    if ok_icon and icon then
        imgui.Image(icon, size_icon, nil, nil, _get_menu_icon_tint(), nil)
        imgui.SameLine()
    end
    return imgui.MenuItem(text, shortcut, selected, enabled == nil and true or enabled)
end

local function _menu_item_font_zoom(zoom)
    if imgui.MenuItem(string.format("%d%%", zoom * 100), nil, SettingsManager.get("editor_zoom_ratio") == zoom) then
        SettingsManager.set("editor_zoom_ratio", zoom)
    end
end

local function _draw_theme_color_menu()
    local current_theme_id = EditorThemeManager.get_current_color_id and EditorThemeManager.get_current_color_id() or EditorThemeManager.get_current_theme_id()
    local previous_group = nil

    for _, preset in ipairs(EditorThemeManager.list_color_presets and EditorThemeManager.list_color_presets() or EditorThemeManager.list_presets()) do
        if previous_group and previous_group ~= preset.menu_group then
            imgui.Separator()
        end

        if imgui.MenuItem(preset.display_name, nil, current_theme_id == preset.id) then
            if EditorThemeManager.set_color then
                EditorThemeManager.set_color(preset.id)
            else
                EditorThemeManager.set_theme(preset.id)
            end
        end

        previous_group = preset.menu_group
    end
end

local function _draw_theme_style_menu()
    local current_style_id = EditorThemeManager.get_current_style_id and EditorThemeManager.get_current_style_id() or ""
    local previous_group = nil

    for _, preset in ipairs(EditorThemeManager.list_style_presets and EditorThemeManager.list_style_presets() or {}) do
        if previous_group and previous_group ~= preset.menu_group then
            imgui.Separator()
        end

        if imgui.MenuItem(preset.display_name, nil, current_style_id == preset.id) then
            EditorThemeManager.set_style(preset.id)
        end

        previous_group = preset.menu_group
    end
end

local function _get_current_flow_document()
    local document = GlobalContext.current_flow_document
    if document and document._is_open and document._is_open.val then
        return document
    end

    if window_story_designer.is_window_focused and window_story_designer.is_window_focused() then
        document = window_story_designer.get_current_document and window_story_designer.get_current_document() or nil
        if document then
            return document
        end
    end

    if GlobalContext.current_blueprint and GlobalContext.current_blueprint._is_open and GlobalContext.current_blueprint._is_open.val then
        return GlobalContext.current_blueprint
    end

    return FlowManager.get_workspace_current_document and FlowManager.get_workspace_current_document() or nil
end

local function _is_flow_document_open(document)
    return document ~= nil
        and document._is_open ~= nil
        and document._is_open.val == true
end

local function _get_debug_focus_document()
    if GlobalContext.is_debug_game then
        return nil
    end

    if GlobalContext.is_flow_designer_window_focused == true then
        local document = FlowManager.get_workspace_current_document and FlowManager.get_workspace_current_document("graph") or nil
        if _is_flow_document_open(document) and document.kind == "graph" then
            return document
        end

        document = GlobalContext.current_blueprint
        if _is_flow_document_open(document) and document.kind == "graph" then
            return document
        end
        return nil
    end

    if window_story_designer.is_window_focused and window_story_designer.is_window_focused() then
        local document = window_story_designer.get_current_document and window_story_designer.get_current_document() or nil
        if _is_flow_document_open(document) and document.kind == "text" then
            return document
        end
    end

    return nil
end

local function _can_run_debug_from_focus()
    return _get_debug_focus_document() ~= nil
end

local function _get_current_blueprint()
    local document = _get_current_flow_document()
    if document and document.kind == "graph" then
        return document
    end
    return nil
end

local function _is_current_blueprint_zoom_guard_protecting()
    local blueprint = _get_current_blueprint()
    return blueprint ~= nil
        and blueprint.is_flow_zoom_guard_protecting
        and blueprint:is_flow_zoom_guard_protecting()
end

local function _run_debug()
    local document = _get_debug_focus_document()
    if not document then
        return
    end

    GlobalContext.is_debug_game = true
    GlobalContext.debug_flow_document = document
    GlobalContext.debug_blueprint = document.kind == "graph" and document or nil
    local ok_session, session_err = pcall(function()
        _get_save_manager().begin_new_session()
    end)
    if not ok_session then
        LogManager.log(string.format("Debug session startup failed: %s", tostring(session_err)), "error")
        if GlobalContext.stop_debug then
            GlobalContext.stop_debug()
        end
        return
    end

    local ok_execute, executed, execute_err = pcall(FlowRuntimeHost.execute, document)
    if not ok_execute then
        LogManager.log(string.format("Debug flow startup failed: %s", tostring(executed)), "error")
        if GlobalContext.stop_debug and GlobalContext.is_debug_game then
            GlobalContext.stop_debug()
        end
        return
    end
    if executed == false then
        LogManager.log(string.format("Debug flow startup failed: %s", tostring(execute_err)), "error")
        if GlobalContext.stop_debug and GlobalContext.is_debug_game then
            GlobalContext.stop_debug()
        end
    end
end

local function _save_all_doc()
    FlowManager.save_all()
    StyleWorkspaceManager.save_all()
    UIWorkspaceManager.save_all()
end

local function _save_current_doc(view_id)
    local normalized_view_id = _normalize_active_dock_view_id(view_id or active_dock_view_id)
    if normalized_view_id == "story" then
        return window_story_designer.save_current_document and window_story_designer.save_current_document()
    end
    if normalized_view_id == "ui" then
        return window_ui_designer.save_current_document and window_ui_designer.save_current_document()
    end
    if normalized_view_id == "style" then
        return window_style_designer.save_current_document and window_style_designer.save_current_document()
    end
    if normalized_view_id == "flow" then
        local document = FlowManager.get_workspace_current_document
            and FlowManager.get_workspace_current_document("graph")
            or GlobalContext.current_blueprint
        if document and document._is_open and document._is_open.val and document.save_document then
            return document:save_document()
        end
    end
    return false
end

local function _execute_editor_save_request(request)
    if type(request) ~= "table" then
        return false
    end
    if request.kind == "all" then
        _save_all_doc()
        return true
    end
    if request.kind == "current" then
        return _save_current_doc(request.view_id)
    end
    return false
end

local function _has_active_input_widget()
    return (imgui.IsAnyItemActive and imgui.IsAnyItemActive())
        or (imgui.IsAnyItemFocused and imgui.IsAnyItemFocused())
end

local function _request_editor_save(kind)
    local request =
    {
        kind = kind,
        view_id = _resolve_active_dock_view_id(),
    }
    if _has_active_input_widget() then
        pending_editor_save_request = request
        if imgui.ClearActiveID then
            imgui.ClearActiveID()
        end
        return true
    end
    return _execute_editor_save_request(request)
end

local function _draw_flow_open_menu(kind)
    for _, document in ipairs(FlowManager.get_all_documents()) do
        if document.kind == kind then
            if _menu_item_with_icon("file-paper-2-line", document._resource_id or document._id, nil, document._is_open.val) then
                if document._is_open.val then
                    FlowManager.close_document_in_workspace(document)
                else
                    if kind == "text" then
                        window_story_designer.open_story_document(document, {select = true})
                    else
                        window_flow_designer.open_flow_document(document, {select = true})
                    end
                end
            end
        end
    end
end

local function _draw_ui_open_menu()
    for _, document in ipairs(UIWorkspaceManager.get_all_documents()) do
        if _menu_item_with_icon("file-paper-2-line", document._resource_id or document._id, nil, document._is_open.val) then
            if document._is_open.val then
                UIWorkspaceManager.close_ui_in_workspace(document)
            else
                UIWorkspaceManager.open_ui_in_workspace(document, {select = true})
            end
        end
    end
end

local function _draw_file_menu()
    if _menu_item_with_icon("flow-chart", "新建流程图脚本") then
        EditorResourceDialog.open_create_resource("flow_graph", "flow", {auto_open = true})
    end

    if _menu_with_icon("folder-open-line", "打开流程图脚本") then
        _draw_flow_open_menu("graph")
        imgui.EndMenu()
    end

    if _menu_item_with_icon("file-paper-2-line", "新建文本剧本") then
        EditorResourceDialog.open_create_resource("story_text", "flow", {auto_open = true})
    end

    if _menu_with_icon("folder-open-line", "打开文本剧本") then
        _draw_flow_open_menu("text")
        imgui.EndMenu()
    end

    if _menu_item_with_icon("layout-3-line", "新建界面设计") then
        EditorResourceDialog.open_create_resource("ui", "ui", {auto_open = true})
    end

    if _menu_with_icon("folder-open-line", "打开界面设计") then
        _draw_ui_open_menu()
        imgui.EndMenu()
    end

    if _menu_item_with_icon("palette-line", "新建样式设计") then
        EditorResourceDialog.open_create_resource("style", "style", {auto_open = true})
    end

    if _menu_with_icon("sketching", "打开样式设计") then
        for _, document in ipairs(StyleWorkspaceManager.get_all_documents()) do
            if _menu_item_with_icon("file-paper-2-line", document._resource_id or document._id, nil, document._is_open.val) then
                if document._is_open.val then
                    StyleWorkspaceManager.close_style_in_workspace(document)
                else
                    window_style_designer.open_style_document(document, {select = true})
                end
            end
        end
        imgui.EndMenu()
    end

    imgui.Separator()
    if _menu_item_with_icon("save-3-fill", "全部保存", "Ctrl+Shift+S") then
        _request_editor_save("all")
    end
end

local function _draw_edit_menu()
    local current_story_document = window_story_designer.get_current_document and window_story_designer.get_current_document() or nil
    local is_story_focused = window_story_designer.is_window_focused and window_story_designer.is_window_focused() or false
    local current_ui_document = window_ui_designer.get_current_document and window_ui_designer.get_current_document() or nil
    local is_ui_focused = window_ui_designer.is_window_focused and window_ui_designer.is_window_focused() or false
    local current_style_document = window_style_designer.get_current_document and window_style_designer.get_current_document() or nil
    local is_style_focused = window_style_designer.is_window_focused and window_style_designer.is_window_focused() or false
    local current_blueprint = _get_current_blueprint()

    local can_edit_story = is_story_focused and current_story_document ~= nil
    local can_edit_ui = is_ui_focused and current_ui_document ~= nil
    local can_edit_style = is_style_focused and current_style_document ~= nil
    local can_edit_flow = current_blueprint ~= nil

    imgui.BeginDisabled(not can_edit_story and not can_edit_ui and not can_edit_style and not can_edit_flow)
        if _menu_item_with_icon("arrow-go-back-fill", "撤销", "Ctrl+Z") then
            if can_edit_story and window_story_designer.undo_current_document then
                window_story_designer.undo_current_document()
            elseif can_edit_ui and window_ui_designer.undo_current_document then
                window_ui_designer.undo_current_document()
            elseif can_edit_style and window_style_designer.undo_current_document then
                window_style_designer.undo_current_document()
            elseif can_edit_flow then
                local previous_modify_context = ModifyManager.get_context()
                local previous_undo_context = UndoManager.get_context()
                ModifyManager.set_context(current_blueprint._modify_context)
                UndoManager.set_context(current_blueprint._undo_context)
                    UndoManager.undo()
                UndoManager.set_context(previous_undo_context)
                ModifyManager.set_context(previous_modify_context)
            end
        end

        if _menu_item_with_icon("arrow-go-forward-fill", "重做", "Ctrl+Y") then
            if can_edit_story and window_story_designer.redo_current_document then
                window_story_designer.redo_current_document()
            elseif can_edit_ui and window_ui_designer.redo_current_document then
                window_ui_designer.redo_current_document()
            elseif can_edit_style and window_style_designer.redo_current_document then
                window_style_designer.redo_current_document()
            elseif can_edit_flow then
                local previous_modify_context = ModifyManager.get_context()
                local previous_undo_context = UndoManager.get_context()
                ModifyManager.set_context(current_blueprint._modify_context)
                UndoManager.set_context(current_blueprint._undo_context)
                    UndoManager.redo()
                UndoManager.set_context(previous_undo_context)
                ModifyManager.set_context(previous_modify_context)
            end
        end
    imgui.EndDisabled()
end

local function _draw_view_menu()
    local blueprint = _get_current_blueprint()

    imgui.BeginDisabled(blueprint == nil)
        if _menu_item_with_icon("git-commit-line", "显示流程动画", nil, GlobalContext.is_show_flow.val) then
            GlobalContext.is_show_flow.val = not GlobalContext.is_show_flow.val
        end
        if _menu_item_with_icon("hashtag", "显示所有节点ID", nil, GlobalContext.is_show_all_node_id.val) then
            GlobalContext.is_show_all_node_id.val = not GlobalContext.is_show_all_node_id.val
        end

        local block_navigate_to_content = _is_current_blueprint_zoom_guard_protecting()
        imgui.BeginDisabled(block_navigate_to_content)
            if _menu_item_with_icon("navigation-fill", "导航到全部内容", "Ctrl+R") then
                imgui.NodeEditor.SetCurrentEditor(blueprint._context)
                imgui.NodeEditor.NavigateToContent()
            end
        imgui.EndDisabled()
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

    if _menu_with_icon("palette-line", "主题") then
        if imgui.BeginMenu("主题样式") then
            _draw_theme_style_menu()
            imgui.EndMenu()
        end
        if imgui.BeginMenu("主题颜色") then
            _draw_theme_color_menu()
            imgui.EndMenu()
        end
        imgui.EndMenu()
    end
end

local function _draw_debug_menu()
    if _menu_item_with_icon("delete-bin-5-fill", "清空控制台") then
        LogManager.clear()
    end

    imgui.BeginDisabled(GlobalContext.is_debug_game or not _can_run_debug_from_focus())
        if _menu_item_with_icon("bug-fill", "从当前流程调试", "F5") then
            _run_debug()
        end
    imgui.EndDisabled()

    if _menu_item_with_icon("timer-flash-line", "显示调试窗口帧率", nil, SettingsManager.get("is_show_debug_fps")) then
        SettingsManager.set("is_show_debug_fps", not SettingsManager.get("is_show_debug_fps"))
    end
end

local function _draw_help_menu()
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
        sdl.ShowSimpleMessageBox(
            sdl.MessageBoxFlags.INFORMATION,
            "关于VoidNovelEngine...",
            string.format([[
VoidNovelEngine 视觉小说引擎
版本号：%s
- By Voidmatrix
            ]], GlobalContext.version),
            GlobalContext.window)
    end
end

local function _on_tick_menu_bar()
    if not imgui.BeginMenuBar() then
        return
    end

    if imgui.BeginMenu(" 文件 ") then
        _draw_file_menu()
        imgui.EndMenu()
    end
    if imgui.BeginMenu(" 编辑 ") then
        _draw_edit_menu()
        imgui.EndMenu()
    end
    if imgui.BeginMenu(" 视图 ") then
        _draw_view_menu()
        imgui.EndMenu()
    end
    if imgui.BeginMenu(" 调试 ") then
        _draw_debug_menu()
        imgui.EndMenu()
    end
    if imgui.BeginMenu(" 帮助 ") then
        _draw_help_menu()
        imgui.EndMenu()
    end

    imgui.EndMenuBar()
end

local function on_enter(self)
    window_assets.on_enter()
    window_console.on_enter()
    window_monitor.on_enter()
    window_preview.on_enter()
    window_settings.on_enter()
    window_flow_designer.on_enter()
    window_story_designer.on_enter()
    window_ui_designer.on_enter()
    window_style_designer.on_enter()
    window_save_debugger.on_enter()
    window_exporter.on_enter()
end

local function on_exit(self)
    if window_assets.on_exit then window_assets.on_exit() end
    if window_console.on_exit then window_console.on_exit() end
    if window_monitor.on_exit then window_monitor.on_exit() end
    if window_preview.on_exit then window_preview.on_exit() end
    if window_settings.on_exit then window_settings.on_exit() end
    if window_flow_designer.on_exit then window_flow_designer.on_exit() end
    if window_story_designer.on_exit then window_story_designer.on_exit() end
    if window_ui_designer.on_exit then window_ui_designer.on_exit() end
    if window_style_designer.on_exit then window_style_designer.on_exit() end
    if window_save_debugger.on_exit then window_save_debugger.on_exit() end
    if window_exporter.on_exit then window_exporter.on_exit() end
end

local function on_update(self, delta)
    ResourceHotReload.update(delta)
    local hot_reload_modal_active = GlobalContext.is_resource_modal_active == true
    EditorPreviewInput.begin_frame()
    local viewport = imgui.GetMainViewport()
    imgui.SetNextWindowPos(viewport.WorkPos)
    imgui.SetNextWindowSize(viewport.WorkSize)
    imgui.SetNextWindowViewport(viewport.ID)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVar(imgui.StyleVar.WindowRounding, 0)
    imgui.Begin("DockerWindow", nil, flag_window_main_docker)
        imgui.PopStyleVar(2)
        imgui.DockSpace(imgui.GetID("MainDockSpace"))
        local menu_modal_active = hot_reload_modal_active or EditorResourceDialog.is_modal_active()
        if menu_modal_active then
            imgui.BeginDisabled(true)
        end
        _on_tick_menu_bar()
        if menu_modal_active then
            imgui.EndDisabled()
        end

        local resource_modal_active = hot_reload_modal_active or EditorResourceDialog.is_modal_active()
        GlobalContext.is_resource_modal_active = resource_modal_active
        if resource_modal_active then
            imgui.BeginDisabled(true)
        end

        window_assets:on_update(delta)
        window_console:on_update(delta)
        window_monitor:on_update(delta)
        window_preview:on_update(delta)
        window_settings:on_update(delta)
        window_exporter:on_update(delta)
        _update_primary_dock_windows(delta)

        local block_editor_shortcuts = EditorPreviewInput.should_block_editor_shortcuts()
        if not resource_modal_active and not block_editor_shortcuts then
            if pending_editor_save_request then
                local request = pending_editor_save_request
                pending_editor_save_request = nil
                _execute_editor_save_request(request)
            end

            local io = imgui.GetIO()
            if io.KeyCtrl and io.KeyShift and imgui.IsKeyPressed(imgui.ImGuiKey.S, false) then
                _request_editor_save("all")
            elseif io.KeyCtrl and not io.KeyShift and imgui.IsKeyPressed(imgui.ImGuiKey.S, false) and _has_active_input_widget() then
                _request_editor_save("current")
            end
            if imgui.IsKeyPressed(imgui.ImGuiKey.F5, false) then
                _run_debug()
            end
        end

        if resource_modal_active then
            imgui.EndDisabled()
        end
    imgui.End()

    EditorResourceDialog.draw_modal()
    ResourceHotReload.draw_modal()
end

local function on_render(self)
    if window_assets.on_render then window_assets:on_render() end
    if window_console.on_render then window_console:on_render() end
    if window_monitor.on_render then window_monitor:on_render() end
    if window_preview.on_render then window_preview:on_render() end
    if window_settings.on_render then window_settings:on_render() end
    if window_exporter.on_render then window_exporter:on_render() end
    if window_flow_designer.on_render then window_flow_designer:on_render() end
    if window_story_designer.on_render then window_story_designer:on_render() end
    if window_ui_designer.on_render then window_ui_designer:on_render() end
    if window_style_designer.on_render then window_style_designer:on_render() end
    if window_save_debugger.on_render then window_save_debugger:on_render() end
end

SceneEditor.on_enter = on_enter
SceneEditor.on_exit = on_exit
SceneEditor.on_update = on_update
SceneEditor.on_render = on_render

return SceneEditor

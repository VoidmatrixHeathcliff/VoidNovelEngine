local module = {}

local rl = Engine.Raylib
local imgui = Engine.ImGUI

local EditorResourceActions = require("application.framework.editor_resource_actions")
local EditorResourceDialog = require("application.framework.editor_resource_dialog")
local EditorThemeManager = require("application.framework.editor_theme_manager")
local FlowManager = require("application.framework.flow_manager")
local GlobalContext = require("application.framework.global_context")
local ImGUIHelper = require("application.framework.imgui_helper")
local NativeIO = require("application.framework.native_io")
local ResourceBrowser = require("application.framework.resource_browser")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local SettingsManager = require("application.framework.settings_manager")
local window_flow_designer = require("application.scene.window.window_flow_designer")
local window_story_designer = require("application.scene.window.window_story_designer")
local window_style_designer = require("application.scene.window.window_style_designer")
local window_ui_designer = require("application.scene.window.window_ui_designer")

local browser_state = nil
local cached_asset_list = {}
local last_view_key = ""
local selected_asset_guid = nil
local asset_list_clipper = nil

local CONTEXT_BLANK_MIN_HEIGHT = 56
local visible_asset_type_pool =
{
    flow = true,
    style = true,
    ui = true,
    save_profile = true,
    texture = true,
    audio = true,
    video = true,
    font = true,
    shader = true,
    file = true,
}

local auto_open_resource_kind_pool =
{
    flow_graph = true,
    story_text = true,
    style = true,
    ui = true,
}

local draggable_asset_type_pool =
{
    texture = true,
    audio = true,
    video = true,
    font = true,
    shader = true,
}

local function _get_style_vec_x(style, field_name, fallback)
    local value = style and style[field_name] or nil
    if value and type(value.x) == "number" then
        return value.x
    end
    return fallback or 0
end

local function _get_image_button_total_width(icon_width)
    local style = imgui.GetStyle()
    return icon_width + _get_style_vec_x(style, "FramePadding", 0) * 2
end

local function _mark_view_dirty()
    last_view_key = ""
end

local function _build_view_key()
    local filter_text = browser_state and browser_state.filter:get() or ""
    local key = tostring(GlobalContext.resource_index_revision) .. "|" .. (browser_state.selected_dir or "") .. "|" .. filter_text
    for _, type_id in ipairs(ResourceBrowser.type_order) do
        local state = browser_state.type_filter_pool[type_id]
        key = key .. "|" .. type_id .. ":" .. tostring(state and state.val)
    end
    return key
end

local function _rebuild_visible_asset_list()
    local view_key = _build_view_key()
    if view_key == last_view_key then
        return
    end
    last_view_key = view_key
    cached_asset_list = ResourceBrowser.collect_visible_assets(browser_state, {allowed_types = visible_asset_type_pool})
end

local function _apply_dialog_result()
    local result = EditorResourceDialog.consume_last_result()
    if not result then
        return
    end

    if result.kind == "directory" then
        browser_state.selected_dir = result.relative_dir or ""
        selected_asset_guid = nil
    elseif result.kind == "resource" then
        local meta = result.guid and ResourceIndex.find_by_guid(result.guid) or nil
        if meta then
            browser_state.selected_dir = meta.relative_dir or ""
            selected_asset_guid = meta.guid
        else
            browser_state.selected_dir = result.relative_dir or browser_state.selected_dir
            selected_asset_guid = result.guid or nil
        end
    end

    _mark_view_dirty()
end

local function _focus_flow_asset(meta)
    local document = FlowManager.get_document(meta.guid, "flow_document_open")
    if not document then
        return
    end

    if document.kind == "text" then
        window_story_designer.open_story_document(document, {select = true})
        return
    end

    local opened_document = window_flow_designer.open_flow_document(document, {select = true})
    if opened_document and opened_document._context then
        imgui.NodeEditor.SetCurrentEditor(opened_document._context)
        imgui.NodeEditor.NavigateToContent()
    end
end

local function _open_asset(meta)
    if meta.type == "flow" then
        _focus_flow_asset(meta)
        return
    end

    if meta.type == "style" then
        window_style_designer.open_style_document(meta.guid, {select = true})
        return
    end

    if meta.type == "ui" then
        window_ui_designer.open_ui_document(meta.guid, {select = true})
        return
    end

    if meta.path then
        NativeIO.open_path_or_url(meta.path)
    end
end

local function _handle_asset_activation(meta, is_double_click)
    selected_asset_guid = meta.guid
    if is_double_click then
        _open_asset(meta)
    end
end

local function _draw_file_create_submenu(relative_dir)
    local activated = false
    if not imgui.BeginMenu("新建") then
        return false
    end

    for _, definition in ipairs(EditorResourceActions.list_resource_kind_entries()) do
        if imgui.MenuItem(definition.display_name) then
            EditorResourceDialog.open_create_resource(definition.kind, relative_dir,
                {auto_open = auto_open_resource_kind_pool[definition.kind] == true})
            activated = true
        end
    end

    imgui.EndMenu()
    return activated
end

local function _draw_asset_context_popup(meta)
    local popup_id = string.format("asset_item_context_%s", meta.guid)
    if imgui.IsItemHovered() and imgui.IsMouseReleased(1) then
        selected_asset_guid = meta.guid
        imgui.OpenPopup(popup_id)
    end

    if imgui.BeginPopup(popup_id) then
        if imgui.MenuItem("打开") then
            _open_asset(meta)
            imgui.CloseCurrentPopup()
        end
        imgui.Separator()
        if imgui.MenuItem("重命名") then
            EditorResourceDialog.open_rename_resource(meta.guid, {auto_open = false})
            imgui.CloseCurrentPopup()
        end
        if imgui.MenuItem("删除") then
            EditorResourceDialog.open_delete_resource(meta.guid, {auto_open = false})
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end
end

local function _draw_asset_item(meta, editor_zoom_ratio)
    local pos = imgui.GetCursorPos()
    local selected = selected_asset_guid == meta.guid
    local selectable_flags = imgui.SelectableFlags.SpanAllColumns | imgui.SelectableFlags.AllowDoubleClick
    local activated = imgui.Selectable(string.format("##asset_%s", meta.guid), selected, selectable_flags)
    if activated then
        _handle_asset_activation(meta, imgui.IsMouseDoubleClicked(0))
    end
    _draw_asset_context_popup(meta)

    if draggable_asset_type_pool[meta.type] and imgui.BeginDragDropSource() then
        imgui.SetDragDropPayload("asset",
        {
            guid = meta.guid,
            id = meta.id,
            qualified_id = meta.qualified_id,
            type = meta.type,
            display_name = meta.display_name,
            relative_path = meta.relative_path,
            path = meta.path,
        })
        imgui.SetTooltip("拖拽以创建资源节点或为对应类型引脚赋值")
        imgui.EndDragDropSource()
    end

    ResourceBrowser.handle_asset_hover_preview(meta,
    {
        editor_zoom_ratio = editor_zoom_ratio,
        show_editor_open_hint = true,
    })

    imgui.SetCursorPos(pos)
    local style = imgui.GetStyle()
    local max_label_width = math.max(
        80,
        imgui.GetContentRegionAvail().x - imgui.GetTextLineHeight() - _get_style_vec_x(style, "ItemSpacing", 8) - 8)
    ResourceBrowser.draw_asset_label(meta,
    {
        display_name = meta.file_name or meta.relative_path or meta.display_name or meta.id,
        max_text_width = max_label_width,
    })
end

local function _get_scope_text()
    return ResourceBrowser.get_scope_text(browser_state, "resources")
end

local function _draw_directory_context_menu(node, relative_path, is_root)
    local popup_id = string.format("asset_dir_context_%s", relative_path == "" and "__root__" or relative_path)
    if imgui.IsItemHovered() and imgui.IsMouseReleased(1) then
        browser_state.selected_dir = relative_path or ""
        selected_asset_guid = nil
        _mark_view_dirty()
        imgui.OpenPopup(popup_id)
    end

    if imgui.BeginPopup(popup_id) then
        if imgui.MenuItem("新建文件夹") then
            EditorResourceDialog.open_create_folder(relative_path or "", {auto_open = false})
            imgui.CloseCurrentPopup()
        end
        if not is_root and imgui.MenuItem("重命名文件夹") then
            EditorResourceDialog.open_rename_directory(relative_path, {auto_open = false})
            imgui.CloseCurrentPopup()
        end
        if not is_root and imgui.MenuItem("删除") then
            EditorResourceDialog.open_delete_directory(relative_path, {auto_open = false})
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end
end

local function _draw_asset_list_context_menu()
    local popup_id = "asset_list_context_menu"
    if imgui.BeginPopup(popup_id) then
        if _draw_file_create_submenu(browser_state and browser_state.selected_dir or "") then
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end
end

local function _draw_directory_blank_context_menu(editor_zoom_ratio)
    local popup_id = "asset_tree_blank_context_menu"
    local blank_height = math.max(CONTEXT_BLANK_MIN_HEIGHT, math.floor(CONTEXT_BLANK_MIN_HEIGHT * (editor_zoom_ratio or 1) + 0.5))
    local content_region = imgui.GetContentRegionAvail()
    local host_size = imgui.ImVec2(math.max(1, content_region.x), math.max(blank_height, content_region.y))
    imgui.InvisibleButton("##asset_tree_blank_hitbox", host_size)
    if imgui.IsItemHovered() and imgui.IsMouseReleased(1) then
        browser_state.selected_dir = ""
        selected_asset_guid = nil
        _mark_view_dirty()
        imgui.OpenPopup(popup_id)
    end

    if imgui.BeginPopup(popup_id) then
        if imgui.MenuItem("新建文件夹") then
            EditorResourceDialog.open_create_folder("", {auto_open = false})
            imgui.CloseCurrentPopup()
        end
        imgui.EndPopup()
    end
end

local function _draw_asset_list_blank_context_menu(editor_zoom_ratio)
    local popup_id = "asset_list_context_menu"
    local blank_height = math.max(CONTEXT_BLANK_MIN_HEIGHT, math.floor(CONTEXT_BLANK_MIN_HEIGHT * (editor_zoom_ratio or 1) + 0.5))
    local content_region = imgui.GetContentRegionAvail()
    local host_size = imgui.ImVec2(math.max(1, content_region.x), math.max(blank_height, content_region.y))
    imgui.InvisibleButton("##asset_list_blank_hitbox", host_size)
    if imgui.IsItemHovered() and imgui.IsMouseReleased(1) then
        imgui.OpenPopup(popup_id)
    end
    _draw_asset_list_context_menu()
end

module.on_enter = function()
    browser_state = ResourceBrowser.create_state()
    cached_asset_list = {}
    last_view_key = ""
    selected_asset_guid = nil
    asset_list_clipper = imgui.ListClipper()
end

module.on_exit = function()
    ResourceBrowser.stop_hover_preview()
end

module.on_update = function(self, delta)
    _apply_dialog_result()

    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")

    local is_open = imgui.Begin("资产视图")
    if is_open then
        local style = imgui.GetStyle()
        local filter_icon_width = 18 * editor_zoom_ratio
        local filter_button_width = _get_image_button_total_width(filter_icon_width)
        local filter_button_reserve = filter_button_width + _get_style_vec_x(style, "ItemSpacing", 8)

        imgui.Text("筛选资产：")
        imgui.SameLine()
        local available_after_label = imgui.GetContentRegionAvail().x
        local keep_filter_button_same_line = available_after_label >= 140 + filter_button_reserve
        local filter_width = keep_filter_button_same_line
            and math.max(140, available_after_label - filter_button_reserve)
            or math.max(80, available_after_label)
        imgui.SetNextItemWidth(filter_width)
        imgui.InputText("##filter_assets", browser_state.filter)
        if keep_filter_button_same_line then
            imgui.SameLine()
        end
        if imgui.ImageButton("asset_filter", ResourcesManager.find_icon("filter-2-line"),
            imgui.ImVec2(filter_icon_width, filter_icon_width), nil, nil, nil, EditorThemeManager.get_icon_tint_color()) then
            imgui.OpenPopup("popup_filter_type")
        end
        ImGUIHelper.HoveredTooltip("筛选资源类型")

        if imgui.BeginPopup("popup_filter_type") then
            for _, type_id in ipairs(ResourceBrowser.type_order) do
                imgui.Checkbox(ResourceBrowser.get_type_label(type_id), browser_state.type_filter_pool[type_id])
            end
            imgui.EndPopup()
        end

        imgui.Columns(2, "asset_browser_columns", true)
        if not browser_state.is_layout_initialized or browser_state.layout_zoom_ratio ~= editor_zoom_ratio then
            imgui.SetColumnWidth(0, 260 * editor_zoom_ratio)
            browser_state.is_layout_initialized = true
            browser_state.layout_zoom_ratio = editor_zoom_ratio
        end

        local asset_tree_style = nil
        if ImGUIHelper.ShouldUseInHThemeCompensation() then
            asset_tree_style = ImGUIHelper.PushCompactTreeStyle(editor_zoom_ratio,
            {
                include_window_padding = true,
                item_spacing_x = 4,
                indent_spacing = 21,
            })
        end
        imgui.BeginChild("asset_tree", imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
            local tree_options = ResourceBrowser.get_default_folder_draw_options()
            tree_options.root_label = "resources"
            tree_options.indent_spacing = math.max(21, math.floor(21 * editor_zoom_ratio + 0.5))
            tree_options.allowed_types = visible_asset_type_pool
            tree_options.on_directory_item = _draw_directory_context_menu
            ResourceBrowser.draw_directory_tree(browser_state, tree_options)
            _draw_directory_blank_context_menu(editor_zoom_ratio)
        imgui.EndChild()
        if asset_tree_style then
            ImGUIHelper.PopCompactTreeStyle(asset_tree_style)
        end

        imgui.NextColumn()

        imgui.BeginChild("asset_list", imgui.ImVec2(0, 0), imgui.ChildFlags.Borders)
            _rebuild_visible_asset_list()

            local scope_text = _get_scope_text()
            local scope_width = imgui.GetContentRegionAvail().x
            imgui.TextDisabled(ImGUIHelper.EllipsisTail(scope_text, math.max(80, scope_width)))
            ImGUIHelper.HoveredTooltip(scope_text)
            imgui.Separator()

            asset_list_clipper:Begin(#cached_asset_list)
            while asset_list_clipper:Step() do
                local display_start = asset_list_clipper:GetDisplayStart() + 1
                local display_end = asset_list_clipper:GetDisplayEnd()
                for index = display_start, display_end do
                    local meta = cached_asset_list[index]
                    if meta then
                        _draw_asset_item(meta, editor_zoom_ratio)
                    end
                end
            end
            asset_list_clipper:End()

            if #cached_asset_list == 0 then
                imgui.TextDisabled("当前筛选条件下没有匹配资源")
            end

            _draw_asset_list_blank_context_menu(editor_zoom_ratio)
        imgui.EndChild()

        imgui.Columns(1)
    end
    imgui.End()

    if is_open then
        ResourceBrowser.finish_hover_preview_frame()
    else
        ResourceBrowser.stop_hover_preview()
    end
end

return module

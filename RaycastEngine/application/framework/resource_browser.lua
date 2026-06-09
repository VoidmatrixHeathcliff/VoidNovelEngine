local sdl = Engine.SDL
local util = Engine.Util
local rl = Engine.Raylib
local imgui = Engine.ImGUI

local AudioPlaybackManager = require("application.framework.audio_playback_manager")
local ColorHelper = require("application.framework.color_helper")
local ImGUIHelper = require("application.framework.imgui_helper")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")

local module = {}

local DEFAULT_TREE_INDENT_SPACING <const> = 21
local HOVER_PREVIEW_GRACE_SECONDS <const> = 0.08
local DEFAULT_FOLDER_TINT = imgui.ImColor(232, 194, 73, 255):to_u32()
local MIN_FOLDER_ICON_ARROW_GAP <const> = 4

local default_folder_draw_options = nil
local asset_icon_pool = {}
local preview_audio_token = nil
local preview_audio_guid = nil
local hovered_audio_guid = nil
local last_audio_hover_time = -1
local preview_texture_ticket = nil
local preview_texture_guid = nil
local hovered_texture_guid = nil
local last_texture_hover_time = -1

module.type_order =
{
    "flow",
    "style",
    "ui",
    "save_profile",
    "texture",
    "audio",
    "video",
    "font",
    "shader",
    "file",
}

local type_meta_pool =
{
    flow = {label = "流程", icon_id = "flow-chart"},
    style = {label = "样式", icon_id = "palette-line"},
    ui = {label = "界面", icon_id = "layout-3-line"},
    save_profile = {label = "存档配置", icon_id = "save-3-fill"},
    texture = {label = "纹理", icon_id = "image-fill"},
    audio = {label = "音频", icon_id = "headphone-fill"},
    video = {label = "视频", icon_id = "movie-2-fill"},
    font = {label = "字体", icon_id = "font-size"},
    shader = {label = "着色器", icon_id = "paint-brush-fill"},
    file = {label = "文件", icon_id = "file-paper-2-line"},
}

local function _to_lower(text)
    if type(text) ~= "string" then
        return ""
    end
    return string.lower(text)
end

local function _normalize_allowed_types(allowed_types)
    if type(allowed_types) == "string" then
        return {[allowed_types] = true}
    end
    return allowed_types
end

local function _starts_with(text, prefix)
    return type(text) == "string"
        and type(prefix) == "string"
        and text:sub(1, #prefix) == prefix
end

local function _find_tree_node(root, relative_path)
    if not root or not relative_path or relative_path == "" then
        return root
    end

    local node = root
    for part in string.gmatch(relative_path, "[^/]+") do
        if not node.children_by_name then
            return nil
        end
        node = node.children_by_name[part]
        if not node then
            return nil
        end
    end
    return node
end

local function _is_selected_branch(state, relative_path)
    local selected_dir = state and state.selected_dir or ""
    if selected_dir == "" then
        return relative_path == ""
    end
    if relative_path == "" then
        return true
    end
    return selected_dir == relative_path or _starts_with(selected_dir, relative_path .. "/")
end

local function _matches_type(state, meta, allowed_types)
    local allowed_pool = _normalize_allowed_types(allowed_types)
    if allowed_pool and not allowed_pool[meta.type] then
        return false
    end

    local filter_state = state.type_filter_pool and state.type_filter_pool[meta.type]
    if filter_state and not filter_state.val then
        return false
    end
    return true
end

local function _asset_matches(state, meta, allowed_types)
    if not _matches_type(state, meta, allowed_types) then
        return false
    end

    local filter = _to_lower(state.filter and state.filter:get() or "")
    if filter == "" then
        return true
    end

    local search_text = _to_lower(string.format("%s %s %s %s",
        meta.relative_path or "",
        meta.id or "",
        meta.display_name or "",
        meta.type or ""))

    return string.find(search_text, filter, 1, true) ~= nil
end

local function _node_text_matches_filter(state, node)
    local filter = _to_lower(module.get_filter_text(state))
    if filter == "" then
        return true
    end

    local search_text = _to_lower(string.format("%s %s",
        node and node.name or "",
        node and node.relative_path or ""))
    return string.find(search_text, filter, 1, true) ~= nil
end

local function _node_has_allowed_asset(state, node, allowed_types)
    if not node then
        return false
    end
    if allowed_types == nil then
        return true
    end

    for _, meta in ipairs(node.asset_list or {}) do
        if _matches_type(state, meta, allowed_types) then
            return true
        end
    end

    for _, child in ipairs(node.children or {}) do
        if _node_has_allowed_asset(state, child, allowed_types) then
            return true
        end
    end

    return false
end

local function _node_has_match(state, node, allowed_types, options)
    if not node then
        return false
    end

    if options and options.hide_dirs_without_allowed_assets == true
        and not _node_has_allowed_asset(state, node, allowed_types) then
        return false
    end

    if module.get_filter_text(state) == "" then
        return true
    end

    if _node_text_matches_filter(state, node) then
        return true
    end

    for _, meta in ipairs(node.asset_list or {}) do
        if _asset_matches(state, meta, allowed_types) then
            return true
        end
    end

    for _, child in ipairs(node.children or {}) do
        if _node_has_match(state, child, allowed_types, options) then
            return true
        end
    end

    return false
end

local function _collect_subtree_assets(result, state, node, allowed_types)
    for _, meta in ipairs(node.asset_list or {}) do
        if _asset_matches(state, meta, allowed_types) then
            table.insert(result, meta)
        end
    end

    for _, child in ipairs(node.children or {}) do
        _collect_subtree_assets(result, state, child, allowed_types)
    end
end

local function _resolve_folder_icon(options, is_selected, is_open)
    if not options then
        return nil
    end

    if is_open then
        if is_selected then
            return options.folder_icon_open_selected or options.folder_icon_open or options.folder_icon_closed_selected or options.folder_icon_closed
        end
        return options.folder_icon_open or options.folder_icon_open_selected or options.folder_icon_closed or options.folder_icon_closed_selected
    end

    if is_selected then
        return options.folder_icon_closed_selected or options.folder_icon_closed or options.folder_icon_open_selected or options.folder_icon_open
    end
    return options.folder_icon_closed or options.folder_icon_closed_selected or options.folder_icon_open or options.folder_icon_open_selected
end

local function _ensure_default_folder_draw_options()
    if default_folder_draw_options then
        return default_folder_draw_options
    end

    default_folder_draw_options =
    {
        folder_icon_closed = ResourcesManager.find_icon("folder-6-line"),
        folder_icon_closed_selected = ResourcesManager.find_icon("folder-6-fill"),
        folder_icon_open = ResourcesManager.find_icon("folder-open-line"),
        folder_icon_open_selected = ResourcesManager.find_icon("folder-open-fill"),
        folder_tint = DEFAULT_FOLDER_TINT,
    }
    return default_folder_draw_options
end

local function _merge_folder_draw_options(options)
    local merged = {}
    local defaults = _ensure_default_folder_draw_options()
    for key, value in pairs(defaults) do
        merged[key] = value
    end
    for key, value in pairs(options or {}) do
        merged[key] = value
    end
    return merged
end

local function _get_asset_icon(type_id)
    local cached = asset_icon_pool[type_id]
    if cached ~= nil then
        return cached
    end

    local icon = ResourcesManager.find_icon(module.get_type_icon_id(type_id))
    asset_icon_pool[type_id] = icon or false
    return icon
end

local function _stop_audio_preview()
    if preview_audio_token then
        AudioPlaybackManager.stop(preview_audio_token, 0)
        preview_audio_token = nil
        preview_audio_guid = nil
    end
    last_audio_hover_time = -1
end

local function _clear_finished_audio_preview()
    if preview_audio_token and not AudioPlaybackManager.is_active(preview_audio_token) then
        preview_audio_token = nil
        preview_audio_guid = nil
    end
end

local function _start_audio_preview(meta)
    if not meta or not meta.guid then
        return
    end

    local hover_time = last_audio_hover_time
    _stop_audio_preview()
    last_audio_hover_time = hover_time
    local audio = ResourcesManager.get_audio_asset(meta.guid, "asset_hover_preview")
    if not audio then
        return
    end

    preview_audio_token = AudioPlaybackManager.play_preview(audio)
    if preview_audio_token then
        preview_audio_guid = meta.guid
    end
end

local function _release_texture_preview()
    if preview_texture_ticket then
        ResourcesManager.release_keepalive(preview_texture_ticket)
        preview_texture_ticket = nil
    end
    preview_texture_guid = nil
    last_texture_hover_time = -1
end

local function _ensure_texture_preview(meta)
    if not meta or not meta.guid then
        return nil
    end

    if preview_texture_guid ~= meta.guid then
        local hover_time = last_texture_hover_time
        _release_texture_preview()
        last_texture_hover_time = hover_time
        preview_texture_ticket = ResourcesManager.acquire_keepalive(meta.guid, "asset_hover_preview", "editor_preview", "texture")
        preview_texture_guid = meta.guid
    end
    return ResourcesManager.get_texture_preview(meta.guid, "asset_hover_preview")
end

local function _draw_texture_preview(texture, editor_zoom_ratio)
    local texture_info = sdl.QueryTexture(texture)
    local preview_width = math.max(200, 240 * (editor_zoom_ratio or 1))
    local preview_height = math.max(100, 120 * (editor_zoom_ratio or 1))
    local child_size = imgui.ImVec2(preview_width, preview_height)
    local scale = math.min(child_size.x / texture_info.w, child_size.y / texture_info.h)
    local size_image = imgui.ImVec2(texture_info.w * scale, texture_info.h * scale)

    imgui.BeginChild(string.format("texture_preview_%s", tostring(texture)), child_size)
        local pos_begin = imgui.GetCursorPos()
        imgui.SetCursorPos(imgui.ImVec2(
            pos_begin.x + (child_size.x - size_image.x) / 2,
            pos_begin.y + (child_size.y - size_image.y) / 2))
        imgui.Image(texture, size_image, nil, nil, nil, nil)
    imgui.EndChild()
end

local function _get_editor_open_hint_text(meta)
    if not meta then
        return nil
    end

    local ext = _to_lower(meta and meta.ext or "")
    if meta.type == "flow" then
        if ext == ".vns" then
            return "双击打开剧本"
        end
        if ext == ".flow" then
            return "双击打开流程"
        end
        return "双击打开资源"
    end

    if meta.type == "style" then
        return "双击打开样式"
    end

    if meta.type == "ui" then
        return "双击打开界面"
    end

    return nil
end

local function _draw_asset_tooltip(meta, options)
    options = options or {}
    local show_editor_open_hint = options.show_editor_open_hint == true or options.show_flow_open_hint == true
    local editor_zoom_ratio = options.editor_zoom_ratio or 1
    local alt_pressed = imgui.GetIO().KeyAlt == true
    local editor_open_hint_text = nil

    if show_editor_open_hint then
        editor_open_hint_text = _get_editor_open_hint_text(meta)
    end

    imgui.BeginTooltip()
        imgui.TextDisabled(meta.relative_path or meta.file_name or "")

        if editor_open_hint_text then
            imgui.Separator()
            imgui.TextDisabled(editor_open_hint_text)
        elseif meta.type == "texture" then
            imgui.Separator()
            if alt_pressed then
                local texture = _ensure_texture_preview(meta)
                if texture then
                    _draw_texture_preview(texture, editor_zoom_ratio)
                else
                    imgui.TextDisabled("无法预览纹理")
                end
            else
                imgui.TextDisabled("按住左Alt以预览纹理")
            end
        elseif meta.type == "audio" then
            imgui.Separator()
            if alt_pressed then
                imgui.TextDisabled("松开左Alt以停止试听音频")
            else
                imgui.TextDisabled("按住左Alt以试听音频")
            end
        end
    imgui.EndTooltip()
end

local function _get_tree_node_label_spacing()
    if type(imgui.GetTreeNodeToLabelSpacing) == "function" then
        return imgui.GetTreeNodeToLabelSpacing()
    end

    local style = imgui.GetStyle()
    local item_inner_spacing = style and style.ItemInnerSpacing and tonumber(style.ItemInnerSpacing.x) or 4
    return imgui.GetTextLineHeight() + item_inner_spacing
end

local function _draw_folder_row_content(options, line_start, item_min, item_max, display_name, is_selected, is_open)
    local draw_list = imgui.GetWindowDrawList()
    if not draw_list then
        return
    end

    local style = imgui.GetStyle()
    local icon = _resolve_folder_icon(options, is_selected, is_open)
    local icon_size = imgui.GetTextLineHeight()
    local item_inner_spacing = style and style.ItemInnerSpacing and tonumber(style.ItemInnerSpacing.x) or 4
    local gap = math.max(4, item_inner_spacing)
    local label_x = line_start.x + _get_tree_node_label_spacing()
    local arrow_icon_gap = tonumber(options.folder_icon_arrow_gap) or MIN_FOLDER_ICON_ARROW_GAP
    label_x = label_x + math.max(0, arrow_icon_gap)
    local content_y = item_min.y + math.max(0, (item_max.y - item_min.y - icon_size) * 0.5)
    local text_x = label_x

    if icon then
        local tint = options.folder_tint or imgui.ImColor(255, 255, 255, 255):to_u32()
        local icon_pos = imgui.ImVec2(label_x, content_y)
        draw_list:AddImage(icon, icon_pos, imgui.ImVec2(icon_pos.x + icon_size, icon_pos.y + icon_size), nil, nil, tint)
        text_x = label_x + icon_size + gap
    end

    local text_color = imgui.ImColor(imgui.GetStyleColor(imgui.ImGuiCol.Text)):to_u32()
    draw_list:AddText(imgui.ImVec2(text_x, content_y), text_color, display_name)
end

local function _draw_tree_node(state, node, relative_path, display_name, allowed_types, options, is_root)
    local has_children = node.children and #node.children > 0
    local is_selected = state.selected_dir == relative_path
    local flags = imgui.TreeNodeFlags.OpenOnArrow | imgui.TreeNodeFlags.OpenOnDoubleClick | imgui.TreeNodeFlags.SpanFullWidth
    local node_id = relative_path == "" and "__root__" or relative_path

    if not has_children then
        flags = flags | imgui.TreeNodeFlags.Leaf | imgui.TreeNodeFlags.NoTreePushOnOpen
    end

    if is_root or _is_selected_branch(state, relative_path) then
        flags = flags | imgui.TreeNodeFlags.DefaultOpen
    end

    if is_selected then
        flags = flags | imgui.TreeNodeFlags.Selected
    end

    local line_start = imgui.GetCursorScreenPos()
    local opened = imgui.TreeNode(string.format("##dir_%s", node_id), flags)
    local changed = false
    local item_min = imgui.GetItemRectMin()
    local item_max = imgui.GetItemRectMax()
    if imgui.IsItemClicked() then
        state.selected_dir = relative_path
        changed = true
    end
    if options.on_directory_item then
        options.on_directory_item(node, relative_path, is_root)
    end
    _draw_folder_row_content(options, line_start, item_min, item_max, display_name, is_selected, opened and has_children)

    if opened and has_children then
        for _, child in ipairs(node.children or {}) do
            if _node_has_match(state, child, allowed_types, options) then
                if _draw_tree_node(state, child, child.relative_path, child.name, allowed_types, options, false) then
                    changed = true
                end
            end
        end
        imgui.TreePop()
    end

    return changed
end

module.create_state = function()
    local state =
    {
        filter = util.CString(),
        selected_dir = "",
        type_filter_pool = {},
        is_layout_initialized = false,
        layout_zoom_ratio = nil,
    }

    for _, type_id in ipairs(module.type_order) do
        state.type_filter_pool[type_id] = imgui.Bool(true)
    end

    return state
end

module.get_type_meta = function(type_id)
    return type_meta_pool[type_id]
end

module.get_type_icon_id = function(type_id)
    local meta = type_meta_pool[type_id]
    return meta and meta.icon_id or "file-paper-2-line"
end

module.get_type_label = function(type_id)
    local meta = type_meta_pool[type_id]
    return meta and meta.label or type_id
end

module.find_tree_node = function(relative_path)
    return _find_tree_node(ResourceIndex.get_tree(), relative_path)
end

module.get_filter_text = function(state)
    if not state or not state.filter or not state.filter.get then
        return ""
    end
    return state.filter:get() or ""
end

module.is_filtering = function(state)
    return module.get_filter_text(state) ~= ""
end

module.get_selection_display_path = function(state, root_label)
    local display_root = root_label or "resources"
    if not state or not state.selected_dir or state.selected_dir == "" then
        return display_root
    end
    return string.format("%s/%s", display_root, state.selected_dir)
end

module.get_scope_text = function(state, root_label)
    local filter_text = module.get_filter_text(state)
    if filter_text ~= "" then
        return string.format("筛选：%s", filter_text)
    end
    return string.format("路径：%s", module.get_selection_display_path(state, root_label))
end

module.get_default_folder_draw_options = function()
    return _merge_folder_draw_options()
end

module.draw_asset_label = function(meta, options)
    options = options or {}

    local display_name = options.display_name or meta.file_name or meta.relative_path or meta.display_name or meta.id
    local max_text_width = options.max_text_width
    if max_text_width and max_text_width > 0 then
        display_name = ImGUIHelper.EllipsisTail(display_name, max_text_width)
    end

    local size_icon = imgui.ImVec2(imgui.GetTextLineHeight(), imgui.GetTextLineHeight())
    local icon = _get_asset_icon(meta.type)
    local tint = ColorHelper.AssetTypeColorPool[meta.type] or ColorHelper.IMGUI_WHITE

    if icon and icon ~= false then
        imgui.Image(icon, size_icon, nil, nil, tint, nil)
        imgui.SameLine()
    end
    imgui.Text(display_name)
end

module.handle_asset_hover_preview = function(meta, options)
    if not imgui.IsItemHovered() then
        return false
    end

    local alt_pressed = imgui.GetIO().KeyAlt == true
    if meta.type == "audio" then
        if alt_pressed then
            hovered_audio_guid = meta.guid
            last_audio_hover_time = rl.GetTime()
            _clear_finished_audio_preview()
            if preview_audio_guid ~= meta.guid or not preview_audio_token then
                _start_audio_preview(meta)
            end
        end
    elseif meta.type == "texture" and alt_pressed then
        hovered_texture_guid = meta.guid
        last_texture_hover_time = rl.GetTime()
    end

    _draw_asset_tooltip(meta, options)
    return true
end

module.finish_hover_preview_frame = function()
    local now = rl.GetTime()
    _clear_finished_audio_preview()
    local audio_hover_stale = hovered_audio_guid ~= preview_audio_guid
        and (last_audio_hover_time < 0 or now - last_audio_hover_time > HOVER_PREVIEW_GRACE_SECONDS)
    if preview_audio_token and (imgui.GetIO().KeyAlt ~= true or audio_hover_stale) then
        _stop_audio_preview()
    end
    local texture_hover_stale = hovered_texture_guid ~= preview_texture_guid
        and (last_texture_hover_time < 0 or now - last_texture_hover_time > HOVER_PREVIEW_GRACE_SECONDS)
    if imgui.GetIO().KeyAlt ~= true or texture_hover_stale then
        _release_texture_preview()
    end
    hovered_audio_guid = nil
    hovered_texture_guid = nil
end

module.stop_hover_preview = function()
    _stop_audio_preview()
    _release_texture_preview()
    hovered_audio_guid = nil
    hovered_texture_guid = nil
end

module.collect_visible_assets = function(state, options)
    options = options or {}
    local root = ResourceIndex.get_tree()
    if not root then
        return {}
    end

    local result = {}
    local filter = _to_lower(module.get_filter_text(state))

    if filter ~= "" then
        _collect_subtree_assets(result, state, root, options.allowed_types)
        table.sort(result, function(left, right)
            return left.relative_path < right.relative_path
        end)
        return result
    end

    local target_node = _find_tree_node(root, state.selected_dir) or root
    for _, meta in ipairs(target_node.asset_list or {}) do
        if _asset_matches(state, meta, options.allowed_types) then
            table.insert(result, meta)
        end
    end

    table.sort(result, function(left, right)
        return (left.file_name or left.relative_path) < (right.file_name or right.relative_path)
    end)

    return result
end

module.draw_directory_tree = function(state, options)
    options = _merge_folder_draw_options(options)
    local root = ResourceIndex.get_tree()
    if not root then
        imgui.TextDisabled("暂无资源目录")
        return false
    end

    local root_label = options.root_label or "resources"
    local indent_spacing = tonumber(options.indent_spacing) or DEFAULT_TREE_INDENT_SPACING
    local pushed_indent_spacing = false
    if indent_spacing > 0 and imgui.StyleVar and imgui.StyleVar.IndentSpacing then
        imgui.PushStyleVar(imgui.StyleVar.IndentSpacing, indent_spacing)
        pushed_indent_spacing = true
    end

    local changed = _draw_tree_node(state, root, "", root_label, options.allowed_types, options, true)

    if pushed_indent_spacing then
        imgui.PopStyleVar()
    end
    return changed
end

return module

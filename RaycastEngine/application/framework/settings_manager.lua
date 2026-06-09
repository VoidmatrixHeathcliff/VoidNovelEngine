local module = {}

local rl = Engine.Raylib
local util = Engine.Util

local ProjectFile = require("application.framework.project_file")
local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")
local EditorThemePresets = require("application.framework.editor_theme_presets")

local LogManager = nil
local load_failure_protection = nil

local file_path = "project.vne"
local default_icon_path = "application/resources/texture/icon.png"
local story_text_zoom_ratio_list = {0.50, 0.75, 1.00, 1.25, 1.50, 2.00}
local fixed_save_subdirectory_name <const> = "save"
local fixed_save_pretty_json <const> = true

local function _reset_runtime_slices(reason)
    local ok, SnapshotCoordinator = pcall(require, "application.framework.snapshot_coordinator")
    if ok and SnapshotCoordinator and SnapshotCoordinator.reset_runtime_slices then
        SnapshotCoordinator.reset_runtime_slices(reason)
    end
end

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local clone = {}
    for key, item in pairs(value) do
        clone[key] = _clone_value(item)
    end
    return clone
end

local function _normalize_open_flow_guid_list(list)
    local normalized_list = {}
    local guid_pool = {}
    if type(list) ~= "table" then
        return normalized_list
    end

    for _, guid in ipairs(list) do
        if type(guid) == "string" and guid ~= "" and not guid_pool[guid] then
            guid_pool[guid] = true
            table.insert(normalized_list, guid)
        end
    end

    return normalized_list
end

local function _normalize_open_style_guid_list(list)
    local normalized_list = {}
    local guid_pool = {}
    if type(list) ~= "table" then
        return normalized_list
    end

    for _, guid in ipairs(list) do
        if type(guid) == "string" and guid ~= "" and not guid_pool[guid] then
            guid_pool[guid] = true
            table.insert(normalized_list, guid)
        end
    end

    return normalized_list
end

local function _normalize_open_ui_guid_list(list)
    local normalized_list = {}
    local guid_pool = {}
    if type(list) ~= "table" then
        return normalized_list
    end

    for _, guid in ipairs(list) do
        if type(guid) == "string" and guid ~= "" and not guid_pool[guid] then
            guid_pool[guid] = true
            table.insert(normalized_list, guid)
        end
    end

    return normalized_list
end

local function _normalize_editor_theme_data(theme_data)
    local default_color_id = EditorThemePresets.get_default_color_id and EditorThemePresets.get_default_color_id() or EditorThemePresets.get_default_id()
    local default_style_id = EditorThemePresets.get_default_style_id and EditorThemePresets.get_default_style_id() or "classic_compact"
    local normalized =
    {
        schema_version = 2,
        style_id = default_style_id,
        color_id = default_color_id,
        preset_id = default_color_id,
    }

    if type(theme_data) ~= "table" then
        return normalized
    end

    -- 旧版只保存 preset_id，这里统一迁移到 style_id + color_id。

    local function _normalize_color_id(value)
        if EditorThemePresets.normalize_color_id then
            return EditorThemePresets.normalize_color_id(value)
        end
        return EditorThemePresets.normalize_id(value)
    end

    local function _normalize_style_id(value)
        if EditorThemePresets.normalize_style_id then
            return EditorThemePresets.normalize_style_id(value)
        end
        return default_style_id
    end

    if type(theme_data.preset_id) == "string" and EditorThemePresets.has(theme_data.preset_id) then
        normalized.color_id = _normalize_color_id(theme_data.preset_id)
    end
    if type(theme_data.color_id) == "string" then
        normalized.color_id = _normalize_color_id(theme_data.color_id)
    end
    if type(theme_data.style_id) == "string" then
        normalized.style_id = _normalize_style_id(theme_data.style_id)
    end
    normalized.preset_id = normalized.color_id
    return normalized
end

local function _normalize_story_text_zoom_ratio(value)
    local numeric = tonumber(value) or 1.0
    local best_value = 1.0
    local best_delta = math.huge

    for _, candidate in ipairs(story_text_zoom_ratio_list) do
        local delta = math.abs(candidate - numeric)
        if delta < best_delta then
            best_value = candidate
            best_delta = delta
        end
    end

    return best_value
end

local function _sanitize_workspace_state(target)
    target.open_flow_guid_list = _normalize_open_flow_guid_list(target.open_flow_guid_list)
    target.open_style_guid_list = _normalize_open_style_guid_list(target.open_style_guid_list)
    target.open_ui_guid_list = _normalize_open_ui_guid_list(target.open_ui_guid_list)
    target.editor_theme = _normalize_editor_theme_data(target.editor_theme)
    target.story_text_zoom_ratio = _normalize_story_text_zoom_ratio(target.story_text_zoom_ratio)

    if type(target.current_flow_guid) ~= "string" then
        target.current_flow_guid = ""
    end

    if target.current_flow_guid ~= "" then
        local is_current_guid_open = false
        for _, guid in ipairs(target.open_flow_guid_list) do
            if guid == target.current_flow_guid then
                is_current_guid_open = true
                break
            end
        end

        if not is_current_guid_open then
            target.current_flow_guid = ""
        end
    end

    if type(target.current_graph_flow_guid) ~= "string" then
        target.current_graph_flow_guid = ""
    end

    if target.current_graph_flow_guid ~= "" then
        local is_current_graph_guid_open = false
        for _, guid in ipairs(target.open_flow_guid_list) do
            if guid == target.current_graph_flow_guid then
                is_current_graph_guid_open = true
                break
            end
        end

        if not is_current_graph_guid_open then
            target.current_graph_flow_guid = ""
        end
    end

    if type(target.current_text_flow_guid) ~= "string" then
        target.current_text_flow_guid = ""
    end

    if target.current_text_flow_guid ~= "" then
        local is_current_text_guid_open = false
        for _, guid in ipairs(target.open_flow_guid_list) do
            if guid == target.current_text_flow_guid then
                is_current_text_guid_open = true
                break
            end
        end

        if not is_current_text_guid_open then
            target.current_text_flow_guid = ""
        end
    end

    if type(target.current_style_guid) ~= "string" then
        target.current_style_guid = ""
    end

    if target.current_style_guid ~= "" then
        local is_current_style_guid_open = false
        for _, guid in ipairs(target.open_style_guid_list) do
            if guid == target.current_style_guid then
                is_current_style_guid_open = true
                break
            end
        end

        if not is_current_style_guid_open then
            target.current_style_guid = ""
        end
    end

    if type(target.current_ui_guid) ~= "string" then
        target.current_ui_guid = ""
    end

    if target.current_ui_guid ~= "" then
        local is_current_ui_guid_open = false
        for _, guid in ipairs(target.open_ui_guid_list) do
            if guid == target.current_ui_guid then
                is_current_ui_guid_open = true
                break
            end
        end

        if not is_current_ui_guid_open then
            target.current_ui_guid = ""
        end
    end

end

local function _guid_list_equal(left, right)
    if #left ~= #right then
        return false
    end

    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end

    return true
end

local serializable_key_pool =
{
    filter_mode = true,
    width_game_window = true,
    height_game_window = true,
    default_fullscreen = true,
    entry_flow_guid = true,
    project_version = true,
    is_show_debug_fps = true,
    editor_zoom_ratio = true,
    window_icon_guid = true,
    title = true,
    single_file = true,
    developer = true,
    file_description = true,
    release_version = true,
    release_mode = true,
    story_text_zoom_ratio = true,
    open_flow_guid_list = true,
    current_flow_guid = true,
    current_graph_flow_guid = true,
    current_text_flow_guid = true,
    open_style_guid_list = true,
    current_style_guid = true,
    open_ui_guid_list = true,
    current_ui_guid = true,
    editor_theme = true,
    presentation_ui_backend_enabled = true,
    project_guid = true,
    save_storage_mode = true,
    save_custom_root = true,
    save_subdirectory_name = true,
    save_profile_guid = true,
    save_pretty_json = true,
}

local default_data =
{
    filter_mode = rl.TextureFilter.TRILINEAR,
    width_game_window = 1920,
    height_game_window = 1080,
    default_fullscreen = false,
    entry_flow_guid = "",
    project_version = "0.1.0-dev.3",
    is_show_debug_fps = true,
    editor_zoom_ratio = 1.0,
    window_icon_guid = "",
    title = "Void Novel Engine Game",
    single_file = true,
    developer = "",
    file_description = "",
    release_version = "",
    release_mode = false,
    story_text_zoom_ratio = 1.0,
    open_flow_guid_list = {},
    current_flow_guid = "",
    current_graph_flow_guid = "",
    current_text_flow_guid = "",
    open_style_guid_list = {},
    current_style_guid = "",
    open_ui_guid_list = {},
    current_ui_guid = "",
    editor_theme =
    {
        schema_version = 2,
        style_id = EditorThemePresets.get_default_style_id and EditorThemePresets.get_default_style_id() or "classic_compact",
        color_id = EditorThemePresets.get_default_color_id and EditorThemePresets.get_default_color_id() or EditorThemePresets.get_default_id(),
        preset_id = EditorThemePresets.get_default_color_id and EditorThemePresets.get_default_color_id() or EditorThemePresets.get_default_id(),
    },
    presentation_ui_backend_enabled = false,
    project_guid = "",
    save_storage_mode = "auto",
    save_custom_root = "",
    save_subdirectory_name = fixed_save_subdirectory_name,
    save_profile_guid = "",
    save_pretty_json = fixed_save_pretty_json,
}

local data = {}

local function _log(message, type_message)
    if LogManager and LogManager.log then
        LogManager.log(message, type_message)
    end
end

local function _reset_to_default()
    data = {}
    for key, value in pairs(default_data) do
        data[key] = _clone_value(value)
    end
end

local function _sanitize_for_save(source)
    local target = {}
    for key in pairs(serializable_key_pool) do
        target[key] = _clone_value(source[key])
    end
    _sanitize_workspace_state(target)
    return target
end

local function _normalize_save_storage_mode(value)
    local mode = tostring(value or ""):match("^%s*(.-)%s*$")
    if mode ~= "auto" and mode ~= "custom" then
        return "auto"
    end
    return mode
end

local function _sanitize_save_fields(target)
    local normalized_guid = util.NormalizeGuidString(target.project_guid or "")
    target.project_guid = normalized_guid or ""
    target.save_storage_mode = _normalize_save_storage_mode(target.save_storage_mode)
    target.save_custom_root = type(target.save_custom_root) == "string" and target.save_custom_root or ""
    target.save_subdirectory_name = fixed_save_subdirectory_name
    target.save_profile_guid = util.NormalizeGuidString(target.save_profile_guid or "") or ""
    target.save_pretty_json = fixed_save_pretty_json
end

local function _ensure_project_guid()
    local normalized_guid = util.NormalizeGuidString(data.project_guid or "")
    if normalized_guid and normalized_guid ~= "" then
        if normalized_guid ~= data.project_guid then
            data.project_guid = normalized_guid
        end
        return false
    end

    data.project_guid = util.NewGuidString()
    return true
end

local function _merge_loaded_data(file_data)
    _reset_to_default()
    if type(file_data) ~= "table" then
        return
    end

    for key, value in pairs(file_data) do
        data[key] = _clone_value(value)
    end
    _sanitize_workspace_state(data)
    _sanitize_save_fields(data)
end

module.copy = function()
    local copy_data = {}
    for key, value in pairs(data) do
        copy_data[key] = _clone_value(value)
    end
    return copy_data
end

module.set_logger = function(log_mgr)
    LogManager = log_mgr
end

module.load = function()
    local file_existed = NativeIO.file_exists(file_path)
    local file_data, load_err = ProjectFile.load(file_path)
    if not file_data then
        _reset_to_default()
        _sanitize_save_fields(data)
        _ensure_project_guid()
        if file_existed then
            load_failure_protection =
            {
                path = file_path,
                error = load_err,
            }
            _log(string.format("无法打开项目配置文件：%s。已使用内存默认设置，并跳过自动保存以避免覆盖原文件。", load_err or "未知错误"), "error")
            return false, load_err
        end

        load_failure_protection = nil
        _log("未找到项目配置文件，将使用默认设置生成", "warning")
        return module.save(nil, nil, {silent = true})
    end

    load_failure_protection = nil
    _merge_loaded_data(file_data)
    if _ensure_project_guid() then
        return module.save(nil, nil, {silent = true})
    end
    return true
end

module.save = function(dst, target_data, options)
    local target_path = dst or file_path
    local target_source = target_data or data
    local save_options = options or {}

    if not dst and load_failure_protection and load_failure_protection.path == target_path then
        _log(string.format("跳过项目配置自动保存：当前配置文件加载失败（%s），保存会覆盖原文件。", load_failure_protection.error or "未知错误"), "warning")
        return false, load_failure_protection.error or "项目配置文件加载失败，已阻止自动保存"
    end

    local sanitized_data = _sanitize_for_save(target_source)
    _sanitize_save_fields(sanitized_data)

    ProjectFile.merge_missing_top_level(sanitized_data, ProjectFile.load_or_empty(target_path), serializable_key_pool)
    if target_path ~= file_path then
        ProjectFile.merge_missing_top_level(sanitized_data, ProjectFile.load_or_empty(file_path), serializable_key_pool)
    end

    local ok, err = ProjectFile.save(sanitized_data, target_path)
    if not ok then
        _log(string.format("保存项目配置失败：%s", err or "无法打开文件"), "error")
        return false
    end
    if not dst and not save_options.silent then
        _log("成功保存项目配置", "success")
    end
    return true
end

module.resolve_resource_fields = function(auto_save)
    local is_dirty = false

    local entry_flow_guid = ResourceIndex.resolve_guid("flow", data.entry_flow_guid) or ""
    if entry_flow_guid ~= data.entry_flow_guid then
        data.entry_flow_guid = entry_flow_guid or ""
        is_dirty = true
    end

    local window_icon_guid = ResourceIndex.resolve_guid("texture", data.window_icon_guid)
        or ResourceIndex.resolve_guid("texture", default_icon_path)
        or ""
    if window_icon_guid ~= data.window_icon_guid then
        data.window_icon_guid = window_icon_guid or ""
        is_dirty = true
    end

    if is_dirty and auto_save ~= false then
        module.save()
    end
end

module.get = function(key)
    return _clone_value(data[key])
end

module.set = function(key, val)
    local previous_value = _clone_value(data[key])
    if key == "entry_flow_guid" then
        val = ResourceIndex.resolve_guid("flow", val) or ""
    elseif key == "window_icon_guid" then
        val = ResourceIndex.resolve_guid("texture", val) or ""
    elseif key == "save_profile_guid" then
        val = ResourceIndex.resolve_guid("save_profile", val) or ""
    elseif key == "editor_theme" then
        val = _normalize_editor_theme_data(val)
    elseif key == "story_text_zoom_ratio" then
        val = _normalize_story_text_zoom_ratio(val)
    elseif key == "save_storage_mode" then
        val = _normalize_save_storage_mode(val)
    elseif key == "save_custom_root" then
        val = type(val) == "string" and val or ""
    elseif key == "save_subdirectory_name" then
        val = fixed_save_subdirectory_name
    elseif key == "save_pretty_json" then
        val = fixed_save_pretty_json
    elseif key == "project_guid" then
        val = util.NormalizeGuidString(val or "") or ""
    end
    data[key] = _clone_value(val)
    module.save()
    if previous_value ~= data[key]
        and (key == "save_profile_guid"
            or key == "project_guid"
            or key == "save_storage_mode"
            or key == "save_custom_root"
            or key == "save_subdirectory_name")
    then
        _reset_runtime_slices("项目或存档配置切换")
    end
end

module.get_entry_flow_guid = function()
    return data.entry_flow_guid
end

module.set_entry_flow_guid = function(guid)
    data.entry_flow_guid = ResourceIndex.resolve_guid("flow", guid) or ""
    module.save()
end

module.get_window_icon_guid = function()
    return data.window_icon_guid
end

module.set_window_icon_guid = function(guid)
    data.window_icon_guid = ResourceIndex.resolve_guid("texture", guid) or ""
    module.save()
end

module.get_entry_flow_meta = function()
    return ResourceIndex.find_by_guid(data.entry_flow_guid)
end

module.get_window_icon_meta = function()
    return ResourceIndex.find_by_guid(data.window_icon_guid)
end

module.get_entry_flow_path = function()
    local meta = module.get_entry_flow_meta()
    return meta and meta.path or ""
end

module.get_window_icon_path = function()
    local meta = module.get_window_icon_meta()
    if meta then
        return meta.path
    end
    return default_icon_path
end

module.get_open_flow_guid_list = function()
    return _clone_value(data.open_flow_guid_list or {})
end

module.get_current_flow_guid = function()
    return data.current_flow_guid or ""
end

module.get_current_graph_flow_guid = function()
    return data.current_graph_flow_guid or ""
end

module.get_current_text_flow_guid = function()
    return data.current_text_flow_guid or ""
end

module.get_open_style_guid_list = function()
    return _clone_value(data.open_style_guid_list or {})
end

module.get_current_style_guid = function()
    return data.current_style_guid or ""
end

module.get_open_ui_guid_list = function()
    return _clone_value(data.open_ui_guid_list or {})
end

module.get_current_ui_guid = function()
    return data.current_ui_guid or ""
end

module.set_workspace_flow_state = function(open_flow_guid_list, current_flow_guid, options)
    local next_open_flow_guid_list = _normalize_open_flow_guid_list(open_flow_guid_list)
    local next_current_flow_guid = type(current_flow_guid) == "string" and current_flow_guid or ""
    local save_options = options or {}
    local next_current_graph_flow_guid = type(save_options.current_graph_flow_guid) == "string"
        and save_options.current_graph_flow_guid or ""
    local next_current_text_flow_guid = type(save_options.current_text_flow_guid) == "string"
        and save_options.current_text_flow_guid or ""

    if next_current_flow_guid ~= "" then
        local is_current_guid_open = false
        for _, guid in ipairs(next_open_flow_guid_list) do
            if guid == next_current_flow_guid then
                is_current_guid_open = true
                break
            end
        end
        if not is_current_guid_open then
            next_current_flow_guid = ""
        end
    end

    if next_current_graph_flow_guid ~= "" then
        local is_current_graph_guid_open = false
        for _, guid in ipairs(next_open_flow_guid_list) do
            if guid == next_current_graph_flow_guid then
                is_current_graph_guid_open = true
                break
            end
        end
        if not is_current_graph_guid_open then
            next_current_graph_flow_guid = ""
        end
    end

    if next_current_text_flow_guid ~= "" then
        local is_current_text_guid_open = false
        for _, guid in ipairs(next_open_flow_guid_list) do
            if guid == next_current_text_flow_guid then
                is_current_text_guid_open = true
                break
            end
        end
        if not is_current_text_guid_open then
            next_current_text_flow_guid = ""
        end
    end

    if _guid_list_equal(data.open_flow_guid_list or {}, next_open_flow_guid_list)
        and (data.current_flow_guid or "") == next_current_flow_guid
        and (data.current_graph_flow_guid or "") == next_current_graph_flow_guid
        and (data.current_text_flow_guid or "") == next_current_text_flow_guid
    then
        return false
    end

    data.open_flow_guid_list = next_open_flow_guid_list
    data.current_flow_guid = next_current_flow_guid
    data.current_graph_flow_guid = next_current_graph_flow_guid
    data.current_text_flow_guid = next_current_text_flow_guid
    module.save(nil, nil, {silent = save_options.silent == true})
    return true
end

module.set_workspace_style_state = function(open_style_guid_list, current_style_guid, options)
    local next_open_style_guid_list = _normalize_open_style_guid_list(open_style_guid_list)
    local next_current_style_guid = type(current_style_guid) == "string" and current_style_guid or ""
    local save_options = options or {}

    if next_current_style_guid ~= "" then
        local is_current_guid_open = false
        for _, guid in ipairs(next_open_style_guid_list) do
            if guid == next_current_style_guid then
                is_current_guid_open = true
                break
            end
        end
        if not is_current_guid_open then
            next_current_style_guid = ""
        end
    end

    if _guid_list_equal(data.open_style_guid_list or {}, next_open_style_guid_list)
        and (data.current_style_guid or "") == next_current_style_guid
    then
        return false
    end

    data.open_style_guid_list = next_open_style_guid_list
    data.current_style_guid = next_current_style_guid
    module.save(nil, nil, {silent = save_options.silent == true})
    return true
end

module.set_workspace_ui_state = function(open_ui_guid_list, current_ui_guid, options)
    local next_open_ui_guid_list = _normalize_open_ui_guid_list(open_ui_guid_list)
    local next_current_ui_guid = type(current_ui_guid) == "string" and current_ui_guid or ""
    local save_options = options or {}

    if next_current_ui_guid ~= "" then
        local is_current_guid_open = false
        for _, guid in ipairs(next_open_ui_guid_list) do
            if guid == next_current_ui_guid then
                is_current_guid_open = true
                break
            end
        end
        if not is_current_guid_open then
            next_current_ui_guid = ""
        end
    end

    if _guid_list_equal(data.open_ui_guid_list or {}, next_open_ui_guid_list)
        and (data.current_ui_guid or "") == next_current_ui_guid
    then
        return false
    end

    data.open_ui_guid_list = next_open_ui_guid_list
    data.current_ui_guid = next_current_ui_guid
    module.save(nil, nil, {silent = save_options.silent == true})
    return true
end

module.get_editor_theme = function()
    return _clone_value(_normalize_editor_theme_data(data.editor_theme))
end

module.get_editor_theme_id = function()
    return _normalize_editor_theme_data(data.editor_theme).color_id
end

module.get_editor_theme_color_id = function()
    return _normalize_editor_theme_data(data.editor_theme).color_id
end

module.get_editor_theme_style_id = function()
    return _normalize_editor_theme_data(data.editor_theme).style_id
end

module.set_editor_theme = function(theme_data, options)
    local normalized_theme = _normalize_editor_theme_data(theme_data)
    local current_theme = _normalize_editor_theme_data(data.editor_theme)
    local save_options = options or {}

    if current_theme.schema_version == normalized_theme.schema_version
        and current_theme.color_id == normalized_theme.color_id
        and current_theme.style_id == normalized_theme.style_id
    then
        return false
    end

    data.editor_theme = normalized_theme
    module.save(nil, nil, {silent = save_options.silent == true})
    return true
end

module.set_editor_theme_id = function(preset_id, options)
    local current_theme = _normalize_editor_theme_data(data.editor_theme)
    current_theme.color_id = EditorThemePresets.normalize_color_id and EditorThemePresets.normalize_color_id(preset_id) or EditorThemePresets.normalize_id(preset_id)
    current_theme.preset_id = current_theme.color_id
    return module.set_editor_theme(current_theme, options)
end

module.set_editor_theme_color_id = function(color_id, options)
    return module.set_editor_theme_id(color_id, options)
end

module.set_editor_theme_style_id = function(style_id, options)
    local current_theme = _normalize_editor_theme_data(data.editor_theme)
    current_theme.style_id = EditorThemePresets.normalize_style_id and EditorThemePresets.normalize_style_id(style_id) or current_theme.style_id
    return module.set_editor_theme(current_theme, options)
end

module.get_story_text_zoom_ratio = function()
    return _normalize_story_text_zoom_ratio(data.story_text_zoom_ratio)
end

module.set_story_text_zoom_ratio = function(value, options)
    local normalized_value = _normalize_story_text_zoom_ratio(value)
    local current_value = _normalize_story_text_zoom_ratio(data.story_text_zoom_ratio)
    local save_options = options or {}

    if math.abs(current_value - normalized_value) < 0.001 then
        return false
    end

    data.story_text_zoom_ratio = normalized_value
    module.save(nil, nil, {silent = save_options.silent == true})
    return true
end

_reset_to_default()

return module

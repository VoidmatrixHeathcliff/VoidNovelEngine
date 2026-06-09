local json = Engine.JSON
local util = Engine.Util

local NativeIO = require("application.framework.native_io")
local ProjectFile = require("application.framework.project_file")

local module = {}

local ROOT_PATH_DEFAULT = "application/resources"
local REGISTRY_PATH_DEFAULT = "library/asset_registry.json"
local PROJECT_REGISTRY_KEY <const> = "asset_registry"

local SUPPORTED_TYPE_BY_EXT =
{
    [".png"] = "texture",
    [".jpg"] = "texture",
    [".jpeg"] = "texture",
    [".tif"] = "texture",
    [".tiff"] = "texture",
    [".webp"] = "texture",
    [".avif"] = "texture",
    [".wav"] = "audio",
    [".mp3"] = "audio",
    [".ogg"] = "audio",
    [".flac"] = "audio",
    [".mp4"] = "video",
    [".m4v"] = "video",
    [".avi"] = "video",
    [".mkv"] = "video",
    [".flv"] = "video",
    [".mov"] = "video",
    [".webm"] = "video",
    [".ttf"] = "font",
    [".otf"] = "font",
    [".glsl"] = "shader",
    [".fs"] = "shader",
    [".flow"] = "flow",
    [".vns"] = "flow",
    [".style"] = "style",
    [".ui"] = "ui",
    [".saveprofile"] = "save_profile",
}

local logger = nil
local root_path = ROOT_PATH_DEFAULT
local registry_path = REGISTRY_PATH_DEFAULT
local asset_list = {}
local asset_list_by_type = {}
local asset_by_guid = {}
local guid_by_path = {}
local guid_by_relative_path = {}
local guid_by_qualified_id = {}
local guid_by_file_name = {}
local guid_by_short_name = {}
local tree_root = nil
local serialized_registry_state = nil

local function _log(message, type_message)
    if logger and logger.log then
        logger.log(message, type_message)
    end
end

local function _trim(text)
    if type(text) ~= "string" then
        return nil
    end

    local value = text:match("^%s*(.-)%s*$")
    if value == "" then
        return nil
    end
    return value
end

local function _normalize_slashes(path)
    local value = _trim(path)
    if not value then
        return nil
    end

    value = value:gsub("\\", "/")
    value = value:gsub("//+", "/")
    value = value:gsub("^%./", "")
    if #value > 1 then
        value = value:gsub("/$", "")
    end
    return value
end

local function _starts_with(text, prefix)
    return type(text) == "string" and type(prefix) == "string" and text:sub(1, #prefix) == prefix
end

local function _to_lower(text)
    if type(text) ~= "string" then
        return text
    end
    return string.lower(text)
end

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

local function _values_equal(left, right)
    if left == right then
        return true
    end
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return false
    end

    for key, value in pairs(left) do
        if not _values_equal(value, right[key]) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function _split_file_parts(path)
    local normalized = _normalize_slashes(path)
    if not normalized then
        return nil
    end

    local file_name = normalized:match("([^/]+)$") or normalized
    local ext = file_name:match("(%.[^%.]+)$") or ""
    ext = _to_lower(ext)
    local file_stem = ext ~= "" and file_name:sub(1, #file_name - #ext) or file_name
    local directory = normalized:match("^(.*)/[^/]+$") or ""

    return {
        path = normalized,
        directory = directory,
        file_name = file_name,
        file_stem = file_stem,
        ext = ext,
    }
end

local function _build_meta_path(path)
    return string.format("%s.meta", path)
end

local function _legacy_path_to_resource_path(path)
    local normalized = _normalize_slashes(path)
    if not normalized then
        return nil
    end

    local legacy_prefix_pool =
    {
        ["application/flow/"] = "application/resources/flow/",
        ["application/style/"] = "application/resources/style/",
        ["application/ui/"] = "application/resources/ui/",
    }

    for prefix, replacement in pairs(legacy_prefix_pool) do
        if _starts_with(normalized, prefix) then
            return replacement .. normalized:sub(#prefix + 1)
        end
    end
    return normalized
end

local function _get_supported_type(path)
    local info = _split_file_parts(path)
    if not info then
        return nil
    end
    return SUPPORTED_TYPE_BY_EXT[info.ext] or "file", info
end

local function _is_supported_asset(path)
    local asset_type = _get_supported_type(path)
    return asset_type ~= nil
end

local function _get_relative_path(path)
    local normalized_root = _normalize_slashes(root_path) or ROOT_PATH_DEFAULT
    local normalized = _normalize_slashes(path)
    if not normalized then
        return nil
    end

    if normalized == normalized_root then
        return ""
    end
    if _starts_with(normalized, normalized_root .. "/") then
        return normalized:sub(#normalized_root + 2)
    end
    return normalized
end

local function _is_path_inside_root(path)
    local normalized_root = _normalize_slashes(root_path) or ROOT_PATH_DEFAULT
    local normalized = _normalize_slashes(path)
    if not normalized or not normalized_root then
        return false
    end
    return normalized == normalized_root or _starts_with(normalized, normalized_root .. "/")
end

local function _join_path(left, right)
    local normalized_left = _normalize_slashes(left)
    local normalized_right = _normalize_slashes(right)
    if not normalized_left or normalized_left == "" then
        return normalized_right
    end
    if not normalized_right or normalized_right == "" then
        return normalized_left
    end
    return normalized_left .. "/" .. normalized_right
end

local function _build_asset_meta(path, guid, asset_type, meta_data)
    local normalized_path = _normalize_slashes(path)
    local normalized_guid = util.NormalizeGuidString(guid or "")
    local info = _split_file_parts(normalized_path)
    local relative_path = _get_relative_path(normalized_path) or normalized_path
    local relative_dir = relative_path:match("^(.*)/[^/]+$") or ""
    local id = info.ext ~= "" and relative_path:sub(1, #relative_path - #info.ext) or relative_path

    return
    {
        guid = normalized_guid,
        type = asset_type,
        path = normalized_path,
        meta_path = _build_meta_path(normalized_path),
        relative_path = relative_path,
        relative_dir = relative_dir,
        file_name = info.file_name,
        file_stem = info.file_stem,
        ext = info.ext,
        id = id,
        qualified_id = string.format("%s:%s", asset_type, id),
        display_name = info.file_stem,
        importer = _clone_value(meta_data and meta_data.importer or {}) or {},
    }
end

local function _read_json_file(path)
    local content, err = NativeIO.read_text(path)
    if not content then
        return nil, err
    end

    local ok, data = json.ParseToLua(content)
    if not ok then
        return nil, "JSON 解析失败"
    end
    return data
end

local function _write_json_file(path, data)
    local content = json.PrintFromLua(data)
    return NativeIO.write_text(path, content)
end

local function _normalize_meta_data(meta_data, guid)
    local normalized_guid = util.NormalizeGuidString(guid or (meta_data and meta_data.guid) or "") or util.NewGuidString()
    local normalized = {}

    if type(meta_data) == "table" then
        for key, value in pairs(meta_data) do
            normalized[key] = _clone_value(value)
        end
    end

    normalized.version = tonumber(normalized.version) or 1
    normalized.guid = normalized_guid
    normalized.importer = type(normalized.importer) == "table" and normalized.importer or {}
    return normalized
end

local function _read_meta_data(meta_path)
    if not NativeIO.file_exists(meta_path) then
        return nil
    end

    local meta_data = _read_json_file(meta_path)
    if not meta_data or type(meta_data) ~= "table" then
        return nil
    end

    return _normalize_meta_data(meta_data)
end

local function _hide_meta_file(meta_path)
    if not meta_path or meta_path == "" then
        return
    end

    local ok, err = NativeIO.set_file_hidden(meta_path, true)
    if not ok then
        _log(string.format("无法隐藏资源元数据文件：%s\n%s", meta_path, err or "未知错误"), "warning")
    end
end

local function _write_meta_file(meta_path, guid, meta_data)
    if NativeIO.file_exists(meta_path) then
        local ok_unhide, err_unhide = NativeIO.set_file_hidden(meta_path, false)
        if not ok_unhide then
            _log(string.format("无法更新资源元数据文件属性：%s\n%s", meta_path, err_unhide or "未知错误"), "warning")
        end
    end

    local ok, err = _write_json_file(meta_path, _normalize_meta_data(meta_data, guid))
    if not ok then
        _hide_meta_file(meta_path)
        error(string.format("无法写入资源元数据：%s\n%s", meta_path, err or "未知错误"))
    end
    _hide_meta_file(meta_path)
end

local function _get_file_signature(path)
    local size = util.GetFileSizeUtf8(path)
    local mtime = util.GetFileModifiedTimeUtf8(path)
    if not size or not mtime then
        return nil
    end

    return
    {
        size = size,
        mtime = mtime,
    }
end

local function _new_registry_state()
    return
    {
        version = 1,
        assets = {},
        by_guid = {},
        by_path = {},
    }
end

local function _deserialize_registry_state(data)
    local state = _new_registry_state()
    if type(data) ~= "table" then
        return state
    end

    state.version = tonumber(data.version) or 1
    for _, raw_entry in ipairs(data.assets or {}) do
        local guid = util.NormalizeGuidString(raw_entry.guid or "")
        if guid then
            local entry =
            {
                guid = guid,
                type = raw_entry.type,
                last_known_relative_path = _normalize_slashes(raw_entry.last_known_relative_path),
                last_known_meta_path = _normalize_slashes(raw_entry.last_known_meta_path),
                file_signature =
                {
                    size = raw_entry.file_signature and raw_entry.file_signature.size or nil,
                    mtime = raw_entry.file_signature and raw_entry.file_signature.mtime or nil,
                },
            }
            state.by_guid[guid] = entry
            if entry.last_known_relative_path then
                state.by_path[entry.last_known_relative_path] = entry
            end
            table.insert(state.assets, entry)
        end
    end

    return state
end

local function _serialize_registry_state(registry_state)
    local output =
    {
        version = 1,
        assets = {},
    }

    local guid_list = {}
    for guid in pairs(registry_state and registry_state.by_guid or {}) do
        table.insert(guid_list, guid)
    end
    table.sort(guid_list)

    for _, guid in ipairs(guid_list) do
        local entry = registry_state.by_guid[guid]
        local file_signature = entry.file_signature or {}
        table.insert(output.assets,
        {
            guid = guid,
            type = entry.type,
            last_known_relative_path = entry.last_known_relative_path,
            last_known_meta_path = entry.last_known_meta_path,
            file_signature =
            {
                size = file_signature.size,
                mtime = file_signature.mtime,
            },
        })
    end

    return output
end

local function _load_registry_state()
    local project_data = ProjectFile.load_or_empty()
    local project_registry = project_data[PROJECT_REGISTRY_KEY]
    if type(project_registry) == "table" then
        local state = _deserialize_registry_state(project_registry)
        serialized_registry_state = ProjectFile.clone(_serialize_registry_state(state))
        return state, project_data
    end

    if NativeIO.file_exists(registry_path) then
        local legacy_registry = _read_json_file(registry_path)
        if type(legacy_registry) == "table" then
            local state = _deserialize_registry_state(legacy_registry)
            serialized_registry_state = ProjectFile.clone(_serialize_registry_state(state))
            return state, project_data
        end
    end

    local empty_state = _new_registry_state()
    serialized_registry_state = ProjectFile.clone(_serialize_registry_state(empty_state))
    return empty_state, project_data
end

local function _save_registry_state(registry_state)
    if not registry_state then
        return
    end

    local output = _serialize_registry_state(registry_state)
    local should_write_project_file = not _values_equal(output, serialized_registry_state)

    if not should_write_project_file then
        if NativeIO.file_exists(registry_path) then
            local ok_remove, err_remove = NativeIO.remove_file(registry_path)
            if not ok_remove then
                _log(string.format("无法移除旧版资源账本：%s\n%s", registry_path, err_remove or "未知错误"), "warning")
            end
        end
        return
    end

    local project_data = ProjectFile.load_or_empty()
    project_data[PROJECT_REGISTRY_KEY] = output

    local ok, err = ProjectFile.save(project_data)
    if not ok then
        error(string.format("无法写入项目资源账本：%s\n%s", ProjectFile.get_file_path(), err or "未知错误"))
    end
    serialized_registry_state = ProjectFile.clone(output)
    if NativeIO.file_exists(registry_path) then
        local ok_remove, err_remove = NativeIO.remove_file(registry_path)
        if not ok_remove then
            _log(string.format("无法移除旧版资源账本：%s\n%s", registry_path, err_remove or "未知错误"), "warning")
        end
    end
end

local function _registry_find_recover_entry(registry_state, asset_type, relative_path, file_signature, active_relative_path_pool)
    if not registry_state then
        return nil
    end

    local normalized_relative_path = _normalize_slashes(relative_path)
    local by_path_entry = registry_state.by_path[normalized_relative_path]
    if by_path_entry and by_path_entry.type == asset_type then
        local normalized_guid = util.NormalizeGuidString(by_path_entry.guid or "")
        if normalized_guid then
            return by_path_entry
        end
    end

    if not file_signature then
        return nil
    end

    local matched_entry = nil
    for guid, entry in pairs(registry_state.by_guid or {}) do
        if entry.type == asset_type and entry.file_signature then
            if entry.file_signature.size == file_signature.size and entry.file_signature.mtime == file_signature.mtime then
                local last_known_relative_path = _normalize_slashes(entry.last_known_relative_path)
                local last_known_path_is_active =
                    active_relative_path_pool
                    and last_known_relative_path
                    and last_known_relative_path ~= normalized_relative_path
                    and active_relative_path_pool[last_known_relative_path]
                if not last_known_path_is_active then
                    if matched_entry and matched_entry.guid ~= guid then
                        return nil
                    end
                    matched_entry = entry
                end
            end
        end
    end

    return matched_entry
end

local function _try_move_recovered_meta_file(recovered_entry, target_meta_path)
    local recovered_guid = util.NormalizeGuidString(recovered_entry and recovered_entry.guid or "")
    if not recovered_guid then
        return false
    end

    local source_meta_path = _normalize_slashes(recovered_entry and recovered_entry.last_known_meta_path or nil)
    local normalized_target_meta_path = _normalize_slashes(target_meta_path)
    if not source_meta_path or not normalized_target_meta_path or source_meta_path == normalized_target_meta_path then
        return false
    end
    if _to_lower(source_meta_path):sub(-5) ~= ".meta" then
        return false
    end
    if not _is_path_inside_root(source_meta_path) or not _is_path_inside_root(normalized_target_meta_path) then
        return false
    end
    if NativeIO.file_exists(normalized_target_meta_path) or NativeIO.directory_exists(normalized_target_meta_path) then
        return false
    end
    if not NativeIO.file_exists(source_meta_path) then
        return false
    end

    local source_asset_path = source_meta_path:sub(1, #source_meta_path - 5)
    if NativeIO.file_exists(source_asset_path) then
        return false
    end

    local source_meta_data = _read_meta_data(source_meta_path)
    if not source_meta_data or source_meta_data.guid ~= recovered_guid then
        return false
    end

    local ok, err = NativeIO.rename(source_meta_path, normalized_target_meta_path)
    if not ok then
        _log(string.format("无法跟随迁移资源元数据文件：%s -> %s\n%s", source_meta_path, normalized_target_meta_path, err or "未知错误"), "warning")
        return false
    end

    _hide_meta_file(normalized_target_meta_path)
    _log(string.format("已跟随迁移资源元数据文件：%s -> %s", source_meta_path, normalized_target_meta_path), "info")
    return true, source_meta_path
end

local function _register_meta(meta)
    asset_by_guid[meta.guid] = meta
    guid_by_path[meta.path] = meta.guid
    guid_by_relative_path[meta.relative_path] = meta.guid
    guid_by_qualified_id[meta.qualified_id] = meta.guid

    asset_list_by_type[meta.type] = asset_list_by_type[meta.type] or {}
    table.insert(asset_list_by_type[meta.type], meta)

    guid_by_file_name[meta.type] = guid_by_file_name[meta.type] or {}
    guid_by_file_name[meta.type][meta.file_name] = guid_by_file_name[meta.type][meta.file_name] or {}
    table.insert(guid_by_file_name[meta.type][meta.file_name], meta.guid)

    guid_by_short_name[meta.type] = guid_by_short_name[meta.type] or {}
    guid_by_short_name[meta.type][meta.file_stem] = guid_by_short_name[meta.type][meta.file_stem] or {}
    table.insert(guid_by_short_name[meta.type][meta.file_stem], meta.guid)

    table.insert(asset_list, meta)
end

local function _sort_asset_lists()
    table.sort(asset_list, function(a, b)
        if a.type == b.type then
            return a.id < b.id
        end
        return a.type < b.type
    end)

    for _, meta_list in pairs(asset_list_by_type) do
        table.sort(meta_list, function(a, b)
            return a.id < b.id
        end)
    end
end

local function _ensure_tree_node(parent, name, relative_path)
    parent.children_by_name = parent.children_by_name or {}
    local node = parent.children_by_name[name]
    if node then
        return node
    end

    node =
    {
        name = name,
        relative_path = relative_path,
        directory = true,
        children = {},
        children_by_name = {},
        asset_list = {},
    }
    parent.children_by_name[name] = node
    table.insert(parent.children, node)
    return node
end

local function _rebuild_tree(directory_relative_path_list)
    tree_root =
    {
        name = "resources",
        relative_path = "",
        directory = true,
        children = {},
        children_by_name = {},
        asset_list = {},
    }

    for _, relative_dir in ipairs(directory_relative_path_list or {}) do
        local normalized_relative_dir = _normalize_slashes(relative_dir)
        if normalized_relative_dir and normalized_relative_dir ~= "" then
            local node = tree_root
            local partial_path = ""
            for part in string.gmatch(normalized_relative_dir, "[^/]+") do
                partial_path = partial_path == "" and part or (partial_path .. "/" .. part)
                node = _ensure_tree_node(node, part, partial_path)
            end
        end
    end

    for _, meta in ipairs(asset_list) do
        local node = tree_root
        local relative_dir = meta.relative_dir
        if relative_dir and relative_dir ~= "" then
            local partial_path = ""
            for part in string.gmatch(relative_dir, "[^/]+") do
                partial_path = partial_path == "" and part or (partial_path .. "/" .. part)
                node = _ensure_tree_node(node, part, partial_path)
            end
        end
        table.insert(node.asset_list, meta)
    end

    local function sort_node(node)
        table.sort(node.children, function(a, b)
            return a.name < b.name
        end)
        table.sort(node.asset_list, function(a, b)
            return a.id < b.id
        end)
        for _, child in ipairs(node.children) do
            sort_node(child)
        end
    end

    sort_node(tree_root)
end

local function _clear_internal()
    asset_list = {}
    asset_list_by_type = {}
    asset_by_guid = {}
    guid_by_path = {}
    guid_by_relative_path = {}
    guid_by_qualified_id = {}
    guid_by_file_name = {}
    guid_by_short_name = {}
    tree_root = nil
end

local function _load_assets_from_registry_state(registry_state)
    local directory_relative_path_pool = {}
    local entry_list = {}

    for _, entry in pairs(registry_state and registry_state.by_guid or {}) do
        table.insert(entry_list, entry)
    end

    table.sort(entry_list, function(left, right)
        return tostring(left and left.last_known_relative_path or "") < tostring(right and right.last_known_relative_path or "")
    end)

    for _, entry in ipairs(entry_list) do
        local guid = util.NormalizeGuidString(entry and entry.guid or "")
        local relative_path = _normalize_slashes(entry and entry.last_known_relative_path or nil)
        local meta_path = _normalize_slashes(entry and entry.last_known_meta_path or nil)
        local asset_type = entry and entry.type or nil

        if guid and relative_path and asset_type then
            local asset_path = _join_path(root_path, relative_path)
            local meta_data = _read_meta_data(meta_path or _build_meta_path(asset_path))
            local meta = _build_asset_meta(asset_path, guid, asset_type, meta_data)
            meta.meta_path = meta_path or meta.meta_path
            meta.file_signature = _clone_value(entry.file_signature or {})
            _register_meta(meta)

            if meta.relative_dir and meta.relative_dir ~= "" then
                directory_relative_path_pool[meta.relative_dir] = true
            end
        end
    end

    _sort_asset_lists()

    local directory_relative_path_list = {}
    for relative_path in pairs(directory_relative_path_pool) do
        table.insert(directory_relative_path_list, relative_path)
    end
    table.sort(directory_relative_path_list)
    _rebuild_tree(directory_relative_path_list)
end

function module.set_logger(log_mgr)
    logger = log_mgr
end

function module.clear()
    _clear_internal()
end

function module.scan(path)
    root_path = _normalize_slashes(path or root_path or ROOT_PATH_DEFAULT) or ROOT_PATH_DEFAULT
    registry_path = _normalize_slashes(registry_path or REGISTRY_PATH_DEFAULT) or REGISTRY_PATH_DEFAULT

    _clear_internal()

    local registry_state, project_data = _load_registry_state()
    if type(project_data) == "table" and project_data.release_mode == true then
        _load_assets_from_registry_state(registry_state)
        return
    end

    local path_list = {}
    local active_guid_pool = {}
    if NativeIO.directory_exists(root_path) then
        local list_result, list_err = NativeIO.list_directory_array(root_path, true, false)
        if not list_result then
            error(string.format("无法扫描资源目录：%s\n%s", root_path, list_err or "未知错误"))
        end
        path_list = list_result
    end

    local directory_relative_path_pool = {}
    local meta_path_pool = {}
    local asset_path_pool = {}
    for _, raw_path in ipairs(path_list) do
        local normalized = _normalize_slashes(raw_path)
        if normalized then
            if NativeIO.directory_exists(normalized) then
                local relative_dir = _get_relative_path(normalized)
                if relative_dir ~= nil and relative_dir ~= "" then
                    table.insert(directory_relative_path_pool, relative_dir)
                end
            else
                if _to_lower(normalized):sub(-5) == ".meta" then
                    table.insert(meta_path_pool, normalized)
                elseif _is_supported_asset(normalized) then
                    table.insert(asset_path_pool, normalized)
                end
            end
        end
    end

    table.sort(directory_relative_path_pool)
    table.sort(asset_path_pool)

    local active_relative_path_pool = {}
    for _, asset_path in ipairs(asset_path_pool) do
        local relative_path = _get_relative_path(asset_path)
        if relative_path then
            active_relative_path_pool[relative_path] = true
        end
    end

    local migrated_meta_path_pool = {}
    for _, asset_path in ipairs(asset_path_pool) do
        local asset_type = _get_supported_type(asset_path)
        local meta_path = _build_meta_path(asset_path)
        local relative_path = _get_relative_path(asset_path)
        local file_signature = _get_file_signature(asset_path)
        local meta_data = _read_meta_data(meta_path)
        local guid = meta_data and meta_data.guid or nil
        local should_rewrite_meta = false

        if not guid then
            local recovered_entry = _registry_find_recover_entry(registry_state, asset_type, relative_path, file_signature, active_relative_path_pool)
            local recovered_guid = util.NormalizeGuidString(recovered_entry and recovered_entry.guid or "")
            if recovered_guid then
                local moved, source_meta_path = _try_move_recovered_meta_file(recovered_entry, meta_path)
                if moved then
                    migrated_meta_path_pool[source_meta_path] = true
                    meta_data = _read_meta_data(meta_path)
                    guid = meta_data and meta_data.guid or nil
                end
            end
            if not guid then
                guid = recovered_guid
            end
            if guid then
                _log(string.format("已根据资源账本恢复资源 GUID：%s", relative_path), "warning")
            end
            if not guid then
                guid = util.NewGuidString()
                _log(string.format("已为资源生成新的 GUID：%s", relative_path), "info")
            end
            should_rewrite_meta = meta_data == nil
        end

        if asset_by_guid[guid] then
            local previous_meta = asset_by_guid[guid]
            local new_guid = util.NewGuidString()
            _log(string.format("检测到资源 GUID 冲突，已重建：%s -> %s", relative_path, new_guid), "warning")
            guid = new_guid
            should_rewrite_meta = true
            if previous_meta then
                _log(string.format("GUID 冲突保留先扫描资源：%s", previous_meta.relative_path), "warning")
            end
        end

        if should_rewrite_meta then
            meta_data = _normalize_meta_data(meta_data, guid)
            _write_meta_file(meta_path, guid, meta_data)
        else
            _hide_meta_file(meta_path)
        end

        local meta = _build_asset_meta(asset_path, guid, asset_type, meta_data)
        meta.file_signature = file_signature
        _register_meta(meta)
        active_guid_pool[guid] = true

        registry_state.by_guid[guid] =
        {
            guid = guid,
            type = asset_type,
            last_known_relative_path = meta.relative_path,
            last_known_meta_path = meta.meta_path,
            file_signature = file_signature or {},
        }
        registry_state.by_path[meta.relative_path] = registry_state.by_guid[guid]
    end

    for guid in pairs(registry_state.by_guid or {}) do
        if not active_guid_pool[guid] then
            registry_state.by_guid[guid] = nil
        end
    end
    registry_state.by_path = {}
    for guid, entry in pairs(registry_state.by_guid or {}) do
        if entry and entry.last_known_relative_path then
            registry_state.by_path[entry.last_known_relative_path] = entry
        end
    end

    for _, meta_path in ipairs(meta_path_pool) do
        local asset_path = meta_path:sub(1, #meta_path - 5)
        local normalized_asset_path = _normalize_slashes(asset_path)
        if not migrated_meta_path_pool[meta_path]
            and not guid_by_path[normalized_asset_path]
            and not NativeIO.file_exists(normalized_asset_path) then
            local ok_remove = NativeIO.remove_file(meta_path)
            if not ok_remove then
                _log(string.format("检测到孤立资源元数据文件：%s", meta_path), "warning")
            end
        end
    end

    _sort_asset_lists()
    _rebuild_tree(directory_relative_path_pool)
    _save_registry_state(registry_state)
end

function module.list_all()
    return asset_list
end

function module.list_by_type(asset_type)
    return asset_list_by_type[asset_type] or {}
end

function module.find_by_guid(guid)
    local normalized = util.NormalizeGuidString(guid or "")
    if not normalized then
        return nil
    end
    return asset_by_guid[normalized]
end

function module.get_importer_data(guid, importer_key)
    local meta = module.find_by_guid(guid)
    if not meta or type(importer_key) ~= "string" or importer_key == "" then
        return nil
    end
    local importer = type(meta.importer) == "table" and meta.importer or {}
    return _clone_value(importer[importer_key])
end

function module.set_importer_data(guid, importer_key, value)
    local meta = module.find_by_guid(guid)
    if not meta then
        return false, "无法定位资源元数据"
    end
    if type(importer_key) ~= "string" or importer_key == "" then
        return false, "无效的 importer 标识"
    end

    local meta_data = _read_meta_data(meta.meta_path) or _normalize_meta_data(nil, meta.guid)
    meta_data.guid = meta.guid
    meta_data.importer = type(meta_data.importer) == "table" and meta_data.importer or {}

    if _values_equal(meta_data.importer[importer_key], value) then
        meta.importer = _clone_value(meta_data.importer)
        return true
    end

    if value == nil then
        meta_data.importer[importer_key] = nil
    else
        meta_data.importer[importer_key] = _clone_value(value)
    end

    _write_meta_file(meta.meta_path, meta.guid, meta_data)
    meta.importer = _clone_value(meta_data.importer)
    return true
end

function module.find_guid_by_path(path)
    local normalized = _normalize_slashes(path)
    if not normalized then
        return nil
    end

    normalized = _legacy_path_to_resource_path(normalized)
    return guid_by_path[normalized]
        or guid_by_relative_path[normalized]
        or guid_by_relative_path[normalized:gsub("^application/resources/", "")]
end

function module.find_by_path(path)
    local guid = module.find_guid_by_path(path)
    if not guid then
        return nil
    end
    return asset_by_guid[guid]
end

function module.find_guid_by_id(asset_type, id)
    local normalized_id = _normalize_slashes(id)
    if not normalized_id or not asset_type then
        return nil
    end

    return guid_by_qualified_id[string.format("%s:%s", asset_type, normalized_id)]
end

function module.find_guid_by_file_name(asset_type, file_name)
    local normalized_name = _trim(file_name)
    if not normalized_name or not asset_type then
        return nil
    end

    local guid_list = guid_by_file_name[asset_type] and guid_by_file_name[asset_type][normalized_name]
    if not guid_list or #guid_list ~= 1 then
        return nil
    end
    return guid_list[1]
end

function module.find_by_qualified_id(qualified_id)
    local normalized = _trim(qualified_id)
    if not normalized then
        return nil
    end
    local guid = guid_by_qualified_id[normalized]
    if not guid then
        return nil
    end
    return asset_by_guid[guid]
end

function module.find_guid_by_short_name(asset_type, short_name)
    local normalized_name = _trim(short_name)
    if not normalized_name or not asset_type then
        return nil
    end

    local guid_list = guid_by_short_name[asset_type] and guid_by_short_name[asset_type][normalized_name]
    if not guid_list or #guid_list ~= 1 then
        return nil
    end
    return guid_list[1]
end

function module.resolve_guid(asset_type, value)
    if type(value) == "table" then
        if value.guid then
            local normalized = util.NormalizeGuidString(value.guid or "")
            if normalized and asset_by_guid[normalized] then
                return normalized
            end
        end
        return module.resolve_guid(asset_type, value.path_hint or value.relative_path or value.id or value.path)
    end

    local raw_text = _trim(value)
    if not raw_text then
        return nil
    end

    local normalized_guid = util.NormalizeGuidString(raw_text)
    if normalized_guid and asset_by_guid[normalized_guid] then
        return normalized_guid
    end

    local guid = module.find_guid_by_path(raw_text)
    if guid then
        return guid
    end

    if asset_type then
        guid = module.find_guid_by_id(asset_type, raw_text)
        if guid then
            return guid
        end
    end

    local file_info = _split_file_parts(raw_text)
    if asset_type then
        if file_info and file_info.ext ~= "" and file_info.file_name then
            guid = module.find_guid_by_file_name(asset_type, file_info.file_name)
            if guid then
                return guid
            end
        end
        if file_info and file_info.file_stem then
            guid = module.find_guid_by_short_name(asset_type, file_info.file_stem)
            if guid then
                return guid
            end
        end
        guid = module.find_guid_by_short_name(asset_type, raw_text)
        if guid then
            return guid
        end
    end

    return nil
end

function module.make_reference(asset_type, value)
    if value == nil then
        return nil
    end

    local raw_hint = nil
    if type(value) == "table" then
        raw_hint = value.path_hint or value.relative_path or value.id or value.path
    elseif type(value) == "string" then
        raw_hint = value
    end

    local guid = module.resolve_guid(asset_type, value)
    if guid then
        local meta = module.find_by_guid(guid)
        return
        {
            guid = guid,
            path_hint = meta and meta.relative_path or _trim(raw_hint),
        }
    end

    raw_hint = _trim(raw_hint)
    if not raw_hint then
        return nil
    end

    return
    {
        path_hint = raw_hint,
    }
end

function module.get_display_path(asset_type, value)
    local reference = module.make_reference(asset_type, value)
    if not reference then
        return ""
    end

    if reference.guid then
        local meta = module.find_by_guid(reference.guid)
        if meta then
            return meta.relative_path
        end
    end

    return reference.path_hint or ""
end

function module.get_tree()
    return tree_root
end

function module.get_root_path()
    return root_path
end

function module.get_serialized_registry_state()
    return ProjectFile.clone(serialized_registry_state)
end

function module.set_root_path(path)
    root_path = _normalize_slashes(path or ROOT_PATH_DEFAULT) or ROOT_PATH_DEFAULT
end

function module.set_registry_path(path)
    registry_path = _normalize_slashes(path or REGISTRY_PATH_DEFAULT) or REGISTRY_PATH_DEFAULT
end

return module

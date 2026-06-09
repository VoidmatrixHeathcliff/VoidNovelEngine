local rl = Engine.Raylib

local Blueprint = require("application.framework.blueprint")
local FlowManager = require("application.framework.flow_manager")
local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local NativeIO = require("application.framework.native_io")
local ResourceHotReload = require("application.framework.resource_hot_reload")
local ResourceIndex = require("application.framework.resource_index")
local SaveProfile = require("application.framework.save_profile")
local Style = require("application.framework.style")
local StyleWorkspaceManager = require("application.framework.style_workspace_manager")
local UI = require("application.framework.ui")
local UIWorkspaceManager = require("application.framework.ui_workspace_manager")
local VideoImporter = require("application.framework.video_importer")

local module = {}

local resource_kind_order =
{
    "flow_graph",
    "story_text",
    "ui",
    "style",
    "shader_file",
}

local resource_kind_pool =
{
    flow_graph =
    {
        kind = "flow_graph",
        display_name = "流程图",
        ext = ".flow",
        default_relative_dir = "flow",
    },
    story_text =
    {
        kind = "story_text",
        display_name = "文本剧本",
        ext = ".vns",
        default_relative_dir = "flow",
    },
    ui =
    {
        kind = "ui",
        display_name = "页面设计",
        ext = ".ui",
        default_relative_dir = "ui",
    },
    style =
    {
        kind = "style",
        display_name = "样式设计",
        ext = ".style",
        default_relative_dir = "style",
    },
    shader_file =
    {
        kind = "shader_file",
        display_name = "着色器",
        ext = ".fs",
        default_relative_dir = "shader",
    },
    save_profile =
    {
        kind = "save_profile",
        display_name = "存档配置",
        ext = ".saveprofile",
        default_relative_dir = "save",
    },
}

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
    if value == nil then
        return ""
    end
    value = value:gsub("\\", "/")
    value = value:gsub("//+", "/")
    if #value > 1 then
        value = value:gsub("/$", "")
    end
    return value
end

local function _starts_with(text, prefix)
    return type(text) == "string"
        and type(prefix) == "string"
        and text:sub(1, #prefix) == prefix
end

local function _ends_with_ignore_case(text, suffix)
    if type(text) ~= "string" or type(suffix) ~= "string" then
        return false
    end
    if #suffix == 0 or #text < #suffix then
        return false
    end
    return string.lower(text:sub(-#suffix)) == string.lower(suffix)
end

local function _join_path(left, right)
    local normalized_left = _normalize_slashes(left)
    local normalized_right = _normalize_slashes(right)
    if normalized_left == "" then
        return normalized_right
    end
    if normalized_right == "" then
        return normalized_left
    end
    return string.format("%s/%s", normalized_left, normalized_right)
end

local function _get_root_path()
    return _normalize_slashes(ResourceIndex.get_root_path())
end

local function _to_relative_dir(value)
    local normalized = _normalize_slashes(value)
    local root_path = _get_root_path()
    if normalized == "" or normalized == root_path then
        return ""
    end
    if _starts_with(normalized, root_path .. "/") then
        return normalized:sub(#root_path + 2)
    end
    return normalized:gsub("^/", "")
end

local function _build_directory_path(relative_dir)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    if normalized_relative_dir == "" then
        return _get_root_path()
    end
    return _join_path(_get_root_path(), normalized_relative_dir)
end

local function _is_path_inside_root(path)
    local normalized_path = _normalize_slashes(path)
    local root_path = _get_root_path()
    return normalized_path == root_path or _starts_with(normalized_path, root_path .. "/")
end

local function _get_parent_relative_dir(relative_dir)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    return normalized_relative_dir:match("^(.*)/[^/]+$") or ""
end

local function _get_base_name(path)
    local normalized = _normalize_slashes(path)
    return normalized:match("([^/]+)$") or normalized
end

local function _strip_matching_extension(file_stem, ext)
    local normalized_file_stem = _trim(file_stem)
    if not normalized_file_stem or type(ext) ~= "string" or ext == "" then
        return normalized_file_stem
    end
    if _ends_with_ignore_case(normalized_file_stem, ext) then
        return normalized_file_stem:sub(1, #normalized_file_stem - #ext)
    end
    return normalized_file_stem
end

local function _find_resource_kind(kind)
    return resource_kind_pool[kind]
end

local function _build_resource_path(relative_dir, file_stem, ext)
    return _join_path(_build_directory_path(relative_dir), tostring(file_stem or "") .. tostring(ext or ""))
end

local function _build_directory_result(relative_dir)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    return
    {
        kind = "directory",
        path = _build_directory_path(normalized_relative_dir),
        relative_path = normalized_relative_dir,
        relative_dir = normalized_relative_dir,
        guid = nil,
    }
end

local function _build_resource_result(meta)
    if not meta then
        return nil
    end
    return
    {
        kind = "resource",
        guid = meta.guid,
        path = meta.path,
        relative_path = meta.relative_path,
        relative_dir = meta.relative_dir,
    }
end

local function _path_is_inside_relative_dir(relative_path, relative_dir)
    local normalized_relative_path = _normalize_slashes(relative_path)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    if not normalized_relative_path then
        return false
    end
    if normalized_relative_dir == "" then
        return true
    end
    return normalized_relative_path == normalized_relative_dir
        or _starts_with(normalized_relative_path, normalized_relative_dir .. "/")
end

local function _validate_common_name(raw_name)
    local normalized_name = _trim(raw_name)
    if not normalized_name then
        return nil, "名称不能为空"
    end
    if not rl.IsFileNameValid(normalized_name) then
        return nil, "名称包含非法字符"
    end
    if normalized_name:match("[%. ]$") then
        return nil, "名称不能以空格或句点结尾"
    end

    local upper_name = string.upper(normalized_name)
    if upper_name == "CON"
        or upper_name == "PRN"
        or upper_name == "AUX"
        or upper_name == "NUL"
        or upper_name:match("^COM[0-9]$")
        or upper_name:match("^LPT[0-9]$")
    then
        return nil, "名称不能使用系统保留字"
    end
    return normalized_name
end

local function _create_resource_payload(kind, path)
    if kind == "flow_graph" then
        local blueprint = Blueprint.new(path)
        if blueprint and blueprint.dispose then
            blueprint:dispose()
        end
        return true
    end

    if kind == "story_text" then
        return NativeIO.write_text(path, "")
    end

    if kind == "ui" then
        return UI.save(path, UI.new_document())
    end

    if kind == "style" then
        return Style.save(path, Style.new_document({include_default_domains = true, use_default_values = true}))
    end

    if kind == "shader_file" then
        return NativeIO.write_text(path, "")
    end

    if kind == "save_profile" then
        return SaveProfile.save(path, SaveProfile.new_document(), true)
    end

    return false, "未知的资源类型"
end

local function _refresh_resource_world(options)
    local result = ResourceHotReload.refresh_now(options or {force_editor_refresh = true})
    if GlobalContext.resource_index_revision == nil then
        GlobalContext.resource_index_revision = 0
    end
    return result
end

local function _close_open_document_for_meta(meta)
    if not meta or not meta.guid then
        return
    end

    if meta.type == "flow" then
        FlowManager.close_document_in_workspace(meta.guid)
        return
    end
    if meta.type == "ui" then
        UIWorkspaceManager.close_ui_in_workspace(meta.guid)
        return
    end
    if meta.type == "style" then
        StyleWorkspaceManager.close_style_in_workspace(meta.guid)
        return
    end
end

local function _close_open_documents_under_directory(relative_dir)
    for _, meta in ipairs(ResourceIndex.list_all()) do
        if _path_is_inside_relative_dir(meta.relative_path, relative_dir) then
            _close_open_document_for_meta(meta)
        end
    end
end

local function _find_document_for_meta(meta)
    if not meta or not meta.guid then
        return nil
    end

    if meta.type == "flow" then
        return FlowManager.find_by_guid(meta.guid)
    end
    if meta.type == "ui" then
        return UIWorkspaceManager.find_by_guid(meta.guid)
    end
    if meta.type == "style" then
        return StyleWorkspaceManager.find_by_guid(meta.guid)
    end
    return nil
end

local function _is_document_modified(document)
    return document ~= nil
        and document.is_modified ~= nil
        and document:is_modified() == true
end

local function _find_modified_meta_under_directory(relative_dir)
    for _, meta in ipairs(ResourceIndex.list_all()) do
        if _path_is_inside_relative_dir(meta.relative_path, relative_dir) then
            local document = _find_document_for_meta(meta)
            if _is_document_modified(document) then
                return meta
            end
        end
    end
    return nil
end

function module.get_root_path()
    return _get_root_path()
end

function module.normalize_relative_dir(value)
    return _to_relative_dir(value)
end

function module.get_directory_display_path(relative_dir)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    if normalized_relative_dir == "" then
        return "resources"
    end
    return string.format("resources/%s", normalized_relative_dir)
end

function module.get_resource_kind_definition(kind)
    return _find_resource_kind(kind)
end

function module.list_resource_kind_entries()
    local result = {}
    for _, kind in ipairs(resource_kind_order) do
        local definition = resource_kind_pool[kind]
        if definition then
            table.insert(result, definition)
        end
    end
    return result
end

function module.validate_create_resource(kind, relative_dir, raw_name)
    local definition = _find_resource_kind(kind)
    if not definition then
        return nil, "未知的资源类型"
    end

    local normalized_name, err = _validate_common_name(_strip_matching_extension(raw_name, definition.ext))
    if not normalized_name then
        return nil, err
    end

    local target_relative_dir = _to_relative_dir(relative_dir ~= nil and relative_dir or definition.default_relative_dir)
    local target_path = _build_resource_path(target_relative_dir, normalized_name, definition.ext)
    local target_meta_path = string.format("%s.meta", target_path)
    if not _is_path_inside_root(target_path) then
        return nil, "目标路径超出资源目录"
    end
    if NativeIO.file_exists(target_path) or NativeIO.directory_exists(target_path) then
        return nil, "同名文件已存在"
    end
    if NativeIO.file_exists(target_meta_path) or NativeIO.directory_exists(target_meta_path) then
        return nil, "同名资源元数据文件已存在"
    end

    return normalized_name
end

function module.validate_create_folder(relative_dir, raw_name)
    local normalized_name, err = _validate_common_name(raw_name)
    if not normalized_name then
        return nil, err
    end

    local target_relative_dir = _to_relative_dir(_join_path(relative_dir, normalized_name))
    local target_path = _build_directory_path(target_relative_dir)
    if not _is_path_inside_root(target_path) then
        return nil, "目标路径超出资源目录"
    end
    if NativeIO.directory_exists(target_path) or NativeIO.file_exists(target_path) then
        return nil, "同名目录已存在"
    end

    return normalized_name
end

function module.validate_rename_resource(guid, raw_name)
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return nil, "无法定位资源"
    end

    local normalized_name, err = _validate_common_name(_strip_matching_extension(raw_name, meta.ext))
    if not normalized_name then
        return nil, err
    end
    if normalized_name == meta.file_stem then
        return nil, "名称未发生变化"
    end

    local target_path = _build_resource_path(meta.relative_dir, normalized_name, meta.ext)
    local target_meta_path = string.format("%s.meta", target_path)
    if not _is_path_inside_root(target_path) then
        return nil, "目标路径超出资源目录"
    end
    if NativeIO.file_exists(target_path) or NativeIO.directory_exists(target_path) then
        return nil, "同名文件已存在"
    end
    if target_meta_path ~= meta.meta_path and (NativeIO.file_exists(target_meta_path) or NativeIO.directory_exists(target_meta_path)) then
        return nil, "同名资源元数据文件已存在"
    end

    return normalized_name
end

function module.validate_rename_directory(relative_dir, raw_name)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    if normalized_relative_dir == "" then
        return nil, "根目录不允许重命名"
    end

    local normalized_name, err = _validate_common_name(raw_name)
    if not normalized_name then
        return nil, err
    end
    if normalized_name == _get_base_name(normalized_relative_dir) then
        return nil, "名称未发生变化"
    end

    local parent_relative_dir = _get_parent_relative_dir(normalized_relative_dir)
    local next_relative_dir = _to_relative_dir(_join_path(parent_relative_dir, normalized_name))
    local target_path = _build_directory_path(next_relative_dir)
    if not _is_path_inside_root(target_path) then
        return nil, "目标路径超出资源目录"
    end
    if NativeIO.directory_exists(target_path) or NativeIO.file_exists(target_path) then
        return nil, "同名目录已存在"
    end

    return normalized_name
end

function module.validate_delete_resource(guid)
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return nil, "无法定位资源"
    end
    local document = _find_document_for_meta(meta)
    if _is_document_modified(document) then
        return nil, string.format("资源存在未保存修改，请先保存：%s", meta.file_name or meta.relative_path or meta.display_name or meta.guid)
    end
    return meta
end

function module.validate_delete_directory(relative_dir)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    if normalized_relative_dir == "" then
        return nil, "根目录不允许删除"
    end

    local target_path = _build_directory_path(normalized_relative_dir)
    if not _is_path_inside_root(target_path) then
        return nil, "目标路径超出资源目录"
    end
    if not NativeIO.directory_exists(target_path) then
        return nil, "目录不存在"
    end

    local modified_meta = _find_modified_meta_under_directory(normalized_relative_dir)
    if modified_meta then
        return nil, string.format("文件夹内存在未保存修改，请先保存：%s",
            modified_meta.file_name or modified_meta.relative_path or modified_meta.display_name or modified_meta.guid)
    end

    return normalized_relative_dir
end

function module.create_resource_file(kind, relative_dir, raw_name)
    local definition = _find_resource_kind(kind)
    if not definition then
        return nil, "未知的资源类型"
    end

    local normalized_name, validate_err = module.validate_create_resource(kind, relative_dir, raw_name)
    if not normalized_name then
        return nil, validate_err
    end

    local target_relative_dir = _to_relative_dir(relative_dir ~= nil and relative_dir or definition.default_relative_dir)
    local target_dir_path = _build_directory_path(target_relative_dir)
    local target_path = _build_resource_path(target_relative_dir, normalized_name, definition.ext)
    local ok_make_dir, err_make_dir = NativeIO.create_directories(target_dir_path)
    if not ok_make_dir then
        return nil, err_make_dir or "无法创建资源目录"
    end

    local ok_create, err_create = _create_resource_payload(kind, target_path)
    if not ok_create then
        return nil, err_create or "无法创建资源文件"
    end

    _refresh_resource_world({force_editor_refresh = true})
    local meta = ResourceIndex.find_by_path(target_path)
    if not meta then
        return nil, "资源创建成功，但刷新后无法定位新资源"
    end

    LogManager.log(string.format("已创建%s：%s", definition.display_name, target_path), "info")
    return _build_resource_result(meta)
end

function module.create_folder(relative_dir, raw_name)
    local normalized_name, validate_err = module.validate_create_folder(relative_dir, raw_name)
    if not normalized_name then
        return nil, validate_err
    end

    local target_relative_dir = _to_relative_dir(_join_path(relative_dir, normalized_name))
    local target_path = _build_directory_path(target_relative_dir)
    local ok, err = NativeIO.create_directories(target_path)
    if not ok then
        return nil, err or "无法创建目录"
    end

    _refresh_resource_world({force_editor_refresh = true})
    LogManager.log(string.format("已创建文件夹：%s", target_path), "info")
    return _build_directory_result(target_relative_dir)
end

function module.rename_resource_file(guid, raw_name)
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return nil, "无法定位资源"
    end

    local normalized_name, validate_err = module.validate_rename_resource(guid, raw_name)
    if not normalized_name then
        return nil, validate_err
    end

    local current_path = meta.path
    local current_meta_path = meta.meta_path
    local target_path = _build_resource_path(meta.relative_dir, normalized_name, meta.ext)
    local target_meta_path = string.format("%s.meta", target_path)

    local ok_rename, err_rename = NativeIO.rename(current_path, target_path)
    if not ok_rename then
        return nil, err_rename or "无法重命名资源文件"
    end

    if current_meta_path ~= target_meta_path and NativeIO.file_exists(current_meta_path) then
        local ok_meta, err_meta = NativeIO.rename(current_meta_path, target_meta_path)
        if not ok_meta then
            local ok_revert, err_revert = NativeIO.rename(target_path, current_path)
            if not ok_revert then
                LogManager.log(
                    string.format("资源重命名回滚失败：%s -> %s\n%s", target_path, current_path, err_revert or "未知错误"),
                    "error")
                return nil, string.format("无法重命名资源元数据文件，且资源文件回滚失败：%s", err_meta or "未知错误")
            end
            return nil, err_meta or "无法重命名资源元数据文件"
        end
    end

    _refresh_resource_world({force_editor_refresh = true})
    local next_meta = ResourceIndex.find_by_path(target_path)
    if not next_meta then
        return nil, "资源重命名成功，但刷新后无法定位目标资源"
    end

    LogManager.log(string.format("已重命名资源：%s -> %s", current_path, target_path), "info")
    return _build_resource_result(next_meta)
end

function module.rename_directory(relative_dir, raw_name)
    local normalized_relative_dir = _to_relative_dir(relative_dir)
    local normalized_name, validate_err = module.validate_rename_directory(normalized_relative_dir, raw_name)
    if not normalized_name then
        return nil, validate_err
    end

    local old_path = _build_directory_path(normalized_relative_dir)
    local parent_relative_dir = _get_parent_relative_dir(normalized_relative_dir)
    local next_relative_dir = _to_relative_dir(_join_path(parent_relative_dir, normalized_name))
    local next_path = _build_directory_path(next_relative_dir)
    local ok, err = NativeIO.rename(old_path, next_path)
    if not ok then
        return nil, err or "无法重命名目录"
    end

    _refresh_resource_world({force_editor_refresh = true})
    LogManager.log(string.format("已重命名文件夹：%s -> %s", old_path, next_path), "info")
    return _build_directory_result(next_relative_dir)
end

function module.delete_resource_file(guid)
    local meta, validate_err = module.validate_delete_resource(guid)
    if not meta then
        return nil, validate_err
    end

    _close_open_document_for_meta(meta)

    local ok_remove, err_remove = NativeIO.remove_file(meta.path)
    if not ok_remove then
        return nil, err_remove or "无法删除资源文件"
    end

    if meta.meta_path and NativeIO.file_exists(meta.meta_path) then
        local ok_meta, err_meta = NativeIO.remove_file(meta.meta_path)
        if not ok_meta then
            LogManager.log(string.format("删除资源元数据失败：%s\n%s", meta.meta_path, err_meta or "未知错误"), "warning")
        end
    end

    if meta.type == "video" then
        local cleanup_result, cleanup_err = VideoImporter.cleanup_cache_for_guid(meta.guid)
        if not cleanup_result then
            LogManager.log(string.format("删除视频缓存失败：%s\n%s", meta.guid, cleanup_err or "未知错误"), "warning")
        end
    end

    _refresh_resource_world({force_editor_refresh = true})
    LogManager.log(string.format("已删除资源：%s", meta.path), "info")
    return _build_directory_result(meta.relative_dir or "")
end

function module.delete_directory(relative_dir)
    local normalized_relative_dir, validate_err = module.validate_delete_directory(relative_dir)
    if not normalized_relative_dir then
        return nil, validate_err
    end

    local target_path = _build_directory_path(normalized_relative_dir)
    local parent_relative_dir = _get_parent_relative_dir(normalized_relative_dir)

    _close_open_documents_under_directory(normalized_relative_dir)

    local ok_remove, err_remove = NativeIO.remove_directory(target_path, true)
    if not ok_remove then
        return nil, err_remove or "无法删除文件夹"
    end

    _refresh_resource_world({force_editor_refresh = true})
    LogManager.log(string.format("已删除文件夹：%s", target_path), "info")
    return _build_directory_result(parent_relative_dir)
end

return module

local rl = Engine.Raylib
local json = Engine.JSON
local util = Engine.Util

local AudioPlaybackManager = require("application.framework.audio_playback_manager")
local FlowManager = require("application.framework.flow_manager")
local FlowRuntimeHost = require("application.framework.flow_runtime_host")
local GlobalContext = require("application.framework.global_context")
local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")
local SaveMigration = require("application.framework.save_migration")
local SaveBoundaryDescriptor = require("application.framework.save_boundary_descriptor")
local SaveLocation = require("application.framework.save_location")
local SaveProfile = require("application.framework.save_profile")
local Scene = require("application.framework.scene")
local SettingsManager = require("application.framework.settings_manager")
local StyleManager = require("application.framework.style_manager")
local UIRuntime = require("application.framework.ui_runtime")

local module = {}

local schema_version <const> = 1
local clone_depth_limit <const> = 256
local persist_depth_limit <const> = 128
local root_global_key_pool =
{
    runtime = true,
    scene = true,
    ui = true,
    globals = true,
    style = true,
    audio = true,
    services = true,
    custom_data = true,
    settings = true,
    state = true,
}

local LogManager = false
local save_thumbnail_cache_module = false
local save_load_result_toast_module = false
local storage_override = nil
local storage_resolution_cache =
{
    signature = nil,
    info = nil,
    err = nil,
    resolved_at = 0,
    warned_signature = nil,
}
local storage_resolution_cache_ttl <const> = 1.0
local active_profile_warning_signature = nil
local runtime_session =
{
    initialized = false,
    running = false,
    playtime_ms = 0,
    last_saved_slot_id = nil,
    loaded_slot_id = nil,
}

local _collect_slot_state
local _prepare_persistable_slot_state
local _safe_collect_slot_state
local _safe_prepare_persistable_slot_state
local _resolve_slot_document_resource

local function _get_log_manager()
    if LogManager == false then
        LogManager = require("application.framework.log_manager")
    end
    return LogManager
end

local function _get_save_load_result_toast()
    if save_load_result_toast_module == false then
        save_load_result_toast_module = require("application.framework.save_load_result_toast")
    end
    return save_load_result_toast_module
end

local function _notify_load_success()
    pcall(function()
        local toast = _get_save_load_result_toast()
        if toast and toast.notify_loaded then
            toast.notify_loaded()
        end
    end)
end

local function _notify_load_failed()
    pcall(function()
        local toast = _get_save_load_result_toast()
        if toast and toast.notify_load_failed then
            toast.notify_load_failed()
        end
    end)
end

local function _log(message, type_message)
    local logger = _get_log_manager()
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

local function _clone_value(value, seen, depth)
    if type(value) ~= "table" then
        return value
    end

    depth = (depth or 0) + 1
    if depth > clone_depth_limit then
        return nil
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in next, value do
        local cloned_key = _clone_value(key, seen, depth)
        if cloned_key ~= nil then
            copy[cloned_key] = _clone_value(item, seen, depth)
        end
    end
    return copy
end

local function _copy_save_options(options)
    local result = {}
    if type(options) == "table" then
        for key, value in pairs(options) do
            result[key] = value
        end
    end
    return result
end

local function _value_equal(left, right, seen)
    if left == right then
        return true
    end

    local left_type = type(left)
    if left_type ~= type(right) then
        return false
    end
    if left_type ~= "table" then
        return false
    end

    seen = seen or {}
    if seen[left] == right then
        return true
    end
    seen[left] = right

    local left_count = 0
    for key, value in next, left do
        left_count = left_count + 1
        if not _value_equal(value, right[key], seen) then
            seen[left] = nil
            return false
        end
    end

    local right_count = 0
    for _ in next, right do
        right_count = right_count + 1
    end

    seen[left] = nil
    return left_count == right_count
end

local function _is_finite_number(value)
    local number = tonumber(value)
    return number ~= nil and number == number and number ~= math.huge and number ~= -math.huge
end

local function _read_number_field(value, key)
    local ok, result = pcall(function()
        return value[key]
    end)
    if not ok then
        return nil
    end
    local number = tonumber(result)
    if not _is_finite_number(number) then
        return nil
    end
    return number
end

local function _try_clone_persistable_userdata(value)
    if type(value) ~= "userdata" then
        return nil
    end

    local r = _read_number_field(value, "r")
    local g = _read_number_field(value, "g")
    local b = _read_number_field(value, "b")
    local a = _read_number_field(value, "a")
    if r ~= nil and g ~= nil and b ~= nil and a ~= nil then
        return
        {
            r = r,
            g = g,
            b = b,
            a = a,
        }
    end

    local x = _read_number_field(value, "x")
    local y = _read_number_field(value, "y")
    if x ~= nil and y ~= nil then
        local z = _read_number_field(value, "z")
        local w = _read_number_field(value, "w")
        if z ~= nil and w ~= nil then
            return
            {
                x = x,
                y = y,
                z = z,
                w = w,
            }
        end

        local width = _read_number_field(value, "width")
        local height = _read_number_field(value, "height")
        if width ~= nil and height ~= nil then
            return
            {
                x = x,
                y = y,
                width = width,
                height = height,
            }
        end

        return
        {
            x = x,
            y = y,
        }
    end

    return nil
end

local function _format_persist_path(path)
    if type(path) ~= "table" or #path == 0 then
        return "$"
    end
    return "$" .. table.concat(path, "")
end

local function _format_persist_key_segment(key)
    if type(key) == "number" then
        return string.format("[%s]", tostring(key))
    end

    local text = tostring(key)
    if text:match("^[%a_][%w_]*$") then
        return "." .. text
    end
    return string.format("[%q]", text)
end

local function _append_persist_path(path, key)
    local next_path = {}
    if type(path) == "table" then
        for index, segment in ipairs(path) do
            next_path[index] = segment
        end
    end
    next_path[#next_path + 1] = _format_persist_key_segment(key)
    return next_path
end

local function _with_persist_path(err, path)
    local message = tostring(err or "当前存档数据包含不能写入的值")
    if message:find("(path:", 1, true) then
        return message
    end
    return string.format("%s (path: %s)", message, _format_persist_path(path))
end

local function _clone_persistable_value(value, seen, depth, path)
    local value_type = type(value)
    if value_type == "nil" or value_type == "boolean" or value_type == "string" then
        return value
    end
    if value_type == "number" then
        if not _is_finite_number(value) then
            return nil, _with_persist_path("不支持持久化数值：NaN/Infinity", path)
        end
        return value
    end
    if value_type == "userdata" then
        local converted = _try_clone_persistable_userdata(value)
        if converted ~= nil then
            return converted
        end
    end
    if value_type ~= "table" then
        return nil, _with_persist_path(string.format("不支持持久化类型：%s", value_type), path)
    end

    depth = (depth or 0) + 1
    if depth > persist_depth_limit then
        return nil, _with_persist_path(string.format("持久化数据嵌套过深，超过 %d 层", persist_depth_limit), path)
    end
    seen = seen or {}
    if seen[value] then
        return nil, _with_persist_path("检测到循环引用，无法写入持久化数据", path)
    end
    seen[value] = true

    local copy = {}
    for key, item in next, value do
        local key_type = type(key)
        if key_type ~= "string" and key_type ~= "number" then
            seen[value] = nil
            return nil, _with_persist_path(string.format("持久化数据包含不能写入的键：%s", key_type), path)
        end
        local cloned_item, item_err = _clone_persistable_value(item, seen, depth, _append_persist_path(path, key))
        if item_err then
            seen[value] = nil
            return nil, item_err
        end
        copy[key] = cloned_item
    end

    seen[value] = nil
    return copy
end

local function _merge_missing_deep(target, defaults)
    if type(target) ~= "table" or type(defaults) ~= "table" then
        return target
    end

    for key, value in pairs(defaults) do
        if target[key] == nil then
            target[key] = _clone_value(value)
        elseif type(target[key]) == "table" and type(value) == "table" then
            _merge_missing_deep(target[key], value)
        end
    end

    return target
end

local function _normalize_slashes(path)
    local value = _trim(path)
    if not value then
        return nil
    end

    value = value:gsub("\\", "/")
    value = value:gsub("//+", "/")
    if #value > 1 then
        value = value:gsub("/$", "")
    end
    return value
end

local function _is_absolute_path(path)
    if type(path) ~= "string" then
        return false
    end
    return path:match("^[A-Za-z]:[/\\]") ~= nil
        or path:match("^//") ~= nil
        or path:match("^\\\\") ~= nil
end

local function _join_path(...)
    local result = nil
    for index = 1, select("#", ...) do
        local part = _normalize_slashes(select(index, ...))
        if part then
            if result == nil or result == "" then
                result = part
            else
                result = string.format("%s/%s", result, part:gsub("^/+", ""))
            end
        end
    end
    return _normalize_slashes(result)
end

local function _make_id_set(value_list)
    local result = {}
    for _, value in ipairs(type(value_list) == "table" and value_list or {}) do
        result[tostring(value)] = true
    end
    return result
end

local function _safe_tonumber(value, default_value)
    local number = tonumber(value)
    if number == nil then
        return default_value
    end
    return number
end

local function _format_iso8601(timestamp)
    local ts = tonumber(timestamp) or os.time()
    local local_date = os.date("*t", ts)
    local utc_date = os.date("!*t", ts)
    local local_epoch = os.time(local_date)
    local utc_epoch = os.time(utc_date)
    local offset_minutes = math.floor((local_epoch - utc_epoch) / 60)
    local sign = offset_minutes >= 0 and "+" or "-"
    local absolute_minutes = math.abs(offset_minutes)
    local offset_hours = math.floor(absolute_minutes / 60)
    local offset_rest_minutes = absolute_minutes % 60
    return string.format(
        "%04d-%02d-%02dT%02d:%02d:%02d%s%02d:%02d",
        local_date.year,
        local_date.month,
        local_date.day,
        local_date.hour,
        local_date.min,
        local_date.sec,
        sign,
        offset_hours,
        offset_rest_minutes)
end

local function _get_project_version()
    return SettingsManager.get("project_version") or ""
end

local function _apply_payload_metadata(payload, info, version)
    payload = type(payload) == "table" and payload or {}
    payload.schema_version = version or payload.schema_version or schema_version
    payload.project_guid = info.project_guid
    payload.project_version = _get_project_version()
    payload.engine_version = GlobalContext.version
    return payload
end

local function _ensure_parent_directory(path)
    local directory = type(path) == "string" and path:match("^(.*)[/\\][^/\\]+$") or nil
    if directory and directory ~= "" then
        NativeIO.create_directories(directory)
    end
end

local function _read_json_file(path)
    local content, err = NativeIO.read_text(path)
    if not content then
        return nil, err
    end

    local ok, data = json.ParseToLua(content)
    if not ok or type(data) ~= "table" then
        return nil, "JSON 解析失败"
    end
    return data
end

local function _remove_file_if_exists(path)
    if path and NativeIO.file_exists(path) then
        local ok, err = NativeIO.remove_file(path)
        if ok ~= true then
            return false, err
        end
    end
    return true
end

local function _restore_backup_file(path, backup_path)
    local ok, err = _remove_file_if_exists(path)
    if ok ~= true then
        return false, err
    end

    if backup_path and NativeIO.file_exists(backup_path) then
        return NativeIO.rename(backup_path, path)
    end
    return true
end

local function _replace_file_with_backup(path, temp_path, backup_path)
    local ok, err = _remove_file_if_exists(backup_path)
    if ok ~= true then
        return false, err
    end

    if NativeIO.file_exists(path) then
        ok, err = NativeIO.rename(path, backup_path)
        if ok ~= true then
            return false, err
        end
    end

    ok, err = NativeIO.rename(temp_path, path)
    if ok ~= true then
        local restore_ok, restore_err = _restore_backup_file(path, backup_path)
        if restore_ok ~= true then
            return false, string.format("%s；恢复备份失败：%s", err or "替换文件失败", restore_err or "未知错误")
        end
        return false, err
    end
    return true
end

local function _write_json_file(path, data, pretty)
    local ensure_ok, ensure_err = _ensure_parent_directory(path)
    if ensure_ok ~= true then
        return false, ensure_err or "无法创建父目录"
    end

    local temp_path = string.format("%s.tmp", path)
    local backup_path = string.format("%s.bak", path)
    local payload, payload_err = _clone_persistable_value(type(data) == "table" and data or {})
    if not payload then
        return false, payload_err or "JSON 数据包含不能保存的运行时对象"
    end

    local ok_print, content = pcall(json.PrintFromLua, payload, pretty == true)
    if not ok_print or type(content) ~= "string" then
        return false, "JSON 序列化失败"
    end

    local ok, err = _remove_file_if_exists(temp_path)
    if ok ~= true then
        return false, err
    end

    ok, err = NativeIO.write_text(temp_path, content)
    if not ok then
        return false, err
    end

    ok, err = _replace_file_with_backup(path, temp_path, backup_path)
    if not ok then
        NativeIO.remove_file(temp_path)
        return false, err
    end
    _remove_file_if_exists(backup_path)
    return true
end

local function _get_game_directory()
    local directory = _normalize_slashes(rl.GetApplicationDirectory and rl.GetApplicationDirectory() or nil)
    if not directory then
        directory = _normalize_slashes(rl.GetWorkingDirectory and rl.GetWorkingDirectory() or nil)
    end
    return directory or "."
end

local function _path_exists_as_directory(path)
    local normalized_path = _normalize_slashes(path)
    if not normalized_path then
        return false
    end

    local ok, exists = pcall(NativeIO.directory_exists, normalized_path)
    return ok and exists == true
end

local function _resolve_openable_directory_path(info, path)
    local normalized_path = _normalize_slashes(path)
    if not normalized_path then
        return nil
    end
    if _is_absolute_path(normalized_path) then
        return normalized_path
    end

    local candidates = {}
    local seen = {}
    local function add_candidate(base)
        local normalized_base = _normalize_slashes(base)
        if not normalized_base then
            return
        end
        local candidate = _join_path(normalized_base, normalized_path)
        if candidate and not seen[candidate] then
            seen[candidate] = true
            table.insert(candidates, candidate)
        end
    end

    add_candidate(rl.GetWorkingDirectory and rl.GetWorkingDirectory() or nil)
    add_candidate(info and info.game_dir or nil)
    add_candidate(_get_game_directory())

    for _, candidate in ipairs(candidates) do
        if _path_exists_as_directory(candidate) then
            return candidate
        end
    end

    return candidates[1] or normalized_path
end

local function _to_shell_directory_path(path)
    local normalized_path = _normalize_slashes(path)
    if not normalized_path then
        return nil
    end
    return normalized_path:gsub("/", "\\")
end

local function _probe_write_access(path)
    if not path then
        return false
    end

    local ok, err = NativeIO.create_directories(path)
    if not ok then
        return false, err
    end

    local probe_path = _join_path(path, ".__vne_save_probe.tmp")
    ok, err = NativeIO.write_text(probe_path, "probe")
    if not ok then
        return false, err
    end
    NativeIO.remove_file(probe_path)
    return true
end

local function _normalize_storage_mode(value)
    local mode = _trim(value) or "auto"
    if mode ~= "auto" and mode ~= "game_dir" and mode ~= "pref_path" and mode ~= "custom" then
        return "auto"
    end
    return mode
end

local function _get_project_guid(options)
    local resolve_options = type(options) == "table" and options or {}
    local guid = util.NormalizeGuidString(SettingsManager.get("project_guid") or "")
    if guid and guid ~= "" then
        return guid
    end

    if resolve_options.create_if_missing == false then
        return ""
    end

    guid = util.NewGuidString()
    SettingsManager.set("project_guid", guid)
    return guid
end

local function _load_active_profile(options)
    local resolve_options = type(options) == "table" and options or {}
    local profile_guid = util.NormalizeGuidString(SettingsManager.get("save_profile_guid") or "") or ""
    if profile_guid == "" then
        active_profile_warning_signature = nil
        return SaveProfile.get_default(), "", nil
    end

    local meta = ResourceIndex.find_by_guid(profile_guid)
    if not meta or not meta.path then
        local err = string.format("找不到存档配置资源：%s", profile_guid)
        local warning_signature = string.format("missing|%s", profile_guid)
        if resolve_options.emit_warning ~= false and active_profile_warning_signature ~= warning_signature then
            _log(string.format("找不到存档配置资源，已回退到默认配置：%s", profile_guid), "warning")
            active_profile_warning_signature = warning_signature
        end
        return SaveProfile.get_default(), "", err
    end

    local profile, err = SaveProfile.load(meta.path)
    if not profile then
        local load_err = tostring(err or "存档配置资源加载失败")
        local warning_signature = string.format("load_failed|%s|%s", profile_guid, load_err)
        if resolve_options.emit_warning ~= false and active_profile_warning_signature ~= warning_signature then
            _log(string.format("存档配置资源加载失败，已回退到默认配置：%s", load_err), "warning")
            active_profile_warning_signature = warning_signature
        end
        return SaveProfile.get_default(), "", load_err
    end

    active_profile_warning_signature = nil
    return profile, profile_guid, nil
end

local function _get_requested_storage_options(options)
    local resolve_options = type(options) == "table" and options or {}
    local configured_project_guid = util.NormalizeGuidString(SettingsManager.get("project_guid") or "") or ""
    local configured_profile_guid = util.NormalizeGuidString(SettingsManager.get("save_profile_guid") or "") or ""
    local profile, profile_guid, profile_load_error = _load_active_profile(
    {
        emit_warning = resolve_options.emit_profile_warning ~= false,
    })
    local override = type(storage_override) == "table" and storage_override or nil
    local options =
    {
        project_guid = _get_project_guid(
        {
            create_if_missing = resolve_options.create_project_guid ~= false,
        }),
        configured_project_guid = configured_project_guid,
        project_guid_missing = configured_project_guid == "",
        profile = profile,
        profile_guid = profile_guid,
        configured_profile_guid = configured_profile_guid,
        profile_load_error = profile_load_error,
        pretty_json = true,
        mode = override and override.mode or nil,
        custom_root = override and (override.root or override.custom_root) or nil,
        subdirectory_name = "save",
    }

    if not options.mode then
        options.mode = SettingsManager.get("save_storage_mode")
    end
    if not options.mode and profile.storage then
        options.mode = profile.storage.mode
    end
    options.mode = _normalize_storage_mode(options.mode)

    if options.custom_root == nil then
        options.custom_root = SettingsManager.get("save_custom_root")
    end
    if (options.custom_root == nil or options.custom_root == "") and profile.storage then
        options.custom_root = profile.storage.custom_root
    end
    options.custom_root = options.custom_root or ""

    return options
end

local function _build_storage_info(mode, options)
    local options = _get_requested_storage_options(options)
    local project_guid = options.project_guid
    local game_dir = _get_game_directory()
    local requested_mode = _normalize_storage_mode(mode or options.mode)
    local resolved_mode = requested_mode
    local default_root_path = _normalize_slashes(options.subdirectory_name) or "save"
    local single_file_root_path = _join_path(GlobalContext.get_pref_path(), "runtime", project_guid)
    local root_path = nil

    if resolved_mode == "auto" then
        if SettingsManager.get("release_mode") and SettingsManager.get("single_file") then
            resolved_mode = "pref_path"
        else
            resolved_mode = "game_dir"
        end
    end

    if resolved_mode == "game_dir" then
        root_path = default_root_path
    elseif resolved_mode == "pref_path" then
        root_path = single_file_root_path
    elseif resolved_mode == "custom" then
        local custom_root = _normalize_slashes(options.custom_root)
        if not custom_root then
            root_path = default_root_path
            resolved_mode = "game_dir"
        elseif _is_absolute_path(custom_root) then
            root_path = custom_root
        else
            root_path = custom_root
        end
    else
        root_path = default_root_path
        resolved_mode = "game_dir"
    end

    return
    {
        project_guid = project_guid,
        configured_project_guid = options.configured_project_guid,
        project_guid_missing = options.project_guid_missing == true,
        profile = options.profile,
        profile_guid = options.profile_guid,
        configured_profile_guid = options.configured_profile_guid,
        profile_load_error = options.profile_load_error,
        pretty_json = options.pretty_json == true,
        requested_mode = requested_mode,
        resolved_mode = resolved_mode,
        default_root_path = default_root_path,
        single_file_root_path = single_file_root_path,
        root_path = root_path,
        saves_root = _join_path(root_path, "saves"),
        manual_root = _join_path(root_path, "saves", "manual"),
        cache_root = _join_path(root_path, "saves", "cache"),
        persistent_root = _join_path(root_path, "persistent"),
        settings_root = _join_path(root_path, "settings"),
        diagnostics_root = _join_path(root_path, "diagnostics"),
        game_dir = game_dir,
    }
end

local function _build_storage_resolution_signature(info)
    return table.concat(
    {
        tostring(info and info.project_guid or ""),
        tostring(info and info.profile_guid or ""),
        tostring(info and info.requested_mode or ""),
        tostring(info and info.resolved_mode or ""),
        tostring(info and info.root_path or ""),
        tostring(SettingsManager.get("release_mode") == true),
        tostring(SettingsManager.get("single_file") == true),
    }, "|")
end

local _resolve_storage_info_for_runtime

local function _resolve_storage_info_for_write()
    return _resolve_storage_info_for_runtime(
    {
        emit_warning = true,
    })
end

_resolve_storage_info_for_runtime = function(options)
    local resolve_options = type(options) == "table" and options or {}
    local info = _build_storage_info()
    local signature = _build_storage_resolution_signature(info)
    local now_time = rl.GetTime and rl.GetTime() or 0
    if storage_resolution_cache.signature == signature
        and (now_time - (tonumber(storage_resolution_cache.resolved_at) or 0)) < storage_resolution_cache_ttl
    then
        if storage_resolution_cache.info then
            if resolve_options.emit_warning == true
                and storage_resolution_cache.info.fallback_applied == true
                and storage_resolution_cache.warned_signature ~= signature
            then
                _log(string.format("存档目录不可写，已自动回退到用户数据目录：%s", tostring(storage_resolution_cache.info.write_error or storage_resolution_cache.info.primary_root_path or storage_resolution_cache.info.root_path)), "warning")
                storage_resolution_cache.warned_signature = signature
            end
            return _clone_value(storage_resolution_cache.info)
        end
        return nil, storage_resolution_cache.err
    end

    local ok, err = _probe_write_access(info.root_path)
    if ok then
        info.primary_root_path = info.root_path
        info.primary_resolved_mode = info.resolved_mode
        info.fallback_applied = false
        info.write_error = nil
        storage_resolution_cache.signature = signature
        storage_resolution_cache.info = _clone_value(info)
        storage_resolution_cache.err = nil
        storage_resolution_cache.resolved_at = now_time
        storage_resolution_cache.warned_signature = nil
        return info
    end

    if info.resolved_mode ~= "pref_path" then
        local fallback_info = _build_storage_info("pref_path")
        local fallback_ok, fallback_err = _probe_write_access(fallback_info.root_path)
        if fallback_ok then
            fallback_info.primary_root_path = info.root_path
            fallback_info.primary_resolved_mode = info.resolved_mode
            fallback_info.fallback_applied = true
            fallback_info.write_error = err
            storage_resolution_cache.signature = signature
            storage_resolution_cache.info = _clone_value(fallback_info)
            storage_resolution_cache.err = nil
            storage_resolution_cache.resolved_at = now_time
            storage_resolution_cache.warned_signature = nil
            if resolve_options.emit_warning == true then
                _log(string.format("存档目录不可写，已自动回退到用户数据目录：%s", tostring(err or info.root_path)), "warning")
                storage_resolution_cache.warned_signature = signature
            end
            return fallback_info
        end
        storage_resolution_cache.signature = signature
        storage_resolution_cache.info = nil
        storage_resolution_cache.err = fallback_err or err or "无法写入存档目录"
        storage_resolution_cache.resolved_at = now_time
        storage_resolution_cache.warned_signature = nil
        return nil, fallback_err or err or "无法写入存档目录"
    end

    storage_resolution_cache.signature = signature
    storage_resolution_cache.info = nil
    storage_resolution_cache.err = err or "无法写入存档目录"
    storage_resolution_cache.resolved_at = now_time
    storage_resolution_cache.warned_signature = nil
    return nil, err or "无法写入存档目录"
end
local function _ensure_storage_directories(info)
    local path_list =
    {
        info.root_path,
        info.saves_root,
        info.manual_root,
        info.cache_root,
        info.persistent_root,
        info.settings_root,
        info.diagnostics_root,
    }

    for _, path in ipairs(path_list) do
        local ok, err = NativeIO.create_directories(path)
        if not ok then
            return false, err
        end
    end

    return true
end

local _derive_slot_category
local _notify_runtime_switch_reset

local function _get_location_options(info)
    local profile = type(info) == "table" and info.profile or nil
    local manual = type(profile) == "table" and type(profile.manual) == "table" and profile.manual or nil
    return
    {
        slots_per_page = tonumber(manual and manual.slots_per_page) or SaveLocation.get_default_slots_per_page(),
    }
end

local function _normalize_location(value, info, options)
    local normalize_options = _get_location_options(info)
    if type(options) == "table" then
        for key, item in pairs(options) do
            normalize_options[key] = item
        end
    end
    return SaveLocation.normalize(value, normalize_options)
end

local function _location_to_storage_id(location, info)
    return SaveLocation.to_storage_id(location, _get_location_options(info))
end

local function _normalize_slot_category(value)
    return SaveLocation.normalize_category(value)
end

local function _storage_category_for_slot(category)
    return "manual"
end

local function _format_slot_id_for_user(slot_id, category)
    local location = SaveLocation.from_storage_id(slot_id)
        or SaveLocation.normalize(slot_id, {category = category})
        or SaveLocation.normalize({category = category, page = 1, index = 1})
    return SaveLocation.display_name(location) or _trim(slot_id) or "未命名存档"
end

local function _normalize_user_slot_text(text)
    local value = _trim(text)
    if not value then
        return nil
    end
    value = value:gsub("　", " ")
    value = value:gsub("%s+", " ")
    return value
end

local function _normalize_slot_id_for_storage(info, slot_id, category)
    local location = _normalize_location(slot_id, info, {category = category})
    if location then
        return _location_to_storage_id(location, info)
    end
    return _normalize_user_slot_text(slot_id)
end

function _derive_slot_category(slot_id)
    local location = SaveLocation.from_storage_id(slot_id)
    return _storage_category_for_slot(location and location.category or "manual")
end

local function _slot_root_by_category(info, category)
    return info.manual_root
end

local function _slot_directory(info, slot_id, category)
    return _join_path(_slot_root_by_category(info, category), slot_id)
end

local function _slot_manifest_path(info, slot_id, category)
    return _join_path(_slot_directory(info, slot_id, category), "manifest.json")
end

local function _slot_state_path(info, slot_id, category)
    return _join_path(_slot_directory(info, slot_id, category), "state.json")
end

local function _is_slot_manifest_continue_candidate(info, manifest)
    if type(info) ~= "table" or type(manifest) ~= "table" then
        return false
    end

    local slot_id = _trim(manifest.slot_id)
    if not slot_id then
        return false
    end

    local category = _normalize_slot_category(manifest.category or _derive_slot_category(slot_id))
    local state_path = _slot_state_path(info, slot_id, category)
    if not NativeIO.file_exists(state_path) then
        return false
    end

    if _resolve_slot_document_resource({}, manifest) then
        return true
    end

    local state = _read_json_file(state_path)
    if type(state) ~= "table" then
        return false
    end

    state = SaveMigration.migrate_slot_state(state,
    {
        project_guid = info.project_guid,
        project_version = _get_project_version(),
        engine_version = GlobalContext.version,
        save_profile_guid = info.profile_guid,
        slot_id = slot_id,
    })
    if type(state) ~= "table" then
        return false
    end

    return _resolve_slot_document_resource(type(state.runtime) == "table" and state.runtime or {}, manifest) ~= nil
end

local function _slot_thumbnail_path(info, slot_id, category)
    return _join_path(_slot_directory(info, slot_id, category), "thumbnail.png")
end

local function _slot_index_path(info)
    return _join_path(info.cache_root, "slot_index.json")
end

local function _global_payload_path(info)
    return _join_path(info.persistent_root, "global.json")
end

local function _settings_payload_path(info)
    return _join_path(info.settings_root, "runtime_settings.json")
end

local function _diagnostics_trace_path(info)
    return _join_path(info.diagnostics_root, "tracesave_last.json")
end

local function _save_slot_manifest_internal(info, slot_id, category, manifest)
    local payload, payload_err = _clone_persistable_value(type(manifest) == "table" and manifest or {})
    if not payload then
        return false, payload_err
    end
    payload.location = SaveLocation.to_manifest_location(payload.location or SaveLocation.from_storage_id(slot_id), _get_location_options(info))
    payload.slot_id = nil
    payload.slot_display_name = nil
    payload.storage_id = nil
    payload.semantic_id = nil
    payload.display_name = nil
    payload.category = nil
    _apply_payload_metadata(payload, info, payload.schema_version)
    return _write_json_file(_slot_manifest_path(info, slot_id, category), payload, info.pretty_json)
end

local function _save_slot_state_internal(info, slot_id, category, state)
    local payload, payload_err
    if _safe_prepare_persistable_slot_state then
        payload, payload_err = _safe_prepare_persistable_slot_state(state)
    else
        payload, payload_err = _prepare_persistable_slot_state(state)
    end
    if not payload then
        return false, payload_err
    end
    _apply_payload_metadata(payload, info)
    return _write_json_file(_slot_state_path(info, slot_id, category), payload, info.pretty_json)
end
local function _build_custom_domain_defaults(profile)
    return
    {
        slot = {},
        global = {},
        settings = {},
    }
end

local function _load_global_payload(info)
    local defaults = _build_custom_domain_defaults(info.profile)
    local payload =
    {
        schema_version = schema_version,
        project_guid = info.project_guid,
        project_version = _get_project_version(),
        engine_version = GlobalContext.version,
        seen_text = {},
        visited_events = {},
        unlocks = {},
        last_continue = nil,
        custom_data = defaults.global,
    }

    local loaded = _read_json_file(_global_payload_path(info))
    if type(loaded) == "table" then
        local migrated, migrate_err = SaveMigration.migrate_global_state(loaded,
        {
            project_guid = info.project_guid,
            project_version = _get_project_version(),
            engine_version = GlobalContext.version,
        })
        if migrated then
            for key, value in pairs(migrated) do
                payload[key] = _clone_value(value)
            end
        else
            _log(tostring(migrate_err), "warning")
        end
    end
    payload.custom_data = type(payload.custom_data) == "table" and payload.custom_data or {}
    _merge_missing_deep(payload.custom_data, defaults.global)
    _apply_payload_metadata(payload, info)
    return payload
end

local function _save_global_payload(info, payload)
    local normalized, payload_err = _clone_persistable_value(type(payload) == "table" and payload or {})
    if not normalized then
        return false, payload_err
    end
    _apply_payload_metadata(normalized, info)
    return _write_json_file(_global_payload_path(info), normalized, info.pretty_json)
end

local function _load_settings_payload(info)
    local defaults = _build_custom_domain_defaults(info.profile)
    local payload =
    {
        schema_version = schema_version,
        project_guid = info.project_guid,
        project_version = _get_project_version(),
        engine_version = GlobalContext.version,
        data = defaults.settings,
    }

    local loaded = _read_json_file(_settings_payload_path(info))
    if type(loaded) == "table" then
        local migrated, migrate_err = SaveMigration.migrate_runtime_settings(loaded,
        {
            project_guid = info.project_guid,
            project_version = _get_project_version(),
            engine_version = GlobalContext.version,
        })
        if migrated then
            for key, value in pairs(migrated) do
                payload[key] = _clone_value(value)
            end
        else
            _log(tostring(migrate_err), "warning")
        end
    end
    payload.data = type(payload.data) == "table" and payload.data or {}
    _merge_missing_deep(payload.data, defaults.settings)
    _apply_payload_metadata(payload, info)
    return payload
end

local function _save_settings_payload(info, payload)
    local normalized, payload_err = _clone_persistable_value(type(payload) == "table" and payload or {})
    if not normalized then
        return false, payload_err
    end
    _apply_payload_metadata(normalized, info)
    return _write_json_file(_settings_payload_path(info), normalized, info.pretty_json)
end

local function _slot_sorter(left, right)
    local left_time = tostring(left and left.updated_at or left and left.created_at or "")
    local right_time = tostring(right and right.updated_at or right and right.created_at or "")
    if left_time ~= right_time then
        return left_time > right_time
    end
    return tostring(left and left.slot_id or "") < tostring(right and right.slot_id or "")
end

local function _scan_slot_list(info, category)
    local result = {}
    local category_list = {"manual"}

    for _, current_category in ipairs(category_list) do
        local root = _slot_root_by_category(info, current_category)
        local path_list = NativeIO.list_directory_array(root, false, false) or {}
        for _, path in ipairs(path_list) do
            if NativeIO.directory_exists(path) then
                local slot_id = path:match("([^/\\]+)$") or ""
                local manifest = _read_json_file(_join_path(path, "manifest.json"))
                if type(manifest) == "table" then
                    manifest = SaveMigration.migrate_slot_manifest(manifest,
                    {
                        slot_id = slot_id,
                        category = current_category,
                        project_guid = info.project_guid,
                        project_version = _get_project_version(),
                        engine_version = GlobalContext.version,
                        save_profile_guid = info.profile_guid,
                    })
                end
                if type(manifest) == "table" then
                    local location = manifest.location or SaveLocation.from_storage_id(manifest.slot_id or slot_id, _get_location_options(info))
                    manifest.location = SaveLocation.to_manifest_location(location, _get_location_options(info))
                    manifest.slot_id = _location_to_storage_id(manifest.location, info) or slot_id
                    manifest.storage_id = manifest.slot_id
                    manifest.semantic_id = SaveLocation.semantic_id(manifest.location, _get_location_options(info))
                    manifest.slot_display_name = _format_slot_id_for_user(manifest.slot_id or slot_id, manifest.category or current_category)
                    manifest.display_name = manifest.slot_display_name
                    result[#result + 1] = manifest
                end
            end
        end
    end

    table.sort(result, _slot_sorter)
    _write_json_file(_slot_index_path(info),
    {
        schema_version = schema_version,
        engine_version = GlobalContext.version,
        project_version = _get_project_version(),
        project_guid = info.project_guid,
        updated_at = _format_iso8601(),
        slot_list = result,
    }, info.pretty_json)
    return result
end

local function _find_slot_manifest_internal(info, slot_id)
    local normalized_slot_id = _normalize_slot_id_for_storage(info, slot_id)
    if not normalized_slot_id then
        return nil, nil
    end

    local category = _derive_slot_category(normalized_slot_id)
    local manifest = _read_json_file(_slot_manifest_path(info, normalized_slot_id, category))
    if type(manifest) == "table" then
        manifest = SaveMigration.migrate_slot_manifest(manifest,
        {
            slot_id = normalized_slot_id,
            category = category,
            project_guid = info.project_guid,
            project_version = _get_project_version(),
            engine_version = GlobalContext.version,
            save_profile_guid = info.profile_guid,
        })
        if type(manifest) == "table" then
            local location = manifest.location or SaveLocation.from_storage_id(manifest.slot_id or normalized_slot_id, _get_location_options(info))
            manifest.location = SaveLocation.to_manifest_location(location, _get_location_options(info))
            manifest.slot_id = _location_to_storage_id(manifest.location, info) or normalized_slot_id
            manifest.storage_id = manifest.slot_id
            manifest.semantic_id = SaveLocation.semantic_id(manifest.location, _get_location_options(info))
            manifest.slot_display_name = _format_slot_id_for_user(manifest.slot_id or normalized_slot_id, manifest.category or category)
            manifest.display_name = manifest.slot_display_name
            return manifest, category
        end
    end

    return nil, nil
end

local function _load_slot_state_internal(info, slot_id)
    local manifest, category = _find_slot_manifest_internal(info, slot_id)
    if not manifest then
        return nil, nil, "找不到指定存档"
    end

    local state, err = _read_json_file(_slot_state_path(info, manifest.slot_id, category))
    if not state then
        return nil, manifest, err or "无法读取存档状态"
    end
    state, err = SaveMigration.migrate_slot_state(state,
    {
        project_guid = info.project_guid,
        project_version = _get_project_version(),
        engine_version = GlobalContext.version,
        save_profile_guid = info.profile_guid,
        slot_id = manifest.slot_id,
    })
    if not state then
        return nil, manifest, err or "存档状态迁移失败"
    end
    return state, manifest, nil
end

local function _get_runtime_document()
    local anchor = GlobalContext.get_runtime_save_anchor_document
        and GlobalContext.get_runtime_save_anchor_document()
        or nil
    if anchor ~= nil then
        return anchor
    end
    return FlowRuntimeHost.get_runtime_document and FlowRuntimeHost.get_runtime_document() or nil
end

local function _block_runtime_interaction_for_document(document, reason)
    local scene_context = document and document.get_runtime_scene_context and document:get_runtime_scene_context() or nil
    if scene_context and scene_context.block_runtime_interaction_until_release then
        scene_context:block_runtime_interaction_until_release(reason)
    end
end

local function _read_env_path(env, path)
    local current = env
    for part in tostring(path or ""):gmatch("[^%.]+") do
        if type(current) ~= "table" then
            return nil
        end

        if current[part] ~= nil then
            current = current[part]
        elseif root_global_key_pool[part] and env[part] ~= nil then
            current = env[part]
        else
            return nil
        end
    end
    return current
end

local function _resolve_binding_value(env, entry)
    if type(entry) ~= "table" then
        return nil
    end
    if entry.literal ~= nil then
        local literal = _clone_persistable_value(entry.literal)
        return literal
    end
    if entry.binding then
        local value = _read_env_path(env, entry.binding)
        if value ~= nil then
            local cloned = _clone_persistable_value(value)
            return cloned
        end
    end
    if entry.fallback ~= nil then
        local fallback = _clone_persistable_value(entry.fallback)
        return fallback
    end
    return nil
end

local function _build_runtime_location_text(runtime_state)
    if type(runtime_state) ~= "table" then
        return ""
    end

    local anchor = runtime_state.current_source_anchor or runtime_state.anchor or {}
    if runtime_state.kind == "text" then
        local label = _trim(anchor.label)
        if label then
            return string.format("#%s", label)
        end
        local line = tonumber(anchor.line)
        if line then
            return string.format("第 %d 行", line)
        end
        return "文本剧本"
    end

    if runtime_state.kind == "graph" then
        local node_title = _trim(anchor.node_title)
        if node_title then
            return node_title
        end
        local node_id = tonumber(anchor.node_id)
        if node_id then
            return string.format("节点 #%d", node_id)
        end
        return "流程图"
    end

    return tostring(runtime_state.kind or "")
end

local function _resolve_slot_anchor(manifest, runtime_state)
    if type(manifest) == "table" and type(manifest.anchor) == "table" then
        return _clone_value(manifest.anchor)
    end
    if type(runtime_state) == "table" and type(runtime_state.current_source_anchor) == "table" then
        return _clone_value(runtime_state.current_source_anchor)
    end
    if type(runtime_state) == "table" and type(runtime_state.anchor) == "table" then
        return _clone_value(runtime_state.anchor)
    end
    return {}
end

local function _collect_slot_document_candidates(runtime_state, manifest)
    local candidate_list =
    {
        _trim(runtime_state and runtime_state.document_guid),
        _trim(manifest and manifest.document_guid),
        _trim(manifest and manifest.flow_document_guid),
        _trim(runtime_state and runtime_state.document_path),
        _trim(manifest and manifest.document_path),
    }

    local result = {}
    local seen = {}
    for _, candidate in ipairs(candidate_list) do
        if candidate and not seen[candidate] then
            seen[candidate] = true
            table.insert(result, candidate)
        end
    end
    return result
end

local function _resolve_slot_navigation_document(runtime_state, manifest)
    for _, candidate in ipairs(_collect_slot_document_candidates(runtime_state, manifest)) do
        local document = FlowManager.find_by_guid(candidate) or FlowManager.find_by_identifier(candidate)
        if document then
            return document
        end
    end
    return nil
end

_resolve_slot_document_resource = function(runtime_state, manifest)
    for _, candidate in ipairs(_collect_slot_document_candidates(runtime_state, manifest)) do
        local document = FlowManager.find_by_guid(candidate) or FlowManager.find_by_identifier(candidate)
        if document and document._resource_missing ~= true then
            return document
        end

        local meta = ResourceIndex.find_by_guid(candidate) or ResourceIndex.find_by_path(candidate)
        if meta then
            return meta
        end
    end
    return nil
end

local function _can_use_live_slot_document(document)
    if not document then
        return false
    end
    if document._resource_missing or document._external_change_pending then
        return false
    end
    if document.is_modified and document:is_modified() then
        return false
    end
    return true
end

local function _resolve_slot_runtime_document(runtime_state, manifest, options)
    local resolve_options = type(options) == "table" and options or {}
    for _, candidate in ipairs(_collect_slot_document_candidates(runtime_state, manifest)) do
        local document = nil
        if resolve_options.isolated == true and FlowManager.create_runtime_document_snapshot then
            document = FlowManager.create_runtime_document_snapshot(candidate,
            {
                usage = resolve_options.usage or "flow_runtime",
            })
        else
            document = FlowManager.get_document(candidate, resolve_options.usage or "flow_runtime")
        end
        if document then
            return document
        end
    end
    return nil
end

local function _get_target_runtime_document(target)
    if type(target) ~= "table" then
        return nil
    end
    return target.runtime_document or target.document
end

local function _dispose_temporary_runtime_document(document)
    if not document or document._is_temporary_runtime_document ~= true then
        return
    end
    local active_runtime_document = _get_runtime_document()
    if active_runtime_document == document then
        return
    end
    if document.dispose then
        document:dispose()
    end
end

local function _cleanup_prepared_slot_target(target)
    if type(target) ~= "table" then
        return
    end
    _dispose_temporary_runtime_document(target.runtime_document)
    target.runtime_document = nil
end

local function _validate_prepared_slot_target(target)
    if type(target) ~= "table" then
        return false, "无法解析存档目标"
    end
    local runtime_document = _get_target_runtime_document(target)
    if not runtime_document then
        return false, "无法定位存档对应的流程文档"
    end
    if runtime_document.validate_runtime_save_state then
        return runtime_document:validate_runtime_save_state(target.runtime_state)
    end
    return true
end

local function _preflight_restore_target(target)
    local valid, validation_err = _validate_prepared_slot_target(target)
    if valid ~= true then
        return false, validation_err or "当前存档无法在现有文档结构上恢复"
    end

    local state = type(target.state) == "table" and target.state or {}
    local runtime_state = type(target.runtime_state) == "table" and target.runtime_state or {}
    local skip_object_id_set = _make_id_set(runtime_state.skip_object_ids)
    local skip_ui_instance_id_set = _make_id_set(runtime_state.skip_ui_instance_ids)

    if StyleManager.validate_runtime_state then
        local style_ok, style_err = StyleManager.validate_runtime_state(state.style or {})
        if style_ok ~= true then
            return false, style_err or "存档引用的样式无法恢复"
        end
    end

    if Scene.validate_save_state then
        local scene_ok, scene_err = Scene.validate_save_state(state.scene or {},
        {
            skip_object_id_set = skip_object_id_set,
        })
        if scene_ok ~= true then
            return false, scene_err or "存档引用的场景状态无法恢复"
        end
    end

    if UIRuntime.validate_save_state then
        local ui_ok, ui_err = UIRuntime.validate_save_state(state.ui or {},
        {
            skip_instance_id_set = skip_ui_instance_id_set,
        })
        if ui_ok ~= true then
            return false, ui_err or "存档引用的界面状态无法恢复"
        end
    end

    if AudioPlaybackManager.validate_runtime_state then
        local audio_ok, audio_err = AudioPlaybackManager.validate_runtime_state(state.audio or {})
        if audio_ok ~= true then
            return false, audio_err or "存档引用的音频状态无法恢复"
        end
    end

    return true
end

local function _copy_runtime_target_view(target)
    if type(target) ~= "table" then
        return nil
    end
    local document = target.document
    if document and document._is_temporary_runtime_document == true then
        document = nil
    end
    return
    {
        slot_id = target.slot_id or (target.manifest and target.manifest.slot_id) or nil,
        document = document,
        runtime_kind = target.runtime_kind,
        location_text = target.location_text,
        checkpoint_kind = target.checkpoint_kind or (target.runtime_state and target.runtime_state.checkpoint_kind) or "",
        anchor = _clone_value(target.anchor),
        manifest = _clone_value(target.manifest),
    }
end

local function _capture_runtime_recovery_point(info, runtime_document)
    local document = runtime_document or _get_runtime_document()
    if not document then
        return nil, "当前没有可回滚的运行时"
    end

    local state, err = _safe_collect_slot_state(info, "__rollback__",
    {
        require_stable = false,
        runtime_document = document,
    })
    if not state then
        return nil, err or "无法捕获当前运行时快照"
    end
    local persistable_state, persistable_err = _safe_prepare_persistable_slot_state(state)
    if not persistable_state then
        return nil, persistable_err or "当前运行时快照包含不能保存的数据"
    end

    return
    {
        document = document,
        state = persistable_state,
        runtime_state = type(persistable_state.runtime) == "table" and persistable_state.runtime or {},
        was_debug_game = GlobalContext.is_debug_game == true,
        runtime_session =
        {
            initialized = runtime_session.initialized == true,
            running = runtime_session.running == true,
            playtime_ms = runtime_session.playtime_ms,
            last_saved_slot_id = runtime_session.last_saved_slot_id,
            loaded_slot_id = runtime_session.loaded_slot_id,
        },
    }
end

local function _apply_runtime_restore_payload(target_document, state, runtime_state)
    local snapshot_state = type(state) == "table" and state or {}
    local snapshot_runtime_state = type(runtime_state) == "table" and runtime_state or {}

    GlobalContext.runtime_global_context = _clone_value(snapshot_state.globals or {})

    if StyleManager.apply_runtime_state then
        local ok_call, style_ok, style_err = pcall(StyleManager.apply_runtime_state, snapshot_state.style or {})
        if not ok_call then
            return false, string.format("恢复运行时样式失败：%s", tostring(style_ok))
        end
        if style_ok == false then
            return false, style_err or "恢复运行时样式失败"
        end
    end

    local ok_call, restored, restore_err = pcall(FlowRuntimeHost.restore, target_document, snapshot_runtime_state)
    if not ok_call then
        return false, string.format("恢复流程运行时失败：%s", tostring(restored))
    end
    if restored ~= true then
        return false, restore_err or "恢复流程运行时失败"
    end

    local scene_context = target_document.get_runtime_scene_context and target_document:get_runtime_scene_context() or nil
    local skip_object_id_set = _make_id_set(snapshot_runtime_state.skip_object_ids)
    local skip_ui_instance_id_set = _make_id_set(snapshot_runtime_state.skip_ui_instance_ids)

    if scene_context and scene_context.apply_save_state then
        local scene_call_ok, scene_ok, scene_err = pcall(scene_context.apply_save_state, scene_context, snapshot_state.scene or {},
        {
            skip_object_id_set = skip_object_id_set,
        })
        if not scene_call_ok then
            return false, string.format("恢复场景状态失败：%s", tostring(scene_ok))
        end
        if scene_ok == false then
            return false, scene_err or "恢复场景状态失败"
        end
    end

    local ui_runtime = scene_context and scene_context.get_ui_runtime and scene_context:get_ui_runtime() or nil
    if ui_runtime and ui_runtime.apply_save_state then
        local ui_call_ok, ui_ok, ui_err = pcall(ui_runtime.apply_save_state, ui_runtime, snapshot_state.ui or {},
        {
            skip_instance_id_set = skip_ui_instance_id_set,
        })
        if not ui_call_ok then
            return false, string.format("恢复界面状态失败：%s", tostring(ui_ok))
        end
        if ui_ok == false then
            return false, ui_err or "恢复界面状态失败"
        end
    end

    if target_document.resolve_runtime_local_references then
        target_document:resolve_runtime_local_references()
    end

    if AudioPlaybackManager.apply_runtime_state then
        local audio_call_ok, audio_ok, audio_err = pcall(AudioPlaybackManager.apply_runtime_state, snapshot_state.audio or {})
        if not audio_call_ok then
            return false, string.format("恢复运行时音频失败：%s", tostring(audio_ok))
        end
        if audio_ok == false then
            return false, audio_err or "恢复运行时音频失败"
        end
    end

    return true
end

local function _restore_runtime_recovery_point(recovery_point)
    if type(recovery_point) ~= "table" or not recovery_point.document then
        return false, "缺少可回滚的运行时快照"
    end

    _reset_runtime_environment(
    {
        preserve_debug_session = GlobalContext.is_debug_game == true,
        runtime_document = _get_runtime_document(),
    })

    GlobalContext.is_debug_game = recovery_point.was_debug_game == true
    if recovery_point.was_debug_game then
        GlobalContext.debug_flow_document = nil
        GlobalContext.debug_blueprint = nil
    else
        GlobalContext.current_flow_document = nil
        GlobalContext.current_blueprint = nil
    end

    local ok, err = _apply_runtime_restore_payload(recovery_point.document, recovery_point.state or {}, recovery_point.runtime_state or {})
    if ok ~= true then
        return false, err or "回滚先前运行时失败"
    end

    runtime_session.initialized = recovery_point.runtime_session and recovery_point.runtime_session.initialized == true or false
    runtime_session.running = recovery_point.runtime_session and recovery_point.runtime_session.running == true or false
    runtime_session.playtime_ms = recovery_point.runtime_session and tonumber(recovery_point.runtime_session.playtime_ms) or 0
    runtime_session.last_saved_slot_id = recovery_point.runtime_session and recovery_point.runtime_session.last_saved_slot_id or nil
    runtime_session.loaded_slot_id = recovery_point.runtime_session and recovery_point.runtime_session.loaded_slot_id or nil
    return true
end

local function _prepare_slot_restore(info, slot_id, options)
    local prepare_options = type(options) == "table" and options or {}
    local state, manifest, err = _load_slot_state_internal(info, slot_id)
    if not state then
        return nil, err
    end

    if state.project_guid and state.project_guid ~= _get_project_guid() then
        return nil, "当前存档属于其他项目，无法直接加载"
    end

    local runtime_state = type(state.runtime) == "table" and state.runtime or {}
    local navigation_document = _resolve_slot_navigation_document(runtime_state, manifest)
    local runtime_document = nil

    if prepare_options.isolated_runtime_document == true then
        runtime_document = _resolve_slot_runtime_document(runtime_state, manifest,
        {
            isolated = true,
            usage = "flow_runtime",
        })
    elseif _can_use_live_slot_document(navigation_document) then
        runtime_document = _resolve_slot_runtime_document(runtime_state, manifest,
        {
            isolated = false,
            usage = "flow_runtime",
        })
    end

    if not runtime_document then
        runtime_document = _resolve_slot_runtime_document(runtime_state, manifest,
        {
            isolated = true,
            usage = "flow_runtime",
        })
    end

    if not runtime_document then
        return nil, "无法定位存档对应的流程文档"
    end

    return
    {
        state = state,
        manifest = manifest,
        runtime_state = runtime_state,
        document = navigation_document or runtime_document,
        runtime_document = runtime_document,
        runtime_kind = _trim(runtime_state.kind) or _trim(manifest and manifest.runtime_kind) or runtime_document.kind or "",
        location_text = _trim(manifest and manifest.location_text) or _build_runtime_location_text(runtime_state),
        anchor = _resolve_slot_anchor(manifest, runtime_state),
    }
end

local function _build_manifest_data(info, slot_id, category, state, previous_manifest, thumbnail_relative_path, manifest_options)
    local build_options = type(manifest_options) == "table" and manifest_options or {}
    local manifest_kind = build_options.save_kind
        or build_options.kind
        or category
    local save_kind = _normalize_slot_category(manifest_kind)
    local runtime_state = type(state.runtime) == "table" and state.runtime or {}
    local runtime_summary =
    {
        kind = runtime_state.kind or "",
        document_guid = runtime_state.document_guid or "",
        document_path = runtime_state.document_path or "",
        document_name = runtime_state.document_name or "",
        display_name = runtime_state.document_name or runtime_state.document_path or slot_id,
        location_text = _build_runtime_location_text(runtime_state),
        anchor = _clone_value(runtime_state.current_source_anchor or runtime_state.anchor or {}),
        playtime_ms = math.max(0, math.floor(_safe_tonumber(
            runtime_state.playtime_ms,
            previous_manifest and previous_manifest.playtime_ms or runtime_session.playtime_ms))),
    }

    local env =
    {
        runtime = runtime_summary,
        state = state,
        scene = state.scene or {},
        ui = state.ui or {},
        globals = state.globals or {},
        style = state.style or {},
        audio = state.audio or {},
        custom_data = state.custom_data or {},
        settings = state.custom_data and state.custom_data.settings or {},
    }

    local manifest_title = _resolve_binding_value(env, info.profile.manifest and info.profile.manifest.title)
    local manifest_summary = _resolve_binding_value(env, info.profile.manifest and info.profile.manifest.summary)
    local extra = {}
    for key, entry in pairs(info.profile.manifest and info.profile.manifest.extra or {}) do
        local value = _resolve_binding_value(env, entry)
        if value ~= nil then
            extra[key] = value
        end
    end

    local now_text = _format_iso8601()
    local location = SaveLocation.from_storage_id(slot_id, _get_location_options(info))
        or SaveLocation.normalize({category = category, page = 1, index = 1}, _get_location_options(info))
    local manifest =
    {
        schema_version = 2,
        engine_version = GlobalContext.version,
        project_version = _get_project_version(),
        project_guid = info.project_guid,
        save_profile_guid = info.profile_guid,
        save_kind = save_kind,
        location = SaveLocation.to_manifest_location(location, _get_location_options(info)),
        title = manifest_title or runtime_summary.display_name or slot_id,
        summary = manifest_summary or runtime_summary.location_text or "",
        created_at = previous_manifest and previous_manifest.created_at or now_text,
        updated_at = now_text,
        playtime_ms = runtime_summary.playtime_ms,
        document_guid = runtime_summary.document_guid,
        document_path = runtime_summary.document_path,
        display_name = runtime_summary.display_name,
        location_text = runtime_summary.location_text,
        flow_document_guid = runtime_summary.document_guid,
        flow_document_name = runtime_summary.document_name,
        runtime_kind = runtime_summary.kind,
        anchor = _clone_value(runtime_summary.anchor),
        recovery =
        {
            valid_at_save = true,
            checkpoint_kind = runtime_state.checkpoint_kind or state.checkpoint and state.checkpoint.checkpoint_kind or "stable_boundary",
        },
        extra = extra,
    }

    if thumbnail_relative_path then
        manifest.thumbnail =
        {
            relative_path = thumbnail_relative_path,
            width = math.floor(info.profile.thumbnail.width),
            height = math.floor(info.profile.thumbnail.height),
        }
    elseif previous_manifest and type(previous_manifest.thumbnail) == "table" then
        manifest.thumbnail = _clone_value(previous_manifest.thumbnail)
    end

    return manifest
end

local function _merge_manifest_display_fields(previous_manifest, previous_generated_manifest, next_generated_manifest)
    local merged_manifest = type(next_generated_manifest) == "table" and _clone_value(next_generated_manifest) or {}
    local current_manifest = type(previous_manifest) == "table" and previous_manifest or {}
    local old_generated_manifest = type(previous_generated_manifest) == "table" and previous_generated_manifest or {}

    for _, field in ipairs({"title", "summary"}) do
        if not _value_equal(current_manifest[field], old_generated_manifest[field]) then
            merged_manifest[field] = _clone_value(current_manifest[field])
        end
    end

    local merged_extra = type(merged_manifest.extra) == "table" and _clone_value(merged_manifest.extra) or {}
    local current_extra = type(current_manifest.extra) == "table" and current_manifest.extra or {}
    local old_generated_extra = type(old_generated_manifest.extra) == "table" and old_generated_manifest.extra or {}
    local next_generated_extra = type(next_generated_manifest and next_generated_manifest.extra) == "table" and next_generated_manifest.extra or {}
    local key_set = {}

    for key in pairs(current_extra) do
        key_set[key] = true
    end
    for key in pairs(old_generated_extra) do
        key_set[key] = true
    end
    for key in pairs(next_generated_extra) do
        key_set[key] = true
    end

    for key in pairs(key_set) do
        if _value_equal(current_extra[key], old_generated_extra[key]) then
            if next_generated_extra[key] ~= nil then
                merged_extra[key] = _clone_value(next_generated_extra[key])
            else
                merged_extra[key] = nil
            end
        else
            if current_extra[key] ~= nil then
                merged_extra[key] = _clone_value(current_extra[key])
            else
                merged_extra[key] = nil
            end
        end
    end

    merged_manifest.extra = merged_extra
    return merged_manifest
end

local function _capture_thumbnail(info, slot_id, category)
    -- Thumbnail capture is disabled while the save pipeline is stabilized.
    return nil
end

local function _build_checkpoint(runtime_state)
    local runtime_kind = runtime_state.kind or "unknown"
    local anchor = runtime_state.current_source_anchor or runtime_state.anchor or {}
    local checkpoint_id = runtime_kind
    if runtime_state.document_guid then
        checkpoint_id = string.format("%s:%s", checkpoint_id, tostring(runtime_state.document_guid))
    end
    if runtime_kind == "text" then
        checkpoint_id = string.format("%s:pc_%s", checkpoint_id, tostring(runtime_state.pc or "?"))
    elseif runtime_kind == "graph" then
        checkpoint_id = string.format("%s:node_%s", checkpoint_id, tostring(anchor.node_id or runtime_state.current_node_id or runtime_state.next_node_id or "?"))
    end
    return
    {
        checkpoint_id = checkpoint_id,
        checkpoint_kind = runtime_state.checkpoint_kind or "stable_boundary",
    }
end

_prepare_persistable_slot_state = function(state)
    local payload, err = _clone_persistable_value(type(state) == "table" and state or {})
    if not payload then
        return nil, SaveBoundaryDescriptor.format_block_reason(err or "当前存档数据包含不能写入的值")
    end
    return payload
end

_collect_slot_state = function(info, slot_id, options)
    local collect_options = type(options) == "table" and options or {}
    local require_stable = collect_options.require_stable ~= false
    local unstable_reason = nil

    local document = collect_options.runtime_document or _get_runtime_document()
    if not document then
        return nil, "当前没有运行中的流程"
    end

    if document.can_save_now then
        local ok, reason = document:can_save_now()
        if ok ~= true then
            local display_reason = SaveBoundaryDescriptor.format_block_reason(reason or "当前流程尚未进入可保存的稳定检查点")
            if require_stable then
                return nil, display_reason
            end
            unstable_reason = display_reason
        end
    end

    local runtime_state, runtime_err = document.collect_runtime_save_state and document:collect_runtime_save_state() or nil
    if type(runtime_state) ~= "table" then
        return nil, SaveBoundaryDescriptor.format_block_reason(runtime_err or "当前流程不支持存档")
    end

    local scene_context = document.get_runtime_scene_context and document:get_runtime_scene_context() or nil
    local skip_object_id_set = _make_id_set(runtime_state.skip_object_ids)
    local skip_ui_instance_id_set = _make_id_set(runtime_state.skip_ui_instance_ids)
    if scene_context and scene_context.can_save_now then
        local ok, reason = scene_context:can_save_now(
        {
            skip_object_id_set = skip_object_id_set,
            skip_ui_instance_id_set = skip_ui_instance_id_set,
            allow_active_managed_ui_sessions = collect_options.allow_active_managed_ui_sessions == true,
        })
        if ok ~= true then
            local display_reason = SaveBoundaryDescriptor.format_block_reason(reason or "当前场景尚未进入可保存的稳定检查点")
            if require_stable then
                return nil, display_reason
            end
            if not unstable_reason then
                unstable_reason = display_reason
            end
        end
    end

    local scene_state = scene_context and scene_context.collect_save_state and scene_context:collect_save_state(
    {
        skip_object_id_set = skip_object_id_set,
    }) or
    {
        schema_version = schema_version,
        object_list = {},
    }
    local ui_runtime = scene_context and scene_context.get_ui_runtime and scene_context:get_ui_runtime() or nil
    local ui_state = ui_runtime and ui_runtime.collect_save_state and ui_runtime:collect_save_state(
    {
        skip_instance_id_set = skip_ui_instance_id_set,
    }) or
    {
        schema_version = schema_version,
        instance_list = {},
    }

    local global_payload = _load_global_payload(info)
    local settings_payload = _load_settings_payload(info)
    local state =
    {
        schema_version = schema_version,
        engine_version = GlobalContext.version,
        project_guid = info.project_guid,
        project_version = _get_project_version(),
        project_key = SettingsManager.get("title") or info.project_guid,
        save_profile_guid = info.profile_guid,
        slot_id = slot_id,
        save_time = _format_iso8601(),
        checkpoint = _build_checkpoint(runtime_state),
        runtime = runtime_state,
        scene = scene_state,
        ui = ui_state,
        globals = _clone_value(GlobalContext.runtime_global_context or {}),
        style = StyleManager.collect_runtime_state and StyleManager.collect_runtime_state() or {},
        audio = AudioPlaybackManager.collect_runtime_state and AudioPlaybackManager.collect_runtime_state() or {},
        services = {},
        custom_data =
        {
            slot = _build_custom_domain_defaults(info.profile).slot,
            global = _clone_value(global_payload.custom_data or {}),
            settings = _clone_value(settings_payload.data or {}),
        },
    }
    return state, nil,
    {
        stable = unstable_reason == nil,
        unstable_reason = unstable_reason,
        require_stable = require_stable,
    }
end

_safe_collect_slot_state = function(info, slot_id, options)
    local ok, state, err, diagnostics = pcall(_collect_slot_state, info, slot_id, options)
    if not ok then
        return nil, SaveBoundaryDescriptor.format_block_reason(
            string.format("生成存档快照失败：%s", tostring(state or "未知错误")))
    end
    return state, err, diagnostics
end

_safe_prepare_persistable_slot_state = function(state)
    local ok, payload, err = pcall(_prepare_persistable_slot_state, state)
    if not ok then
        return nil, SaveBoundaryDescriptor.format_block_reason(
            string.format("整理存档数据失败：%s", tostring(payload or "未知错误")))
    end
    return payload, err
end

local function _resolve_manual_slot_id(info)
    local slot_list = _scan_slot_list(info, "manual")
    local next_index = 1
    for _, entry in ipairs(slot_list) do
        local index = tonumber(tostring(entry.slot_id or ""):match("^manual_(%d+)$"))
        if index and index >= next_index then
            next_index = index + 1
        end
    end
    return string.format("manual_%04d", next_index)
end

local function _reset_runtime_environment(options)
    local reset_options = type(options) == "table" and options or {}
    local runtime_document = reset_options.runtime_document or _get_runtime_document()
    if reset_options.preserve_debug_session == true then
        if runtime_document then
            GlobalContext.reset_flow_runtime_state(runtime_document)
        end
        if GlobalContext.set_runtime_flow_document then
            GlobalContext.set_runtime_flow_document(nil)
        end
    else
        FlowRuntimeHost.stop()
    end
    AudioPlaybackManager.stop_all(0)
    StyleManager.reset_runtime_context()
    GlobalContext.runtime_global_context = {}
end

local function _abort_runtime_restore(keep_debug_session)
    _reset_runtime_environment(
    {
        preserve_debug_session = keep_debug_session,
    })
    if keep_debug_session and GlobalContext.stop_debug then
        GlobalContext.stop_debug()
    end
end

local function _remember_last_continue(info, slot_id, updated_at)
    local payload = _load_global_payload(info)
    payload.last_continue =
    {
        slot_id = slot_id,
        updated_at = updated_at or _format_iso8601(),
    }
    _save_global_payload(info, payload)
end

module.init = function()
    local info, err = _resolve_storage_info_for_write()
    if info then
        _ensure_storage_directories(info)
    elseif err then
        _log(string.format("初始化存档目录失败：%s", tostring(err)), "warning")
    end
end

module.update = function(delta)
    local document = _get_runtime_document()
    if document then
        runtime_session.initialized = true
        runtime_session.running = true
        runtime_session.playtime_ms = math.max(0, runtime_session.playtime_ms + (tonumber(delta) or 0) * 1000)
    else
        runtime_session.running = false
    end
end

module.begin_new_session = function(options)
    local init_options = type(options) == "table" and options or {}
    runtime_session.initialized = true
    runtime_session.running = false
    runtime_session.playtime_ms = math.max(0, math.floor(_safe_tonumber(init_options.playtime_ms, 0)))
    runtime_session.last_saved_slot_id = nil
    runtime_session.loaded_slot_id = _trim(init_options.slot_id)
    _notify_runtime_switch_reset("新游戏")
end

module.get_project_guid = function()
    return _get_project_guid()
end

module.get_slot_display_name = function(slot_id, category)
    return _format_slot_id_for_user(slot_id, category)
end

module.normalize_location = function(value, options)
    local info = _build_storage_info(nil,
    {
        create_project_guid = false,
        emit_profile_warning = false,
    })
    return _normalize_location(value, info, options)
end

module.normalize_slot_id_for_user_input = function(slot_id, category)
    local info = _build_storage_info(nil,
    {
        create_project_guid = false,
        emit_profile_warning = false,
    })
    return _normalize_slot_id_for_storage(info, slot_id, category)
end

module.configure_storage = function(options)
    storage_resolution_cache.signature = nil
    storage_resolution_cache.info = nil
    storage_resolution_cache.err = nil
    storage_resolution_cache.resolved_at = 0
    storage_resolution_cache.warned_signature = nil
    if type(options) ~= "table" then
        storage_override = nil
        return true
    end

    storage_override =
    {
        mode = _normalize_storage_mode(options.mode),
        root = type(options.root) == "string" and options.root or options.custom_root,
        custom_root = type(options.root) == "string" and options.root or options.custom_root,
        subdirectory_name = type(options.subdirectory_name) == "string" and options.subdirectory_name or nil,
        pretty_json = options.pretty_json,
    }
    return true
end

module.get_effective_storage_info = function()
    local info, err = _resolve_storage_info_for_runtime()
    if not info then
        info = _build_storage_info()
        info.fallback_applied = false
        info.primary_root_path = info.root_path
        info.primary_resolved_mode = info.resolved_mode
        info.is_writable = false
        info.write_error = err
        return _clone_value(info)
    end
    info.is_writable = true
    return _clone_value(info)
end

module.peek_effective_storage_info = function()
    local info = _build_storage_info(nil,
    {
        create_project_guid = false,
        emit_profile_warning = false,
    })
    local signature = _build_storage_resolution_signature(info)

    if storage_resolution_cache.signature == signature then
        if storage_resolution_cache.info then
            local cached_info = _clone_value(storage_resolution_cache.info)
            cached_info.writability_known = true
            cached_info.is_writable = true
            return cached_info
        end

        info.primary_root_path = info.root_path
        info.primary_resolved_mode = info.resolved_mode
        info.fallback_applied = false
        info.writability_known = true
        info.is_writable = false
        info.write_error = storage_resolution_cache.err
        return _clone_value(info)
    end

    info.primary_root_path = info.root_path
    info.primary_resolved_mode = info.resolved_mode
    info.fallback_applied = false
    info.writability_known = false
    info.is_writable = nil
    info.write_error = nil
    return _clone_value(info)
end

module.get_current_runtime_snapshot = function()
    local info = _build_storage_info()
    local state, err, diagnostics = _safe_collect_slot_state(info, "__preview__",
    {
        require_stable = false,
    })
    if not state then
        return nil, err
    end
    local persistable_state, persistable_err = _safe_prepare_persistable_slot_state(state)
    if not persistable_state then
        return nil, persistable_err
    end
    state = persistable_state

    local manifest = _build_manifest_data(info, "__preview__", "manual", state, nil, nil)
    return
    {
        manifest = _clone_value(manifest),
        state = _clone_value(state),
        profile = _clone_value(info.profile),
        profile_guid = info.profile_guid,
        diagnostics = _clone_value(diagnostics or
        {
            stable = true,
            unstable_reason = nil,
            require_stable = false,
        }),
    }
end

local function _write_json_payload_direct(path, data, pretty)
    _ensure_parent_directory(path)

    local payload, payload_err = _clone_persistable_value(type(data) == "table" and data or {})
    if not payload then
        return false, payload_err or "JSON 数据包含不能保存的运行时对象"
    end

    local ok_print, content = pcall(json.PrintFromLua, payload, pretty == true)
    if not ok_print or type(content) ~= "string" then
        return false, "JSON 序列化失败"
    end

    return NativeIO.write_text(path, content)
end

local function _release_thumbnail_cache(path)
    if not path then
        return
    end
    if save_thumbnail_cache_module == false then
        local ok, module_ref = pcall(require, "application.framework.save_thumbnail_cache")
        save_thumbnail_cache_module = ok and module_ref or nil
    end
    if save_thumbnail_cache_module and save_thumbnail_cache_module.release then
        pcall(save_thumbnail_cache_module.release, path)
    end
end

local function _resolve_location_for_write(info, location_or_id, options)
    local write_options = type(options) == "table" and options or {}
    local location = _normalize_location(location_or_id, info, {category = write_options.category})
    if location then
        return location, _location_to_storage_id(location, info), location.category
    end

    local category = _storage_category_for_slot(write_options.category)
    local slot_id = _resolve_manual_slot_id(info)
    location = SaveLocation.from_storage_id(slot_id, _get_location_options(info))
    return location, slot_id, category
end

local function _attach_runtime_switch_result_fields(result, runtime_generation)
    local normalized = type(result) == "table" and result or {}
    normalized.runtime_generation = runtime_generation
    if normalized.ok == true then
        normalized.runtime_switched = normalized.runtime_switched ~= false
        normalized.abort_current_context = normalized.abort_current_context ~= false
    else
        normalized.ok = false
        normalized.runtime_switched = normalized.runtime_switched == true
        normalized.abort_current_context = normalized.abort_current_context == true
    end
    return normalized
end

_notify_runtime_switch_reset = function(reason)
    local ok, coordinator = pcall(require, "application.framework.snapshot_coordinator")
    if ok and type(coordinator) == "table" and coordinator.reset_runtime_slices then
        local reset_ok, generation = pcall(coordinator.reset_runtime_slices, reason)
        if reset_ok then
            return generation
        end
    end
    return nil
end

local function _commit_loaded_runtime_slice(load_result)
    local ok, coordinator = pcall(require, "application.framework.snapshot_coordinator")
    if not ok or type(coordinator) ~= "table" or type(coordinator.commit_full_slice) ~= "function" then
        return nil
    end

    local document = GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil
    if not document and type(load_result) == "table" then
        document = load_result.document
    end
    if not document then
        return nil
    end

    local anchor = type(load_result) == "table" and type(load_result.anchor) == "table" and load_result.anchor or {}
    local call_ok, slice = pcall(coordinator.commit_full_slice, document,
    {
        kind = "loaded_slot",
        label = "读档恢复点",
        node_id = anchor.node_id,
        node_title = anchor.node_title,
    },
    {
        source = "runtime",
        allow_active_managed_ui_sessions = true,
    })
    if call_ok and type(slice) == "table" then
        return slice.runtime_generation
    end
    return nil
end

module.collect_runtime_slice_state = function(options)
    local collect_options = type(options) == "table" and options or {}
    local info, storage_err = _resolve_storage_info_for_write()
    if not info then
        return nil, storage_err or "无法写入存档目录"
    end

    local ensure_ok, ensure_err = _ensure_storage_directories(info)
    if ensure_ok ~= true then
        return nil, ensure_err or "无法创建存档目录"
    end

    return _safe_collect_slot_state(info, "__slice__", collect_options)
end

module.write_slice = function(location_or_id, slice, options)
    local write_options = type(options) == "table" and options or {}
    if type(slice) ~= "table" or type(slice.state) ~= "table" then
        return false, "没有可写入的运行切片"
    end

    local info, storage_err = _resolve_storage_info_for_write()
    if not info then
        return false, storage_err
    end

    local ensure_ok, ensure_err = _ensure_storage_directories(info)
    if ensure_ok ~= true then
        return false, ensure_err
    end

    local location, storage_id, category = _resolve_location_for_write(info, location_or_id, write_options)
    if not location or not storage_id then
        return false, "无法解析存档位置"
    end

    local previous_manifest = _find_slot_manifest_internal(info, storage_id)
    local state, state_err = _safe_prepare_persistable_slot_state(slice.state)
    if not state then
        return false, state_err or "运行切片包含不能写入的数据"
    end
    state.slot_id = storage_id
    state.save_time = _format_iso8601()

    local boundary = type(slice.boundary) == "table" and slice.boundary or {}
    if type(state.runtime) == "table" then
        state.runtime.checkpoint_kind = _trim(boundary.kind) or state.runtime.checkpoint_kind
        state.runtime.anchor = type(state.runtime.anchor) == "table" and state.runtime.anchor or {}
        if boundary.node_id ~= nil then
            state.runtime.anchor.node_id = boundary.node_id
        end
        if boundary.node_title ~= nil then
            state.runtime.anchor.node_title = boundary.node_title
        end
        if boundary.document_guid ~= nil then
            state.runtime.document_guid = boundary.document_guid
        end
    end
    state.checkpoint = type(state.checkpoint) == "table" and state.checkpoint or {}
    state.checkpoint.checkpoint_kind = _trim(boundary.kind) or state.checkpoint.checkpoint_kind or "stable_boundary"

    local slot_dir = _slot_directory(info, storage_id, category)
    local ok, err = NativeIO.create_directories(slot_dir)
    if ok ~= true then
        return false, err or "无法创建存档位置目录"
    end

    local thumbnail_relative_path = nil
    local thumbnail_temp_path = nil
    local thumbnail_path = _slot_thumbnail_path(info, storage_id, category)
    local thumbnail_source = type(slice.thumbnail) == "table" and _trim(slice.thumbnail.path or slice.thumbnail.absolute_path) or nil
    if thumbnail_source and NativeIO.file_exists(thumbnail_source) then
        thumbnail_temp_path = string.format("%s.pending", thumbnail_path)
        _remove_file_if_exists(thumbnail_temp_path)
        ok, err = NativeIO.copy_file(thumbnail_source, thumbnail_temp_path, true)
        if ok ~= true then
            _remove_file_if_exists(thumbnail_temp_path)
            return false, err or "写入缩略图失败"
        end
        thumbnail_relative_path = "thumbnail.png"
    end

    local manifest = _build_manifest_data(info, storage_id, category, state, previous_manifest, thumbnail_relative_path, write_options)
    if thumbnail_relative_path == nil then
        manifest.thumbnail = nil
    end
    manifest.location = SaveLocation.to_manifest_location(location, _get_location_options(info))
    manifest.anchor = type(manifest.anchor) == "table" and manifest.anchor or {}
    manifest.anchor.node_id = boundary.node_id or manifest.anchor.node_id
    manifest.anchor.node_title = boundary.node_title or manifest.anchor.node_title
    manifest.location_text = _trim(boundary.label) or manifest.location_text
    manifest.recovery = type(manifest.recovery) == "table" and manifest.recovery or {}
    manifest.recovery.valid_at_save = true
    manifest.recovery.checkpoint_kind = _trim(boundary.kind) or manifest.recovery.checkpoint_kind

    local state_path = _slot_state_path(info, storage_id, category)
    local manifest_path = _slot_manifest_path(info, storage_id, category)
    local state_temp_path = string.format("%s.pending", state_path)
    local manifest_temp_path = string.format("%s.pending", manifest_path)
    local state_backup_path = string.format("%s.bak", state_path)
    local manifest_backup_path = string.format("%s.bak", manifest_path)
    local thumbnail_backup_path = string.format("%s.bak", thumbnail_path)

    _remove_file_if_exists(state_temp_path)
    _remove_file_if_exists(manifest_temp_path)
    ok, err = _write_json_payload_direct(state_temp_path, _apply_payload_metadata(state, info), info.pretty_json)
    if ok ~= true then
        _remove_file_if_exists(state_temp_path)
        _remove_file_if_exists(manifest_temp_path)
        _remove_file_if_exists(thumbnail_temp_path)
        return false, err or "写入 state 失败"
    end

    local persist_manifest, persist_manifest_err = _clone_persistable_value(manifest)
    if not persist_manifest then
        _remove_file_if_exists(state_temp_path)
        _remove_file_if_exists(thumbnail_temp_path)
        return false, persist_manifest_err or "manifest 包含不能写入的数据"
    end
    persist_manifest.slot_id = nil
    persist_manifest.slot_display_name = nil
    persist_manifest.storage_id = nil
    persist_manifest.semantic_id = nil
    persist_manifest.display_name = nil
    persist_manifest.category = nil
    ok, err = _write_json_payload_direct(manifest_temp_path, _apply_payload_metadata(persist_manifest, info, 2), info.pretty_json)
    if ok ~= true then
        _remove_file_if_exists(state_temp_path)
        _remove_file_if_exists(manifest_temp_path)
        _remove_file_if_exists(thumbnail_temp_path)
        return false, err or "写入 manifest 失败"
    end

    ok, err = _replace_file_with_backup(state_path, state_temp_path, state_backup_path)
    if ok ~= true then
        _remove_file_if_exists(manifest_temp_path)
        _remove_file_if_exists(thumbnail_temp_path)
        return false, err or "提交 state 失败"
    end

    local thumbnail_committed = false
    if thumbnail_temp_path then
        ok, err = _replace_file_with_backup(thumbnail_path, thumbnail_temp_path, thumbnail_backup_path)
        if ok ~= true then
            _restore_backup_file(state_path, state_backup_path)
            _remove_file_if_exists(manifest_temp_path)
            _remove_file_if_exists(thumbnail_temp_path)
            return false, err or "提交 thumbnail 失败"
        end
        thumbnail_committed = true
    end

    ok, err = _replace_file_with_backup(manifest_path, manifest_temp_path, manifest_backup_path)
    if ok ~= true then
        _restore_backup_file(state_path, state_backup_path)
        if thumbnail_committed then
            _restore_backup_file(thumbnail_path, thumbnail_backup_path)
        end
        _remove_file_if_exists(manifest_temp_path)
        return false, err or "提交 manifest 失败"
    end

    _remove_file_if_exists(state_backup_path)
    _remove_file_if_exists(manifest_backup_path)
    if thumbnail_committed then
        _remove_file_if_exists(thumbnail_backup_path)
        _release_thumbnail_cache(thumbnail_path)
    end

    _write_json_file(_diagnostics_trace_path(info), state, info.pretty_json)
    _remember_last_continue(info, storage_id, manifest.updated_at)
    _scan_slot_list(info)
    runtime_session.last_saved_slot_id = storage_id
    _log(string.format("已保存存档：%s", SaveLocation.display_name(location, _get_location_options(info)) or storage_id), "success")
    return storage_id, nil, manifest
end

module.list_page = function(category, page, per_page)
    local info = _resolve_storage_info_for_runtime()
    if not info then
        return {}
    end

    local normalized_category = _normalize_slot_category(category)
    local page_number = math.max(1, math.floor(tonumber(page) or 1))
    local count = math.max(1, math.floor(tonumber(per_page) or (info.profile and info.profile.manual and info.profile.manual.slots_per_page) or SaveLocation.get_default_slots_per_page()))
    local result = {}
    for index = 1, count do
        local location = SaveLocation.location_for_page_index(normalized_category, page_number, index, _get_location_options(info))
        local storage_id = _location_to_storage_id(location, info)
        local manifest = storage_id and _find_slot_manifest_internal(info, storage_id) or nil
        if type(manifest) == "table" then
            manifest = _clone_value(manifest)
            manifest.empty = false
            manifest.location = SaveLocation.to_manifest_location(location, _get_location_options(info))
            manifest.storage_id = storage_id
            manifest.slot_id = storage_id
            manifest.display_name = SaveLocation.display_name(location, _get_location_options(info))
            manifest.slot_display_name = manifest.display_name
            result[#result + 1] = manifest
        else
            local display_name = SaveLocation.display_name(location, _get_location_options(info))
            result[#result + 1] =
            {
                empty = true,
                location = SaveLocation.to_manifest_location(location, _get_location_options(info)),
                storage_id = storage_id,
                slot_id = storage_id,
                display_name = display_name,
                slot_display_name = display_name,
                category = normalized_category,
            }
        end
    end
    return result
end

module.resolve_thumbnail_path = function(location_or_id)
    local info = _resolve_storage_info_for_runtime()
    if not info then
        return nil
    end

    local location = _normalize_location(location_or_id, info)
    local storage_id = location and _location_to_storage_id(location, info) or _normalize_slot_id_for_storage(info, location_or_id)
    local manifest, category = _find_slot_manifest_internal(info, storage_id)
    if type(manifest) ~= "table" or type(manifest.thumbnail) ~= "table" then
        return nil
    end

    local relative_path = _trim(manifest.thumbnail.relative_path)
    if not relative_path then
        return nil
    end
    return _join_path(_slot_directory(info, manifest.slot_id or storage_id, category), relative_path)
end

module.load_location = function(location_or_id, options)
    local load_options = type(options) == "table" and options or {}
    local info, info_err = _resolve_storage_info_for_runtime()
    if not info then
        _notify_load_failed()
        return
        {
            ok = false,
            error = info_err or "无法访问当前生效存档目录",
            runtime_switched = false,
            abort_current_context = false,
            rolled_back = false,
        }
    end

    local location = _normalize_location(location_or_id, info, {category = load_options.category})
    local storage_id = location and _location_to_storage_id(location, info) or _normalize_slot_id_for_storage(info, location_or_id, load_options.category)
    if not storage_id then
        _notify_load_failed()
        return
        {
            ok = false,
            error = "无法解析读取存档位置",
            runtime_switched = false,
            abort_current_context = false,
            rolled_back = false,
        }
    end

    local start_generation = _notify_runtime_switch_reset("读档开始")
    local ok, result = module.load_slot(storage_id,
    {
        skip_runtime_recovery_snapshot = load_options.skip_runtime_recovery_snapshot == true,
        preserve_debug_session = load_options.preserve_debug_session,
        enter_debug_session = load_options.enter_debug_session == true,
        prepared_slot_target = load_options.prepared_slot_target,
    })
    if ok == true then
        local runtime_generation = _commit_loaded_runtime_slice(result) or start_generation
        _notify_load_success()
        return _attach_runtime_switch_result_fields(
        {
            ok = true,
            runtime_switched = true,
            abort_current_context = true,
            manifest = type(result) == "table" and result.manifest or nil,
            anchor = type(result) == "table" and result.anchor or nil,
            document = type(result) == "table" and result.document or nil,
            runtime_kind = type(result) == "table" and result.runtime_kind or nil,
            location_text = type(result) == "table" and result.location_text or nil,
        }, runtime_generation)
    end

    local runtime_generation = _notify_runtime_switch_reset("读档失败回滚") or start_generation
    _notify_load_failed()
    return _attach_runtime_switch_result_fields(
    {
        ok = false,
        error = tostring(result or "读档失败"),
        runtime_switched = false,
        abort_current_context = false,
        rolled_back = true,
    }, runtime_generation)
end

module.get_save_availability = function(options)
    local availability_options = type(options) == "table" and options or nil
    local function blocked(reason, extra)
        local result = type(extra) == "table" and extra or {}
        result.available = false
        result.status = result.status or "blocked"
        result.reason = SaveBoundaryDescriptor.format_block_reason(reason)
        result.summary = result.reason
        return result
    end

    local document = availability_options and availability_options.runtime_document or _get_runtime_document()
    if not document then
        return blocked("当前没有运行中的流程",
        {
            status = "no_runtime",
        })
    end

    if not document.collect_runtime_save_state then
        return blocked("当前流程不支持存档")
    end

    local info, storage_err = _resolve_storage_info_for_write()
    if not info then
        return blocked(storage_err or "无法写入存档目录",
        {
            status = "storage_blocked",
        })
    end
    local ensure_ok, ensure_err = _ensure_storage_directories(info)
    if ensure_ok ~= true then
        return blocked(ensure_err or "无法创建存档目录",
        {
            status = "storage_blocked",
        })
    end
    local allow_active_managed_ui_sessions = availability_options
        and availability_options.allow_active_managed_ui_sessions == true
        or false
    local state, reason = _safe_collect_slot_state(info, "__availability__",
    {
        runtime_document = document,
        require_stable = true,
        allow_active_managed_ui_sessions = allow_active_managed_ui_sessions,
    })
    if type(state) ~= "table" then
        return blocked(reason or "当前流程尚未进入可保存的稳定检查点")
    end

    local persistable_state, persistable_err = _safe_prepare_persistable_slot_state(state)
    if not persistable_state then
        return blocked(persistable_err or "当前存档数据包含不能写入的运行时对象")
    end

    local runtime_state = type(persistable_state.runtime) == "table" and persistable_state.runtime or {}
    local boundary = SaveBoundaryDescriptor.describe_runtime_state(runtime_state)
    return
    {
        available = true,
        status = "saveable",
        reason = nil,
        summary = boundary.summary or "当前可存档。",
        runtime_state = _clone_value(runtime_state),
        boundary = boundary,
    }
end

module.open_save_directory = function()
    local info, err = _resolve_storage_info_for_write()
    if not info then
        return false, err
    end
    local ok, ensure_err = _ensure_storage_directories(info)
    if not ok then
        return false, ensure_err
    end
    local open_path = _resolve_openable_directory_path(info, info.saves_root)
    if not open_path then
        return false, "无法定位存档目录"
    end

    local shell_path = _to_shell_directory_path(open_path) or open_path
    local open_ok, open_err = NativeIO.open_path_or_url(shell_path)
    if open_ok then
        return true
    end
    return false, string.format("无法打开存档目录：%s（%s）", tostring(open_path), tostring(open_err or "系统未返回具体原因"))
end

module.list_slots = function(category)
    local info = _resolve_storage_info_for_runtime()
    if not info then
        return {}
    end
    return _clone_value(_scan_slot_list(info, category))
end

module.get_slot_manifest = function(slot_id)
    local info = _resolve_storage_info_for_runtime()
    if not info then
        return nil
    end
    local manifest = _find_slot_manifest_internal(info, slot_id)
    return manifest and _clone_value(manifest) or nil
end

module.get_slot_state = function(slot_id)
    local info = _resolve_storage_info_for_runtime()
    if not info then
        return nil
    end
    local state = _load_slot_state_internal(info, slot_id)
    return state and _clone_value(state) or nil
end

module.resolve_slot_target = function(slot_id)
    local status = module.get_slot_runtime_status(slot_id)
    if not status or status.valid ~= true then
        return nil, status and status.error or "无法解析存档目标"
    end
    return _copy_runtime_target_view(status.target)
end

module.get_slot_runtime_status = function(slot_id)
    local normalized_slot_id = _trim(slot_id)
    local info, info_err = _resolve_storage_info_for_runtime()
    if not info then
        return
        {
            slot_id = normalized_slot_id,
            valid = false,
            error = info_err or "无法访问当前生效存档目录",
        }
    end
    local target, err = _prepare_slot_restore(info, normalized_slot_id,
    {
        isolated_runtime_document = true,
    })
    if not target then
        return
        {
            slot_id = normalized_slot_id,
            valid = false,
            error = err or "无法解析存档目标",
        }
    end

    local valid, validation_err = _preflight_restore_target(target)
    local target_view = _copy_runtime_target_view(target)
    _cleanup_prepared_slot_target(target)
    return
    {
        slot_id = target.manifest and target.manifest.slot_id or normalized_slot_id,
        valid = valid == true,
        error = valid == true and nil or (validation_err or "当前存档无法恢复"),
        target = target_view,
    }
end

module.can_save_now = function()
    local availability = module.get_save_availability()
    if availability and availability.available == true then
        return true
    end
    return false, availability and availability.reason or "当前不能存档"
end

module.save_slot = function(slot_id, options)
    local save_options = type(options) == "table" and options or {}
    local info, storage_err = _resolve_storage_info_for_write()
    if not info then
        return false, storage_err
    end

    local ensure_ok, ensure_err = _ensure_storage_directories(info)
    if not ensure_ok then
        return false, ensure_err
    end

    local normalized_slot_id = _normalize_slot_id_for_storage(info, slot_id, save_options.category)
    local category = _storage_category_for_slot(save_options.category or _derive_slot_category(normalized_slot_id or slot_id))
    if not normalized_slot_id then
        normalized_slot_id = _resolve_manual_slot_id(info)
    end

    local previous_manifest = _find_slot_manifest_internal(info, normalized_slot_id)
    local state, collect_err = _safe_collect_slot_state(info, normalized_slot_id, save_options)
    if not state then
        return false, collect_err
    end
    local persistable_state, persistable_err = _safe_prepare_persistable_slot_state(state)
    if not persistable_state then
        return false, persistable_err
    end
    state = persistable_state

    local slot_dir = _slot_directory(info, normalized_slot_id, category)
    local ok_create, create_err = NativeIO.create_directories(slot_dir)
    if ok_create ~= true then
        return false, create_err or "无法创建存档位置目录"
    end

    local thumbnail_relative_path = _capture_thumbnail(info, normalized_slot_id, category)
    local manifest = _build_manifest_data(info, normalized_slot_id, category, state, previous_manifest, thumbnail_relative_path, save_options)
    if thumbnail_relative_path == nil then
        manifest.thumbnail = nil
    end

    local state_path = _slot_state_path(info, normalized_slot_id, category)
    local manifest_path = _slot_manifest_path(info, normalized_slot_id, category)
    local state_temp_path = string.format("%s.pending", state_path)
    local manifest_temp_path = string.format("%s.pending", manifest_path)
    local state_backup_path = string.format("%s.bak", state_path)
    local manifest_backup_path = string.format("%s.bak", manifest_path)

    _remove_file_if_exists(state_temp_path)
    _remove_file_if_exists(manifest_temp_path)

    local state_ok, state_err = _write_json_payload_direct(state_temp_path, _apply_payload_metadata(state, info), info.pretty_json)
    if not state_ok then
        _remove_file_if_exists(state_temp_path)
        _remove_file_if_exists(manifest_temp_path)
        return false, state_err or "写入 state 失败"
    end

    local persist_manifest, persist_manifest_err = _clone_persistable_value(type(manifest) == "table" and manifest or {})
    if not persist_manifest then
        _remove_file_if_exists(state_temp_path)
        _remove_file_if_exists(manifest_temp_path)
        return false, persist_manifest_err or "manifest 包含不能写入的数据"
    end
    persist_manifest.location = SaveLocation.to_manifest_location(persist_manifest.location or SaveLocation.from_storage_id(normalized_slot_id), _get_location_options(info))
    persist_manifest.slot_id = nil
    persist_manifest.slot_display_name = nil
    persist_manifest.storage_id = nil
    persist_manifest.semantic_id = nil
    persist_manifest.display_name = nil
    persist_manifest.category = nil

    local manifest_ok, manifest_err = _write_json_payload_direct(manifest_temp_path, _apply_payload_metadata(persist_manifest, info, persist_manifest.schema_version), info.pretty_json)
    if not manifest_ok then
        _remove_file_if_exists(state_temp_path)
        _remove_file_if_exists(manifest_temp_path)
        return false, manifest_err or "写入 manifest 失败"
    end

    state_ok, state_err = _replace_file_with_backup(state_path, state_temp_path, state_backup_path)
    if not state_ok then
        _remove_file_if_exists(state_temp_path)
        _remove_file_if_exists(manifest_temp_path)
        return false, state_err or "提交 state 失败"
    end

    manifest_ok, manifest_err = _replace_file_with_backup(manifest_path, manifest_temp_path, manifest_backup_path)
    if not manifest_ok then
        local restore_ok, restore_err = _restore_backup_file(state_path, state_backup_path)
        _remove_file_if_exists(manifest_temp_path)
        if restore_ok ~= true then
            return false, string.format("%s；恢复 state 失败：%s", manifest_err or "提交 manifest 失败", restore_err or "未知错误")
        end
        return false, manifest_err
    end

    _remove_file_if_exists(state_backup_path)
    _remove_file_if_exists(manifest_backup_path)
    _write_json_file(_diagnostics_trace_path(info), state, info.pretty_json)
    _remember_last_continue(info, normalized_slot_id, manifest.updated_at)
    _scan_slot_list(info)

    runtime_session.last_saved_slot_id = normalized_slot_id
    _log(string.format("已保存存档：%s", _format_slot_id_for_user(normalized_slot_id, category)), "success")
    return normalized_slot_id, nil
end

module.delete_slot = function(slot_id)
    local info, err = _resolve_storage_info_for_write()
    if not info then
        return false, err
    end

    local manifest, category = _find_slot_manifest_internal(info, slot_id)
    if not manifest then
        return false, "找不到指定存档"
    end

    local ok, remove_err = NativeIO.remove_directory(_slot_directory(info, manifest.slot_id, category), true)
    if not ok then
        return false, remove_err
    end

    local global_payload = _load_global_payload(info)
    if type(global_payload.last_continue) == "table" and global_payload.last_continue.slot_id == manifest.slot_id then
        global_payload.last_continue = nil
        _save_global_payload(info, global_payload)
    end

    _scan_slot_list(info)
    return true
end

module.update_slot_manifest = function(slot_id, patch)
    local info, err = _resolve_storage_info_for_write()
    if not info then
        return false, err
    end

    local manifest, category = _find_slot_manifest_internal(info, slot_id)
    if not manifest then
        return false, "找不到指定存档"
    end

    local next_manifest = _clone_value(manifest)
    local manifest_patch = type(patch) == "table" and patch or {}
    if manifest_patch.title ~= nil then
        next_manifest.title = tostring(manifest_patch.title)
    end
    if manifest_patch.summary ~= nil then
        next_manifest.summary = tostring(manifest_patch.summary)
    end
    if type(manifest_patch.extra) == "table" then
        next_manifest.extra = _clone_value(manifest_patch.extra)
    end
    next_manifest.updated_at = _format_iso8601()

    local ok, write_err = _save_slot_manifest_internal(info, manifest.slot_id, category, next_manifest)
    if not ok then
        return false, write_err
    end

    _scan_slot_list(info)
    return true
end

module.update_slot_custom_data = function(slot_id, custom_data)
    local info, err = _resolve_storage_info_for_write()
    if not info then
        return false, err
    end

    local state, manifest, load_err = _load_slot_state_internal(info, slot_id)
    if not state then
        return false, load_err
    end
    local category = _normalize_slot_category(manifest.category or _derive_slot_category(manifest.slot_id))
    local previous_state = _clone_value(state)
    local normalized_custom_data, custom_data_err = _clone_persistable_value(type(custom_data) == "table" and custom_data or {})
    if not normalized_custom_data then
        return false, SaveBoundaryDescriptor.format_block_reason(custom_data_err or "自定义存档数据包含不能写入的值")
    end
    state.custom_data = normalized_custom_data
    state.save_time = _format_iso8601()
    local preserve_options =
    {
        save_kind = manifest.save_kind or manifest.category or category,
    }
    local previous_generated_manifest = _build_manifest_data(info, manifest.slot_id, category, previous_state, manifest, nil, preserve_options)
    local next_generated_manifest = _build_manifest_data(info, manifest.slot_id, category, state, manifest, nil, preserve_options)
    local next_manifest = _merge_manifest_display_fields(manifest, previous_generated_manifest, next_generated_manifest)
    next_manifest.updated_at = state.save_time

    local ok, write_err = _save_slot_state_internal(info, manifest.slot_id, category, state)
    if not ok then
        return false, write_err
    end
    ok, write_err = _save_slot_manifest_internal(info, manifest.slot_id, category, next_manifest)
    if not ok then
        return false, write_err
    end

    _scan_slot_list(info)
    return true
end
module.quick_save = function(options)
    local save_options = _copy_save_options(options)
    save_options.category = "manual"
    return module.save_slot(nil, save_options)
end

module.quick_load = function(options)
    local info = _build_storage_info()
    local slot_list = _scan_slot_list(info, "manual")
    local slot_id = slot_list[1] and slot_list[1].slot_id or nil
    if not slot_id then
        _notify_load_failed()
        return false, "没有可用的手动存档"
    end
    local result = module.load_location(slot_id, options)
    if result and result.ok == true then
        return true, result
    end
    return false, result and result.error or "快速读档失败"
end

module.get_latest_continue_slot = function()
    local info = _resolve_storage_info_for_runtime()
    if not info then
        return nil
    end
    local payload = _load_global_payload(info)
    local slot_id = type(payload.last_continue) == "table" and _trim(payload.last_continue.slot_id) or nil
    if slot_id then
        local manifest = _find_slot_manifest_internal(info, slot_id)
        if manifest and _is_slot_manifest_continue_candidate(info, manifest) then
            return _clone_value(manifest)
        end
    end

    local slot_list = _scan_slot_list(info)
    for _, manifest in ipairs(slot_list) do
        if _is_slot_manifest_continue_candidate(info, manifest) then
            return _clone_value(manifest)
        end
    end
    return slot_list[1] and _clone_value(slot_list[1]) or nil
end

module.load_slot = function(slot_id, options)
    local load_options = type(options) == "table" and options or {}
    local info, info_err = _resolve_storage_info_for_runtime()
    if not info then
        return false, info_err or "无法访问当前生效存档目录"
    end
    local prepared_target = load_options.prepared_slot_target
    local target, err = prepared_target, nil
    if not target then
        target, err = _prepare_slot_restore(info, slot_id)
    end
    if not target then
        return false, err
    end

    local state = target.state
    local manifest = target.manifest
    local runtime_state = target.runtime_state
    local target_document = _get_target_runtime_document(target)
    local was_debug_game = GlobalContext.is_debug_game == true
    local preserve_debug_session = load_options.preserve_debug_session
    if preserve_debug_session == nil then
        preserve_debug_session = was_debug_game
    end
    local enter_debug_session = load_options.enter_debug_session == true
    local keep_debug_session = preserve_debug_session == true or enter_debug_session == true
    local skip_runtime_recovery_snapshot = load_options.skip_runtime_recovery_snapshot == true
    local previous_runtime_document = _get_runtime_document()
    local recovery_point = nil

    local validation_ok, validation_err = _preflight_restore_target(target)
    if validation_ok ~= true then
        _cleanup_prepared_slot_target(target)
        return false, validation_err or "当前存档无法在现有文档结构上恢复"
    end

    if previous_runtime_document and not skip_runtime_recovery_snapshot then
        recovery_point = _capture_runtime_recovery_point(info, previous_runtime_document)
    end

    _reset_runtime_environment(
    {
        preserve_debug_session = preserve_debug_session,
        runtime_document = previous_runtime_document,
    })
    if enter_debug_session and GlobalContext.is_debug_game ~= true then
        GlobalContext.is_debug_game = true
    end

    local restore_ok, restore_err = _apply_runtime_restore_payload(target_document, state, runtime_state)
    if restore_ok ~= true then
        if recovery_point then
            local rollback_ok, rollback_err = _restore_runtime_recovery_point(recovery_point)
            if rollback_ok ~= true then
                _dispose_temporary_runtime_document(target_document)
                _dispose_temporary_runtime_document(recovery_point.document)
                return false, string.format("%s；且回滚先前运行时失败：%s", tostring(restore_err or "恢复流程运行时失败"), tostring(rollback_err or "未知错误"))
            end
            _dispose_temporary_runtime_document(target_document)
            return false, restore_err
        end
        _abort_runtime_restore(keep_debug_session)
        _dispose_temporary_runtime_document(target_document)
        return false, restore_err or "恢复流程运行时失败"
    end

    if keep_debug_session then
        GlobalContext.is_debug_game = true
        GlobalContext.debug_flow_document = target_document
        GlobalContext.debug_blueprint = target_document.kind == "graph" and target_document or nil
    end

    if recovery_point and recovery_point.document ~= target_document then
        _dispose_temporary_runtime_document(recovery_point.document)
    end

    runtime_session.initialized = true
    runtime_session.running = true
    runtime_session.loaded_slot_id = manifest.slot_id
    runtime_session.playtime_ms = math.max(0, math.floor(_safe_tonumber(manifest.playtime_ms, 0)))
    _block_runtime_interaction_for_document(target_document, "load_slot")
    _remember_last_continue(info, manifest.slot_id, manifest.updated_at)
    _log(string.format("已加载存档：%s", _format_slot_id_for_user(manifest.slot_id, manifest.category)), "success")
    local result_document = target.document
    if result_document and result_document._is_temporary_runtime_document == true then
        result_document = nil
    end
    return true,
    {
        document = result_document,
        runtime_kind = target.runtime_kind,
        location_text = target.location_text,
        anchor = _clone_value(target.anchor),
        manifest = _clone_value(manifest),
    }
end

module.take_over_slot = function(slot_id, options)
    local takeover_options = type(options) == "table" and options or {}
    local info, info_err = _resolve_storage_info_for_runtime()
    if not info then
        return false, info_err or "无法访问当前生效存档目录"
    end
    local target, err = _prepare_slot_restore(info, slot_id)
    if not target then
        return false, err
    end

    local was_debug_game = GlobalContext.is_debug_game == true

    local result = module.load_location(slot_id,
    {
        prepared_slot_target = target,
        preserve_debug_session = was_debug_game,
        enter_debug_session = takeover_options.enter_debug_session ~= false and not was_debug_game,
        skip_runtime_recovery_snapshot = takeover_options.skip_runtime_recovery_snapshot == true,
    })
    if not result or result.ok ~= true then
        return false, result and result.error or "接管存档失败"
    end
    return true, result
end

module.save_global = function(key, value)
    local normalized_key = _trim(key)
    if not normalized_key then
        return false, "无效的全局键名"
    end

    local normalized_value, value_err = _clone_persistable_value(value)
    if value_err then
        return false, value_err
    end

    local info, err = _resolve_storage_info_for_write()
    if not info then
        return false, err
    end
    local payload = _load_global_payload(info)
    payload.custom_data[normalized_key] = normalized_value
    return _save_global_payload(info, payload)
end

module.load_global = function(key)
    local normalized_key = _trim(key)
    if not normalized_key then
        return nil
    end

    local info = _resolve_storage_info_for_runtime()
    if not info then
        return nil
    end
    local payload = _load_global_payload(info)
    return _clone_value(payload.custom_data[normalized_key])
end

module.get_runtime_settings = function()
    local info = _resolve_storage_info_for_runtime()
    if not info then
        return {}
    end
    local payload = _load_settings_payload(info)
    return _clone_value(payload.data)
end

module.update_runtime_settings = function(patch)
    if type(patch) ~= "table" then
        return false, "无效的设置补丁"
    end

    local info, err = _resolve_storage_info_for_write()
    if not info then
        return false, err
    end
    local payload = _load_settings_payload(info)
    for key, value in pairs(patch) do
        local normalized_value, value_err = _clone_persistable_value(value)
        if value_err then
            return false, value_err
        end
        payload.data[key] = normalized_value
    end
    return _save_settings_payload(info, payload)
end

return module

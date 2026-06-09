local json = Engine.JSON

local NativeIO = require("application.framework.native_io")

local module = {}

local file_path = "project.vne"

local function _ensure_parent_directory(path)
    local directory = type(path) == "string" and path:match("^(.*)[/\\][^/\\]+$") or nil
    if directory and directory ~= "" then
        local ok, err = NativeIO.create_directories(directory)
        if ok ~= true then
            return false, err
        end
    end
    return true
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

    ok, err = _remove_file_if_exists(backup_path)
    if ok ~= true then
        return false, err
    end
    return true
end

local function _write_text_atomically(path, content)
    local ok, err = _ensure_parent_directory(path)
    if ok ~= true then
        return false, err
    end

    local temp_path = string.format("%s.tmp", path)
    local backup_path = string.format("%s.bak", path)
    ok, err = _remove_file_if_exists(temp_path)
    if ok ~= true then
        return false, err
    end

    ok, err = NativeIO.write_text(temp_path, content)
    if ok ~= true then
        _remove_file_if_exists(temp_path)
        return false, err
    end

    ok, err = _replace_file_with_backup(path, temp_path, backup_path)
    if ok ~= true then
        _remove_file_if_exists(temp_path)
        return false, err
    end
    return true
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

local function _read_json_file(path)
    local content, err = NativeIO.read_text(path)
    if not content then
        return nil, err
    end

    local ok, data = json.ParseToLua(content)
    if not ok or type(data) ~= "table" then
        return nil, "无法解析项目配置文件"
    end

    return data
end

module.clone = function(value)
    return _clone_value(value)
end

module.get_file_path = function()
    return file_path
end

module.set_file_path = function(path)
    if type(path) == "string" and path ~= "" then
        file_path = path
    end
end

module.load = function(path)
    return _read_json_file(path or file_path)
end

module.load_or_empty = function(path)
    local data = module.load(path)
    if type(data) == "table" then
        return data
    end
    return {}
end

module.save = function(data, path)
    local target_path = path or file_path
    local output = type(data) == "table" and _clone_value(data) or {}
    local content = json.PrintFromLua(output)

    if NativeIO.file_exists(target_path) then
        local current_content = NativeIO.read_text(target_path)
        if current_content == content then
            return true
        end
    end

    return _write_text_atomically(target_path, content)
end

module.merge_missing_top_level = function(target, source, reserved_key_pool)
    if type(target) ~= "table" or type(source) ~= "table" then
        return target
    end

    for key, value in pairs(source) do
        if (not reserved_key_pool or not reserved_key_pool[key]) and target[key] == nil then
            target[key] = _clone_value(value)
        end
    end

    return target
end

return module

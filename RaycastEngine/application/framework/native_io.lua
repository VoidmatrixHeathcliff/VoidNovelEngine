local util = Engine.Util

local module = {}

local function _call_boolean_result(fn, ...)
    local ok, err = fn(...)
    if not ok then
        return nil, err
    end
    return true
end

module.read_text = function(path)
    return util.ReadAllTextUtf8(path)
end

module.read_bytes = function(path)
    return util.ReadAllBytesUtf8(path)
end

module.read_bytes_string = function(path)
    local buffer, err = util.ReadAllBytesUtf8(path)
    if not buffer then
        return nil, err
    end

    local data = buffer:get()
    util.UnloadFileBuffer(buffer)
    return data
end

module.write_text = function(path, text)
    return _call_boolean_result(util.WriteAllTextUtf8, path, text)
end

module.write_bytes = function(path, data)
    return _call_boolean_result(util.WriteAllBytesUtf8, path, data)
end

module.file_exists = function(path)
    return util.FileExistsUtf8(path)
end

module.directory_exists = function(path)
    return util.DirectoryExistsUtf8(path)
end

module.create_directories = function(path)
    return _call_boolean_result(util.CreateDirectoriesUtf8, path)
end

module.remove_file = function(path)
    return _call_boolean_result(util.RemoveFileUtf8, path)
end

module.remove_directory = function(path, recursive)
    return _call_boolean_result(util.RemoveDirectoryUtf8, path, recursive or false)
end

module.rename = function(source, destination)
    return _call_boolean_result(util.RenameUtf8, source, destination)
end

module.copy_file = function(source, destination, overwrite)
    return _call_boolean_result(util.CopyFileUtf8, source, destination, overwrite ~= false)
end

module.copy_directory = function(source, destination)
    return _call_boolean_result(util.CopyDirectoryUtf8, source, destination)
end

module.list_directory = function(path, recursive, files_only)
    return util.ListDirectoryUtf8(path, recursive or false, files_only or false)
end

module.get_file_size = function(path)
    return util.GetFileSizeUtf8(path)
end

module.get_file_modified_time = function(path)
    return util.GetFileModifiedTimeUtf8(path)
end

module.set_file_hidden = function(path, hidden)
    if type(util.SetFileHiddenUtf8) ~= "function" then
        return true
    end
    return _call_boolean_result(util.SetFileHiddenUtf8, path, hidden == true)
end

module.list_directory_array = function(path, recursive, files_only)
    local path_list, err = module.list_directory(path, recursive, files_only)
    if not path_list then
        return nil, err
    end

    local result = {}
    for i = 1, path_list.count do
        table.insert(result, path_list:get(i - 1))
    end
    return result
end

module.load_lua_chunk = function(path, env)
    local text, err = module.read_text(path)
    if not text then
        return nil, err
    end

    return load(text, "@" .. path, "bt", env or _ENV)
end

module.run_process = function(exe_path, args, cwd)
    return util.RunProcessUtf8(exe_path, args or {}, cwd)
end

module.run_process_capture = function(exe_path, args, cwd)
    return util.RunProcessAndCaptureUtf8(exe_path, args or {}, cwd)
end

module.start_process = function(exe_path, args, cwd)
    return util.StartProcessUtf8(exe_path, args or {}, cwd)
end

module.dispose_process = function(pipe)
    if pipe then
        util.UnloadProcessPipe(pipe)
    end
end

module.dispose_buffer = function(buffer)
    if buffer then
        util.UnloadFileBuffer(buffer)
    end
end

module.open_path_or_url = function(target)
    return _call_boolean_result(util.OpenPathOrUrlUtf8, target)
end

return module

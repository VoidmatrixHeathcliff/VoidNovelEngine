local rl = Engine.Raylib
local sdl = Engine.SDL

local GlobalContext = require("application.framework.global_context")
local NativeIO = require("application.framework.native_io")

local module = {}

local texture_pool = {}
local sdl_texture_pool = {}
local max_texture_count <const> = 96
local max_sdl_texture_count <const> = 128
local cache_ttl_seconds <const> = 120.0
local error_ttl_seconds <const> = 15.0
local collect_interval_seconds <const> = 1.0
local next_collect_time = 0
local _unload_entry
local _unload_sdl_entry

local function _now()
    if rl.GetTime then
        local ok, value = pcall(rl.GetTime)
        if ok and type(value) == "number" then
            return value
        end
    end
    return os.clock()
end

local function _estimate_texture_bytes(texture)
    if not texture then
        return 0
    end
    local width = tonumber(texture.width) or 0
    local height = tonumber(texture.height) or 0
    return math.max(0, width * height * 4)
end

local function _estimate_sdl_texture_bytes(texture)
    if not texture or not sdl.QueryTexture then
        return 0
    end
    local ok, info = pcall(sdl.QueryTexture, texture)
    if not ok or type(info) ~= "table" then
        return 0
    end
    local width = tonumber(info.w) or 0
    local height = tonumber(info.h) or 0
    return math.max(0, width * height * 4)
end

local function _touch_entry(entry)
    if entry then
        entry.last_used_time = _now()
    end
end

local function _count_pool(pool)
    local count = 0
    for _ in pairs(pool or {}) do
        count = count + 1
    end
    return count
end

local function _collect_pool(pool, unload_func, max_count, now_time)
    if type(unload_func) ~= "function" then
        return 0
    end
    local removed_count = 0
    for path, entry in pairs(pool) do
        local ttl = entry and entry.texture and cache_ttl_seconds or error_ttl_seconds
        if not entry or now_time - (entry.last_used_time or 0) >= ttl then
            unload_func(entry)
            pool[path] = nil
            removed_count = removed_count + 1
        end
    end

    while _count_pool(pool) > max_count do
        local oldest_path = nil
        local oldest_time = nil
        for path, entry in pairs(pool) do
            local last_used = entry and entry.last_used_time or 0
            if oldest_time == nil or last_used < oldest_time then
                oldest_path = path
                oldest_time = last_used
            end
        end
        if oldest_path == nil then
            break
        end
        unload_func(pool[oldest_path])
        pool[oldest_path] = nil
        removed_count = removed_count + 1
    end
    return removed_count
end

local function _collect(now_time)
    now_time = now_time or _now()
    local removed_texture_count = _collect_pool(texture_pool, _unload_entry, max_texture_count, now_time)
    local removed_sdl_texture_count = _collect_pool(sdl_texture_pool, _unload_sdl_entry, max_sdl_texture_count, now_time)
    return removed_texture_count + removed_sdl_texture_count
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

_unload_entry = function(entry)
    if not entry or not entry.texture then
        return
    end

    local is_valid = true
    if rl.IsTextureValid then
        local ok, result = pcall(rl.IsTextureValid, entry.texture)
        is_valid = ok and result == true
    end
    if is_valid and rl.UnloadTexture then
        pcall(rl.UnloadTexture, entry.texture)
    end
end

_unload_sdl_entry = function(entry)
    if not entry or not entry.texture then
        return
    end
    if sdl.DestroyTexture then
        pcall(sdl.DestroyTexture, entry.texture)
    end
end

local function _file_exists(path)
    local ok, exists = pcall(NativeIO.file_exists, path)
    return ok and exists == true
end

local function _looks_like_png(path)
    local ok, data = pcall(NativeIO.read_bytes_string, path)
    if not ok or type(data) ~= "string" then
        return false
    end
    return data:sub(1, 8) == "\137PNG\r\n\26\n"
end

local function _set_error(path, message)
    _unload_entry(texture_pool[path])
    _unload_sdl_entry(sdl_texture_pool[path])
    local now_time = _now()
    texture_pool[path] =
    {
        texture = nil,
        error = message,
        last_used_time = now_time,
        bytes_estimate = 0,
    }
    sdl_texture_pool[path] =
    {
        texture = nil,
        error = message,
        last_used_time = now_time,
        bytes_estimate = 0,
    }
    return nil, message
end

local function _validate_path(path)
    local normalized_path = _trim(path)
    if not normalized_path then
        return nil, "No slice thumbnail"
    end

    if not _file_exists(normalized_path) then
        return nil, "Thumbnail file does not exist", normalized_path
    end

    if not _looks_like_png(normalized_path) then
        return nil, "Thumbnail is corrupt or unsupported", normalized_path
    end

    return normalized_path, nil, normalized_path
end

function module.get_texture(path)
    local normalized_path, validation_err, error_path = _validate_path(path)
    if not normalized_path then
        if error_path then
            return _set_error(error_path, validation_err)
        end
        return nil, validation_err
    end

    local entry = texture_pool[normalized_path]
    if entry ~= nil and entry.texture ~= nil then
        _touch_entry(entry)
        return entry.texture, entry.error
    end

    local buffer, read_err = NativeIO.read_bytes(normalized_path)
    if not buffer then
        return _set_error(normalized_path, read_err or "Thumbnail file could not be read")
    end

    local ok_image, image = pcall(rl.LoadImageFromMemory, ".png", buffer)
    NativeIO.dispose_buffer(buffer)
    if not ok_image or not image then
        return _set_error(normalized_path, "Thumbnail could not be loaded")
    end
    if rl.IsImageValid then
        local ok_valid_image, is_valid_image = pcall(rl.IsImageValid, image)
        if not ok_valid_image or is_valid_image ~= true then
            if rl.UnloadImage then
                pcall(rl.UnloadImage, image)
            end
            return _set_error(normalized_path, "Thumbnail could not be loaded")
        end
    end

    local ok_texture, texture = pcall(rl.LoadTextureFromImage, image)
    if rl.UnloadImage then
        pcall(rl.UnloadImage, image)
    end
    if not ok_texture then
        texture = nil
    end

    local is_valid = texture ~= nil
    if texture and rl.IsTextureValid then
        local valid_ok, valid_result = pcall(rl.IsTextureValid, texture)
        is_valid = valid_ok and valid_result == true
    end
    if texture and is_valid then
        texture_pool[normalized_path] =
        {
            texture = texture,
            error = nil,
            last_used_time = _now(),
            bytes_estimate = _estimate_texture_bytes(texture),
        }
        _collect()
        return texture, nil
    end

    if texture and rl.UnloadTexture then
        pcall(rl.UnloadTexture, texture)
    end
    return _set_error(normalized_path, "Thumbnail could not be loaded")
end

function module.get_sdl_texture(path)
    local normalized_path, validation_err, error_path = _validate_path(path)
    if not normalized_path then
        if error_path then
            return _set_error(error_path, validation_err)
        end
        return nil, validation_err
    end

    local entry = sdl_texture_pool[normalized_path]
    if entry ~= nil and entry.texture ~= nil then
        _touch_entry(entry)
        return entry.texture, entry.error
    end

    local buffer, read_err = NativeIO.read_bytes(normalized_path)
    if not buffer then
        return _set_error(normalized_path, read_err or "Thumbnail file could not be read")
    end

    local ok, texture = pcall(sdl.LoadTextureFromMemory, GlobalContext.renderer, buffer)
    NativeIO.dispose_buffer(buffer)
    if not ok or not texture then
        return _set_error(normalized_path, "Thumbnail could not be loaded")
    end

    if sdl.SetTextureScaleMode then
        pcall(sdl.SetTextureScaleMode, texture, sdl.ScaleMode.BEST)
    end
    sdl_texture_pool[normalized_path] =
    {
        texture = texture,
        error = nil,
        last_used_time = _now(),
        bytes_estimate = _estimate_sdl_texture_bytes(texture),
    }
    _collect()
    return texture, nil
end

function module.release(path)
    local normalized_path = _trim(path)
    if not normalized_path then
        return
    end
    _unload_entry(texture_pool[normalized_path])
    _unload_sdl_entry(sdl_texture_pool[normalized_path])
    texture_pool[normalized_path] = nil
    sdl_texture_pool[normalized_path] = nil
end

function module.clear()
    for path, entry in pairs(texture_pool) do
        _unload_entry(entry)
        texture_pool[path] = nil
    end
    for path, entry in pairs(sdl_texture_pool) do
        _unload_sdl_entry(entry)
        sdl_texture_pool[path] = nil
    end
end

function module.update(delta)
    local now_time = _now()
    if now_time < next_collect_time then
        return 0
    end
    next_collect_time = now_time + collect_interval_seconds
    return _collect(now_time)
end

local function _build_pool_stats(pool)
    local total_count = 0
    local texture_count = 0
    local error_count = 0
    local bytes_estimate = 0
    for _, entry in pairs(pool or {}) do
        total_count = total_count + 1
        bytes_estimate = bytes_estimate + (tonumber(entry and entry.bytes_estimate) or 0)
        if entry and entry.texture then
            texture_count = texture_count + 1
        else
            error_count = error_count + 1
        end
    end
    return
    {
        total_count = total_count,
        texture_count = texture_count,
        error_count = error_count,
        bytes_estimate = bytes_estimate,
    }
end

function module.get_stats()
    return
    {
        raylib = _build_pool_stats(texture_pool),
        sdl = _build_pool_stats(sdl_texture_pool),
        max_texture_count = max_texture_count,
        max_sdl_texture_count = max_sdl_texture_count,
        ttl_seconds = cache_ttl_seconds,
        error_ttl_seconds = error_ttl_seconds,
    }
end

return module

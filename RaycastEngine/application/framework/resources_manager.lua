local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib

local AudioAsset = require("application.framework.audio_asset")
local FontWrapper = require("application.framework.font_wrapper")
local GlobalContext = require("application.framework.global_context")
local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")
local ResourcePolicy = require("application.framework.resource_policy")
local ResourceRuntimeCache = require("application.framework.resource_runtime_cache")
local SettingsManager = require("application.framework.settings_manager")
local ShaderWrapper = require("application.framework.shader_wrapper")
local VideoAsset = require("application.framework.video_asset")

local runtime_cache = ResourceRuntimeCache.new()
local VideoImporter = nil

local function _get_video_importer()
    if not VideoImporter then
        VideoImporter = require("application.framework.video_importer")
    end
    return VideoImporter
end

local font_pool = {}
local audio_pool = {}
local video_pool = {}
local shader_pool = {}
local texture_pool = {}
local sdl_icon_pool = {}
local sdl_texture_pool = {}

local runtime_type_list =
{
    "texture",
    "audio",
    "video",
    "font",
    "shader",
}

local runtime_pool_by_type =
{
    font = font_pool,
    audio = audio_pool,
    video = video_pool,
    shader = shader_pool,
    texture = texture_pool,
}

local stats =
{
    indexed_count_by_type = {},
    request_count_by_type = {},
    load_count_by_type = {},
    unload_count_by_type = {},
    reload_count_by_type = {},
    collect_count_by_type = {},
    failed_count_by_type = {},
    lazy_request_count = 0,
    last_startup_asset_count = 0,
}

local next_collect_time = 0
local collect_interval_seconds <const> = 0.5
local next_empty_entry_sweep_time = 0
local empty_entry_sweep_interval_seconds <const> = 10.0
local last_empty_entry_sweep_count = 0

local function _count_table_items(map)
    local count = 0
    for _ in pairs(map or {}) do
        count = count + 1
    end
    return count
end

local function _count_font_cached_sizes()
    local count = 0
    for _, font_wrapper in pairs(font_pool or {}) do
        if font_wrapper and font_wrapper.get_stats then
            local stats_font = font_wrapper:get_stats()
            count = count + (tonumber(stats_font and stats_font.cached_size_count) or 0)
        end
    end
    if GlobalContext.font_wrapper_sdl and GlobalContext.font_wrapper_sdl.get_stats then
        local stats_font = GlobalContext.font_wrapper_sdl:get_stats()
        count = count + (tonumber(stats_font and stats_font.cached_size_count) or 0)
    end
    return count
end

local function _mark_stat(target, key, delta)
    target[key] = (target[key] or 0) + (delta or 1)
end

local function _resolve_guid(asset_type, value)
    return ResourceIndex.resolve_guid(asset_type, value)
end

local function _resolve_meta(asset_type, value)
    local guid = _resolve_guid(asset_type, value)
    if not guid then
        return nil
    end
    return ResourceIndex.find_by_guid(guid)
end

local function _get_entry(meta_or_guid, asset_type)
    return ResourceRuntimeCache.ensure_entry(runtime_cache, meta_or_guid, asset_type)
end

local function _update_legacy_pool(meta, runtime_object, preview_object)
    local guid = meta.guid
    local asset_type = meta.type
    local runtime_pool = runtime_pool_by_type[asset_type]
    if runtime_pool then
        runtime_pool[guid] = runtime_object
    end

    if asset_type == "texture" then
        sdl_texture_pool[guid] = preview_object
    end
end

local function _load_runtime_texture(meta)
    local buffer, err = NativeIO.read_bytes(meta.path)
    if not buffer then
        error(string.format("无法读取纹理资源：%s\n%s", meta.path, err or "未知错误"))
    end

    local image = rl.LoadImageFromMemory(meta.ext, buffer)
    if not rl.IsImageValid(image) then
        NativeIO.dispose_buffer(buffer)
        error(string.format("无法解析纹理资源：%s", meta.path))
    end

    local texture = rl.LoadTextureFromImage(image)
    rl.UnloadImage(image)
    NativeIO.dispose_buffer(buffer)
    if not rl.IsTextureValid(texture) then
        error(string.format("无法创建纹理资源：%s", meta.path))
    end

    if SettingsManager.get("filter_mode") == rl.TextureFilter.TRILINEAR then
        rl.GenTextureMipmaps(texture)
    end
    rl.SetTextureFilter(texture, SettingsManager.get("filter_mode"))
    return texture
end

local function _load_sdl_texture_from_path(path, label)
    local buffer, err = NativeIO.read_bytes(path)
    if not buffer then
        error(string.format("无法读取%s：%s\n%s", label or "预览纹理", path, err or "未知错误"))
    end

    local texture = sdl.LoadTextureFromMemory(GlobalContext.renderer, buffer)
    NativeIO.dispose_buffer(buffer)
    if not texture then
        error(string.format("无法创建 SDL %s：%s", label or "预览纹理", path))
    end
    sdl.SetTextureScaleMode(texture, sdl.ScaleMode.BEST)
    return texture
end

local function _load_preview_texture(meta)
    if SettingsManager.get("release_mode") then
        return nil
    end

    if meta.type == "texture" then
        return _load_sdl_texture_from_path(meta.path, "纹理预览")
    end

    if meta.type == "video" then
        local poster_path, err = _get_video_importer().ensure_poster(meta.guid)
        if not poster_path then
            error(string.format("无法准备视频封面：%s\n%s", meta.path, err or "未知错误"))
        end
        return _load_sdl_texture_from_path(poster_path, "视频预览")
    end

    local buffer, err = NativeIO.read_bytes(meta.path)
    if not buffer then
        error(string.format("无法读取纹理资源：%s\n%s", meta.path, err or "未知错误"))
    end

    local texture = sdl.LoadTextureFromMemory(GlobalContext.renderer, buffer)
    NativeIO.dispose_buffer(buffer)
    if not texture then
        error(string.format("无法创建 SDL 预览纹理：%s", meta.path))
    end
    sdl.SetTextureScaleMode(texture, sdl.ScaleMode.BEST)
    return texture
end

local function _create_runtime_object(meta)
    if meta.type == "texture" then
        return _load_runtime_texture(meta)
    elseif meta.type == "audio" then
        return AudioAsset.new(meta)
    elseif meta.type == "video" then
        return VideoAsset.new(meta)
    elseif meta.type == "font" then
        local buffer, err = NativeIO.read_bytes(meta.path)
        if not buffer then
            error(string.format("无法读取字体资源：%s\n%s", meta.path, err or "未知错误"))
        end
        return FontWrapper.new(buffer)
    elseif meta.type == "shader" then
        local shader_source, err = NativeIO.read_text(meta.path)
        if not shader_source then
            error(string.format("无法读取着色器资源：%s\n%s", meta.path, err or "未知错误"))
        end
        if shader_source:match("^%s*$") then
            return ShaderWrapper.empty()
        end
        local shader = ShaderWrapper.new({fragment_source = shader_source})
        if not shader:is_valid() then
            if shader.dispose then
                shader:dispose()
            end
            error(string.format("Invalid Shader: %s", meta.path))
        end
        return shader
    end
    return nil
end

local function _destroy_runtime_object(meta, object)
    if not object then
        return
    end

    if meta.type == "texture" then
        rl.UnloadTexture(object)
    elseif meta.type == "audio" then
        if object.dispose then
            object:dispose()
        end
    elseif meta.type == "font" then
        if object.dispose then
            object:dispose()
        end
    elseif meta.type == "shader" then
        if object.dispose then
            object:dispose()
        end
    end
end

local function _destroy_preview_object(meta, object)
    if not object then
        return
    end

    if meta.type == "texture" or meta.type == "video" then
        sdl.DestroyTexture(object)
    end
end

local function _destroy_retired_list(meta, retired_list, destroy_func)
    if not retired_list then
        return
    end
    for index = #retired_list, 1, -1 do
        destroy_func(meta, retired_list[index])
        retired_list[index] = nil
    end
end

local function _retire_or_destroy(entry, meta, lane, object)
    if not object then
        return
    end

    local retired_key = lane == "preview" and "retired_preview_list" or "retired_object_list"
    local destroy_func = lane == "preview" and _destroy_preview_object or _destroy_runtime_object
    if (entry.keepalive_count or 0) > 0 then
        table.insert(entry[retired_key], object)
    else
        destroy_func(meta, object)
    end
end

local function _clear_runtime_object(entry, meta, reason_key)
    if not entry or not entry.object then
        return false
    end

    _retire_or_destroy(entry, meta, "runtime", entry.object)
    entry.object = nil
    entry.state = "unloaded"
    entry.load_error = nil
    _update_legacy_pool(meta, nil, entry.preview_object)
    if reason_key then
        _mark_stat(stats[reason_key], meta.type)
    end
    return true
end

local function _clear_preview_object(entry, meta, reason_key)
    if not entry or not entry.preview_object then
        return false
    end

    _retire_or_destroy(entry, meta, "preview", entry.preview_object)
    entry.preview_object = nil
    entry.preview_state = "unloaded"
    entry.preview_load_error = nil
    _update_legacy_pool(meta, entry.object, nil)
    if reason_key then
        _mark_stat(stats[reason_key], meta.type)
    end
    return true
end

local function _ensure_runtime_object(meta, usage)
    local entry = _get_entry(meta)
    if not entry then
        return nil
    end

    ResourceRuntimeCache.touch_runtime(entry)
    _mark_stat(stats.request_count_by_type, meta.type)
    if entry.object ~= nil then
        return entry.object
    end

    local ok, object_or_err = pcall(_create_runtime_object, meta)
    if not ok then
        entry.state = "failed"
        entry.load_error = tostring(object_or_err)
        _mark_stat(stats.failed_count_by_type, meta.type)
        error(object_or_err)
    end

    local object = object_or_err
    entry.object = object
    entry.state = "loaded"
    entry.generation = (entry.generation or 0) + 1
    entry.load_error = nil
    _update_legacy_pool(meta, entry.object, entry.preview_object)
    _mark_stat(stats.load_count_by_type, meta.type)
    if usage ~= "startup" then
        stats.lazy_request_count = stats.lazy_request_count + 1
    end
    return entry.object
end

local function _ensure_preview_object(meta)
    local entry = _get_entry(meta)
    if not entry then
        return nil
    end

    ResourceRuntimeCache.touch_preview(entry)
    if entry.preview_object ~= nil then
        return entry.preview_object
    end

    local ok, object_or_err = pcall(_load_preview_texture, meta)
    if not ok then
        entry.preview_state = "failed"
        entry.preview_load_error = tostring(object_or_err)
        _mark_stat(stats.failed_count_by_type, meta.type)
        error(object_or_err)
    end

    local object = object_or_err
    entry.preview_object = object
    entry.preview_state = "loaded"
    entry.preview_load_error = nil
    _update_legacy_pool(meta, entry.object, entry.preview_object)
    return entry.preview_object
end

local function _cleanup_retired_objects(meta, entry)
    if not entry or (entry.keepalive_count or 0) > 0 then
        return
    end

    _destroy_retired_list(meta, entry.retired_object_list, _destroy_runtime_object)
    _destroy_retired_list(meta, entry.retired_preview_list, _destroy_preview_object)
end

local function _should_collect_runtime(meta, entry, now_time)
    if not meta or not entry or not entry.object then
        return false
    end
    if (entry.keepalive_count or 0) > 0 then
        return false
    end
    if not ResourcePolicy.should_collect_runtime(meta) then
        return false
    end

    local ttl = ResourcePolicy.get_runtime_ttl(meta)
    return (now_time - (entry.last_used_time or 0)) >= ttl
end

local function _should_collect_preview(meta, entry, now_time)
    if not meta or not entry or not entry.preview_object then
        return false
    end
    if (entry.keepalive_count or 0) > 0 then
        return false
    end
    if not ResourcePolicy.should_collect_preview(meta) then
        return false
    end

    local ttl = ResourcePolicy.get_preview_ttl(meta)
    return (now_time - (entry.last_preview_used_time or 0)) >= ttl
end

local function _hard_unload_entry(entry, meta)
    if not entry or not meta then
        return
    end

    if entry.object then
        _destroy_runtime_object(meta, entry.object)
        entry.object = nil
    end
    if entry.preview_object then
        _destroy_preview_object(meta, entry.preview_object)
        entry.preview_object = nil
    end
    _destroy_retired_list(meta, entry.retired_object_list, _destroy_runtime_object)
    _destroy_retired_list(meta, entry.retired_preview_list, _destroy_preview_object)
    entry.retired_object_list = {}
    entry.retired_preview_list = {}
    entry.keepalive_ticket_pool = {}
    entry.keepalive_count = 0
    entry.state = "unloaded"
    entry.preview_state = "unloaded"
    _update_legacy_pool(meta, nil, nil)
end

local function _load_editor_icons()
    for key, texture in pairs(sdl_icon_pool) do
        if texture then
            sdl.DestroyTexture(texture)
        end
        sdl_icon_pool[key] = nil
    end

    if SettingsManager.get("release_mode") then
        return
    end

    local path_list, err = NativeIO.list_directory_array("application/icon", true, true)
    if not path_list then
        error(string.format("无法扫描图标目录：%s", err or "未知错误"))
    end

    for _, file_path in ipairs(path_list) do
        local name = rl.GetFileNameWithoutExt(file_path)
        local ext = string.lower(rl.GetFileExtension(file_path))
        if ext == ".png" or ext == ".jpg" then
            local buffer, read_err = NativeIO.read_bytes(file_path)
            if not buffer then
                error(string.format("无法读取图标资源：%s\n%s", file_path, read_err or "未知错误"))
            end

            local texture = sdl.LoadTextureFromMemory(GlobalContext.renderer, buffer)
            NativeIO.dispose_buffer(buffer)
            if not texture then
                error(string.format("无法创建图标纹理：%s", file_path))
            end
            sdl.SetTextureScaleMode(texture, sdl.ScaleMode.BEST)
            sdl_icon_pool[name] = texture
        end
    end
end

local function _clear_editor_icons()
    for key, texture in pairs(sdl_icon_pool) do
        if texture then
            sdl.DestroyTexture(texture)
        end
        sdl_icon_pool[key] = nil
    end
end

module.load_all = function()
    module.unload()
    stats.last_startup_asset_count = #module.list_runtime_asset_meta()
    _load_editor_icons()
end

module.load = module.load_all

module.find_meta = function(value, asset_type)
    return _resolve_meta(asset_type, value)
end

module.find_meta_by_guid = function(guid)
    return ResourceIndex.find_by_guid(guid)
end

module.peek_state = function(value, asset_type)
    local meta = _resolve_meta(asset_type, value)
    if not meta then
        return nil
    end

    local entry = ResourceRuntimeCache.get_entry(runtime_cache, meta.guid)
    return
    {
        guid = meta.guid,
        type = meta.type,
        runtime_loaded = entry and entry.object ~= nil or false,
        preview_loaded = entry and entry.preview_object ~= nil or false,
        keepalive_count = entry and entry.keepalive_count or 0,
    }
end

module.is_loaded = function(value, usage, asset_type)
    local state = module.peek_state(value, asset_type)
    if not state then
        return false
    end
    if usage == "editor_preview" then
        return state.preview_loaded
    end
    return state.runtime_loaded
end

module.list_asset_meta = function(asset_type)
    return ResourceIndex.list_by_type(asset_type)
end

module.list_runtime_asset_meta = function()
    local meta_list = {}
    for _, asset_type in ipairs(runtime_type_list) do
        for _, meta in ipairs(ResourceIndex.list_by_type(asset_type)) do
            table.insert(meta_list, meta)
        end
    end

    table.sort(meta_list, function(left, right)
        if left.type ~= right.type then
            return left.type < right.type
        end
        return left.relative_path < right.relative_path
    end)
    return meta_list
end

module.get_asset_tree = function()
    return ResourceIndex.get_tree()
end

module.get_texture = function(value, usage)
    local meta = _resolve_meta("texture", value)
    if not meta then
        return nil
    end
    return _ensure_runtime_object(meta, usage or "runtime")
end

module.get_texture_preview = function(value, usage)
    local meta = _resolve_meta("texture", value)
    if not meta then
        return nil
    end
    return _ensure_preview_object(meta, usage or "editor_preview")
end

module.get_font = function(value, usage)
    local meta = _resolve_meta("font", value)
    if not meta then
        return nil
    end
    return _ensure_runtime_object(meta, usage or "runtime")
end

module.get_audio_asset = function(value, usage)
    local meta = _resolve_meta("audio", value)
    if not meta then
        return nil
    end
    return _ensure_runtime_object(meta, usage or "runtime")
end

module.get_video = function(value, usage)
    local meta = _resolve_meta("video", value)
    if not meta then
        return nil
    end
    return _ensure_runtime_object(meta, usage or "runtime")
end

module.get_video_preview = function(value, usage)
    local meta = _resolve_meta("video", value)
    if not meta then
        return nil
    end
    return _ensure_preview_object(meta, usage or "editor_preview")
end

module.get_video_asset = function(value, usage)
    return module.get_video(value, usage or "runtime")
end

module.get_video_import_status = function(value)
    local meta = _resolve_meta("video", value)
    if not meta then
        return nil
    end
    return _get_video_importer().get_status(meta.guid)
end

module.ensure_video_runtime = function(value, options)
    local meta = _resolve_meta("video", value)
    if not meta then
        return nil, "无法定位视频资源"
    end

    local runtime_path, status_or_err, status = _get_video_importer().ensure_runtime(meta.guid, options)
    if not runtime_path then
        if type(status) == "table" then
            return nil, status_or_err, status
        end
        return nil, status_or_err
    end

    local asset = module.get_video(meta.guid, options and options.usage or "runtime")
    if asset and asset.refresh then
        asset:refresh(ResourceIndex.find_by_guid(meta.guid) or meta)
    end
    return runtime_path, asset, status_or_err
end

module.get_video_runtime_path = function(value, options)
    local runtime_path, asset_or_err, status = module.ensure_video_runtime(value, options)
    if not runtime_path then
        return nil, asset_or_err, status
    end
    return runtime_path, status
end

module.get_shader = function(value, usage)
    local meta = _resolve_meta("shader", value)
    if not meta then
        return nil
    end
    return _ensure_runtime_object(meta, usage or "runtime")
end

module.prefetch = function(value, usage, asset_type)
    local meta = _resolve_meta(asset_type, value)
    if not meta then
        return nil
    end
    if meta.type == "texture" then
        return module.get_texture(meta.guid, usage or "prefetch")
    elseif meta.type == "audio" then
        return module.get_audio_asset(meta.guid, usage or "prefetch")
    elseif meta.type == "font" then
        return module.get_font(meta.guid, usage or "prefetch")
    elseif meta.type == "shader" then
        return module.get_shader(meta.guid, usage or "prefetch")
    elseif meta.type == "video" then
        return module.get_video(meta.guid, usage or "prefetch")
    end
    return nil
end

module.find_asset_by_guid = function(guid)
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return nil
    end
    local entry = ResourceRuntimeCache.get_entry(runtime_cache, meta.guid)
    return entry and entry.object or nil
end

module.find_font_by_guid = function(guid)
    return module.get_font(guid)
end

module.find_audio_by_guid = function(guid)
    return module.get_audio_asset(guid)
end

module.find_video_by_guid = function(guid)
    return module.get_video(guid)
end

module.find_shader_by_guid = function(guid)
    return module.get_shader(guid)
end

module.find_texture_by_guid = function(guid)
    return module.get_texture(guid)
end

module.find_sdl_texture_by_guid = function(guid)
    return module.get_texture_preview(guid)
end

module.find_font = function(value)
    return module.get_font(value)
end

module.find_audio = function(value)
    return module.get_audio_asset(value)
end

module.find_video = function(value)
    return module.get_video(value)
end

module.find_shader = function(value)
    return module.get_shader(value)
end

module.find_texture = function(value)
    return module.get_texture(value)
end

module.find_sdl_texture = function(value)
    return module.get_texture_preview(value)
end

module.acquire_keepalive = function(value, reason, usage, asset_type)
    local meta = _resolve_meta(asset_type, value)
    if not meta then
        return nil
    end

    local entry = _get_entry(meta)
    if not entry then
        return nil
    end
    return ResourceRuntimeCache.acquire_keepalive(runtime_cache, entry, reason, usage)
end

module.release_keepalive = function(ticket)
    return ResourceRuntimeCache.release_keepalive(runtime_cache, ticket)
end

module.touch = function(value, usage, asset_type)
    local meta = _resolve_meta(asset_type, value)
    if not meta then
        return false
    end

    local entry = _get_entry(meta)
    if usage == "editor_preview" then
        ResourceRuntimeCache.touch_preview(entry)
    else
        ResourceRuntimeCache.touch_runtime(entry)
    end
    return true
end

module.load_asset_by_guid = function(guid)
    local meta = ResourceIndex.find_by_guid(_resolve_guid(nil, guid) or "")
    if not meta then
        return
    end
    _ensure_runtime_object(meta, "startup")
end

module.try_reload_asset_by_guid = function(guid)
    local normalized_guid = _resolve_guid(nil, guid)
    if not normalized_guid then
        return false, "无法解析资源 GUID"
    end

    local entry = _get_entry(normalized_guid)
    local meta = ResourceIndex.find_by_guid(normalized_guid)
    if not meta then
        if entry then
            _clear_runtime_object(entry, {guid = normalized_guid, type = entry.type}, "unload_count_by_type")
            _clear_preview_object(entry, {guid = normalized_guid, type = entry.type}, "unload_count_by_type")
        end
        return true
    end

    if not entry then
        return true
    end

    local needs_runtime_reload = entry.object ~= nil
    local needs_preview_reload = entry.preview_object ~= nil
    if not needs_runtime_reload and not needs_preview_reload then
        entry.load_error = nil
        entry.preview_load_error = nil
        return true
    end

    local new_runtime_object = nil
    if needs_runtime_reload then
        local ok, result = pcall(_create_runtime_object, meta)
        if not ok then
            return false, result
        end
        new_runtime_object = result
    end

    local new_preview_object = nil
    if needs_preview_reload then
        local ok, result = pcall(_load_preview_texture, meta)
        if not ok then
            if new_runtime_object then
                _destroy_runtime_object(meta, new_runtime_object)
            end
            return false, result
        end
        new_preview_object = result
    end

    if needs_runtime_reload then
        _retire_or_destroy(entry, meta, "runtime", entry.object)
        entry.object = new_runtime_object
        entry.state = "loaded"
        entry.generation = (entry.generation or 0) + 1
        _mark_stat(stats.reload_count_by_type, meta.type)
    end

    if needs_preview_reload then
        _retire_or_destroy(entry, meta, "preview", entry.preview_object)
        entry.preview_object = new_preview_object
        entry.preview_state = "loaded"
    end

    _update_legacy_pool(meta, entry.object, entry.preview_object)
    _cleanup_retired_objects(meta, entry)
    return true
end

module.reload_asset_by_guid = function(guid)
    local ok, err = module.try_reload_asset_by_guid(guid)
    if not ok then
        error(err)
    end
end

module.unload_asset_by_guid = function(guid)
    local normalized_guid = _resolve_guid(nil, guid)
    if not normalized_guid then
        return
    end

    local entry = ResourceRuntimeCache.get_entry(runtime_cache, normalized_guid)
    if not entry then
        return
    end

    local meta = ResourceIndex.find_by_guid(normalized_guid) or {guid = normalized_guid, type = entry.type}
    _clear_runtime_object(entry, meta, "unload_count_by_type")
    _clear_preview_object(entry, meta, "unload_count_by_type")
    _cleanup_retired_objects(meta, entry)
end

module.collect_garbage = function(frame_budget_ms)
    local now_time = rl.GetTime()
    local start_time = now_time
    local budget_seconds = math.max(0.001, (frame_budget_ms or 2) / 1000.0)

    for _, entry in ipairs(ResourceRuntimeCache.iter_entries(runtime_cache)) do
        local meta = ResourceIndex.find_by_guid(entry.guid)
        if meta then
            if _should_collect_runtime(meta, entry, now_time) then
                if _clear_runtime_object(entry, meta, "collect_count_by_type") then
                    now_time = rl.GetTime()
                end
            end

            if _should_collect_preview(meta, entry, now_time) then
                _clear_preview_object(entry, meta, "collect_count_by_type")
                now_time = rl.GetTime()
            end

            _cleanup_retired_objects(meta, entry)
        else
            local fallback_meta = {guid = entry.guid, type = entry.type}
            _cleanup_retired_objects(fallback_meta, entry)
        end

        if rl.GetTime() - start_time >= budget_seconds then
            break
        end
    end

    now_time = rl.GetTime()
    if now_time >= next_empty_entry_sweep_time then
        last_empty_entry_sweep_count = ResourceRuntimeCache.sweep_empty_entries(runtime_cache, function(entry)
            return ResourceIndex.find_by_guid(entry and entry.guid or "") ~= nil
        end)
        next_empty_entry_sweep_time = now_time + empty_entry_sweep_interval_seconds
    end
end

module.update = function(delta)
    local now_time = rl.GetTime()
    if now_time >= next_collect_time then
        module.collect_garbage(2)
        next_collect_time = now_time + collect_interval_seconds
    end
end

module.reload_editor_icons = function()
    _load_editor_icons()
end

module.find_icon = function(name)
    if name ~= nil and sdl_icon_pool[name] then
        return sdl_icon_pool[name]
    end
    return sdl_icon_pool["file-paper-2-line"]
        or sdl_icon_pool["question-line"]
        or sdl_icon_pool["information-2-fill"]
end

module.get_font_pool = function()
    return font_pool
end

module.get_audio_pool = function()
    return audio_pool
end

module.get_video_pool = function()
    return video_pool
end

module.get_shader_pool = function()
    return shader_pool
end

module.get_texture_pool = function()
    return texture_pool
end

module.get_stats = function()
    local indexed_count_by_type = {}
    for _, asset_type in ipairs(
    {
        "flow",
        "style",
        "ui",
        "texture",
        "audio",
        "video",
        "font",
        "shader",
    }) do
        indexed_count_by_type[asset_type] = #ResourceIndex.list_by_type(asset_type)
    end

    return
    {
        indexed_count_by_type = indexed_count_by_type,
        request_count_by_type = stats.request_count_by_type,
        load_count_by_type = stats.load_count_by_type,
        unload_count_by_type = stats.unload_count_by_type,
        reload_count_by_type = stats.reload_count_by_type,
        collect_count_by_type = stats.collect_count_by_type,
        failed_count_by_type = stats.failed_count_by_type,
        lazy_request_count = stats.lazy_request_count,
        last_startup_asset_count = stats.last_startup_asset_count,
        loaded_runtime_count =
        {
            texture = _count_table_items(texture_pool),
            audio = _count_table_items(audio_pool),
            video = _count_table_items(video_pool),
            font = _count_table_items(font_pool),
            shader = _count_table_items(shader_pool),
        },
        loaded_preview_texture_count = _count_table_items(sdl_texture_pool),
        runtime_entry_count = ResourceRuntimeCache.count_entries(runtime_cache),
        font_cached_size_count = _count_font_cached_sizes(),
        last_empty_entry_sweep_count = last_empty_entry_sweep_count,
    }
end

module.unload = function()
    GlobalContext.shader_postprocess = nil
    for _, entry in ipairs(ResourceRuntimeCache.iter_entries(runtime_cache)) do
        local meta = ResourceIndex.find_by_guid(entry.guid) or {guid = entry.guid, type = entry.type}
        _hard_unload_entry(entry, meta)
    end
    texture_pool = {}
    audio_pool = {}
    video_pool = {}
    font_pool = {}
    shader_pool = {}
    sdl_texture_pool = {}
    runtime_pool_by_type.texture = texture_pool
    runtime_pool_by_type.audio = audio_pool
    runtime_pool_by_type.video = video_pool
    runtime_pool_by_type.font = font_pool
    runtime_pool_by_type.shader = shader_pool
    _clear_editor_icons()
end

return module

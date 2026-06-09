local rl = Engine.Raylib

local AudioAsset = require("application.framework.audio_asset")
local AudioPlaybackManager = require("application.framework.audio_playback_manager")
local NativeIO = require("application.framework.native_io")
local ResourcePolicy = require("application.framework.resource_policy")

local module = {}

local supported_type_by_ext =
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

local function _normalize_path(path)
    local value = _trim(path)
    if not value then
        return nil
    end
    value = value:gsub("\\", "/")
    value = value:gsub("//+", "/")
    return value
end

local function _join_path(...)
    local parts = {}
    for _, item in ipairs({...}) do
        local value = _normalize_path(item)
        if value then
            value = value:gsub("^/+", ""):gsub("/+$", "")
            if value ~= "" then
                parts[#parts + 1] = value
            end
        end
    end
    return table.concat(parts, "/")
end

local function _extension(path)
    local name = (_normalize_path(path) or ""):match("([^/]+)$") or ""
    local ext = name:match("(%.%w+)$")
    return ext and string.lower(ext) or nil
end

local function _assert_relative_path(path)
    local value = _normalize_path(path)
    if not value then
        return nil
    end
    if value:find("^[/\\]") or value:find("^[A-Za-z]:") or value:find("..", 1, true) then
        return nil
    end
    return value
end

local function _make_file_signature(path)
    return
    {
        size = NativeIO.get_file_size(path),
        mtime = NativeIO.get_file_modified_time(path),
    }
end

local function _load_texture(path, ext)
    local buffer, err = NativeIO.read_bytes(path)
    if not buffer then
        return nil, err or "无法读取纹理资源"
    end

    local image = rl.LoadImageFromMemory(ext, buffer)
    NativeIO.dispose_buffer(buffer)
    if not rl.IsImageValid(image) then
        return nil, "无法解析纹理资源"
    end

    local texture = rl.LoadTextureFromImage(image)
    rl.UnloadImage(image)
    if not rl.IsTextureValid(texture) then
        return nil, "无法创建纹理资源"
    end
    return texture
end

function module.new(manifest)
    local package_path = _normalize_path(manifest and manifest.package_path) or ""
    local resource_root = _assert_relative_path(manifest and manifest.resource_root) or "resources"
    local root_path = _join_path(package_path, resource_root)
    local context =
    {
        plugin_id = manifest and manifest.id or nil,
        root_path = root_path,
        manifest_resources = type(manifest and manifest.resources) == "table" and manifest.resources or {},
        _texture_pool = {},
        _audio_pool = {},
    }

    function context:resolve_path(relative_path, expected_type)
        local safe_path = _assert_relative_path(relative_path)
        if not safe_path then
            return nil, "资源路径必须是插件 resources 目录内的相对路径"
        end

        local ext = _extension(safe_path)
        local detected_type = supported_type_by_ext[ext]
        if expected_type and detected_type and detected_type ~= expected_type then
            return nil, string.format("资源类型不匹配：期望 %s，实际 %s", expected_type, detected_type)
        end
        if expected_type and not detected_type then
            return nil, string.format("不支持的资源扩展名：%s", tostring(ext))
        end

        local full_path = _join_path(root_path, safe_path)
        if not NativeIO.file_exists(full_path) then
            return nil, string.format("插件资源不存在：%s", safe_path)
        end
        return full_path, nil, ext
    end

    function context:get_declared(name)
        local key = _trim(name)
        if not key then
            return nil
        end
        local value = self.manifest_resources[key]
        return type(value) == "string" and value or nil
    end

    function context:find_texture(relative_path)
        local target = relative_path or self:get_declared("background")
        local full_path, err, ext = self:resolve_path(target, "texture")
        if not full_path then
            return nil, err
        end

        local cached = self._texture_pool[full_path]
        if cached then
            return cached
        end

        local texture, load_err = _load_texture(full_path, ext)
        if not texture then
            return nil, string.format("%s：%s", load_err or "纹理加载失败", full_path)
        end
        self._texture_pool[full_path] = texture
        return texture
    end

    function context:find_audio(relative_path)
        local target = relative_path or self:get_declared("music")
        local full_path, err, ext = self:resolve_path(target, "audio")
        if not full_path then
            return nil, err
        end

        local cached = self._audio_pool[full_path]
        if cached then
            return cached
        end

        local audio = AudioAsset.new(
        {
            guid = string.format("plug:%s:%s", tostring(self.plugin_id or ""), tostring(target)),
            type = "audio",
            path = full_path,
            relative_path = target,
            ext = ext,
            file_signature = _make_file_signature(full_path),
            skip_runtime_state = true,
        })
        self._audio_pool[full_path] = audio
        return audio
    end

    function context:dispose()
        if self.plugin_id then
            pcall(AudioPlaybackManager.stop_by_audio_guid_prefix,
                string.format("plug:%s:", tostring(self.plugin_id)),
                0,
                true)
        end
        for key, texture in pairs(self._texture_pool) do
            if texture and (not rl.IsTextureValid or rl.IsTextureValid(texture)) then
                pcall(rl.UnloadTexture, texture)
            end
            self._texture_pool[key] = nil
        end
        for key, audio in pairs(self._audio_pool) do
            if audio and audio.dispose then
                pcall(audio.dispose, audio)
            end
            self._audio_pool[key] = nil
        end
    end

    return context
end

return module

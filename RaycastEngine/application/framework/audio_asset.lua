local sdl = Engine.SDL
local rl = Engine.Raylib

local Class = require("application.framework.class")
local NativeIO = require("application.framework.native_io")
local ResourcePolicy = require("application.framework.resource_policy")

local AudioAsset = Class.define("AudioAsset")

local function _read_buffer(path)
    local buffer, err = NativeIO.read_bytes(path)
    if not buffer then
        return nil, string.format("无法读取音频资源：%s\n%s", path, err or "未知错误")
    end
    return buffer
end

function AudioAsset:ctor(meta)
    self.guid = meta.guid
    self.type = meta.type
    self.path = meta.path
    self.relative_path = meta.relative_path
    self.ext = meta.ext
    self.file_signature = meta.file_signature
    self.skip_runtime_state = meta.skip_runtime_state == true
    self._sample = nil
end

function AudioAsset:get_mode(options)
    return ResourcePolicy.resolve_audio_mode(
    {
        type = self.type,
        ext = self.ext,
        file_signature = self.file_signature,
    }, options)
end

function AudioAsset:get_sample()
    if self._sample then
        return self._sample
    end

    local buffer, err = _read_buffer(self.path)
    if not buffer then
        return nil, err
    end

    local sample = sdl.LoadWAVFromMemory(buffer)
    NativeIO.dispose_buffer(buffer)
    if not sample then
        return nil, string.format("无法解析音频资源：%s", self.path)
    end

    self._sample = sample
    return sample
end

function AudioAsset:create_stream_instance()
    local buffer, err = _read_buffer(self.path)
    if not buffer then
        return nil, err
    end

    local music = rl.LoadMusicStreamFromMemory(self.ext, buffer)
    if not rl.IsMusicValid(music) then
        NativeIO.dispose_buffer(buffer)
        return nil, string.format("无法解析流式音频资源：%s", self.path)
    end

    music.looping = false
    return
    {
        music = music,
        buffer = buffer,
    }
end

function AudioAsset:dispose()
    if self._sample then
        sdl.FreeChunk(self._sample)
        self._sample = nil
    end
end

AudioAsset.__gc = AudioAsset.dispose

return AudioAsset

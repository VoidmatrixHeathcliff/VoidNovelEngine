local Class = require("application.framework.class")
local VideoBackendRegistry = require("application.framework.video_backend_registry")

local VideoPlaybackSession = Class.define("VideoPlaybackSession")

function VideoPlaybackSession:ctor(video_asset, options)
    options = options or {}
    self.asset = video_asset
    self.runtime_path = nil
    self._handle = nil
    self.width = 0
    self.height = 0
    self.duration_seconds = 0
    self.error_message = nil
    self.is_closed = false

    local runtime_path = options.runtime_path or (video_asset and video_asset.get_runtime_path and video_asset:get_runtime_path()) or nil
    if not runtime_path or runtime_path == "" then
        self.error_message = "缺少可用的视频运行时路径"
        self.is_closed = true
        return
    end

    local handle, err = VideoBackendRegistry.create_session_handle(runtime_path, options)
    if not handle then
        self.error_message = err or "创建视频播放会话失败"
        self.is_closed = true
        return
    end

    self.runtime_path = runtime_path
    self._handle = handle
    self:_sync_state()
end

function VideoPlaybackSession:_sync_state()
    if not self._handle then
        return
    end
    self.width = tonumber(self._handle:GetWidth()) or 0
    self.height = tonumber(self._handle:GetHeight()) or 0
    self.duration_seconds = tonumber(self._handle:GetDurationSeconds()) or 0
    if self._handle:HasError() then
        self.error_message = self._handle:GetErrorMessage()
    end
end

function VideoPlaybackSession:play()
    if self._handle then
        self._handle:Play()
    end
end

function VideoPlaybackSession:pause()
    if self._handle then
        self._handle:Pause()
    end
end

function VideoPlaybackSession:stop()
    if self._handle then
        self._handle:Stop()
    end
end

function VideoPlaybackSession:seek_seconds(seconds)
    if self._handle then
        self._handle:SeekSeconds(seconds or 0)
    end
end

function VideoPlaybackSession:set_loop(flag)
    if self._handle then
        self._handle:SetLoop(flag == true)
    end
end

function VideoPlaybackSession:set_volume(volume)
    if self._handle then
        self._handle:SetVolume(volume or 1.0)
    end
end

function VideoPlaybackSession:tick()
    if not self._handle or self.is_closed then
        return
    end
    self._handle:Tick()
    self:_sync_state()
end

function VideoPlaybackSession:is_ready()
    return self._handle and self._handle:IsReady() or false
end

function VideoPlaybackSession:is_playing()
    return self._handle and self._handle:IsPlaying() or false
end

function VideoPlaybackSession:is_finished()
    return self._handle and self._handle:IsEnded() or false
end

function VideoPlaybackSession:has_error()
    return self._handle and self._handle:HasError() or false
end

function VideoPlaybackSession:has_fresh_frame()
    return self._handle and self._handle:HasFreshFrame() or false
end

function VideoPlaybackSession:has_video()
    return self._handle and self._handle:HasVideo() or false
end

function VideoPlaybackSession:update_texture(texture)
    if not self._handle or not texture then
        return false
    end
    local ok = self._handle:UpdateTexture(texture)
    if ok then
        self:_sync_state()
    end
    return ok
end

function VideoPlaybackSession:close()
    if self.is_closed then
        return
    end
    self.is_closed = true
    if self._handle then
        self._handle:Close()
        self._handle = nil
    end
end

VideoPlaybackSession.dispose = VideoPlaybackSession.close
VideoPlaybackSession.__gc = VideoPlaybackSession.close

return VideoPlaybackSession

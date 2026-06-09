local rl = Engine.Raylib

local Class = require("application.framework.class")
local ResourcesManager = require("application.framework.resources_manager")
local SettingsManager = require("application.framework.settings_manager")
local VideoPlaybackManager = require("application.framework.video_playback_manager")

local VideoDecoder = Class.define("VideoDecoder")

local function _resolve_video_texture_filter()
    local filter_mode = SettingsManager.get("filter_mode")
    if filter_mode == rl.TextureFilter.TRILINEAR then
        return rl.TextureFilter.BILINEAR
    end
    return filter_mode
end

local function _create_texture(width, height)
    local image = rl.GenImageColor(width, height, rl.Color(0, 0, 0, 255))
    local texture = rl.LoadTextureFromImage(image)
    -- 视频纹理会在运行时逐帧 UpdateTexture，不能沿用静态贴图的 mipmap / trilinear 配置。
    rl.SetTextureFilter(texture, _resolve_video_texture_filter())
    rl.UnloadImage(image)
    return texture
end

function VideoDecoder:_sync_texture()
    if not self._session then
        return
    end

    local width = tonumber(self._session.width) or 0
    local height = tonumber(self._session.height) or 0
    if width <= 0 or height <= 0 then
        return
    end

    if self.texture and self.width == width and self.height == height then
        return
    end

    if self.texture then
        rl.UnloadTexture(self.texture)
        self.texture = nil
    end

    self.texture = _create_texture(width, height)
    self.width = width
    self.height = height
end

function VideoDecoder:ctor(video)
    local runtime_path, asset_or_err = ResourcesManager.ensure_video_runtime(video,
    {
        reason = "playback",
        usage = "runtime",
        use_cached_status = true,
    })

    if not runtime_path then
        self.error_message = asset_or_err or "无法准备视频运行时资源"
        return false
    end

    local video_asset = asset_or_err
    local session, err = VideoPlaybackManager.create_session(video_asset,
    {
        runtime_path = runtime_path,
    })
    if not session then
        self.error_message = err or "无法创建视频播放会话"
        return false
    end

    self._session = session
    self._video_asset = video_asset
    self.width = 0
    self.height = 0
    self.texture = nil
    self.has_finished = false
    self.has_error = false
    self.error_message = nil
    self._is_closed = false
    self:_sync_texture()
end

function VideoDecoder:play()
    if self._session then
        self._session:play()
    end
end

function VideoDecoder:set_volume(volume)
    if self._session then
        self._session:set_volume(volume or 1.0)
    end
end

function VideoDecoder:on_update(delta)
    if not self._session or self._is_closed then
        return
    end

    self._session:tick(delta)
    self:_sync_texture()

    if self._session:has_error() then
        self.has_error = true
        self.error_message = self._session.error_message or "视频播放失败"
        self.has_finished = true
        return
    end

    if self.texture and self._session:is_ready() and self._session:has_fresh_frame() then
        self._session:update_texture(self.texture)
    end

    if self._session:is_finished() then
        self.has_finished = true
    end
end

function VideoDecoder:close()
    if self._is_closed then
        return
    end
    self._is_closed = true

    if self.texture then
        rl.UnloadTexture(self.texture)
        self.texture = nil
    end

    if self._session then
        VideoPlaybackManager.release_session(self._session)
        self._session = nil
    end
end

VideoDecoder.dispose = VideoDecoder.close
VideoDecoder.__gc = VideoDecoder.close

return VideoDecoder

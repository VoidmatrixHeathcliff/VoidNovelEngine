local sdl = Engine.SDL
local rl = Engine.Raylib

local ResourcePolicy = require("application.framework.resource_policy")

local module = {}

local playback_by_token = {}
local next_token = 0
local stats =
{
    sample_play_count = 0,
    stream_play_count = 0,
    active_sample_count = 0,
    active_stream_count = 0,
}

local ResourcesManager = nil

local function _get_resources_manager()
    if not ResourcesManager then
        ResourcesManager = require("application.framework.resources_manager")
    end
    return ResourcesManager
end

local function _normalize_token(value)
    local token = tonumber(value)
    if not token then
        return nil
    end

    token = math.floor(token)
    if token <= 0 then
        return nil
    end
    return token
end

local function _collect_sorted_token_list()
    local token_list = {}
    for token in pairs(playback_by_token) do
        table.insert(token_list, token)
    end
    table.sort(token_list)
    return token_list
end

local function _cleanup_playback(token, playback)
    playback = playback or playback_by_token[token]
    if not playback then
        return
    end

    if playback.kind == "stream" then
        if playback.music and rl.IsMusicValid(playback.music) then
            rl.StopMusicStream(playback.music)
            rl.UnloadMusicStream(playback.music)
        end
        playback.music = nil
        if playback.stream_buffer then
            require("application.framework.native_io").dispose_buffer(playback.stream_buffer)
            playback.stream_buffer = nil
        end
        stats.active_stream_count = math.max(0, stats.active_stream_count - 1)
    else
        stats.active_sample_count = math.max(0, stats.active_sample_count - 1)
    end

    if playback.keepalive_ticket then
        _get_resources_manager().release_keepalive(playback.keepalive_ticket)
        playback.keepalive_ticket = nil
    end

    playback_by_token[token] = nil
end

local function _allocate_token()
    next_token = next_token + 1
    return next_token
end

local function _resolve_token(preferred_token)
    local token = _normalize_token(preferred_token)
    if token and playback_by_token[token] == nil then
        if token > next_token then
            next_token = token
        end
        return token
    end
    return _allocate_token()
end

local function _clear_all_playbacks()
    for _, token in ipairs(_collect_sorted_token_list()) do
        local playback = playback_by_token[token]
        if playback then
            if playback.kind == "sample" and playback.channel ~= nil then
                sdl.HaltChannel(playback.channel)
            end
            _cleanup_playback(token, playback)
        end
    end
end

local function _create_sample_playback(audio_asset, config)
    local sample, err = audio_asset:get_sample()
    if not sample then
        return nil, err
    end

    local loop_count = tonumber(config.loop_count) or 0
    local fade_ms = math.max(0, math.floor((tonumber(config.fade_in_seconds) or 0) * 1000))
    local channel = sdl.FadeInChannel(-1, sample, loop_count, fade_ms)
    if channel == -1 then
        return nil, string.format("音频播放失败：%s", audio_asset.relative_path or audio_asset.path)
    end

    local volume = math.max(0, math.min(1, tonumber(config.volume) or 1))
    sdl.Volume(channel, math.floor(volume * sdl.MAX_VOLUME))

    stats.sample_play_count = stats.sample_play_count + 1
    stats.active_sample_count = stats.active_sample_count + 1
    return
    {
        kind = "sample",
        channel = channel,
    }
end

local function _create_stream_playback(audio_asset, config)
    local stream_instance, err = audio_asset:create_stream_instance()
    if not stream_instance then
        return nil, err
    end

    local music = stream_instance.music
    local volume = math.max(0, math.min(1, tonumber(config.volume) or 1))
    local fade_in_seconds = math.max(0, tonumber(config.fade_in_seconds) or 0)
    local loop_count = tonumber(config.loop_count) or 0

    rl.SetMusicVolume(music, fade_in_seconds > 0 and 0 or volume)
    if loop_count == -1 then
        music.looping = true
    else
        music.looping = false
    end
    rl.PlayMusicStream(music)

    stats.stream_play_count = stats.stream_play_count + 1
    stats.active_stream_count = stats.active_stream_count + 1
    return
    {
        kind = "stream",
        music = music,
        stream_buffer = stream_instance.buffer,
        current_volume = fade_in_seconds > 0 and 0 or volume,
        target_volume = volume,
        fade_in_seconds = fade_in_seconds,
        fade_in_elapsed = 0,
        fade_out_seconds = 0,
        fade_out_elapsed = 0,
        loop_count = loop_count,
        remaining_loop_count = loop_count,
        stop_requested = false,
    }
end

module.play = function(audio_asset, config, options)
    if not audio_asset then
        return nil, "无效的音频资源"
    end

    config = config or {}
    options = type(options) == "table" and options or {}
    local mode = audio_asset:get_mode(config)
    local playback, err = nil, nil
    if mode == "stream" then
        playback, err = _create_stream_playback(audio_asset, config)
    else
        playback, err = _create_sample_playback(audio_asset, config)
    end

    if not playback then
        return nil, err
    end

    local token = _resolve_token(options.token)
    playback.audio_guid = audio_asset.guid
    playback.audio_asset = audio_asset
    playback.skip_runtime_state = audio_asset.skip_runtime_state == true
    playback.config =
    {
        loop_count = tonumber(config.loop_count) or 0,
        fade_in_seconds = math.max(0, tonumber(config.fade_in_seconds) or 0),
        volume = math.max(0, math.min(1, tonumber(config.volume) or 1)),
        prefer_stream = config.prefer_stream == true,
    }
    playback.keepalive_ticket = _get_resources_manager().acquire_keepalive(audio_asset.guid,
        string.format("audio_playback_%d", token), "runtime")
    playback_by_token[token] = playback
    return token
end

module.stop = function(token, fade_out_seconds)
    local playback = playback_by_token[token]
    if not playback then
        return false
    end

    fade_out_seconds = math.max(0, tonumber(fade_out_seconds) or 0)
    if playback.kind == "sample" then
        if fade_out_seconds > 0 then
            sdl.FadeOutChannel(playback.channel, math.floor(fade_out_seconds * 1000))
        else
            sdl.HaltChannel(playback.channel)
            _cleanup_playback(token, playback)
        end
    else
        if fade_out_seconds > 0 then
            playback.stop_requested = true
            playback.fade_out_seconds = fade_out_seconds
            playback.fade_out_elapsed = 0
        else
            _cleanup_playback(token, playback)
        end
    end
    return true
end

module.stop_all = function(fade_out_seconds)
    fade_out_seconds = math.max(0, tonumber(fade_out_seconds) or 0)
    if fade_out_seconds <= 0 then
        _clear_all_playbacks()
        return
    end

    for _, token in ipairs(_collect_sorted_token_list()) do
        module.stop(token, fade_out_seconds)
    end
end

module.stop_by_audio_guid_prefix = function(guid_prefix, fade_out_seconds, force_cleanup)
    if type(guid_prefix) ~= "string" or guid_prefix == "" then
        return 0
    end

    local token_list = {}
    for token, playback in pairs(playback_by_token) do
        local audio_guid = playback and playback.audio_guid or nil
        if type(audio_guid) == "string" and audio_guid:sub(1, #guid_prefix) == guid_prefix then
            token_list[#token_list + 1] = token
        end
    end

    table.sort(token_list)
    if force_cleanup == true then
        fade_out_seconds = 0
    end
    for _, token in ipairs(token_list) do
        module.stop(token, fade_out_seconds)
        if force_cleanup == true then
            _cleanup_playback(token)
        end
    end
    return #token_list
end

module.is_active = function(token)
    return token ~= nil and playback_by_token[token] ~= nil
end

module.play_preview = function(audio_asset)
    return module.play(audio_asset,
    {
        loop_count = 0,
        fade_in_seconds = 0,
        volume = 1,
        prefer_stream = ResourcePolicy.resolve_audio_mode(
        {
            type = "audio",
            ext = audio_asset.ext,
            file_signature = audio_asset.file_signature,
        }, {loop_count = 0}) == "stream",
    })
end

module.update = function(delta)
    local token_list = {}
    for token in pairs(playback_by_token) do
        table.insert(token_list, token)
    end
    table.sort(token_list)

    for _, token in ipairs(token_list) do
        local playback = playback_by_token[token]
        if playback then
            if playback.kind == "sample" then
                if sdl.PlayingChannel(playback.channel) == 0 then
                    _cleanup_playback(token, playback)
                end
            else
                if playback.music and rl.IsMusicValid(playback.music) then
                    rl.UpdateMusicStream(playback.music)

                    if playback.fade_in_seconds > 0 and playback.fade_in_elapsed < playback.fade_in_seconds then
                        playback.fade_in_elapsed = math.min(playback.fade_in_seconds, playback.fade_in_elapsed + delta)
                        playback.current_volume = playback.target_volume * (playback.fade_in_elapsed / playback.fade_in_seconds)
                        rl.SetMusicVolume(playback.music, playback.current_volume)
                    end

                    if playback.stop_requested and playback.fade_out_seconds > 0 then
                        playback.fade_out_elapsed = math.min(playback.fade_out_seconds, playback.fade_out_elapsed + delta)
                        local ratio = 1 - (playback.fade_out_elapsed / playback.fade_out_seconds)
                        playback.current_volume = math.max(0, playback.target_volume * ratio)
                        rl.SetMusicVolume(playback.music, playback.current_volume)
                        if playback.fade_out_elapsed >= playback.fade_out_seconds then
                            _cleanup_playback(token, playback)
                            playback = nil
                        end
                    end

                    if playback and not rl.IsMusicStreamPlaying(playback.music) then
                        if playback.stop_requested then
                            _cleanup_playback(token, playback)
                        elseif playback.remaining_loop_count == -1 then
                            rl.PlayMusicStream(playback.music)
                            rl.SetMusicVolume(playback.music, playback.current_volume)
                        elseif playback.remaining_loop_count > 0 then
                            playback.remaining_loop_count = playback.remaining_loop_count - 1
                            rl.PlayMusicStream(playback.music)
                            rl.SetMusicVolume(playback.music, playback.current_volume)
                        else
                            _cleanup_playback(token, playback)
                        end
                    end
                else
                    _cleanup_playback(token, playback)
                end
            end
        end
    end
end

module.shutdown = function()
    _clear_all_playbacks()
end

module.get_stats = function()
    return
    {
        sample_play_count = stats.sample_play_count,
        stream_play_count = stats.stream_play_count,
        active_sample_count = stats.active_sample_count,
        active_stream_count = stats.active_stream_count,
        active_count = stats.active_sample_count + stats.active_stream_count,
    }
end

module.collect_runtime_state = function()
    local playback_state_list = {}
    local token_list = {}
    for token in pairs(playback_by_token) do
        table.insert(token_list, token)
    end
    table.sort(token_list)

    for _, token in ipairs(token_list) do
        local playback = playback_by_token[token]
        if playback and playback.audio_guid and playback.skip_runtime_state ~= true then
            local entry =
            {
                token = token,
                audio_guid = playback.audio_guid,
                kind = playback.kind,
                config = playback.config and
                {
                    loop_count = playback.config.loop_count,
                    fade_in_seconds = playback.config.fade_in_seconds,
                    volume = playback.config.volume,
                    prefer_stream = playback.config.prefer_stream == true,
                } or nil,
            }

            if playback.kind == "stream" and playback.music and rl.IsMusicValid(playback.music) then
                entry.position_seconds = rl.GetMusicTimePlayed(playback.music)
                entry.current_volume = playback.current_volume
                entry.target_volume = playback.target_volume
            end
            playback_state_list[#playback_state_list + 1] = entry
        end
    end

    return
    {
        schema_version = 1,
        playback_list = playback_state_list,
    }
end

module.apply_runtime_state = function(state)
    _clear_all_playbacks()

    local snapshot = type(state) == "table" and state or {}
    local ResourcesManager = _get_resources_manager()
    for _, entry in ipairs(snapshot.playback_list or {}) do
        local audio_asset = ResourcesManager.find_audio(entry.audio_guid)
        if audio_asset then
            local token = module.play(audio_asset, entry.config or {}, {token = entry.token})
            local playback = token and playback_by_token[token] or nil
            if playback and playback.kind == "stream"
                and playback.music
                and rl.IsMusicValid(playback.music)
            then
                local position_seconds = tonumber(entry.position_seconds)
                if position_seconds and position_seconds > 0 then
                    rl.SeekMusicStream(playback.music, position_seconds)
                end

                local target_volume = tonumber(entry.target_volume)
                if target_volume then
                    playback.target_volume = math.max(0, math.min(1, target_volume))
                end

                local current_volume = tonumber(entry.current_volume)
                if current_volume then
                    playback.current_volume = math.max(0, math.min(1, current_volume))
                    rl.SetMusicVolume(playback.music, playback.current_volume)
                    if playback.fade_in_seconds > 0 then
                        if playback.target_volume <= 0 then
                            playback.fade_in_elapsed = playback.fade_in_seconds
                        else
                            local ratio = math.max(0, math.min(1, playback.current_volume / playback.target_volume))
                            playback.fade_in_elapsed = playback.fade_in_seconds * ratio
                        end
                    end
                end
            end
        end
    end
    return true
end

module.validate_runtime_state = function(state)
    local snapshot = type(state) == "table" and state or {}
    local ResourcesManager = _get_resources_manager()
    for _, entry in ipairs(snapshot.playback_list or {}) do
        if entry.audio_guid and not ResourcesManager.find_audio(entry.audio_guid) then
            return false, string.format("存档引用的音频资源已不存在：%s", tostring(entry.audio_guid))
        end
    end
    return true
end

return module

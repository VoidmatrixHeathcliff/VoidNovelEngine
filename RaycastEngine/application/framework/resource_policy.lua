local module = {}

local AUDIO_STREAM_EXT_POOL =
{
    [".mp3"] = true,
    [".ogg"] = true,
    [".flac"] = true,
}

local AUDIO_SAMPLE_EXT_POOL =
{
    [".wav"] = true,
}

local AUDIO_STREAM_THRESHOLD_BYTES <const> = 1024 * 1024
local AUDIO_LOOP_STREAM_THRESHOLD_BYTES <const> = 512 * 1024
local TEXTURE_RUNTIME_TTL <const> = 45.0
local TEXTURE_PREVIEW_TTL <const> = 2.5
local VIDEO_PREVIEW_TTL <const> = 2.5
local AUDIO_RUNTIME_TTL <const> = 20.0
local AUDIO_PREVIEW_TTL <const> = 2.0
local SHADER_RUNTIME_TTL <const> = 120.0
local FLOW_DOCUMENT_TTL <const> = 20.0

module.resolve_audio_mode = function(meta, options)
    meta = meta or {}
    options = options or {}

    local ext = string.lower(meta.ext or "")
    local size = tonumber(meta.file_signature and meta.file_signature.size) or 0
    local loop_count = tonumber(options.loop_count) or 0
    local prefer_stream = options.prefer_stream == true

    if prefer_stream then
        return "stream"
    end

    if AUDIO_SAMPLE_EXT_POOL[ext] and size > 0 and size <= AUDIO_STREAM_THRESHOLD_BYTES then
        return "sample"
    end

    if loop_count ~= 0 and size >= AUDIO_LOOP_STREAM_THRESHOLD_BYTES then
        return "stream"
    end

    if AUDIO_STREAM_EXT_POOL[ext] and size >= AUDIO_STREAM_THRESHOLD_BYTES then
        return "stream"
    end

    if AUDIO_STREAM_EXT_POOL[ext] and loop_count ~= 0 then
        return "stream"
    end

    return "sample"
end

module.get_runtime_ttl = function(meta)
    local asset_type = meta and meta.type or nil
    if asset_type == "texture" then
        return TEXTURE_RUNTIME_TTL
    elseif asset_type == "audio" then
        return AUDIO_RUNTIME_TTL
    elseif asset_type == "shader" then
        return SHADER_RUNTIME_TTL
    elseif asset_type == "flow" then
        return FLOW_DOCUMENT_TTL
    elseif asset_type == "font" then
        return math.huge
    elseif asset_type == "video" then
        return math.huge
    end
    return math.huge
end

module.get_preview_ttl = function(meta)
    local asset_type = meta and meta.type or nil
    if asset_type == "texture" then
        return TEXTURE_PREVIEW_TTL
    elseif asset_type == "video" then
        return VIDEO_PREVIEW_TTL
    elseif asset_type == "audio" then
        return AUDIO_PREVIEW_TTL
    end
    return math.huge
end

module.should_collect_runtime = function(meta)
    local asset_type = meta and meta.type or nil
    return asset_type == "texture"
        or asset_type == "audio"
        or asset_type == "shader"
end

module.should_collect_preview = function(meta)
    return meta and (meta.type == "texture" or meta.type == "video")
end

module.get_flow_document_ttl = function()
    return FLOW_DOCUMENT_TTL
end

return module

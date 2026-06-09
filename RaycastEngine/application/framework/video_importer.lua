local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")

local module = {}

local ffmpeg_path <const> = "application/external/ffmpeg.exe"
local runtime_dir_root <const> = ".cache/video"
local legacy_runtime_dir_root <const> = "library/video"
local status_schema_version <const> = 3
local decision_rule_version <const> = 2
local transcode_profile_version <const> = 1
local poster_profile_version <const> = 1
local poster_capture_time_seconds <const> = 0.2
local poster_capture_time_ms <const> = 200

local active_transcode_job_pool = {}
local _ensure_poster_paths

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

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

local function _normalize_path(path)
    if type(path) ~= "string" then
        return nil
    end

    local normalized = path:gsub("\\", "/")
    normalized = normalized:gsub("//+", "/")
    normalized = normalized:gsub("^%./", "")
    return normalized
end

local function _signature_equal(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    return tonumber(left.size) == tonumber(right.size)
        and tonumber(left.mtime) == tonumber(right.mtime)
end

local function _artifact_matches_source(artifact, source_signature)
    if type(artifact) ~= "table" then
        return false
    end
    local path = artifact.path
    if type(path) ~= "string" or path == "" or not NativeIO.file_exists(path) then
        return false
    end
    return _signature_equal(artifact.source_signature, source_signature)
        and tonumber(artifact.profile_version or 0) == transcode_profile_version
        and tonumber(artifact.decision_version or 0) == decision_rule_version
end

local function _status_has_ready_artifact(status, source_signature)
    if type(status) ~= "table" then
        return false
    end

    local artifact = status.transcode_artifact or {}
    local runtime_entry = status.runtime_entry or {}
    local artifact_path = artifact.path
    if type(artifact_path) ~= "string" or artifact_path == "" then
        if runtime_entry.mode == "artifact" then
            artifact_path = runtime_entry.path
        end
    end
    if type(artifact_path) ~= "string" or artifact_path == "" or not NativeIO.file_exists(artifact_path) then
        return false
    end

    local artifact_signature = artifact.source_signature or status.source_signature
    local artifact_profile_version = tonumber(artifact.profile_version or status.transcode_profile_version or 0)
    local artifact_decision_version = tonumber(artifact.decision_version or status.decision_version or 0)
    return _signature_equal(artifact_signature, source_signature)
        and artifact_profile_version == transcode_profile_version
        and artifact_decision_version == decision_rule_version
end

local function _is_probe_complete(probe)
    return type(probe) == "table"
        and type(probe.video_codec) == "string"
        and probe.video_codec ~= ""
end

local function _is_status_current(status)
    if type(status) ~= "table" then
        return false
    end
    return tonumber(status.schema_version or 0) == status_schema_version
        and tonumber(status.decision_version or 0) == decision_rule_version
end

local function _is_synthetic_source_status(meta, status)
    if type(status) ~= "table" then
        return false
    end

    local runtime_entry = status.runtime_entry or {}
    return tonumber(status.schema_version or 0) == 0
        and tonumber(status.decision_version or 0) == 0
        and status.classification == "passthrough"
        and runtime_entry.mode == "source"
        and runtime_entry.path == meta.path
        and not _is_probe_complete(status.probe)
        and (status.last_error or "") == ""
end

local function _normalize_guid_text(value)
    local guid = _trim(value)
    if not guid then
        return nil
    end

    guid = string.lower(guid)
    if not guid:match("^[0-9a-f]+%-%x+%-%x+%-%x+%-%x+$") then
        return nil
    end
    if not guid:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") then
        return nil
    end
    return guid
end

local function _basename(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    return path:match("([^/\\]+)$") or path
end

local function _cache_directory_path(guid)
    return string.format("%s/%s", runtime_dir_root, guid)
end

local function _runtime_artifact_path(guid)
    return string.format("%s/%s/runtime.mp4", runtime_dir_root, guid)
end

local function _legacy_runtime_artifact_path(guid)
    return string.format("%s/%s/runtime.mp4", legacy_runtime_dir_root, guid)
end

local function _runtime_temp_artifact_path(guid)
    return string.format("%s/%s/runtime.transcoding.mp4", runtime_dir_root, guid)
end

local function _runtime_backup_artifact_path(guid)
    return string.format("%s/%s/runtime.rollback.mp4", runtime_dir_root, guid)
end

local function _poster_artifact_path(guid)
    return string.format("%s/%s/poster.jpg", runtime_dir_root, guid)
end

local function _poster_temp_artifact_path(guid)
    return string.format("%s/%s/poster.rendering.jpg", runtime_dir_root, guid)
end

local function _poster_backup_artifact_path(guid)
    return string.format("%s/%s/poster.rollback.jpg", runtime_dir_root, guid)
end

local function _poster_directory(path)
    return path:match("^(.*)/[^/]+$") or path:match("^(.*)\\[^\\]+$") or runtime_dir_root
end

local function _migrate_legacy_artifact_if_needed(guid, target_path, status_path)
    local normalized_target = _normalize_path(target_path) or _runtime_artifact_path(guid)
    local normalized_status_path = _normalize_path(status_path)
    local legacy_path = normalized_status_path or _legacy_runtime_artifact_path(guid)

    if legacy_path == normalized_target then
        return normalized_target
    end

    if not NativeIO.file_exists(legacy_path) or NativeIO.file_exists(normalized_target) then
        return normalized_target
    end

    local ok_dir = NativeIO.create_directories(_poster_directory(normalized_target))
    if not ok_dir then
        return normalized_target
    end

    local ok_move = NativeIO.rename(legacy_path, normalized_target)
    if ok_move then
        return normalized_target
    end

    local ok_copy = NativeIO.copy_file(legacy_path, normalized_target, true)
    if ok_copy then
        NativeIO.remove_file(legacy_path)
    end
    return normalized_target
end

local function _has_ffmpeg()
    return NativeIO.file_exists(ffmpeg_path)
end

local function _to_number(text)
    local value = tonumber(text)
    if value then
        return value
    end
    return nil
end

local function _parse_duration_ms(duration_text)
    if type(duration_text) ~= "string" then
        return nil
    end
    local hour, minute, second = duration_text:match("(%d+):(%d+):(%d+%.%d+)")
    if not hour then
        return nil
    end
    local total_seconds = tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
    return math.floor(total_seconds * 1000 + 0.5)
end

local function _parse_probe_text(text)
    if type(text) ~= "string" or text == "" then
        return nil, "ffmpeg 未返回可解析的探测信息"
    end

    local probe = {}
    probe.container = text:match("Input #%d+,%s*(.-),%s*from%s+'")

    local duration_text = text:match("Duration:%s*([%d%.:]+)")
    if duration_text then
        probe.duration_ms = _parse_duration_ms(duration_text)
    end

    local video_line = text:match("Stream #.-Video:%s*([^\r\n]+)")
    if video_line then
        probe.video_codec = video_line:match("^([^,%s]+)")
        probe.pixel_format = video_line:match(",%s*([%w%d_]+)%s*[%(,]")
        local width, height = video_line:match("(%d%d+)x(%d%d+)")
        probe.width = _to_number(width)
        probe.height = _to_number(height)
        probe.frame_rate = _to_number(video_line:match("([%d%.]+)%s*fps"))
    end

    local audio_line = text:match("Stream #.-Audio:%s*([^\r\n]+)")
    if audio_line then
        probe.audio_codec = audio_line:match("^([^,%s]+)")
    end

    if not probe.video_codec then
        return nil, "当前视频资源不包含可播放的视频流"
    end

    return probe
end

local function _parse_progress_time_ms(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end

    local duration_ms = _parse_duration_ms(value:match("^(%d+:%d+:%d+%.%d+)") or "")
    if duration_ms then
        return duration_ms
    end

    local numeric = tonumber(value)
    if not numeric then
        return nil
    end

    if numeric > 100000 then
        return math.floor(numeric / 1000 + 0.5)
    end

    return math.floor(numeric + 0.5)
end

local function _probe_video(meta)
    local result = NativeIO.run_process_capture(ffmpeg_path, {"-hide_banner", "-i", meta.path})
    local detail = result.stderr
    if not detail or detail == "" then
        detail = result.stdout
    end
    local probe, err = _parse_probe_text(detail)
    if not probe then
        return nil, err or result.message or "视频探测失败"
    end
    return probe
end

local function _classify_probe(meta, probe)
    local ext = string.lower(meta.ext or "")
    local container = string.lower(probe.container or "")
    local video_codec = string.lower(probe.video_codec or "")
    local audio_codec = string.lower(probe.audio_codec or "")
    local pixel_format = string.lower(probe.pixel_format or "")

    local container_ok = ext == ".mp4" or ext == ".m4v"
        or container:find("mov,mp4", 1, true) ~= nil
        or container:find("mp4", 1, true) ~= nil
    local video_ok = video_codec == "h264"
    local audio_ok = audio_codec == "" or audio_codec == "aac"
    local pixel_ok = pixel_format == ""
        or pixel_format == "yuv420p"
        or pixel_format == "yuvj420p"

    if container_ok and video_ok and audio_ok and pixel_ok then
        return "passthrough",
        {
            wmf_runtime_ready = true,
            reason = "",
        }
    end

    return "needs_transcode",
    {
        wmf_runtime_ready = false,
        reason = "素材不满足当前 WMF 运行时标准格式，将自动转码为 MP4/H.264/AAC/yuv420p",
    }
end

local function _build_status(meta)
    local current = ResourceIndex.get_importer_data(meta.guid, "video") or {}
    local artifact_path = _migrate_legacy_artifact_if_needed(
        meta.guid,
        _runtime_artifact_path(meta.guid),
        current.transcode_artifact and current.transcode_artifact.path or nil)
    local runtime_entry = _clone_value(current.runtime_entry or {mode = "source", path = meta.path})
    if runtime_entry.mode == "artifact" then
        runtime_entry.path = artifact_path
    else
        runtime_entry.path = _normalize_path(runtime_entry.path) or meta.path
    end

    local status =
    {
        schema_version = tonumber(current.schema_version or 0),
        decision_version = tonumber(current.decision_version or 0),
        source_signature = _clone_value(meta.file_signature or {}),
        probe = _clone_value(current.probe or {}),
        classification = current.classification or "passthrough",
        compatibility = _clone_value(current.compatibility or {wmf_runtime_ready = true, reason = ""}),
        runtime_entry = runtime_entry,
        transcode_profile_version = tonumber(current.transcode_profile_version or 0),
        transcode_artifact = _clone_value(current.transcode_artifact or
        {
            source_signature = _clone_value(current.source_signature),
        }),
        poster_artifact = _clone_value(current.poster_artifact or
        {
            source_signature = _clone_value(current.source_signature),
        }),
        last_error = current.last_error or "",
    }
    status.transcode_artifact.path = artifact_path
    status.transcode_artifact.exists = NativeIO.file_exists(artifact_path)
    if status.transcode_artifact.source_signature == nil then
        status.transcode_artifact.source_signature = _clone_value(current.source_signature)
    end
    status = _ensure_poster_paths(status, meta)
    if status.poster_artifact.source_signature == nil then
        status.poster_artifact.source_signature = _clone_value(current.source_signature)
    end
    return status
end

local function _write_status(meta, status)
    status = _clone_value(status)
    status.transcode_artifact = status.transcode_artifact or {}
    status.transcode_artifact.path = _migrate_legacy_artifact_if_needed(
        meta.guid,
        _runtime_artifact_path(meta.guid),
        status.transcode_artifact.path)
    status.transcode_artifact.exists = NativeIO.file_exists(status.transcode_artifact.path)
    status.transcode_profile_version = transcode_profile_version
    status.runtime_entry = status.runtime_entry or {mode = "source", path = meta.path}
    if status.runtime_entry.mode == "artifact" then
        status.runtime_entry.path = status.transcode_artifact.path
    else
        status.runtime_entry.path = meta.path
    end
    status = _ensure_poster_paths(status, meta)
    ResourceIndex.set_importer_data(meta.guid, "video", status)
    return status
end

local function _build_transcode_args(meta, output_path)
    return
    {
        "-hide_banner",
        "-nostats",
        "-v", "error",
        "-progress", "pipe:1",
        "-y",
        "-i", meta.path,
        "-map", "0:v:0",
        "-map", "0:a:0?",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        "-preset", "medium",
        "-crf", "18",
        "-c:a", "aac",
        "-b:a", "192k",
        "-ar", "48000",
        "-ac", "2",
        output_path,
    }
end

local function _build_poster_args(meta, output_path, capture_time_seconds)
    local capture_time = math.max(0, tonumber(capture_time_seconds) or poster_capture_time_seconds)
    return
    {
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-ss", string.format("%.3f", capture_time),
        "-i", meta.path,
        "-an",
        "-frames:v", "1",
        "-vf", "scale=512:-2:force_original_aspect_ratio=decrease",
        "-q:v", "3",
        output_path,
    }
end

local function _ensure_transcode_paths(status, meta)
    status.transcode_artifact = status.transcode_artifact or {path = _runtime_artifact_path(meta.guid)}
    status.transcode_artifact.path = status.transcode_artifact.path or _runtime_artifact_path(meta.guid)
    status.transcode_artifact.exists = NativeIO.file_exists(status.transcode_artifact.path)
    return status
end

_ensure_poster_paths = function(status, meta)
    status.poster_artifact = status.poster_artifact or {path = _poster_artifact_path(meta.guid)}
    status.poster_artifact.path = _normalize_path(status.poster_artifact.path) or _poster_artifact_path(meta.guid)
    status.poster_artifact.exists = NativeIO.file_exists(status.poster_artifact.path)
    return status
end

local function _mark_passthrough_ready(meta, status)
    status.runtime_entry = {mode = "source", path = meta.path}
    status.compatibility = {wmf_runtime_ready = true, reason = ""}
    status.last_error = ""
    return _write_status(meta, status)
end

local function _mark_artifact_ready(meta, status)
    status = _ensure_transcode_paths(status, meta)
    status.transcode_artifact.source_signature = _clone_value(status.source_signature)
    status.transcode_artifact.profile_version = transcode_profile_version
    status.transcode_artifact.decision_version = decision_rule_version
    status.transcode_artifact.exists = NativeIO.file_exists(status.transcode_artifact.path)
    status.runtime_entry = {mode = "artifact", path = status.transcode_artifact.path}
    status.compatibility = {wmf_runtime_ready = true, reason = ""}
    status.last_error = ""
    return _write_status(meta, status)
end

local function _mark_transcode_failed(meta, status, error_message)
    status = _ensure_transcode_paths(status, meta)
    status.transcode_artifact.exists = NativeIO.file_exists(status.transcode_artifact.path)
    status.transcode_artifact.source_signature = nil
    status.classification = "error"
    status.compatibility = {wmf_runtime_ready = false, reason = error_message or "视频转码失败"}
    status.last_error = error_message or "视频转码失败"
    return _write_status(meta, status)
end

local function _cleanup_file_if_exists(path)
    if type(path) ~= "string" or path == "" then
        return true
    end
    if not NativeIO.file_exists(path) then
        return true
    end
    return NativeIO.remove_file(path)
end

local function _promote_temp_artifact(final_path, temp_path, backup_path)
    local ok_cleanup_backup, cleanup_backup_err = _cleanup_file_if_exists(backup_path)
    if not ok_cleanup_backup then
        return false, cleanup_backup_err or "无法清理旧的回滚文件"
    end

    local had_old_target = NativeIO.file_exists(final_path)
    if had_old_target then
        local ok_backup, err_backup = NativeIO.rename(final_path, backup_path)
        if not ok_backup then
            return false, err_backup or "无法为旧的视频产物创建回滚备份"
        end
    end

    local ok_promote, err_promote = NativeIO.rename(temp_path, final_path)
    if ok_promote then
        _cleanup_file_if_exists(backup_path)
        return true
    end

    if had_old_target and NativeIO.file_exists(backup_path) then
        NativeIO.rename(backup_path, final_path)
    end
    _cleanup_file_if_exists(temp_path)
    return false, err_promote or "无法写入最终的视频转码产物"
end

local function _run_transcode(meta, artifact_path)
    local temp_path = _runtime_temp_artifact_path(meta.guid)
    local backup_path = _runtime_backup_artifact_path(meta.guid)

    local ok_create, create_err = NativeIO.create_directories(_poster_directory(artifact_path))
    if not ok_create then
        return false, string.format("无法创建视频转码目录：%s", create_err or "未知错误")
    end

    _cleanup_file_if_exists(temp_path)
    _cleanup_file_if_exists(backup_path)

    local result = NativeIO.run_process_capture(ffmpeg_path, _build_transcode_args(meta, temp_path))
    if result.success and NativeIO.file_exists(temp_path) then
        local ok_promote, promote_err = _promote_temp_artifact(artifact_path, temp_path, backup_path)
        if ok_promote and NativeIO.file_exists(artifact_path) then
            return true
        end
        return false, promote_err or "视频转码产物落盘失败"
    end

    _cleanup_file_if_exists(temp_path)
    _cleanup_file_if_exists(backup_path)

    local detail = result.stderr
    if not detail or detail == "" then
        detail = result.stdout
    end
    if not detail or detail == "" then
        detail = result.message
    end
    return false, detail or "ffmpeg 转码失败"
end

local function _run_poster_capture(meta, poster_path, capture_time_seconds)
    local temp_path = _poster_temp_artifact_path(meta.guid)
    local backup_path = _poster_backup_artifact_path(meta.guid)
    local capture_time_ms = math.floor(math.max(0, tonumber(capture_time_seconds) or 0) * 1000 + 0.5)

    local ok_create, create_err = NativeIO.create_directories(_poster_directory(poster_path))
    if not ok_create then
        return false, string.format("无法创建视频封面目录：%s", create_err or "未知错误")
    end

    _cleanup_file_if_exists(temp_path)
    _cleanup_file_if_exists(backup_path)

    local result = NativeIO.run_process_capture(ffmpeg_path, _build_poster_args(meta, temp_path, capture_time_seconds))
    if result.success and NativeIO.file_exists(temp_path) then
        local ok_promote, promote_err = _promote_temp_artifact(poster_path, temp_path, backup_path)
        if ok_promote and NativeIO.file_exists(poster_path) then
            return true,
            {
                capture_time_ms = capture_time_ms,
            }
        end
        return false, promote_err or "视频封面写入失败"
    end

    _cleanup_file_if_exists(temp_path)
    _cleanup_file_if_exists(backup_path)

    local detail = result.stderr
    if not detail or detail == "" then
        detail = result.stdout
    end
    if not detail or detail == "" then
        detail = result.message
    end
    return false, detail or "ffmpeg 视频封面抽帧失败"
end

local function _capture_poster_with_fallback(meta, poster_path)
    local ok_capture, result_or_err = _run_poster_capture(meta, poster_path, poster_capture_time_seconds)
    if ok_capture then
        return true, result_or_err
    end

    if poster_capture_time_ms > 0 then
        local ok_fallback, fallback_result_or_err = _run_poster_capture(meta, poster_path, 0)
        if ok_fallback then
            return true, fallback_result_or_err
        end
        result_or_err = fallback_result_or_err or result_or_err
    end

    return false, result_or_err
end

local function _perform_transcode_if_needed(meta, status, options)
    options = options or {}
    status = _ensure_transcode_paths(status, meta)

    if status.classification == "passthrough" then
        return _mark_passthrough_ready(meta, status)
    end

    if status.classification ~= "needs_transcode" then
        local detail = status.last_error
        if type(detail) ~= "string" or detail == "" then
            detail = "当前视频资源不可进行自动转码"
        end
        return nil, detail, _write_status(meta, status)
    end

    if not _has_ffmpeg() then
        status.compatibility = {wmf_runtime_ready = false, reason = "未检测到 ffmpeg.exe，无法执行自动转码"}
        status.last_error = status.compatibility.reason
        return nil, status.last_error, _write_status(meta, status)
    end

    if not options.force_transcode
        and _status_has_ready_artifact(status, status.source_signature) then
        return _mark_artifact_ready(meta, status)
    end

    if options.allow_transcode == false then
        return _write_status(meta, status)
    end

    local ok_transcode, transcode_err = _run_transcode(meta, status.transcode_artifact.path)
    if not ok_transcode then
        return nil, transcode_err, _mark_transcode_failed(meta, status, transcode_err)
    end

    return _mark_artifact_ready(meta, status)
end

local function _is_status_reusable(meta, status)
    if not _is_status_current(status) or not _signature_equal(status.source_signature, meta.file_signature) then
        return false
    end

    if _has_ffmpeg() and not _is_probe_complete(status.probe) then
        return false
    end

    local runtime_entry = status.runtime_entry or {}
    if runtime_entry.mode == "artifact" then
        local artifact = status.transcode_artifact or {}
        return _artifact_matches_source(artifact, meta.file_signature)
    end

    if runtime_entry.mode ~= "source" then
        return false
    end

    if status.classification ~= "passthrough" then
        return false
    end

    local compatibility = status.compatibility or {}
    if compatibility.wmf_runtime_ready ~= true then
        return false
    end

    return runtime_entry.path ~= nil and runtime_entry.path ~= "" and NativeIO.file_exists(meta.path)
end

local function _resolve_meta(value)
    if type(value) == "table" and value.guid then
        return ResourceIndex.find_by_guid(value.guid)
    end

    local guid = ResourceIndex.resolve_guid("video", value)
    if not guid then
        return nil
    end
    return ResourceIndex.find_by_guid(guid)
end

local function _resolve_runtime_from_status(meta, status)
    status = status or _build_status(meta)

    if not _is_status_current(status) then
        if not (_is_synthetic_source_status(meta, status) and not _has_ffmpeg()) then
            return nil, "视频导入状态已过期，请等待启动校验完成后重试", status
        end
    end

    local compatibility = status.compatibility or {}
    if compatibility.wmf_runtime_ready == false then
        local reason = compatibility.reason
        if type(reason) == "string" and reason ~= "" then
            return nil, reason, status
        end
        return nil, status.last_error ~= "" and status.last_error or "视频资源当前不可直接播放", status
    end

    if status.classification == "error" then
        return nil, status.last_error ~= "" and status.last_error or "视频资源不可用", status
    end

    local runtime_entry = status.runtime_entry or {}
    if status.classification == "needs_transcode" and runtime_entry.mode ~= "artifact" then
        local reason = compatibility.reason
        if type(reason) == "string" and reason ~= "" then
            return nil, reason, status
        end
        return nil, "视频资源尚未完成转码准备", status
    end

    local runtime_path = runtime_entry.path
    if runtime_entry.mode == "artifact" then
        if runtime_path and runtime_path ~= "" and NativeIO.file_exists(runtime_path) then
            return runtime_path, status
        end
        return nil, status.last_error ~= "" and status.last_error or "缺少视频转码产物", status
    end

    if runtime_path and runtime_path ~= "" and NativeIO.file_exists(runtime_path) then
        return runtime_path, status
    end
    return nil, "视频源文件不存在", status
end

local function _resolve_refresh_status(meta)
    local status = module.get_status(meta.guid)
    if not _is_status_current(status) or not _signature_equal(status.source_signature, meta.file_signature) then
        local refreshed_status = module.refresh_meta(meta,
        {
            force = true,
            allow_transcode = false,
        })
        if not refreshed_status then
            return nil, "视频导入状态刷新失败"
        end
        status = refreshed_status
    end
    return status
end

local function _dispose_job_pipe(job)
    if job and job.pipe then
        NativeIO.dispose_process(job.pipe)
        job.pipe = nil
    end
end

local function _remove_job_from_pool(job)
    if job and active_transcode_job_pool[job.guid] == job then
        active_transcode_job_pool[job.guid] = nil
    end
end

local function _set_job_error_tail(job, line)
    if type(line) ~= "string" then
        return
    end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
        return
    end

    job.error_tail_list = job.error_tail_list or {}
    table.insert(job.error_tail_list, line)
    while #job.error_tail_list > 12 do
        table.remove(job.error_tail_list, 1)
    end
end

local function _parse_job_progress_line(job, line)
    local key, value = line:match("^([%w_]+)=(.*)$")
    if not key then
        _set_job_error_tail(job, line)
        return
    end

    job.progress_map = job.progress_map or {}
    job.progress_map[key] = value

    if key == "out_time" then
        local current_ms = _parse_progress_time_ms(value)
        if current_ms then
            job.progress_time_ms = current_ms
        end
    elseif key == "out_time_ms" or key == "out_time_us" then
        local current_ms = _parse_progress_time_ms(value)
        if current_ms then
            job.progress_time_ms = current_ms
        end
    elseif key == "speed" then
        job.speed_text = value
    elseif key == "progress" then
        job.progress_state = value
    end

    if tonumber(job.duration_ms or 0) and job.duration_ms > 0 and tonumber(job.progress_time_ms or 0) then
        job.progress_ratio = math.max(0, math.min(0.999, job.progress_time_ms / job.duration_ms))
    end
end

local function _consume_job_output(job, text)
    if type(text) ~= "string" or text == "" then
        return
    end

    job.output_buffer = (job.output_buffer or "") .. text
    job.output_buffer = job.output_buffer:gsub("\r\n", "\n"):gsub("\r", "\n")

    while true do
        local newline_index = job.output_buffer:find("\n", 1, true)
        if not newline_index then
            break
        end

        local line = job.output_buffer:sub(1, newline_index - 1)
        job.output_buffer = job.output_buffer:sub(newline_index + 1)
        _parse_job_progress_line(job, line)
    end
end

local function _flush_job_output(job)
    if job.output_buffer and job.output_buffer ~= "" then
        _parse_job_progress_line(job, job.output_buffer)
        job.output_buffer = ""
    end
end

local function _build_job_error_message(job, fallback_message)
    local detail = job and job.error_tail_list and table.concat(job.error_tail_list, "\n") or ""
    if detail ~= "" then
        return detail
    end
    return fallback_message or "视频转码失败"
end

local function _cancel_job(job, reason)
    if not job or job.state == "cancelled" or job.state == "success" or job.state == "failed" then
        return
    end

    _dispose_job_pipe(job)
    _cleanup_file_if_exists(job.temp_path)
    _cleanup_file_if_exists(job.backup_path)
    job.state = "cancelled"
    job.error_message = reason or "视频转码任务已取消"
    _remove_job_from_pool(job)
end
local function _create_async_job(meta, status, options)
    options = options or {}
    status = _ensure_transcode_paths(_clone_value(status), meta)

    local current_job = active_transcode_job_pool[meta.guid]
    if current_job then
        local same_request = current_job.state ~= "cancelled"
            and current_job.state ~= "failed"
            and current_job.state ~= "success"
            and _signature_equal(current_job.source_signature, status.source_signature)
            and current_job.force_transcode == (options.force_transcode == true)
        if same_request then
            return current_job
        end
        _cancel_job(current_job, "已切换到更新的视频转码请求")
    end
    if status.classification == "passthrough" then
        return
        {
            guid = meta.guid,
            meta = meta,
            label = string.format("自动转码视频资源：%s", meta.relative_path),
            relative_path = meta.relative_path,
            progress_ratio = 1,
            state = "success",
            final_status = _mark_passthrough_ready(meta, status),
        }
    end

    if status.classification ~= "needs_transcode" then
        return nil, status.last_error ~= "" and status.last_error or "当前视频资源不可进行自动转码", _write_status(meta, status)
    end

    if not _has_ffmpeg() then
        local err = "未检测到 ffmpeg.exe，无法执行自动转码"
        return nil, err, _mark_transcode_failed(meta, status, err)
    end

    if not options.force_transcode
        and _status_has_ready_artifact(status, status.source_signature) then
        return
        {
            guid = meta.guid,
            meta = meta,
            label = string.format("自动转码视频资源：%s", meta.relative_path),
            relative_path = meta.relative_path,
            progress_ratio = 1,
            state = "success",
            final_status = _mark_artifact_ready(meta, status),
        }
    end

    local final_path = status.transcode_artifact.path or _runtime_artifact_path(meta.guid)
    local temp_path = _runtime_temp_artifact_path(meta.guid)
    local backup_path = _runtime_backup_artifact_path(meta.guid)

    local ok_create, create_err = NativeIO.create_directories(_poster_directory(final_path))
    if not ok_create then
        local err = string.format("无法创建视频转码目录：%s", create_err or "未知错误")
        return nil, err, _mark_transcode_failed(meta, status, err)
    end

    _cleanup_file_if_exists(temp_path)
    _cleanup_file_if_exists(backup_path)

    local pipe, start_err = NativeIO.start_process(ffmpeg_path, _build_transcode_args(meta, temp_path))
    if not pipe then
        local err = start_err or "无法启动 ffmpeg 转码进程"
        return nil, err, _mark_transcode_failed(meta, status, err)
    end

    local job =
    {
        guid = meta.guid,
        meta = meta,
        status = status,
        source_signature = _clone_value(status.source_signature),
        label = string.format("自动转码视频资源：%s", meta.relative_path),
        relative_path = meta.relative_path,
        final_path = final_path,
        temp_path = temp_path,
        backup_path = backup_path,
        force_transcode = options.force_transcode == true,
        pipe = pipe,
        state = "running",
        progress_ratio = 0,
        duration_ms = status.probe and status.probe.duration_ms or nil,
        progress_time_ms = 0,
        progress_state = "continue",
        speed_text = "",
        output_buffer = "",
        error_tail_list = {},
    }

    active_transcode_job_pool[meta.guid] = job
    return job
end

local function _read_job_output(job)
    if not job.pipe or not job.pipe.open then
        return
    end

    while true do
        local available = tonumber(job.pipe:available()) or 0
        if available <= 0 then
            break
        end
        local chunk = job.pipe:read(math.min(available, 65536))
        if not chunk or chunk == "" then
            break
        end
        _consume_job_output(job, chunk)
    end
end

local function _finish_job_success(job)
    local ok_promote, promote_err = _promote_temp_artifact(job.final_path, job.temp_path, job.backup_path)
    if not ok_promote or not NativeIO.file_exists(job.final_path) then
        local err = promote_err or "视频转码产物落盘失败"
        job.state = "failed"
        job.error_message = err
        job.final_status = _mark_transcode_failed(job.meta, job.status, err)
        _remove_job_from_pool(job)
        return "failed", job.error_message, job.final_status
    end

    job.progress_ratio = 1
    job.state = "success"
    job.final_status = _mark_artifact_ready(job.meta, job.status)
    _remove_job_from_pool(job)
    return "success", job.final_status
end

local function _finish_job_failure(job, fallback_message)
    _cleanup_file_if_exists(job.temp_path)
    _cleanup_file_if_exists(job.backup_path)
    job.state = "failed"
    job.error_message = _build_job_error_message(job, fallback_message)
    job.final_status = _mark_transcode_failed(job.meta, job.status, job.error_message)
    _remove_job_from_pool(job)
    return "failed", job.error_message, job.final_status
end

module.is_ffmpeg_available = function()
    return _has_ffmpeg()
end

module.refresh_meta = function(meta, options)
    options = options or {}
    if not meta or meta.type ~= "video" then
        return nil, "无效的视频资源元数据"
    end

    local status = _build_status(meta)
    if not options.force and _is_status_reusable(meta, status) then
        return _write_status(meta, status)
    end

    status.schema_version = status_schema_version
    status.decision_version = decision_rule_version
    status.source_signature = _clone_value(meta.file_signature or {})
    status.runtime_entry = {mode = "source", path = meta.path}
    status.transcode_artifact = status.transcode_artifact or {path = _runtime_artifact_path(meta.guid)}
    status.transcode_artifact.path = status.transcode_artifact.path or _runtime_artifact_path(meta.guid)
    status.transcode_artifact.exists = NativeIO.file_exists(status.transcode_artifact.path)
    status.transcode_profile_version = transcode_profile_version
    status.last_error = ""

    if _has_ffmpeg() then
        local probe, probe_err = _probe_video(meta)
        if not probe then
            return _mark_transcode_failed(meta, status, probe_err or "视频探测失败")
        end

        status.probe = probe
        status.classification, status.compatibility = _classify_probe(meta, probe)
        if status.classification == "passthrough" then
            return _mark_passthrough_ready(meta, status)
        end

        return _perform_transcode_if_needed(meta, status, options)
    end

    if _status_has_ready_artifact(status, status.source_signature) then
        status.classification = "needs_transcode"
        return _mark_artifact_ready(meta, status)
    end

    status.transcode_artifact.source_signature = nil
    status.classification = "passthrough"
    status.compatibility =
    {
        wmf_runtime_ready = true,
        reason = "当前未检测到 ffmpeg.exe，将在运行时直接尝试播放源文件",
    }
    status.runtime_entry = {mode = "source", path = meta.path}
    return _write_status(meta, status)
end

module.refresh_guid = function(guid, options)
    local meta = _resolve_meta(guid)
    if not meta then
        return nil, "无法定位视频资源"
    end
    return module.refresh_meta(meta, options)
end

module.begin_transcode_job = function(guid, options)
    local meta = _resolve_meta(guid)
    if not meta then
        return nil, "无法定位视频资源"
    end

    local status, refresh_err = _resolve_refresh_status(meta)
    if not status then
        return nil, refresh_err or "视频导入状态刷新失败"
    end

    return _create_async_job(meta, status, options)
end

module.tick_transcode_job = function(job, delta)
    if not job then
        return "failed", "视频转码任务不存在"
    end

    if job.state == "success" then
        return "success", job.final_status
    end
    if job.state == "failed" then
        return "failed", job.error_message, job.final_status
    end
    if job.state == "cancelled" then
        return "cancelled", job.error_message, job.final_status
    end

    _read_job_output(job)

    local exit_code = job.pipe and job.pipe:wait(0) or 0
    if exit_code == -1 then
        return "pending"
    end

    _read_job_output(job)
    _flush_job_output(job)
    _dispose_job_pipe(job)

    if exit_code == 0 and NativeIO.file_exists(job.temp_path) then
        return _finish_job_success(job)
    end

    local fallback_message = string.format("ffmpeg 转码失败，退出码：%s", tostring(exit_code))
    return _finish_job_failure(job, fallback_message)
end

module.cancel_transcode_job = function(job, reason)
    _cancel_job(job, reason)
end

module.shutdown = function()
    local job_list = {}
    for _, job in pairs(active_transcode_job_pool) do
        table.insert(job_list, job)
    end
    for _, job in ipairs(job_list) do
        _cancel_job(job)
    end
    active_transcode_job_pool = {}
end

module.create_transcode_task = function(guid, options)
    options = options or {}

    local meta = _resolve_meta(guid)
    if not meta then
        return nil, "无法定位视频资源"
    end

    local job = nil
    return
    {
        label = string.format("自动转码视频资源：%s", meta.relative_path),
        present_before_run = true,
        run = function(shared, runner, delta)
            if not job then
                local created_job, err, fallback_status = module.begin_transcode_job(meta.guid,
                {
                    force_transcode = options.force_transcode == true,
                })
                if not created_job then
                    if options.on_error then
                        options.on_error(meta, err, fallback_status, nil)
                    end
                    runner:clear_task_progress()
                    return
                end
                job = created_job
            end

            local state, status_or_err, fallback_status = module.tick_transcode_job(job, delta)
            if state == "pending" then
                runner:set_task_progress(job.progress_ratio or 0, job.label)
                return runner:pending()
            end

            runner:clear_task_progress()
            if state == "success" then
                if options.on_success then
                    options.on_success(meta, status_or_err, job)
                end
                return
            end

            if options.on_error then
                options.on_error(meta, status_or_err, fallback_status, job)
            end
        end
    }
end

module.transcode_guid = function(guid, options)
    options = options or {}

    local meta = _resolve_meta(guid)
    if not meta then
        return nil, "无法定位视频资源"
    end

    local status, refresh_err = _resolve_refresh_status(meta)
    if not status then
        return nil, refresh_err or "视频导入状态刷新失败"
    end

    local transcode_status, transcode_err, fallback_status = _perform_transcode_if_needed(meta, status,
    {
        allow_transcode = true,
        force_transcode = options.force_transcode == true,
    })
    if not transcode_status then
        return nil, transcode_err, fallback_status
    end
    return transcode_status
end

module.get_status = function(value)
    local meta = _resolve_meta(value)
    if not meta then
        return nil
    end
    return ResourceIndex.get_importer_data(meta.guid, "video") or _build_status(meta)
end

module.should_schedule_transcode = function(value, options)
    options = options or {}

    local meta = _resolve_meta(value)
    if not meta then
        return false
    end

    local status = options.status or module.get_status(meta.guid)
    if type(status) ~= "table" then
        return false
    end
    if status.classification ~= "needs_transcode" then
        return false
    end

    local source_signature = _clone_value(status.source_signature or meta.file_signature or {})
    local has_ready_artifact = _status_has_ready_artifact(status, source_signature)
    if not options.force_transcode and has_ready_artifact then
        return false
    end

    local current_job = active_transcode_job_pool[meta.guid]
    if current_job then
        local same_request = current_job.state ~= "cancelled"
            and current_job.state ~= "failed"
            and current_job.state ~= "success"
            and _signature_equal(current_job.source_signature, source_signature)
            and current_job.force_transcode == (options.force_transcode == true)
        if same_request then
            return false
        end
    end

    if options.force_transcode == true then
        return true
    end

    return not has_ready_artifact
end

local function _poster_matches_source(artifact, source_signature)
    if type(artifact) ~= "table" then
        return false
    end

    local path = artifact.path
    if type(path) ~= "string" or path == "" or not NativeIO.file_exists(path) then
        return false
    end

    return _signature_equal(artifact.source_signature, source_signature)
        and tonumber(artifact.profile_version or 0) == poster_profile_version
end

local function _status_has_ready_poster(status, source_signature)
    if type(status) ~= "table" then
        return false
    end

    local artifact = status.poster_artifact or {}
    return _poster_matches_source(artifact, source_signature)
end

module.ensure_runtime = function(value, options)
    options = options or {}

    local meta = _resolve_meta(value)
    if not meta then
        return nil, "无法定位视频资源"
    end

    if options.use_cached_status == true then
        return _resolve_runtime_from_status(meta, module.get_status(meta.guid))
    end

    local status = module.refresh_meta(meta, options)
    if not status then
        return nil, "视频导入状态刷新失败"
    end

    return _resolve_runtime_from_status(meta, status)
end

module.ensure_poster = function(value, options)
    options = options or {}

    local meta = _resolve_meta(value)
    if not meta then
        return nil, "无法定位视频资源"
    end

    local status = options.status
    if type(status) ~= "table"
        or not _is_status_current(status)
        or not _signature_equal(status.source_signature, meta.file_signature) then
        local refreshed_status, refresh_err = _resolve_refresh_status(meta)
        if not refreshed_status then
            return nil, refresh_err or "视频导入状态刷新失败"
        end
        status = refreshed_status
    end

    status = _ensure_poster_paths(status, meta)
    if not options.force_capture and _status_has_ready_poster(status, status.source_signature) then
        return status.poster_artifact.path, _write_status(meta, status)
    end

    if not _has_ffmpeg() then
        status.poster_artifact.last_error = "未检测到 ffmpeg.exe，无法生成视频封面"
        status.poster_artifact.exists = NativeIO.file_exists(status.poster_artifact.path)
        return nil, status.poster_artifact.last_error, _write_status(meta, status)
    end

    local ok_capture, result_or_err = _capture_poster_with_fallback(meta, status.poster_artifact.path)
    if not ok_capture then
        status.poster_artifact.source_signature = nil
        status.poster_artifact.last_error = result_or_err or "视频封面生成失败"
        status.poster_artifact.exists = NativeIO.file_exists(status.poster_artifact.path)
        return nil, status.poster_artifact.last_error, _write_status(meta, status)
    end

    status.poster_artifact.source_signature = _clone_value(status.source_signature)
    status.poster_artifact.profile_version = poster_profile_version
    status.poster_artifact.capture_time_ms = result_or_err.capture_time_ms or poster_capture_time_ms
    status.poster_artifact.last_error = ""
    status.poster_artifact.exists = NativeIO.file_exists(status.poster_artifact.path)
    return status.poster_artifact.path, _write_status(meta, status)
end

module.ensure_export_ready = function(reference_list, options)
    local error_list = {}
    for _, value in ipairs(reference_list or {}) do
        local runtime_path, err = module.ensure_runtime(value, options)
        if not runtime_path then
            table.insert(error_list, tostring(err))
        end
    end
    if #error_list > 0 then
        return false, table.concat(error_list, "\n")
    end
    return true
end

module.cleanup_cache_for_guid = function(guid)
    local normalized_guid = _normalize_guid_text(guid)
    if not normalized_guid then
        return nil, "无效的视频资源 GUID"
    end

    local cache_dir = _cache_directory_path(normalized_guid)
    if not NativeIO.directory_exists(cache_dir) then
        return
        {
            guid = normalized_guid,
            path = cache_dir,
            removed = false,
        }
    end

    local ok_remove, err_remove = NativeIO.remove_directory(cache_dir, true)
    if not ok_remove then
        return nil, err_remove or "无法删除视频缓存目录"
    end

    return
    {
        guid = normalized_guid,
        path = cache_dir,
        removed = true,
    }
end

module.cleanup_orphan_cache = function()
    if not NativeIO.directory_exists(runtime_dir_root) then
        return
        {
            scanned_count = 0,
            removed_count = 0,
            removed_guid_list = {},
        }
    end

    local path_list, list_err = NativeIO.list_directory_array(runtime_dir_root, false, false)
    if not path_list then
        return nil, list_err or "无法扫描视频缓存目录"
    end

    local result =
    {
        scanned_count = 0,
        removed_count = 0,
        removed_guid_list = {},
    }

    for _, path in ipairs(path_list) do
        if NativeIO.directory_exists(path) then
            local guid = _normalize_guid_text(_basename(path))
            if guid then
                result.scanned_count = result.scanned_count + 1
                local meta = ResourceIndex.find_by_guid(guid)
                if not (meta and meta.type == "video") then
                    local cleanup_result, cleanup_err = module.cleanup_cache_for_guid(guid)
                    if not cleanup_result then
                        return nil, cleanup_err or string.format("无法清理孤立视频缓存：%s", guid)
                    end
                    if cleanup_result.removed then
                        result.removed_count = result.removed_count + 1
                        table.insert(result.removed_guid_list, guid)
                    end
                end
            end
        end
    end

    table.sort(result.removed_guid_list)
    return result
end

return module

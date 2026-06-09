local rl = Engine.Raylib

local SaveBoundaryDescriptor = require("application.framework.save_boundary_descriptor")
local SaveLocation = require("application.framework.save_location")
local GlobalContext = require("application.framework.global_context")
local NativeIO = require("application.framework.native_io")
local ScreenManager = require("application.framework.screen_manager")

local module = {}

local save_manager_module = false
local save_load_result_toast_module = false

local state =
{
    runtime_generation = 0,
    latest_anchor = nil,
    latest_slice = nil,
    latest_rejected_reason = nil,
    next_slice_revision = 1,
    last_written_slice_revision_by_location = {},
}

local source_label_pool =
{
    ui_action = "界面按钮",
    flow_node = "流程节点",
    debugger = "存档调试器",
    runtime = "运行时",
}

local function _get_save_manager()
    if save_manager_module == false then
        save_manager_module = require("application.framework.save_manager")
    end
    return save_manager_module
end

local function _get_save_load_result_toast()
    if save_load_result_toast_module == false then
        save_load_result_toast_module = require("application.framework.save_load_result_toast")
    end
    return save_load_result_toast_module
end

local function _notify_save_failed()
    pcall(function()
        local toast = _get_save_load_result_toast()
        if toast and toast.notify_save_failed then
            toast.notify_save_failed()
        end
    end)
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

local function _clone_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[_clone_value(key, seen)] = _clone_value(item, seen)
    end
    return copy
end

local function _normalize_source(value)
    local source = _trim(value) or "runtime"
    if source ~= "ui_action"
        and source ~= "flow_node"
        and source ~= "debugger"
        and source ~= "runtime"
    then
        return "runtime"
    end
    return source
end

local function _clone_options(options)
    local result = {}
    if type(options) == "table" then
        for key, value in pairs(options) do
            result[key] = value
        end
    end
    return result
end

local function _normalize_boundary(boundary, default_kind)
    local source = type(boundary) == "table" and boundary or {}
    return
    {
        kind = _trim(source.kind) or default_kind or "stable_boundary",
        label = _trim(source.label) or SaveBoundaryDescriptor.get_checkpoint_label(_trim(source.kind) or default_kind or "stable_boundary"),
        document_guid = _trim(source.document_guid),
        node_id = source.node_id,
        node_title = _trim(source.node_title),
    }
end

local function _apply_runtime_save_target(options)
    if type(options) ~= "table" or options.runtime_document ~= nil then
        return false
    end

    local stacked_target = GlobalContext.get_runtime_save_target_document
        and GlobalContext.get_runtime_save_target_document()
        or nil
    local target = stacked_target
    if target == nil then
        target = GlobalContext.get_runtime_save_anchor_document
            and GlobalContext.get_runtime_save_anchor_document()
            or nil
    end
    if target == nil or type(target.collect_runtime_save_state) ~= "function" then
        return false
    end

    options.runtime_document = target
    if stacked_target ~= nil and options.allow_active_managed_ui_sessions == nil then
        options.allow_active_managed_ui_sessions = true
    end
    return true
end

local function _make_slice_id(boundary, revision)
    return string.format(
        "runtime:%d:%s:%s",
        state.runtime_generation,
        tostring(boundary and boundary.kind or "slice"),
        tostring(revision or state.next_slice_revision))
end

local function _join_path(...)
    local result = nil
    for index = 1, select("#", ...) do
        local part = tostring(select(index, ...) or ""):gsub("\\", "/"):gsub("//+", "/")
        if part ~= "" then
            if result == nil or result == "" then
                result = part
            else
                result = string.format("%s/%s", result:gsub("/$", ""), part:gsub("^/+", ""))
            end
        end
    end
    return result
end

local function _is_texture_valid(texture)
    if not texture then
        return false
    end
    if rl.IsTextureValid then
        local ok_valid, is_valid = pcall(rl.IsTextureValid, texture)
        if not ok_valid or is_valid ~= true then
            return false
        end
    end
    return true
end

local function _unload_render_texture(target)
    if target and rl.UnloadRenderTexture then
        pcall(rl.UnloadRenderTexture, target)
    end
end

local function _export_image_png_utf8(image, path)
    if type(rl.ExportImageToMemoryBuffer) == "function" then
        local ok_buffer, buffer = pcall(rl.ExportImageToMemoryBuffer, image, ".png")
        if ok_buffer and buffer then
            local ok_data, data = pcall(function()
                return buffer:get()
            end)
            local ok_write = false
            if ok_data and type(data) == "string" then
                local ok_call, write_result = pcall(NativeIO.write_bytes, path, data)
                ok_write = ok_call and write_result == true
            end
            pcall(NativeIO.dispose_buffer, buffer)
            if ok_write then
                return true
            end
        end
        return false
    end

    local ok_export, export_result = pcall(rl.ExportImage, image, path)
    return ok_export and export_result == true
end

local function _render_thumbnail_texture_without_resource_ui(document)
    if not document or type(document.runtime_render) ~= "function" then
        return nil
    end
    if type(rl.LoadRenderTexture) ~= "function"
        or type(rl.BeginTextureMode) ~= "function"
        or type(rl.EndTextureMode) ~= "function"
    then
        return nil
    end

    local screen_width, screen_height = nil, nil
    if ScreenManager.get_size then
        screen_width, screen_height = ScreenManager.get_size()
    end
    local width = math.max(1, math.floor(tonumber(screen_width) or tonumber(GlobalContext.width_game_window) or 1920))
    local height = math.max(1, math.floor(tonumber(screen_height) or tonumber(GlobalContext.height_game_window) or 1080))
    local ok_target, target = pcall(rl.LoadRenderTexture, width, height)
    if not ok_target or not target then
        return nil
    end

    local did_begin = false
    local ok_render = xpcall(function()
        rl.BeginTextureMode(target)
        did_begin = true
        rl.ClearBackground(rl.Color(0, 0, 0, 255))
        document:runtime_render(
        {
            suppress_resource_ui = true,
        })
    end, debug.traceback)
    if did_begin then
        pcall(rl.EndTextureMode)
    end
    if ok_render ~= true or not target.texture or not _is_texture_valid(target.texture) then
        _unload_render_texture(target)
        return nil
    end

    return target
end

local function _capture_thumbnail_temp(revision, document)
    local thumbnail_target = _render_thumbnail_texture_without_resource_ui(document)
    local texture = thumbnail_target and thumbnail_target.texture or nil
    if not _is_texture_valid(texture) then
        _unload_render_texture(thumbnail_target)
        return nil
    end

    local ok_image, image = pcall(rl.LoadImageFromTexture, texture)
    _unload_render_texture(thumbnail_target)
    if not ok_image or not image then
        return nil
    end
    if rl.IsImageValid then
        local ok_valid_image, is_valid_image = pcall(rl.IsImageValid, image)
        if not ok_valid_image or is_valid_image ~= true then
            if rl.UnloadImage then
                pcall(rl.UnloadImage, image)
            end
            return nil
        end
    end

    -- RenderTexture snapshots are stored upside down relative to the player view.
    local ok_flip_v = rl.ImageFlipVertical and pcall(rl.ImageFlipVertical, image) or false
    if ok_flip_v ~= true then
        if rl.UnloadImage then
            pcall(rl.UnloadImage, image)
        end
        return nil
    end

    if image.format ~= rl.PixelFormat.UNCOMPRESSED_R8G8B8A8 then
        local ok_format = rl.ImageFormat and pcall(rl.ImageFormat, image, rl.PixelFormat.UNCOMPRESSED_R8G8B8A8) or false
        if ok_format ~= true then
            if rl.UnloadImage then
                pcall(rl.UnloadImage, image)
            end
            return nil
        end
    end

    local ok_resize = rl.ImageResize and pcall(rl.ImageResize, image, 480, 270) or false
    if ok_resize ~= true then
        if rl.UnloadImage then
            pcall(rl.UnloadImage, image)
        end
        return nil
    end

    local cache_dir = _join_path(GlobalContext.get_pref_path(), "save", "cache")
    local ok_dir = NativeIO.create_directories(cache_dir)
    if ok_dir ~= true then
        if rl.UnloadImage then
            pcall(rl.UnloadImage, image)
        end
        return nil
    end

    local generation = tonumber(state.runtime_generation) or 0
    local path = _join_path(cache_dir, string.format("slice_g%d_r%d_%d.png", generation, tonumber(revision) or 0, os.time()))
    local ok_export = _export_image_png_utf8(image, path)
    if rl.UnloadImage then
        pcall(rl.UnloadImage, image)
    end
    if ok_export == true then
        return path
    end
    return nil
end

local function _remove_temp_thumbnail(slice)
    local thumbnail = type(slice) == "table" and slice.thumbnail or nil
    local path = type(thumbnail) == "table" and thumbnail.temporary == true and _trim(thumbnail.path) or nil
    if path and NativeIO.file_exists(path) then
        pcall(NativeIO.remove_file, path)
    end
end

local function _location_key(location_or_id)
    local location = SaveLocation.normalize(location_or_id)
    return SaveLocation.semantic_id(location) or tostring(location_or_id or "")
end

function module.get_source_label(source)
    local normalized = _normalize_source(source)
    return source_label_pool[normalized] or source_label_pool.runtime
end

function module.reset_runtime_slices(reason)
    _remove_temp_thumbnail(state.latest_slice)
    state.runtime_generation = (tonumber(state.runtime_generation) or 0) + 1
    state.latest_anchor = nil
    state.latest_slice = nil
    state.latest_rejected_reason = _trim(reason)
    state.next_slice_revision = 1
    state.last_written_slice_revision_by_location = {}
    return state.runtime_generation
end

function module.commit_anchor(document, boundary, options)
    local anchor_boundary = _normalize_boundary(boundary, "node_exit")
    state.latest_anchor =
    {
        runtime_generation = state.runtime_generation,
        created_at = os.time(),
        source = _normalize_source(options and options.source or "flow_node"),
        boundary = anchor_boundary,
    }
    return _clone_value(state.latest_anchor)
end

function module.commit_full_slice(document, boundary, options)
    local slice_options = _clone_options(options)
    slice_options.source = _normalize_source(slice_options.source or "flow_node")
    if document ~= nil then
        slice_options.runtime_document = document
    else
        _apply_runtime_save_target(slice_options)
    end
    slice_options.require_stable = slice_options.require_stable ~= false

    local normalized_boundary = _normalize_boundary(boundary, "node_exit")
    local save_manager = _get_save_manager()
    local collected_state, err, diagnostics = save_manager.collect_runtime_slice_state(slice_options)
    if type(collected_state) ~= "table" then
        state.latest_rejected_reason = SaveBoundaryDescriptor.format_block_reason(err or "还没有可保存的运行切片")
        return nil, state.latest_rejected_reason
    end

    local revision = state.next_slice_revision
    state.next_slice_revision = revision + 1
    local thumbnail = _clone_value(slice_options.thumbnail or {})
    if thumbnail.path == nil and slice_options.capture_thumbnail ~= false then
        thumbnail.path = _capture_thumbnail_temp(revision, slice_options.runtime_document)
        if thumbnail.path then
            thumbnail.source = thumbnail.source or "runtime_boundary"
            thumbnail.width = thumbnail.width or 480
            thumbnail.height = thumbnail.height or 270
            thumbnail.temporary = true
        end
    end

    local slice =
    {
        slice_id = _make_slice_id(normalized_boundary, revision),
        runtime_generation = state.runtime_generation,
        slice_revision = revision,
        created_at = os.time(),
        source = slice_options.source,
        boundary = normalized_boundary,
        state = _clone_value(collected_state),
        thumbnail = thumbnail,
        diagnostics =
        {
            stale = false,
            full_slice_ok = true,
            rejected_reason = nil,
            collect = _clone_value(diagnostics or {}),
        },
    }

    _remove_temp_thumbnail(state.latest_slice)
    state.latest_slice = slice
    state.latest_rejected_reason = nil
    module.commit_anchor(slice_options.runtime_document, normalized_boundary, slice_options)
    return _clone_value(slice)
end

function module.get_latest_anchor()
    return _clone_value(state.latest_anchor)
end

function module.get_latest_slice()
    return _clone_value(state.latest_slice)
end

function module.get_save_availability(options)
    local query_options = _clone_options(options)
    query_options.source = _normalize_source(query_options.source)
    local slice = state.latest_slice
    if type(slice) ~= "table" then
        local reason = state.latest_rejected_reason or "还没有可保存的运行切片"
        return
        {
            available = false,
            status = "no_slice",
            source = query_options.source,
            source_label = module.get_source_label(query_options.source),
            reason = SaveBoundaryDescriptor.format_block_reason(reason),
            summary = SaveBoundaryDescriptor.format_block_reason(reason),
            latest_anchor = _clone_value(state.latest_anchor),
        }
    end
    if slice.runtime_generation ~= state.runtime_generation then
        local reason = "运行切片已失效，请等待流程进入新的稳定点"
        return
        {
            available = false,
            status = "stale_slice",
            source = query_options.source,
            source_label = module.get_source_label(query_options.source),
            reason = reason,
            summary = reason,
            latest_anchor = _clone_value(state.latest_anchor),
        }
    end

    local boundary = type(slice.boundary) == "table" and slice.boundary or {}
    local boundary_summary = boundary.label
        or SaveBoundaryDescriptor.get_checkpoint_label(boundary.kind)
        or "当前可保存最近稳定切片。"
    local summary = string.format("将保存到切片：%s", tostring(boundary_summary))
    if state.latest_rejected_reason then
        summary = string.format(
            "当前未形成新切片，将保存上一稳定切片：%s；原因：%s",
            tostring(boundary_summary),
            tostring(state.latest_rejected_reason))
    end
    return
    {
        available = true,
        status = "saveable",
        source = query_options.source,
        source_label = module.get_source_label(query_options.source),
        reason = state.latest_rejected_reason,
        summary = summary,
        boundary = _clone_value(boundary),
        slice_revision = slice.slice_revision,
        runtime_generation = slice.runtime_generation,
    }
end

function module.request_save(location, options)
    local save_options = _clone_options(options)
    save_options.source = _normalize_source(save_options.source)

    local availability = module.get_save_availability(save_options)
    if availability.available ~= true then
        local reason = availability.reason or "当前不能存档。"
        _notify_save_failed()
        return false, reason, availability
    end

    local slice = state.latest_slice
    if not slice or slice.runtime_generation ~= state.runtime_generation then
        local reason = "运行切片已失效，请等待流程进入新的稳定点"
        _notify_save_failed()
        return false, reason, availability
    end

    local save_manager = _get_save_manager()
    local actual_slot_id, err, manifest = save_manager.write_slice(location, slice, save_options)
    if actual_slot_id == false then
        local reason = SaveBoundaryDescriptor.format_block_reason(err)
        _notify_save_failed()
        return false, reason, availability
    end

    local location_key = _location_key(location or actual_slot_id)
    state.last_written_slice_revision_by_location[location_key] = slice.slice_revision
    pcall(function()
        local toast = _get_save_load_result_toast()
        if toast and toast.notify_saved then
            toast.notify_saved()
        end
    end)
    return actual_slot_id, nil, availability, manifest
end

function module.request_quick_save(options)
    local save_options = _clone_options(options)
    save_options.category = "manual"
    return module.request_save(nil, save_options)
end

function module.capture_thumbnail_for_slice(policy)
    return type(policy) == "table" and _clone_value(policy.thumbnail) or nil
end

function module.get_runtime_generation()
    return state.runtime_generation
end

return module

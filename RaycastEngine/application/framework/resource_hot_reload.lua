local rl = Engine.Raylib

local FlowManager = require("application.framework.flow_manager")
local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local NativeIO = require("application.framework.native_io")
local PlugLoader = require("application.framework.plug_loader")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local ResourceTaskRunner = require("application.framework.resource_task_runner")
local SettingsManager = require("application.framework.settings_manager")
local StyleManager = require("application.framework.style_manager")
local StyleWorkspaceManager = require("application.framework.style_workspace_manager")
local UIWorkspaceManager = require("application.framework.ui_workspace_manager")
local VideoImporter = require("application.framework.video_importer")

local module = {}

local watcher = nil
local pending_event_list = {}
local last_raw_event_ms = 0
local debounce_ms = 350
local meta_event_suppress_ms = 1800
local suppress_meta_events_until_ms = 0
local active_runner = nil
local plugin_root_path <const> = "plugins"

local function _sync_modal_state()
    GlobalContext.is_resource_modal_active = active_runner ~= nil
end

local runtime_type_pool =
{
    texture = true,
    audio = true,
    video = true,
    font = true,
    shader = true,
}

local function _normalize_path(path)
    if type(path) ~= "string" then
        return ""
    end
    path = path:gsub("\\", "/")
    path = path:gsub("//+", "/")
    return path
end

local function _current_working_directory()
    return _normalize_path(rl.GetWorkingDirectory and rl.GetWorkingDirectory() or "")
end

local function _is_absolute_path(path)
    local normalized = _normalize_path(path)
    return normalized:find("^/") ~= nil or normalized:find("^[A-Za-z]:/") ~= nil
end

local function _join_path(base, child)
    local left = _normalize_path(base):gsub("/+$", "")
    local right = _normalize_path(child):gsub("^/+", "")
    if left == "" then
        return right
    end
    if right == "" then
        return left
    end
    return left .. "/" .. right
end

local function _ends_with(text, suffix)
    return type(text) == "string"
        and type(suffix) == "string"
        and text:sub(-#suffix) == suffix
end

local function _is_meta_path(path)
    return _ends_with(path or "", ".meta")
end

local function _is_path_inside(path, root)
    local normalized_path = _normalize_path(path)
    local root_path = _normalize_path(root)
    if normalized_path == "" or root_path == "" then
        return false
    end
    local cwd = _current_working_directory()
    if not _is_absolute_path(normalized_path) and _is_absolute_path(root_path) and cwd ~= "" then
        normalized_path = _join_path(cwd, normalized_path)
    end
    if not _is_absolute_path(root_path) and _is_absolute_path(normalized_path) and cwd ~= "" then
        root_path = _join_path(cwd, root_path)
    end
    return normalized_path ~= ""
        and (normalized_path == root_path or normalized_path:sub(1, #root_path + 1) == root_path .. "/")
end

local function _is_path_inside_root(path)
    return _is_path_inside(path, ResourceIndex.get_root_path())
end

local function _is_path_inside_plugin_root(path)
    return _is_path_inside(path, plugin_root_path)
end

local function _clone_signature(signature)
    if type(signature) ~= "table" then
        return nil
    end
    return {size = signature.size, mtime = signature.mtime}
end

local function _clone_meta(meta)
    return
    {
        guid = meta.guid,
        type = meta.type,
        path = meta.path,
        relative_path = meta.relative_path,
        id = meta.id,
        display_name = meta.display_name,
        file_signature = _clone_signature(meta.file_signature),
    }
end

local function _collect_directory_paths(node, result)
    if not node then
        return
    end

    if type(node.relative_path) == "string" and node.relative_path ~= "" then
        result[node.relative_path] = true
    end

    for _, child in ipairs(node.children or {}) do
        _collect_directory_paths(child, result)
    end
end

local function _build_snapshot()
    local snapshot =
    {
        by_guid = {},
        directories_by_path = {},
    }

    for _, meta in ipairs(ResourceIndex.list_all()) do
        snapshot.by_guid[meta.guid] = _clone_meta(meta)
    end
    _collect_directory_paths(ResourceIndex.get_tree(), snapshot.directories_by_path)

    return snapshot
end

local function _signature_equal(left, right)
    if left == nil and right == nil then
        return true
    end
    if left == nil or right == nil then
        return false
    end
    return left.size == right.size and left.mtime == right.mtime
end

local function _meta_equal(left, right)
    if left == nil and right == nil then
        return true
    end
    if left == nil or right == nil then
        return false
    end

    return left.type == right.type
        and left.path == right.path
        and left.relative_path == right.relative_path
        and left.id == right.id
        and _signature_equal(left.file_signature, right.file_signature)
end

local function _build_diff(old_snapshot, new_snapshot)
    local diff =
    {
        changed_guid_pool = {},
        runtime_unload_list = {},
        runtime_reload_list = {},
        flow_related = false,
        style_related = false,
        ui_related = false,
        save_profile_related = false,
        directory_changed = false,
        icon_related = false,
    }

    local guid_pool = {}
    for guid in pairs(old_snapshot.by_guid or {}) do
        guid_pool[guid] = true
    end
    for guid in pairs(new_snapshot.by_guid or {}) do
        guid_pool[guid] = true
    end

    for guid in pairs(guid_pool) do
        local old_meta = old_snapshot.by_guid[guid]
        local new_meta = new_snapshot.by_guid[guid]
        if not _meta_equal(old_meta, new_meta) then
            diff.changed_guid_pool[guid] = true

            local old_type = old_meta and old_meta.type or nil
            local new_type = new_meta and new_meta.type or nil
            if old_type == "flow" or new_type == "flow" then
                diff.flow_related = true
            end
            if old_type == "style" or new_type == "style" then
                diff.style_related = true
            end
            if old_type == "ui" or new_type == "ui" then
                diff.ui_related = true
            end
            if old_type == "save_profile" or new_type == "save_profile" then
                diff.save_profile_related = true
            end
            if guid == SettingsManager.get_window_icon_guid() then
                diff.icon_related = true
            end

            if old_meta and runtime_type_pool[old_type] and not new_meta then
                table.insert(diff.runtime_unload_list, guid)
            end

            if new_meta and (runtime_type_pool[new_type] or runtime_type_pool[old_type]) then
                table.insert(diff.runtime_reload_list, guid)
            end
        end
    end

    table.sort(diff.runtime_unload_list)
    table.sort(diff.runtime_reload_list)

    local directory_pool = {}
    for path in pairs(old_snapshot.directories_by_path or {}) do
        directory_pool[path] = true
    end
    for path in pairs(new_snapshot.directories_by_path or {}) do
        directory_pool[path] = true
    end
    for path in pairs(directory_pool) do
        if not (old_snapshot.directories_by_path or {})[path]
            or not (new_snapshot.directories_by_path or {})[path] then
            diff.directory_changed = true
            break
        end
    end

    return diff
end

local function _has_diff_changes(diff)
    return type(diff) == "table"
        and (next(diff.changed_guid_pool or {}) ~= nil or diff.directory_changed == true)
end

local function _needs_video_transcode(meta, status)
    if not meta then
        return false
    end
    return VideoImporter.should_schedule_transcode(meta.guid, {status = status})
end

local function _cleanup_orphan_video_cache()
    local result, err = VideoImporter.cleanup_orphan_cache()
    if not result then
        LogManager.log(string.format("清理孤立视频缓存失败：%s", err or "未知错误"), "warning")
        return nil, err
    end
    if (result.removed_count or 0) > 0 then
        LogManager.log(string.format("已清理 %d 个孤立视频缓存目录", result.removed_count), "info")
    end
    return result
end

local function _is_internal_video_runtime_path(path)
    local normalized = _normalize_path(path)
    if type(normalized) ~= "string" or normalized == "" then
        return false
    end
    return normalized:find("/.cache/video/", 1, true) ~= nil
        or normalized:find("/library/video/", 1, true) ~= nil
        or normalized:find(".cache/video/", 1, true) == 1
        or normalized:find("library/video/", 1, true) == 1
end

local function _reset_pending_events()
    pending_event_list = {}
    last_raw_event_ms = 0
end

local function _event_is_resource_related(event)
    return event
        and (event.resource_related == true
            or _is_path_inside_root(event.path)
            or _is_path_inside_root(event.old_path))
end

local function _event_is_plugin_related(event)
    return event
        and (event.plugin_related == true
            or _is_path_inside_plugin_root(event.path)
            or _is_path_inside_plugin_root(event.old_path))
end

local function _event_list_has_resource_event(event_list)
    for _, event in ipairs(event_list or {}) do
        if _event_is_resource_related(event) then
            return true
        end
    end
    return false
end

local function _event_list_has_plugin_event(event_list)
    for _, event in ipairs(event_list or {}) do
        if _event_is_plugin_related(event) then
            return true
        end
    end
    return false
end

local function _has_only_meta_events(event_list)
    for _, event in ipairs(event_list or {}) do
        if _event_is_plugin_related(event) then
            return false
        end
        if not (_is_meta_path(event.path) and (_is_meta_path(event.old_path) or event.old_path == "")) then
            return false
        end
    end
    return #(event_list or {}) > 0
end

local function _sanitize_event(event)
    local path = _normalize_path(event.path or "")
    local old_path = _normalize_path(event.old_path or "")
    local resource_related = _is_path_inside_root(path) or _is_path_inside_root(old_path)
    local plugin_related = _is_path_inside_plugin_root(path) or _is_path_inside_plugin_root(old_path)
    if not resource_related and not plugin_related then
        return nil
    end
    if resource_related and (_is_internal_video_runtime_path(path) or _is_internal_video_runtime_path(old_path)) then
        return nil
    end

    local timestamp_ms = tonumber(event.timestamp_ms) or math.floor(rl.GetTime() * 1000)
    if resource_related and active_runner and (_is_meta_path(path) or _is_meta_path(old_path)) then
        return nil
    end
    if resource_related and timestamp_ms < suppress_meta_events_until_ms then
        if _is_meta_path(path) or _is_meta_path(old_path) then
            return nil
        end
    end

    return
    {
        action = event.action,
        path = path,
        old_path = old_path,
        timestamp_ms = timestamp_ms,
        resource_related = resource_related,
        plugin_related = plugin_related,
    }
end

local function _poll_raw_events()
    if not watcher then
        return
    end

    local raw_event_list = watcher:poll()
    local now_ms = math.floor(rl.GetTime() * 1000)
    for _, raw_event in ipairs(raw_event_list) do
        local event = _sanitize_event(raw_event)
        if event then
            table.insert(pending_event_list, event)
            last_raw_event_ms = now_ms
        end
    end
end

local function _build_runner(event_list)
    local shared =
    {
        resource_related = _event_list_has_resource_event(event_list),
        plugin_related = _event_list_has_plugin_event(event_list),
    }

    return ResourceTaskRunner.new(
    {
        title = "正在同步资源变更",
        popup_id = "resource_hot_reload_modal",
        frame_budget_ms = 6,
        present_before_start_frames = 2,
        present_before_start_seconds = 0.05,
        shared = shared,
        stages =
        {
            {
                name = "同步插件目录",
                build_tasks = function()
                    if not shared.plugin_related then
                        return {}
                    end
                    return
                    {
                        {
                            label = "重新扫描 plugins 插件包",
                            run = function()
                                shared.plugin_report = PlugLoader.reload_all(plugin_root_path)
                            end
                        }
                    }
                end
            },
            {
                name = "重新扫描资源目录",
                build_tasks = function()
                    if shared.resource_related == false then
                        return {}
                    end
                    return
                    {
                        {
                            label = "校验资源索引与 .meta 文件",
                            run = function()
                                shared.old_snapshot = _build_snapshot()
                                ResourceIndex.scan()
                                SettingsManager.resolve_resource_fields()
                                _cleanup_orphan_video_cache()
                                shared.new_snapshot = _build_snapshot()
                                shared.diff = _build_diff(shared.old_snapshot, shared.new_snapshot)
                            end
                        }
                    }
                end,
                tasks =
                {
                }
            },
            {
                name = "刷新视频导入状态",
                build_tasks = function()
                    local tasks = {}
                    local diff = shared.diff or {}
                    for guid in pairs(diff.changed_guid_pool or {}) do
                        local meta = ResourceIndex.find_by_guid(guid)
                        if meta and meta.type == "video" then
                            table.insert(tasks,
                            {
                                label = string.format("校验视频导入：%s", meta.relative_path),
                                run = function()
                                    local status, err = VideoImporter.refresh_guid(guid,
                                    {
                                        allow_transcode = false,
                                    })
                                    if not status then
                                        LogManager.log(string.format("视频资源导入校验失败：%s\n%s", meta.relative_path, err or "未知错误"), "warning")
                                    end
                                end
                            })
                        end
                    end
                    return tasks
                end
            },
            {
                name = "转码不兼容视频",
                build_tasks = function()
                    local tasks = {}
                    local diff = shared.diff or {}
                    for guid in pairs(diff.changed_guid_pool or {}) do
                        local meta = ResourceIndex.find_by_guid(guid)
                        local status = meta and meta.type == "video" and VideoImporter.get_status(guid) or nil
                        if meta and _needs_video_transcode(meta, status) then
                            local task = VideoImporter.create_transcode_task(guid,
                            {
                                on_error = function(task_meta, err)
                                    LogManager.log(string.format("视频资源自动转码失败：%s\n%s", task_meta.relative_path, err or "未知错误"), "warning")
                                end
                            })
                            if task then
                                table.insert(tasks, task)
                            end
                        end
                    end
                    return tasks
                end
            },
            {
                name = "刷新运行时资源",
                build_tasks = function()
                    local tasks = {}
                    local diff = shared.diff or {}

                    for _, guid in ipairs(diff.runtime_unload_list or {}) do
                        local old_meta = shared.old_snapshot and shared.old_snapshot.by_guid[guid] or nil
                        table.insert(tasks,
                        {
                            label = string.format("卸载资源：%s", old_meta and old_meta.relative_path or guid),
                            run = function()
                                ResourcesManager.unload_asset_by_guid(guid)
                            end
                        })
                    end

                    for _, guid in ipairs(diff.runtime_reload_list or {}) do
                        local meta = ResourceIndex.find_by_guid(guid)
                        local label = meta and meta.relative_path or guid
                        table.insert(tasks,
                        {
                            label = string.format("重载资源：%s", label),
                            run = function()
                                local ok, err = ResourcesManager.try_reload_asset_by_guid(guid)
                                if not ok then
                                    LogManager.log(string.format("资源热重载失败，已保留旧资源：%s\n%s", label, err or "未知错误"), "warning")
                                end
                            end
                        })
                    end

                    return tasks
                end
            },
            {
                name = "同步流程脚本",
                build_tasks = function()
                    if not (shared.diff and shared.diff.flow_related) then
                        return {}
                    end

                    return
                    {
                        {
                            label = "更新流程文档索引与外部修改状态",
                            run = function()
                                FlowManager.reconcile()
                                FlowManager.mark_dependent_text_documents_dirty(shared.diff and shared.diff.changed_guid_pool or nil)
                            end
                        }
                    }
                end
            },
            {
                name = "同步样式文档",
                build_tasks = function()
                    if not (shared.diff and shared.diff.style_related) then
                        return {}
                    end

                    return
                    {
                        {
                            label = "更新样式文档索引与活动样式缓存",
                            run = function()
                                StyleWorkspaceManager.reconcile()
                                for guid in pairs(shared.diff.changed_guid_pool or {}) do
                                    local old_meta = shared.old_snapshot and shared.old_snapshot.by_guid[guid] or nil
                                    local new_meta = shared.new_snapshot and shared.new_snapshot.by_guid[guid] or nil
                                    if (old_meta and old_meta.type == "style") or (new_meta and new_meta.type == "style") then
                                        StyleManager.invalidate_by_guid(guid)
                                    end
                                end
                            end
                        }
                    }
                end
            },
            {
                name = "同步界面文档",
                build_tasks = function()
                    if not (shared.diff and shared.diff.ui_related) then
                        return {}
                    end

                    return
                    {
                        {
                            label = "更新界面文档索引与外部修改状态",
                            run = function()
                                UIWorkspaceManager.reconcile()
                            end
                        }
                    }
                end
            },
            {
                name = "刷新编辑器视图",
                build_tasks = function()
                    if not _has_diff_changes(shared.diff) then
                        return {}
                    end

                    return
                    {
                        {
                            label = "更新资产视图与窗口资源引用",
                            run = function()
                                GlobalContext.resource_index_revision = GlobalContext.resource_index_revision + 1
                                if shared.diff and shared.diff.icon_related and GlobalContext.refresh_window_icon then
                                    GlobalContext.refresh_window_icon()
                                end
                            end
                        }
                    }
                end
            },
        }
    })
end

local function _refresh_now_core(options)
    options = options or {}

    local old_snapshot = _build_snapshot()
    ResourceIndex.scan()
    SettingsManager.resolve_resource_fields()
    _cleanup_orphan_video_cache()
    local new_snapshot = _build_snapshot()
    local diff = _build_diff(old_snapshot, new_snapshot)

    for guid in pairs(diff.changed_guid_pool or {}) do
        local meta = ResourceIndex.find_by_guid(guid)
        if meta and meta.type == "video" then
            local status, err = VideoImporter.refresh_guid(guid,
            {
                allow_transcode = false,
            })
            if not status then
                LogManager.log(string.format("视频资源导入校验失败：%s\n%s", meta.relative_path, err or "未知错误"), "warning")
            end
        end
    end

    for _, guid in ipairs(diff.runtime_unload_list or {}) do
        ResourcesManager.unload_asset_by_guid(guid)
    end

    for _, guid in ipairs(diff.runtime_reload_list or {}) do
        local meta = ResourceIndex.find_by_guid(guid)
        local label = meta and meta.relative_path or guid
        local ok, err = ResourcesManager.try_reload_asset_by_guid(guid)
        if not ok then
            LogManager.log(string.format("资源热重载失败，已保留旧资源：%s\n%s", label, err or "未知错误"), "warning")
        end
    end

    if diff.flow_related then
        FlowManager.reconcile()
        FlowManager.mark_dependent_text_documents_dirty(diff.changed_guid_pool or nil)
    end

    if diff.style_related then
        StyleWorkspaceManager.reconcile()
        for guid in pairs(diff.changed_guid_pool or {}) do
            local old_meta = old_snapshot and old_snapshot.by_guid[guid] or nil
            local new_meta = new_snapshot and new_snapshot.by_guid[guid] or nil
            if (old_meta and old_meta.type == "style") or (new_meta and new_meta.type == "style") then
                StyleManager.invalidate_by_guid(guid)
            end
        end
    end

    if diff.ui_related then
        UIWorkspaceManager.reconcile()
    end

    if _has_diff_changes(diff) or options.force_editor_refresh == true then
        GlobalContext.resource_index_revision = GlobalContext.resource_index_revision + 1
        if diff.icon_related and GlobalContext.refresh_window_icon then
            GlobalContext.refresh_window_icon()
        end
    end

    local plugin_report = nil
    if options.reload_plugins == true or options.force_plugin_reload == true then
        plugin_report = PlugLoader.reload_all(plugin_root_path)
    end

    return
    {
        old_snapshot = old_snapshot,
        new_snapshot = new_snapshot,
        diff = diff,
        plugin_report = plugin_report,
    }
end

module.start = function()
    if SettingsManager.get("release_mode") then
        return true
    end

    if watcher and watcher.valid then
        return true
    end

    watcher = Engine.FileWatcher.Watcher()
    local watch_id = watcher:add_watch(ResourceIndex.get_root_path(), true)
    if not watch_id or watch_id < 0 then
        LogManager.log(string.format("启动资源目录监听失败：%s", watcher.last_error or "未知错误"), "error")
        watcher:dispose()
        watcher = nil
        return false
    end
    if NativeIO.directory_exists(plugin_root_path) then
        local plugin_watch_id = watcher:add_watch(plugin_root_path, true)
        if not plugin_watch_id or plugin_watch_id < 0 then
            LogManager.log(string.format("启动插件目录监听失败：%s", watcher.last_error or "未知错误"), "warning")
        end
    end
    if not watcher:start() then
        LogManager.log(string.format("启动资源目录监听失败：%s", watcher.last_error or "未知错误"), "error")
        watcher:dispose()
        watcher = nil
        return false
    end

    _reset_pending_events()
    active_runner = nil
    _sync_modal_state()
    return true
end

module.stop = function()
    active_runner = nil
    _sync_modal_state()
    _reset_pending_events()
    if watcher then
        watcher:dispose()
        watcher = nil
    end
end

module.refresh_now = function(options)
    local result = _refresh_now_core(options)
    local now_ms = math.floor(rl.GetTime() * 1000)
    suppress_meta_events_until_ms = now_ms + math.max(debounce_ms, meta_event_suppress_ms)
    _reset_pending_events()
    return result
end

module.update = function(delta)
    _poll_raw_events()

    if active_runner then
        _sync_modal_state()
        active_runner:update(delta)
        return
    end

    _sync_modal_state()

    if #pending_event_list == 0 then
        return
    end

    local now_ms = math.floor(rl.GetTime() * 1000)
    if now_ms - last_raw_event_ms < debounce_ms then
        return
    end

    if _has_only_meta_events(pending_event_list) then
        _reset_pending_events()
        return
    end

    active_runner = _build_runner(pending_event_list)
    _sync_modal_state()
    active_runner:update(delta)
    suppress_meta_events_until_ms = now_ms + math.max(debounce_ms, meta_event_suppress_ms)
    _reset_pending_events()
end

module.draw_modal = function()
    if not active_runner then
        _sync_modal_state()
        return
    end

    active_runner:draw_modal()
    if active_runner.error_message and active_runner:is_dismissed() then
        LogManager.log(string.format("资源热重载任务异常终止：%s", active_runner.error_message), "error")
        active_runner = nil
        _sync_modal_state()
        return
    end
    if active_runner.is_finished and not active_runner.error_message and active_runner:is_closed() then
        active_runner = nil
        _sync_modal_state()
    end
end

module.has_active_runner = function()
    return active_runner ~= nil
end

return module

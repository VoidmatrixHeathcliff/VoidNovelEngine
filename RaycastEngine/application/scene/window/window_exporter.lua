local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util
local imgui = Engine.ImGUI
local json = Engine.JSON

local LogManager = require("application.framework.log_manager")
local ImGUIHelper = require("application.framework.imgui_helper")
local ColorHelper = require("application.framework.color_helper")
local EditorThemeManager = require("application.framework.editor_theme_manager")
local FlowManager = require("application.framework.flow_manager")
local GlobalContext = require("application.framework.global_context")
local ResourceIndex = require("application.framework.resource_index")
local ResourceReferenceField = require("application.framework.resource_reference_field")
local SettingsManager = require("application.framework.settings_manager")
local StyleWorkspaceManager = require("application.framework.style_workspace_manager")
local UIWorkspaceManager = require("application.framework.ui_workspace_manager")
local ResourcesManager = require("application.framework.resources_manager")
local VideoImporter = require("application.framework.video_importer")
local NativeIO = require("application.framework.native_io")

local str_window_title = util.CString()

local idx_platform = 1
local platform_list = {}

local cstr_window_title = util.CString()
local is_default_fullscreen = imgui.Bool()
local is_single_file = imgui.Bool()
local cstr_developer = util.CString()
local cstr_file_description = util.CString()
local cstr_release_version = util.CString()
local export_text_input_active = {}
local export_text_input_focus_pending = {}
local export_text_input_was_active = {}

local reset_folder = function(path)
    if NativeIO.directory_exists(path) then
        local ok, err = NativeIO.remove_directory(path, true)
        if not ok then
            error(string.format("无法清理目录：%s\n%s", path, err or "未知错误"))
        end
    end
    local ok, err = NativeIO.create_directories(path)
    if not ok then
        error(string.format("无法创建目录：%s\n%s", path, err or "未知错误"))
    end
end

local function _ensure_ok(ok, err, action)
    if ok then
        return
    end
    error(string.format("%s失败\n%s", action, err or "未知错误"))
end

local function _run_process_checked(exe_path, args, action, cwd)
    local result = NativeIO.run_process_capture(exe_path, args, cwd)
    if result.success then
        return result
    end

    local detail = result.stderr
    if not detail or #detail == 0 then
        detail = result.stdout
    end
    if not detail or #detail == 0 then
        detail = result.message
    end
    error(string.format("%s失败\n%s", action, detail or "未知错误"))
end

local function _remove_file_if_exists(path)
    if path and NativeIO.file_exists(path) then
        local ok, err = NativeIO.remove_file(path)
        if ok ~= true then
            return false, err
        end
    end
    return true
end

local function _restore_backup_file(path, backup_path)
    local ok, err = _remove_file_if_exists(path)
    if ok ~= true then
        return false, err
    end

    if backup_path and NativeIO.file_exists(backup_path) then
        return NativeIO.rename(backup_path, path)
    end
    return true
end

local function _replace_file_with_backup(path, temp_path, backup_path)
    local ok, err = _remove_file_if_exists(backup_path)
    if ok ~= true then
        return false, err
    end

    if NativeIO.file_exists(path) then
        ok, err = NativeIO.rename(path, backup_path)
        if ok ~= true then
            return false, err
        end
    end

    ok, err = NativeIO.rename(temp_path, path)
    if ok ~= true then
        local restore_ok, restore_err = _restore_backup_file(path, backup_path)
        if restore_ok ~= true then
            return false, string.format("%s；恢复备份失败：%s", err or "替换文件失败", restore_err or "未知错误")
        end
        return false, err
    end

    ok, err = _remove_file_if_exists(backup_path)
    if ok ~= true then
        return false, err
    end
    return true
end

local function _compile_lua_script(luac_path, path)
    local temp_path = string.format("%s.luac.tmp", path)
    local backup_path = string.format("%s.bak", path)
    local ok, err = _remove_file_if_exists(temp_path)
    _ensure_ok(ok, err, string.format("清理临时脚本：%s", temp_path))

    _run_process_checked(luac_path, {"-o", temp_path, path}, string.format("编译脚本：%s", path))
    ok, err = _replace_file_with_backup(path, temp_path, backup_path)
    if ok ~= true then
        _remove_file_if_exists(temp_path)
        error(string.format("替换编译脚本失败：%s\n%s", path, err or "未知错误"))
    end
end

local function _resolve_powershell_path()
    local candidate_list =
    {
        "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        "C:\\Windows\\SysWOW64\\WindowsPowerShell\\v1.0\\powershell.exe",
    }

    for _, path in ipairs(candidate_list) do
        if NativeIO.file_exists(path) then
            return path
        end
    end

    return "PowerShell.exe"
end

local function _normalize_slashes(path)
    if type(path) ~= "string" then
        return nil
    end

    local value = path:gsub("\\", "/")
    value = value:gsub("//+", "/")
    value = value:gsub("^%./", "")
    if #value > 1 then
        value = value:gsub("/$", "")
    end
    return value
end

local function _build_export_path(root_path, relative_path)
    local normalized_relative_path = _normalize_slashes(relative_path)
    if not normalized_relative_path then
        return root_path
    end
    return root_path .. "\\" .. normalized_relative_path:gsub("/", "\\")
end

local function _ensure_parent_directory(path)
    local directory = type(path) == "string" and path:match("^(.*)[/\\][^/\\]+$") or nil
    if not directory or directory == "" then
        return true
    end
    return NativeIO.create_directories(directory)
end

local function _resolve_flow_guid_with_meta(value)
    local guid = ResourceIndex.resolve_guid("flow", value)
    if not guid then
        return nil
    end
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta or meta.type ~= "flow" then
        return nil
    end
    return guid, meta
end

local function _describe_flow_meta(meta, fallback)
    if type(meta) == "table" then
        return meta.relative_path or meta.path or meta.id or meta.guid or fallback or "未知流程"
    end
    return fallback or "未知流程"
end

local function _resolve_release_entry_flow_guid()
    local configured_entry = SettingsManager.get_entry_flow_guid()
    local configured_guid, configured_meta = _resolve_flow_guid_with_meta(configured_entry)
    if configured_guid then
        return configured_guid, nil
    end
    if type(configured_entry) == "string" and configured_entry ~= "" then
        return nil, string.format("发布入口流程无效：%s", configured_entry)
    end

    local fallback_candidate_list =
    {
        {label = "当前流程", value = SettingsManager.get_current_flow_guid()},
        {label = "当前图形流程", value = SettingsManager.get_current_graph_flow_guid and SettingsManager.get_current_graph_flow_guid() or ""},
        {label = "当前文本剧本", value = SettingsManager.get_current_text_flow_guid and SettingsManager.get_current_text_flow_guid() or ""},
    }
    for _, candidate in ipairs(fallback_candidate_list) do
        local guid, meta = _resolve_flow_guid_with_meta(candidate.value)
        if guid then
            return guid, string.format("发布入口流程未设置，已使用%s作为入口：%s",
                candidate.label,
                _describe_flow_meta(meta, guid))
        end
    end

    for _, guid_candidate in ipairs(SettingsManager.get_open_flow_guid_list and SettingsManager.get_open_flow_guid_list() or {}) do
        local guid, meta = _resolve_flow_guid_with_meta(guid_candidate)
        if guid then
            return guid, string.format("发布入口流程未设置，已使用已打开流程作为入口：%s",
                _describe_flow_meta(meta, guid))
        end
    end

    return nil, "发布入口流程未设置，请在发布设置中选择入口流程"
end

local function _starts_with(text, prefix)
    return type(text) == "string"
        and type(prefix) == "string"
        and text:sub(1, #prefix) == prefix
end

local function _collect_release_definition_manifest(copy_root)
    local normalized_root = _normalize_slashes(copy_root)
    local manifest =
    {
        version = 1,
        node_paths = {},
        pin_paths = {},
    }

    local collect_path_pairs =
    {
        {folder = copy_root .. "\\application\\pin", list = manifest.pin_paths},
        {folder = copy_root .. "\\application\\node", list = manifest.node_paths},
    }

    for _, pair in ipairs(collect_path_pairs) do
        local path_list, list_err = NativeIO.list_directory_array(pair.folder, true, true)
        if not path_list then
            return nil, list_err or string.format("无法扫描定义目录：%s", pair.folder)
        end

        for _, path in ipairs(path_list) do
            if string.lower(rl.GetFileExtension(path)) == ".lua" then
                local file_name = rl.GetFileName(path)
                if file_name ~= "" and file_name:sub(1, 1) ~= "_" then
                    local normalized_path = _normalize_slashes(path)
                    if normalized_path and normalized_root and _starts_with(normalized_path, normalized_root .. "/") then
                        table.insert(pair.list, normalized_path:sub(#normalized_root + 2))
                    end
                end
            end
        end

        table.sort(pair.list)
    end

    return manifest
end

local function _collect_release_plugin_manifest(copy_root)
    local plugins_root = copy_root .. "\\plugins"
    if not NativeIO.directory_exists(plugins_root) then
        return {version = 1, package_paths = {}}
    end

    local path_list, list_err = NativeIO.list_directory_array(plugins_root, false, false)
    if not path_list then
        return nil, list_err or string.format("无法扫描插件目录：%s", plugins_root)
    end

    local normalized_root = _normalize_slashes(copy_root)
    local manifest =
    {
        version = 1,
        package_paths = {},
    }

    table.sort(path_list)
    for _, path in ipairs(path_list) do
        if NativeIO.directory_exists(path) and NativeIO.file_exists(path .. "\\manifest.json") then
            local normalized_path = _normalize_slashes(path)
            if normalized_path and normalized_root and _starts_with(normalized_path, normalized_root .. "/") then
                table.insert(manifest.package_paths, normalized_path:sub(#normalized_root + 2))
            end
        end
    end

    return manifest
end

local function _rewrite_release_video_meta(meta, copy_dst_folder, runtime_relative_path)
    if not meta or meta.type ~= "video" then
        return true
    end

    local normalized_runtime_relative_path = _normalize_slashes(runtime_relative_path)
    if not normalized_runtime_relative_path then
        return true
    end

    local copied_meta_path = _build_export_path(copy_dst_folder, meta.meta_path)
    local content, read_err = NativeIO.read_text(copied_meta_path)
    if not content then
        return nil, read_err or string.format("无法读取导出视频元数据：%s", copied_meta_path)
    end

    local ok_parse, meta_data = json.ParseToLua(content)
    if not ok_parse or type(meta_data) ~= "table" then
        return nil, string.format("无法解析导出视频元数据：%s", copied_meta_path)
    end

    meta_data.importer = type(meta_data.importer) == "table" and meta_data.importer or {}
    local status = type(meta_data.importer.video) == "table" and meta_data.importer.video or {}
    status.runtime_entry = {mode = "artifact", path = normalized_runtime_relative_path}
    status.classification = "needs_transcode"
    status.compatibility = {wmf_runtime_ready = true, reason = ""}
    status.last_error = ""
    status.transcode_artifact = type(status.transcode_artifact) == "table" and status.transcode_artifact or {}
    status.transcode_artifact.path = normalized_runtime_relative_path
    status.transcode_artifact.exists = true
    meta_data.importer.video = status

    local ok_write, write_err = NativeIO.write_text(copied_meta_path, json.PrintFromLua(meta_data))
    if not ok_write then
        return nil, write_err or string.format("无法写回导出视频元数据：%s", copied_meta_path)
    end

    return true
end

local function _remove_exported_video_source(meta, copy_dst_folder)
    if not meta or meta.type ~= "video" then
        return true
    end

    local source_path = _build_export_path(copy_dst_folder, meta.path)
    if type(source_path) ~= "string" or source_path == "" or not NativeIO.file_exists(source_path) then
        return true
    end

    return NativeIO.remove_file(source_path)
end

local function _get_document_display_name(document)
    if type(document) ~= "table" then
        return "未知文档"
    end
    return document._display_name
        or document._resource_id
        or document._path
        or document._id
        or "未知文档"
end

local function _should_save_document(document)
    if type(document) ~= "table" or type(document.save_document) ~= "function" then
        return false
    end
    if document._is_open and document._is_open.val == true then
        return true
    end
    return document.is_modified and document:is_modified() == true
end

local function _save_document_for_export(document)
    local ok, result, err = xpcall(function()
        return document:save_document()
    end, debug.traceback)
    if not ok then
        return false, result or "保存文档时发生未知异常"
    end
    if result ~= true then
        return false, err or "请先手动保存该文档并检查日志"
    end
    return true
end

local function _save_document_list_for_export(label, document_list)
    for _, document in ipairs(document_list or {}) do
        if _should_save_document(document) then
            local ok, err = _save_document_for_export(document)
            if ok ~= true then
                error(string.format("发布前保存%s失败：%s\n%s",
                    tostring(label or "文档"),
                    _get_document_display_name(document),
                    err or "请先手动保存该文档并检查日志"))
            end
        end
    end
end

local function _save_workspace_documents_for_export()
    _save_document_list_for_export("流程", FlowManager.get_all_documents and FlowManager.get_all_documents() or {})
    _save_document_list_for_export("样式", StyleWorkspaceManager.get_all_documents and StyleWorkspaceManager.get_all_documents() or {})
    _save_document_list_for_export("界面", UIWorkspaceManager.get_all_documents and UIWorkspaceManager.get_all_documents() or {})
end

local function _get_style_vec_x(style, field_name, fallback)
    local value = style and style[field_name] or nil
    if value and type(value.x) == "number" then
        return value.x
    end
    return fallback or 0
end

local function _draw_export_text_input(id, cstring, setting_key)
    local width = math.max(1, imgui.GetContentRegionAvail().x)
    local input_id = string.format("##%s", id)

    if export_text_input_active[id] == true then
        imgui.SetNextItemWidth(width)
        if export_text_input_focus_pending[id] == true then
            imgui.SetKeyboardFocusHere()
            export_text_input_focus_pending[id] = false
        end
        imgui.InputText(input_id, cstring)

        local item_active = imgui.IsItemActive()
            or (imgui.IsItemFocused and imgui.IsItemFocused() == true)
        if imgui.IsItemDeactivatedAfterEdit() then
            SettingsManager.set(setting_key, cstring:get())
        end
        if export_text_input_was_active[id] == true and not item_active then
            export_text_input_active[id] = false
        end
        export_text_input_was_active[id] = item_active
        return
    end

    export_text_input_was_active[id] = false
    local full_text = tostring(cstring:get() or "")
    local style = imgui.GetStyle()
    local text_width = math.max(32, width - math.max(20, _get_style_vec_x(style, "FramePadding", 4) * 2 + 4))
    local display_text = ImGUIHelper.EllipsisHead(full_text, text_width)
    local button_label = string.format("%s##%s_display", display_text ~= "" and display_text or " ", id)
    local input_frame_palette = EditorThemeManager.get_input_frame_palette()

    imgui.PushStyleColor(imgui.ImGuiCol.Button, input_frame_palette.frame)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, input_frame_palette.hovered)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, input_frame_palette.active)
    if imgui.Button(button_label, imgui.ImVec2(width, 0)) then
        export_text_input_active[id] = true
        export_text_input_focus_pending[id] = true
    end
    imgui.PopStyleColor(3)
    ImGUIHelper.HoveredTooltip(full_text)
end

local on_update_windows = function()
    imgui.SeparatorText("运行")
    imgui.Columns(2, "运行")

    imgui.Text("入口流程")
    ImGUIHelper.HoveredTooltip("游戏启动时自动加载并执行的流程脚本文档")
    imgui.NextColumn()
    local entry_flow_ref, entry_flow_changed = ResourceReferenceField.draw(
    {
        popup_id = "export_entry_flow_picker",
        asset_type = "flow",
        value = SettingsManager.get_entry_flow_guid(),
        width = imgui.GetContentRegionAvail().x,
        allow_clear = false,
    })
    if entry_flow_changed then
        SettingsManager.set_entry_flow_guid(entry_flow_ref and entry_flow_ref.guid or "")
    end
    imgui.NextColumn()

    imgui.Columns(1)

    imgui.SeparatorText("窗口")
    imgui.Columns(2, "窗口")

    imgui.Text("标题")
    imgui.NextColumn()
    _draw_export_text_input("标题", cstr_window_title, "title")
    imgui.NextColumn()

    imgui.Text("图标")
    ImGUIHelper.HoveredTooltip("游戏程序和窗口图标资源")
    imgui.NextColumn()
    local icon_ref, icon_changed = ResourceReferenceField.draw(
    {
        popup_id = "export_window_icon_picker",
        asset_type = "texture",
        value = SettingsManager.get_window_icon_guid(),
        width = imgui.GetContentRegionAvail().x,
        allow_clear = false,
    })
    if icon_changed then
        SettingsManager.set_window_icon_guid(icon_ref and icon_ref.guid or "")
        if GlobalContext.refresh_window_icon then
            GlobalContext.refresh_window_icon()
        end
    end
    imgui.NextColumn()

    imgui.Text("默认全屏")
    ImGUIHelper.HoveredTooltip("游戏启动后窗口默认占据玩家整个屏幕大小")
    imgui.NextColumn()
    if imgui.Checkbox("##默认全屏", is_default_fullscreen) then
        SettingsManager.set("default_fullscreen", is_default_fullscreen.val)
    end
    imgui.NextColumn()

    imgui.Columns(1)

    imgui.SeparatorText("文件")
    imgui.Columns(2, "文件")
    
    imgui.Text("单文件")
    ImGUIHelper.HoveredTooltip("游戏程序仅包含单个可执行文件，需要更长时间来执行发布流程")
    imgui.NextColumn()
    if imgui.Checkbox("##单文件", is_single_file) then
        SettingsManager.set("single_file", is_single_file.val)
    end
    imgui.NextColumn()

    imgui.Text("开发者")
    imgui.NextColumn()
    _draw_export_text_input("开发者", cstr_developer, "developer")
    imgui.NextColumn()

    imgui.Text("文件描述")
    imgui.NextColumn()
    _draw_export_text_input("文件描述", cstr_file_description, "file_description")
    imgui.NextColumn()

    imgui.Text("发布版本")
    imgui.NextColumn()
    _draw_export_text_input("发布版本", cstr_release_version, "release_version")
    imgui.NextColumn()

    imgui.Columns(1)
end

local on_export_windows = function()
    local cleanup_file_path_list = {}
    local cleanup_directory_path_list = {}

    local function _queue_cleanup_file(path)
        if type(path) == "string" and path ~= "" then
            table.insert(cleanup_file_path_list, path)
        end
    end

    local function _queue_cleanup_directory(path)
        if type(path) == "string" and path ~= "" then
            table.insert(cleanup_directory_path_list, path)
        end
    end

    local ok, err = pcall(function()
        LogManager.log("正在执行Windows平台游戏发布流程...", "info")
        LogManager.log("正在保存已打开的工程文档...", "info")
        _save_workspace_documents_for_export()

        local release_entry_flow_guid, release_entry_flow_notice = _resolve_release_entry_flow_guid()
        if not release_entry_flow_guid then
            error(release_entry_flow_notice or "发布入口流程未设置")
        end
        if release_entry_flow_notice then
            LogManager.log(release_entry_flow_notice, "warning")
        end

        LogManager.log("正在构建发布目录...", "info")

        local target_folder <const> = "release\\Windows"
        reset_folder(target_folder)

        local copy_dst_folder = target_folder
        if SettingsManager.get("single_file") then
            copy_dst_folder = target_folder .. "\\.temp"
            _queue_cleanup_directory(copy_dst_folder)
            local ok_create, err_create = NativeIO.create_directories(copy_dst_folder)
            _ensure_ok(ok_create, err_create, "创建临时发布目录")
        end

        local essential_folder_list =
        {
            "application\\extension",
            "application\\framework",
            "application\\icon",
            "application\\node",
            "application\\pin",
            "application\\resources",
            "application\\scene",
        }
        local optional_folder_list =
        {
            "plugins",
        }
        local essential_file_list =
        {
            "application\\application.lua",
            "main.lua",
        }
        local exe_file_name = rl.GetFileName(util.GetExeFilePath())
        table.insert(essential_file_list, exe_file_name)

        local video_meta_list = ResourceIndex.list_by_type("video")
        if #video_meta_list > 0 then
            LogManager.log("正在校验视频资源导入状态...", "info")
            local ok_video, err_video = VideoImporter.ensure_export_ready(video_meta_list,
            {
                allow_transcode = true,
            })
            if not ok_video then
                error(string.format("视频资源导出校验失败\n%s", err_video or "未知错误"))
            end
        end

        for _, folder in ipairs(essential_folder_list) do
            local ok_copy_dir, err_copy_dir = NativeIO.copy_directory(folder, copy_dst_folder .. "\\" .. folder)
            _ensure_ok(ok_copy_dir, err_copy_dir, string.format("复制目录：%s", folder))
        end
        for _, folder in ipairs(optional_folder_list) do
            if NativeIO.directory_exists(folder) then
                local ok_copy_dir, err_copy_dir = NativeIO.copy_directory(folder, copy_dst_folder .. "\\" .. folder)
                _ensure_ok(ok_copy_dir, err_copy_dir, string.format("复制可选目录：%s", folder))
            end
        end
        for _, file in ipairs(essential_file_list) do
            local ok_copy_file, err_copy_file = NativeIO.copy_file(file, copy_dst_folder .. "\\" .. file, true)
            _ensure_ok(ok_copy_file, err_copy_file, string.format("复制文件：%s", file))
        end

        for _, meta in ipairs(video_meta_list) do
            local status = VideoImporter.get_status(meta.guid)
            local runtime_entry = status and status.runtime_entry or nil
            if runtime_entry and runtime_entry.mode == "artifact" and runtime_entry.path and runtime_entry.path ~= "" then
                local export_runtime_path = _build_export_path(copy_dst_folder, runtime_entry.path)
                local ok_ensure_runtime_dir, err_ensure_runtime_dir = _ensure_parent_directory(export_runtime_path)
                _ensure_ok(ok_ensure_runtime_dir, err_ensure_runtime_dir, string.format("创建导出视频目录：%s", meta.relative_path))
                local ok_copy_video, err_copy_video = NativeIO.copy_file(runtime_entry.path, export_runtime_path, true)
                _ensure_ok(ok_copy_video, err_copy_video, string.format("复制导出视频产物：%s", meta.relative_path))
                local ok_rewrite_video_meta, rewrite_video_meta_err = _rewrite_release_video_meta(meta, copy_dst_folder, runtime_entry.path)
                _ensure_ok(ok_rewrite_video_meta, rewrite_video_meta_err, string.format("修正导出视频元数据：%s", meta.relative_path))
                local ok_remove_source, remove_source_err = _remove_exported_video_source(meta, copy_dst_folder)
                _ensure_ok(ok_remove_source, remove_source_err, string.format("删除导出源视频：%s", meta.relative_path))
            end
        end

        local definition_manifest, definition_manifest_err = _collect_release_definition_manifest(copy_dst_folder)
        _ensure_ok(definition_manifest ~= nil, definition_manifest_err, "生成定义清单")
        local definition_manifest_path = copy_dst_folder .. "\\application\\definition_manifest.json"
        local ok_write_manifest, err_write_manifest = NativeIO.write_text(definition_manifest_path, json.PrintFromLua(definition_manifest))
        _ensure_ok(ok_write_manifest, err_write_manifest, "写入定义清单")

        local plugin_manifest, plugin_manifest_err = _collect_release_plugin_manifest(copy_dst_folder)
        _ensure_ok(plugin_manifest ~= nil, plugin_manifest_err, "生成插件清单")
        local plugin_manifest_path = copy_dst_folder .. "\\application\\plugin_manifest.json"
        local ok_write_plugin_manifest, err_write_plugin_manifest = NativeIO.write_text(plugin_manifest_path, json.PrintFromLua(plugin_manifest))
        _ensure_ok(ok_write_plugin_manifest, err_write_plugin_manifest, "写入插件清单")

        LogManager.log("正在编译脚本...", "info")
        local script_path_list, list_err = NativeIO.list_directory_array(copy_dst_folder, true, true)
        if not script_path_list then
            error(string.format("无法扫描发布目录中的脚本文件\n%s", list_err or "未知错误"))
        end
        local luac_path <const> = "application\\external\\luac54.exe"
        for _, path in ipairs(script_path_list) do
            if string.lower(rl.GetFileExtension(path)) == ".lua" then
                _compile_lua_script(luac_path, path)
            end
        end

        local copy_data = SettingsManager.copy()
        copy_data.release_mode = true
        copy_data.single_file = SettingsManager.get("single_file") == true
        copy_data.entry_flow_guid = release_entry_flow_guid
        if copy_data.single_file then
            LogManager.log("单文件发布将按默认策略使用用户数据目录保存运行时存档", "info")
        end
        if not SettingsManager.save(copy_dst_folder .. "\\project.vne", copy_data) then
            error("写入发布版项目配置失败")
        end

        LogManager.log("正在生成文件元信息...", "info")
        local target_exe_file_name = "VoidNovelEngineGame.exe"
        local target_exe_path = copy_dst_folder .. "\\" .. target_exe_file_name
        local icon_file_path = target_folder .. "\\" .. "icon.ico"
        local ok_rename, err_rename = NativeIO.rename(copy_dst_folder .. "\\" .. exe_file_name, target_exe_path)
        _ensure_ok(ok_rename, err_rename, "重命名主程序")

        _run_process_checked("application\\external\\ImageMagick\\magick.exe",
            {SettingsManager.get_window_icon_path(), "-define", "icon:auto-resize=256,128,64,48,32,16", icon_file_path},
            "生成程序图标")

        _run_process_checked("application\\external\\rcedit.exe",
            {target_exe_path, "--set-icon", icon_file_path, "--set-version-string", "CompanyName", SettingsManager.get("developer")},
            "写入程序开发者信息")
        _run_process_checked("application\\external\\rcedit.exe",
            {target_exe_path, "--set-version-string", "FileDescription", SettingsManager.get("file_description")},
            "写入程序文件描述")
        _run_process_checked("application\\external\\rcedit.exe",
            {target_exe_path, "--set-file-version", SettingsManager.get("release_version")},
            "写入程序版本号")
        local ok_remove_icon, err_remove_icon = NativeIO.remove_file(icon_file_path)
        _ensure_ok(ok_remove_icon, err_remove_icon, "删除临时图标")

        if SettingsManager.get("single_file") then
            LogManager.log("正在打包为单文件...", "info")
            local base_path = sdl.GetBasePath()
            local enigma_path <const> = base_path .. "application\\external\\EnigmaVirtualBox\\enigmavbconsole.exe"
            local source_dir = base_path .. copy_dst_folder
            local output_file = base_path .. target_folder .. "\\" .. target_exe_file_name
            local evb_project_file = base_path .. target_folder .. "\\" .. "temp.evb"
            local ps_file_path <const> = base_path .. target_folder .. "\\" .. "temp_pack.ps1"
            _queue_cleanup_file(evb_project_file)
            _queue_cleanup_file(ps_file_path)
            local evb_gen_template = require("application.framework.evb_gen_template")
            local ps_content = string.format(
            [[
$EnigmaPath = "%s"
$SourceDir  = "%s"
$MainExeName = "%s"
$OutputFile = "%s"
$EvbProjectFile = "%s"
%s
            ]], enigma_path, source_dir, target_exe_file_name, output_file, evb_project_file, evb_gen_template)

            local ok_write_ps, err_write_ps = NativeIO.write_bytes(ps_file_path, "\239\187\191" .. ps_content)
            _ensure_ok(ok_write_ps, err_write_ps, "写入打包脚本")
            _run_process_checked(_resolve_powershell_path(),
                {"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps_file_path},
                "执行单文件打包脚本",
                base_path)
        end

        LogManager.log("已完成Windows平台游戏发布", "success")
    end)

    if #cleanup_file_path_list > 0 or #cleanup_directory_path_list > 0 then
        LogManager.log("正在清理临时文件...", "info")
    end
    for _, path in ipairs(cleanup_file_path_list) do
        if NativeIO.file_exists(path) then
            local ok_remove, err_remove = NativeIO.remove_file(path)
            if not ok_remove then
                LogManager.log(string.format("清理临时文件失败：%s\n%s", path, err_remove or "未知错误"), "warning")
            end
        end
    end
    for _, path in ipairs(cleanup_directory_path_list) do
        if NativeIO.directory_exists(path) then
            local ok_remove, err_remove = NativeIO.remove_directory(path, true)
            if not ok_remove then
                LogManager.log(string.format("清理临时目录失败：%s\n%s", path, err_remove or "未知错误"), "warning")
            end
        end
    end

    if not ok then
        LogManager.log(tostring(err), "error")
    end
end

local on_update_unsupported_platform = function()
    imgui.TextDisabled("* 当前版本暂不支持发布到该平台")
end

module.on_enter = function()
    platform_list = {}
    table.insert(platform_list, {icon = "windows-fill", name = "Windows", on_update = on_update_windows, on_export = on_export_windows})
    table.insert(platform_list, {icon = "android-fill", name = "Android", on_update = on_update_unsupported_platform})
    table.insert(platform_list, {icon = "apple-fill", name = "macOS", on_update = on_update_unsupported_platform})
    table.insert(platform_list, {icon = "ubuntu-fill", name = "Linux", on_update = on_update_unsupported_platform})
    table.insert(platform_list, {icon = "html5-fill", name = "Web", on_update = on_update_unsupported_platform})
    cstr_window_title:set(SettingsManager.get("title"))
    is_default_fullscreen.val = SettingsManager.get("default_fullscreen")
    is_single_file.val = SettingsManager.get("single_file")
    cstr_developer:set(SettingsManager.get("developer"))
    cstr_file_description:set(SettingsManager.get("file_description"))
    cstr_release_version:set(SettingsManager.get("release_version"))
    export_text_input_active = {}
    export_text_input_focus_pending = {}
    export_text_input_was_active = {}
end

local function _get_image_button_total_width(icon_width)
    local style = imgui.GetStyle()
    return icon_width + _get_style_vec_x(style, "FramePadding", 0) * 2
end

module.on_update = function(self, delta)
    local is_open = imgui.Begin("发布设置")
    if is_open then
        local size_icon = imgui.ImVec2(imgui.GetTextLineHeight(), imgui.GetTextLineHeight())
        local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio")
        local style = imgui.GetStyle()
        local export_icon_width = 18 * editor_zoom_ratio
        local export_button_width = _get_image_button_total_width(export_icon_width)
        local export_button_reserve = export_button_width + _get_style_vec_x(style, "ItemSpacing", 8)

        imgui.Text("发布平台：")
        imgui.SameLine()
        local available_after_label = imgui.GetContentRegionAvail().x
        local keep_export_button_same_line = available_after_label >= 150 + export_button_reserve
        local combo_width = keep_export_button_same_line
            and math.max(150, available_after_label - export_button_reserve)
            or math.max(80, available_after_label)
        imgui.SetNextItemWidth(combo_width)
        if imgui.BeginCombo("##发布平台", platform_list[idx_platform].name) then
            for idx, platform in ipairs(platform_list) do
                local pos = imgui.GetCursorPos()
                if imgui.Selectable("##"..idx, idx == idx_platform, imgui.SelectableFlags.SpanAllColumns) then
                    idx_platform = idx
                end
                imgui.SetCursorPos(pos)
                imgui.Image(ResourcesManager.find_icon(platform.icon), size_icon, nil, nil, EditorThemeManager.get_icon_tint_color(), nil)
                imgui.SameLine()
                imgui.Text(platform.name)
            end
            imgui.EndCombo()
        end
        if keep_export_button_same_line then
            imgui.SameLine()
        end
        local current_platform = platform_list[idx_platform]
        imgui.BeginDisabled(not current_platform.on_export)
        if imgui.ImageButton("export", ResourcesManager.find_icon("upload-2-fill"), 
            imgui.ImVec2(export_icon_width, export_icon_width), nil, nil, nil, EditorThemeManager.get_icon_tint_color()) then
            current_platform.on_export()
        end
        imgui.EndDisabled()
        ImGUIHelper.HoveredTooltip("发布到当前平台")
        imgui.BeginChild("发布设置内容", nil, imgui.ChildFlags.Borders)
            current_platform.on_update()
        imgui.EndChild()
    end
    imgui.End()
end

return module

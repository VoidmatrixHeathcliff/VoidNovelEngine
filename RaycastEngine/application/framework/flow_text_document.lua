local util = Engine.Util
local imgui = Engine.ImGUI
local rl = Engine.Raylib

local Class = require("application.framework.class")
local FlowTextCompiler = require("application.framework.flow_text_compiler")
local FlowTextDiagnostics = require("application.framework.flow_text_diagnostics")
local FlowTextExecutionBridge = require("application.framework.flow_text_execution_bridge")
local FlowTextRuntime = require("application.framework.flow_text_runtime")
local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local ModifyManager = require("application.framework.modify_manager")
local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")
local Scene = require("application.framework.scene")
local StyleManager = require("application.framework.style_manager")

local FlowTextDocument = Class.define("FlowTextDocument")
local compile_idle_delay_seconds = 0.20

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

local function _clone_signature(signature)
    if type(signature) ~= "table" then
        return nil
    end
    return {size = signature.size, mtime = signature.mtime}
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

local function _text_anchor_equal(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    if tostring(left.path or "") ~= tostring(right.path or "") then
        return false
    end
    if tonumber(left.line) ~= tonumber(right.line) then
        return false
    end
    if tonumber(left.column) ~= tonumber(right.column) then
        return false
    end
    if tostring(left.label or "") ~= tostring(right.label or "") then
        return false
    end
    return true
end

local function _find_instruction_source(program, pc)
    local instruction = program and program.instructions and program.instructions[pc] or nil
    return instruction and instruction.source or nil
end

local function _get_document_name(self)
    return self._resource_id or self._path or self._id
end

local function _describe_runtime_style()
    local active_guid = StyleManager.get_active_style_guid()
    if type(active_guid) ~= "string" or active_guid == "" then
        return nil
    end

    local active_reference = StyleManager.get_active_style_reference()
    local display_path = ResourceIndex.get_display_path("style", active_reference or active_guid)
    if display_path == "" then
        display_path = active_guid
    end
    return display_path, active_guid
end

local function _log_runtime_style_state()
    local display_path, active_guid = _describe_runtime_style()
    if display_path then
        LogManager.log(string.format("文本剧本启动时的运行时样式：%s（%s）", display_path, active_guid), "info")
        return
    end

    LogManager.log("文本剧本启动时尚未激活运行时样式；若脚本稍后执行 @set_style，会在执行到该节点后生效。", "info")
end

local function _get_file_signature(path)
    local size = util.GetFileSizeUtf8(path)
    local mtime = util.GetFileModifiedTimeUtf8(path)
    if not size or not mtime then
        return nil
    end
    return
    {
        size = size,
        mtime = mtime,
    }
end

local function _ensure_parent_directory(path)
    local directory = type(path) == "string" and path:match("^(.*)[/\\][^/\\]+$") or nil
    if directory and directory ~= "" then
        NativeIO.create_directories(directory)
    end
end

local function _touch_document(self)
    self._document_last_used_time = rl.GetTime()
end

local function _should_log_document_lifecycle(self)
    return not (self and self._is_temporary_runtime_document == true)
end

local function _destroy_ui_states(self)
    for _, state in pairs(self._ui_state_pool or {}) do
        if state and state.handle and imgui.TextEditor and imgui.TextEditor.Destroy then
            imgui.TextEditor.Destroy(state.handle)
            state.handle = nil
        end
    end
    self._ui_state_pool = {}
end

local function _is_document_loaded(self)
    return self._document_loaded == true
end

local function _update_resource_meta(self, resource_source)
    local path = resource_source
    local meta = nil
    if type(resource_source) == "table" then
        meta = resource_source
        path = meta.path
    end

    self._path = path
    self._resource_guid = meta and meta.guid or self._resource_guid
    self._resource_id = meta and meta.id or self._resource_id
    self._display_name = meta and meta.display_name or (path and path:match("([^/\\]+)%.vns$") or path)
    self._resource_file_signature = meta and _clone_signature(meta.file_signature) or self._resource_file_signature
    self._resource_missing = meta == nil and self._resource_missing or false
    self._id = self._display_name or self._path
    self._tab_label = string.format("%s##%s", self._display_name or self._id, self._resource_guid or self._path or self._id)
end

local function _set_modify_flag(self, is_modified)
    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    ModifyManager.set_modify(is_modified == true)
    ModifyManager.set_context(previous_context)
end

local function _refresh_modify_flag(self)
    if self._has_saved_snapshot ~= true then
        _set_modify_flag(self, true)
        return true
    end

    local is_modified = tostring(self._source_text or "") ~= tostring(self._saved_source_text or "")
    _set_modify_flag(self, is_modified)
    return is_modified
end

local function _apply_source_text(self, text, options)
    self._source_text = tostring(text or "")
    self._source_revision = (self._source_revision or 0) + 1
    self._compile_dirty = true
    self._compile_dirty_since = rl.GetTime()
    if options and options.compile_immediately then
        self:compile_document({force = true})
    end
end

function FlowTextDocument:ctor(resource_source, options)
    options = options or {}
    local path = type(resource_source) == "table" and resource_source.path or resource_source
    self.kind = "text"
    self._id = path and path:match("([^/\\]+)%.vns$") or path
    self._path = path
    self._resource_guid = nil
    self._resource_id = nil
    self._display_name = nil
    self._tab_label = nil
    self._resource_file_signature = nil
    self._resource_missing = false
    self._external_change_pending = false
    self._document_loaded = false
    self._document_last_used_time = 0
    self._source_text = ""
    self._saved_source_text = nil
    self._source_revision = 0
    self._has_saved_snapshot = false
    self._compiled_program = nil
    self._compiled_revision = 0
    self._diagnostics = {}
    self._outline_items = {}
    self._compile_dirty = true
    self._compile_dirty_since = 0
    self._last_successful_program = nil
    self._last_successful_revision = 0
    self._dependencies = {}
    self._runtime = nil
    self._scene_context = nil
    self._is_disposed = false
    self._is_open = imgui.Bool(options.initial_open == true)
    self._modify_context = ModifyManager.create_context(not NativeIO.file_exists(path))
    self._pending_navigation = nil
    self._manager = options.manager
    self._ui_state_pool = {}
    self._editor_assist_cache = {}
    _update_resource_meta(self, resource_source)

    if not options.lazy_document then
        self:ensure_document_loaded()
    end
end

function FlowTextDocument:compile_document(options)
    options = options or {}
    if not _is_document_loaded(self) then
        return false
    end

    if self._compile_dirty and not options.force then
        local dirty_since = tonumber(self._compile_dirty_since) or 0
        if dirty_since > 0 and (rl.GetTime() - dirty_since) < compile_idle_delay_seconds then
            return false
        end
    end

    local program = FlowTextCompiler.compile_document(self)
    self._compiled_program = program
    self._compiled_revision = (self._compiled_revision or 0) + 1
    self._diagnostics = program.diagnostics or {}
    self._outline_items = program.outline_items or {}
    self._dependencies = program.dependencies or {}
    self._compile_dirty = false
    self._compile_dirty_since = 0
    if not FlowTextDiagnostics.has_errors(self._diagnostics) then
        self._last_successful_program = program
        self._last_successful_revision = self._source_revision
    end
    return not FlowTextDiagnostics.has_errors(self._diagnostics)
end

function FlowTextDocument:update_compile_state()
    if not _is_document_loaded(self) or not self._compile_dirty then
        return false
    end
    return self:compile_document()
end

function FlowTextDocument:ensure_document_loaded()
    if _is_document_loaded(self) then
        _touch_document(self)
        return true
    end

    if not self._path or not NativeIO.file_exists(self._path) then
        self._document_loaded = true
        self._resource_missing = false
        self._external_change_pending = false
        self._source_text = ""
        self._saved_source_text = nil
        self._has_saved_snapshot = false
        self._compile_dirty = true
        self._compile_dirty_since = rl.GetTime()
        self:compile_document({force = true})
        _touch_document(self)
        return true
    end

    local text, err = NativeIO.read_text(self._path)
    if not text then
        if _should_log_document_lifecycle(self) then
            LogManager.log(string.format("加载文本剧本文档失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        end
        return false
    end

    self._document_loaded = true
    self._resource_missing = false
    self._external_change_pending = false
    self._source_text = text
    self._saved_source_text = text
    self._has_saved_snapshot = true
    self._compile_dirty = true
    self._compile_dirty_since = rl.GetTime()
    self:compile_document({force = true})
    _set_modify_flag(self, false)
    _touch_document(self)
    return true
end

function FlowTextDocument:is_document_loaded()
    return _is_document_loaded(self)
end

function FlowTextDocument:unload_document()
    if not _is_document_loaded(self) then
        return false
    end
    self:reset_runtime_state()
    self._document_loaded = false
    self._source_text = ""
    self._compiled_program = nil
    self._diagnostics = {}
    self._outline_items = {}
    self._compile_dirty = true
    self._compile_dirty_since = 0
    self._dependencies = {}
    self._editor_assist_cache = {}
    _destroy_ui_states(self)
    return true
end

function FlowTextDocument:is_modified()
    if not _is_document_loaded(self) then
        return false
    end
    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    local modified = ModifyManager.is_modify()
    ModifyManager.set_context(previous_context)
    return modified
end

function FlowTextDocument:get_source_text()
    return self._source_text or ""
end

function FlowTextDocument:set_source_text(text, options)
    if not self:ensure_document_loaded() then
        return false
    end
    if tostring(text or "") == self._source_text then
        return false
    end
    _apply_source_text(self, text, options)
    if options and options.mark_modified == false then
        _set_modify_flag(self, false)
    else
        _refresh_modify_flag(self)
    end
    return true
end

function FlowTextDocument:get_diagnostics()
    return self._diagnostics or {}
end

function FlowTextDocument:get_outline_items()
    return self._outline_items or {}
end

function FlowTextDocument:get_dependencies()
    return self._dependencies or {}
end

function FlowTextDocument:get_compiled_program()
    return self._compiled_program
end

function FlowTextDocument:get_editor_assist_cache()
    self._editor_assist_cache = self._editor_assist_cache or {}
    return self._editor_assist_cache
end

function FlowTextDocument:depends_on(guid)
    local target_guid = tostring(guid or "")
    if target_guid == "" then
        return false
    end

    for _, dependency_guid in ipairs(self._dependencies or {}) do
        if dependency_guid == target_guid then
            return true
        end
    end
    return false
end

function FlowTextDocument:mark_dependency_changed(guid)
    if not self:depends_on(guid) then
        return false
    end

    self._compile_dirty = true
    self._compile_dirty_since = rl.GetTime()
    if _is_document_loaded(self) then
        LogManager.log(string.format("文本剧本依赖已更新，将在空闲时重新编译：%s", _get_document_name(self)), "info")
    end
    return true
end

function FlowTextDocument:get_ui_state(key)
    local state_key = _trim(key) or tostring(key)
    self._ui_state_pool[state_key] = self._ui_state_pool[state_key] or {}
    return self._ui_state_pool[state_key]
end

function FlowTextDocument:request_navigate_to_line(line, column)
    self._pending_navigation =
    {
        line = tonumber(line) or 1,
        column = tonumber(column) or 1,
    }
end

function FlowTextDocument:consume_pending_navigation()
    local value = self._pending_navigation
    self._pending_navigation = nil
    return value
end

function FlowTextDocument:save_document()
    if not self:ensure_document_loaded() then
        return false
    end

    if self._compile_dirty then
        self:compile_document({force = true})
    end

    _ensure_parent_directory(self._path)
    local ok, err = NativeIO.write_text(self._path, self._source_text or "")
    if not ok then
        LogManager.log(string.format("文本流程文件保存失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        return false
    end

    self._resource_file_signature = _get_file_signature(self._path)
    self._resource_missing = false
    self._external_change_pending = false
    self._saved_source_text = self._source_text or ""
    self._has_saved_snapshot = true
    _set_modify_flag(self, false)
    LogManager.log(string.format("文本流程文件已保存：%s", _get_document_name(self)), "success")
    return true
end

function FlowTextDocument:reload_from_disk(options)
    local reload_options = type(options) == "table" and options or {}
    if not self._path or not NativeIO.file_exists(self._path) then
        return false
    end

    local text, err = NativeIO.read_text(self._path)
    if not text then
        if _should_log_document_lifecycle(self) then
            LogManager.log(string.format("重新加载文本剧本文档失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        end
        return false
    end

    self._document_loaded = true
    self._source_text = text
    self._saved_source_text = text
    self._has_saved_snapshot = true
    self._compile_dirty = true
    self._compile_dirty_since = rl.GetTime()
    self:compile_document({force = true})
    self._resource_missing = false
    self._external_change_pending = false
    self._resource_file_signature = _get_file_signature(self._path)
    _set_modify_flag(self, false)

    if reload_options.silent ~= true and _should_log_document_lifecycle(self) then
        LogManager.log(string.format("已重新加载文本剧本文档：%s", _get_document_name(self)), "success")
    end
    return true
end

function FlowTextDocument:update_resource_meta(resource_source)
    _update_resource_meta(self, resource_source)
end

function FlowTextDocument:mark_external_change(meta)
    if self._resource_missing then
        return
    end
    if meta and meta.file_signature then
        self._resource_file_signature = _clone_signature(meta.file_signature)
    end
    self._external_change_pending = true
    if _should_log_document_lifecycle(self) then
        LogManager.log(string.format("检测到文本剧本文档发生外部修改：%s", _get_document_name(self)), "warning")
    end
end

function FlowTextDocument:mark_resource_missing()
    if self._resource_missing then
        return
    end
    self._resource_missing = true
    self._external_change_pending = false
    if _should_log_document_lifecycle(self) then
        LogManager.log(string.format("文本剧本文档已从磁盘移除：%s", _get_document_name(self)), "warning")
    end
end

function FlowTextDocument:clear_resource_missing()
    self._resource_missing = false
end

function FlowTextDocument:execute()
    if not self:ensure_document_loaded() then
        LogManager.log(string.format("无法执行文本剧本，文档加载失败：%s", _get_document_name(self)), "error")
        GlobalContext.stop_debug()
        return
    end

    if self._compile_dirty then
        self:compile_document({force = true})
    end

    local program = self._compiled_program
    if not program or FlowTextDiagnostics.has_errors(self._diagnostics) then
        LogManager.log(string.format("无法执行文本剧本，当前存在编译错误：%s", _get_document_name(self)), "error")
        GlobalContext.stop_debug()
        return
    end

    self:reset_runtime_state()
    self._scene_context = Scene.new()
    self._runtime = FlowTextRuntime.new(self, program, self._scene_context)
    _touch_document(self)
    _log_runtime_style_state()
    LogManager.log(string.format("开始执行文本剧本：%s", _get_document_name(self)), "info")
end

function FlowTextDocument:runtime_update(delta)
    if self._runtime then
        self._runtime:update(delta)
    end
end

function FlowTextDocument:runtime_render(options)
    if self._scene_context then
        self._scene_context:on_render(options)
    end
end

function FlowTextDocument:get_runtime_scene_context()
    return self._scene_context
end

function FlowTextDocument:can_save_now()
    if not self._runtime then
        return false, "当前文本流程尚未启动"
    end
    return self._runtime:can_save_now()
end

function FlowTextDocument:collect_runtime_save_state()
    if not self._runtime then
        return nil
    end

    local ok, reason = self._runtime:can_save_now()
    if ok ~= true then
        return nil, reason
    end
    return self._runtime:collect_save_state()
end

function FlowTextDocument:resolve_runtime_local_references()
    if self._runtime and self._runtime.resolve_runtime_local_references then
        self._runtime:resolve_runtime_local_references()
    end
end

function FlowTextDocument:validate_runtime_save_state(runtime_state)
    if type(runtime_state) ~= "table" then
        return false, "无效的文本运行时快照"
    end

    if not self:ensure_document_loaded() then
        return false, "无法加载文本剧本文档"
    end

    if self._compile_dirty then
        self:compile_document({force = true})
    end

    local program = self._compiled_program
    if not program or FlowTextDiagnostics.has_errors(self._diagnostics) then
        return false, "当前文本剧本文档存在编译错误"
    end

    local pc = tonumber(runtime_state.pc) or tonumber(program.entry_index) or 1
    local instruction = program.instructions[pc]
    local saved_anchor = type(runtime_state.current_source_anchor) == "table" and runtime_state.current_source_anchor or nil
    local instruction_source = _find_instruction_source(program, pc)
    if saved_anchor and not _text_anchor_equal(saved_anchor, instruction_source) then
        return false, "存档对应的剧本位置已被更改或删除，无法恢复"
    end

    local pending_resume = type(runtime_state.pending_resume) == "table" and runtime_state.pending_resume or nil
    if pending_resume then
        if not instruction then
            return false, "存档对应的文本执行位置已不存在"
        end
        local route = type(pending_resume.route) == "table" and pending_resume.route or nil
        if route and route.kind == "label" and route.target and not (program.labels and program.labels[route.target]) then
            return false, string.format("存档对应的文本恢复标签已不存在：#%s", tostring(route.target))
        end
        return true
    end

    local active_bridge_state = type(runtime_state.active_bridge) == "table" and runtime_state.active_bridge or nil
    if active_bridge_state and active_bridge_state.resume_mode == "reexecute" then
        if not instruction then
            return false, "无法定位待恢复的文本命令"
        end
        if instruction.kind ~= "invoke" then
            return false, "存档对应的文本命令已发生变化，无法恢复"
        end
        return true
    end

    if not instruction then
        return false, "存档对应的文本执行位置已不存在"
    end

    return true
end

function FlowTextDocument:restore_runtime_save_state(runtime_state)
    local valid, validation_err = self:validate_runtime_save_state(runtime_state)
    if valid ~= true then
        return false, validation_err
    end

    local program = self._compiled_program
    self:reset_runtime_state()
    self._scene_context = Scene.new()
    self._runtime = FlowTextRuntime.new(self, program, self._scene_context)
    self._runtime._pc = tonumber(runtime_state.pc) or tonumber(program.entry_index) or 1
    self._runtime._locals = _clone_value(runtime_state.locals or {})
    self._runtime._current_source_anchor = _clone_value(runtime_state.current_source_anchor)

    if type(runtime_state.pending_resume) == "table" then
        self._runtime._pending_resume_action = _clone_value(runtime_state.pending_resume)
        return true
    end

    local active_bridge_state = type(runtime_state.active_bridge) == "table" and runtime_state.active_bridge or nil
    if active_bridge_state and active_bridge_state.resume_mode == "reexecute" then
        local instruction = program.instructions[self._runtime._pc]
        if not instruction then
            return false, "无法定位待恢复的文本命令"
        end

        local bridge, err = FlowTextExecutionBridge.invoke(self, instruction, self._scene_context, self._runtime)
        if not bridge then
            self:reset_runtime_state()
            return false, err or "无法恢复文本命令"
        end
        self._runtime._active_bridge = bridge
        if bridge._node and bridge._node.on_runtime_apply_state then
            bridge._node:on_runtime_apply_state(self._scene_context,
            {
                runtime = self._runtime,
                bridge = bridge,
            }, _clone_value(active_bridge_state.state or {}))
        end
    end

    return true
end

function FlowTextDocument:reset_runtime_state()
    if self._scene_context and self._scene_context.destroy then
        self._scene_context:destroy()
    end
    self._scene_context = nil
    self._runtime = nil
end

function FlowTextDocument:finish_runtime()
    if GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() == self then
        LogManager.log("调试结束", "success")
        GlobalContext.stop_debug()
        return
    end
    self:reset_runtime_state()
end

function FlowTextDocument:get_current_source_anchor()
    return self._runtime and self._runtime:get_current_source_anchor() or nil
end

function FlowTextDocument:runtime_find_node(id)
    return self._runtime and self._runtime:runtime_find_node(id) or nil
end

function FlowTextDocument:runtime_find_pin(id)
    return self._runtime and self._runtime:runtime_find_pin(id) or nil
end

function FlowTextDocument:dispose()
    if self._is_disposed then
        return
    end
    self._is_disposed = true
    self:reset_runtime_state()
    self._editor_assist_cache = {}
    _destroy_ui_states(self)
    if GlobalContext.current_flow_document == self then
        GlobalContext.current_flow_document = nil
    end
    if GlobalContext.debug_flow_document == self then
        GlobalContext.debug_flow_document = nil
    end
    if GlobalContext.runtime_save_anchor_document == self then
        GlobalContext.runtime_save_anchor_document = nil
    end
end

FlowTextDocument.__gc = FlowTextDocument.dispose

return FlowTextDocument

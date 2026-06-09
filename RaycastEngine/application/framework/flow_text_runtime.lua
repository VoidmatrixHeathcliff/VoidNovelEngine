local Class = require("application.framework.class")
local FlowTextExecutionBridge = require("application.framework.flow_text_execution_bridge")
local FlowRuntimeError = require("application.framework.flow_runtime_error")
local GameObject = require("application.framework.game_object")
local GlobalContext = require("application.framework.global_context")
local RuntimeInputState = require("application.framework.runtime_input_state")

local module = {}
local FlowTextRuntime = {}
FlowTextRuntime.__index = FlowTextRuntime
local runtime_flow_control_module = false
local runtime_ref_marker = "__flow_text_runtime_ref"

local function _get_runtime_flow_control()
    if runtime_flow_control_module == false then
        runtime_flow_control_module = require("application.framework.runtime_flow_control")
    end
    return runtime_flow_control_module
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

local function _make_runtime_object_ref(value)
    if type(value) ~= "table" then
        return nil
    end

    local object_id = rawget(value, "_id")
    local is_game_object = false
    local class_ok, class_result = pcall(Class.is_instance, value, GameObject)
    if class_ok then
        is_game_object = class_result == true
    end
    if is_game_object and type(object_id) == "string" and object_id ~= "" then
        return
        {
            [runtime_ref_marker] = true,
            kind = "scene_object",
            id = object_id,
        }
    end

    local instance_id = rawget(value, "id")
    if type(instance_id) == "string" and instance_id ~= "" and rawget(value, "widget_by_id") ~= nil then
        return
        {
            [runtime_ref_marker] = true,
            kind = "ui_instance",
            id = instance_id,
        }
    end

    return nil
end

local function _is_runtime_object_ref(value)
    return type(value) == "table" and value[runtime_ref_marker] == true
end

local function _clone_runtime_local_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    local ref = _make_runtime_object_ref(value)
    if ref then
        return ref
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[_clone_runtime_local_value(key, seen)] = _clone_runtime_local_value(item, seen)
    end
    return copy
end

local function _clone_runtime_locals(locals)
    local source = type(locals) == "table" and locals or {}
    local copy = {}
    local seen = {[source] = copy}
    for key, item in pairs(source) do
        copy[_clone_runtime_local_value(key, seen)] = _clone_runtime_local_value(item, seen)
    end
    return copy
end

local function _resolve_runtime_ref(runtime, value)
    if not _is_runtime_object_ref(value) then
        return value
    end

    local scene_context = runtime and runtime._scene_context or nil
    local ref_id = tostring(value.id or "")
    if ref_id == "" then
        return nil
    end

    if value.kind == "scene_object" then
        return scene_context and scene_context.find_object and scene_context:find_object(ref_id) or nil
    end

    if value.kind == "ui_instance" then
        return scene_context and scene_context.find_ui_instance and scene_context:find_ui_instance(ref_id) or nil
    end

    return nil
end

local function _resolve_runtime_refs(runtime, value, seen)
    if type(value) ~= "table" then
        return value
    end
    if _is_runtime_object_ref(value) then
        return _resolve_runtime_ref(runtime, value)
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[_resolve_runtime_refs(runtime, key, seen)] = _resolve_runtime_refs(runtime, item, seen)
    end
    return copy
end

local function _get_runtime_bridge(runtime)
    if not runtime then
        return nil
    end
    return runtime._active_bridge or runtime._resolving_bridge
end

local function _read_scoped_value(runtime, scope, name)
    if scope == "global" then
        local current = runtime._global_vars
        for part in tostring(name or ""):gmatch("[^%.]+") do
            if type(current) ~= "table" then
                return nil
            end
            current = current[part]
            current = _resolve_runtime_ref(runtime, current)
        end
        return current
    end
    local value = runtime._locals[tostring(name or "")]
    value = _resolve_runtime_ref(runtime, value)
    if _is_runtime_object_ref(runtime._locals[tostring(name or "")]) and value ~= nil then
        runtime._locals[tostring(name or "")] = value
    end
    return value
end

local function _write_scoped_value(runtime, target, value)
    if not target then
        return
    end

    if target.scope == "global" then
        local parts = {}
        for part in tostring(target.name or ""):gmatch("[^%.]+") do
            table.insert(parts, part)
        end
        local current = runtime._global_vars
        for index = 1, #parts - 1 do
            local key = parts[index]
            if type(current[key]) ~= "table" then
                current[key] = {}
            end
            current = current[key]
        end
        current[parts[#parts]] = _clone_runtime_local_value(value)
        return
    end

    runtime._locals[tostring(target.name or "")] = _clone_runtime_local_value(value)
end

local function _is_runtime_interaction_pressed(runtime)
    local scene_context = runtime and runtime._scene_context or nil
    if scene_context and scene_context.is_runtime_interaction_pressed then
        return scene_context:is_runtime_interaction_pressed()
    end
    local input = RuntimeInputState.read_current_state()
    return input.mouse_pressed == true
        or input.submit_pressed == true
        or GlobalContext.is_simulated_interaction == true
end

local function _apply_saved_route(runtime, route)
    if not runtime then
        return
    end
    runtime._save_boundary = nil
    if type(route) ~= "table" then
        runtime._pc = runtime._pc + 1
        return
    end

    if route.kind == "label" and route.target then
        runtime:_jump_to_label(route.target)
        return
    end

    runtime._pc = runtime._pc + 1
end

local function _build_pending_resume(bridge, state)
    local instruction = bridge and bridge._instruction or {}
    local output_ref = state.output_ref
        or instruction.default_flow_output
        or FlowTextExecutionBridge.get_default_flow_output(bridge)
    local route_binding = output_ref ~= nil and (instruction.route_bindings or {})[output_ref] or nil
    local route = {kind = "next"}
    if type(route_binding) == "table" and route_binding.kind == "label" then
        route =
        {
            kind = "label",
            target = route_binding.target,
        }
    end

    return
    {
        type = "interaction",
        output_ref = output_ref,
        route = route,
    }
end

local function _describe_value_type(value)
    local value_type = type(value)
    if value == nil then
        return "nil"
    end
    if value_type == "number" then
        return "number"
    end
    if value_type == "string" then
        return "string"
    end
    if value_type == "boolean" then
        return "bool"
    end
    return value_type
end

local function _evaluate_expression(runtime, expr)
    if not expr then
        return nil, nil
    end

    if expr.kind == "variable" then
        return _read_scoped_value(runtime, expr.scope, expr.name), nil
    end
    if expr.kind == "bool" or expr.kind == "number" or expr.kind == "string" then
        return expr.value, nil
    end
    if expr.kind == "null" then
        return nil, nil
    end
    if expr.kind == "unary" and expr.op == "not" then
        local value, err = _evaluate_expression(runtime, expr.expr)
        if err then
            return nil, err
        end
        return not value, nil
    end
    if expr.kind == "binary" then
        if expr.op == "and" then
            local left, left_err = _evaluate_expression(runtime, expr.left)
            if left_err then
                return nil, left_err
            end
            if not left then
                return left, nil
            end
            return _evaluate_expression(runtime, expr.right)
        elseif expr.op == "or" then
            local left, left_err = _evaluate_expression(runtime, expr.left)
            if left_err then
                return nil, left_err
            end
            if left then
                return left, nil
            end
            return _evaluate_expression(runtime, expr.right)
        end

        local left, left_err = _evaluate_expression(runtime, expr.left)
        if left_err then
            return nil, left_err
        end
        local right, right_err = _evaluate_expression(runtime, expr.right)
        if right_err then
            return nil, right_err
        end

        if expr.op == "==" then
            return left == right, nil
        elseif expr.op == "!=" then
            return left ~= right, nil
        elseif expr.op == ">" or expr.op == "<" or expr.op == ">=" or expr.op == "<=" then
            if type(left) ~= "number" or type(right) ~= "number" then
                return nil, string.format(
                    "文本表达式比较需要数字，实际得到 %s 和 %s",
                    _describe_value_type(left),
                    _describe_value_type(right))
            end
            if expr.op == ">" then
                return left > right, nil
            elseif expr.op == "<" then
                return left < right, nil
            elseif expr.op == ">=" then
                return left >= right, nil
            elseif expr.op == "<=" then
                return left <= right, nil
            end
        end
    end

    return nil, string.format("不支持的文本表达式类型：%s", tostring(expr.kind))
end

local function _stop_runtime(runtime, skip_destroy_scene)
    if not skip_destroy_scene and runtime._scene_context and runtime._scene_context.destroy then
        runtime._scene_context:destroy()
    end
    runtime._scene_context = nil
    runtime._active_bridge = nil
    runtime._ended = true
end

local function _finalize_runtime_end(runtime)
    if not runtime or runtime._finish_notified then
        return
    end

    runtime._finish_notified = true
    if runtime._detach_document_lifecycle ~= true
        and runtime._document
        and runtime._document.finish_runtime
    then
        runtime._document:finish_runtime()
    end
end

local function _raise_text_runtime_error(runtime, err, extra_context)
    local context =
    {
        flow_document = runtime._document,
        text_anchor = runtime._current_source_anchor,
    }
    if type(extra_context) == "table" then
        for key, value in pairs(extra_context) do
            context[key] = value
        end
    end
    if runtime._on_error then
        local payload = FlowRuntimeError.prepare(err, context)
        runtime._on_error(payload)
        _stop_runtime(runtime, runtime._owns_scene_context ~= true)
        _finalize_runtime_end(runtime)
        return
    end

    FlowRuntimeError.handle(err, context)
    _stop_runtime(runtime, true)
    _finalize_runtime_end(runtime)
end

function FlowTextRuntime.new(document, program, scene_context, options)
    options = options or {}

    local entry_label = options.entry_label
    local pc = tonumber(program and program.entry_index) or 1
    local start_error = nil
    if type(entry_label) == "string" and entry_label ~= "" then
        local target_index = program and program.labels and program.labels[entry_label] or nil
        if target_index then
            pc = target_index
        else
            start_error =
            {
                kind = "flow_runtime_abort",
                subtype = "text_jump_error",
                message = string.format("无法跳转到不存在的标签：#%s", tostring(entry_label)),
            }
        end
    end

    local runtime =
    {
        _document = document,
        _program = program,
        _scene_context = scene_context,
        _pc = pc,
        _active_bridge = nil,
        _resolving_bridge = nil,
        _locals = _clone_runtime_locals(type(options.initial_locals) == "table" and options.initial_locals or {}),
        _global_vars = GlobalContext.runtime_global_context,
        _ended = false,
        _current_source_anchor = nil,
        _owns_scene_context = options.owns_scene_context ~= false,
        _update_scene_context = options.update_scene_context ~= false,
        _detach_document_lifecycle = options.detach_document_lifecycle == true,
        _bind_global_runtime_document = options.detach_document_lifecycle ~= true
            and options.bind_global_runtime_document ~= false,
        _finish_notified = false,
        _on_error = type(options.on_error) == "function" and options.on_error or nil,
        _start_error = start_error,
        _pending_resume_action = nil,
        _save_boundary = nil,
    }
    return setmetatable(runtime, FlowTextRuntime)
end

function FlowTextRuntime:get_current_source_anchor()
    return self._current_source_anchor
end

function FlowTextRuntime:get_scene_context()
    return self._scene_context
end

function FlowTextRuntime:set_runtime_save_boundary(boundary)
    self._save_boundary = type(boundary) == "table" and _clone_value(boundary) or nil
end

function FlowTextRuntime:clear_runtime_save_boundary()
    self._save_boundary = nil
end

function FlowTextRuntime:get_runtime_save_boundary()
    return type(self._save_boundary) == "table" and _clone_value(self._save_boundary) or nil
end

function FlowTextRuntime:resolve_runtime_local_value(value)
    return _resolve_runtime_ref(self, value)
end

function FlowTextRuntime:resolve_runtime_local_references()
    self._locals = _resolve_runtime_refs(self, self._locals or {})
end

function FlowTextRuntime:can_save_now()
    if self._ended then
        return false, "当前文本流程已经结束"
    end

    if self._pending_resume_action then
        return true
    end

    if self._active_bridge then
        local node = self._active_bridge._node
        local has_common_wait_state = type(node and node._runtime_wait_interaction_state) == "table"
        local has_save_boundary = type(self._save_boundary) == "table" and self._save_boundary.saveable == true
        if has_save_boundary then
            return true
        end
        if has_common_wait_state then
            return false, "当前命令正在进入等待状态，输入释放后才能存档"
        end
        if node and node.can_save_now then
            local ok, reason = node:can_save_now(self._scene_context,
            {
                runtime = self,
                bridge = self._active_bridge,
            })
            if ok ~= true then
                return false, reason or "当前命令尚未进入可保存的稳定等待点"
            end
            return true
        end
        return false, "当前命令尚未进入可保存的稳定等待点"
    end

    return true
end

function FlowTextRuntime:collect_save_state()
    local snapshot =
    {
        kind = "text",
        document_guid = self._document and self._document._resource_guid or "",
        document_path = self._document and self._document._path or "",
        document_name = self._document and (self._document._display_name or self._document._resource_id or self._document._id) or "",
        pc = self._pc,
        current_source_anchor = _clone_value(self._current_source_anchor),
        locals = _clone_runtime_locals(self._locals),
        checkpoint_kind = "stable_boundary",
    }

    if self._pending_resume_action then
        snapshot.pending_resume = _clone_value(self._pending_resume_action)
        snapshot.checkpoint_kind = "interaction_boundary"
        return snapshot
    end

    if self._active_bridge then
        local node = self._active_bridge._node
        local has_common_wait_state = type(node and node._runtime_wait_interaction_state) == "table"
        local has_save_boundary = type(self._save_boundary) == "table" and self._save_boundary.saveable == true
        local state = nil
        if has_common_wait_state and not has_save_boundary then
            return nil
        elseif has_save_boundary then
            state =
            {
                resume_mode = self._save_boundary.resume_mode or "interaction",
                output_ref = self._save_boundary.output_ref,
                boundary_kind = self._save_boundary.kind,
            }
        else
            state = node and node.collect_runtime_save_state and node:collect_runtime_save_state(self._scene_context,
            {
                runtime = self,
                bridge = self._active_bridge,
            }) or nil
        end
        if type(state) ~= "table" then
            return nil
        end

        if state.resume_mode == "interaction" then
            snapshot.pending_resume = _build_pending_resume(self._active_bridge, state)
            snapshot.checkpoint_kind = state.boundary_kind or "interaction_boundary"
        elseif state.resume_mode == "reexecute" then
            snapshot.skip_object_ids = _clone_value(state.managed_object_ids or {})
            snapshot.skip_ui_instance_ids = _clone_value(state.managed_ui_instance_ids or {})
            snapshot.active_bridge =
            {
                resume_mode = "reexecute",
                instruction_index = self._pc,
                state = _clone_value(state.state or {}),
                managed_object_ids = _clone_value(state.managed_object_ids or {}),
                managed_ui_instance_ids = _clone_value(state.managed_ui_instance_ids or {}),
            }
            snapshot.checkpoint_kind = "bridge_waiting"
        else
            return nil
        end
    end

    return snapshot
end

function FlowTextRuntime:runtime_find_node(id)
    return FlowTextExecutionBridge.runtime_find_node(_get_runtime_bridge(self), id)
end

function FlowTextRuntime:runtime_find_pin(id)
    return FlowTextExecutionBridge.runtime_find_pin(_get_runtime_bridge(self), id)
end

function FlowTextRuntime:_jump_to_label(label_name)
    local target_index = self._program.labels and self._program.labels[label_name] or nil
    if target_index then
        self._pc = target_index
        return true
    end

    _raise_text_runtime_error(self,
    {
        kind = "flow_runtime_abort",
        subtype = "text_jump_error",
        message = string.format("无法跳转到不存在的标签：#%s", tostring(label_name)),
    })
    return false
end

function FlowTextRuntime:_finalize_bridge(bridge)
    if not bridge then
        return
    end
    self._save_boundary = nil

    for output_name, binding in pairs(bridge._instruction.data_bindings or {}) do
        local value = FlowTextExecutionBridge.read_output_value(bridge, output_name)
        _write_scoped_value(self, binding.target, value)
    end

    local selected_route_key = FlowTextExecutionBridge.get_selected_route_key(bridge)
    local route_binding = nil
    if selected_route_key ~= nil then
        route_binding = (bridge._instruction.route_bindings or {})[selected_route_key]
    end

    if route_binding == nil and selected_route_key == nil then
        local default_route = bridge._instruction.default_flow_output or FlowTextExecutionBridge.get_default_flow_output(bridge)
        if default_route ~= nil then
            route_binding = (bridge._instruction.route_bindings or {})[default_route]
        end
    end

    if route_binding and route_binding.kind == "label" then
        self:_jump_to_label(route_binding.target)
        return
    end

    self._pc = self._pc + 1
end

function FlowTextRuntime:_step_instruction()
    local instruction = self._program.instructions[self._pc]
    if not instruction then
        self._ended = true
        return
    end

    self._current_source_anchor = instruction.source
    self._save_boundary = nil

    if self._bind_global_runtime_document ~= false then
        _get_runtime_flow_control().capture_before_transition(self._document,
        {
            source = "flow_node",
            reason = "text_instruction",
            label = "文本指令执行前",
        })
    end

    if instruction.kind == "jump" then
        self:_jump_to_label(instruction.target_label)
        return
    end

    if instruction.kind == "jump_if_false" then
        local value, err = _evaluate_expression(self, instruction.expression)
        if err then
            _raise_text_runtime_error(
            self,
            {
                kind = "flow_runtime_abort",
                subtype = "text_expression_error",
                message = err,
            },
            {
                text_anchor = instruction.source,
            })
            return
        end

        if not value then
            self:_jump_to_label(instruction.target_label)
        else
            self._pc = self._pc + 1
        end
        return
    end

    if instruction.kind == "invoke" then
        local bridge, err = FlowTextExecutionBridge.invoke(self._document, instruction, self._scene_context, self)
        if not bridge then
            _raise_text_runtime_error(
                self,
                err or string.format("文本命令执行失败：%s", tostring(instruction.command)),
                {
                    text_anchor = instruction.source,
                    command = instruction.command,
                })
            return
        end

        if self._bind_global_runtime_document
            and GlobalContext.get_runtime_flow_document
            and GlobalContext.get_runtime_flow_document() ~= self._document
        then
            self._ended = true
            _finalize_runtime_end(self)
            return
        end

        if FlowTextExecutionBridge.is_completed(bridge) then
            self:_finalize_bridge(bridge)
        else
            self._active_bridge = bridge
        end
        return
    end

    self._pc = self._pc + 1
end

function FlowTextRuntime:update(delta)
    if self._ended then
        _finalize_runtime_end(self)
        return
    end

    if self._start_error then
        local start_error = self._start_error
        self._start_error = nil
        _raise_text_runtime_error(self, start_error)
        return
    end

    if self._update_scene_context and self._scene_context then
        self._scene_context:on_update(delta)
    end

    if self._pending_resume_action then
        if self._bind_global_runtime_document
            and GlobalContext.get_runtime_flow_document
            and GlobalContext.get_runtime_flow_document() ~= self._document
        then
            self._ended = true
            _finalize_runtime_end(self)
            return
        end

        if _is_runtime_interaction_pressed(self) then
            local pending_resume = self._pending_resume_action
            self._pending_resume_action = nil
            _apply_saved_route(self, pending_resume.route)
        end
        return
    end

    if self._active_bridge then
        local bridge_ok, bridge_err = FlowTextExecutionBridge.update(self._active_bridge, self._scene_context, delta)
        if bridge_ok == false then
            _raise_text_runtime_error(
                self,
                bridge_err or "文本命令执行失败",
                {
                    command = self._active_bridge
                        and self._active_bridge._instruction
                        and self._active_bridge._instruction.command
                        or nil,
                })
            return
        end
        if self._bind_global_runtime_document
            and GlobalContext.get_runtime_flow_document
            and GlobalContext.get_runtime_flow_document() ~= self._document
        then
            self._ended = true
            _finalize_runtime_end(self)
            return
        end
        if FlowTextExecutionBridge.is_completed(self._active_bridge) then
            local bridge = self._active_bridge
            self._active_bridge = nil
            self:_finalize_bridge(bridge)
        end
        return
    end

    local guard = 0
    while not self._active_bridge and not self._ended and guard < 128 do
        guard = guard + 1
        self:_step_instruction()
    end

    if self._ended then
        _finalize_runtime_end(self)
    end
end

module.new = FlowTextRuntime.new

return module

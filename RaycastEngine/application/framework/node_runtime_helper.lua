local sdl = Engine.SDL
local rl = Engine.Raylib

local Class = require("application.framework.class")
local FlowRuntimeError = require("application.framework.flow_runtime_error")
local GlobalContext = require("application.framework.global_context")
local ResourceIndex = require("application.framework.resource_index")
local ResourcePrefetcher = require("application.framework.resource_prefetcher")
local RuntimeInputState = require("application.framework.runtime_input_state")
local StyleManager = require("application.framework.style_manager")

local module = {}
local finite_abs_limit <const> = math.huge
local SnapshotCoordinator = false
local RuntimeFlowControl = false

local function _get_snapshot_coordinator()
    if SnapshotCoordinator == false then
        SnapshotCoordinator = require("application.framework.snapshot_coordinator")
    end
    return SnapshotCoordinator
end

local function _get_runtime_flow_control()
    if RuntimeFlowControl == false then
        RuntimeFlowControl = require("application.framework.runtime_flow_control")
    end
    return RuntimeFlowControl
end

module.convert_imvec4_to_sdl_color = function(vec4)
    return sdl.Color(
        math.clamp(math.floor(vec4.x * 255), 0, 255),
        math.clamp(math.floor(vec4.y * 255), 0, 255),
        math.clamp(math.floor(vec4.z * 255), 0, 255),
        math.clamp(math.floor(vec4.w * 255), 0, 255))
end

local function _read_number_field(value, key)
    if type(value) ~= "table" and type(value) ~= "userdata" then
        return nil
    end
    local ok, result = pcall(function()
        return value[key]
    end)
    if not ok then
        return nil
    end
    return tonumber(result)
end

module.convert_imvec4_to_color_table = function(vec4)
    local r = _read_number_field(vec4, "x") or _read_number_field(vec4, "r") or 0
    local g = _read_number_field(vec4, "y") or _read_number_field(vec4, "g") or 0
    local b = _read_number_field(vec4, "z") or _read_number_field(vec4, "b") or 0
    local a = _read_number_field(vec4, "w") or _read_number_field(vec4, "a") or 1
    if r <= 1 and g <= 1 and b <= 1 and a <= 1 then
        r, g, b, a = r * 255, g * 255, b * 255, a * 255
    end
    return
    {
        r = math.clamp(math.floor(r), 0, 255),
        g = math.clamp(math.floor(g), 0, 255),
        b = math.clamp(math.floor(b), 0, 255),
        a = math.clamp(math.floor(a), 0, 255),
    }
end

module.convert_imvec4_to_raylib_color = function(vec4)
    return rl.Color(
        math.clamp(math.floor(vec4.x * 255), 0, 255),
        math.clamp(math.floor(vec4.y * 255), 0, 255),
        math.clamp(math.floor(vec4.z * 255), 0, 255),
        math.clamp(math.floor(vec4.w * 255), 0, 255))
end

local function _describe_pin_ref(ref)
    if ref == nil then
        return "默认路由"
    end
    if type(ref) == "string" then
        return string.format("“%s”", ref)
    end
    if type(ref) == "number" then
        return string.format("#%s", tostring(ref))
    end
    if type(ref) == "table" and ref._id and ref._id.get then
        return string.format("#%s", tostring(ref._id:get()))
    end
    return tostring(ref)
end

local function _resolve_input_pin(node, ref)
    if node and node.resolve_input_pin then
        return node:resolve_input_pin(ref)
    end

    if type(ref) == "number" then
        local pin = node and node._input_pin_list and node._input_pin_list[ref] or nil
        return pin, pin and ref or nil
    end

    return nil, nil
end

local function _resolve_output_pin(node, ref)
    if node and node.resolve_output_pin then
        return node:resolve_output_pin(ref)
    end

    if type(ref) == "number" then
        local pin = node and node._output_pin_list and node._output_pin_list[ref] or nil
        return pin, pin and ref or nil
    end

    return nil, nil
end

local function _get_pin(node, ref, is_output)
    local pin, index = nil, nil
    if is_output then
        pin, index = _resolve_output_pin(node, ref)
    else
        pin, index = _resolve_input_pin(node, ref)
    end

    if pin then
        return pin, index
    end

    local node_id = node and node._id and node._id:get() or "?"
    local direction_text = is_output and "输出" or "输入"
    FlowRuntimeError.raise(
        "node_runtime_error",
        string.format("节点[#%s]：访问了不存在的%s引脚 %s", tostring(node_id), direction_text, _describe_pin_ref(ref)),
        {node = node})
end

local function _same_pin(left, right)
    if left == right then
        return true
    end

    local left_id = left and left._id and left._id.get and left._id:get() or nil
    local right_id = right and right._id and right._id.get and right._id:get() or nil
    return left_id ~= nil and right_id ~= nil and left_id == right_id
end

local function _get_node_scene_context(node)
    local blueprint = node and node._blueprint or nil
    return blueprint and blueprint._scene_context or nil
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

local function _make_current_flow_reference_from_document(document)
    if type(document) ~= "table" then
        return nil
    end

    local raw_reference = _trim(document._resource_guid)
        or _trim(document._path)
        or _trim(document._resource_id)
    if not raw_reference then
        return nil
    end

    return ResourceIndex.make_reference("flow", raw_reference)
end

module.get_current_flow_reference = function(node)
    local blueprint = node and node._blueprint or nil
    local runtime_owner = blueprint and blueprint._runtime_owner or nil

    local reference = _make_current_flow_reference_from_document(node and node._flow_document or nil)
    if reference then
        return reference
    end

    reference = _make_current_flow_reference_from_document(runtime_owner and runtime_owner._source_document or nil)
    if reference then
        return reference
    end

    reference = _make_current_flow_reference_from_document(
        GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil)
    if reference then
        return reference
    end

    return _make_current_flow_reference_from_document(blueprint)
end

local function _get_runtime_boundary_owner(node)
    local blueprint = node and node._blueprint or nil
    if not blueprint then
        return nil
    end

    if blueprint._flow_text_runtime then
        return blueprint._flow_text_runtime
    end

    if blueprint._runtime_owner then
        return nil
    end

    if blueprint.kind == "graph" then
        return blueprint
    end

    return nil
end

local function _set_runtime_save_boundary(node, boundary)
    local owner = _get_runtime_boundary_owner(node)
    if not owner then
        return
    end
    if owner.set_runtime_save_boundary then
        owner:set_runtime_save_boundary(boundary)
        return
    end
    owner._save_boundary = boundary
end

local function _commit_anchor(node, boundary)
    local owner = _get_runtime_boundary_owner(node)
    if not owner then
        return
    end
    local ok = pcall(function()
        _get_snapshot_coordinator().commit_anchor(owner, boundary,
        {
            source = "flow_node",
        })
    end)
    return ok
end

local function _commit_full_slice(node, boundary)
    local owner = _get_runtime_boundary_owner(node)
    if not owner then
        return
    end
    local ok = pcall(function()
        _get_snapshot_coordinator().commit_full_slice(owner, boundary,
        {
            source = "flow_node",
        })
    end)
    return ok
end

module.commit_full_slice = function(node, boundary)
    return _commit_full_slice(node, type(boundary) == "table" and boundary or
    {
        kind = "running_resumable",
        label = "运行中可恢复点",
        node_id = node and node._id and node._id:get() or nil,
        node_title = node and node._title or nil,
    })
end

local function _clear_runtime_save_boundary(node)
    local owner = _get_runtime_boundary_owner(node)
    if not owner then
        return
    end
    if owner.clear_runtime_save_boundary then
        owner:clear_runtime_save_boundary()
        return
    end
    owner._save_boundary = nil
end

module.leave_save_boundary = function(node)
    _clear_runtime_save_boundary(node)
end

module.enter_input_wait = function(node, output_ref, options)
    local boundary_options = type(options) == "table" and options or {}
    local boundary =
    {
        kind = boundary_options.kind or "input_wait",
        saveable = true,
        resume_mode = "interaction",
        output_ref = output_ref,
        reason = tostring(boundary_options.reason or "等待玩家操作"),
        node_id = node and node._id and node._id:get() or nil,
        node_title = node and node._title or nil,
        label = tostring(boundary_options.label or boundary_options.reason or "等待玩家操作"),
    }
    _set_runtime_save_boundary(node, boundary)
    _commit_full_slice(node, boundary)
end

local function _is_runtime_interaction_pressed(node)
    local scene = _get_node_scene_context(node)
    if scene and scene.is_runtime_interaction_pressed then
        return scene:is_runtime_interaction_pressed()
    end

    local input = RuntimeInputState.read_current_state()
    return input.mouse_pressed == true
        or input.submit_pressed == true
        or GlobalContext.is_simulated_interaction == true
end

local function _has_runtime_interaction_activity(node)
    local scene = _get_node_scene_context(node)
    if scene and scene.has_runtime_interaction_activity then
        return scene:has_runtime_interaction_activity()
    end

    local input = RuntimeInputState.read_current_state()
    local key_released_map = type(input.key_released_map) == "table" and input.key_released_map or {}
    return input.mouse_down == true
        or input.mouse_pressed == true
        or input.mouse_released == true
        or input.submit_pressed == true
        or input.space_pressed == true
        or input.enter_pressed == true
        or input.keypad_enter_pressed == true
        or key_released_map.space == true
        or key_released_map.enter == true
        or key_released_map.keypad_enter == true
end

local function _merge_opts(type_id, opts)
    local merged = {}
    if type(opts) == "table" then
        for key, value in pairs(opts) do
            merged[key] = value
        end
    end
    merged.type_id = merged.type_id or type_id
    return merged
end

module.execute_next_node = function(self, ref)
    _commit_anchor(self,
    {
        kind = "node_exit",
        label = "节点完成后",
        node_id = self and self._id and self._id:get() or nil,
        node_title = self and self._title or nil,
    })
    self._runtime_wait_interaction_state = nil
    module.leave_save_boundary(self)
    local output_pin, route_index = nil, nil
    if ref == nil then
        output_pin, route_index = _resolve_output_pin(self, 1)
    else
        output_pin, route_index = _get_pin(self, ref, true)
    end

    if not output_pin then
        self._blueprint:execute_node()
        return
    end

    local next_node, next_pin = nil, nil
    if output_pin._linked_pin_id then
        next_pin = GlobalContext.runtime_find_pin(output_pin._linked_pin_id:get())
        if next_pin then
            next_node = GlobalContext.runtime_find_node(next_pin._owner_id:get())
        end
    end

    ResourcePrefetcher.prefetch_next_route(self, route_index)
    self._blueprint:execute_node(next_node, next_pin, output_pin, route_index)
end

module.wait_interact_to_next_node = function(self, ref)
    local output_pin, route_index = nil, nil
    if ref == nil then
        output_pin, route_index = _resolve_output_pin(self, 1)
    else
        output_pin, route_index = _get_pin(self, ref, true)
    end

    if route_index then
        ResourcePrefetcher.prefetch_next_route(self, route_index)
    end

    local wait_ref = tostring(ref or "__default")
    local wait_state = self._runtime_wait_interaction_state
    if type(wait_state) ~= "table" or wait_state.ref ~= wait_ref then
        wait_state =
        {
            ref = wait_ref,
            armed = false,
        }
        self._runtime_wait_interaction_state = wait_state
        module.leave_save_boundary(self)
    end

    if wait_state.armed ~= true then
        if _has_runtime_interaction_activity(self) then
            module.leave_save_boundary(self)
            return
        end
        wait_state.armed = true
        module.enter_input_wait(self, output_pin and (output_pin._key or route_index) or ref)
        return
    end

    if _is_runtime_interaction_pressed(self) then
        _get_runtime_flow_control().capture_before_transition(
            GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil,
            {
                source = "flow_node",
                reason = "interaction_wait",
                label = "等待交互推进前",
            })
        self._runtime_wait_interaction_state = nil
        module.leave_save_boundary(self)
        module.execute_next_node(self, ref)
    end
end

module.abort = function(node, message, subtype, extra)
    local context = {node = node}
    if type(extra) == "table" then
        for key, value in pairs(extra) do
            context[key] = value
        end
    end
    local node_id = node and node._id and node._id:get() or "?"
    FlowRuntimeError.raise(
        subtype or "node_runtime_error",
        string.format("节点[#%s]：%s", tostring(node_id), tostring(message or "流程运行时错误")),
        context)
end

module.fail = function(node, message, subtype, extra)
    local context = {node = node}
    if type(extra) == "table" then
        for key, value in pairs(extra) do
            context[key] = value
        end
    end
    local node_id = node and node._id and node._id:get() or "?"
    FlowRuntimeError.handle(
    {
        kind = "flow_runtime_abort",
        subtype = subtype or "node_runtime_error",
        message = string.format("节点[#%s]：%s", tostring(node_id), tostring(message or "流程运行时错误")),
        context = context,
    }, context)
end

module.get_input_pin = function(node, ref)
    return _get_pin(node, ref, false)
end

module.get_output_pin = function(node, ref)
    return _get_pin(node, ref, true)
end

module.check_input = function(node, ref, expectation)
    return module.get_input_pin(node, ref):check_val(expectation)
end

module.check_bool = function(node, ref, opts)
    return module.check_input(node, ref, _merge_opts("bool", opts))
end

module.check_float = function(node, ref, opts)
    return module.check_input(node, ref, _merge_opts("float", opts))
end

module.check_int = function(node, ref, opts)
    return module.check_input(node, ref, _merge_opts("int", opts))
end

module.check_string = function(node, ref, opts)
    return module.check_input(node, ref, _merge_opts("string", opts))
end

module.check_vector2 = function(node, ref, opts)
    return module.check_input(node, ref, _merge_opts("vector2", opts))
end

module.check_color = function(node, ref, opts)
    return module.check_input(node, ref, _merge_opts("color", opts))
end

module.check_resource = function(node, ref, asset_type, opts)
    return module.check_input(node, ref, _merge_opts(asset_type, opts))
end

module.check_instance = function(node, ref, target_class, opts)
    return module.get_input_pin(node, ref):check_instance(target_class, opts)
end

module.try_check_input = function(node, ref, expectation)
    return module.get_input_pin(node, ref):try_check_val(expectation)
end

module.try_get_style_value = function(node, domain, key, expectation)
    local expected = expectation
    if type(expected) ~= "table" and type(expected) ~= "string" then
        expected = {type_id = "object"}
    end

    local value, ok, err = StyleManager.try_get_value(domain, key, expected)
    if ok then
        return value, true, nil
    end

    return nil, false, err
end

module.get_style_value = function(node, domain, key, expectation)
    local value, ok, err = module.try_get_style_value(node, domain, key, expectation)
    if ok then
        return value
    end

    local message = string.format("样式字段“%s.%s”当前不可用", tostring(domain), tostring(key))
    if type(err) == "string" and err ~= "" then
        message = string.format("%s：%s", message, err)
    end
    module.abort(node, message, "style_runtime_error")
end

module.set_output = function(node, ref, value)
    local pin = module.get_output_pin(node, ref)
    if pin and pin.set_val then
        pin:set_val(value)
    end
    return pin
end

module.is_entry_pin = function(node, ref, entry_pin)
    local pin = module.get_input_pin(node, ref)
    return _same_pin(pin, entry_pin)
end

module.describe_value_type = function(value)
    local value_type = type(value)
    if value_type == "table" then
        return Class.get_class_name(value)
    end
    return value_type
end

module.ensure_non_negative = function(node, label, value)
    if value < 0 then
        module.abort(node, string.format("节点[#%s]：%s不能小于 0", tostring(node._id:get()), label))
    end
    return value
end

module.is_finite_number = function(value)
    return type(value) == "number"
        and value == value
        and value < finite_abs_limit
        and value > -finite_abs_limit
end

return module

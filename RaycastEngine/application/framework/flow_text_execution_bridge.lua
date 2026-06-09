local FlowRuntimeGuard = require("application.framework.flow_runtime_guard")
local NodeFactory = require("application.framework.node_factory")
local NodeRegistry = require("application.framework.node_registry")
local ValueAdapter = require("application.framework.flow_text_value_adapter")

local module = {}

local schema_cache = {}

local function _new_stub(document, source_anchor)
    local stub =
    {
        _flow_document = document,
        _flow_text_anchor = source_anchor,
        _scene_context = nil,
        _max_uid = 0,
        _node_pool = {},
        _pin_pool = {},
        _selected_route = nil,
    }

    function stub:gen_next_uid()
        self._max_uid = self._max_uid + 1
        return self._max_uid
    end

    function stub:execute_node(next_node, entry_pin, output_pin, route_index)
        self._selected_route =
        {
            next_node = next_node,
            entry_pin = entry_pin,
            output_pin = output_pin,
            route_index = route_index,
            route_ref = output_pin and (output_pin._key or route_index) or route_index,
        }
    end

    return stub
end

local function _attach_runtime_node(stub, node)
    stub._node_pool[node._id:get()] = node
    for _, pin in ipairs(node._input_pin_list or {}) do
        stub._pin_pool[pin._id:get()] = pin
    end
    for _, pin in ipairs(node._output_pin_list or {}) do
        stub._pin_pool[pin._id:get()] = pin
    end
end

local function _build_schema(type_id)
    local definition = NodeRegistry.get(type_id)
    if not definition then
        return nil
    end

    local stub = _new_stub(nil, nil)
    local node = NodeFactory.create(
    {
        blueprint = stub,
        type_id = type_id,
    })
    _attach_runtime_node(stub, node)

    local schema =
    {
        type_id = type_id,
        input_list = {},
        input_by_key = {},
        output_list = {},
        output_by_key = {},
        flow_output_count = 0,
        default_flow_output = nil,
    }

    for index, pin in ipairs(node._input_pin_list or {}) do
        local item =
        {
            index = index,
            key = pin._key,
            type_id = pin._type_id,
            name = pin._name,
        }
        table.insert(schema.input_list, item)
        if item.key then
            schema.input_by_key[item.key] = item
        end
    end

    for index, pin in ipairs(node._output_pin_list or {}) do
        local item =
        {
            index = index,
            key = pin._key,
            type_id = pin._type_id,
            name = pin._name,
        }
        table.insert(schema.output_list, item)
        if item.key then
            schema.output_by_key[item.key] = item
        end
        if item.type_id == "flow" then
            schema.flow_output_count = schema.flow_output_count + 1
            if schema.default_flow_output == nil then
                schema.default_flow_output = item.key or item.index
            end
        end
    end

    return schema
end

module.describe_node_schema = function(type_id)
    local schema = schema_cache[type_id]
    if not schema then
        schema = _build_schema(type_id)
        schema_cache[type_id] = schema
    end
    return schema
end

module.invalidate_schema_cache = function()
    schema_cache = {}
end

local function _resolve_input_pin(node, ref)
    if node.resolve_input_pin then
        return node:resolve_input_pin(ref)
    end
    if type(ref) == "number" then
        return node._input_pin_list[ref]
    end
    return node._input_pin_map and node._input_pin_map[ref] or nil
end

local function _resolve_output_pin(node, ref)
    if node.resolve_output_pin then
        return node:resolve_output_pin(ref)
    end
    if type(ref) == "number" then
        return node._output_pin_list[ref]
    end
    return node._output_pin_map and node._output_pin_map[ref] or nil
end

module.invoke = function(document, instruction, scene_context, runtime)
    local source_anchor = instruction.source or {}
    local stub = _new_stub(document, source_anchor)
    stub._scene_context = scene_context
    stub._flow_text_runtime = runtime
    local node = NodeFactory.create(
    {
        blueprint = stub,
        type_id = instruction.type_id,
    })
    if not node then
        return nil, string.format("无法创建命令对应的节点：%s", tostring(instruction.type_id))
    end

    node._flow_document = document
    node._flow_text_anchor = source_anchor
    node._flow_text_command = instruction.command
    _attach_runtime_node(stub, node)

    local bridge =
    {
        _document = document,
        _instruction = instruction,
        _node = node,
        _stub = stub,
        _schema = module.describe_node_schema(instruction.type_id) or {flow_output_count = 0},
    }
    local previous_resolving_bridge = runtime and runtime._resolving_bridge or nil
    if runtime then
        runtime._resolving_bridge = bridge
    end

    for _, binding in ipairs(instruction.input_bindings or {}) do
        local pin = _resolve_input_pin(node, binding.pin_ref)
        if not pin then
            if runtime then
                runtime._resolving_bridge = previous_resolving_bridge
            end
            return nil, string.format("无法绑定输入引脚：%s", tostring(binding.pin_ref))
        end
        if pin._type_id ~= "flow" then
            local value = ValueAdapter.resolve_runtime_value(binding.value, pin._type_id, runtime, binding.adapter)
            if pin.set_val then
                pin:set_val(value)
            end
        end
    end

    node._runtime_wait_interaction_state = nil
    local executed, runtime_error = FlowRuntimeGuard.call_node_captured(node, "on_execute", scene_context, nil)
    if runtime then
        runtime._resolving_bridge = previous_resolving_bridge
    end
    if not executed then
        return nil, runtime_error or string.format("命令执行失败：%s", tostring(instruction.command))
    end

    return bridge
end

module.update = function(bridge, scene_context, delta)
    if not bridge or not bridge._node then
        return true
    end
    if bridge._stub and bridge._stub._selected_route then
        return true
    end
    if bridge._stub then
        bridge._stub._scene_context = scene_context
    end
    local executed, runtime_error = FlowRuntimeGuard.call_node_captured(bridge._node, "on_execute_update", scene_context, delta)
    if not executed then
        return false, runtime_error
    end
    return true
end

module.is_completed = function(bridge)
    if not bridge then
        return true
    end
    if bridge._stub and bridge._stub._selected_route then
        return true
    end
    return (bridge._schema.flow_output_count or 0) == 0
end

module.get_selected_route = function(bridge)
    return bridge and bridge._stub and bridge._stub._selected_route or nil
end

module.get_selected_route_key = function(bridge)
    local route = module.get_selected_route(bridge)
    if not route then
        return nil
    end
    if route.output_pin and route.output_pin._key then
        return route.output_pin._key
    end
    return route.route_ref or route.route_index
end

module.get_default_flow_output = function(bridge)
    if not bridge or not bridge._schema then
        return nil
    end
    return bridge._schema.default_flow_output
end

module.read_output_value = function(bridge, ref)
    if not bridge or not bridge._node then
        return nil
    end
    local pin = _resolve_output_pin(bridge._node, ref)
    if not pin or not pin.get_val then
        return nil
    end
    return pin:get_val()
end

module.runtime_find_node = function(bridge, id)
    return bridge and bridge._stub and bridge._stub._node_pool[id] or nil
end

module.runtime_find_pin = function(bridge, id)
    return bridge and bridge._stub and bridge._stub._pin_pool[id] or nil
end

return module

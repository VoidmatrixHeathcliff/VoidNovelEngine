local FlowRuntimeError = require("application.framework.flow_runtime_error")

local module = {}
local unpack_args = table.unpack or unpack

local function _build_fallback_context(node, method_name)
    if not node then
        return {phase = method_name}
    end

    return
    {
        node = node,
        phase = method_name,
        flow_document = node._flow_document,
        text_anchor = node._flow_text_anchor,
        command = node._flow_text_command,
    }
end

local function _invoke_node(node, method_name, scene, ...)
    local method = node[method_name]
    if type(method) ~= "function" then
        return true
    end

    local args = {...}
    return xpcall(function()
        return method(node, scene, unpack_args(args))
    end, FlowRuntimeError.capture)
end

module.call_node = function(node, method_name, scene, ...)
    if not node then
        return true
    end

    local ok, result = _invoke_node(node, method_name, scene, ...)
    if ok then
        return true, result
    end

    FlowRuntimeError.handle(result, _build_fallback_context(node, method_name))
    return false, result
end

module.call_node_captured = function(node, method_name, scene, ...)
    if not node then
        return true
    end

    local ok, result = _invoke_node(node, method_name, scene, ...)
    if ok then
        return true, result
    end

    return false, FlowRuntimeError.prepare(result, _build_fallback_context(node, method_name))
end

return module

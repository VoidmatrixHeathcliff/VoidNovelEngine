local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")

local module = {}
local FlowManager = nil

local function _get_flow_manager()
    if not FlowManager then
        FlowManager = require("application.framework.flow_manager")
    end
    return FlowManager
end

local supported_resource_type_pool =
{
    texture = true,
    audio = true,
    font = true,
    shader = true,
    video = true,
}

local function _prefetch_reference(asset_type, reference)
    if not asset_type or not reference then
        return
    end
    ResourcesManager.prefetch(reference, "prefetch", asset_type)
end

local function _prefetch_switch_scene(node)
    local scene_pin = node and node._input_pin_list and node._input_pin_list[2] or nil
    if not scene_pin or not scene_pin.get_val then
        return
    end

    local target = scene_pin:get_val()
    if type(target) == "string" and target ~= "" then
        _get_flow_manager().prefetch(target, "prefetch")
    end
end

local function _prefetch_node(node)
    if not node then
        return
    end

    for _, pin in ipairs(node._input_pin_list or {}) do
        if supported_resource_type_pool[pin._type_id] and pin.get_reference then
            _prefetch_reference(pin._type_id, pin:get_reference())
        end
    end

    if node._type_id == "switch_scene" then
        _prefetch_switch_scene(node)
    end
end

module.prefetch_next_route = function(node, idx_route)
    idx_route = idx_route or 1
    if not node or not node._output_pin_list then
        return
    end

    local output_pin = node._output_pin_list[idx_route]
    if not output_pin or not output_pin._linked_pin_id then
        return
    end

    local next_pin = GlobalContext.runtime_find_pin(output_pin._linked_pin_id:get())
    if not next_pin then
        return
    end

    local next_node = GlobalContext.runtime_find_node(next_pin._owner_id:get())
    _prefetch_node(next_node)
end

return module

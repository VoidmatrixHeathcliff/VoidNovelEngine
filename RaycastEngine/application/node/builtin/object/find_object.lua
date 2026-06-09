local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "find_object",
    icon_id = "search-line",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "查找对象",
    comment = nil,
    category = "对象功能",
    category_order = 4,
    order = 1,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "string", name = "对象ID"})
    builder:add_output({type_id = "flow"})
    builder:add_output({type_id = "flow", name = "失败"})
    builder:add_output({type_id = "object"})

    node.on_execute = function(self, scene)
        local object_id = NodeRuntimeHelper.check_string(self, 2)
        local object = scene:find_object(object_id)
        self._output_pin_list[3]:set_val(object)
        if object then
            NodeRuntimeHelper.execute_next_node(self, 1)
        else
            NodeRuntimeHelper.execute_next_node(self, 2)
        end
    end

    return node
end)

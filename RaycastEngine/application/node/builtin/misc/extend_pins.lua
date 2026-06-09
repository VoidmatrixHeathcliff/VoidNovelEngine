local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "extend_pins",
    icon_id = "node-tree",
    color = imgui.ImVec4(imgui.ImColor(121, 124, 127, 255).value),
    name = "扩展引脚",
    comment = nil,
    category = "其他",
    category_order = 9,
    order = 2,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "object"})
    builder:add_output({type_id = "flow"})
    builder:add_output({type_id = "object", name = "扩展1"})
    builder:add_output({type_id = "object", name = "扩展2"})
    builder:add_output({type_id = "object", name = "扩展3"})

    node.on_execute = function(self, scene)
        local value = NodeRuntimeHelper.check_input(self, 2, {type_id = "object", allow_nil = true})
        self._output_pin_list[2]:set_val(value)
        self._output_pin_list[3]:set_val(value)
        self._output_pin_list[4]:set_val(value)
        NodeRuntimeHelper.execute_next_node(self)
    end

    return node
end)

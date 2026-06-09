local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "ceil",
    icon_id = "skip-up-fill",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "向上取整",
    comment = nil,
    category = "运算与逻辑",
    category_order = 7,
    order = 5,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "float"})
    builder:add_output({type_id = "flow"})
    builder:add_output({type_id = "int", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        self._output_pin_list[2]:set_val(math.ceil(NodeRuntimeHelper.check_float(self, 2)))
        NodeRuntimeHelper.execute_next_node(self)
    end

    return node
end)

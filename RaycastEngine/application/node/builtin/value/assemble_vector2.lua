local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local ColorHelper = Common.ColorHelper
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "assemble_vector2",
    icon_id = "organization-chart",
    color = ColorHelper.ValueTypeColorPool.vector2,
    name = "拼装二维向量",
    comment = nil,
    category = "值节点",
    category_order = 6,
    order = 8,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "x", type_id = "float", name = "X"})
    builder:add_input({key = "y", type_id = "float", name = "Y"})
    builder:add_output({key = "out", type_id = "flow"})
    builder:add_output({key = "value", type_id = "vector2", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local x_val = NodeRuntimeHelper.check_float(self, "x")
        local y_val = NodeRuntimeHelper.check_float(self, "y")
        NodeRuntimeHelper.set_output(self, "value", imgui.ImVec2(x_val, y_val))
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

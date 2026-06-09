local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local ColorHelper = Common.ColorHelper
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "random_int",
    icon_id = "dice-3-line",
    color = ColorHelper.ValueTypeColorPool.int,
    name = "随机整数",
    comment = nil,
    category = "值节点",
    category_order = 6,
    order = 7,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "min_value", type_id = "int", name = "最小值", default = 0})
    builder:add_input({key = "max_value", type_id = "int", name = "最大值", default = 100})
    builder:add_output({key = "out", type_id = "flow"})
    builder:add_output({key = "value", type_id = "int", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local min_val = NodeRuntimeHelper.check_int(self, "min_value")
        local max_val = NodeRuntimeHelper.check_int(self, "max_value")
        if min_val > max_val then
            NodeRuntimeHelper.abort(self, "随机数范围定义错误，最小值大于最大值")
        end

        NodeRuntimeHelper.set_output(self, "value", math.random(min_val, max_val))
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

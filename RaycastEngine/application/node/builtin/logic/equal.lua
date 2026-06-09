local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "equal",
    icon_id = "equal-fill",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "等于",
    comment = nil,
    category = "运算与逻辑",
    category_order = 7,
    order = 1,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "object", name = "左值"})
    builder:add_input({type_id = "object", name = "右值"})
    builder:add_output({type_id = "flow"})
    builder:add_output({type_id = "bool", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local left_val = NodeRuntimeHelper.check_input(self, 2, {type_id = "object", allow_nil = true})
        local right_val = NodeRuntimeHelper.check_input(self, 3, {type_id = "object", allow_nil = true})
        self._output_pin_list[2]:set_val(left_val == right_val)
        NodeRuntimeHelper.execute_next_node(self)
    end

    return node
end)

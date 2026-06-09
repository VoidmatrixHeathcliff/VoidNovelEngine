local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "add",
    icon_id = "add-fill",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "加法",
    comment = nil,
    category = "运算与逻辑",
    category_order = 7,
    order = 0.1,
    menu_visible = true,
    keywords = {"加", "+", "add"},
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "left", type_id = "float", name = "左值", default = 0})
    builder:add_input({key = "right", type_id = "float", name = "右值", default = 0})
    builder:add_output({key = "out", type_id = "flow"})
    builder:add_output({key = "value", type_id = "float", name = "结果", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local left_val = NodeRuntimeHelper.check_float(self, "left")
        local right_val = NodeRuntimeHelper.check_float(self, "right")
        local result = left_val + right_val
        if not NodeRuntimeHelper.is_finite_number(result) then
            NodeRuntimeHelper.abort(self, "加法运算结果不是有限数字")
        end

        NodeRuntimeHelper.set_output(self, "value", result)
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

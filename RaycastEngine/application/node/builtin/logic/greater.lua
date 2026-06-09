local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "greater",
    icon_id = "arrow-right-s-line",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "大于",
    comment = nil,
    category = "运算与逻辑",
    category_order = 7,
    order = 3,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "object", name = "左值"})
    builder:add_input({type_id = "object", name = "右值"})
    builder:add_input({type_id = "bool", name = "包含临界值"})
    builder:add_output({type_id = "flow"})
    builder:add_output({type_id = "bool", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local left_val = NodeRuntimeHelper.check_input(self, 2, {type_id = "object", allow_nil = true})
        local right_val = NodeRuntimeHelper.check_input(self, 3, {type_id = "object", allow_nil = true})
        local include_equal = NodeRuntimeHelper.check_bool(self, 4)

        local ok, result = pcall(function()
            if include_equal then
                return left_val >= right_val
            end
            return left_val > right_val
        end)

        if not ok then
            NodeRuntimeHelper.abort(
                self,
                string.format("比较运算在当前输入类型下无效，“%s”与“%s”不可比较",
                    NodeRuntimeHelper.describe_value_type(left_val),
                    NodeRuntimeHelper.describe_value_type(right_val)))
        end

        self._output_pin_list[2]:set_val(result)
        NodeRuntimeHelper.execute_next_node(self)
    end

    return node
end)

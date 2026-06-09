local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "round",
    icon_id = "formula",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "四舍五入",
    comment = nil,
    category = "运算与逻辑",
    category_order = 7,
    order = 6,
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
        local value = NodeRuntimeHelper.check_float(self, 2)
        local result = 0
        if value >= 0 then
            result = math.floor(value + 0.5)
        else
            result = math.ceil(value - 0.5)
        end
        self._output_pin_list[2]:set_val(result)
        NodeRuntimeHelper.execute_next_node(self)
    end

    return node
end)

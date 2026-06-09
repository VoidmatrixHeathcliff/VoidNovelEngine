local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local LogManager = Common.LogManager
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "print",
    icon_id = "terminal-box-fill",
    color = imgui.ImVec4(imgui.ImColor(243, 152, 0, 255).value),
    name = "打印到控制台",
    comment = "仅供调试模式下使用",
    category = "其他",
    category_order = 9,
    order = 4,
    menu_visible = true,
}

local print_output_leading_width <const> = 96

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    node._output_leading_width = print_output_leading_width
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "object", name = "值"})
    builder:add_output({type_id = "flow"})

    node.on_execute = function(self, scene)
        local value = NodeRuntimeHelper.check_input(self, 2, {type_id = "object", allow_nil = true})
        LogManager.log(tostring(value), "debug")
        NodeRuntimeHelper.execute_next_node(self)
    end

    return node
end)

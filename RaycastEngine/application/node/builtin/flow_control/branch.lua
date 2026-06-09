local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "branch",
    icon_id = "git-branch-fill",
    color = imgui.ImVec4(imgui.ImColor(218, 144, 97, 255).value),
    name = "分支判断",
    comment = nil,
    category = "流程控制",
    category_order = 3,
    order = 2,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "condition", type_id = "bool"})
    builder:add_output({key = "true_route", type_id = "flow", name = "真"})
    builder:add_output({key = "false_route", type_id = "flow", name = "假"})

    node.on_execute = function(self, scene)
        if NodeRuntimeHelper.check_bool(self, "condition") then
            NodeRuntimeHelper.execute_next_node(self, "true_route")
        else
            NodeRuntimeHelper.execute_next_node(self, "false_route")
        end
    end

    return node
end)

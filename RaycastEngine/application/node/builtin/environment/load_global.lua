local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local GlobalContext = Common.GlobalContext
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "load_global",
    icon_id = "inbox-unarchive-fill",
    color = imgui.ImVec4(imgui.ImColor(131, 79, 172, 255).value),
    name = "从全局环境中加载",
    comment = nil,
    category = "环境变量",
    category_order = 5,
    order = 2,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "key", type_id = "string", name = "键"})
    builder:add_output({key = "success", type_id = "flow"})
    builder:add_output({key = "failed", type_id = "flow", name = "失败"})
    builder:add_output({key = "value", type_id = "object", name = "值"})

    node.on_execute = function(self, scene)
        local key = NodeRuntimeHelper.check_string(self, "key")
        local value = GlobalContext.runtime_global_context[key]
        NodeRuntimeHelper.set_output(self, "value", value)
        if value ~= nil then
            NodeRuntimeHelper.execute_next_node(self, "success")
        else
            NodeRuntimeHelper.execute_next_node(self, "failed")
        end
    end

    return node
end)

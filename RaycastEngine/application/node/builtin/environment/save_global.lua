local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local GlobalContext = Common.GlobalContext
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "save_global",
    icon_id = "inbox-archive-fill",
    color = imgui.ImVec4(imgui.ImColor(131, 79, 172, 255).value),
    name = "存储到全局环境",
    comment = nil,
    category = "环境变量",
    category_order = 5,
    order = 1,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "string", name = "键"})
    builder:add_input({type_id = "object", name = "值"})
    builder:add_output({type_id = "flow"})

    node.on_execute = function(self, scene)
        local key = NodeRuntimeHelper.check_string(self, 2)
        local value = NodeRuntimeHelper.check_input(self, 3, {type_id = "object", allow_nil = true})
        GlobalContext.runtime_global_context[key] = value
        NodeRuntimeHelper.execute_next_node(self)
    end

    return node
end)

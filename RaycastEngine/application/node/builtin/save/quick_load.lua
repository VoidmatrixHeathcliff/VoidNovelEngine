local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper
local SaveManager = require("application.framework.save_manager")

local NodeDef =
{
    type_id = "quick_load",
    icon_id = "inbox-unarchive-fill",
    color = imgui.ImVec4(imgui.ImColor(84, 132, 219, 255).value),
    name = "快速读档",
    comment = nil,
    category = "存档系统",
    category_order = 6,
    order = 4,
    menu_visible = true,
    script =
    {
        summary = "读取快速存档并切换到目标运行时。",
        detail = "读取成功后会直接进入快速存档对应的运行时，不再从当前节点继续执行；只有失败时才会走“失败”输出。",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_output({key = "failed", type_id = "flow", name = "失败"})
    builder:add_output({key = "error_message", type_id = "string", name = "错误信息", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local ok, result = SaveManager.quick_load({source = "flow_node"})
        if ok ~= true then
            NodeRuntimeHelper.set_output(self, "error_message", tostring(result or "未知错误"))
            NodeRuntimeHelper.execute_next_node(self, "failed")
            return
        end
    end

    return node
end)

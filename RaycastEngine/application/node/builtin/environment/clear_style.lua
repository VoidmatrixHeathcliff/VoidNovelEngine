local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper
local LogManager = Common.LogManager

local StyleManager = require("application.framework.style_manager")

local NodeDef =
{
    type_id = "clear_style",
    icon_id = "delete-bin-5-line",
    color = imgui.ImVec4(imgui.ImColor(131, 79, 172, 255).value),
    name = "清空当前样式",
    comment = nil,
    category = "环境变量",
    category_order = 5,
    order = 4,
    menu_visible = true,
    script =
    {
        summary = "清空当前激活样式，回退到默认表现。",
        detail = "执行后样式管理器会移除当前覆盖样式，后续界面节点将重新使用默认配置。",
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_output({key = "out", type_id = "flow"})

    node.on_execute = function(self, scene)
        StyleManager.clear_active_style()
        LogManager.log("运行时样式已清空，后续界面节点将使用默认值或显式参数。", "info")
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

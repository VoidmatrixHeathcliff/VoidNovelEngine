local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "show_ui",
    pin_schema_version = 2,
    icon_id = "layout-3-line",
    color = imgui.ImVec4(imgui.ImColor(107, 187, 133, 255).value),
    name = "显示界面",
    comment = "显示界面后立即继续",
    category = "界面逻辑",
    category_order = 4,
    order = 0.1,
    menu_visible = true,
    script =
    {
        aliases = {"show_screen", "open_ui"},
        summary = "显示一个 .ui 界面资源，流程不会停在这里。",
        detail = "适合快捷菜单、HUD、提示层等覆盖界面。这个节点只负责把界面显示出来，显示后流程立即继续，不会自己创建存档点；如果需要等待玩家在界面里做选择或打开存档界面，请使用“调用界面”。",
        signature =
        {
            {name = "ui", pin = "ui", positional = true, required = true, doc = "要显示的界面资源。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "ui", type_id = "ui", name = "界面"})
    builder:add_output({key = "out", type_id = "flow"})

    node.on_execute = function(self, scene)
        local ui_reference = NodeRuntimeHelper.check_resource(self, "ui", "ui")
        local instance, err = scene:open_ui(ui_reference,
        {
            behavior_flow = NodeRuntimeHelper.get_current_flow_reference(self),
            global_overlay = true,
        })
        if not instance then
            NodeRuntimeHelper.abort(self, string.format("无法显示界面：%s", tostring(err or "未知错误")))
            return
        end

        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

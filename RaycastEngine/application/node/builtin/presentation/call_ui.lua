local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "call_ui",
    pin_schema_version = 2,
    icon_id = "layout-3-line",
    color = imgui.ImVec4(imgui.ImColor(107, 187, 133, 255).value),
    name = "调用界面",
    comment = "显示界面并等待关闭",
    category = "界面逻辑",
    category_order = 4,
    order = 0.2,
    menu_visible = true,
    script =
    {
        aliases = {"call_screen"},
        summary = "显示一个 .ui 界面资源，并让流程等待界面关闭。",
        detail = "适合选项界面、存档界面、确认框等需要玩家处理后再继续的界面。等待期间这是可存档等待点。",
        signature =
        {
            {name = "ui", pin = "ui", positional = true, required = true, doc = "要调用的界面资源。"},
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

    node._opened_instance_id = nil

    node.on_execute = function(self, scene)
        local ui_reference = NodeRuntimeHelper.check_resource(self, "ui", "ui")
        local instance, err = scene:open_ui(ui_reference,
        {
            behavior_flow = NodeRuntimeHelper.get_current_flow_reference(self),
        })
        if not instance then
            NodeRuntimeHelper.abort(self, string.format("无法调用界面：%s", tostring(err or "未知错误")))
            return
        end

        self._opened_instance_id = tostring(instance.id or "")
        NodeRuntimeHelper.commit_full_slice(self,
        {
            kind = "ui_call_wait",
            label = "等待界面关闭",
            node_id = self._id and self._id:get() or nil,
            node_title = self._title,
        })
    end

    node.on_execute_update = function(self, scene, delta)
        local instance_id = tostring(self._opened_instance_id or "")
        if instance_id == "" then
            return
        end
        if scene:find_ui_instance(instance_id) ~= nil then
            return
        end

        if scene.consume_closed_ui_result then
            scene:consume_closed_ui_result(instance_id)
        end
        self._opened_instance_id = nil
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    node.can_save_now = function(self, scene, runtime)
        local instance_id = tostring(self._opened_instance_id or "")
        if instance_id == "" then
            return false, "调用界面节点还没有打开有效界面"
        end
        if scene:find_ui_instance(instance_id) == nil then
            return false, "调用的界面已经关闭，即将继续执行后续流程"
        end
        return true
    end

    node.collect_runtime_save_state = function(self, scene, runtime)
        local instance_id = tostring(self._opened_instance_id or "")
        if instance_id == "" or scene:find_ui_instance(instance_id) == nil then
            return nil
        end

        return
        {
            resume_mode = "reexecute",
            managed_ui_instance_ids = {instance_id},
        }
    end

    return node
end)

local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "loop",
    pin_schema_version = 1,
    icon_id = "loop-right-fill",
    color = imgui.ImVec4(imgui.ImColor(218, 144, 97, 255).value),
    name = "循环执行",
    comment = nil,
    category = "流程控制",
    category_order = 3,
    order = 3,
    menu_visible = true,
}

local max_num_loop <const> = 10000

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "loop_again", type_id = "flow", name = "再次执行"})
    builder:add_input({key = "finish_loop", type_id = "flow", name = "结束循环"})
    builder:add_input({key = "target_loop_count", type_id = "int", name = "循环次数", default = -1})
    builder:add_output({key = "out", type_id = "flow"})
    builder:add_output({key = "loop_body", type_id = "flow", name = "循环体"})
    builder:add_output({key = "current_count", type_id = "int", name = "当前次数", options = {can_edit = false}})

    node.num_loop_completed = 0
    node.on_execute = function(self, scene, entry_pin)
        local target_num_loop = NodeRuntimeHelper.check_int(self, "target_loop_count")

        if NodeRuntimeHelper.is_entry_pin(self, "in", entry_pin) then
            self.num_loop_completed = 0
            if target_num_loop == 0 then
                NodeRuntimeHelper.execute_next_node(self, "out")
            else
                NodeRuntimeHelper.set_output(self, "current_count", 1)
                NodeRuntimeHelper.execute_next_node(self, "loop_body")
            end
            return
        end

        if NodeRuntimeHelper.is_entry_pin(self, "loop_again", entry_pin) then
            self.num_loop_completed = self.num_loop_completed + 1
            if target_num_loop > 0 and self.num_loop_completed >= target_num_loop then
                NodeRuntimeHelper.execute_next_node(self, "out")
                return
            end

            if self.num_loop_completed > max_num_loop then
                NodeRuntimeHelper.abort(self, string.format("循环超过最大次数上限[%d]，请检查循环条件", max_num_loop))
            end

            NodeRuntimeHelper.set_output(self, "current_count", self.num_loop_completed + 1)
            NodeRuntimeHelper.execute_next_node(self, "loop_body")
            return
        end

        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

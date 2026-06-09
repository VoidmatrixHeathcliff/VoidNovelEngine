local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local Timer = Common.Timer
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "delay",
    icon_id = "time-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "延迟执行",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 1,
    menu_visible = true,
    script =
    {
        aliases = {"wait"},
        summary = "延迟指定秒数后继续执行后续流程。",
        detail = "常用于控制镜头节奏、等待演出完成或为后续节点留出缓冲时间。负值会在运行时被钳制为 0。",
        signature =
        {
            {name = "seconds", pin = "seconds", positional = true, required = true, aliases = {"time"}, doc = "需要等待的秒数。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "float", name = "秒"})
    builder:add_output({type_id = "flow"})

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "seconds"
    node._input_pin_map["seconds"] = node._input_pin_list[2]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]

    node.on_execute = function(self, scene)
        local delay_seconds = NodeRuntimeHelper.check_float(self, "seconds")
        if delay_seconds < 0 then
            delay_seconds = 0
        end

        scene:add_object(Timer.new(delay_seconds, function(timer)
            NodeRuntimeHelper.execute_next_node(self, "out")
            timer:make_invalid()
        end, true), string.format("timer_%d", self._id:get()))
    end

    return node
end)

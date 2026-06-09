local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "wait_interaction",
    icon_id = "click-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "等待互动",
    comment = "鼠标左键或空格键推进流程",
    category = "演出控制",
    category_order = 1,
    order = 2,
    menu_visible = true,
    script =
    {
        summary = "等待玩家点击鼠标左键或按下空格后继续流程。",
        detail = "wait 为 false 时节点会直接继续执行，相当于把等待逻辑临时关闭。",
        signature =
        {
            {name = "wait", pin = "wait", positional = true, aliases = {"enabled"}, doc = "是否启用等待互动。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "bool", name = "等待互动"})
    builder:add_output({type_id = "flow"})

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "wait"
    node._input_pin_map["wait"] = node._input_pin_list[2]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]

    if not ctx.data then
        node._input_pin_list[2]:set_val(true)
    end

    node.on_execute_update = function(self, scene, delta)
        if NodeRuntimeHelper.check_bool(self, "wait") then
            NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
        else
            NodeRuntimeHelper.execute_next_node(self, "out")
        end
    end

    node.can_save_now = function(self, scene, runtime)
        if NodeRuntimeHelper.check_bool(self, "wait") ~= true then
            return false, "当前等待互动节点未处于等待状态"
        end
        return true
    end

    node.collect_runtime_save_state = function(self, scene, runtime)
        if NodeRuntimeHelper.check_bool(self, "wait") ~= true then
            return nil
        end

        return
        {
            resume_mode = "interaction",
            output_ref = "out",
        }
    end

    return node
end)

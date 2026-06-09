local Common = require("application.framework.builtin_node_common")

local rl = Common.rl
local imgui = Common.imgui
local Tween = Common.Tween
local ForegroundObject = Common.ForegroundObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "move_foreground",
    icon_id = "body-scan-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "移动前景图片",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 6,
    menu_visible = true,
    script =
    {
        aliases = {"fg_move", "move_fg"},
        summary = "将指定前景对象移动到目标位置。",
        detail = "通常与 add_foreground 的输出配合使用。duration 为 0 时会直接跳到目标位置，wait 控制移动完成后是否等待互动。",
        signature =
        {
            {name = "foreground", pin = "foreground", positional = true, required = true, aliases = {"target"}, doc = "要移动的前景对象。"},
            {name = "position", pin = "position", positional = true, required = true, aliases = {"target_position"}, doc = "目标位置。"},
            {name = "duration", pin = "duration", positional = true, aliases = {"time"}, doc = "移动持续时间，单位为秒。"},
            {name = "wait", pin = "wait", aliases = {"wait_interaction"}, doc = "是否在移动结束后等待玩家互动。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "object", name = "前景图片", options = {object_type = "foreground"}})
    builder:add_input({type_id = "vector2", name = "目标位置", options = {width_input = 100}})
    builder:add_input({type_id = "float", name = "时间"})
    builder:add_input({type_id = "bool", name = "等待互动"})
    builder:add_output({type_id = "flow"})

    if not ctx.data then
        node._input_pin_list[4]:set_val(0.5)
        node._input_pin_list[5]:set_val(true)
    end

    node._runtime_foreground = nil
    node._foreground_move_done = true

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "foreground"
    node._input_pin_map["foreground"] = node._input_pin_list[2]
    node._input_pin_list[3]._key = "position"
    node._input_pin_map["position"] = node._input_pin_list[3]
    node._input_pin_list[4]._key = "duration"
    node._input_pin_map["duration"] = node._input_pin_list[4]
    node._input_pin_list[5]._key = "wait"
    node._input_pin_map["wait"] = node._input_pin_list[5]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]

    node.on_execute = function(self, scene)
        local foreground_obj = NodeRuntimeHelper.check_instance(self, "foreground", ForegroundObject)
        local position = NodeRuntimeHelper.check_vector2(self, "position")
        local time = NodeRuntimeHelper.check_float(self, "duration")

        self._runtime_foreground = foreground_obj
        self._foreground_move_done = false
        foreground_obj:begin_move(rl.Vector2(position.x, position.y))
        if time > 0 then
            scene:add_object(Tween.new(foreground_obj, "move_progress", 0, 1, time, function()
                foreground_obj:on_move_complete()
                self._foreground_move_done = true
            end, "out"), string.format("tween_move_foreground_%d", self._id:get()))
        else
            foreground_obj:on_move_complete()
            self._foreground_move_done = true
        end
    end

    node.on_execute_update = function(self, scene, delta)
        if self._foreground_move_done ~= true then
            return
        end

        if NodeRuntimeHelper.check_bool(self, "wait") then
            local foreground_obj = self._runtime_foreground
            if foreground_obj and foreground_obj.move_progress >= 1 then
                NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
            end
        else
            NodeRuntimeHelper.execute_next_node(self, "out")
        end
    end

    return node
end)

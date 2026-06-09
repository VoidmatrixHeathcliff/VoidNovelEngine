local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local Tween = Common.Tween
local ForegroundObject = Common.ForegroundObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "remove_foreground",
    icon_id = "body-scan-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "删除前景图片",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 5,
    menu_visible = true,
    script =
    {
        aliases = {"fg_remove", "hide_foreground"},
        summary = "移除一个前景对象，可选淡出。",
        detail = "foreground 通常来自 add_foreground 的输出。淡出结束后对象会被标记为无效并从场景中移除。",
        signature =
        {
            {name = "foreground", pin = "foreground", positional = true, required = true, aliases = {"target"}, doc = "要移除的前景对象。"},
            {name = "fade_time", pin = "fade_time", positional = true, aliases = {"duration"}, doc = "淡出所需时间，0 表示立即移除。"},
            {name = "wait", pin = "wait", aliases = {"wait_interaction"}, doc = "是否在前景移除完成后等待玩家互动。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "object", name = "前景图片", options = {object_type = "foreground"}})
    builder:add_input({type_id = "float", name = "淡出时间"})
    builder:add_input({type_id = "bool", name = "等待互动"})
    builder:add_output({type_id = "flow"})

    if not ctx.data then
        node._input_pin_list[3]:set_val(0.5)
        node._input_pin_list[4]:set_val(true)
    end

    node._runtime_foreground = nil
    node._foreground_remove_done = true

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "foreground"
    node._input_pin_map["foreground"] = node._input_pin_list[2]
    node._input_pin_list[3]._key = "fade_time"
    node._input_pin_map["fade_time"] = node._input_pin_list[3]
    node._input_pin_list[4]._key = "wait"
    node._input_pin_map["wait"] = node._input_pin_list[4]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]

    node.on_execute = function(self, scene)
        local foreground_obj = NodeRuntimeHelper.check_instance(self, "foreground", ForegroundObject)
        local time = NodeRuntimeHelper.check_float(self, "fade_time")
        self._runtime_foreground = foreground_obj
        self._foreground_remove_done = false

        if time > 0 then
            scene:add_object(Tween.new(foreground_obj, "alpha", 1, 0, time, function()
                foreground_obj:make_invalid()
                self._foreground_remove_done = true
            end), string.format("tween_remove_foreground_%d", self._id:get()))
        else
            foreground_obj:make_invalid()
            self._foreground_remove_done = true
        end
    end

    node.on_execute_update = function(self, scene, delta)
        if self._foreground_remove_done ~= true then
            return
        end

        if NodeRuntimeHelper.check_bool(self, "wait") then
            local foreground_obj = self._runtime_foreground
            if foreground_obj and foreground_obj.alpha <= 0 then
                NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
            end
        else
            NodeRuntimeHelper.execute_next_node(self, "out")
        end
    end

    return node
end)

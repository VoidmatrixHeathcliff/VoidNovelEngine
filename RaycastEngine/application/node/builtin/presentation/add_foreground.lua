local Common = require("application.framework.builtin_node_common")

local rl = Common.rl
local imgui = Common.imgui
local Tween = Common.Tween
local ForegroundObject = Common.ForegroundObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local foreground_z_idx <const> = 10

local NodeDef =
{
    type_id = "add_foreground",
    pin_schema_version = 2,
    icon_id = "body-scan-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "添加前景图片",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 4,
    menu_visible = true,
    script =
    {
        aliases = {"fg_add", "show_foreground"},
        summary = "向场景中添加一张前景图片对象。",
        detail = "适合立绘、特写图层或前景特效。节点会输出创建出的 foreground 对象，供后续移动或移除节点继续操作。",
        signature =
        {
            {name = "texture", pin = "texture", positional = true, required = true, doc = "前景所使用的纹理资源。"},
            {name = "shader", pin = "shader", doc = "可选前景着色器资源；为空时走样式 shader.foreground。"},
            {name = "scale", pin = "scale", doc = "前景缩放倍率。"},
            {name = "position", pin = "position", doc = "前景初始位置。"},
            {name = "fade_time", pin = "fade_time", aliases = {"duration"}, doc = "淡入所需秒数。"},
            {name = "wait", pin = "wait", aliases = {"wait_interaction"}, doc = "是否在前景完全显示后等待玩家互动。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "float", name = "缩放"})
    builder:add_input({type_id = "vector2", name = "位置", options = {width_input = 100}})
    builder:add_input({type_id = "texture", name = "纹理"})
    builder:add_input({type_id = "float", name = "淡入时间"})
    builder:add_input({type_id = "bool", name = "等待互动"})
    builder:add_input({type_id = "shader", name = "着色器"})
    builder:add_output({type_id = "flow"})
    builder:add_output({type_id = "object", name = "前景图片", options = {object_type = "foreground"}})

    if not ctx.data then
        node._input_pin_list[2]:set_val(1)
        node._input_pin_list[5]:set_val(0.5)
        node._input_pin_list[6]:set_val(true)
    end

    local object_id <const> = string.format("bp-foreground-%d", node._id:get())

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "scale"
    node._input_pin_map["scale"] = node._input_pin_list[2]
    node._input_pin_list[3]._key = "position"
    node._input_pin_map["position"] = node._input_pin_list[3]
    node._input_pin_list[4]._key = "texture"
    node._input_pin_map["texture"] = node._input_pin_list[4]
    node._input_pin_list[5]._key = "fade_time"
    node._input_pin_map["fade_time"] = node._input_pin_list[5]
    node._input_pin_list[6]._key = "wait"
    node._input_pin_map["wait"] = node._input_pin_list[6]
    node._input_pin_list[7]._key = "shader"
    node._input_pin_map["shader"] = node._input_pin_list[7]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]
    node._output_pin_list[2]._key = "foreground"
    node._output_pin_map["foreground"] = node._output_pin_list[2]
    node._foreground_add_done = true

    node.on_execute = function(self, scene)
        local scale = NodeRuntimeHelper.check_float(self, "scale")
        local position = NodeRuntimeHelper.check_vector2(self, "position")
        local texture = NodeRuntimeHelper.check_resource(self, "texture", "texture")
        local duration_fade_in = NodeRuntimeHelper.check_float(self, "fade_time")
        local texture_pin = self._input_pin_map["texture"] or self._input_pin_list[4]
        local texture_reference = texture_pin.get_reference and texture_pin:get_reference() or nil
        local shader_pin = self._input_pin_map["shader"] or self._input_pin_list[7]
        local shader_reference = shader_pin and shader_pin.get_reference and shader_pin:get_reference() or nil

        local foreground_obj = ForegroundObject.new(
            texture,
            rl.Vector2(position.x, position.y),
            scale,
            texture_reference,
            nil,
            shader_reference)

        if not rawget(foreground_obj, "texture") then
            NodeRuntimeHelper.abort(self, "无效的纹理对象输入")
        end

        scene:add_object(foreground_obj, object_id, foreground_z_idx)
        NodeRuntimeHelper.set_output(self, "foreground", foreground_obj)
        self._foreground_add_done = false

        if duration_fade_in > 0 then
            scene:add_object(Tween.new(foreground_obj, "alpha", 0, 1, duration_fade_in, function()
                foreground_obj:on_fade_in_complete()
                self._foreground_add_done = true
            end), string.format("tween_add_foreground_%d", self._id:get()))
            return
        end

        foreground_obj:on_fade_in_complete()
        self._foreground_add_done = true
    end

    node.on_execute_update = function(self, scene, delta)
        if self._foreground_add_done ~= true then
            return
        end

        local wait_interaction = NodeRuntimeHelper.check_bool(self, "wait")
        if wait_interaction then
            local foreground_obj = scene:find_object(object_id)
            if foreground_obj and foreground_obj.alpha == 1 then
                NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
            end
        else
            NodeRuntimeHelper.execute_next_node(self, "out")
        end
    end

    return node
end)

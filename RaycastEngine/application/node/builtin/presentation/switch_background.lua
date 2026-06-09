local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local Tween = Common.Tween
local BackgroundObject = Common.BackgroundObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "switch_background",
    pin_schema_version = 2,
    icon_id = "image-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "切换背景图片",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 3,
    menu_visible = true,
    script =
    {
        aliases = {"bg"},
        summary = "切换当前背景图，可选淡入过渡并等待玩家推进。",
        detail = "常用于场景切换、镜头转场和章节开场。若淡入时间为 0 会立即完成切换，wait 决定是否在切换完成后等待互动再继续执行。",
        signature =
        {
            {name = "texture", pin = "texture", positional = true, required = true, aliases = {"background"}, doc = "目标背景纹理资源。"},
            {name = "shader", pin = "shader", doc = "可选背景着色器资源；为空时走样式 shader.background。"},
            {name = "fade_time", pin = "fade_time", aliases = {"duration"}, doc = "背景淡入所需秒数，0 表示立即切换。"},
            {name = "wait", pin = "wait", aliases = {"wait_interaction"}, doc = "是否在背景切换完成后等待玩家互动再继续流程。"},
        },
        default_flow_output = "out",
    },
}

local object_id <const> = "bp-background"
local tween_object_id <const> = "tween_switch_background"
local default_fit_mode <const> = "stretch"

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "texture", name = "纹理"})
    builder:add_input({type_id = "float", name = "淡入时间"})
    builder:add_input({type_id = "bool", name = "等待互动"})
    builder:add_input({type_id = "shader", name = "着色器"})
    builder:add_output({type_id = "flow"})

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "texture"
    node._input_pin_map["texture"] = node._input_pin_list[2]
    node._input_pin_list[3]._key = "fade_time"
    node._input_pin_map["fade_time"] = node._input_pin_list[3]
    node._input_pin_list[4]._key = "wait"
    node._input_pin_map["wait"] = node._input_pin_list[4]
    node._input_pin_list[5]._key = "shader"
    node._input_pin_map["shader"] = node._input_pin_list[5]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]
    node._background_switch_done = true
    node._background_switch_token = nil

    if not ctx.data then
        node._input_pin_list[3]:set_val(1)
        node._input_pin_list[4]:set_val(true)
    end

    node.on_execute = function(self, scene)
        local texture_pin = self._input_pin_list[2]
        local shader_pin = self._input_pin_map["shader"] or self._input_pin_list[5]
        local texture = NodeRuntimeHelper.check_resource(self, "texture", "texture")
        local texture_reference = texture_pin.get_reference and texture_pin:get_reference() or nil
        local shader_reference = shader_pin and shader_pin.get_reference and shader_pin:get_reference() or nil
        local background_obj = scene:find_object(object_id)
        if not background_obj then
            background_obj = BackgroundObject.new()
            scene:add_object(background_obj, object_id, 0)
        end

        scene:del_object(tween_object_id)
        local switch_token = (tonumber(background_obj._switch_background_token) or 0) + 1
        background_obj._switch_background_token = switch_token
        self._background_switch_token = switch_token
        self._background_switch_done = false

        background_obj:set_next_texture(texture, texture_reference, default_fit_mode)
        background_obj:set_next_shader_reference(shader_reference)
        if not rawget(background_obj, "texture_next") then
            NodeRuntimeHelper.abort(self, "无效的纹理对象输入")
        end

        background_obj.alpha_next = 0
        local duration_fade_in = NodeRuntimeHelper.check_float(self, "fade_time")
        if duration_fade_in > 0 then
            scene:add_object(Tween.new(background_obj, "alpha_next", 0, 1, duration_fade_in, function()
                if background_obj._switch_background_token == switch_token then
                    background_obj:on_fade_in_complete()
                end
                self._background_switch_done = true
            end), tween_object_id)
        else
            background_obj:on_fade_in_complete()
            self._background_switch_done = true
        end
    end

    node.on_execute_update = function(self, scene, delta)
        if self._background_switch_done ~= true then
            local background_obj = scene:find_object(object_id)
            if background_obj and background_obj._switch_background_token == self._background_switch_token then
                return
            end
            self._background_switch_done = true
        end

        if NodeRuntimeHelper.check_bool(self, "wait") then
            NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
        else
            NodeRuntimeHelper.execute_next_node(self, "out")
        end
    end

    return node
end)

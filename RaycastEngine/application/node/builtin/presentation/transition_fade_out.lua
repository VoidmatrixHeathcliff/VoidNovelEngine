local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local Tween = Common.Tween
local TransitionFadeObject = Common.TransitionFadeObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "transition_fade_out",
    icon_id = "slideshow-2-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "淡出转场",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 14,
    menu_visible = true,
}

local object_id <const> = "bp-transition-fade"
local tween_object_id <const> = "tween_transition_fade"

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "float", name = "时间"})
    builder:add_input({type_id = "bool", name = "等待互动"})
    builder:add_output({type_id = "flow"})

    if not ctx.data then
        node._input_pin_list[2]:set_val(1)
    end
    node._transition_done = true

    node.on_execute = function(self, scene)
        local transition_fade_obj = scene:find_object(object_id)
        if not transition_fade_obj then
            transition_fade_obj = TransitionFadeObject.new()
            scene:add_object(transition_fade_obj, object_id, 100)
        end

        scene:del_object(tween_object_id)
        transition_fade_obj.alpha = 0
        self._transition_done = false
        local duration_fade = NodeRuntimeHelper.check_float(self, 2)
        if duration_fade > 0 then
            scene:add_object(Tween.new(transition_fade_obj, "alpha", 0, 1, duration_fade, function()
                transition_fade_obj:on_fade_out_complete()
                self._transition_done = true
            end), tween_object_id)
        else
            transition_fade_obj:on_fade_out_complete()
            self._transition_done = true
        end
    end

    node.on_execute_update = function(self, scene, delta)
        if self._transition_done ~= true then
            return
        end

        if NodeRuntimeHelper.check_bool(self, 3) then
            local transition_fade_obj = scene:find_object(object_id)
            if transition_fade_obj and transition_fade_obj.alpha == 1 then
                NodeRuntimeHelper.wait_interact_to_next_node(self)
            end
        else
            NodeRuntimeHelper.execute_next_node(self)
        end
    end

    return node
end)

local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local Tween = Common.Tween
local LetterboxingObject = Common.LetterboxingObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "show_letterboxing",
    icon_id = "film-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示宽银幕遮罩",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 7,
    menu_visible = true,
}

local object_id <const> = "bp-letterboxing"
local tween_object_id <const> = "tween_letterboxing"

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "float", name = "高度"})
    builder:add_input({type_id = "float", name = "缓入时间"})
    builder:add_input({type_id = "bool", name = "等待互动"})
    builder:add_output({type_id = "flow"})

    if not ctx.data then
        node._input_pin_list[2]:set_val(200)
        node._input_pin_list[3]:set_val(1.5)
    end
    node._letterboxing_done = true

    node.on_execute = function(self, scene)
        local letterboxing = scene:find_object(object_id)
        if not letterboxing then
            letterboxing = LetterboxingObject.new()
            scene:add_object(letterboxing, object_id, 80)
        end

        letterboxing.full_height = NodeRuntimeHelper.check_float(self, 2)
        scene:del_object(tween_object_id)
        self._letterboxing_done = false
        local duration_ease = NodeRuntimeHelper.check_float(self, 3)
        if duration_ease > 0 then
            scene:add_object(Tween.new(letterboxing, "progress", 0, 1, duration_ease, function()
                letterboxing:on_show_complete()
                self._letterboxing_done = true
            end, "out"), tween_object_id)
        else
            letterboxing:on_show_complete()
            self._letterboxing_done = true
        end
    end

    node.on_execute_update = function(self, scene, delta)
        if self._letterboxing_done ~= true then
            return
        end

        if NodeRuntimeHelper.check_bool(self, 4) then
            local letterboxing = scene:find_object(object_id)
            if letterboxing and letterboxing.progress == 1 then
                NodeRuntimeHelper.wait_interact_to_next_node(self)
            end
        else
            NodeRuntimeHelper.execute_next_node(self)
        end
    end

    return node
end)

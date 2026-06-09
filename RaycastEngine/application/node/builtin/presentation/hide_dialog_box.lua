local Common = require("application.framework.builtin_node_common")
local PresentationUIBridge = require("application.framework.presentation_ui_bridge")

local imgui = Common.imgui
local Billboard = Common.Billboard
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "hide_dialog_box",
    icon_id = "text-block",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "隐藏对话框",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 12,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "dialog_box", type_id = "object", name = "对话框", options = {object_type = "dialog_box"}})
    builder:add_input({key = "fade_out_time", type_id = "float", name = "淡出时间", default = 1, style_binding = {domain = "dialog_box", field = "fade_out_time"}})
    builder:add_input({key = "wait_interaction", type_id = "bool", name = "等待互动", default = true})
    builder:add_output({key = "out", type_id = "flow"})

    if not ctx.data then
        node._input_pin_list[3]:set_val(1)
        node._input_pin_list[4]:set_val(true)
    end

    node._runtime_dialog_box = nil
    node._ui_backend_active = false
    node._ui_instance_id = nil
    node._ui_hide_time = 0
    node._ui_hide_elapsed = 0

    node.on_execute = function(self, scene)
        local time = NodeRuntimeHelper.check_float(self, "fade_out_time")
        self._ui_backend_active = false
        self._ui_instance_id = nil
        self._ui_hide_time = math.max(0, time)
        self._ui_hide_elapsed = 0

        local value = NodeRuntimeHelper.get_input_pin(self, "dialog_box"):get_val()
        if type(value) == "table" and value.widget_by_id and value.id then
            self._runtime_dialog_box = value
            self._ui_backend_active = true
            self._ui_instance_id = value.id
            if self._ui_hide_time <= 0 then
                scene:close_ui(self._ui_instance_id)
            end
            return
        end

        local dialog_box = NodeRuntimeHelper.check_instance(self, "dialog_box", Billboard)
        self._runtime_dialog_box = dialog_box
        dialog_box:hide(self._ui_hide_time)
    end

    node.on_execute_update = function(self, scene, delta)
        if self._ui_backend_active then
            local instance = self._ui_instance_id and scene:find_ui_instance(self._ui_instance_id) or nil
            if instance and self._ui_hide_time > 0 then
                self._ui_hide_elapsed = math.min(self._ui_hide_time, self._ui_hide_elapsed + delta)
                PresentationUIBridge.set_instance_opacity(instance, 1 - self._ui_hide_elapsed / self._ui_hide_time)
                if self._ui_hide_elapsed >= self._ui_hide_time then
                    scene:close_ui(self._ui_instance_id)
                end
            end

            local finished = self._ui_instance_id == nil or scene:find_ui_instance(self._ui_instance_id) == nil
            if NodeRuntimeHelper.check_bool(self, "wait_interaction") then
                if finished then
                    NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
                end
            elseif finished then
                NodeRuntimeHelper.execute_next_node(self, "out")
            end
            return
        end

        local dialog_box = self._runtime_dialog_box
        if dialog_box and dialog_box._progress == 0 then
            if NodeRuntimeHelper.check_bool(self, "wait_interaction") then
                NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
            else
                NodeRuntimeHelper.execute_next_node(self, "out")
            end
        end
    end

    return node
end)

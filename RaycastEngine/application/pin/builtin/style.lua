local Common = require("application.framework.builtin_pin_common")

local imgui = Common.imgui
local StyleAdapterFactory = Common.StyleAdapterFactory

local BlueprintPin = Common.BlueprintPin
local LogManager = Common.LogManager
local UndoManager = Common.UndoManager

local ResourceIndex = require("application.framework.resource_index")
local ResourceReferenceField = require("application.framework.resource_reference_field")
local resource_field_default_width <const> = 140

local function _clone_reference(value)
    if type(value) ~= "table" then
        return nil
    end
    return
    {
        guid = value.guid,
        path_hint = value.path_hint,
    }
end

local function _same_reference(left, right)
    if left == nil and right == nil then
        return true
    end
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    return tostring(left.guid or "") == tostring(right.guid or "")
        and tostring(left.path_hint or "") == tostring(right.path_hint or "")
end

return Common.make_definition({
    type_id = "style",
    display_name = "样式资产",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_resource_adapter("style"),
    runtime =
    {
        validate = function(value, opts)
            local reference = ResourceIndex.make_reference("style", value)
            if not reference then
                return false, nil,
                {
                    code = "resource_unset",
                    expected_type_id = "style",
                    expected_display_name = "样式资源",
                }
            end

            if ResourceIndex.resolve_guid("style", reference) == nil then
                return false, nil,
                {
                    code = "resource_unavailable",
                    expected_type_id = "style",
                    expected_display_name = "样式资源",
                    issue = "样式资源不存在",
                }
            end

            return true, reference
        end,
    }
}, function(pin, ctx)
    local id = ctx.pin_id
    local extra_args = ctx.options
    local _base_load = function(self, data)
        return BlueprintPin.on_load(self, data)
    end
    local _base_save = function(self)
        return BlueprintPin.on_save(self)
    end

    pin._resource_ref = nil
    pin._width_input = extra_args and extra_args.width_input or resource_field_default_width

    pin._apply_value = function(self, value)
        self._resource_ref = ResourceIndex.make_reference("style", value)
    end

    pin._record_change = function(self, value)
        local old_ref = _clone_reference(self._resource_ref)
        local new_ref = ResourceIndex.make_reference("style", value)
        if _same_reference(old_ref, new_ref) then
            return false
        end
        self._resource_ref = new_ref
        UndoManager.record(function(data)
                self._resource_ref = _clone_reference(data.old_ref)
            end,
            function(data)
                self._resource_ref = _clone_reference(data.new_ref)
            end,
            {
                old_ref = old_ref,
                new_ref = _clone_reference(new_ref),
            })
        return true
    end

    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            local selected_value, changed, invalid_payload = ResourceReferenceField.draw(
            {
                popup_id = string.format("style_pin_picker_%s", id),
                asset_type = "style",
                value = self._resource_ref,
                width = self:get_widget_input_width(self._width_input),
                disabled = not self._is_output and self._linked_pin_id ~= nil,
                allow_clear = true,
                use_node_editor_overlay = true,
            })
            if invalid_payload then
                LogManager.log(string.format("错误的引脚赋值类型，使用“%s”类型资源为“style”类型引脚赋值", invalid_payload.type), "warning")
            elseif changed then
                self:_record_change(selected_value)
            end
        imgui.EndDisabled()
    end

    pin.on_load = function(self, data)
        _base_load(self, data)
        self:_apply_value(data.val)
    end

    pin.on_save = function(self)
        local data = _base_save(self)
        -- SAVE TRACE: concrete style pin appends a cloned resource reference as val.
        data.val = _clone_reference(self._resource_ref)
        return data
    end

    pin.set_val = function(self, value)
        self:_apply_value(value)
    end

    pin.get_reference = function(self)
        if self._is_output then
            return _clone_reference(self._resource_ref)
        end
        if self._linked_pin_id then
            local linked_pin = self:_resolve_runtime_source_pin()
            if linked_pin and linked_pin.get_reference then
                return linked_pin:get_reference()
            end
            return nil
        end
        return _clone_reference(self._resource_ref)
    end

    pin.get_val = function(self)
        local reference = self:get_reference()
        return self:_resolve_runtime_input_value(reference)
    end
end)

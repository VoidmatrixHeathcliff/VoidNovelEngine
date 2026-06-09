local Common = require("application.framework.builtin_pin_common")

local imgui = Common.imgui
local StyleAdapterFactory = Common.StyleAdapterFactory

local BlueprintPin = Common.BlueprintPin
local UndoManager = Common.UndoManager

return Common.make_definition({
    type_id = "int",
    display_name = "整数",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_int_adapter(),
    runtime =
    {
        validate = function(value, opts)
            if value == nil then
                if opts and opts.allow_nil then
                    return true, nil
                end
                return false, nil, {code = "nil_value"}
            end
            if type(value) ~= "number" then
                return false, nil, {code = "type_mismatch", actual_type = type(value)}
            end
            if value ~= value or value == math.huge or value == -math.huge then
                return false, nil, {code = "number_not_finite", actual_type = "number"}
            end
            local integer = math.tointeger(value)
            if integer == nil then
                return false, nil, {code = "int_non_integral", actual_type = "number", actual_value = value}
            end
            return true, integer
        end,
    },
    can_accept = function(input_pin, output_pin)
        if output_pin._type_id == "float" then
            return true
        end
    end
}, function(pin, ctx)
    local id = ctx.pin_id
    local extra_args = ctx.options
    local _base_load = function(self, data)
        return BlueprintPin.on_load(self, data)
    end
    local _base_save = function(self)
        return BlueprintPin.on_save(self)
    end

    pin._int = imgui.Int(0)
    pin._prev_val = pin._int.val
    pin._width_input = 100
    if extra_args then
        pin._width_input = extra_args.width_input or pin._width_input
    end
    pin._can_edit = true
    if extra_args and extra_args.can_edit ~= nil then
        pin._can_edit = extra_args.can_edit
    end

    if pin._can_edit then
        pin._on_tick_widgets = function(self)
            imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
                imgui.SetNextItemWidth(self:get_widget_input_width(self._width_input))
                imgui.InputInt("##int" .. id, self._int)
                if imgui.IsItemDeactivatedAfterEdit() then
                    local next_value = pin._int.val
                    if next_value == pin._prev_val then
                        imgui.EndDisabled()
                        return
                    end
                    local old_style_override = pin:has_style_local_override()
                    UndoManager.record(function(data)
                            pin._int.val = data.old
                            pin._prev_val = data.old
                            pin:set_style_local_override(data.old_style_override)
                        end,
                        function(data)
                            pin._int.val = data.new
                            pin._prev_val = data.new
                            pin:set_style_local_override(data.new_style_override)
                        end,
                        {
                            old = pin._prev_val,
                            new = next_value,
                            old_style_override = old_style_override,
                            new_style_override = true,
                        })
                    pin._prev_val = next_value
                    pin:set_style_local_override(true)
                end
            imgui.EndDisabled()
        end
    end

    pin.on_load = function(self, data)
        _base_load(self, data)
        self._int.val = data.val
        self._prev_val = data.val
    end

    pin.on_save = function(self)
        local data = _base_save(self)
        -- SAVE TRACE: concrete int pin appends its editable value.
        data.val = self._int.val
        return data
    end

    pin.set_val = function(self, val)
        self._int.val = val
        self._prev_val = val
    end

    pin.get_val = function(self)
        return self:_resolve_runtime_input_value(self._int.val)
    end
end)

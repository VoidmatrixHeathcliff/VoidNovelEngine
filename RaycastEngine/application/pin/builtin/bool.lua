local Common = require("application.framework.builtin_pin_common")

local imgui = Common.imgui
local StyleAdapterFactory = Common.StyleAdapterFactory

local BlueprintPin = Common.BlueprintPin
local UndoManager = Common.UndoManager

return Common.make_definition({
    type_id = "bool",
    display_name = "布尔值",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_bool_adapter(),
    runtime =
    {
        validate = function(value, opts)
            if value == nil then
                if opts and opts.allow_nil then
                    return true, nil
                end
                return false, nil, {code = "nil_value"}
            end
            if type(value) == "boolean" then
                return true, value
            end
            return false, nil, {code = "type_mismatch", actual_type = type(value)}
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

    pin._bool = imgui.Bool(false)
    pin._prev_val = pin._bool.val
    pin._layout_widget_width = 22
    pin._can_edit = true
    if extra_args and extra_args.can_edit ~= nil then
        pin._can_edit = extra_args.can_edit
    end

    if pin._can_edit then
        pin._on_tick_widgets = function(self)
            imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
                if imgui.Checkbox("##bool" .. id, self._bool) then
                    local old_value = pin._prev_val
                    local new_value = pin._bool.val
                    if old_value == new_value then
                        imgui.EndDisabled()
                        return
                    end
                    local old_style_override = pin:has_style_local_override()
                    pin:set_style_local_override(true)
                    UndoManager.record(function(data)
                            data.pin._bool.val = data.old
                            data.pin._prev_val = data.old
                            data.pin:set_style_local_override(data.old_style_override)
                        end,
                        function(data)
                            data.pin._bool.val = data.new
                            data.pin._prev_val = data.new
                            data.pin:set_style_local_override(data.new_style_override)
                        end,
                        {
                            pin = pin,
                            old = old_value,
                            new = new_value,
                            old_style_override = old_style_override,
                            new_style_override = true,
                        })
                    pin._prev_val = new_value
                end
            imgui.EndDisabled()
        end
    end

    pin.on_load = function(self, data)
        _base_load(self, data)
        self._bool.val = data.val
        self._prev_val = data.val
    end

    pin.on_save = function(self)
        local data = _base_save(self)
        -- SAVE TRACE: concrete bool pin appends its editable value.
        data.val = self._bool.val
        return data
    end

    pin.set_val = function(self, val)
        self._bool.val = val
        self._prev_val = val
    end

    pin.get_val = function(self)
        return self:_resolve_runtime_input_value(self._bool.val)
    end
end)

local Common = require("application.framework.builtin_pin_common")

local imgui = Common.imgui
local StyleAdapterFactory = Common.StyleAdapterFactory

local BlueprintPin = Common.BlueprintPin
local UndoManager = Common.UndoManager

local function _same_color(left, right)
    local left_value = left and left.value or nil
    local right_value = right and right.value or nil
    return left_value and right_value
        and left_value.x == right_value.x
        and left_value.y == right_value.y
        and left_value.z == right_value.z
        and left_value.w == right_value.w
end

return Common.make_definition({
    type_id = "color",
    display_name = "颜色",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_color_adapter(),
    runtime =
    {
        validate = function(value, opts)
            if value == nil then
                if opts and opts.allow_nil then
                    return true, nil
                end
                return false, nil, {code = "nil_value"}
            end

            local x = value.x or value.r
            local y = value.y or value.g
            local z = value.z or value.b
            local w = value.w or value.a
            if type(x) == "number" and type(y) == "number" and type(z) == "number" and type(w) == "number" then
                return true, imgui.ImVec4(x, y, z, w)
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

    pin._val_color = imgui.ImColor(0, 0, 0, 255)
    pin._prev_color = imgui.ImColor(pin._val_color)
    pin._full_edit = false
    if extra_args then
        pin._full_edit = extra_args.full_edit or pin._full_edit
    end
    pin._layout_widget_width = pin._full_edit and 200 or 132

    pin._on_tick_widgets = function(self)
        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            local flag = imgui.ColorEditFlags.NoTooltip
                | imgui.ColorEditFlags.NoOptions
                | imgui.ColorEditFlags.NoPicker
                | imgui.ColorEditFlags.AlphaBar
            if not self._full_edit then
                imgui.SetNextItemWidth(self:get_widget_input_width(132))
                imgui.ColorEdit4("##color" .. id, self._val_color, flag)
            else
                imgui.SetNextItemWidth(self:get_widget_input_width(200))
                imgui.ColorPicker4("##color" .. id, self._val_color, flag)
            end
            if imgui.IsItemDeactivatedAfterEdit() then
                if _same_color(pin._val_color, pin._prev_color) then
                    imgui.EndDisabled()
                    return
                end
                local old_style_override = pin:has_style_local_override()
                UndoManager.record(function(data)
                        pin._val_color = data.old
                        pin._prev_color = imgui.ImColor(pin._val_color)
                        pin:set_style_local_override(data.old_style_override)
                    end,
                    function(data)
                        pin._val_color = data.new
                        pin._prev_color = imgui.ImColor(pin._val_color)
                        pin:set_style_local_override(data.new_style_override)
                    end,
                    {
                        old = imgui.ImColor(pin._prev_color),
                        new = imgui.ImColor(pin._val_color),
                        old_style_override = old_style_override,
                        new_style_override = true,
                    })
                pin._prev_color = imgui.ImColor(pin._val_color)
                pin:set_style_local_override(true)
            end
        imgui.EndDisabled()
    end

    pin.on_load = function(self, data)
        _base_load(self, data)
        self._val_color.value.x = data.val.r
        self._val_color.value.y = data.val.g
        self._val_color.value.z = data.val.b
        self._val_color.value.w = data.val.a
        self._prev_color = imgui.ImColor(self._val_color)
    end

    pin.on_save = function(self)
        local data = _base_save(self)
        -- SAVE TRACE: concrete color pin appends val.r/g/b/a.
        data.val =
        {
            r = pin._val_color.value.x,
            g = pin._val_color.value.y,
            b = pin._val_color.value.z,
            a = pin._val_color.value.w,
        }
        return data
    end

    pin.set_val = function(self, val)
        self._val_color = imgui.ImColor(val)
        self._prev_color = imgui.ImColor(self._val_color)
    end

    pin.get_val = function(self)
        return self:_resolve_runtime_input_value(self._val_color.value)
    end
end)

local Common = require("application.framework.builtin_pin_common")

local imgui = Common.imgui
local StyleAdapterFactory = Common.StyleAdapterFactory

local BlueprintPin = Common.BlueprintPin
local UndoManager = Common.UndoManager

local function _same_vec2(left, right)
    return left and right and left.x == right.x and left.y == right.y
end

return Common.make_definition({
    type_id = "vector2",
    display_name = "二维向量",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_vector2_adapter(),
    runtime =
    {
        validate = function(value, opts)
            if value == nil then
                if opts and opts.allow_nil then
                    return true, nil
                end
                return false, nil, {code = "nil_value"}
            end

            local x = value.x
            local y = value.y
            if type(x) == "number" and type(y) == "number" then
                return true, imgui.ImVec2(x, y)
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

    pin._val = imgui.ImVec2(0, 0)
    pin._prev_val = imgui.ImVec2(pin._val)
    pin._width_input = 50
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
                imgui.InputFloat2("##vector2" .. id, self._val, nil, nil)
                if imgui.IsItemDeactivatedAfterEdit() then
                    if _same_vec2(pin._val, pin._prev_val) then
                        imgui.EndDisabled()
                        return
                    end
                    local old_style_override = pin:has_style_local_override()
                    UndoManager.record(function(data)
                            pin._val = data.old
                            pin._prev_val = imgui.ImVec2(pin._val)
                            pin:set_style_local_override(data.old_style_override)
                        end,
                        function(data)
                            pin._val = data.new
                            pin._prev_val = imgui.ImVec2(pin._val)
                            pin:set_style_local_override(data.new_style_override)
                        end,
                        {
                            old = imgui.ImVec2(pin._prev_val),
                            new = imgui.ImVec2(pin._val),
                            old_style_override = old_style_override,
                            new_style_override = true,
                        })
                    pin._prev_val = imgui.ImVec2(pin._val)
                    pin:set_style_local_override(true)
                end
            imgui.EndDisabled()
        end
    end

    pin.on_load = function(self, data)
        _base_load(self, data)
        self._val.x = data.val.x
        self._val.y = data.val.y
        self._prev_val = imgui.ImVec2(self._val)
    end

    pin.on_save = function(self)
        local data = _base_save(self)
        -- SAVE TRACE: concrete vector2 pin appends val.x and val.y.
        data.val = {x = self._val.x, y = self._val.y}
        return data
    end

    pin.set_val = function(self, val)
        self._val = imgui.ImVec2(val)
        self._prev_val = imgui.ImVec2(self._val)
    end

    pin.get_val = function(self)
        return self:_resolve_runtime_input_value(self._val)
    end
end)

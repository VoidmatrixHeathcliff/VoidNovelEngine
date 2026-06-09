local Common = require("application.framework.builtin_pin_common")

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local imgui = Common.imgui

return Common.make_definition({
    type_id = "object",
    display_name = "对象",
    icon_type = imgui.NodeEditor.IconType.Circle,
    runtime =
    {
        validate = function(value, opts)
            if value == nil then
                if opts and opts.allow_nil then
                    return true, nil
                end
                return false, nil, {code = "nil_value"}
            end

            local is_game_object = false
            local class_ok, class_result = pcall(Class.is_instance, value, GameObject)
            if class_ok then
                is_game_object = class_result == true
            end
            if is_game_object
                and ((value.is_valid and value:is_valid() ~= true)
                    or (value.is_destroyed and value:is_destroyed() == true))
            then
                return false, nil,
                {
                    code = "runtime_object_stale",
                    actual_type = type(value),
                    actual_class_name = Class.get_class_name(value),
                }
            end

            if opts and opts.class and not Class.is_instance(value, opts.class) then
                return false, nil,
                {
                    code = "instance_mismatch",
                    actual_type = type(value),
                    actual_class_name = Class.get_class_name(value),
                }
            end

            return true, value
        end,
    },
    can_accept = function(input_pin, output_pin)
        return output_pin._type_id ~= "flow"
    end,
    can_connect_to = function(input_pin, output_pin)
        return input_pin._type_id ~= "flow"
    end
}, function(pin, ctx)
    pin.set_val = function(self, val)
        self._val = val
    end

    pin.get_val = function(self)
        return self:_resolve_runtime_input_value(self._val)
    end
end)

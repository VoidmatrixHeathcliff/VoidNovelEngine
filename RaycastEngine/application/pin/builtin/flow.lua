local Common = require("application.framework.builtin_pin_common")

local imgui = Common.imgui

return Common.make_definition({
    type_id = "flow",
    display_name = "流程",
    icon_type = imgui.NodeEditor.IconType.Flow,
    runtime =
    {
        validate = function()
            return false, nil, {code = "flow_value_forbidden"}
        end,
    }
}, function(pin, ctx)
    -- flow 引脚不暴露数据取值语义。
end)

local Common = require("application.framework.builtin_pin_common")
local ResourcePinHelper = require("application.framework.resource_pin_helper")

local imgui = Common.imgui
local ResourcesManager = Common.ResourcesManager
local StyleAdapterFactory = Common.StyleAdapterFactory

return Common.make_definition({
    type_id = "shader",
    display_name = "着色器资产",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_resource_adapter("shader"),
    runtime =
    {
        validate = ResourcePinHelper.make_runtime_validator("shader"),
    }
}, function(pin, ctx)
    ResourcePinHelper.setup(pin, ctx, "shader", function(reference)
        return ResourcesManager.find_shader(reference)
    end)
end)

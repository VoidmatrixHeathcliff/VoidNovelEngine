local Common = require("application.framework.builtin_pin_common")
local ResourcePinHelper = require("application.framework.resource_pin_helper")

local imgui = Common.imgui
local ResourcesManager = Common.ResourcesManager
local StyleAdapterFactory = Common.StyleAdapterFactory

return Common.make_definition({
    type_id = "font",
    display_name = "字体资产",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_resource_adapter("font"),
    runtime =
    {
        validate = ResourcePinHelper.make_runtime_validator("font"),
    }
}, function(pin, ctx)
    ResourcePinHelper.setup(pin, ctx, "font", function(reference)
        return ResourcesManager.find_font(reference)
    end)
end)

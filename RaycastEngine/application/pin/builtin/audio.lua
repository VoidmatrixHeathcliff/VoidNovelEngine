local Common = require("application.framework.builtin_pin_common")
local ResourcePinHelper = require("application.framework.resource_pin_helper")

local imgui = Common.imgui
local ResourcesManager = Common.ResourcesManager
local StyleAdapterFactory = Common.StyleAdapterFactory

return Common.make_definition({
    type_id = "audio",
    display_name = "音频资产",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_resource_adapter("audio"),
    runtime =
    {
        validate = ResourcePinHelper.make_runtime_validator("audio"),
    }
}, function(pin, ctx)
    ResourcePinHelper.setup(pin, ctx, "audio", function(reference)
        return ResourcesManager.find_audio(reference)
    end)
end)

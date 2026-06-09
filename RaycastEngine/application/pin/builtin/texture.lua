local Common = require("application.framework.builtin_pin_common")
local ResourcePinHelper = require("application.framework.resource_pin_helper")

local sdl = Common.sdl
local imgui = Common.imgui
local ResourcesManager = Common.ResourcesManager
local StyleAdapterFactory = Common.StyleAdapterFactory

local function _describe_texture_issue(pin, reference)
    if not reference then
        return nil
    end

    if ResourcesManager.get_texture_preview(reference, "editor_preview") == nil then
        return "当前纹理资源不可用"
    end

    return nil
end

return Common.make_definition({
    type_id = "texture",
    display_name = "纹理资产",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_resource_adapter("texture"),
    runtime =
    {
        validate = ResourcePinHelper.make_runtime_validator("texture", _describe_texture_issue),
    }
}, function(pin, ctx)
    ResourcePinHelper.setup(pin, ctx, "texture", function(reference)
        return ResourcesManager.find_texture(reference)
    end, function(self, reference)
        self._preview_texture = self._preview_texture or nil
        self._preview_texture_token = self._preview_texture_token or nil
        self._preview_texture_guid = self._preview_texture_guid or nil
        self._preview_texture_info = self._preview_texture_info or nil

        if not reference then
            self._preview_texture = nil
            self._preview_texture_token = nil
            self._preview_texture_guid = nil
            self._preview_texture_info = nil
            return
        end

        local texture = ResourcesManager.get_texture_preview(reference, "editor_preview")
        if not texture then
            self._preview_texture = nil
            self._preview_texture_token = nil
            self._preview_texture_guid = nil
            self._preview_texture_info = nil
            return
        end

        local guid = self._resource_ref and self._resource_ref.guid or nil
        local texture_token = tostring(texture)
        if self._preview_texture ~= texture
            or self._preview_texture_token ~= texture_token
            or self._preview_texture_guid ~= guid
            or self._preview_texture_info == nil then
            self._preview_texture = texture
            self._preview_texture_token = texture_token
            self._preview_texture_guid = guid
            self._preview_texture_info = sdl.QueryTexture(texture)
        end

        local info = self._preview_texture_info
        local pos_begin = imgui.GetCursorPos()
        local preview_width = self:get_widget_input_width(self._width_input)
        local scale = preview_width / info.w
        local size_image = imgui.ImVec2(info.w * scale, info.h * scale)
        imgui.SetCursorPos(pos_begin)
        imgui.Image(texture, size_image, nil, nil, nil, imgui.ImColor(255, 255, 255, 100).value)
    end, function(self, reference)
        return _describe_texture_issue(self, reference)
    end)
end)

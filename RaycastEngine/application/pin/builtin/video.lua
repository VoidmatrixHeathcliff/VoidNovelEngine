local Common = require("application.framework.builtin_pin_common")
local ResourcePinHelper = require("application.framework.resource_pin_helper")

local sdl = Common.sdl
local imgui = Common.imgui
local GlobalContext = Common.GlobalContext
local ResourcesManager = Common.ResourcesManager
local StyleAdapterFactory = Common.StyleAdapterFactory

local function _describe_video_issue(pin, reference)
    if not reference then
        return nil
    end

    local meta = ResourcesManager.find_meta(reference, "video")
    if not meta then
        return "无效的资源引用"
    end

    local status = ResourcesManager.get_video_import_status(reference)
    if not status then
        return nil
    end

    if type(status.last_error) == "string" and status.last_error ~= "" then
        return status.last_error
    end

    local compatibility = status.compatibility or {}
    if compatibility.wmf_runtime_ready == false then
        local reason = compatibility.reason
        if type(reason) == "string" and reason ~= "" then
            return reason
        end
        return "当前视频资源不可用"
    end

    local runtime_entry = status.runtime_entry or {}
    local artifact = status.transcode_artifact or {}
    if runtime_entry.mode == "artifact" and artifact.exists ~= true then
        return "缺少视频转码产物"
    end

    return nil
end

return Common.make_definition({
    type_id = "video",
    display_name = "视频资产",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_resource_adapter("video"),
    runtime =
    {
        validate = ResourcePinHelper.make_runtime_validator("video", _describe_video_issue),
    }
}, function(pin, ctx)
    local extra_args = ctx.options or {}
    local show_preview = extra_args.show_preview == true

    ResourcePinHelper.setup(pin, ctx, "video", function(reference)
        return ResourcesManager.find_video(reference)
    end, show_preview and function(self, reference)
        self._preview_texture = self._preview_texture or nil
        self._preview_texture_token = self._preview_texture_token or nil
        self._preview_texture_guid = self._preview_texture_guid or nil
        self._preview_texture_info = self._preview_texture_info or nil
        self._preview_failure_guid = self._preview_failure_guid or nil
        self._preview_failure_revision = self._preview_failure_revision or nil

        local guid = type(reference) == "table" and reference.guid or nil
        local revision = tonumber(GlobalContext.resource_index_revision) or 0
        if not guid then
            self._preview_texture = nil
            self._preview_texture_token = nil
            self._preview_texture_guid = nil
            self._preview_texture_info = nil
            self._preview_failure_guid = nil
            self._preview_failure_revision = nil
            return
        end

        if self._preview_failure_guid == guid and self._preview_failure_revision == revision then
            return
        end

        local ok, texture = pcall(ResourcesManager.get_video_preview, reference, "editor_preview")
        if not ok or not texture then
            self._preview_texture = nil
            self._preview_texture_token = nil
            self._preview_texture_guid = nil
            self._preview_texture_info = nil
            self._preview_failure_guid = guid
            self._preview_failure_revision = revision
            return
        end

        self._preview_failure_guid = nil
        self._preview_failure_revision = nil

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
        if not info or not info.w or not info.h or info.w <= 0 or info.h <= 0 then
            return
        end

        local pos_begin = imgui.GetCursorPos()
        local preview_width = self:get_widget_input_width(self._width_input)
        local scale = preview_width / info.w
        local size_image = imgui.ImVec2(info.w * scale, info.h * scale)
        imgui.SetCursorPos(pos_begin)
        imgui.Image(texture, size_image, nil, nil, nil, imgui.ImColor(255, 255, 255, 100).value)
    end or nil, function(self, reference)
        return _describe_video_issue(self, reference)
    end)
end)

local rl = Engine.Raylib

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local ColorHelper = require("application.framework.color_helper")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local RuntimeLayout = require("application.framework.runtime_layout_context")
local ShaderRuntime = require("application.framework.shader_runtime")

local VideoRendererObject = Class.define("VideoRenderer", GameObject)

local function _release_keepalive(self, field_name)
    local ticket = rawget(self, field_name)
    if ticket then
        ResourcesManager.release_keepalive(ticket)
        self[field_name] = nil
    end
end

function VideoRendererObject:ctor(decoder, on_finished, on_error, shader_reference)
    Class.call_super(VideoRendererObject, self, "ctor")
    self._decoder = decoder
    self._on_finished = on_finished
    self._on_error = on_error
    self._shader_reference = nil
    self._shader_ticket = nil
    self:set_shader_reference(shader_reference)
end

function VideoRendererObject:set_shader_reference(reference)
    _release_keepalive(self, "_shader_ticket")
    local normalized_reference = ResourceIndex.make_reference("shader", reference)
    self._shader_reference = normalized_reference
    if normalized_reference then
        self._shader_ticket = ResourcesManager.acquire_keepalive(normalized_reference,
            string.format("video_shader_%s", tostring(self)), "runtime", "shader")
    end
end

function VideoRendererObject:on_render()
    rl.ClearBackground(ColorHelper.BLACK)
    if not self._decoder or not self._decoder.texture or self._decoder.width <= 0 or self._decoder.height <= 0 then
        return
    end
    local width_screen, height_screen = RuntimeLayout.get_canvas_size()
    local scale = math.min(width_screen / self._decoder.width, height_screen / self._decoder.height)
    local rect_dst = rl.Rectangle((width_screen - (self._decoder.width * scale)) * 0.5,
        (height_screen - (self._decoder.height * scale)) * 0.5, self._decoder.width * scale, self._decoder.height * scale)
    local rect_src = rl.Rectangle(0, 0, self._decoder.width, self._decoder.height)
    ShaderRuntime.draw_with_shader(ShaderRuntime.resolve_layer_shader("video", self._shader_reference), function()
        rl.DrawTexturePro(self._decoder.texture, rect_src, rect_dst, rl.Vector2(0, 0), 0, ColorHelper.WHITE)
    end,
    {
        layer = "video",
        texture = self._decoder.texture,
        texture_width = self._decoder.width,
        texture_height = self._decoder.height,
        resolution_width = width_screen,
        resolution_height = height_screen,
        alpha = 1,
    })
end

function VideoRendererObject:on_update(delta)
    self._decoder:on_update(delta)
    if self._decoder.has_error then
        self:make_invalid()
        if self._on_error then
            self._on_error(self._decoder.error_message)
        end
        return
    end
    if self._decoder.has_finished then
        self:make_invalid()
        if self._on_finished then self._on_finished() end
    end
end

function VideoRendererObject:on_destroy()
    _release_keepalive(self, "_shader_ticket")
    if self._decoder and self._decoder.close then
        self._decoder:close()
        self._decoder = nil
    end
end

return VideoRendererObject

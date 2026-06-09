local rl = Engine.Raylib

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local ColorHelper = require("application.framework.color_helper")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local RuntimeLayout = require("application.framework.runtime_layout_context")
local ShaderRuntime = require("application.framework.shader_runtime")

local BackgroundObject = Class.define("BackgroundObject", GameObject)

local fit_mode_pool =
{
    stretch = true,
    cover = true,
    contain = true,
    center = true,
}

local function _normalize_fit_mode(value)
    local mode = type(value) == "string" and value:match("^%s*(.-)%s*$") or nil
    if not mode or mode == "" or not fit_mode_pool[mode] then
        return "stretch"
    end
    return mode
end

local function _release_keepalive(self, field_name)
    local ticket = rawget(self, field_name)
    if ticket then
        ResourcesManager.release_keepalive(ticket)
        self[field_name] = nil
    end
end

local function _apply_texture_slot(self, slot_name, ticket_field_name, texture, reference)
    _release_keepalive(self, ticket_field_name)
    self[slot_name] = texture
    if reference then
        self[ticket_field_name] = ResourcesManager.acquire_keepalive(reference,
            string.format("background_%s_%s", slot_name, tostring(self)), "runtime", "texture")
    end
end

local function _apply_shader_slot(self, reference_field_name, ticket_field_name, reference)
    _release_keepalive(self, ticket_field_name)
    local normalized_reference = ResourceIndex.make_reference("shader", reference)
    self[reference_field_name] = normalized_reference
    if normalized_reference then
        self[ticket_field_name] = ResourcesManager.acquire_keepalive(normalized_reference,
            string.format("background_shader_%s_%s", reference_field_name, tostring(self)), "runtime", "shader")
    end
end

local function _resolve_destination_rect(texture, fit_mode)
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    if not texture or (tonumber(texture.width) or 0) <= 0 or (tonumber(texture.height) or 0) <= 0 then
        return rl.Rectangle(0, 0, canvas_width, canvas_height)
    end

    if fit_mode == "cover" or fit_mode == "contain" then
        local scale_x = canvas_width / texture.width
        local scale_y = canvas_height / texture.height
        local scale = fit_mode == "cover" and math.max(scale_x, scale_y) or math.min(scale_x, scale_y)
        local width = texture.width * scale
        local height = texture.height * scale
        return rl.Rectangle((canvas_width - width) * 0.5, (canvas_height - height) * 0.5, width, height)
    end

    if fit_mode == "center" then
        return rl.Rectangle(
            (canvas_width - texture.width) * 0.5,
            (canvas_height - texture.height) * 0.5,
            texture.width,
            texture.height)
    end

    return rl.Rectangle(0, 0, canvas_width, canvas_height)
end

function BackgroundObject:ctor()
    Class.call_super(BackgroundObject, self, "ctor")
    self.alpha_next = 0
    self.texture_prev = nil
    self.texture_next = nil
    self._texture_prev_ticket = nil
    self._texture_next_ticket = nil
    self._texture_prev_reference = nil
    self._texture_next_reference = nil
    self._shader_prev_ticket = nil
    self._shader_next_ticket = nil
    self._shader_prev_reference = nil
    self._shader_next_reference = nil
    self.fit_mode = "stretch"
    self._fit_mode_prev = "stretch"
    self._fit_mode_next = "stretch"
end

function BackgroundObject:set_prev_texture(texture, reference, fit_mode)
    _apply_texture_slot(self, "texture_prev", "_texture_prev_ticket", texture, reference)
    self._texture_prev_reference = reference
    if fit_mode ~= nil then
        self._fit_mode_prev = _normalize_fit_mode(fit_mode)
        self.fit_mode = self._fit_mode_prev
    end
end

function BackgroundObject:set_next_texture(texture, reference, fit_mode)
    _apply_texture_slot(self, "texture_next", "_texture_next_ticket", texture, reference)
    self._texture_next_reference = reference
    if fit_mode ~= nil then
        self._fit_mode_next = _normalize_fit_mode(fit_mode)
    end
end

function BackgroundObject:set_prev_shader_reference(reference)
    _apply_shader_slot(self, "_shader_prev_reference", "_shader_prev_ticket", reference)
end

function BackgroundObject:set_next_shader_reference(reference)
    _apply_shader_slot(self, "_shader_next_reference", "_shader_next_ticket", reference)
end

function BackgroundObject:set_fit_mode(fit_mode)
    local mode = _normalize_fit_mode(fit_mode)
    self.fit_mode = mode
    self._fit_mode_prev = mode
    self._fit_mode_next = mode
end

function BackgroundObject:on_render()
    local origin <const> = rl.Vector2(0, 0)
    local prev_fit_mode = _normalize_fit_mode(self._fit_mode_prev or self.fit_mode)
    local next_fit_mode = _normalize_fit_mode(self._fit_mode_next or self.fit_mode)
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    if rawget(self, "texture_prev") then
        local rect_dst <const> = _resolve_destination_rect(self.texture_prev, prev_fit_mode)
        ShaderRuntime.draw_with_shader(ShaderRuntime.resolve_layer_shader("background", self._shader_prev_reference), function()
            rl.DrawTexturePro(self.texture_prev, rl.Rectangle(0, 0, self.texture_prev.width, self.texture_prev.height),
                rect_dst, origin, 0, ColorHelper.WHITE)
        end,
        {
            layer = "background",
            texture = self.texture_prev,
            texture_width = self.texture_prev.width,
            texture_height = self.texture_prev.height,
            resolution_width = canvas_width,
            resolution_height = canvas_height,
            alpha = 1,
        })
    end
    if rawget(self, "texture_next") then
        local rect_dst <const> = _resolve_destination_rect(self.texture_next, next_fit_mode)
        ShaderRuntime.draw_with_shader(ShaderRuntime.resolve_layer_shader("background", self._shader_next_reference), function()
            rl.DrawTexturePro(self.texture_next, rl.Rectangle(0, 0, self.texture_next.width, self.texture_next.height),
                rect_dst, origin, 0, rl.Color(255, 255, 255, math.floor(255 * self.alpha_next)))
        end,
        {
            layer = "background",
            texture = self.texture_next,
            texture_width = self.texture_next.width,
            texture_height = self.texture_next.height,
            resolution_width = canvas_width,
            resolution_height = canvas_height,
            alpha = self.alpha_next,
        })
    end
end

function BackgroundObject:on_fade_in_complete()
    _release_keepalive(self, "_texture_prev_ticket")
    _release_keepalive(self, "_shader_prev_ticket")
    self.texture_prev = self.texture_next
    self._texture_prev_ticket = self._texture_next_ticket
    self._texture_prev_reference = self._texture_next_reference
    self._shader_prev_ticket = self._shader_next_ticket
    self._shader_prev_reference = self._shader_next_reference
    self._fit_mode_prev = _normalize_fit_mode(self._fit_mode_next or self._fit_mode_prev or self.fit_mode)
    self.fit_mode = self._fit_mode_prev
    self.texture_next = nil
    self._texture_next_ticket = nil
    self._texture_next_reference = nil
    self._shader_next_ticket = nil
    self._shader_next_reference = nil
    self._fit_mode_next = self._fit_mode_prev
    self.alpha_next = 1
end

function BackgroundObject:collect_save_state()
    local prev_fit_mode = _normalize_fit_mode(self._fit_mode_prev or self.fit_mode)
    local next_fit_mode = _normalize_fit_mode(self._fit_mode_next or prev_fit_mode)
    return
    {
        type = "BackgroundObject",
        prev_texture = self._texture_prev_reference,
        next_texture = self._texture_next_reference,
        shader = self._shader_prev_reference,
        prev_shader = self._shader_prev_reference,
        next_shader = self._shader_next_reference,
        alpha_next = self.alpha_next,
        fit_mode = prev_fit_mode,
        fit_mode_prev = prev_fit_mode,
        fit_mode_next = next_fit_mode,
    }
end

function BackgroundObject:apply_save_state(state)
    local snapshot = type(state) == "table" and state or {}
    local legacy_fit_mode = snapshot.fit_mode
    local prev_fit_mode = _normalize_fit_mode(snapshot.fit_mode_prev or legacy_fit_mode)
    local next_fit_mode = _normalize_fit_mode(snapshot.fit_mode_next or legacy_fit_mode or prev_fit_mode)
    self.alpha_next = tonumber(snapshot.alpha_next) or 0
    self:set_prev_texture(ResourcesManager.find_texture(snapshot.prev_texture), snapshot.prev_texture, prev_fit_mode)
    self:set_next_texture(ResourcesManager.find_texture(snapshot.next_texture), snapshot.next_texture, next_fit_mode)
    self:set_prev_shader_reference(snapshot.prev_shader or snapshot.shader)
    self:set_next_shader_reference(snapshot.next_shader)
end

function BackgroundObject.create_from_save_state(state)
    local object = BackgroundObject.new()
    object:apply_save_state(state)
    return object
end

function BackgroundObject:on_destroy()
    _release_keepalive(self, "_texture_prev_ticket")
    _release_keepalive(self, "_texture_next_ticket")
    _release_keepalive(self, "_shader_prev_ticket")
    _release_keepalive(self, "_shader_next_ticket")
end

return BackgroundObject

local rl = Engine.Raylib

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local RuntimeLayout = require("application.framework.runtime_layout_context")
local ShaderRuntime = require("application.framework.shader_runtime")

local ForegroundObject = Class.define("ForegroundObject", GameObject)

local coordinate_space_pool =
{
    design = true,
    canvas = true,
    normalized = true,
}

local anchor_pool =
{
    top_left = {x = 0, y = 0},
    top_center = {x = 0.5, y = 0},
    top_right = {x = 1, y = 0},
    center_left = {x = 0, y = 0.5},
    center = {x = 0.5, y = 0.5},
    center_right = {x = 1, y = 0.5},
    bottom_left = {x = 0, y = 1},
    bottom_center = {x = 0.5, y = 1},
    bottom_right = {x = 1, y = 1},
}

local fit_mode_pool =
{
    none = true,
    fit_width = true,
    fit_height = true,
    contain = true,
}

local function _trim(value)
    if type(value) ~= "string" then
        return nil
    end
    local text = value:match("^%s*(.-)%s*$")
    if text == "" then
        return nil
    end
    return text
end

local function _normalize_coordinate_space(value, fallback)
    local mode = _trim(value) or fallback or "design"
    if not coordinate_space_pool[mode] then
        return fallback or "design"
    end
    return mode
end

local function _normalize_anchor(value, fallback)
    local anchor = _trim(value) or fallback or "top_left"
    if not anchor_pool[anchor] then
        return fallback or "top_left"
    end
    return anchor
end

local function _normalize_fit_mode(value, fallback)
    local mode = _trim(value) or fallback or "none"
    if not fit_mode_pool[mode] then
        return fallback or "none"
    end
    return mode
end

local function _resolve_anchor_vector(anchor)
    local value = anchor_pool[_normalize_anchor(anchor)]
    return value.x, value.y
end

local function _resolve_pivot_vector(pivot)
    if type(pivot) == "table" then
        return tonumber(pivot.x) or tonumber(pivot[1]) or 0, tonumber(pivot.y) or tonumber(pivot[2]) or 0
    end
    return _resolve_anchor_vector(pivot)
end

local function _normalize_design_size(layout)
    local default_width, default_height = RuntimeLayout.get_design_size()
    return
        math.max(1, tonumber(layout and layout.design_width) or default_width),
        math.max(1, tonumber(layout and layout.design_height) or default_height)
end

local function _release_keepalive(self, field_name)
    local ticket = rawget(self, field_name)
    if ticket then
        ResourcesManager.release_keepalive(ticket)
        self[field_name] = nil
    end
end

function ForegroundObject:ctor(texture, position, scale, texture_reference, layout, shader_reference)
    Class.call_super(ForegroundObject, self, "ctor")
    self.alpha = 0
    self.scale = scale or 1
    self.texture = texture
    self.position = position or rl.Vector2(0, 0)
    self.move_progress = 1
    self.src_position = nil
    self.dst_position = nil
    self._texture_ticket = nil
    self._texture_reference = texture_reference
    self._shader_ticket = nil
    self._shader_reference = nil
    self.layout_schema_version = 2
    self.coordinate_space = "design"
    self.anchor = "top_left"
    self.pivot = "top_left"
    self.fit_mode = "none"
    self.design_width, self.design_height = RuntimeLayout.get_design_size()
    self:set_layout(layout)
    if texture_reference then
        self._texture_ticket = ResourcesManager.acquire_keepalive(texture_reference,
            string.format("foreground_texture_%s", tostring(self)), "runtime", "texture")
    end
    self:set_shader_reference(shader_reference)
end

function ForegroundObject:set_shader_reference(reference)
    _release_keepalive(self, "_shader_ticket")
    local normalized_reference = ResourceIndex.make_reference("shader", reference)
    self._shader_reference = normalized_reference
    if normalized_reference then
        self._shader_ticket = ResourcesManager.acquire_keepalive(normalized_reference,
            string.format("foreground_shader_%s", tostring(self)), "runtime", "shader")
    end
end

function ForegroundObject:set_layout(layout, options)
    layout = type(layout) == "table" and layout or {}
    options = type(options) == "table" and options or {}

    local keep_existing = options.keep_existing == true
    self.coordinate_space = _normalize_coordinate_space(layout.coordinate_space,
        keep_existing and self.coordinate_space or "design")
    self.anchor = _normalize_anchor(layout.anchor, keep_existing and self.anchor or "top_left")
    self.pivot = _normalize_anchor(layout.pivot, keep_existing and self.pivot or "top_left")
    self.fit_mode = _normalize_fit_mode(layout.fit_mode, keep_existing and self.fit_mode or "none")

    local design_width, design_height = _normalize_design_size(layout)
    if keep_existing and (layout.design_width == nil or layout.design_height == nil) then
        self.design_width = self.design_width or design_width
        self.design_height = self.design_height or design_height
    else
        self.design_width = design_width
        self.design_height = design_height
    end
end

function ForegroundObject:begin_move(dst_position)
    self.move_progress = 0
    self.src_position = rl.Vector2(self.position.x, self.position.y)
    self.dst_position = rl.Vector2(dst_position.x, dst_position.y)
end

function ForegroundObject:on_update(delta)
    if self.move_progress >= 1 or not self.src_position or not self.dst_position then
        return
    end
    self.position.x = math.lerp(self.src_position.x, self.dst_position.x, self.move_progress)
    self.position.y = math.lerp(self.src_position.y, self.dst_position.y, self.move_progress)
end

function ForegroundObject:_resolve_layout_offset()
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    local position = self.position or rl.Vector2(0, 0)
    local coordinate_space = _normalize_coordinate_space(self.coordinate_space)

    if coordinate_space == "canvas" then
        return position.x, position.y, canvas_width, canvas_height
    end
    if coordinate_space == "normalized" then
        return position.x * canvas_width, position.y * canvas_height, canvas_width, canvas_height
    end

    local default_design_width, default_design_height = RuntimeLayout.get_design_size()
    local design_width = math.max(1, tonumber(self.design_width) or default_design_width)
    local design_height = math.max(1, tonumber(self.design_height) or default_design_height)
    return position.x * canvas_width / design_width, position.y * canvas_height / design_height, canvas_width, canvas_height
end

function ForegroundObject:_resolve_render_scale(canvas_width, canvas_height)
    local scale = tonumber(self.scale) or 1
    local fit_mode = _normalize_fit_mode(self.fit_mode)

    if rawget(self, "texture") then
        if fit_mode == "fit_width" then
            scale = scale * canvas_width / math.max(1, self.texture.width)
        elseif fit_mode == "fit_height" then
            scale = scale * canvas_height / math.max(1, self.texture.height)
        elseif fit_mode == "contain" then
            scale = scale * math.min(canvas_width / math.max(1, self.texture.width), canvas_height / math.max(1, self.texture.height))
        elseif _normalize_coordinate_space(self.coordinate_space) == "design" then
            scale = scale * math.max(0.001, RuntimeLayout.scale_uniform(1))
        end
    end

    return scale
end

function ForegroundObject:_canvas_offset_to_position(offset_x, offset_y, canvas_width, canvas_height)
    local coordinate_space = _normalize_coordinate_space(self.coordinate_space)
    canvas_width = math.max(1, tonumber(canvas_width) or 1)
    canvas_height = math.max(1, tonumber(canvas_height) or 1)

    if coordinate_space == "canvas" then
        return rl.Vector2(offset_x, offset_y)
    end
    if coordinate_space == "normalized" then
        return rl.Vector2(offset_x / canvas_width, offset_y / canvas_height)
    end

    local default_design_width, default_design_height = RuntimeLayout.get_design_size()
    local design_width = math.max(1, tonumber(self.design_width) or default_design_width)
    local design_height = math.max(1, tonumber(self.design_height) or default_design_height)
    return rl.Vector2(offset_x * design_width / canvas_width, offset_y * design_height / canvas_height)
end

function ForegroundObject:_resolve_render_transform()
    local offset_x, offset_y, canvas_width, canvas_height = self:_resolve_layout_offset()
    local anchor_x, anchor_y = _resolve_anchor_vector(self.anchor)
    local pivot_x, pivot_y = _resolve_pivot_vector(self.pivot)
    local scale = self:_resolve_render_scale(canvas_width, canvas_height)

    local texture_width = rawget(self, "texture") and self.texture.width or 0
    local texture_height = rawget(self, "texture") and self.texture.height or 0
    local x = canvas_width * anchor_x + offset_x - texture_width * scale * pivot_x
    local y = canvas_height * anchor_y + offset_y - texture_height * scale * pivot_y
    return x, y, scale
end

function ForegroundObject:get_render_top_left()
    local x, y, scale = self:_resolve_render_transform()
    return x, y, scale
end

function ForegroundObject:set_position_from_render_top_left(x, y)
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    local anchor_x, anchor_y = _resolve_anchor_vector(self.anchor)
    local pivot_x, pivot_y = _resolve_pivot_vector(self.pivot)
    local scale = self:_resolve_render_scale(canvas_width, canvas_height)
    local texture_width = rawget(self, "texture") and self.texture.width or 0
    local texture_height = rawget(self, "texture") and self.texture.height or 0
    local offset_x = (tonumber(x) or 0) + texture_width * scale * pivot_x - canvas_width * anchor_x
    local offset_y = (tonumber(y) or 0) + texture_height * scale * pivot_y - canvas_height * anchor_y
    self.position = self:_canvas_offset_to_position(offset_x, offset_y, canvas_width, canvas_height)
end

function ForegroundObject:on_render()
    if not rawget(self, "texture") then
        return
    end

    local x, y, scale = self:_resolve_render_transform()
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    ShaderRuntime.draw_with_shader(ShaderRuntime.resolve_layer_shader("foreground", self._shader_reference), function()
        rl.DrawTextureEx(self.texture, rl.Vector2(x, y), 0, scale,
            rl.Color(255, 255, 255, math.floor(255 * self.alpha)))
    end,
    {
        layer = "foreground",
        texture = self.texture,
        texture_width = self.texture.width,
        texture_height = self.texture.height,
        resolution_width = canvas_width,
        resolution_height = canvas_height,
        alpha = self.alpha,
    })
end

function ForegroundObject:on_fade_in_complete()
    self.alpha = 1
end

function ForegroundObject:on_move_complete()
    if self.dst_position then
        self.position = self.dst_position
    end
    self.move_progress = 1
end

function ForegroundObject:on_destroy()
    _release_keepalive(self, "_texture_ticket")
    _release_keepalive(self, "_shader_ticket")
end

function ForegroundObject:collect_save_state()
    return
    {
        type = "ForegroundObject",
        texture = self._texture_reference,
        shader = self._shader_reference,
        position =
        {
            x = self.position and self.position.x or 0,
            y = self.position and self.position.y or 0,
        },
        scale = self.scale,
        alpha = self.alpha,
        move_progress = self.move_progress,
        layout_schema_version = 2,
        coordinate_space = _normalize_coordinate_space(self.coordinate_space),
        anchor = _normalize_anchor(self.anchor),
        pivot = _normalize_anchor(self.pivot),
        fit_mode = _normalize_fit_mode(self.fit_mode),
        design_width = self.design_width,
        design_height = self.design_height,
    }
end

function ForegroundObject:apply_save_state(state)
    local snapshot = type(state) == "table" and state or {}
    _release_keepalive(self, "_texture_ticket")
    self._texture_reference = snapshot.texture
    self.texture = ResourcesManager.find_texture(snapshot.texture)
    if self._texture_reference then
        self._texture_ticket = ResourcesManager.acquire_keepalive(self._texture_reference,
            string.format("foreground_texture_%s", tostring(self)), "runtime", "texture")
    end
    self:set_shader_reference(snapshot.shader)
    self.position = rl.Vector2(
        snapshot.position and tonumber(snapshot.position.x) or 0,
        snapshot.position and tonumber(snapshot.position.y) or 0)
    self.scale = tonumber(snapshot.scale) or 1
    self.alpha = tonumber(snapshot.alpha) or 0
    self.move_progress = tonumber(snapshot.move_progress) or 1
    self.layout_schema_version = tonumber(snapshot.layout_schema_version) or 1
    self:set_layout(
    {
        coordinate_space = snapshot.coordinate_space,
        anchor = snapshot.anchor,
        pivot = snapshot.pivot,
        fit_mode = snapshot.fit_mode,
        design_width = snapshot.design_width,
        design_height = snapshot.design_height,
    })
    self.src_position = nil
    self.dst_position = nil
end

function ForegroundObject.create_from_save_state(state)
    local object = ForegroundObject.new(nil, rl.Vector2(0, 0), 1, nil)
    object:apply_save_state(state)
    return object
end

return ForegroundObject

local sdl = Engine.SDL
local rl = Engine.Raylib

local Class = require("application.framework.class")
local Tween = require("application.framework.tween")
local GameObject = require("application.framework.game_object")
local GlobalContext = require("application.framework.global_context")
local TextWrapper = require("application.framework.text_wrapper")
local ResourcesManager = require("application.framework.resources_manager")
local RuntimeLayout = require("application.framework.runtime_layout_context")

local padding <const> = 15

local Billboard = Class.define("DialogBox", GameObject)

local function _get_padding()
    return math.max(8, RuntimeLayout.round(RuntimeLayout.scale_uniform(padding)))
end

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

local function _normalize_text(value)
    local text = tostring(value or "")
    if text == "" then
        return " "
    end
    return text
end

local function _read_number_field(value, key)
    if type(value) ~= "table" and type(value) ~= "userdata" then
        return nil
    end
    local ok, result = pcall(function()
        return value[key]
    end)
    if not ok then
        return nil
    end
    return tonumber(result)
end

local function _clamp_color_channel(value, default)
    local number = tonumber(value)
    if number == nil then
        number = default or 0
    end
    number = math.floor(number + 0.5)
    if number < 0 then return 0 end
    if number > 255 then return 255 end
    return number
end

local function _to_color_table(value, fallback)
    local source = value
    if type(source) ~= "table" and type(source) ~= "userdata" then
        source = fallback
    end
    local r = _read_number_field(source, "r") or _read_number_field(source, "x")
    local g = _read_number_field(source, "g") or _read_number_field(source, "y")
    local b = _read_number_field(source, "b") or _read_number_field(source, "z")
    local a = _read_number_field(source, "a") or _read_number_field(source, "w")
    local normalized = r ~= nil and g ~= nil and b ~= nil and a ~= nil
        and r <= 1 and g <= 1 and b <= 1 and a <= 1
    if normalized then
        r, g, b, a = r * 255, g * 255, b * 255, a * 255
    end
    return
    {
        r = _clamp_color_channel(r, 255),
        g = _clamp_color_channel(g, 255),
        b = _clamp_color_channel(b, 255),
        a = _clamp_color_channel(a, 255),
    }
end

local function _make_rect(x, y, w, h)
    return
    {
        x = x,
        y = y,
        w = w,
        h = h,
    }
end

local function _draw_texture_fill(texture, rect, alpha)
    if not texture or not rect or rect.w <= 0 or rect.h <= 0 then
        return false
    end

    local texture_width = math.max(1, tonumber(texture.width) or 1)
    local texture_height = math.max(1, tonumber(texture.height) or 1)
    local tint = rl.Color(255, 255, 255, math.floor(255 * math.max(0, math.min(1, tonumber(alpha) or 1)) + 0.5))
    rl.DrawTexturePro(
        texture,
        rl.Rectangle(0, 0, texture_width, texture_height),
        rl.Rectangle(rect.x, rect.y, rect.w, rect.h),
        rl.Vector2(0, 0),
        0,
        tint)
    return true
end

local function _resolve_background_texture(reference)
    return reference and ResourcesManager.find_texture(reference) or nil
end

local function _dispose_text(self)
    if self._text_name and self._text_name.dispose then
        self._text_name:dispose()
        self._text_name = nil
    end
    if self._text_dialogue and self._text_dialogue.dispose then
        self._text_dialogue:dispose()
        self._text_dialogue = nil
    end
end

local function _layout_dialog(self, x, y)
    self._x, self._y = RuntimeLayout.resolve_dialog_position(x, y)
end

function Billboard:ctor(name, dialogue, x, y, width, font_name, font_dialog, color_name, color_dialog, color_bg, time, background_image_reference, font_name_size, font_dialog_size)
    Class.call_super(Billboard, self, "ctor")
    name = _normalize_text(name)
    dialogue = _normalize_text(dialogue)

    local pad = _get_padding()
    self._raw_x = x
    self._raw_y = y
    self._raw_width = width
    self._width = RuntimeLayout.resolve_dialog_width(width)
    self._text_name = TextWrapper.new(font_name, name, color_name, nil, font_name_size)
    self._text_dialogue = TextWrapper.new(font_dialog, dialogue, color_dialog, math.max(1, self._width - pad * 2), font_dialog_size)
    self._height = self._text_name.h + self._text_dialogue.h + pad * 3
    _layout_dialog(self, x, y)
    self._tween = Tween.new(self, "_progress", 0, 1, time, nil, "out")
    self._progress = 0
    self._color_bg = color_bg
    self._background_image_reference = _clone_value(background_image_reference)
    self._background_texture = _resolve_background_texture(self._background_image_reference)
    self._save_state =
    {
        name = name,
        dialogue = dialogue,
        layout_schema_version = 2,
        design_width = 1920,
        design_height = 1080,
        x = x,
        y = y,
        width = width,
        role_font_reference = nil,
        dialogue_font_reference = nil,
        role_font_size = nil,
        dialogue_font_size = nil,
        role_color = _to_color_table(color_name),
        dialogue_color = _to_color_table(color_dialog),
        background_color = _to_color_table(color_bg, {r = 0, g = 0, b = 0, a = 128}),
        background_image_reference = _clone_value(background_image_reference),
    }
end

function Billboard:hide(time)
    self._tween = Tween.new(self, "_progress", 1, 0, time, function()
        self:make_invalid()
    end, "out")
end

function Billboard:on_update(delta)
    if self._tween then
        self._tween:on_update(delta)
    end
end

function Billboard:on_render()
    local pad = _get_padding()
    local background_rect = _make_rect(self._x, self._y, self._width * self._progress, self._height * self._progress)
    if self._background_texture then
        _draw_texture_fill(self._background_texture, background_rect, self._progress)
    else
        rl.DrawRectangleV(rl.Vector2(self._x, self._y), rl.Vector2(background_rect.w, background_rect.h),
            rl.Color(self._color_bg.r, self._color_bg.g, self._color_bg.b, math.floor(self._color_bg.a * self._progress)))
    end
    local color_hint = rl.Color(255, 255, 255, math.floor(255 * self._progress))
    if self._text_name and self._text_name.texture then
        rl.DrawTextureV(self._text_name.texture, rl.Vector2(self._x + pad, self._y + pad), color_hint)
    end
    local role_height = self._text_name and tonumber(self._text_name.h) or 0
    if self._text_dialogue and self._text_dialogue.texture then
        rl.DrawTextureV(self._text_dialogue.texture, rl.Vector2(self._x + pad, self._y + pad * 2 + role_height), color_hint)
    end
end

function Billboard:on_destroy()
    _dispose_text(self)
end

function Billboard:set_runtime_save_data(data)
    if type(data) ~= "table" then
        return
    end
    self._save_state = _clone_value(data)
    self._save_state.name = _normalize_text(self._save_state.name)
    self._save_state.dialogue = _normalize_text(self._save_state.dialogue)
    self._save_state.role_color = _to_color_table(self._save_state.role_color)
    self._save_state.dialogue_color = _to_color_table(self._save_state.dialogue_color)
    self._save_state.background_color = _to_color_table(self._save_state.background_color, {r = 0, g = 0, b = 0, a = 128})
    self._background_image_reference = _clone_value(self._save_state.background_image_reference)
    self._background_texture = _resolve_background_texture(self._background_image_reference)
end

function Billboard:collect_save_state()
    local snapshot = _clone_value(self._save_state or {})
    snapshot.type = "Billboard"
    snapshot.progress = self._progress
    return snapshot
end

function Billboard:apply_save_state(state)
    local snapshot = type(state) == "table" and state or {}
    self._save_state = _clone_value(snapshot)

    _dispose_text(self)

    self._raw_x = tonumber(snapshot.x) or 0
    self._raw_y = tonumber(snapshot.y) or 0
    self._raw_width = tonumber(snapshot.width) or self._raw_width or 320
    self._width = RuntimeLayout.resolve_dialog_width(self._raw_width)
    self._progress = tonumber(snapshot.progress) or 1
    self._color_bg = _to_color_table(snapshot.background_color, self._color_bg)
    self._background_image_reference = _clone_value(snapshot.background_image_reference)
    self._background_texture = _resolve_background_texture(self._background_image_reference)

    local role_font = ResourcesManager.find_font(snapshot.role_font_reference) or GlobalContext.font_wrapper_sdl
    local dialogue_font = ResourcesManager.find_font(snapshot.dialogue_font_reference) or GlobalContext.font_wrapper_sdl
    local role_font_size = RuntimeLayout.scale_font_size(tonumber(snapshot.role_font_size) or 20)
    local dialogue_font_size = RuntimeLayout.scale_font_size(tonumber(snapshot.dialogue_font_size) or 25)
    local pad = _get_padding()

    self._save_state.name = _normalize_text(snapshot.name)
    self._save_state.dialogue = _normalize_text(snapshot.dialogue)
    self._text_name = TextWrapper.new(role_font, self._save_state.name, snapshot.role_color, nil, role_font_size)
    self._text_dialogue = TextWrapper.new(dialogue_font, self._save_state.dialogue, snapshot.dialogue_color, math.max(1, self._width - pad * 2), dialogue_font_size)
    self._height = self._text_name.h + self._text_dialogue.h + pad * 3
    _layout_dialog(self, self._raw_x, self._raw_y)
    self._tween = nil
end

function Billboard.create_from_save_state(state)
    local object = Billboard.new(" ", " ", 0, 0, 320,
        GlobalContext.font_wrapper_sdl,
        GlobalContext.font_wrapper_sdl,
        {r = 255, g = 255, b = 255, a = 255},
        {r = 255, g = 255, b = 255, a = 255},
        {r = 0, g = 0, b = 0, a = 128},
        0,
        nil,
        20,
        20)
    object:apply_save_state(state)
    return object
end

return Billboard

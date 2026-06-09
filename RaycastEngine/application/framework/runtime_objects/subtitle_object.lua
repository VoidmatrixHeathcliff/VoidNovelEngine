local rl = Engine.Raylib
local util = Engine.Util

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local ColorHelper = require("application.framework.color_helper")
local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")
local TextWrapper = require("application.framework.text_wrapper")
local RuntimeLayout = require("application.framework.runtime_layout_context")

local SubtitleObject = Class.define("Subtitle", GameObject)

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

function SubtitleObject:ctor(bottom_offset_provider)
    Class.call_super(SubtitleObject, self, "ctor")
    self.idx_text = 1
    self.is_visible = false
    self.can_push_on = false
    self.text_object = nil
    self._bottom_offset_provider = bottom_offset_provider
    self._save_state = nil
end

function SubtitleObject:set_text_object(text_object)
    if self.text_object and self.text_object.dispose then
        self.text_object:dispose()
    end
    self.text_object = text_object
end

function SubtitleObject:set_bottom_offset_provider(provider)
    if type(provider) == "function" then
        self._bottom_offset_provider = provider
    else
        self._bottom_offset_provider = nil
    end
end

function SubtitleObject:on_render()
    if not self.is_visible or not self.text_object then return end
    local bottom_offset = 0
    if self._bottom_offset_provider then
        bottom_offset = self._bottom_offset_provider()
    end
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    local x = (canvas_width - self.text_object.w) * 0.5
    local y = canvas_height - bottom_offset - self.text_object.h
    rl.DrawTextureV(self.text_object.texture, rl.Vector2(x, y), ColorHelper.WHITE)
end

function SubtitleObject:on_destroy()
    if self.text_object and self.text_object.dispose then
        self.text_object:dispose()
        self.text_object = nil
    end
end

function SubtitleObject:set_runtime_save_data(data)
    if type(data) ~= "table" then
        return
    end
    self._save_state = {}
    for key, value in pairs(data) do
        if type(value) == "table" then
            local copy = {}
            for copy_key, copy_value in pairs(value) do
                copy[copy_key] = copy_value
            end
            self._save_state[key] = copy
        else
            self._save_state[key] = value
        end
    end
    self._save_state.color = _to_color_table(self._save_state.color)
end

function SubtitleObject:collect_save_state()
    local snapshot = {}
    for key, value in pairs(self._save_state or {}) do
        if type(value) == "table" then
            local copy = {}
            for copy_key, copy_value in pairs(value) do
                copy[copy_key] = copy_value
            end
            snapshot[key] = copy
        else
            snapshot[key] = value
        end
    end
    snapshot.type = "SubtitleObject"
    snapshot.idx_text = self.idx_text
    snapshot.is_visible = self.is_visible
    snapshot.can_push_on = self.can_push_on
    return snapshot
end

function SubtitleObject:apply_save_state(state)
    local snapshot = type(state) == "table" and state or {}
    self._save_state = snapshot
    self.idx_text = tonumber(snapshot.idx_text) or 1
    self.is_visible = snapshot.is_visible == true
    self.can_push_on = snapshot.can_push_on == true

    local font_wrapper = ResourcesManager.find_font(snapshot.font_reference) or GlobalContext.font_wrapper_sdl
    local font_size = RuntimeLayout.scale_font_size(tonumber(snapshot.font_size) or 25)
    local full_text = tostring(snapshot.text or " ")
    local visible_text = full_text
    if self.can_push_on ~= true then
        visible_text = util.UTF8Sub(full_text, 0, math.max(1, self.idx_text))
    end
    if self.text_object and self.text_object.dispose then
        self.text_object:dispose()
    end
    local canvas_width = RuntimeLayout.get_canvas_size()
    self.text_object = TextWrapper.new(font_wrapper, visible_text,
        snapshot.color or {r = 255, g = 255, b = 255, a = 255},
        math.max(1, RuntimeLayout.round(canvas_width)),
        font_size)
end

function SubtitleObject.create_from_save_state(state)
    local snapshot = type(state) == "table" and state or {}
    local object = SubtitleObject.new(function()
        return RuntimeLayout.scale_y(tonumber(snapshot.bottom_distance) or 0)
    end)
    object:apply_save_state(snapshot)
    return object
end

return SubtitleObject

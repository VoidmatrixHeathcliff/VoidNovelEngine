local rl = Engine.Raylib
local sdl = Engine.SDL

local Class = require("application.framework.class")
local GlobalContext = require("application.framework.global_context")

local TextWrapper = Class.define("TextWrapper")
local max_native_wrap_len <const> = 2147483647

local function _is_finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function _normalize_wrap_len(wrap_len)
    if wrap_len == nil then
        return nil
    end

    local number = tonumber(wrap_len)
    if not _is_finite_number(number) then
        return 0
    end

    number = math.floor(number + 0.5)
    if number < 0 or number > max_native_wrap_len then
        return 0
    end
    return number
end

local function _get_wrap_signature_value(wrap_len)
    local normalized = _normalize_wrap_len(wrap_len)
    return normalized == nil and -1 or normalized
end

local function _normalize_channel(value, default_value, is_normalized)
    local number = tonumber(value)
    if number == nil or number ~= number then
        number = default_value or 0
    end
    if is_normalized then
        number = number * 255
    end
    if number == math.huge then return 255 end
    if number == -math.huge then return 0 end
    number = math.floor(number + 0.5)
    if number < 0 then return 0 end
    if number > 255 then return 255 end
    return number
end

local function _normalize_color(color)
    if type(color) ~= "table" and type(color) ~= "userdata" then
        return {r = 255, g = 255, b = 255, a = 255}
    end

    local r = tonumber(color.r) or tonumber(color.x)
    local g = tonumber(color.g) or tonumber(color.y)
    local b = tonumber(color.b) or tonumber(color.z)
    local a = tonumber(color.a) or tonumber(color.w)
    local use_normalized_range = false
    if r ~= nil and g ~= nil and b ~= nil and a ~= nil then
        use_normalized_range = r <= 1 and g <= 1 and b <= 1 and a <= 1
    end

    return
    {
        r = _normalize_channel(r, 255, use_normalized_range),
        g = _normalize_channel(g, 255, use_normalized_range),
        b = _normalize_channel(b, 255, use_normalized_range),
        a = _normalize_channel(a, 255, use_normalized_range),
    }
end

local function _is_font_wrapper(value)
    if type(value) ~= "table" then
        return false
    end
    if type(value.get) == "function" then
        return true
    end
    local metatable = getmetatable(value)
    return metatable and metatable.__index and type(metatable.__index.get) == "function"
end

local function _clear_texture_handles(o)
    if o.texture then
        rl.UnloadTexture(o.texture)
        o.texture = nil
    end
    if o.preview_texture then
        sdl.DestroyTexture(o.preview_texture)
        o.preview_texture = nil
    end
    o.w = 0
    o.h = 0
end

local function _render_surface(o)
    local font = o._font
    if o._font_wrapper then
        if not o._font_size then
            return nil
        end
        font = o._font_wrapper:get(o._font_size)
    end
    if not font then
        return nil
    end

    if o._wrap_len == nil then
        return sdl.RenderUTF8BlendedRGBA(font, o._text, o._color.r, o._color.g, o._color.b, o._color.a)
    end
    return sdl.RenderUTF8BlendedWrappedRGBA(font, o._text, o._color.r, o._color.g, o._color.b, o._color.a, o._wrap_len)
end

local function set_font(o, font)
    if _is_font_wrapper(font) then
        if font == o._font_wrapper then return end
        o._font = nil
        o._font_wrapper = font
    else
        if font == o._font then return end
        o._font = font
        o._font_wrapper = nil
        o._font_size = nil
    end
    o:_render()
end

local function set_text(o, text)
    local normalized = tostring(text or "")
    if normalized == o._text then return end

    o._text = normalized
    o:_render()
end

local function set_color(o, color)
    local normalized = _normalize_color(color)
    if normalized.r == o._color.r and normalized.g == o._color.g
        and normalized.b == o._color.b and normalized.a == o._color.a then return end

    o._color = normalized
    o:_render()
end

local function set_wrap_len(o, wrap_len)
    local normalized = _normalize_wrap_len(wrap_len)
    if normalized == o._wrap_len then return end

    o._wrap_len = normalized
    o:_render()
end

local function _render(o)
    local surface = _render_surface(o)
    if not surface then
        _clear_texture_handles(o)
        return
    end

    local width = tonumber(surface.w) or 0
    local height = tonumber(surface.h) or 0
    local texture = rl.LoadTextureFromSDLSurface(surface)
    local preview_texture = nil
    if GlobalContext.renderer then
        preview_texture = sdl.CreateTextureFromSurface(GlobalContext.renderer, surface)
        if preview_texture then
            sdl.SetTextureScaleMode(preview_texture, sdl.ScaleMode.BEST)
            sdl.SetTextureBlendMode(preview_texture, sdl.BlendMode.BLEND)
        end
    end
    sdl.FreeSurface(surface)

    _clear_texture_handles(o)
    if rl.IsTextureValid(texture) then
        o.texture = texture
    end
    o.preview_texture = preview_texture
    o.w = width
    o.h = height
end

function TextWrapper:ctor(font, text, color, wrap_len, font_size)
    self.texture = nil
    self.preview_texture = nil
    self.w = 0
    self.h = 0
    self._font = _is_font_wrapper(font) and nil or font
    self._font_wrapper = _is_font_wrapper(font) and font or nil
    self._font_size = self._font_wrapper and math.max(1, math.floor(tonumber(font_size) or 1)) or nil
    self._text = tostring(text or "")
    self._color = _normalize_color(color)
    self._wrap_len = _normalize_wrap_len(wrap_len)
    self:_render()
end

TextWrapper.set_font = set_font
TextWrapper.set_text = set_text
TextWrapper.set_color = set_color
TextWrapper.set_wrap_len = set_wrap_len
TextWrapper._render = _render
TextWrapper.normalize_wrap_len = _normalize_wrap_len
TextWrapper.get_wrap_signature_value = _get_wrap_signature_value

function TextWrapper:dispose()
    _clear_texture_handles(self)
end

TextWrapper.__gc = TextWrapper.dispose

function TextWrapper:__tostring()
    return self:get_class_name()
end

return TextWrapper

local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib

local metaname = "TextWrapper"

local function set_font(o, font)
    if font == o._font then return end

    o._font = font
    o:_render()
end

local function set_text(o, text)
    if text == o._text then return end

    o._text = text
    o:_render()
end

local function set_color(o, color)
    if color.r == o._color.r and color.g == o._color.g
        and color.b == o._color.b and color.a == o._color.a then return end 
    
    o._color = color
    o:_render()
end

local function set_wrap_len(o, wrap_len)
    assert(type(o) == metaname)
    assert(type(wrap_len) == "number")
    if wrap_len == o._wrap_len then return end

    o._wrap_len = wrap_len
    o:_render()
end

local function _render(o)
    local surface 
    if not o._wrap_len then 
        surface = sdl.RenderUTF8Blended(o._font, o._text, o._color)
    else
        surface = sdl.RenderUTF8BlendedWrapped(o._font, o._text, o._color, o._wrap_len)
    end

    -- 渲染失败直接报警
    assert(surface)

    local surface_formatted = sdl.ConvertSurfaceFormat(surface, sdl.PixelFormat.RGBA32, 0)

    -- 如果纹理已存在且尺寸相同则不需要销毁再创建
    if o.texture and surface.w == o.w and surface.h == o.h then
        rl.UpdateTexture(o.texture, surface_formatted.pixels)
    else
        if o.texture then rl.UnloadTexture(o.texture) end
        local image = rl.Image()
        image.data = surface_formatted.pixels
        image.width, image.height = surface_formatted.w, surface_formatted.h
        image.mipmaps = 1
        image.format = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8
        o.texture = rl.LoadTextureFromImage(image)
        o.w, o.h = surface.w, surface.h
        -- 注意这里没有像素内存拷贝，不需要主动销毁Imgae
    end

    sdl.FreeSurface(surface)
    sdl.FreeSurface(surface_formatted)
end

local metatable = 
{
    __index = 
    {
        set_font = set_font,
        set_text = set_text,
        set_color = set_color,
        set_wrap_len = set_wrap_len,
        _render = _render
    },
    __gc = function(o)
        if o.texture then
            rl.UnloadTexture(o.texture)
        end
    end,
    __tostring = function()
        return metaname
    end
}

module.new = function(font, text, color, wrap_len)
    local o = 
    {
        texture = nil,
        w = 0, h = 0,

        _font = font,
        _text = text,
        _color = color,
        _wrap_len = wrap_len,
    }
    setmetatable(o, metatable)
    o:_render()
    return o
end

return module
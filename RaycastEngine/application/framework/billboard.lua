local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib

local Tween = require("application.framework.tween")
local GameObject = require("application.framework.game_object")
local TextWrapper = require("application.framework.text_wrapper")

local padding <const> = 15

local function hide(self, time)
    self._tween = Tween.new(self, "_progress", 1, 0, time, function()
        self:make_invalid()
    end, "out")
end

local function on_update(self, delta)
    self._tween:on_update(delta)
end

local function on_render(self)
    rl.DrawRectangleV(rl.Vector2(self._x, self._y), rl.Vector2(self._width * self._progress, self._height * self._progress), 
        rl.Color(self._color_bg.r, self._color_bg.g, self._color_bg.b, math.floor(self._color_bg.a * self._progress)))
    local color_hint = rl.Color(255, 255, 255, math.floor(255 * self._progress))
    rl.DrawTextureV(self._text_name.texture, rl.Vector2(self._x + padding, self._y + padding), color_hint)
    rl.DrawTextureV(self._text_dialogue.texture, rl.Vector2(self._x + padding, self._y + padding * 2 + self._text_name.h), color_hint)
end

module.new = function(name, dialogue, x, y, width, font_name, font_dialog, color_name, color_dialog, color_bg, time)
    if #name == 0 then name = " " end
    if #dialogue == 0 then dialogue = " " end
    local o = 
    {
        -- _metaname = "Billboard",
        _metaname = "DialogBox",

        _x = x, _y = y,
        _text_name = TextWrapper.new(font_name, name, color_name),
        _text_dialogue = TextWrapper.new(font_dialog, dialogue, color_dialog, width - padding * 2),
        _width = width, _height = -1,
        _tween = nil, _progress = 0,
        _color_bg = color_bg,

        hide = hide,
        on_update = on_update,
        on_render = on_render,
    }

    o._height = o._text_name.h + o._text_dialogue.h + padding * 3
    o._tween = Tween.new(o, "_progress", 0, 1, time, nil, "out")

    setmetatable(o, GameObject.new())
    o.__index = o
    return o
end

return module
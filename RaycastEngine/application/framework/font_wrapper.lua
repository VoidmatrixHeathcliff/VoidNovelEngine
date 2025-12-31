local module = {}

local sdl = Engine.SDL

local function get(self, size)
    local font = self._pool[size]
    if not font then
        font = sdl.OpenFont(self._path, size)
        self._pool[size] = font
    end
    return font
end

module.new = function(path)
    local o = 
    {
        _metaname = "FontWrapper",

        _path = path,
        _pool = {},

        get = get,

        __gc = function(self)
            for _, v in pairs(self._pool) do
                sdl.CloseFont(v)
            end
        end
    }
    setmetatable(o, o)
    o.__index = o
    return o
end

return module
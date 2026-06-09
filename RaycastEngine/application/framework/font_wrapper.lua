local sdl = Engine.SDL
local util = Engine.Util

local Class = require("application.framework.class")

local FontWrapper = Class.define("FontWrapper")
local max_cached_font_sizes <const> = 32
local max_font_size <const> = 2048

local function _normalize_size(size)
    local normalized = math.floor(tonumber(size) or 1)
    if normalized < 1 then
        return 1
    end
    if normalized > max_font_size then
        return max_font_size
    end
    return normalized
end

local function _close_font(font)
    if font and sdl.CloseFont then
        pcall(sdl.CloseFont, font)
    end
end

local function _count_pool(pool)
    local count = 0
    for _ in pairs(pool or {}) do
        count = count + 1
    end
    return count
end

local function _trim_pool(self)
    while _count_pool(self._pool) > max_cached_font_sizes do
        local oldest_size = nil
        local oldest_serial = nil
        for size in pairs(self._pool) do
            local serial = self._last_used_by_size[size] or 0
            if oldest_serial == nil or serial < oldest_serial then
                oldest_size = size
                oldest_serial = serial
            end
        end
        if oldest_size == nil then
            return
        end
        _close_font(self._pool[oldest_size])
        self._pool[oldest_size] = nil
        self._last_used_by_size[oldest_size] = nil
    end
end

local function get(self, size)
    if not self._source then
        return nil
    end
    size = _normalize_size(size)
    local font = self._pool[size]
    if not font then
        if self._is_memory_source then
            font = sdl.OpenFontFromMemory(self._source, size)
        else
            font = sdl.OpenFont(self._source, size)
        end
        if font then
            self._pool[size] = font
        end
    end
    if font then
        self._access_serial = (self._access_serial or 0) + 1
        self._last_used_by_size[size] = self._access_serial
        _trim_pool(self)
    end
    return font
end

function FontWrapper:ctor(source)
    self._source = source
    self._is_memory_source = type(source) ~= "string"
    self._pool = {}
    self._last_used_by_size = {}
    self._access_serial = 0
end

FontWrapper.get = get

function FontWrapper:dispose()
    for key, value in pairs(self._pool) do
        _close_font(value)
        self._pool[key] = nil
    end
    self._last_used_by_size = {}
    if self._is_memory_source and self._source then
        util.UnloadFileBuffer(self._source)
        self._source = nil
    end
end

function FontWrapper:get_stats()
    local size_list = {}
    for size in pairs(self._pool or {}) do
        table.insert(size_list, size)
    end
    table.sort(size_list)
    return
    {
        cached_size_count = #size_list,
        max_cached_size_count = max_cached_font_sizes,
        cached_sizes = size_list,
    }
end

FontWrapper.__gc = FontWrapper.dispose

return FontWrapper

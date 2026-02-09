local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local util = Engine.Util

local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")

local ffmpeg_path = "application\\external\\ffmpeg.exe"

local function next_frame(decoder)
    local data = decoder._pipe:read(decoder._frame_size)
    if data and #data == decoder._frame_size then
        decoder._buffer:set(data)
        rl.UpdateTexture(decoder.texture, decoder._buffer:raw())
    else
        decoder.has_finished = true
    end
end

local function on_update(self, delta)
    self._accumulator = self._accumulator + delta
    if self._accumulator >= self._duration then
        self._accumulator = self._accumulator - self._duration
        next_frame(self)
    end
end

local function close(self)
    rl.UnloadTexture(self.texture)
    self._pipe:close()
    sdl.FreeChunk(self.audio)
end

module.new = function(file, width, height, frame_rate)
    local folder = GlobalContext.get_pref_path()
    if not folder then folder = "./" end
    local audio_path = string.format("%s%s.wav", folder, rl.GetFileNameWithoutExt(file))
    local command = string.format("%s -v error -y -i \"%s\" -vn -ac 2 -ar 44100 \"%s\"", ffmpeg_path, file, audio_path)
    os.execute(command)

    local audio = sdl.LoadWAV(audio_path)
    os.remove(audio_path)
    if not audio then return end

    local frame_size = width * height * 4
    command = string.format("%s -v error -i \"%s\" -r %d -s %dx%d -f rawvideo -pix_fmt rgba -", ffmpeg_path, file, frame_rate, width, height)
    local pipe = io.popen(command, "rb")
    if not pipe then sdl.FreeChunk(audio) return end

    local image = rl.GenImageColor(width, height, rl.Color(0, 0, 0, 255))
    local texture = rl.LoadTextureFromImage(image)
    if SettingsManager.get("filter_mode") == rl.TextureFilter.TRILINEAR then
        rl.GenTextureMipmaps(texture)
    end
    rl.SetTextureFilter(texture, SettingsManager.get("filter_mode"))
    rl.UnloadImage(image)

    local o = 
    {
        _metaname = "VideoDecoder",

        _accumulator = 0,
        _duration = 1 / frame_rate,
        _frame_size = frame_size,
        _buffer = util.CString(),
        _pipe = pipe,
        width = width,
        height = height,
        has_finished = false,

        audio = audio,
        texture = texture,
        on_update = on_update,
        close = close
    }

    setmetatable(o, o)
    o.__index = o
    return o

end

return module
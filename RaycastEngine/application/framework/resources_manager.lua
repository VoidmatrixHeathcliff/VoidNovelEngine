local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib

local FontWrapper = require("application.framework.font_wrapper")
local ShaderWrapper = require("application.framework.shader_wrapper")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")

local font_pool = {}
local audio_pool = {}
local video_pool = {}
local shader_pool = {}
local texture_pool = {}
local sdl_icon_pool = {}
local sdl_texture_pool = {}

module.load = function(path)
    path = path or "application\\resources"
    local path_list = rl.LoadDirectoryFilesEx(path, nil, true)
    local is_release_mode = SettingsManager.get("release_mode")
    for i = 1, path_list.count do
        local path = path_list:get(i - 1)
        local name = rl.GetFileNameWithoutExt(path)
        local raw_ext = rl.GetFileExtension(path)
        if raw_ext then
            local ext = string.lower(raw_ext)
            if ext == ".png" or ext == ".jpg" or ext == ".jpeg" or ext == ".tif" or ext == ".tiff" or ext == ".webp" or ext == ".avif" then
                -- 加载Runtime纹理格式
                local texture = rl.LoadTexture(path)
                if texture then
                    if SettingsManager.get("filter_mode") == rl.TextureFilter.TRILINEAR then
                        rl.GenTextureMipmaps(texture)
                    end
                    rl.SetTextureFilter(texture, SettingsManager.get("filter_mode"))
                    texture_pool[name] = texture
                    if not is_release_mode then
                        -- 加载Editor纹理格式
                        local sdl_texture = sdl.LoadTexture(GlobalContext.renderer, path)
                        sdl.SetTextureScaleMode(sdl_texture, sdl.ScaleMode.BEST)
                        sdl_texture_pool[name] = sdl_texture
                    end
                end
            elseif ext == ".wav" or ext == ".mp3" or ext == ".ogg" or ext == ".flac" then
                audio_pool[name] = sdl.LoadWAV(path)
            elseif ext == ".mp4" or ext == ".avi" or ext == ".mkv" or ext == ".flv" or ext == ".mov" or ext == ".webm" then
                video_pool[name] = path
            elseif ext == ".ttf" or ext == ".otf" then
                font_pool[name] = FontWrapper.new(path)
            elseif ext == ".glsl" or ext == ".fs" then
                local shader = ShaderWrapper.new(path)
                if not rl.IsShaderValid(shader._shader) then
                    error(string.format("Invalid Shader: %s", path))
                end
                shader_pool[name] = shader
            end
        end
    end
    rl.UnloadDirectoryFiles(path_list)
    -- 加载编辑器图标
    if not is_release_mode then
        path_list = rl.LoadDirectoryFilesEx("application\\icon", nil, true)
        for i = 1, path_list.count do
            local path = path_list:get(i - 1)
            local name = rl.GetFileNameWithoutExt(path)
            local ext = string.lower(rl.GetFileExtension(path))
            if ext == ".png" or ext == ".jpg" then
                local texture = sdl.LoadTexture(GlobalContext.renderer, path)
                sdl.SetTextureScaleMode(texture, sdl.ScaleMode.BEST)
                sdl_icon_pool[name] = texture
            end
        end
        rl.UnloadDirectoryFiles(path_list)
    end
end

module.find_font = function(name)
    return font_pool[name]
end

module.find_audio = function(name)
    return audio_pool[name]
end

module.find_video = function(name)
    return video_pool[name]
end

module.find_shader = function(name)
    return shader_pool[name]
end

module.find_texture = function(name)
    return texture_pool[name]
end

module.find_sdl_texture = function(name)
    return sdl_texture_pool[name]
end

module.find_icon = function(name)
    return sdl_icon_pool[name]
end

module.get_font_pool = function()
    return font_pool
end

module.get_audio_pool = function()
    return audio_pool
end

module.get_video_pool = function()
    return video_pool
end

module.get_shader_pool = function()
    return shader_pool
end

module.get_texture_pool = function()
    return texture_pool
end

return module
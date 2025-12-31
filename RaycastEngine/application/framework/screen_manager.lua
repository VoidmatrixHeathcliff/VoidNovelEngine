local module = {}

local rl = Engine.Raylib

local ColorHelper = require("application.framework.color_helper")
local GlobalContext = require("application.framework.global_context")

local scale = 0
local texture_target = nil
local mouse_x, mouse_y = 0, 0
local render_origin = rl.Vector2(0, 0)
local width_texture, height_texture = 0, 0
local rect_render_src = rl.Rectangle(0, 0, 0, 0)

module.init = function(width, height)
    texture_target = rl.LoadRenderTexture(width, height)
    width_texture, height_texture = width, height
    rect_render_src.width, rect_render_src.height = width, -height
    rl.SetTextureFilter(texture_target.texture, GlobalContext.filter_mode)
end

module.get_size = function()
    return width_texture, height_texture
end

module.get_target = function()
    return texture_target
end

module.set_target = function(texture)
    texture_target = texture
end

module.get_mouse_pos = function()
    return mouse_x, mouse_y
end

module.get_texture = function()
    return texture_target.texture
end

module.begin_render = function()
    rl.BeginTextureMode(texture_target)
    rl.ClearBackground(ColorHelper.BLACK)
end

module.end_render = function()
    rl.EndTextureMode()
end

module.on_update = function()
    scale = math.min(rl.GetScreenWidth() / width_texture, rl.GetScreenHeight() / height_texture)

    local native_mouse_pos = rl.GetMousePosition()
    mouse_x = math.clamp((native_mouse_pos.x - (rl.GetScreenWidth() - (width_texture * scale)) * 0.5) / scale, 0, width_texture)
    mouse_y = math.clamp((native_mouse_pos.y - (rl.GetScreenHeight() - (height_texture * scale)) * 0.5) / scale, 0, height_texture)
end

module.on_render = function()
    local rect_render_dst = rl.Rectangle((rl.GetScreenWidth() - (width_texture * scale)) * 0.5, 
        (rl.GetScreenHeight() - (height_texture * scale)) * 0.5, width_texture * scale, height_texture * scale)
    if GlobalContext.shader_postprocess then GlobalContext.shader_postprocess:use() end
    rl.DrawTexturePro(texture_target.texture, rect_render_src, rect_render_dst, render_origin, 0, ColorHelper.WHITE)
    if GlobalContext.shader_postprocess then GlobalContext.shader_postprocess:unuse() end
    -- if GlobalContext.debug then rl.DrawFPS(25, 25) end
    rl.DrawFPS(25, 25)
end

return module
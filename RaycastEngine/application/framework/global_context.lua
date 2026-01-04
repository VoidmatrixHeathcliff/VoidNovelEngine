local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local imgui = Engine.ImGUI

module.debug = false

module.shader_postprocess = nil

module.width_game_window, module.height_game_window = 1920, 1080

-- rl.TextureFilter.POINT / rl.TextureFilter.BILINEAR
module.filter_mode = rl.TextureFilter.BILINEAR

module.color_theme = rl.Color(104, 163, 68, 225)
module.color_theme_sdl = sdl.Color(module.color_theme.r, module.color_theme.g, module.color_theme.b, module.color_theme.a)

module.window, module.renderer = nil, nil

module.font_imgui = nil
module.font_wrapper_sdl = nil

module.version = "0.1.0-dev.1"

module.clipboard = {}
module.clipboard.format = "vne_blueprint_clipboard"
module.clipboard.format_version = 1

module.is_debug_game = false
module.current_blueprint = nil
module.runtime_global_context = {}

module.is_simulated_interaction = false

-- 是否显示流程
module.is_show_flow = imgui.Bool(false)
-- 是否显示所有节点ID
module.is_show_all_node_id = imgui.Bool(false)

-- 下一帧选中的流程文档ID
module.bp_id_selected_next_frame = nil

-- 是否在编辑器中预览内容
module.is_preview_in_editor = true

-- 切换预览模式
module.toggle_preview_mode = function()
    module.is_preview_in_editor = not module.is_preview_in_editor
    if module.is_preview_in_editor then
        -- 哎呦，Raylib怎么这么坏啊！
        rl.ClearWindowState(rl.ConfigFlags.WINDOW_HIDDEN)
        rl.SetWindowState(rl.ConfigFlags.WINDOW_HIDDEN)
    else
        rl.RestoreWindow()
    end
end

-- 运行时辅助函数：获取指定ID的节点对象
module.runtime_find_node = function(id)
    return module.current_blueprint._node_pool[id]
end

-- 运行时辅助函数：获取指定ID的引脚对象
module.runtime_find_pin = function(id)
    return module.current_blueprint._pin_pool[id]
end

-- 结束调试
module.stop_debug = function()
    module.runtime_global_context = {}
    module.is_debug_game = false
    sdl.HaltChannel(-1)
end

-- 所有流程文档对象列表
module.blueprint_list = {}

return module
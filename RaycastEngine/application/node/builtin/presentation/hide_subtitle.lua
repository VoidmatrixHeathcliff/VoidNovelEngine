local Common = require("application.framework.builtin_node_common")
local PresentationUIBridge = require("application.framework.presentation_ui_bridge")

local sdl = Common.sdl
local rl = Common.rl
local util = Common.util
local imgui = Common.imgui

local Class = Common.Class
local Timer = Common.Timer
local Tween = Common.Tween
local Billboard = Common.Billboard
local BlueprintNode = Common.BlueprintNode
local LogManager = Common.LogManager
local TextWrapper = Common.TextWrapper
local ColorHelper = Common.ColorHelper
local UndoManager = Common.UndoManager
local VideoDecoder = Common.VideoDecoder
local GlobalContext = Common.GlobalContext
local ModifyManager = Common.ModifyManager
local BranchSelector = Common.BranchSelector
local ResourcesManager = Common.ResourcesManager
local BackgroundObject = Common.BackgroundObject
local ForegroundObject = Common.ForegroundObject
local LetterboxingObject = Common.LetterboxingObject
local SubtitleObject = Common.SubtitleObject
local TransitionFadeObject = Common.TransitionFadeObject
local VideoRendererObject = Common.VideoRendererObject
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    hide_subtitle =
    {
    type_id = "hide_subtitle",
    icon_id = "text-spacing",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "隐藏字幕",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 10,
    menu_visible = true,
    }
}

return Common.make_definition(NodeDef.hide_subtitle, function(ctx)
    local blueprint = ctx.blueprint
    local data = ctx.data
    local _execute_next_node = NodeRuntimeHelper.execute_next_node
    local _wait_interact_to_next_node = NodeRuntimeHelper.wait_interact_to_next_node
    local _convert_imvec4_to_sdl_color = NodeRuntimeHelper.convert_imvec4_to_sdl_color
    local _convert_imvec4_to_raylib_color = NodeRuntimeHelper.convert_imvec4_to_raylib_color

    local node = ctx:create_base_node()
    local builder = ctx.builder
    builder:add_input({type_id = "flow"})
    builder:add_output({type_id = "flow"})
    node.on_execute = function(self, scene)
        if PresentationUIBridge.is_enabled() and scene and scene.find_ui_instance and scene:find_ui_instance("bp-subtitle") then
            scene:close_ui("bp-subtitle")
            _execute_next_node(self)
            return
        end
        local subtitle = scene:find_object("bp-subtitle")
        if not subtitle then return end
        subtitle.is_visible = false
        _execute_next_node(self)
    end
    return node
end)

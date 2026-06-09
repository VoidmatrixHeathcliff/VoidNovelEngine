local Common = require("application.framework.builtin_node_common")

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
    string =
    {
    type_id = "string",
    icon_id = "text",
    color = ColorHelper.ValueTypeColorPool.string,
    name = "字符串",
    comment = nil,
    category = "值节点",
    category_order = 6,
    order = 2,
    menu_visible = true,
    }
}

return Common.make_definition(NodeDef.string, function(ctx)
    local blueprint = ctx.blueprint
    local data = ctx.data
    local _execute_next_node = NodeRuntimeHelper.execute_next_node
    local _wait_interact_to_next_node = NodeRuntimeHelper.wait_interact_to_next_node
    local _convert_imvec4_to_sdl_color = NodeRuntimeHelper.convert_imvec4_to_sdl_color
    local _convert_imvec4_to_raylib_color = NodeRuntimeHelper.convert_imvec4_to_raylib_color

    local node = ctx:create_base_node({use_definition_style = false})
    local builder = ctx.builder
    builder:add_output({key = "value", type_id = "string", options = {width_input = 100}})
    return node
end)

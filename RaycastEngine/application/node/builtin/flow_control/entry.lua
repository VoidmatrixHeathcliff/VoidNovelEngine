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
    entry =
    {
    type_id = "entry",
    icon_id = "arrow-right-up-box-fill",
    color = imgui.ImVec4(imgui.ImColor(175, 23, 30, 255).value),
    name = "流程场景进入",
    comment = "当前流程脚本入口节点",
    category = "流程控制",
    category_order = 3,
    order = 1,
    menu_visible = false,
    }
}

local entry_output_leading_width <const> = 140

return Common.make_definition(NodeDef.entry, function(ctx)
    local blueprint = ctx.blueprint
    local data = ctx.data
    local _execute_next_node = NodeRuntimeHelper.execute_next_node
    local _wait_interact_to_next_node = NodeRuntimeHelper.wait_interact_to_next_node
    local _convert_imvec4_to_sdl_color = NodeRuntimeHelper.convert_imvec4_to_sdl_color
    local _convert_imvec4_to_raylib_color = NodeRuntimeHelper.convert_imvec4_to_raylib_color

    local node = ctx:create_base_node()
    node._output_leading_width = entry_output_leading_width
    local builder = ctx.builder
    builder:add_output({type_id = "flow"})
    node.on_execute = function(self, scene)
        _execute_next_node(self)
    end
    return node
end)

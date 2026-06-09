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
    comment =
    {
    type_id = "comment",
    icon_id = "message-2-fill",
    color = imgui.ImVec4(imgui.ImColor(255, 255, 255, 255).value),
    name = "注释节点",
    comment = nil,
    category = "其他",
    category_order = 9,
    order = 1,
    menu_visible = true,
    }
}

local comment_size_stable_frames_required <const> = 1
local comment_resize_hit_padding <const> = 12

local function _get_node_numeric_id(node)
    if not node or not node._id then
        return nil
    end
    local ok, value = pcall(function()
        return node._id:get()
    end)
    if ok then
        return value
    end
    return nil
end

local function _is_mouse_in_node_rect(node)
    if not node or not imgui.NodeEditor.ScreenToCanvas or not imgui.GetMousePos then
        return false
    end

    local mouse_canvas = imgui.NodeEditor.ScreenToCanvas(imgui.GetMousePos())
    local node_pos = imgui.NodeEditor.GetNodePosition(node._id)
    local node_size = imgui.NodeEditor.GetNodeSize(node._id)
    local mouse_x, mouse_y = tonumber(mouse_canvas and mouse_canvas.x), tonumber(mouse_canvas and mouse_canvas.y)
    local min_x, min_y = tonumber(node_pos and node_pos.x), tonumber(node_pos and node_pos.y)
    local width, height = tonumber(node_size and node_size.x), tonumber(node_size and node_size.y)
    if not mouse_x or not mouse_y or not min_x or not min_y or not width or not height then
        return false
    end

    local max_x = min_x + math.max(0, width)
    local max_y = min_y + math.max(0, height)
    return mouse_x >= min_x - comment_resize_hit_padding
        and mouse_y >= min_y - comment_resize_hit_padding
        and mouse_x <= max_x + comment_resize_hit_padding
        and mouse_y <= max_y + comment_resize_hit_padding
end

local function _is_comment_resize_user_action(node)
    if not node or not node._size_layout_initialized then
        return false
    end
    if not imgui.IsMouseDown or not imgui.IsMouseDown(0) then
        return false
    end

    local runtime_state = imgui.NodeEditor.GetRuntimeState and imgui.NodeEditor.GetRuntimeState() or nil
    if not runtime_state or runtime_state.has_current_action ~= true then
        return false
    end

    local node_id = _get_node_numeric_id(node)
    if node_id and tonumber(runtime_state.hovered_node_id) == node_id then
        return true
    end

    return _is_mouse_in_node_rect(node)
end

return Common.make_definition(NodeDef.comment, function(ctx)
    local blueprint = ctx.blueprint
    local data = ctx.data
    local _execute_next_node = NodeRuntimeHelper.execute_next_node
    local _wait_interact_to_next_node = NodeRuntimeHelper.wait_interact_to_next_node
    local _convert_imvec4_to_sdl_color = NodeRuntimeHelper.convert_imvec4_to_sdl_color
    local _convert_imvec4_to_raylib_color = NodeRuntimeHelper.convert_imvec4_to_raylib_color

    local node = ctx:create_base_node({use_definition_style = false})
    local builder = ctx.builder
    node._cstring = util.CString(NodeDef.comment.name)
    node._prev_text = node._cstring:get()
    node._size = {x = 600, y = 300}
    node._size_layout_initialized = false
    node._size_layout_stable_frames = 0
    if data then
        node._cstring:set(data.text)
        local saved_size = data.size or {}
        node._size.x = tonumber(saved_size.x) or node._size.x
        node._size.y = tonumber(saved_size.y) or node._size.y
    end
    node.on_update = function(self)
        imgui.NodeEditor.Comment(self._id, self._cstring:get(), imgui.ImVec2(self._size.x, self._size.y))
        local size = imgui.NodeEditor.GetNodeSize(self._id)
        -- x:16 y:38 为注释节点内容尺寸与实际渲染节点尺寸的差值
        local next_width = math.max(1, size.x - 16)
        local next_height = math.max(1, size.y - 38)
        local changed = math.abs(next_width - node._size.x) > 0.5
            or math.abs(next_height - node._size.y) > 0.5
        if changed then
            local is_user_resize = _is_comment_resize_user_action(node)
            node._size.x, node._size.y = next_width, next_height
            node._size_layout_stable_frames = 0
            if is_user_resize then
                ModifyManager.set_modify(true)
            end
        else
            node._size_layout_stable_frames = math.min(
                comment_size_stable_frames_required,
                (node._size_layout_stable_frames or 0) + 1)
            if node._size_layout_stable_frames >= comment_size_stable_frames_required then
                node._size_layout_initialized = true
            end
        end
    end
    node.on_save = function(self)
        local data = BlueprintNode.on_save(self)
        -- SAVE TRACE: comment node appends its own text and size fields.
        data.text = self._cstring:get()
        data.size = {x = self._size.x, y = self._size.y}
        return data
    end
    node.query_menu_id = function(self)
        return string.format("comment_node_%d", self._id:get())
    end
    node.on_show_menu = function(self)
        imgui.Text("注释内容：")
        imgui.SameLine()
        imgui.SetNextItemWidth(100)
        imgui.InputText(string.format("##comment_%d", self._id:get()), self._cstring)
        if imgui.IsItemDeactivatedAfterEdit() then
            local next_text = node._cstring:get()
            if next_text == node._prev_text then
                return
            end
            UndoManager.record(function(data)
                    node._cstring:set(data.old)
                    node._prev_text = data.old
                end, function(data)
                    node._cstring:set(data.new)
                    node._prev_text = data.new
                end, {old = node._prev_text, new = next_text})
            node._prev_text = next_text
        end
    end
    return node
end)

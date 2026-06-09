local imgui = Engine.ImGUI

local Navigation = {}

local default_duration <const> = 0.22
local default_focus_rect_scale <const> = 1.8

local function _as_number(value, fallback)
    local result = tonumber(value)
    if result == nil then
        return fallback
    end
    return result
end

local function _clear_pending(blueprint)
    blueprint._flow_pending_navigation = nil
    blueprint._flow_pending_navigation_node_id = nil
end

local function _read_canvas_size(node_editor)
    if type(node_editor.GetRuntimeState) ~= "function" then
        return 0, 0
    end

    local state = node_editor.GetRuntimeState()
    if type(state) ~= "table" then
        return 0, 0
    end

    local width = _as_number(state.canvas_max_x, 0) - _as_number(state.canvas_min_x, 0)
    local height = _as_number(state.canvas_max_y, 0) - _as_number(state.canvas_min_y, 0)
    return math.max(0, width), math.max(0, height)
end

local function _read_node_rect(blueprint, node_editor, node_id)
    local node = blueprint._node_pool and blueprint._node_pool[node_id] or nil
    local editor_node_id = node and node._id or node_editor.NodeId(node_id)
    local position = node_editor.GetNodePosition(editor_node_id)
    local size = node_editor.GetNodeSize(editor_node_id)

    local x = position and tonumber(position.x)
    local y = position and tonumber(position.y)
    if (x == nil or y == nil) and node and node._position then
        x = tonumber(node._position.x)
        y = tonumber(node._position.y)
    end

    local width = size and tonumber(size.x) or nil
    local height = size and tonumber(size.y) or nil
    if not x or not y or not width or not height or width <= 0 or height <= 0 then
        return nil
    end

    return x, y, width, height
end

local function _build_focus_rect(blueprint, node_editor, node_id, pending)
    local x, y, width, height = _read_node_rect(blueprint, node_editor, node_id)
    if not x then
        return nil
    end

    local canvas_width, canvas_height = _read_canvas_size(node_editor)
    local scale = math.max(1.0, _as_number(pending.focus_rect_scale, default_focus_rect_scale))
    local target_width = math.max(width * scale, canvas_width * scale)
    local target_height = math.max(height * scale, canvas_height * scale)
    local center_x = x + width * 0.5
    local center_y = y + height * 0.5

    return
    {
        min_x = center_x - target_width * 0.5,
        min_y = center_y - target_height * 0.5,
        max_x = center_x + target_width * 0.5,
        max_y = center_y + target_height * 0.5,
    }
end

function Navigation.request_node(blueprint, node_id, options)
    if type(node_id) ~= "number" or not blueprint._node_pool or not blueprint._node_pool[node_id] then
        return false
    end

    local navigate_options = type(options) == "table" and options or {}
    local focus_rect_scale = navigate_options.focus_rect_scale or navigate_options.view_rect_scale
    local pending =
    {
        node_id = node_id,
        stabilize_view = navigate_options.stabilize_view == true,
        duration = tonumber(navigate_options.duration) or nil,
        focus_rect_scale = tonumber(focus_rect_scale) or nil,
    }

    blueprint._flow_pending_navigation = pending
    blueprint._flow_pending_navigation_node_id = node_id
    if navigate_options.skip_initial_content ~= false and pending.stabilize_view then
        blueprint._navigate_counter = math.max(4, tonumber(blueprint._navigate_counter) or 0)
    end
    return true
end

function Navigation.apply_pending(blueprint, node_editor)
    node_editor = node_editor or imgui.NodeEditor
    local pending = rawget(blueprint, "_flow_pending_navigation")
    local node_id = pending and pending.node_id or rawget(blueprint, "_flow_pending_navigation_node_id")
    if not node_id then
        return false
    end

    _clear_pending(blueprint)
    if not blueprint._node_pool or not blueprint._node_pool[node_id] then
        return false
    end

    node_editor.ClearSelection()
    node_editor.SelectNode(node_editor.NodeId(node_id), true)

    local stabilize_view = pending and pending.stabilize_view == true
    local duration = pending and tonumber(pending.duration) or nil
    if stabilize_view then
        duration = duration or default_duration
        if type(node_editor.NavigateToViewRect) == "function" then
            local rect = _build_focus_rect(blueprint, node_editor, node_id, pending)
            if rect and node_editor.NavigateToViewRect(rect.min_x, rect.min_y, rect.max_x, rect.max_y, duration) then
                return true
            end
        end
    end

    node_editor.NavigateToSelection(false, duration)
    return true
end

function Navigation.clear_pending(blueprint)
    _clear_pending(blueprint)
end

return Navigation

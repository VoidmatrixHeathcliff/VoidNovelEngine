local GlobalContext = require("application.framework.global_context")
local ScreenManager = require("application.framework.screen_manager")

local module = {}

local design_width <const> = 1920
local design_height <const> = 1080

local function _is_finite_number(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function _as_number(value, fallback)
    local number = tonumber(value)
    if not _is_finite_number(number) then
        return fallback
    end
    return number
end

local function _as_positive_number(value, fallback)
    local number = _as_number(value, fallback)
    return math.max(1, number or 1)
end

local function _round(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

function module.get_design_size()
    return design_width, design_height
end

function module.get_canvas_size()
    local width, height = 0, 0
    if ScreenManager and ScreenManager.get_size then
        local ok, result_width, result_height = pcall(ScreenManager.get_size)
        if ok then
            width, height = tonumber(result_width) or 0, tonumber(result_height) or 0
        end
    end

    if width <= 0 then
        width = tonumber(GlobalContext.width_game_window) or design_width
    end
    if height <= 0 then
        height = tonumber(GlobalContext.height_game_window) or design_height
    end
    return math.max(1, width), math.max(1, height)
end

function module.scale_x(value)
    local width = module.get_canvas_size()
    return (tonumber(value) or 0) * width / design_width
end

function module.scale_y(value)
    local _, height = module.get_canvas_size()
    return (tonumber(value) or 0) * height / design_height
end

function module.scale_uniform(value)
    local width, height = module.get_canvas_size()
    local scale = math.min(width / design_width, height / design_height)
    return (tonumber(value) or 0) * scale
end

function module.scale_font_size(value)
    local width, height = module.get_canvas_size()
    local scale = math.min(width / design_width, height / design_height)
    local scaled = (tonumber(value) or 0) * scale
    return math.max(1, _round(scaled))
end

function module.scale_point(point)
    point = point or {}
    return
    {
        x = module.scale_x(point.x),
        y = module.scale_y(point.y),
    }
end

function module.scale_size(size)
    size = size or {}
    return
    {
        x = module.scale_x(size.x),
        y = module.scale_y(size.y),
    }
end

function module.resolve_dialog_width(width)
    local scaled_width = module.scale_x(_as_positive_number(width, 1640))
    return math.max(1, scaled_width)
end

function module.resolve_dialog_position(x, y)
    local point = module.scale_point({x = x, y = y})
    return _as_number(point.x, 0),
        _as_number(point.y, 0)
end

function module.round(value)
    return _round(value)
end

return module

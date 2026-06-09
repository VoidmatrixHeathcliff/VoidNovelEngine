local module = {}

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

function module.render_canvas(blueprint, context)
    local render_context = type(context) == "table" and context or {}
    blueprint._flow_view_performance_context = _clone_value(
    {
        render_mode = render_context.render_mode,
        host_size = render_context.host_size,
        popup_open = render_context.popup_open == true,
    })
    if type(render_context.render) == "function" then
        return render_context.render()
    end
    return nil
end

function module.get_last_context(blueprint)
    return _clone_value(blueprint and blueprint._flow_view_performance_context or nil)
end

return module

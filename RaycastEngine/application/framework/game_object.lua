local module = {}

local function get_id(o)
    return o._id
end

local function on_update(o, delta)

end

local function on_render(o)

end

local function make_invalid(o)
    o._valid = false
end

module.new = function(id, z_idx)
    local o = 
    {
        _id = id or "",
        _z_idx = z_idx or 0,
        _valid = true,
        _metaname = "GameObject",

        get_id = get_id,
        on_update = on_update,
        on_render = on_render,
        make_invalid = make_invalid,

        __tostring = function(o)
            return o._metaname
        end
    }
    setmetatable(o, o)
    o.__index = o
    return o
end

return module
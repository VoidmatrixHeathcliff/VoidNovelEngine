local module = {}

local function _deep_copy(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, child in pairs(value) do
        copy[_deep_copy(key, seen)] = _deep_copy(child, seen)
    end
    return setmetatable(copy, getmetatable(value))
end

module.deep_copy = function(value)
    return _deep_copy(value)
end

return module

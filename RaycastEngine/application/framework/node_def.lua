local NodeRegistry = require("application.framework.node_registry")

local module = {}

local metatable =
{
    __index = function(_, key)
        return NodeRegistry.get(key)
    end,
    __pairs = function()
        local list = NodeRegistry.list()
        local index = 0
        return function()
            index = index + 1
            local definition = list[index]
            if not definition then
                return nil
            end
            return definition.type_id, definition
        end
    end
}

setmetatable(module, metatable)

return module

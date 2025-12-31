local module = {}

module.create_context = function(is_modify)
    return {is_modify = is_modify}
end

local global_context = module.create_context()
local current_context = global_context

module.get_context = function()
    return current_context
end

module.set_context = function(context)
    current_context = context or global_context
end

module.set_modify = function(flag)
    current_context.is_modify = flag
end

module.is_modify = function()
    return current_context.is_modify
end

return module
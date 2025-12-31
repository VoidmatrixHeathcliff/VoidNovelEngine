local module = {}

local ModifyManager = require("application.framework.modify_manager")

module.create_context = function()
    return
    {
        stack_undo = {},
        stack_redo = {},
    }
end

local global_context = module.create_context()
local current_context = global_context

module.set_context = function(context)
    current_context = context or global_context
end

module.record = function(on_undo, on_redo, userdata)
    ModifyManager.set_modify(true)
    table.insert(current_context.stack_undo, {on_undo = on_undo, on_redo = on_redo, userdata = userdata})
    if #current_context.stack_redo > 0 then current_context.stack_redo = {} end
end

module.undo = function()
    local idx = #current_context.stack_undo
    local obj = current_context.stack_undo[idx]
    if obj then
        ModifyManager.set_modify(true)
        if obj.on_undo then obj.on_undo(obj.userdata) end
        table.remove(current_context.stack_undo, idx)
        table.insert(current_context.stack_redo, obj)
    end
end

module.redo = function()
    local idx = #current_context.stack_redo
    local obj = current_context.stack_redo[idx]
    if obj then
        ModifyManager.set_modify(true)
        if obj.on_redo then obj.on_redo(obj.userdata) end
        table.remove(current_context.stack_redo, idx)
        table.insert(current_context.stack_undo, obj)
    end
end

module.clear = function()
    current_context.stack_undo = {}
    current_context.stack_redo = {}
end

return module
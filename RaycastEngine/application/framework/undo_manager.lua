local module = {}

local ModifyManager = require("application.framework.modify_manager")

local max_undo_records <const> = 300
local max_redo_records <const> = 300

module.create_context = function()
    return
    {
        stack_undo = {},
        stack_redo = {},
        group_stack = {},
    }
end

local global_context = module.create_context()
local current_context = global_context

module.get_context = function()
    return current_context
end

local function _clear_redo_stack(context)
    if #context.stack_redo > 0 then
        context.stack_redo = {}
    end
end

local function _trim_stack(stack, limit)
    limit = math.max(1, math.floor(tonumber(limit) or 1))
    while #stack > limit do
        table.remove(stack, 1)
    end
end

local function _push_record(context, record)
    local group_stack = context.group_stack or {}
    local group = group_stack[#group_stack]
    if group then
        table.insert(group.record_list, record)
        return
    end

    table.insert(context.stack_undo, record)
    _trim_stack(context.stack_undo, max_undo_records)
    _clear_redo_stack(context)
end

module.set_context = function(context)
    current_context = context or global_context
end

module.record = function(on_undo, on_redo, userdata)
    ModifyManager.set_modify(true)
    _push_record(current_context, {on_undo = on_undo, on_redo = on_redo, userdata = userdata})
end

module.begin_group = function(label)
    table.insert(current_context.group_stack, {label = label, record_list = {}})
end

module.end_group = function()
    local group_stack = current_context.group_stack or {}
    local idx = #group_stack
    local group = group_stack[idx]
    if not group then
        return false
    end

    table.remove(group_stack, idx)
    if #group.record_list == 0 then
        return false
    end

    local record = nil
    if #group.record_list == 1 then
        record = group.record_list[1]
        if group.label and record.label == nil then
            record.label = group.label
        end
    else
        record =
        {
            label = group.label,
            userdata = group.record_list,
            on_undo = function(record_list)
                for index = #record_list, 1, -1 do
                    local item = record_list[index]
                    if item and item.on_undo then
                        item.on_undo(item.userdata)
                    end
                end
            end,
            on_redo = function(record_list)
                for index = 1, #record_list do
                    local item = record_list[index]
                    if item and item.on_redo then
                        item.on_redo(item.userdata)
                    end
                end
            end,
        }
    end

    _push_record(current_context, record)
    return true
end

module.cancel_group = function()
    local group_stack = current_context.group_stack or {}
    local idx = #group_stack
    if idx == 0 then
        return false
    end

    table.remove(group_stack, idx)
    return true
end

module.undo = function()
    local idx = #current_context.stack_undo
    local obj = current_context.stack_undo[idx]
    if obj then
        ModifyManager.set_modify(true)
        if obj.on_undo then obj.on_undo(obj.userdata) end
        table.remove(current_context.stack_undo, idx)
        table.insert(current_context.stack_redo, obj)
        _trim_stack(current_context.stack_redo, max_redo_records)
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
        _trim_stack(current_context.stack_undo, max_undo_records)
    end
end

module.clear = function()
    current_context.stack_undo = {}
    current_context.stack_redo = {}
    current_context.group_stack = {}
end

module.get_context_stats = function(context)
    context = context or current_context
    return
    {
        undo_count = #(context.stack_undo or {}),
        redo_count = #(context.stack_redo or {}),
        group_depth = #(context.group_stack or {}),
        max_undo_records = max_undo_records,
        max_redo_records = max_redo_records,
    }
end

return module

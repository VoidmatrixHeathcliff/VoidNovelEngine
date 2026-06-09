local rl = Engine.Raylib

local module = {}

local function _now()
    return rl.GetTime()
end

module.new = function()
    return
    {
        entry_by_guid = {},
        next_ticket_id = 0,
    }
end

module.ensure_entry = function(cache, meta_or_guid, asset_type)
    if not cache then
        return nil
    end

    local guid = type(meta_or_guid) == "table" and meta_or_guid.guid or meta_or_guid
    if not guid then
        return nil
    end

    local entry = cache.entry_by_guid[guid]
    if not entry then
        entry =
        {
            guid = guid,
            type = type(meta_or_guid) == "table" and meta_or_guid.type or asset_type,
            state = "unloaded",
            preview_state = "unloaded",
            object = nil,
            preview_object = nil,
            retired_object_list = {},
            retired_preview_list = {},
            keepalive_ticket_pool = {},
            keepalive_count = 0,
            generation = 0,
            last_used_time = 0,
            last_preview_used_time = 0,
            load_error = nil,
            preview_load_error = nil,
        }
        cache.entry_by_guid[guid] = entry
    end

    if type(meta_or_guid) == "table" then
        entry.type = meta_or_guid.type or entry.type
    elseif asset_type then
        entry.type = asset_type
    end

    return entry
end

module.get_entry = function(cache, guid)
    if not cache or not guid then
        return nil
    end
    return cache.entry_by_guid[guid]
end

module.touch_runtime = function(entry, now_time)
    if not entry then
        return
    end
    entry.last_used_time = now_time or _now()
end

module.touch_preview = function(entry, now_time)
    if not entry then
        return
    end
    entry.last_preview_used_time = now_time or _now()
end

module.acquire_keepalive = function(cache, entry, reason, usage)
    if not cache or not entry then
        return nil
    end

    cache.next_ticket_id = cache.next_ticket_id + 1
    local ticket =
    {
        id = cache.next_ticket_id,
        guid = entry.guid,
        usage = usage or "runtime",
    }
    entry.keepalive_ticket_pool[ticket.id] =
    {
        reason = reason,
        usage = ticket.usage,
    }
    entry.keepalive_count = entry.keepalive_count + 1
    module.touch_runtime(entry)
    return ticket
end

module.release_keepalive = function(cache, ticket)
    if not cache or not ticket or not ticket.guid or not ticket.id then
        return false
    end

    local entry = cache.entry_by_guid[ticket.guid]
    if not entry then
        return false
    end

    if not entry.keepalive_ticket_pool[ticket.id] then
        return false
    end

    entry.keepalive_ticket_pool[ticket.id] = nil
    entry.keepalive_count = math.max(0, (entry.keepalive_count or 0) - 1)
    return true
end

local function _is_empty_entry(entry)
    return entry
        and entry.object == nil
        and entry.preview_object == nil
        and #(entry.retired_object_list or {}) == 0
        and #(entry.retired_preview_list or {}) == 0
        and (entry.keepalive_count or 0) <= 0
end

module.sweep_empty_entries = function(cache, keep_func)
    if not cache then
        return 0
    end

    local removed_count = 0
    for guid, entry in pairs(cache.entry_by_guid or {}) do
        local keep = type(keep_func) == "function" and keep_func(entry) == true or false
        if not keep and _is_empty_entry(entry) then
            cache.entry_by_guid[guid] = nil
            removed_count = removed_count + 1
        end
    end
    return removed_count
end

module.count_entries = function(cache)
    local count = 0
    for _ in pairs(cache and cache.entry_by_guid or {}) do
        count = count + 1
    end
    return count
end

module.iter_entries = function(cache)
    local list = {}
    if not cache then
        return list
    end

    for _, entry in pairs(cache.entry_by_guid or {}) do
        table.insert(list, entry)
    end

    table.sort(list, function(left, right)
        return (left.guid or "") < (right.guid or "")
    end)

    return list
end

return module

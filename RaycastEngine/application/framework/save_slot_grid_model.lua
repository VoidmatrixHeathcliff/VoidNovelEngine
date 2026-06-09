local SaveLocation = require("application.framework.save_location")
local ResourceIndex = require("application.framework.resource_index")

local module = {}

local save_manager_module = false

local function _get_save_manager()
    if save_manager_module == false then
        save_manager_module = require("application.framework.save_manager")
    end
    return save_manager_module
end

local function _trim(text)
    if type(text) ~= "string" then
        return nil
    end

    local value = text:match("^%s*(.-)%s*$")
    if value == "" then
        return nil
    end
    return value
end

local function _basename(path)
    local value = _trim(path)
    if not value then
        return nil
    end
    return value:gsub("\\", "/"):match("([^/]+)$") or value
end

local function _has_flow_extension(text)
    return type(text) == "string" and text:match("%.[Ff][Ll][Oo][Ww]$") ~= nil
end

local function _has_story_extension(text)
    return type(text) == "string" and text:match("%.[Vv][Nn][Ss]$") ~= nil
end

local function _normalize_page(value, total_pages)
    return math.max(1, math.min(math.max(1, math.floor(tonumber(total_pages) or 1)), math.floor(tonumber(value) or 1)))
end

function module.get_profile_options()
    local info = nil
    local ok, result = pcall(function()
        return _get_save_manager().get_effective_storage_info()
    end)
    if ok and type(result) == "table" then
        info = result
    end

    local profile = type(info) == "table" and info.profile or nil
    local manual = type(profile) == "table" and type(profile.manual) == "table" and profile.manual or nil
    return
    {
        category = "manual",
        page_count = math.max(1, math.floor(tonumber(manual and manual.page_count) or SaveLocation.get_default_page_count())),
        slots_per_page = math.max(1, math.floor(tonumber(manual and manual.slots_per_page) or SaveLocation.get_default_slots_per_page())),
    }
end

function module.normalize_page(page, total_pages)
    return _normalize_page(page, total_pages)
end

function module.format_time_short(value)
    local text = _trim(value)
    if not text then
        return ""
    end

    local year, month, day, hour, minute = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T%s](%d%d):(%d%d)")
    if year then
        return string.format("%04d/%d/%d-%02d:%02d", tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute))
    end

    year, month, day, hour, minute = text:match("^(%d%d%d%d)/(%d%d?)/(%d%d?)[T%s%-](%d%d):(%d%d)")
    if year then
        return string.format("%04d/%d/%d-%02d:%02d", tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute))
    end

    return text
end

local function _resolve_save_kind(source)
    if type(source) ~= "table" then
        return source
    end

    return _trim(source.save_kind or source.save_type) or source.category
end

function module.format_type_label(source)
    return SaveLocation.category_label(_resolve_save_kind(source))
end

function module.format_source(manifest, state)
    local runtime_state = type(state) == "table" and type(state.runtime) == "table" and state.runtime or state
    local candidate_list = {}
    local function append_candidate(value)
        local candidate = _trim(value)
        if candidate then
            candidate_list[#candidate_list + 1] = candidate
        end
    end

    append_candidate(manifest and manifest.document_path)
    append_candidate(runtime_state and runtime_state.document_path)
    append_candidate(manifest and manifest.flow_document_name)
    append_candidate(runtime_state and runtime_state.document_name)
    append_candidate(manifest and manifest.document_name)
    append_candidate(manifest and manifest.display_name)
    append_candidate(manifest and manifest.extra and manifest.extra.document)

    for _, candidate in ipairs(candidate_list) do
        local name = _basename(candidate)
        if _has_flow_extension(name) or _has_story_extension(name) then
            return name
        end
    end

    local guid = _trim(manifest and (manifest.document_guid or manifest.flow_document_guid))
        or _trim(runtime_state and runtime_state.document_guid)
    if guid then
        local meta = ResourceIndex.find_by_guid(guid)
        local name = meta and _basename(meta.path or meta.id or meta.display_name)
        if _has_flow_extension(name) or _has_story_extension(name) then
            return name
        end
    end

    for _, candidate in ipairs(candidate_list) do
        local name = _basename(candidate)
        if name then
            local kind = _trim(manifest and manifest.runtime_kind) or _trim(runtime_state and runtime_state.kind)
            if kind == "text" then
                return name .. (name:find("%.") and "" or ".vns")
            end
            return name .. (name:find("%.") and "" or ".flow")
        end
    end

    return "未记录"
end

function module.fit_rect_preserve_aspect(container, source_width, source_height)
    if not container or container.w <= 0 or container.h <= 0 then
        return nil
    end

    local width = tonumber(source_width) or 0
    local height = tonumber(source_height) or 0
    if width <= 0 or height <= 0 then
        width = 16
        height = 9
    end

    local scale = math.min(container.w / width, container.h / height)
    local draw_width = width * scale
    local draw_height = height * scale
    return
    {
        x = container.x + (container.w - draw_width) * 0.5,
        y = container.y + (container.h - draw_height) * 0.5,
        w = draw_width,
        h = draw_height,
    }
end

function module.fit_16_9_rect(container)
    if not container or container.w <= 0 or container.h <= 0 then
        return nil
    end

    return module.fit_rect_preserve_aspect(container, 16, 9)
end

function module.build_slot_view(entry, options)
    local view_options = type(options) == "table" and options or {}
    local is_empty = type(entry) ~= "table" or entry.empty == true
    local page = tonumber(view_options.page) or tonumber(entry and entry.location and entry.location.page) or 1
    local index = tonumber(view_options.index) or tonumber(entry and entry.location and entry.location.index) or 1

    if is_empty then
        return
        {
            empty = true,
            type_label = module.format_type_label(entry or "manual"),
            title = string.format("空存档%d-%d", page, index),
            source_text = "",
            time_text = "",
            thumbnail_path = nil,
        }
    end

    local title = _trim(entry.title)
        or _trim(entry.display_name)
        or _trim(entry.slot_display_name)
        or string.format("存档%d-%d", page, index)
    local thumbnail_path = nil
    local ok_path, resolved_path = pcall(function()
        return _get_save_manager().resolve_thumbnail_path(entry.location or entry.slot_id)
    end)
    if ok_path then
        thumbnail_path = resolved_path
    end

    return
    {
        empty = false,
        type_label = module.format_type_label(entry),
        title = title,
        source_text = module.format_source(entry, view_options.state),
        time_text = module.format_time_short(entry.updated_at or entry.created_at),
        thumbnail_path = thumbnail_path,
    }
end

function module.list_page(page, per_page)
    local options = module.get_profile_options()
    local total_pages = options.page_count
    local count = math.max(1, math.floor(tonumber(per_page) or options.slots_per_page))
    local page_number = _normalize_page(page, total_pages)
    local entries = {}
    local ok, result = pcall(function()
        return _get_save_manager().list_page(options.category, page_number, count)
    end)
    if ok and type(result) == "table" then
        entries = result
    end
    return entries, page_number, count, total_pages
end

return module

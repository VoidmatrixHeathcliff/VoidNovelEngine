local module = {}

local default_slots_per_page <const> = 6
local default_page_count <const> = 20

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

local function _clone_location(location)
    if type(location) ~= "table" then
        return nil
    end
    return
    {
        category = "manual",
        page = location.page,
        index = location.index,
    }
end

local function _positive_integer(value, default_value)
    local number = tonumber(value)
    if number == nil then
        return default_value
    end
    return math.max(1, math.floor(number))
end

local function _slots_per_page(options)
    local value = type(options) == "table" and options.slots_per_page or nil
    return _positive_integer(value, default_slots_per_page)
end

local function _normalize_user_text(text)
    local value = _trim(text)
    if not value then
        return nil
    end
    value = value:gsub("　", " ")
    value = value:gsub("%s+", " ")
    return value
end

function module.get_default_slots_per_page()
    return default_slots_per_page
end

function module.get_default_page_count()
    return default_page_count
end

function module.normalize_category(value)
    return "manual"
end

function module.category_label(category)
    return "手动存档"
end

function module.normalize(value, options)
    local normalize_options = type(options) == "table" and options or {}
    local slots_per_page = _slots_per_page(normalize_options)

    if type(value) == "table" then
        local source = type(value.location) == "table" and value.location or value
        local page = _positive_integer(source.page, 1)
        local index = _positive_integer(source.index or source.slot_index or source.position, 1)
        if index > slots_per_page then
            page = page + math.floor((index - 1) / slots_per_page)
            index = ((index - 1) % slots_per_page) + 1
        end
        return
        {
            category = "manual",
            page = page,
            index = index,
        }
    end

    local text = _normalize_user_text(value)
    if not text then
        return nil
    end

    local direct = module.from_storage_id(text, normalize_options)
    if direct then
        return direct
    end

    local compact = text:gsub("%s+", "")
    if compact == "手动" or compact == "手动存档" then
        return nil
    end

    local page = tonumber(compact:match("第(%d+)页")) or tonumber(compact:match("页(%d+)")) or nil
    local index = tonumber(compact:match("第%d+页第(%d+)位"))
        or tonumber(compact:match("第(%d+)位"))
        or tonumber(compact:match("位置(%d+)"))
        or tonumber(compact:match("(%d+)$"))

    if index == nil or index < 1 then
        return nil
    end

    if page == nil then
        local absolute_index = math.floor(index)
        page = math.floor((absolute_index - 1) / slots_per_page) + 1
        index = ((absolute_index - 1) % slots_per_page) + 1
    end

    return
    {
        category = "manual",
        page = _positive_integer(page, 1),
        index = _positive_integer(index, 1),
    }
end

function module.from_storage_id(slot_id, options)
    local text = _trim(slot_id)
    if not text then
        return nil
    end

    local manual_index = tonumber(text:match("^manual_(%d+)$"))
    if not manual_index then
        return nil
    end

    local slots_per_page = _slots_per_page(options)
    return
    {
        category = "manual",
        page = math.floor((manual_index - 1) / slots_per_page) + 1,
        index = ((manual_index - 1) % slots_per_page) + 1,
    }
end

function module.to_storage_id(location, options)
    local normalized = module.normalize(location, options)
    if not normalized then
        return nil
    end

    local absolute_index = (normalized.page - 1) * _slots_per_page(options) + normalized.index
    return string.format("manual_%04d", absolute_index)
end

function module.to_manifest_location(location, options)
    return _clone_location(module.normalize(location, options))
end

function module.semantic_id(location, options)
    local normalized = module.normalize(location, options)
    if not normalized then
        return nil
    end
    return string.format("manual:p%02d:s%02d", normalized.page, normalized.index)
end

function module.display_name(location, options)
    local normalized = module.normalize(location, options)
    if not normalized then
        return nil
    end
    return string.format("手动存档 第 %d 页 第 %d 位", normalized.page, normalized.index)
end

function module.location_for_page_index(category, page, index, options)
    return module.normalize(
    {
        category = "manual",
        page = page,
        index = index,
    }, options)
end

return module

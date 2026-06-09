local json = Engine.JSON

local NativeIO = require("application.framework.native_io")

local module = {}

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

local function _clone_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[_clone_value(key, seen)] = _clone_value(item, seen)
    end
    return copy
end

local function _normalize_storage_mode(value)
    local mode = _trim(value) or "auto"
    if mode ~= "auto" and mode ~= "game_dir" and mode ~= "pref_path" and mode ~= "custom" then
        return "auto"
    end
    return mode
end

local function _normalize_boolean(value, default_value)
    if value == nil then
        return default_value == true
    end
    return value == true
end

local function _normalize_number(value, default_value, min_value)
    local number = tonumber(value)
    if number == nil then
        return default_value
    end
    if min_value ~= nil and number < min_value then
        return min_value
    end
    return number
end

local function _normalize_binding_entry(value)
    if type(value) == "string" then
        local binding = _trim(value)
        if not binding then
            return nil
        end
        return {binding = binding}
    end

    if type(value) ~= "table" then
        return nil
    end

    local result = {}
    if _trim(value.binding) then
        result.binding = _trim(value.binding)
    end
    if value.literal ~= nil then
        result.literal = _clone_value(value.literal)
    end
    if _trim(value.fallback) then
        result.fallback = _trim(value.fallback)
    end

    if result.binding == nil and result.literal == nil and result.fallback == nil then
        return nil
    end
    return result
end

local function _normalize_binding_map(value)
    local normalized = {}
    if type(value) ~= "table" then
        return normalized
    end

    for key, item in pairs(value) do
        if _trim(key) then
            local entry = _normalize_binding_entry(item)
            if entry then
                normalized[key] = entry
            end
        end
    end
    return normalized
end

local default_profile =
{
    version = 1,
    storage =
    {
        mode = "auto",
        custom_root = "",
        subdirectory_name = "save",
    },
    manifest =
    {
        title = {binding = "runtime.display_name"},
        summary = {binding = "runtime.location_text"},
        extra =
        {
            runtime_kind = {binding = "runtime.kind"},
            document = {binding = "runtime.document_path"},
        },
    },
    manual =
    {
        page_count = 20,
        slots_per_page = 6,
    },
    thumbnail =
    {
        enabled = true,
        width = 480,
        height = 270,
    },
    debug =
    {
        pretty_json = true,
    },
}

module.clone = function(value)
    return _clone_value(value)
end

module.normalize = function(raw_profile)
    local profile = _clone_value(default_profile)
    local source = type(raw_profile) == "table" and raw_profile or {}

    profile.version = _normalize_number(source.version, default_profile.version, 1)

    local storage = type(source.storage) == "table" and source.storage or {}
    profile.storage.mode = _normalize_storage_mode(storage.mode)
    profile.storage.custom_root = _trim(storage.custom_root) or ""
    profile.storage.subdirectory_name = "save"

    local manifest = type(source.manifest) == "table" and source.manifest or {}
    profile.manifest.title = _normalize_binding_entry(manifest.title) or _clone_value(default_profile.manifest.title)
    profile.manifest.summary = _normalize_binding_entry(manifest.summary) or _clone_value(default_profile.manifest.summary)
    profile.manifest.extra = _normalize_binding_map(manifest.extra)
    for key, value in pairs(default_profile.manifest.extra) do
        if profile.manifest.extra[key] == nil then
            profile.manifest.extra[key] = _clone_value(value)
        end
    end

    local manual = type(source.manual) == "table" and source.manual or {}
    profile.manual.page_count = math.max(1, math.floor(_normalize_number(manual.page_count, default_profile.manual.page_count, 1)))
    profile.manual.slots_per_page = math.max(1, math.floor(_normalize_number(manual.slots_per_page, default_profile.manual.slots_per_page, 1)))

    local thumbnail = type(source.thumbnail) == "table" and source.thumbnail or {}
    profile.thumbnail.enabled = _normalize_boolean(thumbnail.enabled, default_profile.thumbnail.enabled)
    profile.thumbnail.width = math.max(64, math.floor(_normalize_number(thumbnail.width, default_profile.thumbnail.width, 64)))
    profile.thumbnail.height = math.max(36, math.floor(_normalize_number(thumbnail.height, default_profile.thumbnail.height, 36)))

    profile.debug.pretty_json = true

    return profile
end

module.get_default = function()
    return module.clone(default_profile)
end

module.new_document = function()
    return module.get_default()
end

module.load = function(path)
    if type(path) ~= "string" or path == "" then
        return nil, "无效的 SaveProfile 路径"
    end

    local content, err = NativeIO.read_text(path)
    if not content then
        return nil, err
    end

    local ok, data = json.ParseToLua(content)
    if not ok or type(data) ~= "table" then
        return nil, "SaveProfile JSON 解析失败"
    end

    return module.normalize(data)
end

module.save = function(path, profile, pretty)
    if type(path) ~= "string" or path == "" then
        return false, "无效的 SaveProfile 路径"
    end

    local normalized = module.normalize(profile)
    local content = json.PrintFromLua(normalized, pretty == true)
    return NativeIO.write_text(path, content)
end

return module

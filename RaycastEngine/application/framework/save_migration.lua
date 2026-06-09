local module = {}

local SaveLocation = require("application.framework.save_location")

local current_versions =
{
    slot_manifest = 2,
    slot_state = 1,
    global_state = 1,
    runtime_settings = 1,
}

local migration_step_pool =
{
    slot_manifest = {},
    slot_state = {},
    global_state = {},
    runtime_settings = {},
}

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
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

local function _ensure_table(value)
    return type(value) == "table" and value or {}
end

local function _safe_integer(value, default_value)
    local number = tonumber(value)
    if number == nil then
        return default_value or 0
    end
    return math.floor(number)
end

local function _normalize_slot_category(value)
    return "manual"
end

migration_step_pool.slot_manifest[1] = function(source)
    local migrated = _clone_value(source)
    local location = SaveLocation.normalize(migrated.location)
        or SaveLocation.from_storage_id(migrated.slot_id)
        or SaveLocation.normalize(migrated.slot_id, {category = migrated.category})
    if location then
        migrated.location = SaveLocation.to_manifest_location(location)
    end
    return migrated
end

local function _migrate_domain(domain_key, source)
    if type(source) ~= "table" then
        return nil, "数据不是有效的对象"
    end

    local current_version = current_versions[domain_key] or 1
    local version = tonumber(source.schema_version)
    if version == nil then
        version = 1
    end
    version = math.max(1, math.floor(version))

    if version > current_version then
        return nil, string.format("schema_version=%d 高于当前引擎支持的版本 %d", version, current_version)
    end

    local migrated = _clone_value(source)
    while version < current_version do
        local step = migration_step_pool[domain_key] and migration_step_pool[domain_key][version] or nil
        if type(step) ~= "function" then
            return nil, string.format("缺少从版本 %d 迁移到版本 %d 的处理逻辑", version, version + 1)
        end

        migrated = step(migrated) or migrated
        version = version + 1
        migrated.schema_version = version
    end

    migrated.schema_version = current_version
    return migrated
end

module.current_versions = current_versions

module.migrate_slot_manifest = function(source, context)
    local migrated, err = _migrate_domain("slot_manifest", source)
    if not migrated then
        return nil, string.format("存档 manifest 迁移失败：%s", tostring(err))
    end

    local normalized = _ensure_table(migrated)
    local location = SaveLocation.normalize(normalized.location)
        or SaveLocation.from_storage_id(normalized.slot_id)
        or SaveLocation.normalize(context and context.location)
        or SaveLocation.from_storage_id(context and context.slot_id)
        or SaveLocation.normalize(context and context.slot_id, {category = context and context.category})
    normalized.location = SaveLocation.to_manifest_location(location)
    normalized.slot_id = SaveLocation.to_storage_id(location) or _trim(normalized.slot_id) or _trim(context and context.slot_id) or ""
    normalized.category = location and location.category or _normalize_slot_category(normalized.category or (context and context.category))
    normalized.slot_display_name = SaveLocation.display_name(location) or normalized.slot_display_name
    normalized.title = _trim(normalized.title) or normalized.slot_id
    normalized.summary = _trim(normalized.summary) or ""
    normalized.created_at = _trim(normalized.created_at or normalized.updated_at or normalized.save_time) or ""
    normalized.updated_at = _trim(normalized.updated_at or normalized.created_at or normalized.save_time) or normalized.created_at
    normalized.runtime_kind = _trim(normalized.runtime_kind) or "unknown"
    normalized.display_name = _trim(normalized.display_name) or ""
    normalized.location_text = _trim(normalized.location_text) or ""
    normalized.document_guid = _trim(normalized.document_guid) or ""
    normalized.document_path = _trim(normalized.document_path) or ""
    normalized.project_guid = _trim(normalized.project_guid) or _trim(context and context.project_guid) or ""
    normalized.project_version = _trim(normalized.project_version) or _trim(context and context.project_version) or ""
    normalized.engine_version = _trim(normalized.engine_version) or _trim(context and context.engine_version) or ""
    normalized.save_profile_guid = _trim(normalized.save_profile_guid) or _trim(context and context.save_profile_guid) or ""
    normalized.playtime_ms = math.max(0, _safe_integer(normalized.playtime_ms, 0))
    normalized.extra = _ensure_table(normalized.extra)

    if type(normalized.thumbnail) == "table" then
        normalized.thumbnail =
        {
            relative_path = _trim(normalized.thumbnail.relative_path or normalized.thumbnail.path) or "",
            width = math.max(0, _safe_integer(normalized.thumbnail.width, 0)),
            height = math.max(0, _safe_integer(normalized.thumbnail.height, 0)),
        }
        if normalized.thumbnail.relative_path == "" then
            normalized.thumbnail = nil
        end
    else
        normalized.thumbnail = nil
    end

    return normalized
end

module.migrate_slot_state = function(source, context)
    local migrated, err = _migrate_domain("slot_state", source)
    if not migrated then
        return nil, string.format("存档状态迁移失败：%s", tostring(err))
    end

    local normalized = _ensure_table(migrated)
    normalized.project_guid = _trim(normalized.project_guid) or _trim(context and context.project_guid) or ""
    normalized.project_version = _trim(normalized.project_version) or _trim(context and context.project_version) or ""
    normalized.engine_version = _trim(normalized.engine_version) or _trim(context and context.engine_version) or ""
    normalized.project_key = _trim(normalized.project_key) or ""
    normalized.save_profile_guid = _trim(normalized.save_profile_guid) or _trim(context and context.save_profile_guid) or ""
    normalized.slot_id = _trim(normalized.slot_id) or _trim(context and context.slot_id) or ""
    normalized.save_time = _trim(normalized.save_time) or ""
    normalized.runtime = _ensure_table(normalized.runtime)
    normalized.scene = _ensure_table(normalized.scene)
    normalized.ui = _ensure_table(normalized.ui)
    normalized.globals = _ensure_table(normalized.globals)
    normalized.style = _ensure_table(normalized.style)
    normalized.audio = _ensure_table(normalized.audio)
    normalized.services = _ensure_table(normalized.services)
    normalized.checkpoint = _ensure_table(normalized.checkpoint)
    normalized.checkpoint.checkpoint_id = _trim(normalized.checkpoint.checkpoint_id) or ""
    normalized.checkpoint.checkpoint_kind = _trim(normalized.checkpoint.checkpoint_kind) or "stable_boundary"

    normalized.custom_data = _ensure_table(normalized.custom_data)
    normalized.custom_data.slot = _ensure_table(normalized.custom_data.slot)
    normalized.custom_data.global = _ensure_table(normalized.custom_data.global)
    normalized.custom_data.settings = _ensure_table(normalized.custom_data.settings)

    return normalized
end

module.migrate_global_state = function(source, context)
    local migrated, err = _migrate_domain("global_state", source)
    if not migrated then
        return nil, string.format("全局持久化数据迁移失败：%s", tostring(err))
    end

    local normalized = _ensure_table(migrated)
    normalized.project_guid = _trim(normalized.project_guid) or _trim(context and context.project_guid) or ""
    normalized.project_version = _trim(normalized.project_version) or _trim(context and context.project_version) or ""
    normalized.engine_version = _trim(normalized.engine_version) or _trim(context and context.engine_version) or ""
    normalized.seen_text = _ensure_table(normalized.seen_text)
    normalized.visited_events = _ensure_table(normalized.visited_events)
    normalized.unlocks = _ensure_table(normalized.unlocks)
    normalized.custom_data = _ensure_table(normalized.custom_data)

    if type(normalized.last_continue) == "table" then
        normalized.last_continue =
        {
            slot_id = _trim(normalized.last_continue.slot_id) or "",
            updated_at = _trim(normalized.last_continue.updated_at) or "",
        }
        if normalized.last_continue.slot_id == "" then
            normalized.last_continue = nil
        end
    else
        normalized.last_continue = nil
    end

    return normalized
end

module.migrate_runtime_settings = function(source, context)
    local migrated, err = _migrate_domain("runtime_settings", source)
    if not migrated then
        return nil, string.format("运行时设置数据迁移失败：%s", tostring(err))
    end

    local normalized = _ensure_table(migrated)
    normalized.project_guid = _trim(normalized.project_guid) or _trim(context and context.project_guid) or ""
    normalized.project_version = _trim(normalized.project_version) or _trim(context and context.project_version) or ""
    normalized.engine_version = _trim(normalized.engine_version) or _trim(context and context.engine_version) or ""
    normalized.data = _ensure_table(normalized.data)
    return normalized
end

return module

local ModifyManager = require("application.framework.modify_manager")
local ResourceIndex = require("application.framework.resource_index")
local SettingsManager = require("application.framework.settings_manager")
local UI = require("application.framework.ui")
local UIDocument = require("application.framework.ui_document")

local module = {}

local document_list = {}
local document_by_guid = {}
local workspace_open_guid_list = {}
local workspace_current_guid = ""
local workspace_restore_guid_list = {}
local workspace_restore_current_guid = ""
local workspace_restore_pending_failure = false

local function _clone_guid_list(guid_list)
    local clone = {}
    for _, guid in ipairs(guid_list or {}) do
        table.insert(clone, guid)
    end
    return clone
end

local function _guid_list_equal(left, right)
    if #left ~= #right then
        return false
    end
    for index = 1, #left do
        if left[index] ~= right[index] then
            return false
        end
    end
    return true
end

local function _find_guid_index(guid_list, guid)
    for index, item in ipairs(guid_list or {}) do
        if item == guid then
            return index
        end
    end
    return nil
end

local function _remove_guid(guid_list, guid)
    local index = _find_guid_index(guid_list, guid)
    if not index then
        return false
    end
    table.remove(guid_list, index)
    return true
end

local function _save_workspace_state()
    local persisted_open_guid_list = workspace_restore_pending_failure and workspace_restore_guid_list or workspace_open_guid_list
    local persisted_current_guid = workspace_restore_pending_failure and workspace_restore_current_guid or workspace_current_guid
    SettingsManager.set_workspace_ui_state(persisted_open_guid_list, persisted_current_guid, {silent = true})
end

local function _set_restore_shadow_state(open_guid_list, current_guid, pending_failure)
    workspace_restore_guid_list = _clone_guid_list(open_guid_list)
    workspace_restore_current_guid = current_guid or ""
    workspace_restore_pending_failure = pending_failure == true
end

local function _sync_restore_shadow_to_workspace()
    _set_restore_shadow_state(workspace_open_guid_list, workspace_current_guid, false)
end

local function _resolve_ui_guid(value)
    return ResourceIndex.resolve_guid("ui", value)
end

local function _rebuild_guid_map()
    document_by_guid = {}
    for _, document in ipairs(document_list) do
        if document._resource_guid then
            document_by_guid[document._resource_guid] = document
        end
    end
end

local function _sort_document_list()
    table.sort(document_list, function(left, right)
        return (left._resource_id or left._path or left._id) < (right._resource_id or right._path or right._id)
    end)
end

local function _refresh_display_labels()
    local duplicate_count = {}
    for _, document in ipairs(document_list) do
        local key = document._display_name or document._id
        duplicate_count[key] = (duplicate_count[key] or 0) + 1
    end

    for _, document in ipairs(document_list) do
        local title = document._display_name or document._id
        if duplicate_count[title] and duplicate_count[title] > 1 then
            local suffix = document._resource_id or document._path or ""
            title = string.format("%s (%s)", title, suffix)
        end
        document._tab_label = string.format("%s##%s", title, document._resource_guid or document._path or title)
    end
end

local function _clone_signature(signature)
    if type(signature) ~= "table" then
        return nil
    end
    return {size = signature.size, mtime = signature.mtime}
end

local function _signature_equal(left, right)
    if left == nil and right == nil then
        return true
    end
    if left == nil or right == nil then
        return false
    end
    return left.size == right.size and left.mtime == right.mtime
end

local function _finalize_document_list()
    _sort_document_list()
    _rebuild_guid_map()
    _refresh_display_labels()
end

local function _is_document_modified(document)
    if not document or not document.is_document_loaded or not document:is_document_loaded() then
        return false
    end

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(document._modify_context)
    local modified = ModifyManager.is_modify()
    ModifyManager.set_context(previous_context)
    return modified
end

local function _should_keep_document(document)
    return document._is_open.val or _is_document_modified(document)
end

local function _should_prefer_memory_snapshot(document)
    return document ~= nil and _is_document_modified(document)
end

local function _resolve_document(value)
    if type(value) == "table" and value._is_open ~= nil then
        return value
    end
    return module.find_by_guid(value) or module.find_by_identifier(value)
end

local function _normalize_runtime_resolve_options(options)
    options = type(options) == "table" and options or {}
    return
    {
        allow_unsaved_snapshot = options.allow_unsaved_snapshot == true,
    }
end

local function _ensure_document_loaded(document)
    if not document then
        return false, "无法定位界面文档"
    end

    local ok, err = document:ensure_document_loaded()
    if ok then
        return true
    end
    if document.get_last_load_error then
        err = err or document:get_last_load_error()
    end
    return false, err or "无法加载界面文件"
end

local function _normalize_workspace_open_guid_list()
    local normalized_open_guid_list = {}
    local guid_pool = {}

    for _, guid in ipairs(workspace_open_guid_list or {}) do
        local document = document_by_guid[guid]
        if document and document._is_open.val and not guid_pool[guid] then
            guid_pool[guid] = true
            table.insert(normalized_open_guid_list, guid)
        end
    end

    for _, document in ipairs(document_list) do
        local guid = document._resource_guid
        if guid and document._is_open.val and not guid_pool[guid] then
            guid_pool[guid] = true
            table.insert(normalized_open_guid_list, guid)
        end
    end

    return normalized_open_guid_list, guid_pool
end

function module.begin_load()
    module.unload()
    document_list = {}
    document_by_guid = {}
    workspace_open_guid_list = {}
    workspace_current_guid = ""
    workspace_restore_guid_list = {}
    workspace_restore_current_guid = ""
    workspace_restore_pending_failure = false
end

function module.load_ui_meta(meta)
    local document = UIDocument.new(meta,
    {
        lazy_document = true,
        initial_open = false,
        manager = module,
    })
    table.insert(document_list, document)
    if document._resource_guid then
        document_by_guid[document._resource_guid] = document
    end
    return document
end

function module.finalize_load()
    _finalize_document_list()
end

function module.apply_workspace_state()
    local requested_open_guid_list = SettingsManager.get_open_ui_guid_list and SettingsManager.get_open_ui_guid_list() or {}
    local requested_current_guid = SettingsManager.get_current_ui_guid and SettingsManager.get_current_ui_guid() or ""
    local restore_open_guid_list = {}
    local loaded_open_guid_list = {}
    local has_load_failure = false

    for _, document in ipairs(document_list) do
        document._is_open.val = false
    end

    for _, guid in ipairs(requested_open_guid_list) do
        local document = document_by_guid[guid]
        if document then
            table.insert(restore_open_guid_list, guid)
            local loaded_ok = _ensure_document_loaded(document)
            if loaded_ok then
                document._is_open.val = true
                table.insert(loaded_open_guid_list, guid)
            else
                document._is_open.val = false
                has_load_failure = true
            end
        end
    end

    workspace_open_guid_list = loaded_open_guid_list
    workspace_current_guid = ""

    if requested_current_guid ~= "" then
        local document = document_by_guid[requested_current_guid]
        if document and document._is_open.val then
            workspace_current_guid = requested_current_guid
        end
    end

    if workspace_current_guid == "" then
        workspace_current_guid = loaded_open_guid_list[1] or ""
    end

    if has_load_failure then
        local restore_current_guid = ""
        if requested_current_guid ~= "" and _find_guid_index(restore_open_guid_list, requested_current_guid) then
            restore_current_guid = requested_current_guid
        else
            restore_current_guid = restore_open_guid_list[1] or ""
        end
        -- 保留启动恢复目标，但不把失败文档混进实际打开标签列表。
        _set_restore_shadow_state(restore_open_guid_list, restore_current_guid, true)
        return
    end

    _sync_restore_shadow_to_workspace()
    _save_workspace_state()
end

function module.load()
    module.begin_load()
    for _, meta in ipairs(ResourceIndex.list_by_type("ui")) do
        module.load_ui_meta(meta)
    end
    module.finalize_load()
    module.apply_workspace_state()
end

function module.reconcile()
    local next_document_list = {}
    local existing_pool = {}

    for _, document in ipairs(document_list) do
        if document._resource_guid then
            existing_pool[document._resource_guid] = document
        end
    end

    for _, meta in ipairs(ResourceIndex.list_by_type("ui")) do
        local document = existing_pool[meta.guid]
        if document then
            existing_pool[meta.guid] = nil
            local previous_signature = _clone_signature(document._resource_file_signature)
            local is_loaded = document.is_document_loaded and document:is_document_loaded()
            document:update_resource_meta(meta)
            document:clear_resource_missing()
            if previous_signature and not _signature_equal(previous_signature, meta.file_signature) and is_loaded then
                if _is_document_modified(document) then
                    document:mark_external_change(meta)
                elseif document.reload_from_disk then
                    local reload_ok = document:reload_from_disk({silent = true})
                    if not reload_ok then
                        document:mark_external_change(meta)
                    end
                elseif document.unload_document then
                    document:unload_document()
                end
            end
            table.insert(next_document_list, document)
        else
            table.insert(next_document_list, UIDocument.new(meta,
            {
                lazy_document = true,
                initial_open = false,
                manager = module,
            }))
        end
    end

    for _, document in pairs(existing_pool) do
        if _should_keep_document(document) then
            document:mark_resource_missing()
            table.insert(next_document_list, document)
        elseif document.dispose then
            document:dispose()
        end
    end

    document_list = next_document_list
    _finalize_document_list()
    module.sync_workspace_state()
end

function module.find_by_guid(guid)
    local normalized_guid = _resolve_ui_guid(guid)
    if not normalized_guid then
        return nil
    end
    return document_by_guid[normalized_guid]
end

function module.find_by_identifier(identifier)
    local document = module.find_by_guid(identifier)
    if document then
        return document
    end

    for _, item in ipairs(document_list) do
        if identifier == item._id
            or identifier == item._resource_id
            or identifier == item._path
        then
            return item
        end
    end
    return nil
end

function module.get_ui_document(value)
    local document = _resolve_document(value)
    if not document then
        return nil
    end
    local loaded_ok, err = _ensure_document_loaded(document)
    if not loaded_ok then
        return nil, err
    end
    return document
end

function module.open_ui_in_workspace(value, options)
    local document = _resolve_document(value)
    local open_options = options or {}
    if not document then
        return nil
    end

    local loaded_ok, err = _ensure_document_loaded(document)
    if not loaded_ok then
        return nil, err
    end

    document._is_open.val = true

    if document._resource_guid and not _find_guid_index(workspace_open_guid_list, document._resource_guid) then
        table.insert(workspace_open_guid_list, document._resource_guid)
    end

    if open_options.select ~= false and document._resource_guid then
        workspace_current_guid = document._resource_guid
    end

    _sync_restore_shadow_to_workspace()
    _save_workspace_state()
    return document
end

function module.close_ui_in_workspace(value)
    local document = _resolve_document(value)
    if not document then
        return false
    end

    document._is_open.val = false
    if document._resource_guid then
        _remove_guid(workspace_open_guid_list, document._resource_guid)
        if workspace_current_guid == document._resource_guid then
            workspace_current_guid = workspace_open_guid_list[1] or ""
        end
    end

    _sync_restore_shadow_to_workspace()
    _save_workspace_state()
    return true
end

function module.set_workspace_current_ui(value)
    local document = _resolve_document(value)
    local next_current_guid = ""
    if document and document._is_open and document._is_open.val then
        next_current_guid = document._resource_guid or ""
    end

    if workspace_current_guid == next_current_guid then
        return false
    end

    workspace_current_guid = next_current_guid
    _sync_restore_shadow_to_workspace()
    _save_workspace_state()
    return true
end

function module.sync_workspace_state()
    local normalized_open_guid_list, open_guid_pool = _normalize_workspace_open_guid_list()
    local next_current_guid = workspace_current_guid

    if next_current_guid ~= "" and not open_guid_pool[next_current_guid] then
        next_current_guid = ""
    end
    if next_current_guid == "" then
        next_current_guid = normalized_open_guid_list[1] or ""
    end

    if _guid_list_equal(workspace_open_guid_list, normalized_open_guid_list)
        and workspace_current_guid == next_current_guid
    then
        return false
    end

    workspace_open_guid_list = normalized_open_guid_list
    workspace_current_guid = next_current_guid
    if not workspace_restore_pending_failure then
        _sync_restore_shadow_to_workspace()
    end
    _save_workspace_state()
    return true
end

function module.get_workspace_open_documents()
    local result = {}
    local guid_pool = {}

    for _, guid in ipairs(workspace_open_guid_list) do
        local document = document_by_guid[guid]
        if document and document._is_open.val and not guid_pool[guid] then
            guid_pool[guid] = true
            table.insert(result, document)
        end
    end

    for _, document in ipairs(document_list) do
        local guid = document._resource_guid
        if guid and document._is_open.val and not guid_pool[guid] then
            guid_pool[guid] = true
            table.insert(result, document)
        end
    end

    return result
end

function module.get_workspace_current_guid()
    return workspace_current_guid
end

function module.get_workspace_current_document()
    local document = document_by_guid[workspace_current_guid] or nil
    if document and document._is_open and document._is_open.val then
        return document
    end
    return nil
end

function module.resolve_runtime_document(reference, options)
    local resolve_options = _normalize_runtime_resolve_options(options)
    local guid = ResourceIndex.resolve_guid("ui", reference)
    if not guid then
        return nil, "找不到界面资源"
    end

    local document = document_by_guid[guid]
    if resolve_options.allow_unsaved_snapshot and _should_prefer_memory_snapshot(document) then
        local loaded_ok, err = _ensure_document_loaded(document)
        if not loaded_ok then
            return nil, err or "无法加载界面文件"
        end
        return
        {
            guid = guid,
            path = document._path,
            document = document:get_document_snapshot(),
        }
    end

    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return nil, "界面资源不存在"
    end

    local loaded_document, err = UI.load(meta.path)
    if not loaded_document then
        return nil, err or "无法加载界面文件"
    end

    return
    {
        guid = guid,
        path = meta.path,
        document = loaded_document,
    }
end

function module.get_all_documents()
    local result = {}
    for index, document in ipairs(document_list) do
        result[index] = document
    end
    return result
end

function module.save_all()
    for _, document in ipairs(document_list) do
        if document._is_open.val or document:is_modified() then
            document:save_document()
        end
    end
end

function module.unload()
    for _, document in ipairs(document_list) do
        if document.dispose then
            document:dispose()
        end
    end
    document_list = {}
    document_by_guid = {}
    workspace_open_guid_list = {}
    workspace_current_guid = ""
    workspace_restore_guid_list = {}
    workspace_restore_current_guid = ""
    workspace_restore_pending_failure = false
end

return module

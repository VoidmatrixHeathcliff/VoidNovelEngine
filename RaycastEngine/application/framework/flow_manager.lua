local module = {}

local rl = Engine.Raylib
local util = Engine.Util

local Blueprint = require("application.framework.blueprint")
local FlowTextDocument = require("application.framework.flow_text_document")
local GlobalContext = require("application.framework.global_context")
local ModifyManager = require("application.framework.modify_manager")
local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")
local ResourcePolicy = require("application.framework.resource_policy")
local SettingsManager = require("application.framework.settings_manager")

local document_list = {}
local document_by_guid = {}
local workspace_open_guid_list = {}
local workspace_current_guid = ""
local workspace_current_graph_guid = ""
local workspace_current_text_guid = ""

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
    SettingsManager.set_workspace_flow_state(
        workspace_open_guid_list,
        workspace_current_guid,
        {
            silent = true,
            current_graph_flow_guid = workspace_current_graph_guid,
            current_text_flow_guid = workspace_current_text_guid,
        })
end

local function _resolve_flow_guid(value)
    return ResourceIndex.resolve_guid("flow", value)
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

local function _resolve_guid_if_flow(guid)
    local normalized = util.NormalizeGuidString(guid or "")
    if not normalized then
        return nil
    end
    local meta = ResourceIndex.find_by_guid(normalized)
    if meta and meta.type == "flow" then
        return normalized
    end
    return nil
end

local function _resolve_strict_flow_guid(value)
    if type(value) == "table" then
        local guid = _resolve_guid_if_flow(value.guid or value._resource_guid)
        if guid then
            return guid
        end
        return _resolve_strict_flow_guid(value.path_hint or value.relative_path or value.path or value._path)
    end

    local raw_text = _trim(value)
    if not raw_text then
        return nil
    end

    local guid = _resolve_guid_if_flow(raw_text)
    if guid then
        return guid
    end

    guid = ResourceIndex.find_guid_by_path(raw_text)
    if guid then
        return _resolve_guid_if_flow(guid)
    end

    local ext = string.lower(raw_text:match("(%.[^%./\\]+)$") or "")
    if ext == ".flow" or ext == ".vns" then
        guid = ResourceIndex.find_guid_by_file_name("flow", raw_text)
        if guid then
            return _resolve_guid_if_flow(guid)
        end
    end

    return nil
end

local function _uses_strict_flow_locator(usage)
    return usage == "flow_runtime" or usage == "prefetch"
end

local function _find_by_strict_flow_locator(value)
    local guid = _resolve_strict_flow_guid(value)
    if not guid then
        return nil
    end
    return document_by_guid[guid]
end

local function _get_document_ext(meta_or_path)
    local path = type(meta_or_path) == "table" and meta_or_path.path or meta_or_path
    return string.lower(rl.GetFileExtension(path or "") or "")
end

local function _is_graph_document(document)
    return document and document.kind == "graph"
end

local function _is_text_document(document)
    return document and document.kind == "text"
end

local function _update_global_document_views()
    GlobalContext.flow_document_list = document_list

    local graph_list = {}
    for _, document in ipairs(document_list) do
        if _is_graph_document(document) then
            table.insert(graph_list, document)
        end
    end
    GlobalContext.blueprint_list = graph_list
end

local function _resolve_document(value)
    if type(value) == "table" and value._is_open ~= nil then
        return value
    end
    return module.find_by_guid(value) or module.find_by_identifier(value)
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

local function _rebuild_guid_map()
    document_by_guid = {}
    for _, document in ipairs(document_list) do
        if document._resource_guid then
            document_by_guid[document._resource_guid] = document
        end
    end
end

local function _sort_document_list()
    table.sort(document_list, function(a, b)
        local left_kind = a.kind or ""
        local right_kind = b.kind or ""
        if left_kind ~= right_kind then
            return left_kind < right_kind
        end
        return (a._resource_id or a._path or a._id) < (b._resource_id or b._path or b._id)
    end)
end

local function _finalize_document_list()
    _sort_document_list()
    _rebuild_guid_map()
    _refresh_display_labels()
    _update_global_document_views()
end

local function _is_document_modified(document)
    if not document or not document.is_document_loaded or not document:is_document_loaded() then
        return false
    end

    if document.is_modified then
        return document:is_modified()
    end

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(document._modify_context)
    local is_modified = ModifyManager.is_modify()
    ModifyManager.set_context(previous_context)
    return is_modified
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

local function _get_runtime_document()
    if GlobalContext.get_runtime_flow_document then
        return GlobalContext.get_runtime_flow_document()
    end
    return GlobalContext.current_flow_document
end

local function _should_keep_document(document)
    local runtime_document = _get_runtime_document()
    return document._is_open.val
        or _is_document_modified(document)
        or GlobalContext.current_flow_document == document
        or GlobalContext.debug_flow_document == document
        or GlobalContext.current_blueprint == document
        or GlobalContext.debug_blueprint == document
        or runtime_document == document
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

local function _create_document_from_meta(meta)
    local ext = _get_document_ext(meta)
    if ext == ".vns" then
        return FlowTextDocument.new(meta, {lazy_document = true, initial_open = false, manager = module})
    end
    return Blueprint.new(meta, {lazy_document = true, initial_open = false})
end

local function _resolve_snapshot_source(value)
    local document = _resolve_document(value)
    if document and document._resource_guid then
        local meta = ResourceIndex.find_by_guid(document._resource_guid)
        if meta then
            return meta
        end
    end

    local normalized_guid = _resolve_flow_guid(value)
    if normalized_guid then
        local meta = ResourceIndex.find_by_guid(normalized_guid)
        if meta then
            return meta
        end
    end

    local path = nil
    if type(value) == "table" then
        path = value.path or value._path
    elseif type(value) == "string" then
        path = value
    end
    if path then
        local meta = ResourceIndex.find_by_path(path)
        if meta then
            return meta
        end
        if NativeIO.file_exists(path) then
            return path
        end
    end

    if document and document._path and NativeIO.file_exists(document._path) then
        return document._path
    end
    return nil
end

module.begin_load = function()
    module.unload()
    document_list = {}
    document_by_guid = {}
    workspace_open_guid_list = {}
    workspace_current_guid = ""
    workspace_current_graph_guid = ""
    workspace_current_text_guid = ""
    _update_global_document_views()
end

module.load_flow_meta = function(meta)
    local document = _create_document_from_meta(meta)
    table.insert(document_list, document)
    if document._resource_guid then
        document_by_guid[document._resource_guid] = document
    end
    _update_global_document_views()
    return document
end

module.load_blueprint_meta = function(meta)
    return module.load_flow_meta(meta)
end

module.finalize_load = function()
    _finalize_document_list()
end

module.apply_workspace_state = function()
    local requested_open_guid_list = SettingsManager.get_open_flow_guid_list()
    local requested_current_guid = SettingsManager.get_current_flow_guid()
    local requested_current_graph_guid = SettingsManager.get_current_graph_flow_guid and SettingsManager.get_current_graph_flow_guid() or ""
    local requested_current_text_guid = SettingsManager.get_current_text_flow_guid and SettingsManager.get_current_text_flow_guid() or ""
    local normalized_open_guid_list = {}

    for _, document in ipairs(document_list) do
        document._is_open.val = false
    end

    for _, guid in ipairs(requested_open_guid_list) do
        local document = document_by_guid[guid]
        if document then
            document._is_open.val = true
            table.insert(normalized_open_guid_list, guid)
        end
    end

    workspace_open_guid_list = normalized_open_guid_list
    workspace_current_guid = ""
    workspace_current_graph_guid = ""
    workspace_current_text_guid = ""

    if requested_current_guid ~= "" then
        local document = document_by_guid[requested_current_guid]
        if document and document._is_open.val then
            workspace_current_guid = requested_current_guid
        end
    end

    if requested_current_graph_guid ~= "" then
        local document = document_by_guid[requested_current_graph_guid]
        if _is_graph_document(document) and document._is_open.val then
            workspace_current_graph_guid = requested_current_graph_guid
        end
    end

    if requested_current_text_guid ~= "" then
        local document = document_by_guid[requested_current_text_guid]
        if _is_text_document(document) and document._is_open.val then
            workspace_current_text_guid = requested_current_text_guid
        end
    end

    if workspace_current_guid == "" then
        workspace_current_guid = workspace_open_guid_list[1] or ""
    end

    if workspace_current_graph_guid == "" then
        for _, guid in ipairs(workspace_open_guid_list) do
            local document = document_by_guid[guid]
            if _is_graph_document(document) then
                workspace_current_graph_guid = guid
                break
            end
        end
    end

    if workspace_current_text_guid == "" then
        for _, guid in ipairs(workspace_open_guid_list) do
            local document = document_by_guid[guid]
            if _is_text_document(document) then
                workspace_current_text_guid = guid
                break
            end
        end
    end

    if workspace_current_guid ~= "" then
        local document = document_by_guid[workspace_current_guid]
        if _is_graph_document(document) then
            GlobalContext.bp_id_selected_next_frame = document._id
        end
    end

    _save_workspace_state()
end

module.sync_workspace_state = function()
    local normalized_open_guid_list, open_guid_pool = _normalize_workspace_open_guid_list()
    local next_current_guid = workspace_current_guid
    local next_current_graph_guid = workspace_current_graph_guid
    local next_current_text_guid = workspace_current_text_guid

    if next_current_guid ~= "" and not open_guid_pool[next_current_guid] then
        next_current_guid = ""
    end

    if next_current_graph_guid ~= "" then
        local document = document_by_guid[next_current_graph_guid]
        if not (document and document._is_open.val and _is_graph_document(document)) then
            next_current_graph_guid = ""
        end
    end

    if next_current_text_guid ~= "" then
        local document = document_by_guid[next_current_text_guid]
        if not (document and document._is_open.val and _is_text_document(document)) then
            next_current_text_guid = ""
        end
    end

    local current_document = GlobalContext.current_flow_document
    if current_document
        and current_document._is_open
        and current_document._is_open.val
        and current_document._resource_guid
        and open_guid_pool[current_document._resource_guid]
    then
        next_current_guid = current_document._resource_guid
    elseif next_current_guid == "" then
        next_current_guid = normalized_open_guid_list[1] or ""
    end

    if current_document
        and current_document._is_open
        and current_document._is_open.val
        and current_document._resource_guid
    then
        if _is_graph_document(current_document) then
            next_current_graph_guid = current_document._resource_guid
        elseif _is_text_document(current_document) then
            next_current_text_guid = current_document._resource_guid
        end
    end

    if next_current_graph_guid == "" then
        for _, guid in ipairs(normalized_open_guid_list) do
            local document = document_by_guid[guid]
            if _is_graph_document(document) then
                next_current_graph_guid = guid
                break
            end
        end
    end

    if next_current_text_guid == "" then
        for _, guid in ipairs(normalized_open_guid_list) do
            local document = document_by_guid[guid]
            if _is_text_document(document) then
                next_current_text_guid = guid
                break
            end
        end
    end

    if _guid_list_equal(workspace_open_guid_list, normalized_open_guid_list)
        and workspace_current_guid == next_current_guid
        and workspace_current_graph_guid == next_current_graph_guid
        and workspace_current_text_guid == next_current_text_guid
    then
        return false
    end

    workspace_open_guid_list = normalized_open_guid_list
    workspace_current_guid = next_current_guid
    workspace_current_graph_guid = next_current_graph_guid
    workspace_current_text_guid = next_current_text_guid
    _save_workspace_state()
    return true
end

module.load = function()
    module.begin_load()
    for _, meta in ipairs(ResourceIndex.list_by_type("flow")) do
        module.load_flow_meta(meta)
    end
    module.finalize_load()
    module.apply_workspace_state()
end

module.reload_index = function()
    module.unload()
    module.load()
end

module.reconcile = function()
    local next_document_list = {}
    local existing_pool = {}

    for _, document in ipairs(document_list) do
        if document._resource_guid then
            existing_pool[document._resource_guid] = document
        end
    end

    for _, meta in ipairs(ResourceIndex.list_by_type("flow")) do
        local document = existing_pool[meta.guid]
        if document then
            existing_pool[meta.guid] = nil
            local previous_signature = _clone_signature(document._resource_file_signature)
            local is_loaded = document.is_document_loaded and document:is_document_loaded()
            document:update_resource_meta(meta)
            document:clear_resource_missing()
            if previous_signature and not _signature_equal(previous_signature, meta.file_signature) and is_loaded then
                document:mark_external_change(meta)
            end
            table.insert(next_document_list, document)
        else
            table.insert(next_document_list, _create_document_from_meta(meta))
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

module.find_by_guid = function(guid)
    local normalized_guid = _resolve_flow_guid(guid)
    if not normalized_guid then
        return nil
    end
    return document_by_guid[normalized_guid]
end

module.find_by_identifier = function(identifier)
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

module.get_document = function(value, usage)
    local document = nil
    if _uses_strict_flow_locator(usage) then
        document = _find_by_strict_flow_locator(value)
    else
        document = module.find_by_guid(value) or module.find_by_identifier(value)
    end
    if not document then
        return nil
    end

    if document.ensure_document_loaded then
        if not document:ensure_document_loaded(usage or "flow_document_open") then
            return nil
        end
    end
    return document
end

module.get_blueprint = function(value, usage)
    return module.get_document(value, usage)
end

module.prefetch = function(value, usage)
    return module.get_document(value, usage or "prefetch")
end

module.open_document_in_workspace = function(value, options)
    local document = _resolve_document(value)
    local open_options = options or {}
    if not document then
        return nil
    end

    if document.ensure_document_loaded then
        if not document:ensure_document_loaded("flow_document_open") then
            return nil
        end
    end

    document._is_open.val = true

    if document._resource_guid and not _find_guid_index(workspace_open_guid_list, document._resource_guid) then
        table.insert(workspace_open_guid_list, document._resource_guid)
    end

    if open_options.select ~= false and document._resource_guid then
        workspace_current_guid = document._resource_guid
        if _is_graph_document(document) then
            workspace_current_graph_guid = document._resource_guid
            GlobalContext.bp_id_selected_next_frame = document._id
        elseif _is_text_document(document) then
            workspace_current_text_guid = document._resource_guid
        end
    end

    _save_workspace_state()
    return document
end

module.open_blueprint_in_workspace = function(value, options)
    return module.open_document_in_workspace(value, options)
end

module.close_document_in_workspace = function(value)
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
        if workspace_current_graph_guid == document._resource_guid then
            workspace_current_graph_guid = ""
            for _, guid in ipairs(workspace_open_guid_list) do
                local next_document = document_by_guid[guid]
                if _is_graph_document(next_document) then
                    workspace_current_graph_guid = guid
                    break
                end
            end
        end
        if workspace_current_text_guid == document._resource_guid then
            workspace_current_text_guid = ""
            for _, guid in ipairs(workspace_open_guid_list) do
                local next_document = document_by_guid[guid]
                if _is_text_document(next_document) then
                    workspace_current_text_guid = guid
                    break
                end
            end
        end
    end

    if GlobalContext.current_flow_document == document then
        GlobalContext.current_flow_document = document_by_guid[workspace_current_guid] or nil
    end
    if GlobalContext.current_blueprint == document then
        GlobalContext.current_blueprint = document_by_guid[workspace_current_graph_guid] or nil
    end
    if GlobalContext.bp_id_selected_next_frame == document._id then
        GlobalContext.bp_id_selected_next_frame = nil
    end

    _save_workspace_state()
    return true
end

module.close_blueprint_in_workspace = function(value)
    return module.close_document_in_workspace(value)
end

module.toggle_document_in_workspace = function(value, options)
    local document = _resolve_document(value)
    if not document then
        return nil
    end

    if document._is_open.val then
        module.close_document_in_workspace(document)
    else
        module.open_document_in_workspace(document, options)
    end

    return document
end

module.toggle_blueprint_in_workspace = function(value, options)
    return module.toggle_document_in_workspace(value, options)
end

module.set_workspace_current_document = function(value)
    local document = _resolve_document(value)
    local next_current_guid = ""
    local next_current_graph_guid = workspace_current_graph_guid
    local next_current_text_guid = workspace_current_text_guid

    if document and document._is_open and document._is_open.val then
        next_current_guid = document._resource_guid or ""
        if _is_graph_document(document) then
            next_current_graph_guid = next_current_guid
        elseif _is_text_document(document) then
            next_current_text_guid = next_current_guid
        end
    end

    if workspace_current_guid == next_current_guid
        and workspace_current_graph_guid == next_current_graph_guid
        and workspace_current_text_guid == next_current_text_guid
    then
        return false
    end

    workspace_current_guid = next_current_guid
    workspace_current_graph_guid = next_current_graph_guid
    workspace_current_text_guid = next_current_text_guid
    _save_workspace_state()
    return true
end

module.set_workspace_current_blueprint = function(value)
    return module.set_workspace_current_document(value)
end

module.get_workspace_open_documents = function()
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

module.get_workspace_open_blueprints = function()
    local result = {}
    for _, document in ipairs(module.get_workspace_open_documents()) do
        if _is_graph_document(document) then
            table.insert(result, document)
        end
    end
    return result
end

module.get_workspace_open_text_documents = function()
    local result = {}
    for _, document in ipairs(module.get_workspace_open_documents()) do
        if _is_text_document(document) then
            table.insert(result, document)
        end
    end
    return result
end

module.get_workspace_open_guid_list = function()
    return _clone_guid_list(workspace_open_guid_list)
end

module.get_workspace_current_guid = function()
    return workspace_current_guid
end

module.get_workspace_current_graph_guid = function()
    return workspace_current_graph_guid
end

module.get_workspace_current_text_guid = function()
    return workspace_current_text_guid
end

module.get_workspace_current_document = function(kind)
    if kind == "graph" then
        return document_by_guid[workspace_current_graph_guid] or nil
    end
    if kind == "text" then
        return document_by_guid[workspace_current_text_guid] or nil
    end
    return document_by_guid[workspace_current_guid] or nil
end

module.get_all_documents = function()
    return document_list
end

module.get_all_blueprints = function()
    return GlobalContext.blueprint_list or {}
end

module.create_runtime_document_snapshot = function(value, options)
    local snapshot_options = type(options) == "table" and options or {}
    local resource_source = _resolve_snapshot_source(value)
    if not resource_source then
        return nil
    end

    local path = type(resource_source) == "table" and resource_source.path or resource_source
    if not path or not NativeIO.file_exists(path) then
        return nil
    end

    local document = _create_document_from_meta(resource_source)
    if not document then
        return nil
    end

    document._is_temporary_runtime_document = true
    if snapshot_options.load ~= false
        and document.ensure_document_loaded
        and not document:ensure_document_loaded(snapshot_options.usage or "flow_runtime")
    then
        if document.dispose then
            document:dispose()
        end
        return nil
    end
    return document
end

module.collect_garbage = function()
    local ttl = ResourcePolicy.get_flow_document_ttl()
    if ttl == math.huge then
        return
    end

    local now_time = rl.GetTime()
    for _, document in ipairs(document_list) do
        if document.is_document_loaded
            and document:is_document_loaded()
            and not _should_keep_document(document)
            and (now_time - (document._document_last_used_time or 0)) >= ttl
        then
            document:unload_document()
        end
    end
end

module.get_stats = function()
    local loaded_document_count = 0
    local open_document_count = 0
    local modified_document_count = 0
    local missing_document_count = 0

    for _, document in ipairs(document_list) do
        if document.is_document_loaded and document:is_document_loaded() then
            loaded_document_count = loaded_document_count + 1
        end
        if document._is_open.val then
            open_document_count = open_document_count + 1
        end
        if _is_document_modified(document) then
            modified_document_count = modified_document_count + 1
        end
        if document._resource_missing then
            missing_document_count = missing_document_count + 1
        end
    end

    return
    {
        total_flow_count = #document_list,
        graph_flow_count = #(GlobalContext.blueprint_list or {}),
        text_flow_count = #document_list - #(GlobalContext.blueprint_list or {}),
        loaded_document_count = loaded_document_count,
        open_document_count = open_document_count,
        modified_document_count = modified_document_count,
        missing_document_count = missing_document_count,
    }
end

module.on_resource_changed = function(meta)
    if not meta or meta.type ~= "flow" then
        return
    end

    local document = document_by_guid[meta.guid]
    if document and document.update_resource_meta then
        document:update_resource_meta(meta)
        _refresh_display_labels()
        _update_global_document_views()
    end
end

module.mark_dependent_text_documents_dirty = function(changed_guid_pool)
    if type(changed_guid_pool) ~= "table" then
        return 0
    end

    local dirty_count = 0
    for _, document in ipairs(document_list) do
        if _is_text_document(document) and document.mark_dependency_changed then
            for guid in pairs(changed_guid_pool) do
                if document:mark_dependency_changed(guid) then
                    dirty_count = dirty_count + 1
                    break
                end
            end
        end
    end
    return dirty_count
end

module.save_all = function()
    for _, document in ipairs(document_list) do
        local is_open = document._is_open and document._is_open.val == true
        local is_modified = document.is_modified and document:is_modified()
        if is_open or is_modified then
            document:save_document()
        end
    end
end

module.unload = function()
    for _, document in ipairs(document_list) do
        if document and document.dispose then
            document:dispose()
        end
    end
    document_list = {}
    document_by_guid = {}
    workspace_open_guid_list = {}
    workspace_current_guid = ""
    workspace_current_graph_guid = ""
    workspace_current_text_guid = ""
    _update_global_document_views()
end

return module

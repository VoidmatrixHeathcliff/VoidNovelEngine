local imgui = Engine.ImGUI
local util = Engine.Util

local Class = require("application.framework.class")
local LogManager = require("application.framework.log_manager")
local ModifyManager = require("application.framework.modify_manager")
local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")
local Style = require("application.framework.style")
local StyleManager = require("application.framework.style_manager")
local UndoManager = require("application.framework.undo_manager")

local StyleDocument = Class.define("StyleDocument")

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

local function _clone_signature(signature)
    if type(signature) ~= "table" then
        return nil
    end
    return {size = signature.size, mtime = signature.mtime}
end

local function _deep_equal(left, right)
    if left == right then
        return true
    end

    if type(left) ~= type(right) then
        return false
    end

    if type(left) ~= "table" then
        return false
    end

    for key, value in pairs(left) do
        if not _deep_equal(value, right[key]) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

local function _get_document_name(self)
    return self._resource_id or self._path or self._id
end

local function _get_file_signature(path)
    local size = util.GetFileSizeUtf8(path)
    local mtime = util.GetFileModifiedTimeUtf8(path)
    if not size or not mtime then
        return nil
    end
    return
    {
        size = size,
        mtime = mtime,
    }
end

local function _ensure_parent_directory(path)
    local directory = type(path) == "string" and path:match("^(.*)[/\\][^/\\]+$") or nil
    if directory and directory ~= "" then
        NativeIO.create_directories(directory)
    end
end

local function _update_resource_meta(self, resource_source)
    local path = resource_source
    local meta = nil
    if type(resource_source) == "table" then
        meta = resource_source
        path = meta.path
    end

    self._path = path
    self._resource_guid = meta and meta.guid or nil
    self._resource_id = meta and meta.id or nil
    self._display_name = meta and meta.display_name or (path and path:match("([^/\\]+)%.style$") or path)
    self._resource_file_signature = meta and _clone_signature(meta.file_signature) or self._resource_file_signature
    self._resource_missing = meta == nil and self._resource_missing or false
    self._id = self._display_name or self._path
    self._tab_label = string.format("%s##%s", self._display_name or self._id, self._resource_guid or self._path or self._id)
end

local function _touch_document(self)
    self._document_last_used_time = os.time()
end

local function _is_document_loaded(self)
    return self._document_loaded == true
end

local function _bump_document_revision(self)
    self._document_revision = (tonumber(self._document_revision) or 0) + 1
end

local function _set_document_from_snapshot(self, document_snapshot)
    self._document = Style.normalize_document(document_snapshot)
    _bump_document_revision(self)
    self._compiled_sheet = nil
    self._compiled_revision = (self._compiled_revision or 0) + 1
end

local function _commit_document_snapshot(self, next_document)
    if not _is_document_loaded(self) then
        return false
    end

    local normalized_next = Style.normalize_document(next_document)
    if _deep_equal(self._document, normalized_next) then
        return false
    end

    local old_snapshot = Style.clone(self._document)
    local new_snapshot = Style.clone(normalized_next)
    _set_document_from_snapshot(self, normalized_next)

    UndoManager.record(function(data)
            _set_document_from_snapshot(self, data.old_snapshot)
        end,
        function(data)
            _set_document_from_snapshot(self, data.new_snapshot)
        end,
        {
            old_snapshot = old_snapshot,
            new_snapshot = new_snapshot,
        })
    StyleManager.invalidate_by_guid(self._resource_guid)
    return true
end

function StyleDocument:ctor(resource_source, options)
    options = options or {}
    local path = type(resource_source) == "table" and resource_source.path or resource_source
    self._id = path and path:match("([^/\\]+)%.style$") or path
    self._path = path
    self._resource_guid = nil
    self._resource_id = nil
    self._display_name = nil
    self._tab_label = nil
    self._resource_file_signature = nil
    self._resource_missing = false
    self._external_change_pending = false
    self._document_loaded = false
    self._document_last_used_time = 0
    self._document = Style.new_document()
    self._document_revision = 0
    self._compiled_sheet = nil
    self._compiled_revision = 0
    self._last_load_error = nil
    self._ui_state_pool = {}
    self._manager = options.manager
    self._is_disposed = false
    self._is_open = imgui.Bool(options.initial_open == true)
    self._undo_context = UndoManager.create_context()
    self._modify_context = ModifyManager.create_context(not NativeIO.file_exists(path))
    _update_resource_meta(self, resource_source)

    if not options.lazy_document then
        self:ensure_document_loaded()
    end
end

function StyleDocument:ensure_document_loaded()
    if _is_document_loaded(self) then
        self._last_load_error = nil
        _touch_document(self)
        return true
    end

    if not self._path or not NativeIO.file_exists(self._path) then
        self._document = Style.new_document()
        _bump_document_revision(self)
        self._document_loaded = true
        self._resource_missing = false
        self._external_change_pending = false
        self._compiled_sheet = nil
        self._compiled_revision = (self._compiled_revision or 0) + 1
        self._last_load_error = nil
        _touch_document(self)
        return true
    end

    local document, err = Style.load(self._path)
    if not document then
        self._last_load_error = err or "无法加载样式文件"
        LogManager.log(string.format("加载样式文件失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        return false, self._last_load_error
    end

    self._document = document
    _bump_document_revision(self)
    self._document_loaded = true
    self._resource_missing = false
    self._external_change_pending = false
    self._compiled_sheet = nil
    self._compiled_revision = (self._compiled_revision or 0) + 1
    self._last_load_error = nil
    _touch_document(self)
    return true
end

function StyleDocument:is_document_loaded()
    return _is_document_loaded(self)
end

function StyleDocument:unload_document()
    if not _is_document_loaded(self) then
        return false
    end
    self._document_loaded = false
    self._document = Style.new_document()
    _bump_document_revision(self)
    self._compiled_sheet = nil
    self._last_load_error = nil
    self._ui_state_pool = {}
    return true
end

function StyleDocument:is_modified()
    if not _is_document_loaded(self) then
        return false
    end

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    local modified = ModifyManager.is_modify()
    ModifyManager.set_context(previous_context)
    return modified
end

function StyleDocument:save_document()
    local loaded_ok, load_err = self:ensure_document_loaded()
    if not loaded_ok then
        return false, load_err
    end

    _ensure_parent_directory(self._path)
    local ok, err = Style.save(self._path, self._document)
    if not ok then
        LogManager.log(string.format("样式文件保存失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        return false
    end

    self._resource_file_signature = _get_file_signature(self._path)
    self._resource_missing = false
    self._external_change_pending = false
    self._last_load_error = nil
    StyleManager.invalidate_by_guid(self._resource_guid)

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    ModifyManager.set_modify(false)
    ModifyManager.set_context(previous_context)

    LogManager.log(string.format("样式文件已保存：%s", _get_document_name(self)), "success")
    return true
end

function StyleDocument:reload_from_disk(options)
    local reload_options = type(options) == "table" and options or {}
    if not self._path or not NativeIO.file_exists(self._path) then
        return false
    end

    local document, err = Style.load(self._path)
    if not document then
        self._last_load_error = err or "无法重新加载样式文件"
        LogManager.log(string.format("重新加载样式文件失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        return false, self._last_load_error
    end

    self._document = document
    _bump_document_revision(self)
    self._document_loaded = true
    self._compiled_sheet = nil
    self._compiled_revision = (self._compiled_revision or 0) + 1
    self._resource_missing = false
    self._external_change_pending = false
    self._last_load_error = nil
    self._ui_state_pool = {}
    StyleManager.invalidate_by_guid(self._resource_guid)

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    ModifyManager.set_modify(false)
    ModifyManager.set_context(previous_context)

    if reload_options.silent ~= true then
        LogManager.log(string.format("已重新加载样式文件：%s", _get_document_name(self)), "success")
    end
    return true
end

function StyleDocument:update_resource_meta(resource_source)
    _update_resource_meta(self, resource_source)
end

function StyleDocument:mark_external_change(meta)
    if self._resource_missing then
        return
    end
    if meta and meta.file_signature then
        self._resource_file_signature = _clone_signature(meta.file_signature)
    end
    self._external_change_pending = true
    LogManager.log(string.format("检测到样式文件发生外部修改：%s", _get_document_name(self)), "warning")
end

function StyleDocument:mark_resource_missing()
    if self._resource_missing then
        return
    end
    self._resource_missing = true
    self._external_change_pending = false
    LogManager.log(string.format("样式文件已从磁盘移除：%s", _get_document_name(self)), "warning")
end

function StyleDocument:clear_resource_missing()
    self._resource_missing = false
end

function StyleDocument:get_document_snapshot()
    if not self:ensure_document_loaded() then
        return Style.new_document()
    end
    return Style.clone(self._document)
end

function StyleDocument:get_document_revision()
    return tonumber(self._document_revision) or 0
end

function StyleDocument:get_last_load_error()
    return self._last_load_error
end

function StyleDocument:get_compiled_sheet(options)
    local compile_options = type(options) == "table" and options or {}
    local allow_unsaved_snapshot = compile_options.allow_unsaved_snapshot == true
    if not self:ensure_document_loaded() then
        return nil, self:get_last_load_error() or "无法加载样式文件"
    end

    local compiled_sheet, err = Style.compile_document(self._document,
    {
        document_guid = self._resource_guid or self._path or self._id or "style_document",
        cache_key = self._resource_guid or self._path or self._id or "style_document",
        resolve_parent_document = function(reference)
            if self._manager and self._manager.resolve_parent_document then
                return self._manager.resolve_parent_document(reference, self,
                {
                    allow_unsaved_snapshot = allow_unsaved_snapshot,
                })
            end

            local parent_guid = ResourceIndex.resolve_guid("style", reference)
            if not parent_guid then
                return nil, "父样式不存在"
            end
            local meta = ResourceIndex.find_by_guid(parent_guid)
            if not meta then
                return nil, "父样式不存在"
            end
            local document, parent_err = Style.load(meta.path)
            if not document then
                return nil, parent_err or "无法加载父样式"
            end
            return
            {
                guid = parent_guid,
                path = meta.path,
                document = document,
            }
        end,
    })

    if not compiled_sheet then
        return nil, err and err.message or tostring(err)
    end

    self._compiled_sheet = compiled_sheet
    return compiled_sheet
end

function StyleDocument:get_ui_state(field_path)
    local key = _trim(field_path) or tostring(field_path)
    self._ui_state_pool[key] = self._ui_state_pool[key] or {}
    return self._ui_state_pool[key]
end

function StyleDocument:set_parent(parent_reference)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    Style.set_parent(next_document, parent_reference)
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:set_domain_display_name(domain_key, display_name)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.set_domain_display_name(next_document, domain_key, display_name) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:ensure_domain(domain_key)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.get_domain(next_document, domain_key, true) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:ensure_domain_with_default_values(domain_key)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.apply_default_domain(next_document, domain_key) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:remove_domain(domain_key)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.remove_domain(next_document, domain_key) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:set_field_entry(domain_key, field_key, entry)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.set_field_entry(next_document, domain_key, field_key, entry) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:remove_field_entry(domain_key, field_key)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.clear_field_entry(next_document, domain_key, field_key) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:set_field_value(domain_key, field_key, value, options)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.set_field_value(next_document, domain_key, field_key, value, options) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:clear_field_value(domain_key, field_key)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = Style.clone(self._document)
    if not Style.clear_field_value(next_document, domain_key, field_key) then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function StyleDocument:dispose()
    if self._is_disposed then
        return
    end
    self._is_disposed = true
    self._ui_state_pool = {}
    self._compiled_sheet = nil
    self._document = Style.new_document()
    self._document_loaded = false
    self._last_load_error = nil
end

StyleDocument.get_document_name = _get_document_name

return StyleDocument

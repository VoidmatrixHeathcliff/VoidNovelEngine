local imgui = Engine.ImGUI
local util = Engine.Util

local Class = require("application.framework.class")
local LogManager = require("application.framework.log_manager")
local ModifyManager = require("application.framework.modify_manager")
local NativeIO = require("application.framework.native_io")
local UI = require("application.framework.ui")
local UndoManager = require("application.framework.undo_manager")

local UIDocument = Class.define("UIDocument")

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

local function _find_duplicate_widget_name(document, widget_id, name)
    local normalized_name = _trim(name)
    if not document or not normalized_name then
        return nil
    end

    local duplicate_widget = nil
    UI.walk_widgets(document, function(widget)
        if widget and widget.id ~= widget_id and _trim(widget.name) == normalized_name then
            duplicate_widget = widget
            return true
        end
        return false
    end)
    return duplicate_widget
end

local function _touch_document(self)
    self._document_last_used_time = os.time()
end

local function _is_document_loaded(self)
    return self._document_loaded == true
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
    self._display_name = meta and meta.display_name or (path and path:match("([^/\\]+)%.ui$") or path)
    self._resource_file_signature = meta and _clone_signature(meta.file_signature) or self._resource_file_signature
    self._resource_missing = meta == nil and self._resource_missing or false
    self._id = self._display_name or self._path
    self._tab_label = string.format("%s##%s", self._display_name or self._id, self._resource_guid or self._path or self._id)
end

local function _set_document_from_snapshot(self, document_snapshot)
    self._document = UI.normalize_document(document_snapshot)
    self._document_revision = (tonumber(self._document_revision) or 0) + 1
end

local function _commit_document_snapshot(self, next_document)
    if not _is_document_loaded(self) then
        return false
    end

    local normalized_next = UI.normalize_document(next_document)
    if _deep_equal(self._document, normalized_next) then
        return false
    end

    local old_snapshot = UI.clone(self._document)
    local new_snapshot = UI.clone(normalized_next)
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
    return true
end

function UIDocument:ctor(resource_source, options)
    options = options or {}
    local path = type(resource_source) == "table" and resource_source.path or resource_source
    self._id = path and path:match("([^/\\]+)%.ui$") or path
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
    self._document = UI.new_document()
    self._document_revision = 0
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

function UIDocument:ensure_document_loaded()
    if _is_document_loaded(self) then
        _touch_document(self)
        return true
    end

    if not self._path or not NativeIO.file_exists(self._path) then
        self._document = UI.new_document()
        self._document_revision = (tonumber(self._document_revision) or 0) + 1
        self._document_loaded = true
        self._resource_missing = false
        self._external_change_pending = false
        self._resource_file_signature = _get_file_signature(self._path)
        self._last_load_error = nil
        _touch_document(self)
        return true
    end

    local document, err = UI.load(self._path)
    if not document then
        self._last_load_error = err or "无法加载界面文件"
        LogManager.log(string.format("加载界面文件失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        return false, self._last_load_error
    end

    self._document = document
    self._document_revision = (tonumber(self._document_revision) or 0) + 1
    self._document_loaded = true
    self._resource_missing = false
    self._external_change_pending = false
    self._resource_file_signature = _get_file_signature(self._path)
    self._last_load_error = nil
    _touch_document(self)
    return true
end

function UIDocument:is_document_loaded()
    return _is_document_loaded(self)
end

function UIDocument:unload_document()
    if not _is_document_loaded(self) then
        return false
    end
    self._document_loaded = false
    self._document = UI.new_document()
    self._document_revision = (tonumber(self._document_revision) or 0) + 1
    self._last_load_error = nil
    self._ui_state_pool = {}
    return true
end

function UIDocument:is_modified()
    if not _is_document_loaded(self) then
        return false
    end

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    local modified = ModifyManager.is_modify()
    ModifyManager.set_context(previous_context)
    return modified
end

function UIDocument:save_document()
    local loaded_ok, load_err = self:ensure_document_loaded()
    if not loaded_ok then
        return false, load_err
    end

    _ensure_parent_directory(self._path)
    local ok, err = UI.save(self._path, self._document)
    if not ok then
        LogManager.log(string.format("界面文件保存失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        return false, err or "无法保存界面文件"
    end

    self._resource_file_signature = _get_file_signature(self._path)
    self._resource_missing = false
    self._external_change_pending = false
    self._last_load_error = nil

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    ModifyManager.set_modify(false)
    ModifyManager.set_context(previous_context)

    LogManager.log(string.format("界面文件已保存：%s", _get_document_name(self)), "success")
    return true
end

function UIDocument:reload_from_disk(options)
    local reload_options = type(options) == "table" and options or {}
    if not self._path or not NativeIO.file_exists(self._path) then
        self._last_load_error = "无法重新加载界面文件"
        return false, self._last_load_error
    end

    local document, err = UI.load(self._path)
    if not document then
        self._last_load_error = err or "无法重新加载界面文件"
        LogManager.log(string.format("重新加载界面文件失败：%s\n%s", _get_document_name(self), err or "未知错误"), "error")
        return false, self._last_load_error
    end

    self._resource_file_signature = _get_file_signature(self._path)
    self._document = document
    self._document_loaded = true
    self._document_revision = (tonumber(self._document_revision) or 0) + 1
    self._resource_missing = false
    self._external_change_pending = false
    self._last_load_error = nil
    self._ui_state_pool = {}

    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    ModifyManager.set_modify(false)
    ModifyManager.set_context(previous_context)

    if reload_options.silent ~= true then
        LogManager.log(string.format("已重新加载界面文件：%s", _get_document_name(self)), "success")
    end
    return true
end

function UIDocument:update_resource_meta(resource_source)
    _update_resource_meta(self, resource_source)
end

function UIDocument:mark_external_change(meta)
    if self._resource_missing then
        return
    end
    if meta and meta.file_signature then
        self._resource_file_signature = _clone_signature(meta.file_signature)
    end
    self._external_change_pending = true
    LogManager.log(string.format("检测到界面文件发生外部修改：%s", _get_document_name(self)), "warning")
end

function UIDocument:mark_resource_missing()
    if self._resource_missing then
        return
    end
    self._resource_missing = true
    self._external_change_pending = false
    LogManager.log(string.format("界面文件已从磁盘移除：%s", _get_document_name(self)), "warning")
end

function UIDocument:clear_resource_missing()
    self._resource_missing = false
end

function UIDocument:get_document_snapshot()
    if not self:ensure_document_loaded() then
        return UI.new_document()
    end
    return UI.clone(self._document)
end

function UIDocument:get_document_revision()
    return tonumber(self._document_revision) or 0
end

function UIDocument:get_last_load_error()
    return self._last_load_error
end

function UIDocument:set_document_snapshot(document_snapshot)
    if not self:ensure_document_loaded() then
        return false
    end
    return _commit_document_snapshot(self, document_snapshot)
end

function UIDocument:get_ui_state(key)
    local state_key = _trim(key) or tostring(key)
    self._ui_state_pool[state_key] = self._ui_state_pool[state_key] or {}
    return self._ui_state_pool[state_key]
end

function UIDocument:get_widget(widget_id)
    if not self:ensure_document_loaded() then
        return nil, nil, nil
    end
    return UI.find_widget(self._document, widget_id or "root")
end

function UIDocument:create_widget(parent_id, type_id, index)
    if not self:ensure_document_loaded() then
        return nil
    end

    local next_document, widget = UI.insert_widget(self._document, parent_id or "root",
    {
        type = type_id,
    }, index)
    if not next_document then
        return nil
    end

    if _commit_document_snapshot(self, next_document) then
        return widget
    end
    return nil
end

function UIDocument:delete_widget(widget_id)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = UI.remove_widget(self._document, widget_id)
    if not next_document then
        return false
    end
    return _commit_document_snapshot(self, next_document)
end

function UIDocument:move_widget(widget_id, new_parent_id, index)
    local loaded_ok, load_err = self:ensure_document_loaded()
    if not loaded_ok then
        return false, load_err
    end

    local next_document, err = UI.move_widget(self._document, widget_id, new_parent_id, index)
    if not next_document then
        return false, err
    end
    return _commit_document_snapshot(self, next_document)
end

function UIDocument:set_widget_name(widget_id, name)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = UI.clone(self._document)
    local widget = UI.find_widget(next_document, widget_id)
    if not widget then
        return false
    end

    local next_name = _trim(name) or widget.name
    widget.name = next_name
    local duplicate_widget = _find_duplicate_widget_name(next_document, widget_id, next_name)
    local ok = _commit_document_snapshot(self, next_document)
    if ok and duplicate_widget then
        LogManager.log(string.format(
            "界面组件名称重复：%s。重复组件：%s、%s。界面逻辑按组件名称监听时可能无法区分。",
            tostring(next_name),
            tostring(widget_id),
            tostring(duplicate_widget.id or "未知组件")),
            "warning")
    end
    return ok
end

function UIDocument:set_widget_property(widget_id, key, value)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = UI.clone(self._document)
    local widget = UI.find_widget(next_document, widget_id)
    if not widget then
        return false
    end

    widget.props = widget.props or {}
    widget.props[key] = UI.clone(value)
    return _commit_document_snapshot(self, next_document)
end

function UIDocument:set_widget_event(widget_id, event_key, event_value)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = UI.clone(self._document)
    local widget = UI.find_widget(next_document, widget_id)
    if not widget then
        return false
    end

    widget.events = widget.events or {}
    widget.events[event_key] = UI.clone(event_value)
    return _commit_document_snapshot(self, next_document)
end

function UIDocument:set_canvas_size(width, height)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_document = UI.clone(self._document)
    next_document.canvas.width = math.max(1, math.floor(tonumber(width) or next_document.canvas.width or 1920))
    next_document.canvas.height = math.max(1, math.floor(tonumber(height) or next_document.canvas.height or 1080))
    return _commit_document_snapshot(self, next_document)
end

function UIDocument:set_canvas_mode(mode)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_mode = _trim(mode) or "fixed"
    if next_mode ~= "fixed" and next_mode ~= "project" and next_mode ~= "responsive" then
        next_mode = "fixed"
    end

    local next_document = UI.clone(self._document)
    next_document.canvas = next_document.canvas or {}
    next_document.canvas.mode = next_mode
    if next_mode == "project" or next_mode == "responsive" then
        next_document.canvas.design_width = next_document.canvas.design_width or next_document.canvas.width or 1920
        next_document.canvas.design_height = next_document.canvas.design_height or next_document.canvas.height or 1080
    end
    return _commit_document_snapshot(self, next_document)
end

function UIDocument:sync_canvas_to_project(width, height)
    if not self:ensure_document_loaded() then
        return false
    end

    local next_width = math.max(1, math.floor(tonumber(width) or 1920))
    local next_height = math.max(1, math.floor(tonumber(height) or 1080))
    local next_document = UI.clone(self._document)
    next_document.canvas = next_document.canvas or {}
    next_document.canvas.width = next_width
    next_document.canvas.height = next_height
    next_document.canvas.design_width = next_width
    next_document.canvas.design_height = next_height
    return _commit_document_snapshot(self, next_document)
end

function UIDocument:dispose()
    if self._is_disposed then
        return
    end
    self._is_disposed = true
    self._ui_state_pool = {}
    self._document = UI.new_document()
    self._document_loaded = false
    self._last_load_error = nil
end

UIDocument.get_document_name = _get_document_name

return UIDocument

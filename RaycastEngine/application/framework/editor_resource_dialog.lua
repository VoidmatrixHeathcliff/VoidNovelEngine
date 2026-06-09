local imgui = Engine.ImGUI
local util = Engine.Util

local EditorResourceActions = require("application.framework.editor_resource_actions")
local FlowManager = require("application.framework.flow_manager")
local LogManager = require("application.framework.log_manager")
local ResourceIndex = require("application.framework.resource_index")
local window_flow_designer = require("application.scene.window.window_flow_designer")
local window_story_designer = require("application.scene.window.window_story_designer")
local window_style_designer = require("application.scene.window.window_style_designer")
local window_ui_designer = require("application.scene.window.window_ui_designer")

local module = {}

local state =
{
    mode = nil,
    title = "",
    confirm_text = "",
    resource_kind = nil,
    relative_dir = "",
    ext = "",
    target_guid = nil,
    target_relative_dir = nil,
    name_input = util.CString(),
    error_text = nil,
    request_open_popup = false,
    request_focus_input = false,
    auto_open = false,
}

local last_result = nil
local pending_open_result = nil
local pending_open_resource_kind = nil

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

local function _reset_state()
    state.mode = nil
    state.title = ""
    state.confirm_text = ""
    state.resource_kind = nil
    state.relative_dir = ""
    state.ext = ""
    state.target_guid = nil
    state.target_relative_dir = nil
    state.name_input:set("")
    state.error_text = nil
    state.request_open_popup = false
    state.request_focus_input = false
    state.auto_open = false
end

local function _get_popup_id()
    return string.format("%s##editor_resource_dialog_modal", state.title ~= "" and state.title or "资源操作")
end

local function _close_dialog()
    imgui.CloseCurrentPopup()
    _reset_state()
end

local function _is_delete_mode()
    return state.mode == "delete_resource" or state.mode == "delete_directory"
end

local function _open_created_resource(result, resource_kind)
    if not result or result.kind ~= "resource" then
        return
    end

    if resource_kind == "flow_graph" then
        window_flow_designer.open_flow_document(result.guid, {select = true})
        return
    end

    if resource_kind == "story_text" then
        window_story_designer.open_story_document(result.guid, {select = true})
        return
    end

    if resource_kind == "ui" then
        window_ui_designer.open_ui_document(result.guid, {select = true})
        return
    end

    if resource_kind == "style" then
        window_style_designer.open_style_document(result.guid, {select = true})
        return
    end

end

local function _execute_action()
    local result = nil
    local err = nil
    local should_auto_open = state.mode == "create_resource" and state.auto_open == true
    local auto_open_resource_kind = state.resource_kind

    if state.mode == "create_resource" then
        result, err = EditorResourceActions.create_resource_file(state.resource_kind, state.relative_dir, state.name_input:get())
    elseif state.mode == "create_folder" then
        result, err = EditorResourceActions.create_folder(state.relative_dir, state.name_input:get())
    elseif state.mode == "rename_resource" then
        result, err = EditorResourceActions.rename_resource_file(state.target_guid, state.name_input:get())
    elseif state.mode == "rename_directory" then
        result, err = EditorResourceActions.rename_directory(state.target_relative_dir, state.name_input:get())
    elseif state.mode == "delete_resource" then
        result, err = EditorResourceActions.delete_resource_file(state.target_guid)
    elseif state.mode == "delete_directory" then
        result, err = EditorResourceActions.delete_directory(state.target_relative_dir)
    else
        err = "未知的资源操作"
    end

    if not result then
        state.error_text = err or "资源操作失败"
        return false
    end

    last_result = result
    _close_dialog()
    if should_auto_open then
        pending_open_result = result
        pending_open_resource_kind = auto_open_resource_kind
    end
    return true
end

local function _get_validation_error()
    if state.mode == "create_resource" then
        local _, err = EditorResourceActions.validate_create_resource(state.resource_kind, state.relative_dir, state.name_input:get())
        return err
    end
    if state.mode == "create_folder" then
        local _, err = EditorResourceActions.validate_create_folder(state.relative_dir, state.name_input:get())
        return err
    end
    if state.mode == "rename_resource" then
        local _, err = EditorResourceActions.validate_rename_resource(state.target_guid, state.name_input:get())
        return err
    end
    if state.mode == "rename_directory" then
        local _, err = EditorResourceActions.validate_rename_directory(state.target_relative_dir, state.name_input:get())
        return err
    end
    if state.mode == "delete_resource" then
        local _, err = EditorResourceActions.validate_delete_resource(state.target_guid)
        return err
    end
    if state.mode == "delete_directory" then
        local _, err = EditorResourceActions.validate_delete_directory(state.target_relative_dir)
        return err
    end
    return "未知的资源操作"
end

function module.open_create_resource(resource_kind, relative_dir, options)
    local definition = EditorResourceActions.get_resource_kind_definition(resource_kind)
    if not definition then
        LogManager.log(string.format("无法打开资源创建弹窗，未知资源类型：%s", tostring(resource_kind)), "warning")
        return false
    end

    local open_options = options or {}
    state.mode = "create_resource"
    state.title = string.format("新建%s", definition.display_name)
    state.confirm_text = "创建"
    state.resource_kind = resource_kind
    state.relative_dir = EditorResourceActions.normalize_relative_dir(relative_dir ~= nil and relative_dir or definition.default_relative_dir)
    state.ext = definition.ext
    state.target_guid = nil
    state.target_relative_dir = nil
    state.name_input:set("")
    state.error_text = nil
    state.request_open_popup = true
    state.request_focus_input = true
    state.auto_open = open_options.auto_open == true
    return true
end

function module.open_create_folder(relative_dir, options)
    local open_options = options or {}
    state.mode = "create_folder"
    state.title = "新建文件夹"
    state.confirm_text = "创建"
    state.resource_kind = nil
    state.relative_dir = EditorResourceActions.normalize_relative_dir(relative_dir)
    state.ext = ""
    state.target_guid = nil
    state.target_relative_dir = nil
    state.name_input:set("")
    state.error_text = nil
    state.request_open_popup = true
    state.request_focus_input = true
    state.auto_open = open_options.auto_open == true
    return true
end

function module.open_rename_resource(guid, options)
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        LogManager.log(string.format("无法打开资源重命名弹窗，未找到资源：%s", tostring(guid)), "warning")
        return false
    end

    local open_options = options or {}
    state.mode = "rename_resource"
    state.title = "重命名资源"
    state.confirm_text = "重命名"
    state.resource_kind = nil
    state.relative_dir = meta.relative_dir or ""
    state.ext = meta.ext or ""
    state.target_guid = meta.guid
    state.target_relative_dir = nil
    state.name_input:set(meta.file_stem or meta.display_name or "")
    state.error_text = nil
    state.request_open_popup = true
    state.request_focus_input = true
    state.auto_open = open_options.auto_open == true
    return true
end

function module.open_rename_directory(relative_dir, options)
    local normalized_relative_dir = EditorResourceActions.normalize_relative_dir(relative_dir)
    if normalized_relative_dir == "" then
        LogManager.log("根目录不允许重命名", "warning")
        return false
    end

    local open_options = options or {}
    state.mode = "rename_directory"
    state.title = "重命名文件夹"
    state.confirm_text = "重命名"
    state.resource_kind = nil
    state.relative_dir = EditorResourceActions.normalize_relative_dir(_trim(normalized_relative_dir:match("^(.*)/[^/]+$") or ""))
    state.ext = ""
    state.target_guid = nil
    state.target_relative_dir = normalized_relative_dir
    state.name_input:set(normalized_relative_dir:match("([^/]+)$") or normalized_relative_dir)
    state.error_text = nil
    state.request_open_popup = true
    state.request_focus_input = true
    state.auto_open = open_options.auto_open == true
    return true
end

function module.open_delete_resource(guid, options)
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        LogManager.log(string.format("无法打开资源删除弹窗，未找到资源：%s", tostring(guid)), "warning")
        return false
    end

    local open_options = options or {}
    state.mode = "delete_resource"
    state.title = "删除资源"
    state.confirm_text = "删除"
    state.resource_kind = nil
    state.relative_dir = meta.relative_dir or ""
    state.ext = ""
    state.target_guid = meta.guid
    state.target_relative_dir = nil
    state.name_input:set("")
    state.error_text = nil
    state.request_open_popup = true
    state.request_focus_input = false
    state.auto_open = open_options.auto_open == true
    return true
end

function module.open_delete_directory(relative_dir, options)
    local normalized_relative_dir = EditorResourceActions.normalize_relative_dir(relative_dir)
    if normalized_relative_dir == "" then
        LogManager.log("根目录不允许删除", "warning")
        return false
    end

    local open_options = options or {}
    state.mode = "delete_directory"
    state.title = "删除文件夹"
    state.confirm_text = "删除"
    state.resource_kind = nil
    state.relative_dir = EditorResourceActions.normalize_relative_dir(_trim(normalized_relative_dir:match("^(.*)/[^/]+$") or ""))
    state.ext = ""
    state.target_guid = nil
    state.target_relative_dir = normalized_relative_dir
    state.name_input:set("")
    state.error_text = nil
    state.request_open_popup = true
    state.request_focus_input = false
    state.auto_open = open_options.auto_open == true
    return true
end

function module.is_modal_active()
    return state.mode ~= nil
end

function module.consume_last_result()
    local result = last_result
    last_result = nil
    return result
end

function module.draw_modal()
    if state.mode == nil and pending_open_result ~= nil then
        local result = pending_open_result
        local resource_kind = pending_open_resource_kind
        pending_open_result = nil
        pending_open_resource_kind = nil
        local ok, err = pcall(_open_created_resource, result, resource_kind)
        if not ok then
            LogManager.log(string.format("打开新建资源失败：%s", tostring(err)), "warning")
        end
        return
    end

    if state.mode == nil then
        return
    end

    local popup_id = _get_popup_id()
    if state.request_open_popup then
        imgui.OpenPopup(popup_id)
        state.request_open_popup = false
    end

    if not imgui.BeginPopupModal(popup_id, nil, imgui.WindowFlags.AlwaysAutoResize | imgui.WindowFlags.NoSavedSettings) then
        return
    end

    local is_delete_mode = _is_delete_mode()
    local display_relative_dir = state.mode == "rename_directory" and state.target_relative_dir or state.relative_dir

    imgui.SeparatorText(state.title)
    imgui.TextDisabled(string.format("所在目录：%s", EditorResourceActions.get_directory_display_path(display_relative_dir)))

    if state.mode == "rename_resource" and state.target_guid then
        local meta = ResourceIndex.find_by_guid(state.target_guid)
        if meta then
            imgui.TextDisabled(string.format("当前文件：%s", meta.file_name or meta.relative_path or meta.display_name or meta.guid))
        end
    end

    if state.mode == "rename_directory" and state.target_relative_dir then
        imgui.TextDisabled(string.format("当前文件夹：%s", EditorResourceActions.get_directory_display_path(state.target_relative_dir)))
    end

    if state.mode == "delete_resource" and state.target_guid then
        local meta = ResourceIndex.find_by_guid(state.target_guid)
        if meta then
            imgui.TextDisabled(string.format("目标资源：%s", meta.file_name or meta.relative_path or meta.display_name or meta.guid))
        end
    end

    if state.mode == "delete_directory" and state.target_relative_dir then
        imgui.TextDisabled(string.format("目标文件夹：%s", EditorResourceActions.get_directory_display_path(state.target_relative_dir)))
    end

    imgui.Dummy(imgui.ImVec2(0, 4))
    if not is_delete_mode then
        imgui.Text("名称")
        imgui.SameLine()
        imgui.SetNextItemWidth(260)
        if state.request_focus_input then
            imgui.SetKeyboardFocusHere()
            state.request_focus_input = false
        end
        imgui.InputText("##editor_resource_dialog_name", state.name_input)
        if state.ext ~= "" then
            imgui.SameLine()
            imgui.TextDisabled(state.ext)
        end
    else
        local warning_text = state.mode == "delete_directory"
            and "删除文件夹会递归删除其中全部资源，删除后不可恢复"
            or "删除后不可恢复，请确认后继续"
        imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, warning_text)
    end

    local validation_error = _get_validation_error()
    if state.error_text and state.error_text ~= validation_error then
        state.error_text = nil
    end

    local display_error = state.error_text or validation_error
    if display_error then
        imgui.TextColored(imgui.ImColor(183, 40, 46, 255).value, display_error)
    elseif not is_delete_mode then
        imgui.TextColored(imgui.ImColor(62, 179, 112, 255).value, "名称可用")
    end

    imgui.Dummy(imgui.ImVec2(0, 6))
    local can_confirm = display_error == nil
    imgui.BeginDisabled(not can_confirm)
        if imgui.Button(state.confirm_text, imgui.ImVec2(120, 0)) then
            _execute_action()
        end
    imgui.EndDisabled()
    imgui.SameLine()
    if imgui.Button("取消", imgui.ImVec2(120, 0)) then
        _close_dialog()
    end

    imgui.EndPopup()
end

return module

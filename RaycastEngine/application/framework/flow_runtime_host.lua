local GlobalContext = require("application.framework.global_context")

local module = {}
local log_manager_module = false
local runtime_flow_control_module = false

local function _get_runtime_flow_control()
    if runtime_flow_control_module == false then
        runtime_flow_control_module = require("application.framework.runtime_flow_control")
    end
    return runtime_flow_control_module
end

local function _log_runtime_error(message)
    if log_manager_module == false then
        local ok, module_ref = pcall(require, "application.framework.log_manager")
        log_manager_module = ok and module_ref or nil
    end
    if log_manager_module and log_manager_module.log then
        pcall(log_manager_module.log, message, "error")
    end
end

module.get_runtime_document = function()
    return GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil
end

module.execute = function(document)
    if not document then
        return false
    end

    _get_runtime_flow_control().reset_runtime_state()
    local previous_document = module.get_runtime_document()
    if previous_document and previous_document ~= document then
        GlobalContext.reset_flow_runtime_state(previous_document)
    end

    GlobalContext.set_runtime_flow_document(document)
    if document.execute then
        local ok, err = pcall(function()
            document:execute()
        end)
        if not ok then
            _log_runtime_error(string.format("Flow startup failed: %s", tostring(err)))
            GlobalContext.reset_flow_runtime_state(document)
            GlobalContext.set_runtime_flow_document(nil)
            if GlobalContext.stop_debug then
                GlobalContext.stop_debug()
            end
            return false, err
        end
    end
    return true
end

module.restore = function(document, runtime_state)
    if not document or not runtime_state then
        return false, "无效的流程恢复请求"
    end

    _get_runtime_flow_control().reset_runtime_state()
    local previous_document = module.get_runtime_document()
    if previous_document and previous_document ~= document then
        GlobalContext.reset_flow_runtime_state(previous_document)
    end

    GlobalContext.set_runtime_flow_document(document)
    if document.restore_runtime_save_state then
        local ok, err = document:restore_runtime_save_state(runtime_state)
        if ok ~= true then
            GlobalContext.reset_flow_runtime_state(document)
            GlobalContext.set_runtime_flow_document(nil)
            return false, err
        end
        return true
    end
    GlobalContext.set_runtime_flow_document(nil)
    return false, "当前流程文档不支持读档恢复"
end

module.update = function(delta)
    local document = module.get_runtime_document()
    if not document or not document.runtime_update then
        return
    end

    local runtime_flow_control = _get_runtime_flow_control()
    if runtime_flow_control.has_pending_rollback and runtime_flow_control.has_pending_rollback() then
        runtime_flow_control.consume_rollback_request(document)
        return
    end

    local scene_context = document.get_runtime_scene_context and document:get_runtime_scene_context() or nil
    runtime_flow_control.update(document, scene_context, delta)

    local ok, err = pcall(function()
        document:runtime_update(delta)
    end)
    if not ok then
        _log_runtime_error(string.format("Flow runtime update failed: %s", tostring(err)))
        module.stop()
        return
    end

    if runtime_flow_control.has_pending_rollback and runtime_flow_control.has_pending_rollback() then
        runtime_flow_control.consume_rollback_request(document)
    end
end

module.render = function()
    local document = module.get_runtime_document()
    if not document or not document.runtime_render then
        return
    end
    local ok, err = pcall(function()
        document:runtime_render()
    end)
    if not ok then
        _log_runtime_error(string.format("Flow runtime render failed: %s", tostring(err)))
        module.stop()
    end
end

module.stop = function()
    local document = module.get_runtime_document()
    if not document then
        return
    end

    _get_runtime_flow_control().reset_runtime_state()
    GlobalContext.reset_flow_runtime_state(document)
    if GlobalContext.is_debug_game then
        GlobalContext.stop_debug()
        return
    end

    GlobalContext.set_runtime_flow_document(nil)
    if document._is_temporary_runtime_document == true and document.dispose then
        document:dispose()
    end
end

return module

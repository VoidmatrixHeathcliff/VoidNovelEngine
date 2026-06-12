local Class = require("application.framework.class")
local Scene = require("application.framework.scene")
local FlowManager = require("application.framework.flow_manager")
local FlowRuntimeHost = require("application.framework.flow_runtime_host")
local GlobalContext = require("application.framework.global_context")
local ResourceIndex = require("application.framework.resource_index")
local SettingsManager = require("application.framework.settings_manager")

local SceneReleased = Class.define("SceneReleased", Scene)
local save_manager_module = false

local function _get_save_manager()
    if save_manager_module == false then
        save_manager_module = require("application.framework.save_manager")
    end
    return save_manager_module
end

local function on_enter(self)
    local entry_flow_guid = ResourceIndex.resolve_guid("flow", SettingsManager.get_entry_flow_guid())
        or ResourceIndex.resolve_guid("flow", SettingsManager.get_current_flow_guid())
        or ""
    local document = FlowManager.get_document(entry_flow_guid, "flow_runtime")
    if not document then
        error("入口流程脚本缺失，请检查文件完整性或重新发布。")
    end

    GlobalContext.current_flow_document = document
    GlobalContext.current_blueprint = document.kind == "graph" and document or nil
    _get_save_manager().begin_new_session()
    FlowRuntimeHost.execute(document)
end

local function on_exit(self)
end

local function on_update(self, delta)
    FlowRuntimeHost.update(delta)
end

local function on_render(self)
    FlowRuntimeHost.render()
end

SceneReleased.on_enter = on_enter
SceneReleased.on_exit = on_exit
SceneReleased.on_update = on_update
SceneReleased.on_render = on_render

return SceneReleased

local module = {}

local Scene = require("application.framework.scene")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")

local function on_enter(self)
    local entry_flow_path = SettingsManager.get("entry_flow")
    for _, blueprint in ipairs(GlobalContext.blueprint_list) do
        if blueprint._path == entry_flow_path then
            GlobalContext.current_blueprint = blueprint
            break
        end
    end
    if not GlobalContext.current_blueprint then
        error("入口流程脚本缺失，请检查文件完整性或重新发布！")
    end
    GlobalContext.current_blueprint:execute()
end

local function on_exit(self)

end

local function on_update(self, delta)
    local blueprint = GlobalContext.current_blueprint
    while rawget(blueprint, "_next_node") do
        blueprint._current_node = blueprint._next_node
        blueprint._next_node = nil
        blueprint._current_node:on_exetute(blueprint._scene_context, rawget(blueprint, "_next_node_entry_pin"))
    end
    blueprint._scene_context:on_update(delta)
    blueprint._current_node:on_exetute_update(blueprint._scene_context, delta)
end

local function on_render(self)
    GlobalContext.current_blueprint._scene_context:on_render()
end

module.new = function()
    local o = 
    {
        on_enter = on_enter,
        on_exit = on_exit,
        on_update = on_update,
        on_render = on_render,
    }
    setmetatable(o, Scene.new())
    o.__index = o
    return o
end

return module
local Class = require("application.framework.class")
local Scene = require("application.framework.scene")
local SceneManager = require("application.framework.scene_manager")
local SettingsManager = require("application.framework.settings_manager")
local StartupLoader = require("application.framework.startup_loader")
local ResourceHotReload = require("application.framework.resource_hot_reload")

local SceneBootstrapLoading = Class.define("SceneBootstrapLoading", Scene)

function SceneBootstrapLoading:ctor(target_scene_id)
    Class.call_super(SceneBootstrapLoading, self, "ctor")
    self._target_scene_id = target_scene_id
    self._loader = nil
    self._has_switched = false
end

function SceneBootstrapLoading:on_enter()
    self._loader = StartupLoader.create({target_scene_id = self._target_scene_id})
    self._has_switched = false
end

function SceneBootstrapLoading:_destroy_loader()
    if self._loader and self._loader.destroy then
        self._loader:destroy()
    end
    self._loader = nil
end

function SceneBootstrapLoading:on_exit()
    self:_destroy_loader()
end

function SceneBootstrapLoading:on_destroy()
    self:_destroy_loader()
    Class.call_super(SceneBootstrapLoading, self, "on_destroy")
end

function SceneBootstrapLoading:on_update(delta)
    if not self._loader then
        return
    end

    self._loader:update(delta)
    self._loader:draw_loading_screen()

    if self._has_switched then
        return
    end

    if self._loader:is_finished() then
        local error_message = self._loader:get_error_message()
        if error_message then
            error(error_message)
        end

        if not SettingsManager.get("release_mode") then
            ResourceHotReload.start()
        end
        self._has_switched = true
        SceneManager.switch_to(self._target_scene_id)
    end
end

function SceneBootstrapLoading:on_render()
    Class.call_super(SceneBootstrapLoading, self, "on_render")
    if self._loader and self._loader.render_loading_screen then
        self._loader:render_loading_screen()
    end
end

return SceneBootstrapLoading

local module = {}

module.sdl = Engine.SDL
module.util = Engine.Util
module.imgui = Engine.ImGUI

module.BlueprintPin = require("application.framework.blueprint_pin")
module.LogManager = require("application.framework.log_manager")
module.ColorHelper = require("application.framework.color_helper")
module.EditorThemeManager = require("application.framework.editor_theme_manager")
module.UndoManager = require("application.framework.undo_manager")
module.GlobalContext = require("application.framework.global_context")
module.ResourcesManager = require("application.framework.resources_manager")
module.StyleAdapterFactory = require("application.framework.style_adapter_factory")

module.type_color_pool =
{
    ["flow"] = module.EditorThemeManager.get_flow_pin_color(),
    ["object"] = module.imgui.ImVec4(module.imgui.ImColor(255, 255, 255, 255).value),
    ["vector2"] = module.ColorHelper.ValueTypeColorPool.vector2,
    ["color"] = module.ColorHelper.ValueTypeColorPool.color,
    ["string"] = module.ColorHelper.ValueTypeColorPool.string,
    ["int"] = module.ColorHelper.ValueTypeColorPool.int,
    ["float"] = module.ColorHelper.ValueTypeColorPool.float,
    ["bool"] = module.ColorHelper.ValueTypeColorPool.bool,
    ["font"] = module.ColorHelper.AssetTypeColorPool.font,
    ["audio"] = module.ColorHelper.AssetTypeColorPool.audio,
    ["video"] = module.ColorHelper.AssetTypeColorPool.video,
    ["shader"] = module.ColorHelper.AssetTypeColorPool.shader,
    ["texture"] = module.ColorHelper.AssetTypeColorPool.texture,
    ["style"] = module.ColorHelper.AssetTypeColorPool.style,
    ["ui"] = module.ColorHelper.AssetTypeColorPool.ui,
}

module.make_definition = function(definition, setup_func)
    local def = {}
    for key, value in pairs(definition or {}) do
        def[key] = value
    end
    def.api_version = def.api_version or 1
    def.kind = "pin"
    def.display_name = def.display_name or def.name or def.type_id
    def.name = def.display_name
    def.color = def.color or module.type_color_pool[def.type_id]
    if rawget(def, "default_name") == nil then
        if def.type_id == "flow" then
            def.default_name = nil
        else
            def.default_name = def.display_name
        end
    end
    def.setup = setup_func or def.setup or function() end
    def.runtime = def.runtime or {}
    def.runtime.display_name = def.runtime.display_name or def.display_name
    return def
end

return module

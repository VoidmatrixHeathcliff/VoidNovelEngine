local module = {}

module.sdl = Engine.SDL
module.rl = Engine.Raylib
module.util = Engine.Util
module.imgui = Engine.ImGUI

module.Class = require("application.framework.class")
module.Timer = require("application.framework.timer")
module.Tween = require("application.framework.tween")
module.Billboard = require("application.framework.billboard")
module.BlueprintNode = require("application.framework.blueprint_node")
module.LogManager = require("application.framework.log_manager")
module.TextWrapper = require("application.framework.text_wrapper")
module.ColorHelper = require("application.framework.color_helper")
module.UndoManager = require("application.framework.undo_manager")
module.VideoDecoder = require("application.framework.video_decoder")
module.GlobalContext = require("application.framework.global_context")
module.ModifyManager = require("application.framework.modify_manager")
module.BranchSelector = require("application.framework.branch_selector")
module.ResourcesManager = require("application.framework.resources_manager")
module.BackgroundObject = require("application.framework.runtime_objects.background_object")
module.ForegroundObject = require("application.framework.runtime_objects.foreground_object")
module.LetterboxingObject = require("application.framework.runtime_objects.letterboxing_object")
module.SubtitleObject = require("application.framework.runtime_objects.subtitle_object")
module.TransitionFadeObject = require("application.framework.runtime_objects.transition_fade_object")
module.VideoRendererObject = require("application.framework.runtime_objects.video_renderer_object")
module.NodeRuntimeHelper = require("application.framework.node_runtime_helper")

module.default_font_reference = function()
    return
    {
        guid = "d4298d94-ccd9-4bd9-b4ba-b03f304852e4",
        path_hint = "font/font.otf",
    }
end

module.make_definition = function(definition, build_func)
    local def = {}
    for key, value in pairs(definition or {}) do
        def[key] = value
    end
    def.api_version = def.api_version or 1
    def.kind = "node"
    def.pin_schema_version = tonumber(def.pin_schema_version) or 1
    def.title = def.title or def.name or def.type_id
    def.name = def.title
    def.build = build_func or def.build
    return def
end

module.base_constructor = function(ctx, type_id, _, icon, header_color, title, comment)
    return ctx:create_base_node(
    {
        type_id = type_id,
        icon = icon,
        header_color = header_color,
        title = title,
        comment = comment,
        use_definition_style = false,
    })
end

module.attach_pin = function(ctx, _, pin_data, pin_type_id, is_output, name, extra_args)
    assert(ctx.builder, "node builder has not been initialized")
    return ctx.builder:attach_legacy(pin_data, pin_type_id, is_output, name, extra_args)
end

return module

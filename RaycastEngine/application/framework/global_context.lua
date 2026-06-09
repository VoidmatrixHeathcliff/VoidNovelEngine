local module = {}

local sdl = Engine.SDL
local rl = Engine.Raylib
local imgui = Engine.ImGUI

module.debug = true

module.shader_postprocess = nil

module.width_game_window, module.height_game_window = 1920, 1080

module.window, module.renderer = nil, nil

module.font_imgui = nil
module.font_imgui_code = nil
module.font_imgui_story_editor = nil
module.font_wrapper_sdl = nil

module.version = "0.1.0-dev.3"

module.is_debug_game = false
module.current_flow_document = nil
module.debug_flow_document = nil
module.current_blueprint = nil
module.debug_blueprint = nil
module.flow_document_list = {}
module.runtime_global_context = {}
module.runtime_save_target_stack = {}
module.runtime_save_anchor_document = nil
module.active_plugin_id = nil
module.plugin_registry = {}
module.plugin_registry_revision = 0
module.runtime_style_context =
{
    active_style_guid = "",
    active_style_reference = nil,
    active_style_document = nil,
    compiled_sheet = nil,
    compiled_revision = 0,
    source_revision = 0,
    warning_pool = {},
}

module.is_simulated_interaction = false

module.editor_zoom_ratio = 1.0

module.is_show_flow = imgui.Bool(false)
module.is_show_all_node_id = imgui.Bool(false)
module.is_flow_designer_window_focused = false
module.is_resource_modal_active = false

module.bp_id_selected_next_frame = nil

module.is_preview_in_editor = true
module.resource_index_revision = 0
module.render_target_reset_revision = 0
module.refresh_window_icon = nil

module.is_plugin_running = function()
    return module.active_plugin_id ~= nil
end

module.get_pref_path = function()
    return sdl.GetPrefPath("", "VoidNovelEngine")
end

module.toggle_preview_mode = function()
    module.is_preview_in_editor = not module.is_preview_in_editor
    if module.is_preview_in_editor then
        rl.ClearWindowState(rl.ConfigFlags.WINDOW_HIDDEN)
        rl.SetWindowState(rl.ConfigFlags.WINDOW_HIDDEN)
    else
        rl.RestoreWindow()
    end
end

module.get_runtime_flow_document = function()
    if module.is_debug_game and module.debug_flow_document then
        return module.debug_flow_document
    end
    return module.current_flow_document
end

module.set_runtime_flow_document = function(document, options)
    local set_options = type(options) == "table" and options or {}
    local transient = set_options.transient == true
    if module.is_debug_game then
        module.debug_flow_document = document
        module.debug_blueprint = document and document.kind == "graph" and document or nil
    else
        module.current_flow_document = document
        module.current_blueprint = document and document.kind == "graph" and document or nil
    end
    if not transient then
        module.runtime_save_anchor_document = document
    end
end

module.push_runtime_save_target = function(document)
    local stack = module.runtime_save_target_stack
    if type(stack) ~= "table" then
        stack = {}
        module.runtime_save_target_stack = stack
    end

    local token =
    {
        document = document,
    }
    table.insert(stack, token)
    return token
end

module.pop_runtime_save_target = function(token)
    local stack = module.runtime_save_target_stack
    if type(stack) ~= "table" or #stack == 0 then
        return
    end

    if token == nil or stack[#stack] == token then
        table.remove(stack)
        return
    end

    for index = #stack, 1, -1 do
        if stack[index] == token then
            table.remove(stack, index)
            return
        end
    end
end

module.get_runtime_save_target_document = function()
    local stack = module.runtime_save_target_stack
    if type(stack) ~= "table" then
        return nil
    end

    for index = #stack, 1, -1 do
        local entry = stack[index]
        local document = entry and entry.document or nil
        if document ~= nil then
            return document
        end
    end
    return nil
end

module.get_runtime_save_anchor_document = function()
    local stacked_target = module.get_runtime_save_target_document()
    if stacked_target ~= nil then
        return stacked_target
    end

    local anchor = module.runtime_save_anchor_document
    if anchor ~= nil then
        return anchor
    end

    local runtime_document = module.get_runtime_flow_document()
    if type(runtime_document) == "table" and runtime_document._runtime_owner ~= nil then
        return nil
    end
    return runtime_document
end

module.reset_flow_runtime_state = function(document)
    if not document then
        return
    end

    if document.reset_runtime_state then
        document:reset_runtime_state()
        return
    end

    if document._scene_context and document._scene_context.destroy then
        document._scene_context:destroy()
    end
    document._scene_context = nil
    document._next_node = nil
    document._next_node_entry_pin = nil
    document._current_node = nil
    document._current_node_entry_pin = nil
    document._pending_resume_action = nil
    document._runtime = nil
end

module.get_runtime_blueprint = function()
    local document = module.get_runtime_flow_document()
    if document and document.kind == "graph" then
        return document
    end
    if module.is_debug_game and module.debug_blueprint then
        return module.debug_blueprint
    end
    return module.current_blueprint
end

module.set_runtime_blueprint = function(blueprint)
    module.set_runtime_flow_document(blueprint)
end

module.reset_blueprint_runtime_state = function(blueprint)
    module.reset_flow_runtime_state(blueprint)
end

module.runtime_find_node = function(id)
    local document = module.get_runtime_flow_document()
    if document and document.runtime_find_node then
        return document:runtime_find_node(id)
    end

    local blueprint = module.get_runtime_blueprint()
    return blueprint and blueprint._node_pool[id] or nil
end

module.runtime_find_pin = function(id)
    local document = module.get_runtime_flow_document()
    if document and document.runtime_find_pin then
        return document:runtime_find_pin(id)
    end

    local blueprint = module.get_runtime_blueprint()
    return blueprint and blueprint._pin_pool[id] or nil
end

module.stop_debug = function()
    local ok_snapshot, SnapshotCoordinator = pcall(require, "application.framework.snapshot_coordinator")
    if ok_snapshot and SnapshotCoordinator and SnapshotCoordinator.reset_runtime_slices then
        pcall(SnapshotCoordinator.reset_runtime_slices, "停止运行")
    end
    local ok_flow_control, RuntimeFlowControl = pcall(require, "application.framework.runtime_flow_control")
    if ok_flow_control and RuntimeFlowControl and RuntimeFlowControl.reset_runtime_state then
        pcall(RuntimeFlowControl.reset_runtime_state)
    end
    local document = module.get_runtime_flow_document()
    module.reset_flow_runtime_state(document)
    module.runtime_global_context = {}
    module.runtime_save_target_stack = {}
    module.runtime_save_anchor_document = nil
    module.runtime_style_context =
    {
        active_style_guid = "",
        active_style_reference = nil,
        active_style_document = nil,
        compiled_sheet = nil,
        compiled_revision = 0,
        source_revision = 0,
        warning_pool = {},
    }
    module.is_debug_game = false
    module.debug_flow_document = nil
    module.debug_blueprint = nil
    module.is_simulated_interaction = false
    local AudioPlaybackManager = require("application.framework.audio_playback_manager")
    AudioPlaybackManager.stop_all(0)
    sdl.HaltChannel(-1)
    if document and document._is_temporary_runtime_document == true and document.dispose then
        document:dispose()
    end
end

module.blueprint_list = {}
module.flow_document_list = module.flow_document_list or {}

return module

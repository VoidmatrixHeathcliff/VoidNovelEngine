local GlobalContext = require("application.framework.global_context")

local module = {}

local state =
{
    fast_forward_enabled = false,
    fast_forward_phase = false,
    auto_advance_enabled = false,
    auto_advance_interval = 1.0,
    auto_advance_timer = 0,
    auto_advance_binding_key = nil,
    rollback_requested = false,
    history_stack = {},
    history_limit = 64,
    restoring = false,
}

local style_manager_module = false
local audio_playback_manager_module = false

local function _get_style_manager()
    if style_manager_module == false then
        style_manager_module = require("application.framework.style_manager")
    end
    return style_manager_module
end

local function _get_audio_playback_manager()
    if audio_playback_manager_module == false then
        audio_playback_manager_module = require("application.framework.audio_playback_manager")
    end
    return audio_playback_manager_module
end

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

local function _clone_value(value, seen)
    if type(value) ~= "table" then
        return value
    end

    seen = seen or {}
    if seen[value] then
        return seen[value]
    end

    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[_clone_value(key, seen)] = _clone_value(item, seen)
    end
    return copy
end

local function _make_id_set(value_list)
    local result = {}
    if type(value_list) ~= "table" then
        return result
    end

    for key, value in pairs(value_list) do
        if type(key) == "string" and value == true then
            result[key] = true
        end

        if type(value) == "string" or type(value) == "number" then
            local id = tostring(value)
            if id ~= "" then
                result[id] = true
            end
        end
    end

    return result
end

local function _append_signature_value(result, value, depth, seen)
    depth = tonumber(depth) or 0
    local value_type = type(value)
    if depth > 32 then
        result[#result + 1] = "<max-depth>"
        return
    end

    if value_type ~= "table" then
        result[#result + 1] = value_type
        result[#result + 1] = ":"
        result[#result + 1] = tostring(value)
        result[#result + 1] = ";"
        return
    end

    seen = seen or {}
    if seen[value] then
        result[#result + 1] = "<cycle>"
        return
    end
    seen[value] = true

    local key_list = {}
    for key in pairs(value) do
        key_list[#key_list + 1] = key
    end
    table.sort(key_list, function(left, right)
        return string.format("%s:%s", type(left), tostring(left)) < string.format("%s:%s", type(right), tostring(right))
    end)

    result[#result + 1] = "{"
    for _, key in ipairs(key_list) do
        _append_signature_value(result, key, depth + 1, seen)
        result[#result + 1] = "="
        _append_signature_value(result, value[key], depth + 1, seen)
    end
    result[#result + 1] = "}"
    seen[value] = nil
end

local function _make_audio_signature_state(audio_state)
    if type(audio_state) ~= "table" then
        return audio_state
    end

    local signature =
    {
        schema_version = audio_state.schema_version,
        playback_list = {},
    }
    for _, entry in ipairs(audio_state.playback_list or {}) do
        signature.playback_list[#signature.playback_list + 1] =
        {
            token = entry.token,
            audio_guid = entry.audio_guid,
            kind = entry.kind,
            config = _clone_value(entry.config),
            target_volume = entry.target_volume,
        }
    end
    return signature
end

local function _make_snapshot_signature(snapshot)
    if type(snapshot) ~= "table" then
        return nil
    end

    local signature_source =
    {
        runtime = snapshot.runtime,
        scene = snapshot.scene,
        ui = snapshot.ui,
        globals = snapshot.globals,
        style = snapshot.style,
        audio = _make_audio_signature_state(snapshot.audio),
    }
    local result = {}
    _append_signature_value(result, signature_source, 0, {})
    return table.concat(result)
end

local function _is_same_runtime_document(left, right)
    if left == nil or right == nil then
        return left == right
    end
    if left == right then
        return true
    end

    local left_guid = _trim(left._resource_guid)
    local right_guid = _trim(right._resource_guid)
    if left_guid and right_guid then
        return left_guid == right_guid
    end

    local left_path = _trim(left._path)
    local right_path = _trim(right._path)
    return left_path ~= nil and right_path ~= nil and left_path == right_path
end

local function _normalize_interval(value)
    local interval = tonumber(value) or 1.0
    if interval < 0.1 then
        interval = 0.1
    end
    if interval > 60 then
        interval = 60
    end
    return interval
end

local function _prime_runtime_wait_state(document)
    if type(document) ~= "table" then
        return false
    end

    local primed = false
    local current_node = document._current_node
    if type(current_node) == "table" and type(current_node._runtime_wait_interaction_state) == "table" then
        current_node._runtime_wait_interaction_state.armed = true
        primed = true
    end

    local runtime = document._runtime
    local bridge = runtime and runtime._active_bridge or nil
    local bridge_node = bridge and bridge._node or nil
    if type(bridge_node) == "table" and type(bridge_node._runtime_wait_interaction_state) == "table" then
        bridge_node._runtime_wait_interaction_state.armed = true
        primed = true
    end

    return primed
end

local function _get_scene_context(document)
    if not document or not document.get_runtime_scene_context then
        return nil
    end
    return document:get_runtime_scene_context()
end

local function _is_choice_wait_active(document, scene_context)
    local scene = scene_context or _get_scene_context(document)
    if scene then
        local ui_instance = scene.find_ui_instance and scene:find_ui_instance("bp-choice-button") or nil
        if ui_instance then
            return true
        end
        local runtime_object = scene.find_object and scene:find_object("bp-choice-button") or nil
        if runtime_object and runtime_object._is_visible == true then
            return true
        end
    end

    local snapshot_coordinator = nil
    local ok, module_ref = pcall(require, "application.framework.snapshot_coordinator")
    if ok then
        snapshot_coordinator = module_ref
    end
    local slice = snapshot_coordinator and snapshot_coordinator.get_latest_slice and snapshot_coordinator.get_latest_slice() or nil
    local boundary = type(slice) == "table" and type(slice.boundary) == "table" and slice.boundary or nil
    return boundary ~= nil and boundary.kind == "choice_wait"
end

local function _capture_runtime_snapshot(document)
    if not document or not document.collect_runtime_save_state then
        return nil, "当前没有可回退的运行时"
    end

    local runtime_state = document:collect_runtime_save_state()
    if type(runtime_state) ~= "table" then
        return nil, "当前没有可回退的运行时"
    end

    local scene_context = _get_scene_context(document)
    local skip_object_id_set = _make_id_set(runtime_state.skip_object_ids)
    local skip_ui_instance_id_set = _make_id_set(runtime_state.skip_ui_instance_ids)
    local scene_state = scene_context and scene_context.collect_save_state and scene_context:collect_save_state(
    {
        skip_object_id_set = skip_object_id_set,
    }) or
    {
        schema_version = 1,
        object_list = {},
    }

    local ui_runtime = scene_context and scene_context.get_ui_runtime and scene_context:get_ui_runtime() or nil
    local ui_state = ui_runtime and ui_runtime.collect_save_state and ui_runtime:collect_save_state(
    {
        skip_instance_id_set = skip_ui_instance_id_set,
    }) or
    {
        schema_version = 1,
        instance_list = {},
    }

    local style_manager = _get_style_manager()
    local audio_manager = _get_audio_playback_manager()

    return
    {
        runtime = _clone_value(runtime_state),
        scene = _clone_value(scene_state),
        ui = _clone_value(ui_state),
        globals = _clone_value(GlobalContext.runtime_global_context or {}),
        style = style_manager.collect_runtime_state and style_manager.collect_runtime_state() or {},
        audio = audio_manager.collect_runtime_state and audio_manager.collect_runtime_state() or {},
    }
end

local function _validate_runtime_snapshot(document, snapshot)
    if not document or type(snapshot) ~= "table" then
        return false, "无效的回退快照"
    end

    if document.validate_runtime_save_state then
        local runtime_ok, runtime_err = document:validate_runtime_save_state(snapshot.runtime or {})
        if runtime_ok ~= true then
            return false, runtime_err or "回退快照对应的流程运行时已失效"
        end
    end

    local runtime_state = type(snapshot.runtime) == "table" and snapshot.runtime or {}
    local skip_object_id_set = _make_id_set(runtime_state.skip_object_ids)
    local skip_ui_instance_id_set = _make_id_set(runtime_state.skip_ui_instance_ids)
    local scene_context = _get_scene_context(document)
    if scene_context and scene_context.validate_save_state then
        local scene_ok, scene_err = scene_context:validate_save_state(snapshot.scene or {},
        {
            skip_object_id_set = skip_object_id_set,
        })
        if scene_ok ~= true then
            return false, scene_err or "回退快照对应的场景状态已失效"
        end
    end

    local ui_runtime = scene_context and scene_context.get_ui_runtime and scene_context:get_ui_runtime() or nil
    if ui_runtime and ui_runtime.validate_save_state then
        local ui_ok, ui_err = ui_runtime:validate_save_state(snapshot.ui or {},
        {
            skip_instance_id_set = skip_ui_instance_id_set,
        })
        if ui_ok ~= true then
            return false, ui_err or "回退快照对应的界面状态已失效"
        end
    end

    local style_manager = _get_style_manager()
    if style_manager.validate_runtime_state then
        local style_ok, style_err = style_manager.validate_runtime_state(snapshot.style or {})
        if style_ok ~= true then
            return false, style_err or "回退快照对应的样式状态已失效"
        end
    end

    local audio_manager = _get_audio_playback_manager()
    if audio_manager.validate_runtime_state then
        local audio_ok, audio_err = audio_manager.validate_runtime_state(snapshot.audio or {})
        if audio_ok ~= true then
            return false, audio_err or "回退快照对应的音频状态已失效"
        end
    end

    return true
end

local function _apply_runtime_snapshot(document, snapshot)
    if not document or type(snapshot) ~= "table" then
        return false, "无效的回退快照"
    end

    local style_manager = _get_style_manager()
    local audio_manager = _get_audio_playback_manager()

    GlobalContext.runtime_global_context = _clone_value(type(snapshot.globals) == "table" and snapshot.globals or {})

    if style_manager.apply_runtime_state then
        local ok, err = style_manager.apply_runtime_state(snapshot.style or {})
        if ok ~= true then
            return false, err or "恢复样式状态失败"
        end
    end

    local snapshot_runtime_state = type(snapshot.runtime) == "table" and snapshot.runtime or {}
    local skip_object_id_set = _make_id_set(snapshot_runtime_state.skip_object_ids)
    local skip_ui_instance_id_set = _make_id_set(snapshot_runtime_state.skip_ui_instance_ids)

    local runtime_ok, runtime_err = document:restore_runtime_save_state(snapshot_runtime_state)
    if runtime_ok ~= true then
        return false, runtime_err or "恢复流程运行时失败"
    end

    local scene_context = _get_scene_context(document)
    if scene_context and scene_context.apply_save_state then
        local scene_ok, scene_err = scene_context:apply_save_state(snapshot.scene or {},
        {
            skip_object_id_set = skip_object_id_set,
        })
        if scene_ok ~= true then
            return false, scene_err or "恢复场景状态失败"
        end
    end

    local ui_runtime = scene_context and scene_context.get_ui_runtime and scene_context:get_ui_runtime() or nil
    if ui_runtime and ui_runtime.apply_save_state then
        local ui_ok, ui_err = ui_runtime:apply_save_state(snapshot.ui or {},
        {
            skip_instance_id_set = skip_ui_instance_id_set,
        })
        if ui_ok ~= true then
            return false, ui_err or "恢复界面状态失败"
        end
    end

    if document.resolve_runtime_local_references then
        document:resolve_runtime_local_references()
    end

    if audio_manager.apply_runtime_state then
        local audio_ok, audio_err = audio_manager.apply_runtime_state(snapshot.audio or {})
        if audio_ok ~= true then
            return false, audio_err or "恢复音频状态失败"
        end
    end

    if scene_context and scene_context.block_runtime_interaction_until_release then
        scene_context:block_runtime_interaction_until_release("回退")
    end

    GlobalContext.is_simulated_interaction = false
    return true
end

local function _push_history_snapshot(document, snapshot, options)
    if type(snapshot) ~= "table" then
        return false
    end

    local history_stack = state.history_stack
    if type(history_stack) ~= "table" then
        history_stack = {}
        state.history_stack = history_stack
    end

    local signature = _make_snapshot_signature(snapshot)
    local previous_entry = history_stack[#history_stack]
    if previous_entry
        and _is_same_runtime_document(previous_entry.document, document)
        and previous_entry.signature ~= nil
        and previous_entry.signature == signature
    then
        previous_entry.reason = _trim(options and options.reason) or previous_entry.reason or ""
        previous_entry.label = _trim(options and options.label) or previous_entry.label or ""
        previous_entry.source = _trim(options and options.source) or previous_entry.source or "runtime"
        previous_entry.created_at = os.time()
        return true
    end

    history_stack[#history_stack + 1] =
    {
        document = document,
        snapshot = snapshot,
        signature = signature,
        reason = _trim(options and options.reason) or "",
        label = _trim(options and options.label) or "",
        source = _trim(options and options.source) or "runtime",
        created_at = os.time(),
    }

    local limit = math.max(1, math.floor(tonumber(state.history_limit) or 64))
    while #history_stack > limit do
        table.remove(history_stack, 1)
    end
    return true
end

local function _clear_runtime_modes()
    state.fast_forward_enabled = false
    state.fast_forward_phase = false
    state.auto_advance_enabled = false
    state.auto_advance_interval = 1.0
    state.auto_advance_timer = 0
    state.auto_advance_binding_key = nil
    state.rollback_requested = false
    GlobalContext.is_simulated_interaction = false
end

function module.reset_runtime_state()
    state.history_stack = {}
    _clear_runtime_modes()
    state.restoring = false
    return true
end

function module.capture_before_transition(document, options)
    if state.restoring == true then
        return false, "正在恢复回退快照"
    end

    local runtime_document = document or (GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil)
    local snapshot, err = _capture_runtime_snapshot(runtime_document)
    if not snapshot then
        return false, err
    end
    _push_history_snapshot(runtime_document, snapshot, options)
    return true
end

function module.toggle_fast_forward(document, options)
    return module.set_fast_forward_enabled(document, state.fast_forward_enabled ~= true, options)
end

function module.set_fast_forward_enabled(document, enabled, options)
    if enabled ~= true then
        state.fast_forward_enabled = false
        state.fast_forward_phase = false
        GlobalContext.is_simulated_interaction = false
        return false
    end

    state.fast_forward_enabled = true
    state.fast_forward_phase = true
    state.auto_advance_enabled = false
    state.auto_advance_timer = 0
    state.auto_advance_binding_key = nil
    GlobalContext.is_simulated_interaction = false
    _prime_runtime_wait_state(document or (GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil))
    return true
end

function module.toggle_auto_advance(document, interval, options)
    local next_interval = _normalize_interval(interval)
    if state.auto_advance_enabled and math.abs((tonumber(state.auto_advance_interval) or 0) - next_interval) < 0.00001 then
        module.set_auto_advance_enabled(document, false, next_interval, options)
        return false, next_interval
    end

    return module.set_auto_advance_enabled(document, true, next_interval, options)
end

function module.set_auto_advance_enabled(document, enabled, interval, options)
    local next_interval = _normalize_interval(interval)
    local next_binding_key = _trim(options and options.binding_key)
    if enabled ~= true then
        state.auto_advance_enabled = false
        state.auto_advance_timer = 0
        state.auto_advance_binding_key = nil
        GlobalContext.is_simulated_interaction = false
        return false, next_interval
    end

    if state.auto_advance_enabled == true
        and math.abs((tonumber(state.auto_advance_interval) or 0) - next_interval) < 0.00001
        and state.auto_advance_binding_key == next_binding_key
    then
        state.fast_forward_enabled = false
        state.fast_forward_phase = false
        _prime_runtime_wait_state(document or (GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil))
        return true, next_interval
    end

    state.fast_forward_enabled = false
    state.fast_forward_phase = false
    state.auto_advance_enabled = true
    state.auto_advance_interval = next_interval
    state.auto_advance_timer = next_interval
    state.auto_advance_binding_key = next_binding_key
    GlobalContext.is_simulated_interaction = false
    _prime_runtime_wait_state(document or (GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil))
    return true, next_interval
end

function module.is_auto_advance_bound()
    return state.auto_advance_binding_key ~= nil
end

function module.request_rollback(options)
    state.fast_forward_enabled = false
    state.fast_forward_phase = false
    state.auto_advance_enabled = false
    state.auto_advance_timer = 0
    state.auto_advance_binding_key = nil
    state.rollback_requested = true
    GlobalContext.is_simulated_interaction = false
    return true
end

function module.has_pending_rollback()
    return state.rollback_requested == true
end

function module.consume_rollback_request(document)
    if state.rollback_requested ~= true then
        return false
    end

    state.rollback_requested = false
    local runtime_document = document or (GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil)
    if not runtime_document then
        return false, "当前没有运行中的流程"
    end

    local current_snapshot, current_err = _capture_runtime_snapshot(runtime_document)
    local current_signature = _make_snapshot_signature(current_snapshot)
    local history_stack = state.history_stack
    while type(history_stack) == "table" and #history_stack > 0 do
        local entry = table.remove(history_stack)
        local snapshot = entry and entry.snapshot or nil
        local snapshot_signature = entry and entry.signature or _make_snapshot_signature(snapshot)
        if entry and not _is_same_runtime_document(entry.document, runtime_document) then
            goto continue
        end
        if current_signature ~= nil and snapshot_signature ~= nil and current_signature == snapshot_signature then
            goto continue
        end
        if snapshot then
            local valid, validation_err = _validate_runtime_snapshot(runtime_document, snapshot)
            if valid == true then
                state.restoring = true
                local ok, restore_ok, restore_err = pcall(_apply_runtime_snapshot, runtime_document, snapshot)
                state.restoring = false
                if ok == true and restore_ok == true then
                    return true
                end
                if current_snapshot then
                    pcall(_apply_runtime_snapshot, runtime_document, current_snapshot)
                end
                return false, restore_err or restore_ok or "回退快照恢复失败"
            end
            if validation_err then
                -- 继续尝试更早的快照。
            end
        end
        ::continue::
    end

    if current_snapshot then
        pcall(_apply_runtime_snapshot, runtime_document, current_snapshot)
    end
    return false, current_err or "没有可回退的历史快照"
end

function module.update(document, scene_context, delta)
    if state.restoring == true then
        GlobalContext.is_simulated_interaction = false
        return false
    end

    local runtime_document = document or (GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil)
    if not runtime_document then
        _clear_runtime_modes()
        return false
    end

    if _is_choice_wait_active(runtime_document, scene_context) then
        if state.fast_forward_enabled then
            state.fast_forward_enabled = false
            state.fast_forward_phase = false
        end
        GlobalContext.is_simulated_interaction = false
        return false
    end

    if state.fast_forward_enabled then
        _prime_runtime_wait_state(runtime_document)
        state.fast_forward_phase = true
        GlobalContext.is_simulated_interaction = true
        return true
    end

    if state.auto_advance_enabled then
        _prime_runtime_wait_state(runtime_document)
        local interval = _normalize_interval(state.auto_advance_interval)
        state.auto_advance_interval = interval
        state.auto_advance_timer = (tonumber(state.auto_advance_timer) or interval) - math.max(0, tonumber(delta) or 0)
        if state.auto_advance_timer <= 0 then
            GlobalContext.is_simulated_interaction = true
            state.auto_advance_timer = interval
            return true
        end
        GlobalContext.is_simulated_interaction = false
        return false
    end

    GlobalContext.is_simulated_interaction = false
    return false
end

function module.is_fast_forward_enabled()
    return state.fast_forward_enabled == true
end

function module.is_auto_advance_enabled()
    return state.auto_advance_enabled == true
end

function module.get_auto_advance_interval()
    return _normalize_interval(state.auto_advance_interval)
end

function module.get_control_state()
    return
    {
        fast_forward_enabled = state.fast_forward_enabled == true,
        auto_advance_enabled = state.auto_advance_enabled == true,
        auto_advance_interval = _normalize_interval(state.auto_advance_interval),
        auto_advance_binding_key = state.auto_advance_binding_key,
        rollback_requested = state.rollback_requested == true,
    }
end

function module.get_history_count()
    return #(state.history_stack or {})
end

return module

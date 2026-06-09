local Class = require("application.framework.class")
local Billboard = require("application.framework.billboard")
local BranchSelector = require("application.framework.branch_selector")
local BackgroundObject = require("application.framework.runtime_objects.background_object")
local ForegroundObject = require("application.framework.runtime_objects.foreground_object")
local LetterboxingObject = require("application.framework.runtime_objects.letterboxing_object")
local SubtitleObject = require("application.framework.runtime_objects.subtitle_object")
local TransitionFadeObject = require("application.framework.runtime_objects.transition_fade_object")
local GameObject = require("application.framework.game_object")
local GlobalContext = require("application.framework.global_context")
local RuntimeInputState = require("application.framework.runtime_input_state")
local UIRuntime = require("application.framework.ui_runtime")

local Scene = Class.define("Scene", GameObject)
local unsupported_save_object_type_pool =
{
    Tween = true,
    Timer = true,
    VideoRenderer = true,
}

local save_state_creator_pool =
{
    BackgroundObject = BackgroundObject.create_from_save_state,
    ForegroundObject = ForegroundObject.create_from_save_state,
    LetterboxingObject = LetterboxingObject.create_from_save_state,
    TransitionFadeObject = TransitionFadeObject.create_from_save_state,
    Billboard = Billboard.create_from_save_state,
    DialogBox = Billboard.create_from_save_state,
    SubtitleObject = SubtitleObject.create_from_save_state,
    Subtitle = SubtitleObject.create_from_save_state,
    ChoiceButton = BranchSelector.create_from_save_state,
}

local function _ensure_object_storage(self)
    if rawget(self, "_go_pool") == nil then
        self._go_pool = {}
    end
    if rawget(self, "_go_list") == nil then
        self._go_list = {}
    end
    if rawget(self, "_go_order_serial") == nil then
        self._go_order_serial = 0
    end
    if rawget(self, "_go_order_dirty") == nil then
        self._go_order_dirty = true
    end
end

local function _sort_objects_if_dirty(self)
    if self._go_order_dirty ~= true then
        return
    end

    table.sort(self._go_list, function(obj_1, obj_2)
        local z_1 = tonumber(obj_1 and obj_1._z_idx) or 0
        local z_2 = tonumber(obj_2 and obj_2._z_idx) or 0
        if z_1 ~= z_2 then
            return z_1 < z_2
        end

        local order_1 = tonumber(obj_1 and obj_1._go_order_serial) or 0
        local order_2 = tonumber(obj_2 and obj_2._go_order_serial) or 0
        if order_1 ~= order_2 then
            return order_1 < order_2
        end

        return tostring(obj_1 and obj_1._id or "") < tostring(obj_2 and obj_2._id or "")
    end)
    self._go_order_dirty = false
end

local function _remove_object(self, obj, idx)
    if not obj then
        return
    end

    self._go_pool[obj._id] = nil
    if idx then
        table.remove(self._go_list, idx)
    else
        for i, value in ipairs(self._go_list) do
            if value == obj then
                table.remove(self._go_list, i)
                break
            end
        end
    end

    obj:on_removed(self)
    obj._scene = nil
    obj:destroy()
end

local function _apply_ui_input_capture(self, capture_result)
    self._ui_input_capture_result = RuntimeInputState.normalize_capture_result(capture_result)
end

local function _has_runtime_submit_down(input)
    local key_down_map = type(input and input.key_down_map) == "table" and input.key_down_map or {}
    return key_down_map.space == true
        or key_down_map.enter == true
        or key_down_map.keypad_enter == true
end

local function _has_runtime_interaction_down(input)
    return input and (input.mouse_down == true or _has_runtime_submit_down(input))
end

local function _has_runtime_interaction_edge(input)
    if not input then
        return false
    end

    local key_released_map = type(input.key_released_map) == "table" and input.key_released_map or {}
    return input.mouse_pressed == true
        or input.mouse_released == true
        or input.submit_pressed == true
        or input.space_pressed == true
        or input.enter_pressed == true
        or input.keypad_enter_pressed == true
        or key_released_map.space == true
        or key_released_map.enter == true
        or key_released_map.keypad_enter == true
end

local function _is_runtime_interaction_barrier_active(self)
    local barrier = self and self._runtime_interaction_barrier or nil
    return type(barrier) == "table" and barrier.active == true
end

local function _update_runtime_interaction_barrier(self)
    local barrier = self._runtime_interaction_barrier
    if type(barrier) ~= "table" or barrier.active ~= true then
        return
    end

    local input = self._runtime_input_state
    if _has_runtime_interaction_down(input) or _has_runtime_interaction_edge(input) then
        barrier.clean_frame_count = 0
        return
    end

    barrier.clean_frame_count = (tonumber(barrier.clean_frame_count) or 0) + 1
    if barrier.clean_frame_count >= 1 then
        barrier.active = false
        barrier.reason = nil
    end
end

local function _begin_runtime_input_frame(self)
    self._runtime_input_state = RuntimeInputState.read_current_state()
    self._ui_input_capture_result = RuntimeInputState.make_empty_capture_result()
    _update_runtime_interaction_barrier(self)
end

local function _is_ui_overlay_object(obj)
    return Class.is_instance(obj, Billboard)
        or Class.is_instance(obj, BranchSelector)
        or Class.is_instance(obj, SubtitleObject)
end

local function _render_scene_objects(self, predicate)
    for _, value in ipairs(self._go_list) do
        if value._valid and predicate(value) then
            value:on_render()
        end
    end
end

function Scene:ctor()
    Class.call_super(Scene, self, "ctor")
    _ensure_object_storage(self)
    self._runtime_input_state = RuntimeInputState.normalize_state()
    self._ui_input_capture_result = RuntimeInputState.make_empty_capture_result()
    self._runtime_interaction_barrier = {active = false, clean_frame_count = 0}
    self._ui_runtime = UIRuntime.new(self)
    self._save_state_provider_pool = {}
end

function Scene:on_enter()
end

function Scene:on_exit()
end

function Scene:add_object(obj, id, z_idx)
    _ensure_object_storage(self)
    assert(Class.is_instance(obj, GameObject), "Scene:add_object only accepts GameObject instances")
    self:del_object(id)
    assert(not obj:is_destroyed(), "Scene:add_object cannot reuse a destroyed object")

    obj._id = id
    if z_idx then
        obj._z_idx = z_idx
    end

    self._go_order_serial = self._go_order_serial + 1
    obj._go_order_serial = self._go_order_serial
    obj._valid = true
    obj._scene = self
    self._go_pool[id] = obj
    table.insert(self._go_list, obj)
    self._go_order_dirty = true
    obj:on_added(self)
end

function Scene:del_object(id)
    _ensure_object_storage(self)
    local obj = self._go_pool[id]
    if not obj then
        return
    end
    _remove_object(self, obj)
end

function Scene:find_object(id)
    _ensure_object_storage(self)
    return self._go_pool[id]
end

function Scene:clear_objects()
    _ensure_object_storage(self)
    for i = #self._go_list, 1, -1 do
        _remove_object(self, self._go_list[i], i)
    end
end

function Scene:mark_object_order_dirty()
    _ensure_object_storage(self)
    self._go_order_dirty = true
end

function Scene:on_update(delta)
    _ensure_object_storage(self)
    _begin_runtime_input_frame(self)
    if self._ui_runtime and self._ui_runtime.begin_frame then
        _apply_ui_input_capture(self, self._ui_runtime:begin_frame(self:get_runtime_input_state()))
    end

    _sort_objects_if_dirty(self)

    for _, value in ipairs(self._go_list) do
        if value._valid then
            value:on_update(delta)
        end
    end

    for i = #self._go_list, 1, -1 do
        local obj = self._go_list[i]
        if not obj._valid then
            _remove_object(self, obj, i)
        end
    end

    if self._ui_runtime and self._ui_runtime.update then
        self._ui_runtime:update(delta)
    end
end

function Scene:on_render(options)
    local render_options = type(options) == "table" and options or nil
    local suppress_resource_ui = render_options and render_options.suppress_resource_ui == true
    _ensure_object_storage(self)
    _sort_objects_if_dirty(self)
    _render_scene_objects(self, function(value)
        return not _is_ui_overlay_object(value)
    end)

    _render_scene_objects(self, _is_ui_overlay_object)

    if self._ui_runtime and self._ui_runtime.render then
        self._ui_runtime:render(suppress_resource_ui and {suppress_resource_ui = true} or nil)
    end
end

function Scene:on_destroy()
    if self._ui_runtime and self._ui_runtime.destroy then
        self._ui_runtime:destroy()
        self._ui_runtime = nil
    end
    self:clear_objects()
end

function Scene:get_ui_runtime()
    return self._ui_runtime
end

function Scene:register_save_state_provider(key, provider)
    local provider_key = tostring(key or "")
    if provider_key == "" or type(provider) ~= "table" then
        return false
    end
    self._save_state_provider_pool[provider_key] = provider
    return true
end

function Scene:unregister_save_state_provider(key)
    local provider_key = tostring(key or "")
    if provider_key == "" then
        return false
    end
    self._save_state_provider_pool[provider_key] = nil
    return true
end

function Scene:can_save_now(options)
    _ensure_object_storage(self)
    local save_options = type(options) == "table" and options or {}
    local skip_object_id_set = save_options.skip_object_id_set or {}
    local skip_ui_instance_id_set = save_options.skip_ui_instance_id_set or {}
    local allow_active_managed_ui_sessions = save_options.allow_active_managed_ui_sessions == true
    for _, object in ipairs(self._go_list) do
        local object_id = object and object._id or nil
        if object and object._valid then
            if skip_object_id_set[tostring(object_id or "")] then
                goto continue
            end
            if object.can_save_now then
                local ok, reason = object:can_save_now()
                if ok ~= true then
                    return false, reason or "当前场景对象尚未进入可保存状态"
                end
            else
                local class_name = object.get_class_name and object:get_class_name() or object._metaname or "GameObject"
                if unsupported_save_object_type_pool[class_name] then
                    return false, string.format("场景中仍存在不可恢复的运行时对象：%s", tostring(class_name))
                end
            end
        end
        ::continue::
    end

    if self._ui_runtime and self._ui_runtime.can_save_now then
        local ok, reason = self._ui_runtime:can_save_now(
        {
            skip_instance_id_set = skip_ui_instance_id_set,
            allow_active_managed_ui_sessions = allow_active_managed_ui_sessions,
        })
        if ok ~= true then
            return false, reason or "当前界面运行时尚未进入可保存状态"
        end
    end

    for _, provider in pairs(self._save_state_provider_pool or {}) do
        if provider.can_save_now then
            local ok, reason = provider.can_save_now(provider, self, save_options)
            if ok ~= true then
                return false, reason or "场景扩展服务尚未进入可保存状态"
            end
        end
    end

    return true
end

function Scene:collect_save_state(options)
    _ensure_object_storage(self)
    local collect_options = type(options) == "table" and options or {}
    local skip_object_id_set = collect_options.skip_object_id_set or {}
    local object_list = {}
    local provider_state = {}

    for _, object in ipairs(self._go_list) do
        local object_id = object and object._id or nil
        if object and object._valid and not skip_object_id_set[tostring(object_id or "")] then
            local state = object.collect_save_state and object:collect_save_state() or nil
            if type(state) == "table" then
                object_list[#object_list + 1] =
                {
                    object_id = object_id,
                    z_idx = object._z_idx,
                    object_type = state.type or (object.get_class_name and object:get_class_name()) or "GameObject",
                    state = state,
                }
            end
        end
    end

    for key, provider in pairs(self._save_state_provider_pool or {}) do
        if provider.collect_save_state then
            provider_state[key] = provider.collect_save_state(provider, self)
        end
    end

    return
    {
        schema_version = 1,
        object_list = object_list,
        provider_state = provider_state,
    }
end

function Scene.validate_save_state(state, options)
    local snapshot = type(state) == "table" and state or {}
    local validate_options = type(options) == "table" and options or {}
    local skip_object_id_set = validate_options.skip_object_id_set or {}
    for _, entry in ipairs(snapshot.object_list or {}) do
        local object_id = tostring(entry and entry.object_id or "")
        if skip_object_id_set[object_id] then
            goto continue
        end
        local object_type = tostring(entry and entry.object_type or "")
        if object_type ~= "" and not save_state_creator_pool[object_type] then
            return false, string.format("存档对应的场景对象类型已无法恢复：%s", object_type)
        end
        ::continue::
    end
    return true
end

function Scene:apply_save_state(state, options)
    _ensure_object_storage(self)
    local snapshot = type(state) == "table" and state or {}
    local apply_options = type(options) == "table" and options or {}
    local skip_object_id_set = apply_options.skip_object_id_set or {}

    for index = #self._go_list, 1, -1 do
        local object = self._go_list[index]
        local object_id = object and object._id or nil
        if object and not skip_object_id_set[tostring(object_id or "")] then
            _remove_object(self, object, index)
        end
    end

    for _, entry in ipairs(snapshot.object_list or {}) do
        local object_id = tostring(entry.object_id or "")
        if object_id ~= "" and not skip_object_id_set[object_id] then
            local creator = save_state_creator_pool[tostring(entry.object_type or "")]
            if creator then
                local object = creator(entry.state or {})
                if object then
                    self:add_object(object, object_id, tonumber(entry.z_idx) or 0)
                end
            else
                return false, string.format("存档对应的场景对象类型已无法恢复：%s", tostring(entry.object_type or ""))
            end
        end
    end

    for key, provider in pairs(self._save_state_provider_pool or {}) do
        if provider.apply_save_state then
            local ok, err = provider.apply_save_state(provider, self, snapshot.provider_state and snapshot.provider_state[key] or nil)
            if ok == false then
                return false, err or string.format("场景扩展服务恢复失败：%s", tostring(key))
            end
        end
    end

    return true
end

function Scene:get_runtime_input_state()
    return RuntimeInputState.clone_state(self._runtime_input_state)
end

function Scene:get_ui_input_capture_result()
    return RuntimeInputState.clone_state(self._ui_input_capture_result)
end

function Scene:block_runtime_interaction_until_release(reason)
    self._runtime_interaction_barrier =
    {
        active = true,
        clean_frame_count = 0,
        reason = tostring(reason or ""),
    }
end

function Scene:is_runtime_interaction_blocked()
    return _is_runtime_interaction_barrier_active(self)
end

function Scene:has_runtime_interaction_activity()
    return _is_runtime_interaction_barrier_active(self)
        or _has_runtime_interaction_down(self._runtime_input_state)
        or _has_runtime_interaction_edge(self._runtime_input_state)
end

function Scene:get_runtime_pointer_position()
    return
    {
        x = tonumber(self._runtime_input_state.mouse_x) or -100000,
        y = tonumber(self._runtime_input_state.mouse_y) or -100000,
    }
end

function Scene:is_runtime_pointer_down()
    return self._runtime_input_state.mouse_down == true
        and not _is_runtime_interaction_barrier_active(self)
        and self._ui_input_capture_result.pointer_pressed_consumed ~= true
        and self._ui_input_capture_result.pointer_released_consumed ~= true
end

function Scene:is_runtime_pointer_pressed()
    return self._runtime_input_state.mouse_pressed == true
        and not _is_runtime_interaction_barrier_active(self)
        and self._ui_input_capture_result.pointer_pressed_consumed ~= true
end

function Scene:is_runtime_pointer_released()
    return self._runtime_input_state.mouse_released == true
        and not _is_runtime_interaction_barrier_active(self)
        and self._ui_input_capture_result.pointer_released_consumed ~= true
end

function Scene:get_runtime_wheel_y()
    if self._ui_input_capture_result.wheel_consumed == true then
        return 0
    end
    return tonumber(self._runtime_input_state.wheel_y) or 0
end

function Scene:is_runtime_submit_pressed()
    return self._runtime_input_state.submit_pressed == true
        and not _is_runtime_interaction_barrier_active(self)
        and self._ui_input_capture_result.submit_consumed ~= true
end

function Scene:is_runtime_space_pressed()
    return self._runtime_input_state.space_pressed == true
        and not _is_runtime_interaction_barrier_active(self)
        and self._ui_input_capture_result.submit_consumed ~= true
end

function Scene:is_runtime_interaction_pressed()
    if GlobalContext.is_simulated_interaction == true then
        return true
    end
    return self:is_runtime_pointer_pressed() or self:is_runtime_space_pressed()
end

function Scene:open_ui(document_or_reference, options)
    if not self._ui_runtime or not self._ui_runtime.open_document then
        return nil, "UIRuntime 不可用"
    end
    return self._ui_runtime:open_document(document_or_reference, options)
end

function Scene:close_ui(value)
    if not self._ui_runtime or not self._ui_runtime.close_by_source then
        return false
    end
    return self._ui_runtime:close_by_source(value)
end

function Scene:find_ui_instance(value)
    if not self._ui_runtime or not self._ui_runtime.find_instance then
        return nil
    end
    return self._ui_runtime:find_instance(value)
end

function Scene:consume_closed_ui_result(value)
    if not self._ui_runtime or not self._ui_runtime.consume_closed_instance_result then
        return nil
    end
    return self._ui_runtime:consume_closed_instance_result(value)
end

function Scene:collect_global_ui_state()
    if not self._ui_runtime or not self._ui_runtime.collect_global_overlay_state then
        return {schema_version = 1, instance_list = {}}
    end
    return self._ui_runtime:collect_global_overlay_state()
end

function Scene:apply_global_ui_state(state)
    if not self._ui_runtime or not self._ui_runtime.apply_global_overlay_state then
        return false
    end
    return self._ui_runtime:apply_global_overlay_state(state)
end

function Scene:emit_ui_event(instance_or_id, event_name, extra)
    return false, "界面事件入口已移除"
end

return Scene

local rl = Engine.Raylib
local json = Engine.JSON
local imgui = Engine.ImGUI

local Class = require("application.framework.class")
local Scene = require("application.framework.scene")
local GameObject = require("application.framework.game_object")
local TableUtil = require("application.framework.table_util")
local LogManager = require("application.framework.log_manager")
local NodeFactory = require("application.framework.node_factory")
local NodeRegistry = require("application.framework.node_registry")
local PinRegistry = require("application.framework.pin_registry")
local BlueprintClipboard = require("application.framework.blueprint_clipboard")
local BlueprintNavigation = require("application.framework.blueprint_navigation")
local ResourceReferenceField = require("application.framework.resource_reference_field")
local UndoManager = require("application.framework.undo_manager")
local ModifyManager = require("application.framework.modify_manager")
local GlobalContext = require("application.framework.global_context")
local SettingsManager = require("application.framework.settings_manager")
local EditorThemeManager = require("application.framework.editor_theme_manager")
local ResourcesManager = require("application.framework.resources_manager")
local NativeIO = require("application.framework.native_io")
local FlowRuntimeError = require("application.framework.flow_runtime_error")

local color_link_accepted = imgui.ImVec4(imgui.ImColor(45, 225, 45, 255).value)
local color_link_rejected = imgui.ImVec4(imgui.ImColor(225, 45, 45, 255).value)
local blueprint_clipboard_kind <const> = "vne_flow_clipboard"
local blueprint_clipboard_version <const> = 1
local paste_offset_x <const> = 32
local paste_offset_y <const> = 24
local _flow_guard_is_protecting
local debug_visual_zoom_threshold <const> = 0.65
local flow_cache_idle_stable_frames_required <const> = 2
local flow_cache_live_warmup_frames <const> = 2
local flow_context_popup_close_grace_frames <const> = 2
local flow_guard_visible_sample_interval_ms <const> = 400
local flow_guard_zoom_apply_delay_ms <const> = 180
local flow_guard_node_total_observe_threshold <const> = 48
local flow_guard_node_total_protect_threshold <const> = 64
local flow_guard_visible_observe_threshold <const> = 32
local flow_guard_visible_protect_threshold <const> = 48
local flow_guard_fps_soft_threshold <const> = 50
local flow_guard_fps_hard_threshold <const> = 32
local flow_guard_fps_recover_threshold <const> = 56
local flow_guard_live_soft_ms <const> = 10
local flow_guard_live_hard_ms <const> = 18
local flow_guard_live_recover_ms <const> = 12.5
local flow_guard_enter_observe_duration_ms <const> = 550
local flow_guard_enter_protect_duration_ms <const> = 1600
local flow_guard_enter_protect_hard_duration_ms <const> = 1000
local flow_guard_min_observe_duration_ms <const> = 900
local flow_guard_leave_protect_duration_ms <const> = 520
local flow_guard_cooldown_duration_ms <const> = 900
local flow_guard_host_area_divisor <const> = 90000
local flow_guard_ema_half_life_ms <const> = 320
local flow_guard_zoom_epsilon <const> = 0.01
local flow_guard_zoom_response_soft_power <const> = 0.38
local flow_guard_zoom_response_hard_power <const> = 0.52
local flow_guard_zoom_ratio_soft_max <const> = 2.00
local flow_guard_zoom_ratio_hard_max <const> = 2.60
local runtime_default_max_steps_per_frame <const> = 1000
local runtime_trace_node_limit <const> = 16

local Blueprint = Class.define("Blueprint")
local _id_value

local function _get_document_name(self)
    return self._resource_id or self._path or self._id
end

local function _stringify_error(value, fallback)
    if value == nil or value == "" then
        return fallback or "未知错误"
    end
    return tostring(value)
end

local function _touch_document(self)
    self._document_last_used_time = rl.GetTime()
end

local function _append_runtime_trace(trace, node)
    if type(trace) ~= "table" or not node then
        return
    end

    trace[#trace + 1] = FlowRuntimeError.describe_node(node)
    while #trace > runtime_trace_node_limit do
        table.remove(trace, 1)
    end
end

local function _format_runtime_trace(trace)
    if type(trace) ~= "table" or #trace == 0 then
        return ""
    end
    return table.concat(trace, " -> ")
end

local function _abort_runtime_step_overflow(self, max_steps, trace)
    local node = rawget(self, "_next_node") or rawget(self, "_current_node")
    local trace_text = _format_runtime_trace(trace)
    local message = string.format("流程图单帧执行超过 %d 个节点，疑似存在循环 flow 路由。", max_steps)
    if trace_text ~= "" then
        message = string.format("%s 最近路径：%s", message, trace_text)
    end

    self._next_node = nil
    self._next_node_entry_pin = nil
    FlowRuntimeError.handle(
    {
        kind = "flow_runtime_abort",
        subtype = "flow_cycle_detected",
        message = message,
        context =
        {
            blueprint = self,
            node = node,
        },
    },
    {
        blueprint = self,
        node = node,
    })
end

function Blueprint:_with_node_editor_binding(callback)
    if type(callback) ~= "function"
        or not self
        or self._disable_editor_binding == true
        or not self._context
        or not imgui.NodeEditor
        or type(imgui.NodeEditor.SetCurrentEditor) ~= "function"
    then
        return nil
    end

    local previous_context = nil
    if type(imgui.NodeEditor.GetCurrentEditor) == "function" then
        previous_context = imgui.NodeEditor.GetCurrentEditor()
    end
    imgui.NodeEditor.SetCurrentEditor(self._context)
    local ok, result = pcall(callback)
    imgui.NodeEditor.SetCurrentEditor(previous_context)
    if not ok then
        error(result)
    end
    return result
end

function Blueprint:_clear_node_editor_selection()
    self:_with_node_editor_binding(function()
        imgui.NodeEditor.ClearSelection()
    end)
end

function Blueprint:_clear_document_edit_state()
    local previous_modify_context = ModifyManager.get_context()
    local previous_undo_context = UndoManager.get_context()
    ModifyManager.set_context(self._modify_context)
    UndoManager.set_context(self._undo_context)
        ModifyManager.set_modify(false)
        UndoManager.clear()
    UndoManager.set_context(previous_undo_context)
    ModifyManager.set_context(previous_modify_context)
end

function Blueprint:_apply_queued_pin_widget_selection()
    local node_id = self._flow_pending_widget_select_node_id
    self._flow_pending_widget_select_node_id = nil
    if type(node_id) ~= "number"
        or not self._node_pool
        or not self._node_pool[node_id]
        or not imgui.NodeEditor
        or type(imgui.NodeEditor.SelectNode) ~= "function" then
        return false
    end

    imgui.NodeEditor.SelectNode(self._node_pool[node_id]._id, false)
    return true
end

local function _is_document_loaded(self)
    return self._document_loaded == true
end

local function _clone_signature(signature)
    if type(signature) ~= "table" then
        return nil
    end
    return {size = signature.size, mtime = signature.mtime}
end

local function _update_resource_meta(self, resource_source)
    local path = resource_source
    local meta = nil
    if type(resource_source) == "table" then
        meta = resource_source
        path = meta.path
    end

    self._path = path
    self._resource_guid = meta and meta.guid or nil
    self._resource_id = meta and meta.id or rl.GetFileNameWithoutExt(path)
    self._display_name = meta and meta.display_name or rl.GetFileNameWithoutExt(path)
    self._resource_file_signature = meta and _clone_signature(meta.file_signature) or self._resource_file_signature
    self._resource_missing = meta == nil and self._resource_missing or false
    self._id = self._display_name
    self._tab_label = string.format("%s##%s", self._display_name, self._resource_guid or self._resource_id or path)
end

-- 检查指定引脚对象是否可以被连接
local function _can_link(pin_input, pin_output)
    return PinRegistry.can_link(pin_input, pin_output)
end

local function _resolve_link_pins(pin_a, pin_b)
    if not pin_a or not pin_b or pin_a._is_output == pin_b._is_output then
        return nil, nil
    end

    if pin_a._is_output then
        return pin_b, pin_a
    end

    return pin_a, pin_b
end

_id_value = function(id)
    local id_type = type(id)
    if id_type == "table" or id_type == "userdata" then
        local ok, value = pcall(function()
            return id:get()
        end)
        if ok and value ~= nil then
            return value
        end
    end
    local numeric = tonumber(id)
    return numeric ~= nil and numeric or id
end

local function _sort_numeric_id_list(id_list)
    table.sort(id_list, function(left, right)
        return left < right
    end)
    return id_list
end

local function _sort_link_record_list(record_list)
    table.sort(record_list, function(left, right)
        local left_id = left and left.link and _id_value(left.link.id) or 0
        local right_id = right and right.link and _id_value(right.link.id) or 0
        return left_id < right_id
    end)
    return record_list
end

local function _append_unique_link_record_list(target_list, source_list)
    if not target_list or not source_list then
        return target_list
    end

    local existing_link_id_set = {}
    for _, record in ipairs(target_list) do
        local link_id = record and record.link and _id_value(record.link.id) or nil
        if link_id ~= nil then
            existing_link_id_set[link_id] = true
        end
    end

    for _, record in ipairs(source_list) do
        local link_id = record and record.link and _id_value(record.link.id) or nil
        if link_id ~= nil and not existing_link_id_set[link_id] then
            existing_link_id_set[link_id] = true
            table.insert(target_list, record)
        end
    end

    return target_list
end

local _remove_link_records_by_pin_id
local _resolve_link_pins_from_pool

local function _mark_link_pool_dirty(self)
    if self then
        self._link_pool_dirty = true
    end
end

local function _bump_flow_revision(self, field)
    self[field] = (self[field] or 0) + 1
end

local function _mark_flow_graph_dirty(self)
    _bump_flow_revision(self, "_flow_graph_revision")
end

local function _mark_flow_view_dirty(self)
    _bump_flow_revision(self, "_flow_view_revision")
end

local function _mark_flow_style_dirty(self)
    _bump_flow_revision(self, "_flow_style_revision")
end

local function _invalidate_flow_view_cache(self)
    if self and self._flow_view_cache and imgui.FlowViewCache and imgui.FlowViewCache.Invalidate then
        imgui.FlowViewCache.Invalidate(self._flow_view_cache)
    end
    self._flow_cached_graph_revision = -1
    self._flow_cached_view_revision = -1
    self._flow_cached_style_revision = -1
    self._flow_cached_static_overlay_revision = -1
end

local function _wake_flow_live(self, frames)
    if not self then
        return
    end

    _invalidate_flow_view_cache(self)
    _mark_flow_view_dirty(self)
    self._flow_idle_stable_frames = 0
    self._flow_live_warmup_remaining = math.max(
        self._flow_live_warmup_remaining or 0,
        frames or flow_cache_live_warmup_frames)
end

local function _mark_flow_cache_captured(self)
    self._flow_cached_graph_revision = self._flow_graph_revision or 0
    self._flow_cached_view_revision = self._flow_view_revision or 0
    self._flow_cached_style_revision = self._flow_style_revision or 0
    self._flow_cached_static_overlay_revision = self._flow_static_overlay_revision or 0
    self._flow_last_captured_window_width = self._flow_last_window_width or 0
    self._flow_last_captured_window_height = self._flow_last_window_height or 0
end

local function _set_flow_signature(self, signature_field, revision_field, signature)
    if self[signature_field] ~= signature then
        self[signature_field] = signature
        _bump_flow_revision(self, revision_field)
        return true
    end
    return false
end

local function _round_signature_number(value, scale)
    scale = scale or 100
    return tostring(math.floor((tonumber(value) or 0) * scale + 0.5))
end

local function _clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function _clamp01(value)
    return _clamp(value, 0, 1)
end

local function _lerp(left, right, factor)
    local t = _clamp01(factor or 0)
    return left + (right - left) * t
end

local function _normalize_range(value, min_value, max_value)
    if max_value <= min_value then
        return value >= max_value and 1 or 0
    end
    return _clamp01((value - min_value) / (max_value - min_value))
end

local function _calc_ema(previous, sample, delta_ms, half_life_ms)
    if sample == nil then
        return previous or 0
    end
    if previous == nil or previous <= 0 then
        return sample
    end
    local dt = math.max(0.0, tonumber(delta_ms) or 0.0)
    local half_life = math.max(1.0, tonumber(half_life_ms) or flow_guard_ema_half_life_ms)
    local factor = 1.0 - math.exp(-math.log(2.0) * dt / half_life)
    return previous + (sample - previous) * _clamp01(factor)
end

local function _copy_vec2(value)
    if not value then
        return nil
    end

    return {x = value.x or 0, y = value.y or 0}
end

local function _to_imgui_vec2(value)
    if not value then
        return imgui.ImVec2(0, 0)
    end

    return imgui.ImVec2(value.x or 0, value.y or 0)
end

local function _new_flow_guard_state()
    return
    {
        state = "normal",
        editor_frame_ms_ema = 0,
        editor_fps_ema = 0,
        flow_live_total_ms_ema = 0,
        flow_live_submit_ms_ema = 0,
        flow_live_sample_age_ms = 0,
        flow_guard_over_budget_ms = 0,
        flow_guard_hard_over_budget_ms = 0,
        flow_guard_under_budget_ms = 0,
        flow_guard_node_total = 0,
        flow_guard_visible_nodes = 0,
        flow_guard_host_area = 0,
        flow_guard_locked_min_zoom = 0,
        flow_guard_target_visible = 0,
        flow_guard_severity = 0,
        observe_elapsed_ms = 0,
        visible_sample_elapsed_ms = flow_guard_visible_sample_interval_ms,
        cooldown_remaining_ms = 0,
        zoom_apply_delay_remaining_ms = 0,
        pending_view_rect = nil,
        pending_view_rect_force = false,
    }
end

local function _sync_flow_style_revision(self)
    local signature = table.concat(
    {
        _round_signature_number(SettingsManager.get("editor_zoom_ratio"), 1000),
        tostring(GlobalContext.font_imgui),
        tostring(GlobalContext.resource_index_revision or 0),
        tostring(GlobalContext.render_target_reset_revision or 0),
    }, "|")
    return _set_flow_signature(self, "_flow_style_signature", "_flow_style_revision", signature)
end

local function _sync_flow_static_overlay_revision(self)
    local show_all_active = GlobalContext.is_show_all_node_id.val == true
    return _set_flow_signature(
        self,
        "_flow_static_overlay_signature",
        "_flow_static_overlay_revision",
        show_all_active and "1" or "0")
end

local function _sync_flow_view_revision(self, runtime_state, window_size)
    local signature = table.concat(
    {
        _round_signature_number(window_size and window_size.x or 0, 10),
        _round_signature_number(window_size and window_size.y or 0, 10),
        _round_signature_number(runtime_state and runtime_state.view_origin_x or 0, 10),
        _round_signature_number(runtime_state and runtime_state.view_origin_y or 0, 10),
        _round_signature_number(runtime_state and runtime_state.view_scale or self._current_zoom or 1, 1000),
    }, "|")
    return _set_flow_signature(self, "_flow_view_signature", "_flow_view_revision", signature)
end

local function _sync_flow_render_target_reset(self)
    local current_revision = GlobalContext.render_target_reset_revision or 0
    if (self._flow_last_render_target_reset_revision or -1) ~= current_revision then
        self._flow_last_render_target_reset_revision = current_revision
        if self._flow_view_cache and imgui.FlowViewCache and imgui.FlowViewCache.ReleaseTarget then
            imgui.FlowViewCache.ReleaseTarget(self._flow_view_cache)
        end
        _invalidate_flow_view_cache(self)
        _mark_flow_style_dirty(self)
    end
end

local function _refresh_flow_pin_theme_color(self, flow_color)
    if not flow_color then
        return
    end

    for _, pin in pairs(self._pin_pool or {}) do
        if pin and pin._type_id == "flow" then
            pin._color = flow_color
        end
    end
end

local function _is_point_in_rect(point, rect_min, rect_size)
    if not point or not rect_min or not rect_size then
        return false
    end

    local ok, point_x, point_y, rect_x, rect_y, rect_w, rect_h = pcall(function()
        return point.x, point.y, rect_min.x, rect_min.y, rect_size.x, rect_size.y
    end)
    if not ok then
        return false
    end

    point_x, point_y = tonumber(point_x), tonumber(point_y)
    rect_x, rect_y = tonumber(rect_x), tonumber(rect_y)
    rect_w, rect_h = tonumber(rect_w), tonumber(rect_h)
    if not point_x or not point_y or not rect_x or not rect_y or not rect_w or not rect_h then
        return false
    end
    if point_x ~= point_x or point_y ~= point_y or rect_x ~= rect_x or rect_y ~= rect_y or rect_w ~= rect_w or rect_h ~= rect_h then
        return false
    end

    return point_x >= rect_x
        and point_y >= rect_y
        and point_x <= rect_x + rect_w
        and point_y <= rect_y + rect_h
end

local function _did_flow_mouse_move(self, mouse_pos)
    if not mouse_pos then
        return false
    end

    local last_x = self._flow_last_mouse_x
    local last_y = self._flow_last_mouse_y
    if last_x == nil or last_y == nil then
        return false
    end

    return math.abs(mouse_pos.x - last_x) > 0.1
        or math.abs(mouse_pos.y - last_y) > 0.1
end

local function _is_flow_pointer_active(self, mouse_in_host, mouse_pos)
    if GlobalContext.is_resource_modal_active then
        return false
    end

    if not mouse_in_host then
        return false
    end

    if rawget(self, "_flow_context_popup_hovered_last_frame") then
        return false
    end

    local io = imgui.GetIO()
    local wheel_active = io and (((io.MouseWheel or 0) ~= 0) or ((io.MouseWheelH or 0) ~= 0))
    local mouse_entered = mouse_in_host and not self._flow_last_mouse_in_host
    local mouse_moved = _did_flow_mouse_move(self, mouse_pos)
    local mouse_button_active =
        (imgui.IsMouseDown and (imgui.IsMouseDown(0) or imgui.IsMouseDown(1) or imgui.IsMouseDown(2)))
        or (imgui.IsMouseClicked and (imgui.IsMouseClicked(0, false) or imgui.IsMouseClicked(1, false) or imgui.IsMouseClicked(2, false)))
        or (imgui.IsMouseReleased and (imgui.IsMouseReleased(0) or imgui.IsMouseReleased(1) or imgui.IsMouseReleased(2)))

    return mouse_entered or mouse_moved or wheel_active or mouse_button_active
end

local function _get_pin_numeric_id(pin)
    if not pin or not pin._id then
        return nil
    end
    return _id_value(pin._id)
end

local function _link_matches_pin(link, pin_id, is_output)
    if not link then
        return false
    end

    local target_pin = is_output and link.output or link.input
    local target_pin_id = _get_pin_numeric_id(target_pin)
    if target_pin_id == nil then
        return false
    end

    return target_pin_id == _id_value(pin_id)
end

_resolve_link_pins_from_pool = function(self, link)
    if not link then
        return nil, nil
    end

    local pin_a = link.input
    local pin_b = link.output
    local pin_a_id = _get_pin_numeric_id(pin_a)
    local pin_b_id = _get_pin_numeric_id(pin_b)

    if pin_a_id ~= nil then
        pin_a = self._pin_pool[pin_a_id] or pin_a
    end
    if pin_b_id ~= nil then
        pin_b = self._pin_pool[pin_b_id] or pin_b
    end

    return _resolve_link_pins(pin_a, pin_b)
end

local function _normalize_link_in_place(self, link)
    local input_pin, output_pin = _resolve_link_pins_from_pool(self, link)
    if not input_pin or not output_pin then
        return nil, nil
    end

    link.input = input_pin
    link.output = output_pin
    return input_pin, output_pin
end

local function _refresh_pin_link_state(self, pin)
    if not pin then
        return
    end

    local numeric_pin_id = _get_pin_numeric_id(pin)
    local resolved_linked_pin_id = nil
    local resolved_link_id = nil
    for link_id, link in pairs(self._link_pool or {}) do
        local input_pin, output_pin = _normalize_link_in_place(self, link)
        if pin._is_output and output_pin and _get_pin_numeric_id(output_pin) == numeric_pin_id and input_pin then
            if resolved_link_id == nil or link_id > resolved_link_id then
                resolved_link_id = link_id
                resolved_linked_pin_id = input_pin._id
            end
        elseif (not pin._is_output) and input_pin and _get_pin_numeric_id(input_pin) == numeric_pin_id and output_pin then
            if resolved_link_id == nil or link_id > resolved_link_id then
                resolved_link_id = link_id
                resolved_linked_pin_id = output_pin._id
            end
        end
    end
    pin._linked_pin_id = resolved_linked_pin_id
end

local function _make_link_record(link)
    if not link then
        return nil
    end

    local input_pin, output_pin = _resolve_link_pins(link.input, link.output)
    if not input_pin or not output_pin then
        return nil
    end

    link.input = input_pin
    link.output = output_pin

    return
    {
        link = link,
        input_linked_pin_id = output_pin._id,
        output_linked_pin_id = input_pin._id,
    }
end

local function _clear_pin_link_id_if_matches(pin, linked_pin_id)
    if not pin or pin._linked_pin_id == nil or linked_pin_id == nil then
        return
    end

    if _id_value(pin._linked_pin_id) == _id_value(linked_pin_id) then
        pin._linked_pin_id = nil
    end
end

local function _clear_link_record_pin_state(self, record)
    if not record or not record.link then
        return
    end

    local input_pin, output_pin = _resolve_link_pins_from_pool(self, record.link)
    local input_linked_pin_id = record.input_linked_pin_id or (output_pin and output_pin._id or nil)
    local output_linked_pin_id = record.output_linked_pin_id or (input_pin and input_pin._id or nil)

    _clear_pin_link_id_if_matches(input_pin, input_linked_pin_id)
    _clear_pin_link_id_if_matches(output_pin, output_linked_pin_id)
end

local function _refresh_link_record_pin_state(self, record)
    if not record or not record.link then
        return
    end

    local input_pin, output_pin = _resolve_link_pins_from_pool(self, record.link)
    if input_pin then
        _refresh_pin_link_state(self, input_pin)
    end
    if output_pin then
        _refresh_pin_link_state(self, output_pin)
    end
end

local function _refresh_link_record_list_pin_state(self, record_list)
    for _, record in ipairs(record_list or {}) do
        _refresh_link_record_pin_state(self, record)
    end
end

local function _collect_link_record_affected_pin_ids(self, record, affected_pin_id_set)
    if not record or not record.link then
        return
    end

    local input_pin, output_pin = _resolve_link_pins_from_pool(self, record.link)
    local input_pin_id = _get_pin_numeric_id(input_pin)
    local output_pin_id = _get_pin_numeric_id(output_pin)
    if input_pin_id ~= nil then
        affected_pin_id_set[input_pin_id] = true
    end
    if output_pin_id ~= nil then
        affected_pin_id_set[output_pin_id] = true
    end
end

local function _restore_link_record_list_snapshot(self, record_list)
    local sorted_record_list = {}
    local affected_pin_id_set = {}
    for _, record in ipairs(record_list or {}) do
        if record and record.link then
            table.insert(sorted_record_list, record)
        end
    end
    _sort_link_record_list(sorted_record_list)
    for _, record in ipairs(sorted_record_list) do
        local link = record.link
        local input_pin, output_pin = _normalize_link_in_place(self, link)
        if input_pin and output_pin then
            self._link_pool[link.id:get()] = link
            input_pin._linked_pin_id = record.input_linked_pin_id or output_pin._id
            output_pin._linked_pin_id = record.output_linked_pin_id or input_pin._id
            _collect_link_record_affected_pin_ids(self, record, affected_pin_id_set)
            _mark_link_pool_dirty(self)
        end
    end
    for pin_id in pairs(affected_pin_id_set) do
        _refresh_pin_link_state(self, self._pin_pool[pin_id])
    end
    if next(affected_pin_id_set) ~= nil then
        _mark_flow_graph_dirty(self)
    end
end
local function _remove_link_record_list_snapshot(self, record_list)
    local sorted_record_list = {}
    local affected_pin_id_set = {}
    for _, record in ipairs(record_list or {}) do
        if record and record.link then
            table.insert(sorted_record_list, record)
        end
    end
    _sort_link_record_list(sorted_record_list)
    for _, record in ipairs(sorted_record_list) do
        local link = record.link
        _normalize_link_in_place(self, link)
        self._link_pool[link.id:get()] = nil
        _clear_link_record_pin_state(self, record)
        _collect_link_record_affected_pin_ids(self, record, affected_pin_id_set)
        _mark_link_pool_dirty(self)
    end
    for pin_id in pairs(affected_pin_id_set) do
        _refresh_pin_link_state(self, self._pin_pool[pin_id])
    end
    if next(affected_pin_id_set) ~= nil then
        _mark_flow_graph_dirty(self)
    end
end
local function _attach_node_to_pool(self, node)
    if not node then
        return
    end

    self._node_pool[node._id:get()] = node
    for _, pin in ipairs(node._input_pin_list) do
        pin._owner_blueprint = self
        self._pin_pool[pin._id:get()] = pin
    end
    for _, pin in ipairs(node._output_pin_list) do
        pin._owner_blueprint = self
        self._pin_pool[pin._id:get()] = pin
    end
    self:_with_node_editor_binding(function()
        imgui.NodeEditor.SetNodePosition(node._id, imgui.ImVec2(node._position.x, node._position.y))
    end)
    _mark_flow_graph_dirty(self)
end

local function _detach_node_from_pool(self, node)
    if not node then
        return
    end

    for _, pin in ipairs(node._input_pin_list) do
        if pin._owner_blueprint == self then
            pin._owner_blueprint = nil
        end
        self._pin_pool[pin._id:get()] = nil
    end
    for _, pin in ipairs(node._output_pin_list) do
        if pin._owner_blueprint == self then
            pin._owner_blueprint = nil
        end
        self._pin_pool[pin._id:get()] = nil
    end
    self._node_pool[node._id:get()] = nil
    _mark_flow_graph_dirty(self)
end

local function _restore_link_record(self, record, options)
    if not record or not record.link then
        return
    end

    options = options or {}

    local link = record.link
    local input_pin, output_pin = _normalize_link_in_place(self, link)
    if not input_pin or not output_pin then
        return
    end
    if link.input then
        local removed_record_list = _remove_link_records_by_pin_id(self, link.input._id, false, _id_value(link.id))
        _append_unique_link_record_list(options.capture_removed_record_list, removed_record_list)
    end
    if link.output then
        local removed_record_list = _remove_link_records_by_pin_id(self, link.output._id, true, _id_value(link.id))
        _append_unique_link_record_list(options.capture_removed_record_list, removed_record_list)
    end
    self._link_pool[link.id:get()] = link
    if link.input then
        _refresh_pin_link_state(self, link.input)
    end
    if link.output then
        _refresh_pin_link_state(self, link.output)
    end
    _mark_link_pool_dirty(self)
    _mark_flow_graph_dirty(self)
end

local function _remove_link_record(self, record)
    if not record or not record.link then
        return
    end

    local link = record.link
    _normalize_link_in_place(self, link)
    self._link_pool[link.id:get()] = nil
    _clear_link_record_pin_state(self, record)
    if link.input then
        _refresh_pin_link_state(self, link.input)
    end
    if link.output then
        _refresh_pin_link_state(self, link.output)
    end
    _mark_link_pool_dirty(self)
    _mark_flow_graph_dirty(self)
end

local function _remove_link_by_link_id(self, id)
    local numeric_id = _id_value(id)
    local link = self._link_pool[numeric_id]
    if not link then
        return nil
    end

    local record = _make_link_record(link)
    _remove_link_record(self, record)
    return record
end

local function _remove_link_by_pin_id(self, pin_id, is_output)
    local numeric_pin_id = _id_value(pin_id)
    local pin = self._pin_pool[numeric_pin_id]
    if not pin then
        return nil
    end

    for id, link in pairs(self._link_pool) do
        local input_pin, output_pin = _normalize_link_in_place(self, link)
        if input_pin and output_pin and _link_matches_pin(link, numeric_pin_id, is_output) then
            return _remove_link_by_link_id(self, id)
        end
    end
    return nil
end

_remove_link_records_by_pin_id = function(self, pin_id, is_output, exclude_link_id)
    local numeric_pin_id = _id_value(pin_id)
    local pin = self._pin_pool[numeric_pin_id]
    if not pin then
        return {}
    end

    local removed_record_list = {}
    local matched_link_id_list = {}
    local excluded_link_id = exclude_link_id and _id_value(exclude_link_id) or nil

    for id, link in pairs(self._link_pool) do
        local input_pin, output_pin = _normalize_link_in_place(self, link)
        if input_pin and output_pin
            and _link_matches_pin(link, numeric_pin_id, is_output)
            and (excluded_link_id == nil or id ~= excluded_link_id) then
            table.insert(matched_link_id_list, id)
        end
    end

    _sort_numeric_id_list(matched_link_id_list)
    for _, link_id in ipairs(matched_link_id_list) do
        local removed_record = _remove_link_by_link_id(self, link_id)
        if removed_record then
            table.insert(removed_record_list, removed_record)
        end
    end

    return removed_record_list
end

local function _sanitize_link_pool(self, force)
    if not self then
        return false
    end
    if not force and not self._link_pool_dirty then
        return false
    end
    self._link_pool_dirty = false
    local normalized_link_id_list = {}
    local latest_link_id_by_input_pin = {}
    local latest_link_id_by_output_pin = {}
    local removed_link_id_set = {}
    local affected_pin_id_set = {}
    for link_id, link in pairs(self._link_pool or {}) do
        local input_pin, output_pin = _normalize_link_in_place(self, link)
        if input_pin and output_pin and _can_link(input_pin, output_pin) then
            table.insert(normalized_link_id_list, link_id)
            local input_pin_id = _get_pin_numeric_id(input_pin)
            local output_pin_id = _get_pin_numeric_id(output_pin)
            if input_pin_id ~= nil then
                latest_link_id_by_input_pin[input_pin_id] = math.max(link_id, latest_link_id_by_input_pin[input_pin_id] or link_id)
                affected_pin_id_set[input_pin_id] = true
            end
            if output_pin_id ~= nil then
                latest_link_id_by_output_pin[output_pin_id] = math.max(link_id, latest_link_id_by_output_pin[output_pin_id] or link_id)
                affected_pin_id_set[output_pin_id] = true
            end
        else
            removed_link_id_set[link_id] = true
        end
    end
    for _, link_id in ipairs(normalized_link_id_list) do
        local link = self._link_pool[link_id]
        if link then
            local input_pin_id = _get_pin_numeric_id(link.input)
            local output_pin_id = _get_pin_numeric_id(link.output)
            local keep_current_link =
                input_pin_id ~= nil
                and output_pin_id ~= nil
                and latest_link_id_by_input_pin[input_pin_id] == link_id
                and latest_link_id_by_output_pin[output_pin_id] == link_id
            if not keep_current_link then
                removed_link_id_set[link_id] = true
            end
        end
    end
    local removed_link_id_list = {}
    for link_id in pairs(removed_link_id_set) do
        table.insert(removed_link_id_list, link_id)
    end
    if #removed_link_id_list == 0 then
        return false
    end
    _sort_numeric_id_list(removed_link_id_list)
    for _, link_id in ipairs(removed_link_id_list) do
        local link = self._link_pool[link_id]
        if link then
            local removed_record = _make_link_record(link)
            local input_pin_id = _get_pin_numeric_id(link.input)
            local output_pin_id = _get_pin_numeric_id(link.output)
            if input_pin_id ~= nil then
                affected_pin_id_set[input_pin_id] = true
            end
            if output_pin_id ~= nil then
                affected_pin_id_set[output_pin_id] = true
            end
            self._link_pool[link_id] = nil
            _clear_link_record_pin_state(self, removed_record)
        end
    end
    for pin_id in pairs(affected_pin_id_set) do
        _refresh_pin_link_state(self, self._pin_pool[pin_id])
    end
    _mark_flow_graph_dirty(self)
    return true
end
local function _create_node_by_def(self, def, position)
    local node = NodeFactory.create({blueprint = self, type_id = def.type_id})
    local node_position = _to_imgui_vec2(position)
    node._position.x, node._position.y = node_position.x, node_position.y
    self:spawn_node(node, true)
    return node
end

-- 节点创建菜单项
local function _menu_item_create_node(self, def, position)
    local height <const> = imgui.GetTextLineHeight()
    local size_icon <const> = imgui.ImVec2(height, height)
    imgui.Image(ResourcesManager.find_icon(def.icon_id), size_icon, nil, nil, def.color, nil)
    imgui.SameLine()
    if imgui.MenuItem(def.name) then
        _create_node_by_def(self, def, position)
    end
end

-- 生成下一个uid，类型为Number
function Blueprint:gen_next_uid()
    self._max_uid = self._max_uid + 1
    return self._max_uid
end

-- 向流程中添加指定node对象
-- 注意：所有的pool中的键均为Number类型的id
function Blueprint:spawn_node(node, can_undo)
    local function _spawn()
        _attach_node_to_pool(self, node)
    end
    _spawn()
    if can_undo then
        UndoManager.record(function()
            _detach_node_from_pool(self, node)
        end, _spawn)
    end
end

-- 加载连接
local function load_link(blueprint, data)
    local link =
    {
        id = imgui.NodeEditor.LinkId(data.id),
        input = blueprint._pin_pool[data.input_pin_id],
        output = blueprint._pin_pool[data.output_pin_id],
    }
    return _make_link_record(link) and link or nil
end

-- 保存连接
local function save_link(link)
    -- SAVE TRACE: link_data collected under dump_data.link_pool[link_id].
    -- Fields: link id plus the two endpoint pin ids.
    return 
    {
        id = link.id:get(),
        input_pin_id = link.input._id:get(),
        output_pin_id = link.output._id:get(),
    }
end

local function _restore_graph_snapshot(self, snapshot)
    if not snapshot then
        return
    end

    for _, node_record in ipairs(snapshot.node_records or {}) do
        _attach_node_to_pool(self, node_record.node)
    end
    for _, link_record in ipairs(snapshot.link_records or {}) do
        _restore_link_record(self, link_record)
    end
end

local function _apply_delete_snapshot(self, snapshot)
    if not snapshot then
        return
    end

    for _, link_record in ipairs(snapshot.link_records or {}) do
        _remove_link_record(self, link_record)
    end
    for _, node_record in ipairs(snapshot.node_records or {}) do
        _detach_node_from_pool(self, node_record.node)
    end
end

local function _build_delete_snapshot(self, node_id_list, link_id_list)
    local node_id_set = {}
    local link_id_set = {}

    for _, node_id in ipairs(node_id_list or {}) do
        local numeric_id = _id_value(node_id)
        local node = self._node_pool[numeric_id]
        if node and node._type_id ~= "entry" then
            node_id_set[numeric_id] = true
        end
    end

    for _, link_id in ipairs(link_id_list or {}) do
        local numeric_id = _id_value(link_id)
        if self._link_pool[numeric_id] then
            link_id_set[numeric_id] = true
        end
    end

    if next(node_id_set) then
        for link_id, link in pairs(self._link_pool) do
            local input_owner_id = link.input and link.input._owner_id and link.input._owner_id:get() or nil
            local output_owner_id = link.output and link.output._owner_id and link.output._owner_id:get() or nil
            if node_id_set[input_owner_id] or node_id_set[output_owner_id] then
                link_id_set[link_id] = true
            end
        end
    end

    local sorted_node_ids = {}
    for node_id in pairs(node_id_set) do
        table.insert(sorted_node_ids, node_id)
    end
    _sort_numeric_id_list(sorted_node_ids)

    local sorted_link_ids = {}
    for link_id in pairs(link_id_set) do
        table.insert(sorted_link_ids, link_id)
    end
    _sort_numeric_id_list(sorted_link_ids)

    if #sorted_node_ids == 0 and #sorted_link_ids == 0 then
        return nil
    end

    local snapshot =
    {
        node_records = {},
        link_records = {},
        node_id_list = sorted_node_ids,
        link_id_list = sorted_link_ids,
    }

    for _, link_id in ipairs(sorted_link_ids) do
        local link = self._link_pool[link_id]
        if link then
            table.insert(snapshot.link_records, _make_link_record(link))
        end
    end

    for _, node_id in ipairs(sorted_node_ids) do
        local node = self._node_pool[node_id]
        if node then
            table.insert(snapshot.node_records, {node = node})
        end
    end

    return snapshot
end

local function _get_selected_node_id_list(self)
    local result = {}
    for _, node_id in ipairs(imgui.NodeEditor.GetSelectedNodes() or {}) do
        if type(node_id) == "number" and self._node_pool[node_id] then
            table.insert(result, node_id)
        end
    end
    return _sort_numeric_id_list(result)
end

local function _get_selected_link_id_list(self)
    local result = {}
    for _, link_id in ipairs(imgui.NodeEditor.GetSelectedLinks() or {}) do
        if type(link_id) == "number" and self._link_pool[link_id] then
            table.insert(result, link_id)
        end
    end
    return _sort_numeric_id_list(result)
end

local function _get_all_node_id_list(self)
    local result = {}
    for node_id in pairs(self._node_pool or {}) do
        table.insert(result, node_id)
    end
    return _sort_numeric_id_list(result)
end

local function _set_selected_node_list(self, node_id_list)
    self:_with_node_editor_binding(function()
        imgui.NodeEditor.ClearSelection()
        for _, node_id in ipairs(node_id_list or {}) do
            if self._node_pool[node_id] then
                imgui.NodeEditor.SelectNode(imgui.NodeEditor.NodeId(node_id), true)
            end
        end
    end)
    _mark_flow_graph_dirty(self)
end

local function _clone_position(position)
    return {x = position.x, y = position.y}
end

local function _set_node_position(node, position)
    if not node or not position then
        return
    end

    node._position.x = position.x
    node._position.y = position.y
    local blueprint = node._blueprint
    if blueprint then
        blueprint:_with_node_editor_binding(function()
            imgui.NodeEditor.SetNodePosition(node._id, imgui.ImVec2(position.x, position.y))
        end)
        _mark_flow_graph_dirty(blueprint)
    end
end

local function _resolve_clipboard_bounds(snapshot)
    local bounds = snapshot and snapshot.bounds or nil
    if bounds and type(bounds.min_x) == "number" and type(bounds.min_y) == "number"
        and type(bounds.max_x) == "number" and type(bounds.max_y) == "number" then
        return bounds
    end

    local min_x, min_y = 0, 0
    local max_x, max_y = 0, 0
    local initialized = false
    for _, node_data in ipairs(snapshot and snapshot.node_list or {}) do
        local position = node_data.position or {}
        local x = tonumber(position.x) or 0
        local y = tonumber(position.y) or 0
        if not initialized then
            min_x, min_y = x, y
            max_x, max_y = x, y
            initialized = true
        else
            min_x = math.min(min_x, x)
            min_y = math.min(min_y, y)
            max_x = math.max(max_x, x)
            max_y = math.max(max_y, y)
        end
    end

    return {min_x = min_x, min_y = min_y, max_x = max_x, max_y = max_y}
end

local function _build_clipboard_snapshot(self, node_id_list)
    local selected_node_set = {}
    local snapshot =
    {
        kind = blueprint_clipboard_kind,
        version = blueprint_clipboard_version,
        source_blueprint_guid = self._resource_guid,
        source_blueprint_name = self._display_name or self._id,
        bounds = nil,
        node_list = {},
        link_list = {},
    }

    local min_x, min_y = 0, 0
    local max_x, max_y = 0, 0
    local initialized = false

    for _, node_id in ipairs(node_id_list or {}) do
        local node = self._node_pool[node_id]
        if node and node._type_id ~= "entry" then
            selected_node_set[node_id] = true
            local node_data = node:on_save()
            table.insert(snapshot.node_list, node_data)

            local position = node_data.position or {}
            local x = tonumber(position.x) or 0
            local y = tonumber(position.y) or 0
            if not initialized then
                min_x, min_y = x, y
                max_x, max_y = x, y
                initialized = true
            else
                min_x = math.min(min_x, x)
                min_y = math.min(min_y, y)
                max_x = math.max(max_x, x)
                max_y = math.max(max_y, y)
            end
        end
    end

    if #snapshot.node_list == 0 then
        return nil
    end

    _sort_numeric_id_list(node_id_list)
    table.sort(snapshot.node_list, function(left, right)
        return (left.id or 0) < (right.id or 0)
    end)

    for _, link in pairs(self._link_pool) do
        local input_owner_id = link.input and link.input._owner_id and link.input._owner_id:get() or nil
        local output_owner_id = link.output and link.output._owner_id and link.output._owner_id:get() or nil
        if selected_node_set[input_owner_id] and selected_node_set[output_owner_id] then
            table.insert(snapshot.link_list, save_link(link))
        end
    end

    table.sort(snapshot.link_list, function(left, right)
        return (left.id or 0) < (right.id or 0)
    end)

    snapshot.bounds =
    {
        min_x = min_x,
        min_y = min_y,
        max_x = max_x,
        max_y = max_y,
    }
    return snapshot
end

local function _validate_clipboard_snapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, "流程图剪贴板为空"
    end
    if snapshot.kind ~= blueprint_clipboard_kind then
        return false, "剪贴板负载类型不匹配"
    end
    if snapshot.version ~= blueprint_clipboard_version then
        return false, string.format("剪贴板版本不匹配：%s", tostring(snapshot.version))
    end
    if type(snapshot.node_list) ~= "table" or type(snapshot.link_list) ~= "table" then
        return false, "剪贴板负载结构不完整"
    end

    local pin_id_set = {}
    for _, node_data in ipairs(snapshot.node_list) do
        if type(node_data) ~= "table" or type(node_data.type_id) ~= "string" or not NodeRegistry.has(node_data.type_id) then
            return false, string.format("剪贴板中的节点类型不存在：%s", tostring(node_data and node_data.type_id))
        end

        for _, pin_data in ipairs(node_data.input_pin_list or {}) do
            if type(pin_data) ~= "table" or type(pin_data.type_id) ~= "string" or not PinRegistry.has(pin_data.type_id) then
                return false, string.format("剪贴板中的输入引脚类型不存在：%s", tostring(pin_data and pin_data.type_id))
            end
            pin_id_set[pin_data.id] = true
        end
        for _, pin_data in ipairs(node_data.output_pin_list or {}) do
            if type(pin_data) ~= "table" or type(pin_data.type_id) ~= "string" or not PinRegistry.has(pin_data.type_id) then
                return false, string.format("剪贴板中的输出引脚类型不存在：%s", tostring(pin_data and pin_data.type_id))
            end
            pin_id_set[pin_data.id] = true
        end
    end

    for _, link_data in ipairs(snapshot.link_list) do
        if type(link_data) ~= "table"
            or not pin_id_set[link_data.input_pin_id]
            or not pin_id_set[link_data.output_pin_id] then
            return false, "剪贴板中的连线端点无效"
        end
    end

    return true
end

local function _build_paste_graph_snapshot(self, clipboard_snapshot, anchor_pos)
    local snapshot =
    {
        node_records = {},
        link_records = {},
        node_id_list = {},
        link_id_list = {},
    }

    local success, result = pcall(function()
        local node_data_list = TableUtil.deep_copy(clipboard_snapshot.node_list or {})
        local link_data_list = TableUtil.deep_copy(clipboard_snapshot.link_list or {})
        local bounds = _resolve_clipboard_bounds(clipboard_snapshot)
        local pin_id_map = {}

        table.sort(node_data_list, function(left, right)
            return (left.id or 0) < (right.id or 0)
        end)
        table.sort(link_data_list, function(left, right)
            return (left.id or 0) < (right.id or 0)
        end)

        for _, node_data in ipairs(node_data_list) do
            local position = node_data.position or {x = 0, y = 0}
            local offset_x = (tonumber(position.x) or 0) - bounds.min_x
            local offset_y = (tonumber(position.y) or 0) - bounds.min_y
            node_data.id = self:gen_next_uid()
            node_data.position =
            {
                x = math.floor(anchor_pos.x + offset_x),
                y = math.floor(anchor_pos.y + offset_y),
            }

            for _, pin_data in ipairs(node_data.input_pin_list or {}) do
                local old_pin_id = pin_data.id
                pin_data.id = self:gen_next_uid()
                pin_id_map[old_pin_id] = pin_data.id
            end
            for _, pin_data in ipairs(node_data.output_pin_list or {}) do
                local old_pin_id = pin_data.id
                pin_data.id = self:gen_next_uid()
                pin_id_map[old_pin_id] = pin_data.id
            end

            local node = NodeFactory.create({blueprint = self, type_id = node_data.type_id, data = node_data})
            _attach_node_to_pool(self, node)
            table.insert(snapshot.node_records, {node = node})
            table.insert(snapshot.node_id_list, node._id:get())
        end

        for _, link_data in ipairs(link_data_list) do
            link_data.id = self:gen_next_uid()
            link_data.input_pin_id = pin_id_map[link_data.input_pin_id]
            link_data.output_pin_id = pin_id_map[link_data.output_pin_id]
            if not link_data.input_pin_id or not link_data.output_pin_id then
                error("剪贴板中的连线端点映射失败")
            end

            local link = load_link(self, link_data)
            local record = _make_link_record(link)
            _restore_link_record(self, record)
            table.insert(snapshot.link_records, record)
            table.insert(snapshot.link_id_list, link.id:get())
        end

        return snapshot
    end)

    if success then
        return result
    end

    _apply_delete_snapshot(self, snapshot)
    return nil, result
end

local function _resolve_paste_anchor(self, canvas_mouse_pos, revision)
    local rounded_x = math.floor((canvas_mouse_pos.x or 0) + 0.5)
    local rounded_y = math.floor((canvas_mouse_pos.y or 0) + 0.5)
    local same_source = self._last_paste_revision == revision
        and self._last_paste_cursor_x == rounded_x
        and self._last_paste_cursor_y == rounded_y

    if same_source then
        self._last_paste_repeat_count = self._last_paste_repeat_count + 1
    else
        self._last_paste_repeat_count = 0
    end

    self._last_paste_revision = revision
    self._last_paste_cursor_x = rounded_x
    self._last_paste_cursor_y = rounded_y

    return
    {
        x = canvas_mouse_pos.x + self._last_paste_repeat_count * paste_offset_x,
        y = canvas_mouse_pos.y + self._last_paste_repeat_count * paste_offset_y,
    }
end

local function _has_active_input_widget()
    return imgui.IsAnyItemActive() or imgui.IsAnyItemFocused()
end

function Blueprint:_has_pin_widget_activity(mouse_pos)
    for _, pin in pairs(self._pin_pool or {}) do
        local rect_min = pin and pin._widget_rect_min
        local rect_max = pin and pin._widget_rect_max
        local mouse_in_widget = mouse_pos and rect_min and rect_max
            and mouse_pos.x >= rect_min.x
            and mouse_pos.y >= rect_min.y
            and mouse_pos.x <= rect_max.x
            and mouse_pos.y <= rect_max.y
        if pin
            and (pin._widget_hovered == true
                or pin._widget_active == true
                or pin._widget_focused == true
                or pin._widget_clicked == true
                or pin._widget_interacting == true
                or mouse_in_widget == true) then
            return true
        end
    end
    return false
end

local function _can_handle_shortcuts(self)
    return not GlobalContext.is_debug_game
        and not GlobalContext.is_resource_modal_active
        and GlobalContext.is_flow_designer_window_focused
        and not _has_active_input_widget()
end

local function _has_flow_popup_open(self)
    return type(ResourceReferenceField.has_open_popup) == "function" and ResourceReferenceField.has_open_popup()
end

local function _queue_flow_popup(self, popup_id, mouse_pos)
    self._queued_flow_popup_id = popup_id
    self._queued_flow_popup_screen_pos = _copy_vec2(mouse_pos)
    self._flow_context_popup_keepalive_id = popup_id
    self._flow_context_popup_keepalive_frames = flow_context_popup_close_grace_frames

    if popup_id == "CreateNewNode" and mouse_pos and type(imgui.NodeEditor.ScreenToCanvas) == "function" then
        self._flow_create_popup_screen_pos = _copy_vec2(mouse_pos)
        self._flow_create_popup_canvas_pos = _copy_vec2(imgui.NodeEditor.ScreenToCanvas(mouse_pos))
    elseif popup_id ~= "CreateNewNode" then
        self._flow_create_popup_screen_pos = nil
        self._flow_create_popup_canvas_pos = nil
    end
end

local function _apply_create_node_popup_layout(self, queued_popup_screen_pos)
    local zoom_ratio = SettingsManager.get("editor_zoom_ratio")
    local margin = math.max(6, math.floor(8 * zoom_ratio + 0.5))
    local min_height = math.max(120, math.floor(160 * zoom_ratio + 0.5))
    local max_height = math.max(min_height, math.floor(520 * zoom_ratio + 0.5))
    local popup_pos = queued_popup_screen_pos or rawget(self, "_flow_create_popup_screen_pos")
    local popup_pivot = imgui.ImVec2(0, 0)
    local viewport = type(imgui.GetMainViewport) == "function" and imgui.GetMainViewport() or nil

    if viewport and viewport.WorkPos and viewport.WorkSize then
        local work_left = viewport.WorkPos.x
        local work_top = viewport.WorkPos.y
        local work_right = work_left + viewport.WorkSize.x
        local work_bottom = work_top + viewport.WorkSize.y
        local viewport_height = math.max(80, viewport.WorkSize.y - margin * 2)
        min_height = math.min(min_height, viewport_height)
        max_height = math.min(viewport_height, math.max(min_height, max_height))

        if popup_pos then
            local x = math.max(work_left + margin, math.min(popup_pos.x, work_right - margin))
            local y = math.max(work_top + margin, math.min(popup_pos.y, work_bottom - margin))
            local available_below = math.max(0, work_bottom - y - margin)
            local available_above = math.max(0, y - work_top - margin)

            if available_below < min_height and available_above > available_below then
                max_height = math.min(max_height, math.max(min_height, available_above))
                popup_pivot = imgui.ImVec2(0, 1)
            else
                max_height = math.min(max_height, math.max(min_height, available_below))
            end
            popup_pos = imgui.ImVec2(x, y)
        end
    end

    imgui.SetNextWindowSizeConstraints(imgui.ImVec2(0, 0), imgui.ImVec2(10000, max_height))
    if popup_pos then
        imgui.SetNextWindowPos(popup_pos, imgui.ImGuiCond.Always, popup_pivot)
    end
end

local function _draw_flow_context_popups(self)
    local queued_popup_id = rawget(self, "_queued_flow_popup_id")
    local queued_popup_screen_pos = rawget(self, "_queued_flow_popup_screen_pos")
    local keepalive_popup_id = rawget(self, "_flow_context_popup_keepalive_id")
    local keepalive_frames = rawget(self, "_flow_context_popup_keepalive_frames") or 0
    local active_popup_id = nil
    local popup_hovered = false

    self._queued_flow_popup_id = nil
    self._queued_flow_popup_screen_pos = nil

    imgui.PushFont(GlobalContext.font_imgui, math.floor(18 * SettingsManager.get("editor_zoom_ratio")))
        if queued_popup_id then
            imgui.OpenPopup(queued_popup_id)
            keepalive_popup_id = queued_popup_id
            self._flow_context_popup_keepalive_id = queued_popup_id
            keepalive_frames = flow_context_popup_close_grace_frames
        end
        if rawget(self, "_id_menu") then
            if queued_popup_id == self._id_menu and queued_popup_screen_pos then
                imgui.SetNextWindowPos(imgui.ImVec2(queued_popup_screen_pos.x, queued_popup_screen_pos.y), imgui.ImGuiCond.Always)
            end
            if imgui.BeginPopup(self._id_menu) then
                active_popup_id = self._id_menu
                keepalive_popup_id = self._id_menu
                self._flow_context_popup_keepalive_id = self._id_menu
                keepalive_frames = flow_context_popup_close_grace_frames
                popup_hovered = popup_hovered or imgui.IsWindowHovered()
                if self._node_menu and self._node_menu.on_show_menu then
                    self._node_menu:on_show_menu()
                else
                    imgui.CloseCurrentPopup()
                end
                imgui.EndPopup()
            end
        end

        _apply_create_node_popup_layout(self, queued_popup_screen_pos)
        local create_node_popup_style = nil
        local imgui_helper = package.loaded["application.framework.imgui_helper"] or require("application.framework.imgui_helper")
        if imgui_helper.ShouldUseInHThemeCompensation() then
            create_node_popup_style = imgui_helper.PushCompactPopupStyle(SettingsManager.get("editor_zoom_ratio"))
        end
        if imgui.BeginPopup("CreateNewNode") then
            active_popup_id = "CreateNewNode"
            keepalive_popup_id = "CreateNewNode"
            self._flow_context_popup_keepalive_id = "CreateNewNode"
            keepalive_frames = flow_context_popup_close_grace_frames
            popup_hovered = popup_hovered or imgui.IsWindowHovered()
            local flags_span = imgui.TreeNodeFlags.SpanFullWidth
            local popup_canvas_pos = rawget(self, "_flow_create_popup_canvas_pos") or {x = 0, y = 0}
            for _, category in ipairs(NodeRegistry.get_menu_tree()) do
                local flags = flags_span
                if category.default_open then
                    flags = flags | imgui.TreeNodeFlags.DefaultOpen
                end
                if type(imgui.SetNextItemOpen) == "function" then
                    imgui.SetNextItemOpen(category.default_open == true, imgui.ImGuiCond.Appearing)
                end
                local category_tree_id = string.format("%s##CreateNewNodeCategory_%s", category.name, category.name)
                if imgui.TreeNode(category_tree_id, flags) then
                    for _, def in ipairs(category.node_list) do
                        self:_menu_item_create_node(def, popup_canvas_pos)
                    end
                    imgui.TreePop()
                end
            end
            imgui.EndPopup()
        end
        if create_node_popup_style then
            imgui_helper.PopCompactPopupStyle(create_node_popup_style)
        end
    imgui.PopFont()

    local popup_open = active_popup_id ~= nil
    if not popup_open and keepalive_popup_id and type(imgui.IsPopupOpen) == "function" then
        popup_open = imgui.IsPopupOpen(keepalive_popup_id)
    end

    if popup_open then
        keepalive_frames = flow_context_popup_close_grace_frames
    elseif keepalive_popup_id or keepalive_frames > 0 then
        keepalive_frames = math.max(0, keepalive_frames - 1)
    end

    self._flow_context_popup_keepalive_frames = keepalive_frames

    self._flow_context_popup_open_last_frame = popup_open
    self._flow_context_popup_hovered_last_frame = popup_open and popup_hovered

    if not popup_open and keepalive_frames <= 0 then
        self._flow_context_popup_keepalive_id = nil
        self._flow_create_popup_screen_pos = nil
        self._flow_create_popup_canvas_pos = nil
    end
end

local function _draw_flow_debug_mask(host_pos, host_size)
    if not host_pos or not host_size or host_size.x <= 0 or host_size.y <= 0 then
        return
    end

    local draw_list = imgui.GetWindowDrawList()
    if not draw_list then
        return
    end

    draw_list:AddRectFilled(
        _to_imgui_vec2(host_pos),
        imgui.ImVec2(host_pos.x + host_size.x, host_pos.y + host_size.y),
        imgui.ImColor(0, 0, 0, 150):to_u32())
end

local function _is_flow_shortcut_pending(self)
    if not _can_handle_shortcuts(self) then
        return false
    end

    local io = imgui.GetIO()
    local ctrl = io and io.KeyCtrl
    if ctrl then
        local block_navigate_to_content = _flow_guard_is_protecting(self)
        return imgui.IsKeyPressed(imgui.ImGuiKey.A, false)
            or imgui.IsKeyPressed(imgui.ImGuiKey.C, false)
            or imgui.IsKeyPressed(imgui.ImGuiKey.X, false)
            or imgui.IsKeyPressed(imgui.ImGuiKey.V, false)
            or imgui.IsKeyPressed(imgui.ImGuiKey.Z, false)
            or imgui.IsKeyPressed(imgui.ImGuiKey.Y, false)
            or (not block_navigate_to_content and imgui.IsKeyPressed(imgui.ImGuiKey.R, false))
            or imgui.IsKeyPressed(imgui.ImGuiKey.S, false)
    end

    return imgui.IsKeyPressed(imgui.ImGuiKey.Delete, false)
end

local function _is_flow_cache_dirty(self)
    if not self._flow_view_cache or not imgui.FlowViewCache or not imgui.FlowViewCache.IsValid then
        return true
    end
    if not imgui.FlowViewCache.IsValid(self._flow_view_cache) then
        return true
    end

    local expected_width = math.floor((self._flow_last_window_width or 0) + 0.5)
    local expected_height = math.floor((self._flow_last_window_height or 0) + 0.5)
    local captured_width = math.floor((self._flow_last_captured_window_width or -1) + 0.5)
    local captured_height = math.floor((self._flow_last_captured_window_height or -1) + 0.5)
    if expected_width ~= captured_width or expected_height ~= captured_height then
        return true
    end

    return (self._flow_cached_graph_revision or -1) ~= (self._flow_graph_revision or 0)
        or (self._flow_cached_view_revision or -1) ~= (self._flow_view_revision or 0)
        or (self._flow_cached_style_revision or -1) ~= (self._flow_style_revision or 0)
        or (self._flow_cached_static_overlay_revision or -1) ~= (self._flow_static_overlay_revision or 0)
end

local function _has_pending_initial_flow_navigation(self)
    return (self._navigate_counter or 0) < 3
end

local function _flow_guard_reset(self, next_state)
    local guard = self._flow_guard or _new_flow_guard_state()
    guard.state = next_state or "normal"
    guard.flow_guard_over_budget_ms = 0
    guard.flow_guard_hard_over_budget_ms = 0
    guard.flow_guard_under_budget_ms = 0
    guard.flow_guard_locked_min_zoom = 0
    guard.flow_guard_target_visible = 0
    guard.flow_guard_severity = 0
    guard.observe_elapsed_ms = 0
    guard.cooldown_remaining_ms = 0
    guard.zoom_apply_delay_remaining_ms = 0
    guard.pending_view_rect = nil
    guard.pending_view_rect_force = false
    self._flow_guard = guard
    return guard
end

local function _flow_guard_enter_observe(self)
    local guard = self._flow_guard or _new_flow_guard_state()
    guard.state = "observe"
    guard.flow_guard_under_budget_ms = 0
    guard.observe_elapsed_ms = 0
    guard.cooldown_remaining_ms = 0
    self._flow_guard = guard
    return guard
end

local function _flow_guard_enter_cooldown(self)
    local guard = self._flow_guard or _new_flow_guard_state()
    guard.state = "cooldown"
    guard.flow_guard_locked_min_zoom = 0
    guard.pending_view_rect = nil
    guard.pending_view_rect_force = false
    guard.zoom_apply_delay_remaining_ms = 0
    guard.flow_guard_over_budget_ms = 0
    guard.flow_guard_hard_over_budget_ms = 0
    guard.flow_guard_under_budget_ms = 0
    guard.observe_elapsed_ms = 0
    guard.cooldown_remaining_ms = flow_guard_cooldown_duration_ms
    self._flow_guard = guard
    return guard
end

local function _flow_guard_block_sampling(self)
    local guard = self._flow_guard or _new_flow_guard_state()
    guard.flow_guard_over_budget_ms = 0
    guard.flow_guard_hard_over_budget_ms = 0
    guard.flow_guard_under_budget_ms = 0
    guard.flow_guard_severity = 0
    guard.observe_elapsed_ms = 0
    guard.cooldown_remaining_ms = 0
    guard.pending_view_rect = nil
    guard.pending_view_rect_force = false
    guard.zoom_apply_delay_remaining_ms = 0
    if guard.state ~= "normal" then
        guard.state = "normal"
        guard.flow_guard_locked_min_zoom = 0
        guard.flow_guard_target_visible = 0
    end
    self._flow_guard = guard
    return guard
end

local function _flow_guard_is_view_rect_valid(rect)
    return rect
        and rect.min_x ~= nil
        and rect.min_y ~= nil
        and rect.max_x ~= nil
        and rect.max_y ~= nil
        and rect.max_x > rect.min_x
        and rect.max_y > rect.min_y
end

local function _flow_guard_queue_view_rect(self, rect, delay_ms, force_apply)
    local guard = self._flow_guard or _new_flow_guard_state()
    if not _flow_guard_is_view_rect_valid(rect) then
        return false
    end

    guard.pending_view_rect =
    {
        min_x = rect.min_x,
        min_y = rect.min_y,
        max_x = rect.max_x,
        max_y = rect.max_y,
    }
    guard.pending_view_rect_force = force_apply == true
    guard.zoom_apply_delay_remaining_ms = math.max(0, tonumber(delay_ms) or flow_guard_zoom_apply_delay_ms)
    self._flow_guard = guard
    _wake_flow_live(self, flow_cache_live_warmup_frames + 1)
    return true
end

local function _flow_guard_is_view_adjust_blocked(self, runtime_state, popup_open)
    if GlobalContext.is_debug_game or GlobalContext.is_resource_modal_active then
        return true
    end

    if popup_open or _has_pending_initial_flow_navigation(self) then
        return true
    end

    local io = imgui.GetIO()
    local wheel_active = io and (((io.MouseWheel or 0) ~= 0) or ((io.MouseWheelH or 0) ~= 0))
    local mouse_down = type(imgui.IsMouseDown) == "function"
        and (imgui.IsMouseDown(0) or imgui.IsMouseDown(1) or imgui.IsMouseDown(2))

    return wheel_active
        or mouse_down
        or (runtime_state and runtime_state.has_current_action == true)
        or (runtime_state and runtime_state.has_live_animation == true)
        or (runtime_state and runtime_state.is_navigating == true)
end

local function _flow_guard_apply_pending_view_rect(self, delta_ms, runtime_state, popup_open)
    local guard = self._flow_guard
    if not guard or not _flow_guard_is_view_rect_valid(guard.pending_view_rect) then
        return false
    end

    local force_apply = guard.pending_view_rect_force == true
    if type(imgui.NodeEditor.SetViewRect) ~= "function" then
        guard.pending_view_rect = nil
        guard.pending_view_rect_force = false
        guard.zoom_apply_delay_remaining_ms = 0
        return false
    end

    if not force_apply and _flow_guard_is_view_adjust_blocked(self, runtime_state, popup_open) then
        return false
    end

    guard.zoom_apply_delay_remaining_ms = math.max(0, (guard.zoom_apply_delay_remaining_ms or 0) - math.max(0, delta_ms or 0))
    if guard.zoom_apply_delay_remaining_ms > 0 then
        return false
    end

    local rect = guard.pending_view_rect
    imgui.NodeEditor.SetViewRect(rect.min_x, rect.min_y, rect.max_x, rect.max_y)
    guard.pending_view_rect = nil
    guard.pending_view_rect_force = false
    guard.zoom_apply_delay_remaining_ms = 0
    _mark_flow_view_dirty(self)
    return true
end

local function _flow_guard_can_sample(self, render_mode, popup_open)
    if render_mode ~= "live" and render_mode ~= "live_forced" then
        return false
    end

    if GlobalContext.is_debug_game or GlobalContext.is_resource_modal_active then
        return false
    end

    if popup_open or _has_pending_initial_flow_navigation(self) then
        return false
    end

    return self._flow_was_visible_last_frame == true and self:is_document_loaded()
end

local function _flow_guard_rect_intersects(left_min_x, left_min_y, left_max_x, left_max_y, right_min_x, right_min_y, right_max_x, right_max_y)
    return left_min_x < right_max_x
        and left_max_x > right_min_x
        and left_min_y < right_max_y
        and left_max_y > right_min_y
end

local function _flow_guard_update_visible_sample(self, runtime_state, host_size, delta_ms)
    local guard = self._flow_guard or _new_flow_guard_state()
    local host_width = host_size and math.max(0, host_size.x or 0) or 0
    local host_height = host_size and math.max(0, host_size.y or 0) or 0
    guard.flow_guard_host_area = host_width * host_height
    guard.visible_sample_elapsed_ms = (guard.visible_sample_elapsed_ms or 0) + math.max(0, delta_ms or 0)

    if guard.visible_sample_elapsed_ms < flow_guard_visible_sample_interval_ms
        and (guard.flow_guard_node_total or 0) > 0 then
        return guard
    end

    guard.visible_sample_elapsed_ms = 0

    local node_total = 0
    local visible_nodes = 0
    local sample_visible = runtime_state
        and runtime_state.view_min_x ~= nil
        and runtime_state.view_min_y ~= nil
        and runtime_state.view_max_x ~= nil
        and runtime_state.view_max_y ~= nil

    local view_min_x = sample_visible and runtime_state.view_min_x or 0
    local view_min_y = sample_visible and runtime_state.view_min_y or 0
    local view_max_x = sample_visible and runtime_state.view_max_x or 0
    local view_max_y = sample_visible and runtime_state.view_max_y or 0

    for _, node in pairs(self._node_pool or {}) do
        node_total = node_total + 1
        if sample_visible and node and node._id then
            local node_pos = imgui.NodeEditor.GetNodePosition(node._id)
            local node_size = imgui.NodeEditor.GetNodeSize(node._id)
            local min_x = tonumber(node_pos and node_pos.x) or 0
            local min_y = tonumber(node_pos and node_pos.y) or 0
            local width = math.max(1.0, tonumber(node_size and node_size.x) or 0)
            local height = math.max(1.0, tonumber(node_size and node_size.y) or 0)
            local max_x = min_x + width
            local max_y = min_y + height
            if _flow_guard_rect_intersects(min_x, min_y, max_x, max_y, view_min_x, view_min_y, view_max_x, view_max_y) then
                visible_nodes = visible_nodes + 1
            end
        end
    end

    guard.flow_guard_node_total = node_total
    guard.flow_guard_visible_nodes = visible_nodes
    self._flow_guard = guard
    return guard
end

local function _flow_guard_compute_target_visible(guard)
    local host_area = math.max(0, guard and guard.flow_guard_host_area or 0)
    local base_target = _clamp(math.floor(host_area / flow_guard_host_area_divisor + 0.5), 8, 24)
    local severe_target = _clamp(math.floor(base_target * 0.50 + 0.5), math.min(8, base_target), base_target)
    local target_visible = math.floor(_lerp(base_target, severe_target, guard and guard.flow_guard_severity or 0) + 0.5)
    guard.flow_guard_target_visible = target_visible
    return base_target, target_visible
end

local function _flow_guard_update_metrics(self, delta_ms, render_mode, runtime_state, host_size, popup_open, live_total_ms, submit_ms)
    local guard = self._flow_guard or _new_flow_guard_state()
    local frame_ms = math.max(0, delta_ms or 0)
    guard.editor_frame_ms_ema = _calc_ema(guard.editor_frame_ms_ema, frame_ms, frame_ms, flow_guard_ema_half_life_ms)
    guard.editor_fps_ema = guard.editor_frame_ms_ema > 0 and (1000.0 / guard.editor_frame_ms_ema) or 0
    guard.flow_live_sample_age_ms = (guard.flow_live_sample_age_ms or 0) + frame_ms

    if not _flow_guard_can_sample(self, render_mode, popup_open) then
        return _flow_guard_block_sampling(self)
    end

    guard.flow_live_sample_age_ms = 0
    guard.flow_live_total_ms_ema = _calc_ema(guard.flow_live_total_ms_ema, live_total_ms or 0, frame_ms, flow_guard_ema_half_life_ms)
    guard.flow_live_submit_ms_ema = _calc_ema(guard.flow_live_submit_ms_ema, submit_ms or 0, frame_ms, flow_guard_ema_half_life_ms)

    _flow_guard_update_visible_sample(self, runtime_state, host_size, frame_ms)

    local severity_flow = _normalize_range(guard.flow_live_total_ms_ema or 0, flow_guard_live_soft_ms, flow_guard_live_hard_ms)
    local fps_gap = math.max(0, flow_guard_fps_soft_threshold - (guard.editor_fps_ema or 0))
    local severity_fps = _normalize_range(fps_gap, 0, flow_guard_fps_soft_threshold - flow_guard_fps_hard_threshold)
    guard.flow_guard_severity = math.max(severity_flow, severity_fps)

    local soft_over_budget = (guard.flow_live_total_ms_ema or 0) >= flow_guard_live_soft_ms
        or ((guard.editor_fps_ema or 0) > 0 and (guard.editor_fps_ema or 0) <= flow_guard_fps_soft_threshold)
    local hard_over_budget = (guard.flow_live_total_ms_ema or 0) >= flow_guard_live_hard_ms
        or ((guard.editor_fps_ema or 0) > 0 and (guard.editor_fps_ema or 0) <= flow_guard_fps_hard_threshold)

    local recovery_ready = false
    if guard.state == "protect" then
        local fps_recovered = (guard.editor_fps_ema or 0) >= flow_guard_fps_recover_threshold
        local live_recovered = (guard.flow_live_total_ms_ema or 0) <= flow_guard_live_recover_ms
        recovery_ready = fps_recovered or live_recovered
    end

    if soft_over_budget then
        guard.flow_guard_over_budget_ms = (guard.flow_guard_over_budget_ms or 0) + frame_ms
    else
        guard.flow_guard_over_budget_ms = 0
    end

    if recovery_ready or not soft_over_budget then
        guard.flow_guard_under_budget_ms = (guard.flow_guard_under_budget_ms or 0) + frame_ms
    else
        guard.flow_guard_under_budget_ms = 0
    end

    if hard_over_budget then
        guard.flow_guard_hard_over_budget_ms = (guard.flow_guard_hard_over_budget_ms or 0) + frame_ms
    else
        guard.flow_guard_hard_over_budget_ms = 0
    end

    self._flow_guard = guard
    return guard
end

local function _flow_guard_compute_target_zoom(self, runtime_state)
    local guard = self._flow_guard
    if not guard or not runtime_state then
        return nil
    end

    local current_zoom = tonumber(runtime_state.view_scale) or tonumber(self._current_zoom) or 1
    local visible_nodes = tonumber(guard.flow_guard_visible_nodes) or 0
    local target_visible = tonumber(guard.flow_guard_target_visible) or 0
    if current_zoom <= 0 or visible_nodes <= 0 or target_visible <= 0 or visible_nodes <= target_visible then
        return nil
    end

    local severity = _clamp01(guard.flow_guard_severity or 0)
    local ratio = visible_nodes / target_visible
    local response_power = _lerp(flow_guard_zoom_response_soft_power, flow_guard_zoom_response_hard_power, severity)
    local max_zoom_ratio = _lerp(flow_guard_zoom_ratio_soft_max, flow_guard_zoom_ratio_hard_max, severity)
    local zoom_ratio = math.max(1.0, ratio) ^ response_power
    zoom_ratio = _clamp(zoom_ratio, 1.0, max_zoom_ratio)
    return current_zoom * zoom_ratio
end

local function _flow_guard_request_zoom_lock(self, runtime_state, force_enter)
    local guard = self._flow_guard or _new_flow_guard_state()
    if self._flow_guard_allow_zoom_lock ~= true then
        guard.flow_guard_locked_min_zoom = 0
        guard.pending_view_rect = nil
        guard.pending_view_rect_force = false
        guard.zoom_apply_delay_remaining_ms = 0
        self._flow_guard = guard
        return guard
    end

    local current_zoom = tonumber(runtime_state and runtime_state.view_scale) or tonumber(self._current_zoom) or 1
    local locked_min_zoom = tonumber(guard.flow_guard_locked_min_zoom) or 0

    if force_enter or locked_min_zoom <= 0 then
        local computed_zoom = _flow_guard_compute_target_zoom(self, runtime_state)
        if not computed_zoom then
            return guard
        end
        locked_min_zoom = math.max(locked_min_zoom, current_zoom, computed_zoom)
        guard.flow_guard_locked_min_zoom = locked_min_zoom
    end

    if current_zoom + flow_guard_zoom_epsilon >= locked_min_zoom then
        self._flow_guard = guard
        return guard
    end

    local view_min_x = tonumber(runtime_state.view_min_x) or 0
    local view_min_y = tonumber(runtime_state.view_min_y) or 0
    local view_max_x = tonumber(runtime_state.view_max_x) or 0
    local view_max_y = tonumber(runtime_state.view_max_y) or 0
    local current_width = math.max(1.0, view_max_x - view_min_x)
    local current_height = math.max(1.0, view_max_y - view_min_y)
    local center_x = (view_min_x + view_max_x) * 0.5
    local center_y = (view_min_y + view_max_y) * 0.5
    local scale_ratio = current_zoom / math.max(flow_guard_zoom_epsilon, locked_min_zoom)
    local target_width = current_width * scale_ratio
    local target_height = current_height * scale_ratio
    local force_apply = guard.state == "protect" or force_enter == true
    local apply_delay_ms = force_apply and 0 or flow_guard_zoom_apply_delay_ms

    self._flow_guard = guard
    _flow_guard_queue_view_rect(self,
    {
        min_x = center_x - target_width * 0.5,
        min_y = center_y - target_height * 0.5,
        max_x = center_x + target_width * 0.5,
        max_y = center_y + target_height * 0.5,
    }, apply_delay_ms, force_apply)
    return guard
end

_flow_guard_is_protecting = function(self)
    local guard = self and self._flow_guard
    return guard ~= nil and guard.state == "protect" and (tonumber(guard.flow_guard_locked_min_zoom) or 0) > 0
end

local function _flow_guard_update_state(self, delta_ms, runtime_state)
    local guard = self._flow_guard or _new_flow_guard_state()
    local base_target_visible, _ = _flow_guard_compute_target_visible(guard)
    local node_total = tonumber(guard.flow_guard_node_total) or 0
    local visible_nodes = tonumber(guard.flow_guard_visible_nodes) or 0
    local severity = tonumber(guard.flow_guard_severity) or 0
    local observe_visible_threshold = math.max(
        flow_guard_visible_observe_threshold,
        base_target_visible + 2,
        math.floor(base_target_visible * 1.20 + 0.5))
    local protect_visible_threshold = math.max(
        flow_guard_visible_protect_threshold,
        math.max(1, guard.flow_guard_target_visible or base_target_visible) + 2,
        math.floor(math.max(1, guard.flow_guard_target_visible or base_target_visible) * 1.35 + 0.5))
    local observe_eligible = node_total >= flow_guard_node_total_observe_threshold
        and visible_nodes >= observe_visible_threshold
    local protect_eligible = node_total >= flow_guard_node_total_protect_threshold
        and visible_nodes >= protect_visible_threshold
    local over_budget_ms = tonumber(guard.flow_guard_over_budget_ms) or 0
    local hard_over_budget_ms = tonumber(guard.flow_guard_hard_over_budget_ms) or 0
    local under_budget_ms = tonumber(guard.flow_guard_under_budget_ms) or 0

    if guard.state == "cooldown" then
        guard.cooldown_remaining_ms = math.max(0, (guard.cooldown_remaining_ms or flow_guard_cooldown_duration_ms) - math.max(0, delta_ms or 0))
        if guard.cooldown_remaining_ms <= 0 then
            guard.state = "normal"
            guard.cooldown_remaining_ms = 0
        end
        self._flow_guard = guard
        return guard
    end

    if guard.state == "protect" then
        if under_budget_ms >= flow_guard_leave_protect_duration_ms then
            return _flow_guard_enter_cooldown(self)
        end

        self._flow_guard = guard
        return _flow_guard_request_zoom_lock(self, runtime_state, false)
    end

    if not observe_eligible or severity <= 0 then
        if guard.state ~= "normal" then
            return _flow_guard_reset(self, "normal")
        end
        self._flow_guard = guard
        return guard
    end

    if guard.state == "normal" then
        if over_budget_ms >= flow_guard_enter_observe_duration_ms then
            guard = _flow_guard_enter_observe(self)
        end
    end

    if guard.state == "observe" then
        guard.observe_elapsed_ms = (guard.observe_elapsed_ms or 0) + math.max(0, delta_ms or 0)
        if protect_eligible
            and (guard.observe_elapsed_ms or 0) >= flow_guard_min_observe_duration_ms
            and (over_budget_ms >= flow_guard_enter_protect_duration_ms or hard_over_budget_ms >= flow_guard_enter_protect_hard_duration_ms)
        then
            guard.state = "protect"
            guard.cooldown_remaining_ms = 0
            guard.flow_guard_under_budget_ms = 0
            guard.observe_elapsed_ms = 0
            self._flow_guard = guard
            return _flow_guard_request_zoom_lock(self, runtime_state, true)
        end

        self._flow_guard = guard
        return guard
    end

    self._flow_guard = guard
    return guard
end

local function _flow_guard_tick_inactive(self, delta_ms)
    local guard = self._flow_guard or _new_flow_guard_state()
    local frame_ms = math.max(0, delta_ms or 0)
    guard.editor_frame_ms_ema = _calc_ema(guard.editor_frame_ms_ema, frame_ms, frame_ms, flow_guard_ema_half_life_ms)
    guard.editor_fps_ema = guard.editor_frame_ms_ema > 0 and (1000.0 / guard.editor_frame_ms_ema) or 0
    guard.flow_live_sample_age_ms = (guard.flow_live_sample_age_ms or 0) + frame_ms
    if guard.state == "cooldown" then
        guard.cooldown_remaining_ms = math.max(0, (guard.cooldown_remaining_ms or flow_guard_cooldown_duration_ms) - frame_ms)
        if guard.cooldown_remaining_ms <= 0 then
            guard.state = "normal"
            guard.cooldown_remaining_ms = 0
        end
    end
    self._flow_guard = guard
    return guard
end

local function _flow_guard_build_overlay_model(self)
    local guard = self._flow_guard
    local host_pos = self and self._flow_host_screen_pos
    local host_size = self and self._flow_host_screen_size
    if not guard or not host_pos or not host_size or host_size.x <= 0 or host_size.y <= 0 then
        return nil
    end

    if GlobalContext.is_debug_game or GlobalContext.is_resource_modal_active then
        return nil
    end

    local state = guard.state
    if state ~= "observe" and state ~= "protect" then
        return nil
    end

    local warning_color = EditorThemeManager.get_token("accent_warning") or imgui.ImVec4(imgui.ImColor(232, 176, 72, 255).value)
    local danger_color = EditorThemeManager.get_token("accent_danger") or imgui.ImVec4(imgui.ImColor(214, 72, 88, 255).value)
    local border_color = state == "protect" and danger_color or warning_color
    local panel_bg = EditorThemeManager.with_alpha(EditorThemeManager.get_modal_panel_bg_color(), 0.92)
    local title_bg = EditorThemeManager.with_alpha(border_color, state == "protect" and 0.30 or 0.20)
    local title_color = EditorThemeManager.get_text_on_color(border_color)
    local body_color = EditorThemeManager.get_text_on_color(panel_bg)
    local secondary_color = EditorThemeManager.get_secondary_text_on_color(panel_bg)

    local title = state == "protect" and "已启用性能保护" or "流程图较重"
    local suggestion = state == "protect"
        and "已暂停额外装饰并延后缓存捕获，可继续缩放或拆分流程"
        or "建议放大视图或拆分节点"

    return {
        state = state,
        host_pos = _copy_vec2(host_pos),
        host_size = _copy_vec2(host_size),
        border_color = border_color,
        panel_bg = panel_bg,
        title_bg = title_bg,
        title_color = title_color,
        body_color = body_color,
        secondary_color = secondary_color,
        title = title,
        suggestion = suggestion,
    }
end

local function _read_document_data(self)
    local content, err = NativeIO.read_text(self._path)
    if not content then
        return nil, string.format("无法打开流程文件：%s\n%s", _get_document_name(self), _stringify_error(err, "读取失败"))
    end

    -- SAVE TRACE: JSON string -> Lua table load entry for the same graph fields saved below.
    local result, data = json.ParseToLua(content)
    if not result then
        return nil, string.format("无法解析流程文件：%s\n%s", _get_document_name(self), _stringify_error(data, "JSON解析失败"))
    end

    return data
end

local function _reset_document_graph(self)
    local runtime_blueprint = GlobalContext.get_runtime_blueprint and GlobalContext.get_runtime_blueprint() or GlobalContext.current_blueprint
    if GlobalContext.is_debug_game and runtime_blueprint == self then
        GlobalContext.stop_debug()
    end
    if self._scene_context and self._scene_context.destroy then
        self._scene_context:destroy()
    end
    self._scene_context = nil
    self._next_node = nil
    self._next_node_entry_pin = nil
    self._current_node = nil
    self._max_uid = 0
    self._pin_pool = {}
    self._link_pool = {}
    self._link_pool_dirty = false
    self._node_pool = {}
    self._ticked = false
    self._navigate_counter = 0
    BlueprintNavigation.clear_pending(self)
    self._last_paste_revision = nil
    self._last_paste_cursor_x = nil
    self._last_paste_cursor_y = nil
    self._last_paste_repeat_count = 0
    self._node_move_tracker = nil
    self._flow_host_screen_pos = nil
    self._flow_host_screen_size = nil
    self._queued_flow_popup_id = nil
    self._queued_flow_popup_screen_pos = nil
    self._flow_context_popup_keepalive_id = nil
    self._flow_context_popup_keepalive_frames = 0
    self._flow_create_popup_screen_pos = nil
    self._flow_create_popup_canvas_pos = nil
    self._flow_context_popup_open_last_frame = false
    self._flow_context_popup_hovered_last_frame = false
    self._flow_capture_pending = false
    self._flow_last_has_pin_widget_activity = false
    self._flow_pending_widget_select_node_id = nil
    self._flow_capture_stable_frames = 0
    self._flow_last_capture_time_ms = -1000000
    self._flow_perf_stats = {}
    self._flow_guard = _new_flow_guard_state()
    _invalidate_flow_view_cache(self)
    _mark_flow_graph_dirty(self)
    _mark_flow_view_dirty(self)
end

local function _apply_document_data(self, data, preserve_open_state)
    imgui.NodeEditor.SetCurrentEditor(self._context)
    self:_reset_document_graph()
    self._max_uid = data.max_uid or 0
    for _, node_data in pairs(data.node_pool or {}) do
        self:spawn_node(NodeFactory.create({blueprint = self, type_id = node_data.type_id, data = node_data}), false)
    end
    local link_data_list = {}
    for _, link_data in pairs(data.link_pool or {}) do
        if type(link_data) == "table" then
            table.insert(link_data_list, link_data)
        end
    end
    table.sort(link_data_list, function(left, right)
        return (left.id or 0) < (right.id or 0)
    end)
    for _, link_data in ipairs(link_data_list) do
        local link = load_link(self, link_data)
        if link.input and link.output then
            _restore_link_record(self, _make_link_record(link))
        end
    end
    self._resource_file_signature =
    {
        size = NativeIO.get_file_size(self._path),
        mtime = NativeIO.get_file_modified_time(self._path),
    }
    self._document_loaded = true
    _touch_document(self)
    _invalidate_flow_view_cache(self)
    _mark_flow_graph_dirty(self)
    _mark_flow_view_dirty(self)
end

function Blueprint:ensure_document_loaded()
    if _is_document_loaded(self) then
        _touch_document(self)
        return true
    end

    local data, err = _read_document_data(self)
    if not data then
        self._document_loaded = false
        if self._is_temporary_runtime_document ~= true then
            LogManager.log(err, "error")
        end
        return false, err
    end
    _apply_document_data(self, data)
    self:_clear_document_edit_state()
    self._external_change_pending = false
    self._resource_missing = false
    if self._is_temporary_runtime_document ~= true then
        LogManager.log(string.format("成功加载流程脚本文件：%s", _get_document_name(self)), "success")
    end
    return true
end

function Blueprint:_is_flow_view_cache_valid()
    return self
        and self._flow_view_cache
        and imgui.FlowViewCache
        and imgui.FlowViewCache.IsValid
        and imgui.FlowViewCache.IsValid(self._flow_view_cache) == true
end

function Blueprint:_update_flow_perf_stats(sample)
    if not self then
        return nil
    end

    local stats = self._flow_perf_stats or {}
    self._flow_perf_stats = stats

    local delta_ms = tonumber(sample and sample.delta_ms) or 0
    local function assign_ms(field, value)
        local sample_value = math.max(0, tonumber(value) or 0)
        stats[field] = sample_value
        stats[field .. "_ema"] = _calc_ema(stats[field .. "_ema"], sample_value, delta_ms, flow_guard_ema_half_life_ms)
    end

    assign_ms("live_submit_ms", sample and sample.live_submit_ms)
    assign_ms("post_live_ms", sample and sample.post_live_ms)
    assign_ms("cache_capture_ms", sample and sample.cache_capture_ms)
    assign_ms("live_total_ms", sample and sample.live_total_ms)
    assign_ms("idle_draw_ms", sample and sample.idle_draw_ms)
    stats.last_render_mode = sample and sample.render_mode or stats.last_render_mode
    stats.cache_capture_skipped = sample and sample.cache_capture_skipped == true or false
    stats.cache_capture_skip_reason = sample and sample.cache_capture_skip_reason or nil
    return stats
end

function Blueprint:_flow_cache_evaluate_capture(context)
    local capture_context = type(context) == "table" and context or {}
    if capture_context.render_mode == "live_forced" then
        return false, "forced_live"
    end
    if capture_context.is_show_flow_active == true then
        return false, "flow_animation"
    end
    if capture_context.cache_dirty ~= true then
        self._flow_capture_pending = false
        return false, "cache_clean"
    end
    if not GlobalContext.renderer
        or not self._flow_view_cache
        or not imgui.FlowViewCache
        or not imgui.FlowViewCache.CaptureCurrentWindow
    then
        return false, "cache_unavailable"
    end

    local runtime_state = capture_context.runtime_state
    local critical_interaction = capture_context.popup_open == true
        or capture_context.input_widget_active == true
        or capture_context.shortcut_pending == true
        or (runtime_state and runtime_state.has_current_action == true)
        or (runtime_state and runtime_state.has_live_animation == true)
        or (runtime_state and runtime_state.is_navigating == true)
    local pointer_active = capture_context.pointer_active == true
    local mouse_in_host = capture_context.mouse_in_host == true
    if critical_interaction or pointer_active or mouse_in_host then
        self._flow_capture_stable_frames = 0
        self._flow_capture_pending = true
        if critical_interaction then
            return false, "critical_interaction"
        end
        return false, pointer_active and "pointer_active" or "mouse_in_host"
    end

    self._flow_capture_stable_frames = (self._flow_capture_stable_frames or 0) + 1
    if (self._flow_capture_stable_frames or 0) < 1 then
        self._flow_capture_pending = true
        return false, "waiting_stable_frame"
    end

    local now_ms = (rl.GetTime() or 0) * 1000
    local last_capture_ms = tonumber(self._flow_last_capture_time_ms) or -1000000
    if now_ms - last_capture_ms < 160 then
        self._flow_capture_pending = true
        return false, "capture_interval"
    end

    local live_before_capture_ms = math.max(0, tonumber(capture_context.live_before_capture_ms) or 0)
    if live_before_capture_ms > 14 and self:_is_flow_view_cache_valid() then
        self._flow_capture_pending = true
        return false, "live_over_budget"
    end

    return true, nil
end

function Blueprint:unload_document()
    if not _is_document_loaded(self) then
        return true
    end

    if self._flow_view_cache and imgui.FlowViewCache and imgui.FlowViewCache.ReleaseTarget then
        imgui.FlowViewCache.ReleaseTarget(self._flow_view_cache)
    end
    _invalidate_flow_view_cache(self)
    self:_reset_document_graph()
    self._document_loaded = false
    return true
end

-- 加载流程
function Blueprint:load_document()
    return self:ensure_document_loaded()
end

-- 保存流程
function Blueprint:save_document()
    local loaded_ok, load_err = self:ensure_document_loaded()
    if not loaded_ok then
        return false, load_err or string.format("无法加载流程文件：%s", _get_document_name(self))
    end
    local prev_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)

    local node_editor_began = false
    local function end_node_editor_if_needed()
        if node_editor_began then
            node_editor_began = false
            imgui.NodeEditor.End()
        end
    end

    local save_ok, result, err = xpcall(function()
        -- 如果没有更新过则更新一次初始化位置信息等数据
        imgui.NodeEditor.SetCurrentEditor(self._context)
        if not self._ticked then
            imgui.NodeEditor.Begin(self._tab_label or self._id)
            node_editor_began = true
                self:on_tick()
            end_node_editor_if_needed()
        end
        _sanitize_link_pool(self, true)
        -- 收集需要序列化的数据
        -- SAVE TRACE: blueprint dump root passed to Engine.JSON.PrintFromLua.
        -- Top-level fields: max_uid, node_pool, link_pool.
        -- Numeric-key-only node/link pools are encoded as JSON arrays; each record keeps its own id.
        local dump_data =
        {
            max_uid = self._max_uid,
            node_pool = {}, link_pool = {},
        }
        for id, node in pairs(self._node_pool) do
            -- SAVE TRACE: node:on_save() expands one node into node fields and nested pin lists.
            dump_data.node_pool[id] = node:on_save()
        end
        for id, link in pairs(self._link_pool) do
            -- SAVE TRACE: save_link() expands one link into id/input_pin_id/output_pin_id.
            dump_data.link_pool[id] = save_link(link)
        end
        -- 打开文件写入
        -- SAVE TRACE: Lua table -> JSON string conversion point.
        local str_json = json.PrintFromLua(dump_data)
        if type(str_json) ~= "string" then
            local serialize_err = "序列化流程文件失败"
            LogManager.log(string.format("图形流程文件保存失败：%s\n%s", _get_document_name(self), serialize_err), "error")
            return false, serialize_err
        end
        -- SAVE TRACE: final JSON payload is written to the blueprint resource path.
        local ok, write_err = NativeIO.write_text(self._path, str_json)
        if not ok then
            local message = _stringify_error(write_err, "写入失败")
            LogManager.log(string.format("图形流程文件保存失败：%s\n%s", _get_document_name(self), message), "error")
            return false, message
        end
        self._resource_file_signature =
        {
            size = NativeIO.get_file_size(self._path),
            mtime = NativeIO.get_file_modified_time(self._path),
        }
        self._external_change_pending = false
        self._resource_missing = false
        ModifyManager.set_modify(false)
        LogManager.log(string.format("图形流程文件已保存：%s", _get_document_name(self)), "success")
        return true
    end, function(message)
        if node_editor_began then
            node_editor_began = false
            pcall(function()
                imgui.NodeEditor.End()
            end)
        end
        return debug.traceback(_stringify_error(message, "保存流程时发生未知异常"), 2)
    end)

    ModifyManager.set_context(prev_context)
    if not save_ok then
        local message = _stringify_error(result, "未知错误")
        LogManager.log(string.format("图形流程文件保存失败：%s\n%s", _get_document_name(self), message), "error")
        return false, message
    end
    return result, err
end

function Blueprint:delete_graph_items(node_id_list, link_id_list)
    local snapshot = _build_delete_snapshot(self, node_id_list, link_id_list)
    if not snapshot then
        return false
    end

    _apply_delete_snapshot(self, snapshot)
    self:_clear_node_editor_selection()
    UndoManager.record(function(data)
            _restore_graph_snapshot(self, data)
        end, function(data)
            _apply_delete_snapshot(self, data)
            self:_clear_node_editor_selection()
        end, snapshot)
    return true
end

function Blueprint:delete_selection()
    return self:delete_graph_items(self:_get_selected_node_id_list(), self:_get_selected_link_id_list())
end

function Blueprint:copy_selection_to_clipboard()
    local snapshot = _build_clipboard_snapshot(self, self:_get_selected_node_id_list())
    if not snapshot then
        return false
    end

    BlueprintClipboard.write(snapshot)
    return true
end

function Blueprint:cut_selection_to_clipboard()
    if not self:copy_selection_to_clipboard() then
        return false
    end
    return self:delete_selection()
end

function Blueprint:paste_from_clipboard(canvas_mouse_pos)
    local clipboard_snapshot, revision = BlueprintClipboard.read()
    local valid, err = _validate_clipboard_snapshot(clipboard_snapshot)
    if not valid then
        LogManager.log(string.format("流程图粘贴失败：%s", err), "warning")
        return false
    end

    local anchor_pos = _resolve_paste_anchor(self, canvas_mouse_pos, revision)
    local graph_snapshot, build_err = _build_paste_graph_snapshot(self, clipboard_snapshot, anchor_pos)
    if not graph_snapshot then
        LogManager.log(string.format("流程图粘贴失败：%s", tostring(build_err)), "warning")
        return false
    end

    _set_selected_node_list(self, graph_snapshot.node_id_list)
    UndoManager.record(function(data)
            _apply_delete_snapshot(self, data)
            self:_clear_node_editor_selection()
        end, function(data)
            _restore_graph_snapshot(self, data)
            _set_selected_node_list(self, data.node_id_list)
        end, graph_snapshot)
    return true
end

function Blueprint:select_all_nodes()
    _set_selected_node_list(self, _get_all_node_id_list(self))
    return true
end

local function _begin_node_move_tracking(self, node_id_list)
    if not node_id_list or #node_id_list == 0 then
        return
    end

    local tracker =
    {
        node_id_list = {},
        position_pool = {},
    }

    for _, node_id in ipairs(node_id_list) do
        local node = self._node_pool[node_id]
        if node then
            table.insert(tracker.node_id_list, node_id)
            tracker.position_pool[node_id] =
            {
                start_pos = _clone_position(node._position),
            }
        end
    end

    if #tracker.node_id_list == 0 then
        return
    end

    self._node_move_tracker = tracker
end

local function _finish_node_move_tracking(self)
    local tracker = self._node_move_tracker
    if not tracker then
        return false
    end

    self._node_move_tracker = nil

    local move_record_list = {}
    for _, node_id in ipairs(tracker.node_id_list or {}) do
        local node = self._node_pool[node_id]
        local tracker_record = tracker.position_pool[node_id]
        if node and tracker_record and tracker_record.start_pos then
            local start_pos = tracker_record.start_pos
            local end_pos = _clone_position(node._position)
            if start_pos.x ~= end_pos.x or start_pos.y ~= end_pos.y then
                table.insert(move_record_list,
                {
                    node_id = node_id,
                    start_pos = start_pos,
                    end_pos = end_pos,
                })
            end
        end
    end

    if #move_record_list == 0 then
        return false
    end

    local undo_data =
    {
        move_record_list = move_record_list,
        selected_node_id_list = TableUtil.deep_copy(tracker.node_id_list),
    }

    UndoManager.record(function(data)
            for _, record in ipairs(data.move_record_list or {}) do
                local node = self._node_pool[record.node_id]
                if node then
                    _set_node_position(node, record.start_pos)
                end
            end
            _set_selected_node_list(self, data.selected_node_id_list)
        end, function(data)
            for _, record in ipairs(data.move_record_list or {}) do
                local node = self._node_pool[record.node_id]
                if node then
                    _set_node_position(node, record.end_pos)
                end
            end
            _set_selected_node_list(self, data.selected_node_id_list)
        end, undo_data)
    return true
end

local function _sync_node_positions(self, runtime_state)
    local changed_position_pool = {}
    local moved_node_id_list = {}

    for node_id, node in pairs(self._node_pool) do
        if node then
            local position = imgui.NodeEditor.GetNodePosition(node._id)
            local ix, iy = math.floor(position.x), math.floor(position.y)
            if node._position.x ~= ix or node._position.y ~= iy then
                changed_position_pool[node_id] = {x = ix, y = iy}
                table.insert(moved_node_id_list, node_id)
            end
        end
    end

    if #moved_node_id_list > 0 then
        _sort_numeric_id_list(moved_node_id_list)
    end

    local can_track_user_move = runtime_state
        and runtime_state.has_current_action == true
        and imgui.IsMouseDown
        and imgui.IsMouseDown(0)
    if can_track_user_move and self._node_move_tracker == nil and #moved_node_id_list > 0 then
        _begin_node_move_tracking(self, moved_node_id_list)
    end

    for node_id, position in pairs(changed_position_pool) do
        local node = self._node_pool[node_id]
        if node then
            node._position.x = position.x
            node._position.y = position.y
        end
    end

    if #moved_node_id_list > 0 then
        _mark_flow_graph_dirty(self)
    end

    if self._node_move_tracker and imgui.IsMouseReleased and imgui.IsMouseReleased(0) then
        _finish_node_move_tracking(self)
    end
end

local function _draw_flow_visuals(self)
    local degrade_visuals = self ~= nil and self._flow_guard ~= nil and self._flow_guard.state == "protect"
    local is_show_flow_active = not degrade_visuals
        and GlobalContext.is_show_flow.val
        and (self._current_zoom or 1) >= debug_visual_zoom_threshold
    if is_show_flow_active then
        for _, link in pairs(self._link_pool) do
            if link.input._type_id == "flow" then
                imgui.NodeEditor.Flow(link.id)
            end
        end
    end

    local is_show_all_node_id_active = not degrade_visuals and GlobalContext.is_show_all_node_id.val == true
    if is_show_all_node_id_active then
        imgui.NodeEditor.ShowAllNodeID()
    end

    return is_show_flow_active, is_show_all_node_id_active
end

local function _handle_flow_asset_drop(self)
    if imgui.BeginDragDropTarget() then
        local payload = imgui.AcceptDragDropPayload("asset")
        if payload then
            local node = nil
            local def = NodeRegistry.find_by_asset_payload(payload.type)
            if def then
                node = _create_node_by_def(self, def, imgui.NodeEditor.ScreenToCanvas(imgui.GetMousePos()))
            end
            if node then
                node._output_pin_list[1]:set_val(payload)
            end
        end
        imgui.EndDragDropTarget()
    end
end

local function _handle_flow_shortcuts(self)
    if not _can_handle_shortcuts(self) then
        return
    end

    local io = imgui.GetIO()
    if io and io.KeyCtrl then
        local block_navigate_to_content = _flow_guard_is_protecting(self)
        if imgui.IsKeyPressed(imgui.ImGuiKey.A, false) then
            self:select_all_nodes()
        elseif imgui.IsKeyPressed(imgui.ImGuiKey.C, false) then
            self:copy_selection_to_clipboard()
        elseif imgui.IsKeyPressed(imgui.ImGuiKey.X, false) then
            self:cut_selection_to_clipboard()
        elseif imgui.IsKeyPressed(imgui.ImGuiKey.V, false) then
            self:paste_from_clipboard(imgui.NodeEditor.ScreenToCanvas(imgui.GetMousePos()))
        elseif imgui.IsKeyPressed(imgui.ImGuiKey.Z, false) then
            UndoManager.undo()
        elseif imgui.IsKeyPressed(imgui.ImGuiKey.Y, false) then
            UndoManager.redo()
        elseif not block_navigate_to_content and imgui.IsKeyPressed(imgui.ImGuiKey.R, false) then
            imgui.NodeEditor.NavigateToContent()
            _mark_flow_view_dirty(self)
        elseif not io.KeyShift and imgui.IsKeyPressed(imgui.ImGuiKey.S, false) then
            self:save_document()
        end
    elseif imgui.IsKeyPressed(imgui.ImGuiKey.Delete, false) then
        self:delete_selection()
    end
end

function Blueprint:on_tick()
    local allow_interaction = not GlobalContext.is_debug_game and not GlobalContext.is_resource_modal_active
    _sanitize_link_pool(self)
    -- 处理节点渲染
    for id, node in pairs(self._node_pool) do
        node:on_update()
    end
    -- 处理连接渲染
    for _, link in pairs(self._link_pool) do
        local input_pin, output_pin = _normalize_link_in_place(self, link)
        if input_pin and output_pin then
            local link_color = input_pin._type_id == "flow" and EditorThemeManager.get_flow_link_color() or input_pin._color
            imgui.NodeEditor.Link(link.id, output_pin._id, input_pin._id, link_color, 2)
        end
    end
    if allow_interaction and imgui.NodeEditor.BeginCreate() then
        -- 处理连接建立
        local id_start, id_end = imgui.NodeEditor.PinId(0), imgui.NodeEditor.PinId(0)
        if imgui.NodeEditor.QueryNewLink(id_start, id_end) then
            local pin_start, pin_end = self._pin_pool[id_start:get()], self._pin_pool[id_end:get()]
            local pin_input, pin_output = _resolve_link_pins(pin_start, pin_end)
            if id_start:check_valid() and id_end:check_valid() and pin_input and pin_output and _can_link(pin_input, pin_output) then
                if imgui.NodeEditor.AcceptNewItem(color_link_accepted, 2) then
                    --[=========================================[
                        当新连接建立时：
                            1. 断开并保存输入节点的旧有连接对象
                            2. 断开并保存输出节点的旧有连接对象
                            3. 创建新的连接对象
                        撤销时：
                            1. 移除新创建的连接对象
                            2. 检查若输入节点旧有连接对象存在则恢复
                            3. 检查若输出节点旧有连接对象存在则恢复
                    --]=========================================]
                    local undo_data =
                    {
                        replaced_link_record_list = {},
                    }
                    _append_unique_link_record_list(undo_data.replaced_link_record_list, _remove_link_records_by_pin_id(self, pin_input._id, false))
                    _append_unique_link_record_list(undo_data.replaced_link_record_list, _remove_link_records_by_pin_id(self, pin_output._id, true))
                    -- ???????????????
                    -- ???????????????
                    -- ?????
                    local new_link =
                    {
                        id = imgui.NodeEditor.LinkId(self:gen_next_uid()),
                        input = pin_input,
                        output = pin_output
                    }
                    undo_data.new_link_record =
                    {
                        link = new_link,
                        input_linked_pin_id = pin_output._id,
                        output_linked_pin_id = pin_input._id,
                    }
                    _restore_link_record(self, undo_data.new_link_record, {capture_removed_record_list = undo_data.replaced_link_record_list})
                    _sort_link_record_list(undo_data.replaced_link_record_list)
                    _sanitize_link_pool(self, true)
                    _refresh_link_record_list_pin_state(self, undo_data.replaced_link_record_list)
                    _refresh_link_record_pin_state(self, undo_data.new_link_record)
                    -- 记录撤销重做
                    UndoManager.record(function(data)
                        _remove_link_record_list_snapshot(self, {data.new_link_record})
                        _restore_link_record_list_snapshot(self, data.replaced_link_record_list)
                        _sanitize_link_pool(self, true)
                        _refresh_link_record_list_pin_state(self, data.replaced_link_record_list)
                        _refresh_link_record_pin_state(self, data.new_link_record)
                    end, function(data)
                        _remove_link_record_list_snapshot(self, data.replaced_link_record_list)
                        _restore_link_record_list_snapshot(self, {data.new_link_record})
                        _sanitize_link_pool(self, true)
                        _refresh_link_record_list_pin_state(self, data.replaced_link_record_list)
                        _refresh_link_record_pin_state(self, data.new_link_record)
                    end, undo_data)
                end
            else
                imgui.NodeEditor.RejectNewItem(color_link_rejected, 2)
            end
        end
        -- 处理新节点创建
        local id_pin = imgui.NodeEditor.PinId(0)
        if imgui.NodeEditor.QueryNewNode(id_pin) then
            if imgui.NodeEditor.AcceptNewItem() then
                _queue_flow_popup(self, "CreateNewNode", imgui.GetMousePos())
            end
        end
    end
    if allow_interaction then
        imgui.NodeEditor.EndCreate()
    end
    if allow_interaction and imgui.NodeEditor.BeginDelete() then
        local deleted_node_id_list = {}
        local deleted_link_id_list = {}
        -- 处理节点删除
        local id_node = imgui.NodeEditor.NodeId()
        while imgui.NodeEditor.QueryDeletedNode(id_node) do
            local node = self._node_pool[id_node:get()]
            if node and node._type_id == "entry" then
                imgui.NodeEditor.RejectDeletedItem()
            elseif imgui.NodeEditor.AcceptDeletedItem(false) then
                table.insert(deleted_node_id_list, id_node:get())
            end
        end
        -- 处理连接删除
        local id_link = imgui.NodeEditor.LinkId()
        while imgui.NodeEditor.QueryDeletedLink(id_link) do
            if imgui.NodeEditor.AcceptDeletedItem() then
                table.insert(deleted_link_id_list, id_link:get())
            end
        end
        self:delete_graph_items(deleted_node_id_list, deleted_link_id_list)
        imgui.NodeEditor.EndDelete()
    end
    -- 处理右键菜单
    imgui.NodeEditor.Suspend()
        if allow_interaction then
            local mouse_pos = imgui.GetMousePos()
            local id_node = imgui.NodeEditor.NodeId(0)
            if imgui.NodeEditor.ShowNodeContextMenu(id_node) then
                self._node_menu = self._node_pool[id_node:get()]
                self._id_menu = self._node_menu:query_menu_id()
                if rawget(self, "_id_menu") then
                    _queue_flow_popup(self, self._id_menu, mouse_pos)
                end
            elseif imgui.NodeEditor.ShowBackgroundContextMenu() then
                _queue_flow_popup(self, "CreateNewNode", mouse_pos)
            end
            ResourceReferenceField.flush_overlay()
        else
            self._queued_flow_popup_id = nil
            self._queued_flow_popup_screen_pos = nil
            self._flow_context_popup_keepalive_id = nil
            self._flow_context_popup_keepalive_frames = 0
            self._flow_create_popup_screen_pos = nil
            self._flow_create_popup_canvas_pos = nil
            self._flow_context_popup_open_last_frame = false
            self._flow_context_popup_hovered_last_frame = false
        end
    imgui.NodeEditor.Resume()
    if BlueprintNavigation.apply_pending(self, imgui.NodeEditor) then
        _mark_flow_graph_dirty(self)
        _wake_flow_live(self)
    end
    if not self._ticked then
        self._ticked = true
    end
    -- 卧槽为啥啊只有三帧之后才生效！
    if self._navigate_counter < 4 then
        self._navigate_counter = self._navigate_counter + 1
        if self._navigate_counter == 3 then
            imgui.NodeEditor.NavigateToContent()
        end
    end
end

function Blueprint:on_update(delta)
    local function _reset_tab_visibility_state()
        self._flow_was_visible_last_frame = false
        self._flow_last_has_active_input_widget = false
        self._flow_last_has_pin_widget_activity = false
        self._flow_pending_widget_select_node_id = nil
        self._flow_last_mouse_in_host = false
        self._flow_host_screen_pos = nil
        self._flow_host_screen_size = nil
        self._queued_flow_popup_id = nil
        self._queued_flow_popup_screen_pos = nil
        self._flow_context_popup_keepalive_id = nil
        self._flow_context_popup_keepalive_frames = 0
        self._flow_create_popup_screen_pos = nil
        self._flow_create_popup_canvas_pos = nil
        self._flow_context_popup_open_last_frame = false
        self._flow_context_popup_hovered_last_frame = false
        _flow_guard_block_sampling(self)
    end

    local delta_ms = math.max(0, (delta or 0) * 1000)

    local previous_modify_context = ModifyManager.get_context()
    local previous_undo_context = UndoManager.get_context()
    ModifyManager.set_context(self._modify_context)
    if not self._is_open.val then
        _reset_tab_visibility_state()
        ModifyManager.set_context(previous_modify_context)
        return
    end

    local flag = imgui.TabItemFlags.None
    if ModifyManager.is_modify() then flag = flag | imgui.TabItemFlags.UnsavedDocument end
    if GlobalContext.bp_id_selected_next_frame == self._id then
        flag = flag | imgui.TabItemFlags.SetSelected
        GlobalContext.bp_id_selected_next_frame = nil
    end

    local is_tab_visible = false
    local tab_item_open = self._is_open
    if GlobalContext.is_debug_game then
        tab_item_open = nil
    end
    if imgui.BeginTabItem(self._tab_label or self._id, tab_item_open, flag) then
        is_tab_visible = true
        UndoManager.set_context(self._undo_context)
        if not GlobalContext.is_debug_game and GlobalContext.is_flow_designer_window_focused then
            GlobalContext.current_flow_document = self
            GlobalContext.current_blueprint = self
        end

        if self._resource_missing and not self:is_document_loaded() then
            imgui.TextColored(imgui.ImColor(197, 61, 67, 255).value, "该流程文件已在磁盘中删除或暂时不可用。")
            imgui.EndTabItem()
            UndoManager.set_context(previous_undo_context)
            ModifyManager.set_context(previous_modify_context)
            return
        end
        if not self:ensure_document_loaded() then
            imgui.TextColored(imgui.ImColor(197, 61, 67, 255).value, "无法加载当前流程文档，请检查控制台日志。")
            imgui.EndTabItem()
            UndoManager.set_context(previous_undo_context)
            ModifyManager.set_context(previous_modify_context)
            return
        end
        _touch_document(self)

        if self._resource_missing then
            imgui.TextColored(imgui.ImColor(197, 61, 67, 255).value, "该流程文件已在磁盘中删除或暂时不可用，当前保留的是内存中的旧内容。")
            imgui.Separator()
        elseif self._external_change_pending then
            imgui.TextColored(imgui.ImColor(248, 181, 0, 255).value, "磁盘中的流程文件已被外部修改，是否从磁盘重新加载？")
            if imgui.SmallButton("从磁盘重载##reload_" .. (self._resource_guid or self._id)) then
                self:reload_from_disk()
            end
            imgui.SameLine()
            if imgui.SmallButton("忽略提醒##ignore_" .. (self._resource_guid or self._id)) then
                self._external_change_pending = false
            end
            imgui.Separator()
        end

        _sync_flow_render_target_reset(self)
        _sync_flow_style_revision(self)
        _sync_flow_static_overlay_revision(self)
        if not self._flow_was_visible_last_frame then
            _mark_flow_view_dirty(self)
        end
        self._flow_was_visible_last_frame = true

        imgui.PushFont(GlobalContext.font_imgui, 18)
        imgui.NodeEditor.SetCurrentEditor(self._context)

        local host_id = string.format("flow_canvas_host_%s", self._resource_guid or self._id)
        local host_pos = imgui.GetCursorScreenPos()
        local host_size = imgui.GetContentRegionAvail()
        self._flow_host_screen_pos = _copy_vec2(host_pos)
        self._flow_host_screen_size = _copy_vec2(host_size)
        self._flow_last_window_width = host_size.x
        self._flow_last_window_height = host_size.y

        local mouse_pos = imgui.GetMousePos()
        local mouse_in_host = _is_point_in_rect(mouse_pos, host_pos, host_size)
        local mouse_entered_host = mouse_in_host and not self._flow_last_mouse_in_host
        local mouse_left_host = (not mouse_in_host) and self._flow_last_mouse_in_host == true
        local mouse_moved_in_host = mouse_in_host and _did_flow_mouse_move(self, mouse_pos)
        local pointer_active = _is_flow_pointer_active(self, mouse_in_host, mouse_pos)
        local pointer_critical_active = false
        if mouse_in_host then
            local io = imgui.GetIO()
            pointer_critical_active =
                (io and (((io.MouseWheel or 0) ~= 0) or ((io.MouseWheelH or 0) ~= 0)))
                or (imgui.IsMouseDown and (imgui.IsMouseDown(0) or imgui.IsMouseDown(1) or imgui.IsMouseDown(2)))
                or (imgui.IsMouseClicked and (imgui.IsMouseClicked(0, false) or imgui.IsMouseClicked(1, false) or imgui.IsMouseClicked(2, false)))
                or (imgui.IsMouseReleased and (imgui.IsMouseReleased(0) or imgui.IsMouseReleased(1) or imgui.IsMouseReleased(2)))
        end
        local last_runtime_state = self._flow_last_runtime_state or {}
        local hover_live_probe = mouse_left_host
            or (mouse_in_host
                and (mouse_entered_host
                    or mouse_moved_in_host
                    or last_runtime_state.has_hovered_object == true))
        local pointer_active_for_live = pointer_active
        if (self._flow_guard and self._flow_guard.state == "protect")
            and pointer_active
            and not pointer_critical_active
            and not hover_live_probe
        then
            pointer_active_for_live = false
        end
        local popup_open = _has_flow_popup_open(self)
        local shortcut_pending = _is_flow_shortcut_pending(self)
        local input_widget_active = _has_active_input_widget() or self._flow_last_has_active_input_widget == true
        local pin_widget_active = self:_has_pin_widget_activity(mouse_pos)
            or self._flow_last_has_pin_widget_activity == true
        local widget_interaction_active = input_widget_active or pin_widget_active
        local continuous_dirty = not (self._flow_guard and self._flow_guard.state == "protect")
            and GlobalContext.is_show_flow.val
            and (self._current_zoom or 1) >= debug_visual_zoom_threshold
        local cache_dirty = _is_flow_cache_dirty(self)
        local initial_navigation_pending = _has_pending_initial_flow_navigation(self)
        local render_mode = "idle_snapshot"

        if GlobalContext.is_debug_game then
            self._queued_flow_popup_id = nil
            self._queued_flow_popup_screen_pos = nil
            self._flow_context_popup_keepalive_id = nil
            self._flow_context_popup_keepalive_frames = 0
            self._flow_create_popup_screen_pos = nil
            self._flow_create_popup_canvas_pos = nil
            self._flow_context_popup_open_last_frame = false
            self._flow_context_popup_hovered_last_frame = false
        end

        if not GlobalContext.is_debug_game and pointer_active_for_live then
            self._flow_live_warmup_remaining = flow_cache_live_warmup_frames
        elseif not GlobalContext.is_debug_game and widget_interaction_active then
            self._flow_live_warmup_remaining = math.max(self._flow_live_warmup_remaining or 0, flow_cache_live_warmup_frames)
        elseif not GlobalContext.is_debug_game and (self._flow_live_warmup_remaining or 0) > 0 then
            self._flow_live_warmup_remaining = self._flow_live_warmup_remaining - 1
        else
            self._flow_live_warmup_remaining = math.max(0, self._flow_live_warmup_remaining or 0)
        end

        if GlobalContext.is_debug_game then
            if continuous_dirty or cache_dirty or initial_navigation_pending then
                render_mode = continuous_dirty and "live_forced" or "live"
                self._flow_idle_stable_frames = 0
            end
            self._flow_live_warmup_remaining = 0
        else
            local should_live = continuous_dirty
                or cache_dirty
                or initial_navigation_pending
                or popup_open
                or pointer_active_for_live
                or hover_live_probe
                or widget_interaction_active
                or shortcut_pending
                or last_runtime_state.has_current_action
                or last_runtime_state.has_live_animation
                or last_runtime_state.is_navigating
                or (self._flow_guard and self._flow_guard.pending_view_rect ~= nil)
                or ((self._flow_live_warmup_remaining or 0) > 0)

            if should_live then
                render_mode = continuous_dirty and "live_forced" or "live"
                self._flow_idle_stable_frames = 0
            else
                self._flow_idle_stable_frames = (self._flow_idle_stable_frames or 0) + 1
                if (self._flow_idle_stable_frames or 0) < flow_cache_idle_stable_frames_required then
                    render_mode = "live"
                end
            end
        end

        imgui.BeginChild(
            host_id,
            imgui.ImVec2(0, 0),
            nil,
            imgui.WindowFlags.NoScrollbar | imgui.WindowFlags.NoScrollWithMouse | imgui.WindowFlags.NoBackground)

        require("application.framework.blueprint_view_performance").render_canvas(self,
        {
            render_mode = render_mode,
            host_size = host_size,
            popup_open = popup_open,
        })

        if render_mode ~= "idle_snapshot" then
            local live_total_begin_time = rl.GetTime()
            local submit_begin_time = rl.GetTime()
            imgui.NodeEditor.Begin(self._tab_label or self._id)
                _flow_guard_apply_pending_view_rect(self, delta_ms, last_runtime_state, popup_open)
                if imgui.NodeEditor.GetCurrentZoom then
                    self._current_zoom = imgui.NodeEditor.GetCurrentZoom()
                else
                    self._current_zoom = 1
                end
                self:on_tick()
            imgui.NodeEditor.End()
            if self:_apply_queued_pin_widget_selection() then
                _mark_flow_graph_dirty(self)
            end
            self._flow_last_has_active_input_widget = _has_active_input_widget()
            self._flow_last_has_pin_widget_activity = self:_has_pin_widget_activity(mouse_pos)
            local submit_ms = (rl.GetTime() - submit_begin_time) * 1000
            local post_begin_time = rl.GetTime()

            local runtime_state = imgui.NodeEditor.GetRuntimeState() or {}
            runtime_state.has_current_action = runtime_state.has_current_action == true
            runtime_state.has_live_animation = runtime_state.has_live_animation == true
            runtime_state.is_navigating = runtime_state.is_navigating == true
            runtime_state.has_hovered_object = runtime_state.has_hovered_object == true
            _sync_node_positions(self, runtime_state)
            local is_show_flow_active = _draw_flow_visuals(self)
            self._flow_last_runtime_state = runtime_state
            if runtime_state.view_scale then
                self._current_zoom = runtime_state.view_scale
            end
            if imgui.NodeEditor.HasSelectionChanged and imgui.NodeEditor.HasSelectionChanged() then
                _mark_flow_graph_dirty(self)
            end

            _sync_flow_static_overlay_revision(self)
            _sync_flow_view_revision(self, runtime_state, imgui.GetWindowSize())

            local post_live_ms = (rl.GetTime() - post_begin_time) * 1000
            local live_before_capture_ms = (rl.GetTime() - live_total_begin_time) * 1000
            local cache_capture_ms = 0
            local cache_capture_skipped = false
            local cache_capture_skip_reason = nil
            local can_capture, capture_skip_reason = self:_flow_cache_evaluate_capture(
            {
                render_mode = render_mode,
                is_show_flow_active = is_show_flow_active,
                pointer_active = pointer_active_for_live,
                mouse_in_host = mouse_in_host,
                popup_open = popup_open,
                input_widget_active = widget_interaction_active
                    or self._flow_last_has_active_input_widget == true
                    or self._flow_last_has_pin_widget_activity == true,
                shortcut_pending = shortcut_pending,
                runtime_state = runtime_state,
                live_before_capture_ms = live_before_capture_ms,
                cache_dirty = cache_dirty,
            })
            if can_capture then
                local capture_begin_time = rl.GetTime()
                if imgui.FlowViewCache.CaptureCurrentWindow(self._flow_view_cache, GlobalContext.renderer) then
                    cache_capture_ms = (rl.GetTime() - capture_begin_time) * 1000
                    self._flow_last_capture_time_ms = (rl.GetTime() or 0) * 1000
                    self._flow_capture_pending = false
                    _mark_flow_cache_captured(self)
                    if imgui.FlowViewCache.DrawCurrentWindow then
                        -- Keep live and idle frames on the same visible presentation path to avoid mode-switch flicker.
                        imgui.FlowViewCache.DrawCurrentWindow(self._flow_view_cache)
                    end
                else
                    cache_capture_ms = (rl.GetTime() - capture_begin_time) * 1000
                    cache_capture_skipped = true
                    cache_capture_skip_reason = "capture_failed"
                    _invalidate_flow_view_cache(self)
                end
            else
                cache_capture_skipped = true
                cache_capture_skip_reason = capture_skip_reason
            end
            local live_total_ms = (rl.GetTime() - live_total_begin_time) * 1000
            self:_update_flow_perf_stats(
            {
                delta_ms = delta_ms,
                render_mode = render_mode,
                live_submit_ms = submit_ms,
                post_live_ms = post_live_ms,
                cache_capture_ms = cache_capture_ms,
                live_total_ms = live_total_ms,
                idle_draw_ms = 0,
                cache_capture_skipped = cache_capture_skipped,
                cache_capture_skip_reason = cache_capture_skip_reason,
            })
            _flow_guard_update_metrics(self, delta_ms, render_mode, runtime_state, host_size, popup_open, live_total_ms, submit_ms)
            _flow_guard_update_state(self, delta_ms, runtime_state)
        elseif self._flow_view_cache and imgui.FlowViewCache and imgui.FlowViewCache.DrawCurrentWindow then
            self._flow_last_has_active_input_widget = false
            self._flow_last_has_pin_widget_activity = false
            local idle_draw_begin_time = rl.GetTime()
            if not imgui.FlowViewCache.DrawCurrentWindow(self._flow_view_cache) then
                _invalidate_flow_view_cache(self)
            end
            self:_update_flow_perf_stats(
            {
                delta_ms = delta_ms,
                render_mode = render_mode,
                live_submit_ms = 0,
                post_live_ms = 0,
                cache_capture_ms = 0,
                live_total_ms = 0,
                idle_draw_ms = (rl.GetTime() - idle_draw_begin_time) * 1000,
                cache_capture_skipped = false,
            })
            _flow_guard_tick_inactive(self, delta_ms)
        else
            self._flow_last_has_active_input_widget = false
            self._flow_last_has_pin_widget_activity = false
            self:_update_flow_perf_stats(
            {
                delta_ms = delta_ms,
                render_mode = render_mode,
                live_submit_ms = 0,
                post_live_ms = 0,
                cache_capture_ms = 0,
                live_total_ms = 0,
                idle_draw_ms = 0,
                cache_capture_skipped = false,
            })
            _flow_guard_tick_inactive(self, delta_ms)
        end
        if GlobalContext.is_debug_game then
            _draw_flow_debug_mask(host_pos, host_size)
        end
        imgui.EndChild()
        if not GlobalContext.is_debug_game then
            _draw_flow_context_popups(self)
        end
        self._flow_last_mouse_x = mouse_pos.x
        self._flow_last_mouse_y = mouse_pos.y
        self._flow_last_mouse_in_host = mouse_in_host

        _handle_flow_asset_drop(self)
        imgui.PopFont()
        _handle_flow_shortcuts(self)
        imgui.EndTabItem()
        UndoManager.set_context(previous_undo_context)
    end

    if not is_tab_visible then
        _reset_tab_visibility_state()
    end
    ModifyManager.set_context(previous_modify_context)
end

function Blueprint:execute(scene)
    if not self:ensure_document_loaded() then
        LogManager.log(string.format("执行流程脚本时出错，无法加载流程文件：%s", _get_document_name(self)), "error")
        GlobalContext.stop_debug()
        return
    end
    _touch_document(self)
    local node_entry = nil
    for _, node in pairs(self._node_pool) do
        if node._type_id == "entry" then
            node_entry = node
            break
        end
    end
    if not node_entry then
        LogManager.log(string.format("执行流程脚本时出错，无法找到入口节点：%s", _get_document_name(self)), "error")
        GlobalContext.stop_debug()
        return
    end
    LogManager.log(string.format("开始调试场景：%s", _get_document_name(self)), "info")
    pcall(function()
        require("application.framework.snapshot_coordinator").reset_runtime_slices("新游戏")
    end)
    if self._scene_context and self._scene_context.destroy then
        self._scene_context:destroy()
    end
    self._scene_context = Scene.new()
    self._save_boundary = nil
    self:execute_node(node_entry)
end

function Blueprint:execute_node(node, entry_pin)
    self._save_boundary = nil
    if not node then
        LogManager.log("调试结束", "success")
        GlobalContext.stop_debug()
        return
    end
    _touch_document(self)
    self._next_node = node
    self._next_node_entry_pin = entry_pin
    pcall(function()
        require("application.framework.snapshot_coordinator").commit_anchor(self,
        {
            kind = "node_enter",
            label = "节点进入",
            node_id = node._id and node._id:get() or nil,
            node_title = node._title,
            document_guid = self._resource_guid,
        },
        {
            source = "flow_node",
        })
    end)
end

function Blueprint._is_runtime_scene_interaction_pressed(scene)
    if scene and scene.is_runtime_interaction_pressed then
        return scene:is_runtime_interaction_pressed()
    end
    local input = require("application.framework.runtime_input_state").read_current_state()
    return input.mouse_pressed == true
        or input.submit_pressed == true
        or GlobalContext.is_simulated_interaction == true
end

function Blueprint._build_graph_resume_route(node, output_ref)
    if not node then
        return {kind = "finish"}
    end

    local output_pin = node.resolve_output_pin and node:resolve_output_pin(output_ref) or nil
    local next_pin = output_pin and output_pin._linked_pin_id and GlobalContext.runtime_find_pin(output_pin._linked_pin_id:get()) or nil
    local next_node = next_pin and GlobalContext.runtime_find_node(next_pin._owner_id:get()) or nil
    return
    {
        kind = "interaction",
        output_ref = output_ref,
        source_node_id = node._id and node._id:get() or nil,
        source_node_title = node._title or nil,
        next_node_id = next_node and next_node._id and next_node._id:get() or nil,
        next_entry_pin_id = next_pin and next_pin._id and next_pin._id:get() or nil,
    }
end

function Blueprint._resolve_saved_resume_route(self, pending_resume)
    if type(pending_resume) ~= "table" then
        return nil, "无效的交互恢复信息"
    end

    if pending_resume.kind == "finish" then
        return {kind = "finish"}
    end

    local source_node_id = tonumber(pending_resume.source_node_id)
    if source_node_id == nil then
        return nil, "当前存档缺少交互节点标识，请重新创建该存档"
    end

    local source_node = self:runtime_find_node(source_node_id)
    if not source_node then
        return nil, "存档对应的交互节点已被更改或删除，无法恢复"
    end

    if pending_resume.output_ref == nil then
        return nil, "当前存档缺少恢复出口信息，请重新创建该存档"
    end

    local output_pin = source_node.resolve_output_pin and source_node:resolve_output_pin(pending_resume.output_ref) or nil
    if not output_pin then
        return nil, "存档对应的交互出口已变更，无法恢复"
    end

    return Blueprint._build_graph_resume_route(source_node, pending_resume.output_ref)
end

function Blueprint._resolve_saved_continue_route(self, continue_route)
    if type(continue_route) ~= "table" then
        return nil, "无效的继续执行恢复信息"
    end

    local source_node_id = tonumber(continue_route.source_node_id)
    if source_node_id == nil then
        return nil, "当前存档缺少继续执行节点标识，请重新创建该存档"
    end

    local source_node = self:runtime_find_node(source_node_id)
    if not source_node then
        return nil, "存档对应的继续执行节点已被更改或删除，无法恢复"
    end

    if continue_route.output_ref == nil then
        return nil, "当前存档缺少继续执行出口信息，请重新创建该存档"
    end

    local output_pin = source_node.resolve_output_pin and source_node:resolve_output_pin(continue_route.output_ref) or nil
    if not output_pin then
        return nil, "存档对应的继续执行出口已变更，无法恢复"
    end

    return Blueprint._build_graph_resume_route(source_node, continue_route.output_ref)
end

function Blueprint:runtime_update(delta)
    if not self._scene_context then
        return
    end

    if rawget(self, "_pending_resume_action") then
        self._scene_context:on_update(delta)
        if not self._scene_context then
            return
        end
        if Blueprint._is_runtime_scene_interaction_pressed(self._scene_context) then
            local pending_resume = self._pending_resume_action
            self._pending_resume_action = nil
            self._current_node = nil
            local resolved_resume, resume_err = Blueprint._resolve_saved_resume_route(self, pending_resume)
            if not resolved_resume then
                LogManager.log(string.format("恢复交互存档失败：%s", tostring(resume_err or "未知错误")), "error")
                self:execute_node()
                return
            end

            self._next_node = resolved_resume.next_node_id and self:runtime_find_node(resolved_resume.next_node_id) or nil
            self._next_node_entry_pin = resolved_resume.next_entry_pin_id and self:runtime_find_pin(resolved_resume.next_entry_pin_id) or nil
            if resolved_resume.kind == "finish" or self._next_node == nil then
                self:execute_node()
            end
        end
        return
    end

    local steps_this_frame = 0
    local max_steps = math.max(1, math.floor(tonumber(self._runtime_max_steps_per_frame) or runtime_default_max_steps_per_frame))
    local runtime_trace = {}

    while rawget(self, "_next_node") do
        steps_this_frame = steps_this_frame + 1
        _append_runtime_trace(runtime_trace, rawget(self, "_next_node"))
        if steps_this_frame > max_steps then
            _abort_runtime_step_overflow(self, max_steps, runtime_trace)
            return
        end

        self._current_node = self._next_node
        self._current_node_entry_pin = rawget(self, "_next_node_entry_pin")
        self._next_node = nil
        self._save_boundary = nil
        self._current_node._runtime_wait_interaction_state = nil
        require("application.framework.runtime_flow_control").capture_before_transition(self,
        {
            source = "flow_node",
            reason = "node_execute",
            label = "节点执行前",
        })
        local executed = require("application.framework.flow_runtime_guard").call_node(
            self._current_node,
            "on_execute",
            self._scene_context,
            rawget(self, "_next_node_entry_pin"))
        if not executed or not self._scene_context then
            return
        end
    end

    if not self._current_node then
        return
    end

    local current_node = self._current_node
    self._scene_context:on_update(delta)
    if not self._scene_context or self._current_node ~= current_node or not current_node then
        return
    end

    require("application.framework.flow_runtime_guard").call_node(current_node, "on_execute_update", self._scene_context, delta)
end

function Blueprint:runtime_render(options)
    if self._scene_context then
        self._scene_context:on_render(options)
    end
end

function Blueprint:reset_runtime_state()
    if self._scene_context and self._scene_context.destroy then
        self._scene_context:destroy()
    end
    self._scene_context = nil
    self._next_node = nil
    self._next_node_entry_pin = nil
    self._current_node = nil
    self._current_node_entry_pin = nil
    self._pending_resume_action = nil
    self._save_boundary = nil
end

function Blueprint:runtime_find_node(id)
    return self._node_pool and self._node_pool[id] or nil
end

function Blueprint:runtime_find_pin(id)
    return self._pin_pool and self._pin_pool[id] or nil
end

function Blueprint:get_runtime_scene_context()
    return self._scene_context
end

function Blueprint:resolve_runtime_local_references()
    local scene = self._scene_context
    if not scene or not self._node_pool then
        return false
    end

    for _, node in pairs(self._node_pool) do
        for _, pin in ipairs(node and node._output_pin_list or {}) do
            if pin and pin._type_id == "object" and pin.get_val and pin.set_val then
                local value = pin:get_val()
                if type(value) == "table" then
                    local object_id = rawget(value, "_id")
                    local is_game_object = false
                    local class_ok, class_result = pcall(Class.is_instance, value, GameObject)
                    if class_ok then
                        is_game_object = class_result == true
                    end

                    if is_game_object and type(object_id) == "string" and object_id ~= "" then
                        pin:set_val(scene:find_object(object_id))
                    elseif rawget(value, "widget_by_id") ~= nil and type(rawget(value, "id")) == "string" then
                        pin:set_val(scene:find_ui_instance(value.id))
                    end
                end
            end
        end
    end

    return true
end

function Blueprint:set_runtime_save_boundary(boundary)
    self._save_boundary = type(boundary) == "table" and TableUtil.deep_copy(boundary) or nil
end

function Blueprint:clear_runtime_save_boundary()
    self._save_boundary = nil
end

function Blueprint:get_runtime_save_boundary()
    return type(self._save_boundary) == "table" and TableUtil.deep_copy(self._save_boundary) or nil
end

function Blueprint:can_save_now()
    if not self._scene_context then
        return false, "当前流程图运行时尚未启动"
    end

    if self._pending_resume_action then
        return true
    end

    if self._current_node then
        local has_common_wait_state = type(self._current_node._runtime_wait_interaction_state) == "table"
        local has_save_boundary = type(self._save_boundary) == "table" and self._save_boundary.saveable == true
        if has_save_boundary then
            return true
        end
        if has_common_wait_state then
            return false, "当前节点正在进入等待状态，输入释放后才能存档"
        end
        if self._current_node.can_save_now then
            local ok, reason = self._current_node:can_save_now(self._scene_context,
            {
                blueprint = self,
                entry_pin = self._current_node_entry_pin,
            })
            if ok ~= true then
                return false, reason or "当前节点尚未进入可保存的稳定等待点"
            end
            return true
        end
        return false, "当前节点尚未进入可保存的稳定等待点"
    end

    return true
end

function Blueprint:collect_runtime_save_state()
    local anchor_node = self._current_node or self._next_node
    local snapshot =
    {
        kind = "graph",
        document_guid = self._resource_guid or "",
        document_path = self._path or "",
        document_name = self._display_name or self._resource_id or self._id or "",
        current_node_id = self._current_node and self._current_node._id and self._current_node._id:get() or nil,
        next_node_id = self._next_node and self._next_node._id and self._next_node._id:get() or nil,
        next_entry_pin_id = self._next_node_entry_pin and self._next_node_entry_pin._id and self._next_node_entry_pin._id:get() or nil,
        checkpoint_kind = "stable_boundary",
        anchor =
        {
            node_id = anchor_node and anchor_node._id and anchor_node._id:get() or nil,
            node_title = anchor_node and anchor_node._title or nil,
        },
    }

    if self._pending_resume_action then
        snapshot.pending_resume = TableUtil.deep_copy(self._pending_resume_action)
        if snapshot.anchor and snapshot.anchor.node_id == nil and snapshot.pending_resume.source_node_id ~= nil then
            snapshot.anchor.node_id = snapshot.pending_resume.source_node_id
            snapshot.anchor.node_title = snapshot.pending_resume.source_node_title
        end
        snapshot.checkpoint_kind = "interaction_boundary"
        return snapshot
    end

    if self._current_node then
        local has_common_wait_state = type(self._current_node._runtime_wait_interaction_state) == "table"
        local has_save_boundary = type(self._save_boundary) == "table" and self._save_boundary.saveable == true
        local state = nil
        if has_common_wait_state and not has_save_boundary then
            return nil
        elseif has_save_boundary then
            state =
            {
                resume_mode = self._save_boundary.resume_mode or "interaction",
                output_ref = self._save_boundary.output_ref,
                boundary_kind = self._save_boundary.kind,
            }
        else
            state = self._current_node.collect_runtime_save_state
                and self._current_node:collect_runtime_save_state(self._scene_context,
                {
                    blueprint = self,
                    entry_pin = self._current_node_entry_pin,
                }) or nil
        end
        if type(state) ~= "table" then
            return nil
        end

        if state.resume_mode == "interaction" then
            snapshot.pending_resume = Blueprint._build_graph_resume_route(self._current_node, state.output_ref)
            snapshot.checkpoint_kind = state.boundary_kind or "interaction_boundary"
            snapshot.current_node_id = nil
        elseif state.resume_mode == "continue" then
            snapshot.continue_route = Blueprint._build_graph_resume_route(self._current_node, state.output_ref)
            snapshot.current_node_id = nil
            snapshot.next_node_id = nil
            snapshot.next_entry_pin_id = nil
        elseif state.resume_mode == "reexecute" then
            snapshot.skip_object_ids = TableUtil.deep_copy(state.managed_object_ids or {})
            snapshot.skip_ui_instance_ids = TableUtil.deep_copy(state.managed_ui_instance_ids or {})
            snapshot.current_node_state = TableUtil.deep_copy(state.state or {})
            snapshot.current_node_resume_mode = "reexecute"
            snapshot.current_entry_pin_id = self._current_node_entry_pin and self._current_node_entry_pin._id and self._current_node_entry_pin._id:get() or nil
            snapshot.checkpoint_kind = "node_waiting"
        else
            return nil
        end
    end

    return snapshot
end

function Blueprint:validate_runtime_save_state(runtime_state)
    if type(runtime_state) ~= "table" then
        return false, "无效的流程图运行时快照"
    end

    if not self:ensure_document_loaded() then
        return false, "无法加载流程图文档"
    end

    local pending_resume = type(runtime_state.pending_resume) == "table" and runtime_state.pending_resume or nil
    local continue_route = type(runtime_state.continue_route) == "table" and runtime_state.continue_route or nil
    local anchor = type(runtime_state.anchor) == "table" and runtime_state.anchor or {}
    local anchor_node_id = tonumber(anchor.node_id)
    if anchor_node_id ~= nil and not self:runtime_find_node(anchor_node_id) then
        return false, "存档对应的锚点节点已被更改或删除，无法恢复"
    end

    if pending_resume then
        local _, resume_err = Blueprint._resolve_saved_resume_route(self, pending_resume)
        if resume_err then
            return false, resume_err
        end
        return true
    end

    if continue_route then
        local _, continue_err = Blueprint._resolve_saved_continue_route(self, continue_route)
        if continue_err then
            return false, continue_err
        end
        return true
    end

    if runtime_state.current_node_resume_mode == "reexecute" and runtime_state.current_node_id then
        if not self:runtime_find_node(runtime_state.current_node_id) then
            return false, "无法定位待恢复的流程节点"
        end
        if runtime_state.current_entry_pin_id ~= nil and not self:runtime_find_pin(runtime_state.current_entry_pin_id) then
            return false, "存档对应的流程入口已不存在"
        end
        return true
    end

    if runtime_state.next_node_id ~= nil and not self:runtime_find_node(runtime_state.next_node_id) then
        return false, "存档对应的下一执行节点已不存在"
    end
    if runtime_state.next_entry_pin_id ~= nil and not self:runtime_find_pin(runtime_state.next_entry_pin_id) then
        return false, "存档对应的下一执行入口已不存在"
    end

    return true
end

function Blueprint:restore_runtime_save_state(runtime_state)
    local valid, validation_err = self:validate_runtime_save_state(runtime_state)
    if valid ~= true then
        return false, validation_err
    end
    if type(runtime_state) ~= "table" then
        return false, "无效的流程图运行时快照"
    end

    if not self:ensure_document_loaded() then
        return false, "无法加载流程图文档"
    end

    self:reset_runtime_state()
    self._scene_context = Scene.new()

    if type(runtime_state.pending_resume) == "table" then
        self._pending_resume_action = TableUtil.deep_copy(runtime_state.pending_resume)
        self._pending_resume_action.next_node_id = nil
        self._pending_resume_action.next_entry_pin_id = nil
        self._save_boundary = nil
        return true
    end

    if type(runtime_state.continue_route) == "table" then
        local continue_route, continue_err = Blueprint._resolve_saved_continue_route(self, runtime_state.continue_route)
        if not continue_route then
            self:reset_runtime_state()
            return false, continue_err or "无法恢复后续执行路线"
        end

        self._next_node = continue_route.next_node_id and self:runtime_find_node(continue_route.next_node_id) or nil
        self._next_node_entry_pin = continue_route.next_entry_pin_id and self:runtime_find_pin(continue_route.next_entry_pin_id) or nil
        self._current_node = nil
        self._current_node_entry_pin = nil
        self._save_boundary = nil
        return true
    end

    if runtime_state.current_node_resume_mode == "reexecute" and runtime_state.current_node_id then
        local node = self:runtime_find_node(runtime_state.current_node_id)
        if not node then
            return false, "无法定位待恢复的流程节点"
        end

        self._current_node = node
        self._current_node_entry_pin = runtime_state.current_entry_pin_id and self:runtime_find_pin(runtime_state.current_entry_pin_id) or nil
        self._current_node._runtime_wait_interaction_state = nil
        local executed = require("application.framework.flow_runtime_guard").call_node(
            self._current_node,
            "on_execute",
            self._scene_context,
            self._current_node_entry_pin)
        if executed == false then
            self:reset_runtime_state()
            return false, "无法恢复流程节点运行时"
        end

        if self._current_node.on_runtime_apply_state then
            self._current_node:on_runtime_apply_state(self._scene_context,
            {
                blueprint = self,
                entry_pin = self._current_node_entry_pin,
            }, TableUtil.deep_copy(runtime_state.current_node_state or {}))
        end
        self._next_node = nil
        self._next_node_entry_pin = nil
        self._save_boundary = nil
        return true
    end

    self._next_node = runtime_state.next_node_id and self:runtime_find_node(runtime_state.next_node_id) or nil
    self._next_node_entry_pin = runtime_state.next_entry_pin_id and self:runtime_find_pin(runtime_state.next_entry_pin_id) or nil
    self._current_node = nil
    self._current_node_entry_pin = nil
    self._save_boundary = nil
    return true
end

function Blueprint:is_modified()
    if not _is_document_loaded(self) then
        return false
    end
    local previous_context = ModifyManager.get_context()
    ModifyManager.set_context(self._modify_context)
    local modified = ModifyManager.is_modify()
    ModifyManager.set_context(previous_context)
    return modified
end

function Blueprint:mark_external_change(meta)
    if self._resource_missing then
        return
    end
    if not _is_document_loaded(self) then
        if meta and meta.file_signature then
            self._resource_file_signature = _clone_signature(meta.file_signature)
        end
        self._external_change_pending = false
        return
    end
    self._external_change_pending = true
    if meta and meta.file_signature then
        self._resource_file_signature = _clone_signature(meta.file_signature)
    end
    if self._is_temporary_runtime_document ~= true then
        LogManager.log(string.format("检测到流程文件发生外部修改：%s", _get_document_name(self)), "warning")
    end
end

function Blueprint:mark_resource_missing()
    if self._resource_missing then
        return
    end
    self._resource_missing = true
    self._external_change_pending = false
    if self._is_temporary_runtime_document ~= true then
        LogManager.log(string.format("流程文件已从磁盘中移除：%s", _get_document_name(self)), "warning")
    end
end

function Blueprint:clear_resource_missing()
    self._resource_missing = false
end

function Blueprint:reload_from_disk()
    if not self:ensure_document_loaded() then
        return false
    end
    local data, err = _read_document_data(self)
    if not data then
        if self._is_temporary_runtime_document ~= true then
            LogManager.log(err, "error")
        end
        return false
    end

    _apply_document_data(self, data, true)
    self:_clear_document_edit_state()

    self._external_change_pending = false
    self._resource_missing = false
    if self._is_temporary_runtime_document ~= true then
        LogManager.log(string.format("已从磁盘重新加载流程文件：%s", _get_document_name(self)), "success")
    end
    return true
end

function Blueprint:dispose()
    if rawget(self, "_is_disposed") then return end
    local runtime_blueprint = GlobalContext.get_runtime_blueprint and GlobalContext.get_runtime_blueprint() or GlobalContext.current_blueprint
    if GlobalContext.is_debug_game and runtime_blueprint == self then
        GlobalContext.stop_debug()
    end
    self._is_disposed = true
    self._node_move_tracker = nil
    if self._scene_context and self._scene_context.destroy then
        self._scene_context:destroy()
        self._scene_context = nil
    end
    if GlobalContext.debug_blueprint == self then
        GlobalContext.debug_blueprint = nil
    end
    if self._context then
        imgui.NodeEditor.Destroy(self._context)
        self._context = nil
    end
    if self._flow_view_cache and imgui.FlowViewCache and imgui.FlowViewCache.Destroy then
        imgui.FlowViewCache.Destroy(self._flow_view_cache)
        self._flow_view_cache = nil
    end
    self._node_pool = {}
    self._pin_pool = {}
    self._link_pool = {}
    self._link_pool_dirty = false
    self._document_loaded = false
    if GlobalContext.current_flow_document == self then
        GlobalContext.current_flow_document = nil
    end
    if GlobalContext.debug_flow_document == self then
        GlobalContext.debug_flow_document = nil
    end
    if GlobalContext.runtime_save_anchor_document == self then
        GlobalContext.runtime_save_anchor_document = nil
    end
    if GlobalContext.current_blueprint == self then
        GlobalContext.current_blueprint = nil
    end
end

function Blueprint:ctor(resource_source, options)
    options = options or {}
    local config = imgui.NodeEditor.Config()
    config.SettingsFile = nil
    local path = type(resource_source) == "table" and resource_source.path or resource_source
    local is_create_file = not NativeIO.file_exists(path)
    self._id = rl.GetFileNameWithoutExt(path)
    self._max_uid = 0
    self._pin_pool = {}
    self._link_pool = {}
    self._link_pool_dirty = false
    self._node_pool = {}
    self._is_open = imgui.Bool(true)
    self._path = path
    self.kind = "graph"
    self._resource_guid = nil
    self._resource_id = nil
    self._resource_file_signature = nil
    self._resource_missing = false
    self._external_change_pending = false
    self._document_loaded = false
    self._document_last_used_time = 0
    self._display_name = nil
    self._tab_label = nil
    self._ticked = false
    self._id_menu = nil
    self._node_menu = nil
    self._navigate_counter = 0
    self._last_paste_revision = nil
    self._last_paste_cursor_x = nil
    self._last_paste_cursor_y = nil
    self._last_paste_repeat_count = 0
    self._current_zoom = 1
    self._node_move_tracker = nil
    self._flow_view_cache = imgui.FlowViewCache and imgui.FlowViewCache.Create and imgui.FlowViewCache.Create() or nil
    self._flow_graph_revision = 0
    self._flow_view_revision = 0
    self._flow_style_revision = 0
    self._flow_static_overlay_revision = 0
    self._flow_cached_graph_revision = -1
    self._flow_cached_view_revision = -1
    self._flow_cached_style_revision = -1
    self._flow_cached_static_overlay_revision = -1
    self._flow_last_runtime_state = {}
    self._flow_last_window_width = 0
    self._flow_last_window_height = 0
    self._flow_last_captured_window_width = -1
    self._flow_last_captured_window_height = -1
    self._flow_idle_stable_frames = 0
    self._flow_live_warmup_remaining = 0
    self._flow_was_visible_last_frame = false
    self._flow_last_render_target_reset_revision = -1
    self._flow_style_signature = nil
    self._flow_view_signature = nil
    self._flow_static_overlay_signature = nil
    self._flow_last_mouse_x = nil
    self._flow_last_mouse_y = nil
    self._flow_last_has_active_input_widget = false
    self._flow_last_has_pin_widget_activity = false
    self._flow_pending_widget_select_node_id = nil
    self._flow_last_mouse_in_host = false
    self._flow_host_screen_pos = nil
    self._flow_host_screen_size = nil
    self._queued_flow_popup_id = nil
    self._queued_flow_popup_screen_pos = nil
    self._flow_context_popup_keepalive_id = nil
    self._flow_context_popup_keepalive_frames = 0
    self._flow_create_popup_screen_pos = nil
    self._flow_create_popup_canvas_pos = nil
    self._flow_context_popup_open_last_frame = false
    self._flow_context_popup_hovered_last_frame = false
    self._flow_capture_pending = false
    self._flow_capture_stable_frames = 0
    self._flow_last_capture_time_ms = -1000000
    self._flow_perf_stats = {}
    BlueprintNavigation.clear_pending(self)
    self._flow_guard = _new_flow_guard_state()
    self._context = imgui.NodeEditor.Create(config)
    if self._context and EditorThemeManager.apply_node_editor_theme_to_context then
        EditorThemeManager.apply_node_editor_theme_to_context(self._context)
    end
    self._undo_context = UndoManager.create_context()
    self._modify_context = ModifyManager.create_context(is_create_file)
    self._next_node = nil
    self._next_node_entry_pin = nil
    self._current_node = nil
    self._current_node_entry_pin = nil
    self._pending_resume_action = nil
    self._save_boundary = nil
    self._scene_context = nil
    self._is_disposed = false
    self:update_resource_meta(resource_source)
    if options.initial_open ~= nil then
        self._is_open.val = options.initial_open == true
    end

    UndoManager.set_context(self._undo_context)
    if is_create_file then
        self._document_loaded = true
        self:spawn_node(NodeFactory.create({blueprint = self, type_id = "entry"}), false)
        self:save_document()
    elseif not options.lazy_document then
        self:load_document()
    end
end

function Blueprint:mark_theme_dirty(flow_color)
    _refresh_flow_pin_theme_color(self, flow_color)
    if self._context and EditorThemeManager.apply_node_editor_theme_to_context then
        EditorThemeManager.apply_node_editor_theme_to_context(self._context)
    end
    _mark_flow_style_dirty(self)
    _wake_flow_live(self)
end

Blueprint._remove_link_by_link_id = _remove_link_by_link_id
Blueprint._remove_link_by_pin_id = _remove_link_by_pin_id
Blueprint._menu_item_create_node = _menu_item_create_node
Blueprint._reset_document_graph = _reset_document_graph
Blueprint._get_selected_node_id_list = _get_selected_node_id_list
Blueprint._get_selected_link_id_list = _get_selected_link_id_list
Blueprint.is_document_loaded = _is_document_loaded
function Blueprint:request_navigate_to_node(node_id, options)
    local ok = BlueprintNavigation.request_node(self, node_id, options)
    if ok then
        if type(options) == "table" and options.stabilize_view == true then
            _flow_guard_block_sampling(self)
        end
        _wake_flow_live(self, flow_cache_live_warmup_frames + 1)
    end
    return ok
end
Blueprint.get_flow_guard_overlay_model = _flow_guard_build_overlay_model
Blueprint.is_flow_zoom_guard_protecting = _flow_guard_is_protecting

Blueprint.__gc = Blueprint.dispose
Blueprint.update_resource_meta = _update_resource_meta


return Blueprint

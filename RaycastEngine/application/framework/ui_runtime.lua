local rl = Engine.Raylib
local imgui = Engine.ImGUI

local Class = require("application.framework.class")
local FlowRuntimeError = require("application.framework.flow_runtime_error")
local FlowTextDiagnostics = require("application.framework.flow_text_diagnostics")
local FlowTextRuntime = require("application.framework.flow_text_runtime")
local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local RuntimeInputState = require("application.framework.runtime_input_state")
local SaveSlotGridModel = require("application.framework.save_slot_grid_model")
local SaveThumbnailCache = require("application.framework.save_thumbnail_cache")
local ScreenManager = require("application.framework.screen_manager")
local ShaderWrapper = require("application.framework.shader_wrapper")
local ShaderRuntime = require("application.framework.shader_runtime")
local StyleManager = require("application.framework.style_manager")
local TextWrapper = require("application.framework.text_wrapper")
local UI = require("application.framework.ui")
local UIFlowGraphRuntime = require("application.framework.ui_flow_graph_runtime")
local UIWidgetRegistry = require("application.framework.ui_widget_registry")

local UIRuntime = Class.define("UIRuntime")
local flow_manager_module = false
local save_manager_module = false
local snapshot_coordinator_module = false
local runtime_flow_control_module = false
local save_load_result_toast_module = false

local function _get_flow_manager()
    if flow_manager_module == false then
        flow_manager_module = require("application.framework.flow_manager")
    end
    return flow_manager_module
end

local function _get_save_manager()
    if save_manager_module == false then
        save_manager_module = require("application.framework.save_manager")
    end
    return save_manager_module
end

local function _get_snapshot_coordinator()
    if snapshot_coordinator_module == false then
        snapshot_coordinator_module = require("application.framework.snapshot_coordinator")
    end
    return snapshot_coordinator_module
end

local function _get_runtime_flow_control()
    if runtime_flow_control_module == false then
        runtime_flow_control_module = require("application.framework.runtime_flow_control")
    end
    return runtime_flow_control_module
end

local function _notify_load_failed()
    if save_load_result_toast_module == false then
        save_load_result_toast_module = require("application.framework.save_load_result_toast")
    end
    local toast = save_load_result_toast_module
    if toast and toast.notify_load_failed then
        toast.notify_load_failed()
    end
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

local function _normalize_runtime_flow_reference(reference)
    return ResourceIndex.make_reference("flow", reference)
end

local function _display_text(value)
    local text = _trim(tostring(value or ""))
    return text or "空"
end

local function _document_key(document)
    if not document then
        return nil
    end
    return _trim(document._resource_guid)
        or _trim(document._path)
        or _trim(document._resource_id)
        or _trim(document._display_name)
        or tostring(document)
end

local function _document_display_name(document)
    if not document then
        return "未知流程"
    end
    return _trim(document._display_name)
        or _trim(document._resource_id)
        or _trim(document._path)
        or _trim(document._resource_guid)
        or "未知流程"
end

local function _describe_ui_event_payload(payload)
    payload = type(payload) == "table" and payload or {}
    return string.format(
        "事件=%s；界面=%s；实例名=%s；组件名称=%s；内部组件ID=%s；界面事件=%s",
        _display_text(payload.event_type),
        _display_text(payload.source_path or payload.source_guid),
        _display_text(payload.instance_id),
        _display_text(payload.widget_name),
        _display_text(payload.widget_id),
        _display_text(payload.event_name))
end

local function _log_warning_once(runtime, key, message)
    if not runtime then
        LogManager.log(message, "warning")
        return
    end
    runtime._behavior_warning_pool = runtime._behavior_warning_pool or {}
    if runtime._behavior_warning_pool[key] then
        return
    end
    runtime._behavior_warning_pool[key] = true
    LogManager.log(message, "warning")
end

local function _should_log_missing_entry(event_type, action)
    event_type = tostring(event_type or "")
    local action_kind = _trim(action and action.kind) or "none"
    local has_explicit_flow = type(action) == "table"
        and (action.flow ~= nil or _trim(action.entry) ~= nil)
    local has_explicit_event_name = type(action) == "table"
        and _trim(action.event_name) ~= nil

    if event_type == "on_click" then
        if action_kind == "open_save_panel"
            or action_kind == "open_load_panel"
        then
            return false
        end
        return action_kind == "run_flow"
            or has_explicit_flow
            or has_explicit_event_name
    end

    return has_explicit_flow or has_explicit_event_name
end

local function _get_panel_action_hint(action_kind)
    if action_kind == "open_save_panel" then
        return "该按钮会打开系统存档面板；若要直接存档，请把点击动作改为“快速存档”或“保存存档”。"
    end
    if action_kind == "open_load_panel" then
        return "该按钮会打开系统读档面板；若要直接读档，请把点击动作改为“快速读档”或“读取存档”。"
    end
    return nil
end

local function _normalize_reentry_policy(value)
    local policy = _trim(value) or "repeatable"
    if policy == "ignore" then
        return "once"
    end
    if policy == "restart" or policy == "queue" then
        return "repeatable"
    end
    if policy ~= "once" and policy ~= "repeatable" then
        return "repeatable"
    end
    return policy
end

local function _normalize_auto_advance_interval(value)
    local interval = tonumber(value) or 1.0
    if interval < 0.1 then
        interval = 0.1
    end
    if interval > 60 then
        interval = 60
    end
    return interval
end

local supported_click_action_kind_pool =
{
    none = true,
    close_ui = true,
    open_ui = true,
    quick_save = true,
    quick_load = true,
    return_value = true,
    fast_forward = true,
    auto_advance = true,
    rollback = true,
}

local function _normalize_click_action_kind(kind)
    local kind_id = _trim(kind) or "none"
    if supported_click_action_kind_pool[kind_id] ~= true then
        kind_id = "none"
    end
    return kind_id
end

local function _is_focusable_widget(widget)
    return widget ~= nil
        and (widget.type == "Button"
            or widget.type == "Toggle"
            or widget.type == "Slider"
            or widget.type == "SaveSlotGrid")
end

local function _is_pressable_widget(widget)
    return widget ~= nil
        and (widget.type == "Button"
            or widget.type == "Toggle"
            or widget.type == "Slider"
            or widget.type == "SaveSlotGrid")
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

local function _clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function _normalize_vec2(value, default_x, default_y)
    if type(value) == "userdata" then
        return
        {
            x = tonumber(value.x) or default_x or 0,
            y = tonumber(value.y) or default_y or 0,
        }
    end

    if type(value) ~= "table" then
        return {x = default_x or 0, y = default_y or 0}
    end

    return
    {
        x = tonumber(value.x) or tonumber(value[1]) or default_x or 0,
        y = tonumber(value.y) or tonumber(value[2]) or default_y or 0,
    }
end

local function _normalize_padding(value)
    if type(value) ~= "table" then
        return {left = 0, top = 0, right = 0, bottom = 0}
    end

    return
    {
        left = tonumber(value.left) or tonumber(value[1]) or 0,
        top = tonumber(value.top) or tonumber(value[2]) or 0,
        right = tonumber(value.right) or tonumber(value[3]) or 0,
        bottom = tonumber(value.bottom) or tonumber(value[4]) or 0,
    }
end

local function _round(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

local function _normalize_color(value, default_alpha)
    if type(value) == "userdata" then
        return
        {
            r = tonumber(value.x) or 1,
            g = tonumber(value.y) or 1,
            b = tonumber(value.z) or 1,
            a = tonumber(value.w) or default_alpha or 1,
        }
    end

    if type(value) ~= "table" then
        return {r = 1, g = 1, b = 1, a = default_alpha or 1}
    end

    return
    {
        r = tonumber(value.r) or tonumber(value.x) or tonumber(value[1]) or 1,
        g = tonumber(value.g) or tonumber(value.y) or tonumber(value[2]) or 1,
        b = tonumber(value.b) or tonumber(value.z) or tonumber(value[3]) or 1,
        a = tonumber(value.a) or tonumber(value.w) or tonumber(value[4]) or default_alpha or 1,
    }
end

local function _mul_color_alpha(color, alpha)
    local normalized = _normalize_color(color, 1)
    normalized.a = normalized.a * (alpha or 1)
    return normalized
end

local function _to_rl_color(color, extra_alpha)
    local value = _mul_color_alpha(color, extra_alpha or 1)
    return rl.Color(
        _clamp(math.floor(value.r * 255 + 0.5), 0, 255),
        _clamp(math.floor(value.g * 255 + 0.5), 0, 255),
        _clamp(math.floor(value.b * 255 + 0.5), 0, 255),
        _clamp(math.floor(value.a * 255 + 0.5), 0, 255))
end

local function _copy_rect(rect)
    if not rect then
        return nil
    end

    return
    {
        x = rect.x,
        y = rect.y,
        w = rect.w,
        h = rect.h,
    }
end

local function _make_rect(x, y, w, h)
    return {x = x, y = y, w = w, h = h}
end

local function _rect_contains(rect, x, y)
    if not rect then
        return false
    end
    return x >= rect.x and y >= rect.y and x <= rect.x + rect.w and y <= rect.y + rect.h
end

local function _rect_intersection(left, right)
    if not left then
        return _copy_rect(right)
    end
    if not right then
        return _copy_rect(left)
    end

    local x1 = math.max(left.x, right.x)
    local y1 = math.max(left.y, right.y)
    local x2 = math.min(left.x + left.w, right.x + right.w)
    local y2 = math.min(left.y + left.h, right.y + right.h)
    if x2 <= x1 or y2 <= y1 then
        return _make_rect(x1, y1, 0, 0)
    end
    return _make_rect(x1, y1, x2 - x1, y2 - y1)
end

local function _inset_rect(rect, padding)
    padding = _normalize_padding(padding)
    return
    {
        x = rect.x + padding.left,
        y = rect.y + padding.top,
        w = math.max(0, rect.w - padding.left - padding.right),
        h = math.max(0, rect.h - padding.top - padding.bottom),
    }
end

local function _get_responsive_layout_scale(widget)
    local instance = widget and widget.instance or nil
    local layout_scale = instance and instance._responsive_layout_scale or nil
    if type(layout_scale) ~= "table" then
        return nil
    end
    return layout_scale
end

local function _scale_layout_offset(widget, value)
    local offset = _normalize_vec2(value, 0, 0)
    local layout_scale = _get_responsive_layout_scale(widget)
    if not layout_scale then
        return offset
    end
    return
    {
        x = offset.x * layout_scale.x,
        y = offset.y * layout_scale.y,
    }
end

local function _compute_anchor_rect(parent_rect, widget)
    local props = widget and widget.props or {}
    local anchor_min = _normalize_vec2(props.anchor_min, 0, 0)
    local anchor_max = _normalize_vec2(props.anchor_max, 0, 0)
    local offset_min = _scale_layout_offset(widget, props.offset_min)
    local offset_max = _scale_layout_offset(widget, props.offset_max)

    local x = parent_rect.x + parent_rect.w * anchor_min.x + offset_min.x
    local y = parent_rect.y + parent_rect.h * anchor_min.y + offset_min.y
    local right = parent_rect.x + parent_rect.w * anchor_max.x + offset_max.x
    local bottom = parent_rect.y + parent_rect.h * anchor_max.y + offset_max.y

    return
    {
        x = x,
        y = y,
        w = right - x,
        h = bottom - y,
    }
end

local function _normalize_corner_roundness(value)
    return _clamp((tonumber(value) or 0) / 100, 0, 1)
end

local function _draw_rectangle(rect, color, corner_roundness)
    if not rect or rect.w <= 0 or rect.h <= 0 then
        return
    end

    local roundness = _clamp(tonumber(corner_roundness) or 0, 0, 1)
    if roundness > 0 and type(rl.DrawRectangleRounded) == "function" then
        rl.DrawRectangleRounded(
            rl.Rectangle(
                math.floor(rect.x + 0.5),
                math.floor(rect.y + 0.5),
                math.max(0, math.floor(rect.w + 0.5)),
                math.max(0, math.floor(rect.h + 0.5))),
            roundness,
            12,
            color)
        return
    end

    rl.DrawRectangle(
        math.floor(rect.x + 0.5),
        math.floor(rect.y + 0.5),
        math.max(0, math.floor(rect.w + 0.5)),
        math.max(0, math.floor(rect.h + 0.5)),
        color)
end

local function _draw_border(rect, thickness, color, corner_roundness)
    local width = math.max(1, math.floor(tonumber(thickness) or 1))
    local x = math.floor(rect.x + 0.5)
    local y = math.floor(rect.y + 0.5)
    local w = math.max(1, math.floor(rect.w + 0.5))
    local h = math.max(1, math.floor(rect.h + 0.5))
    local roundness = _clamp(tonumber(corner_roundness) or 0, 0, 1)

    if roundness > 0 and type(rl.DrawRectangleRoundedLinesEx) == "function" then
        rl.DrawRectangleRoundedLinesEx(
            rl.Rectangle(x, y, w, h),
            roundness,
            12,
            width,
            color)
        return
    end

    rl.DrawRectangle(x, y, w, width, color)
    rl.DrawRectangle(x, y + h - width, w, width, color)
    rl.DrawRectangle(x, y, width, h, color)
    rl.DrawRectangle(x + w - width, y, width, h, color)
end

local rounded_texture_shader_source <const> = [[
#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec2 u_size;
uniform float u_radius;

out vec4 finalColor;

void main()
{
    vec4 texel = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    vec2 size = max(u_size, vec2(1.0, 1.0));
    float radius = clamp(u_radius, 0.0, min(size.x, size.y) * 0.5);
    vec2 halfSize = size * 0.5;
    vec2 point = fragTexCoord * size;
    vec2 q = abs(point - halfSize) - (halfSize - vec2(radius));
    float distanceToEdge = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
    float aa = max(fwidth(distanceToEdge), 0.75);
    float mask = 1.0 - smoothstep(-aa, aa, distanceToEdge);
    finalColor = vec4(texel.rgb, texel.a * mask);
}
]]

local rounded_texture_shader = nil
local rounded_texture_shader_failed = false
local rounded_texture_render_target = nil
local rounded_texture_render_target_width = 0
local rounded_texture_render_target_height = 0

local function _get_rounded_texture_shader()
    if rounded_texture_shader_failed then
        return nil
    end
    if rounded_texture_shader then
        return rounded_texture_shader
    end

    local ok, shader = pcall(ShaderWrapper.new,
    {
        vertex_source = nil,
        fragment_source = rounded_texture_shader_source,
    })
    if ok and shader and shader:is_valid() then
        rounded_texture_shader = shader
        return rounded_texture_shader
    end

    rounded_texture_shader_failed = true
    if LogManager and LogManager.log then
        LogManager.log(string.format("UI rounded texture shader unavailable: %s", tostring(shader)), "warning")
    end
    return nil
end

local function _release_rounded_texture_render_target()
    if rounded_texture_render_target and type(rl.UnloadRenderTexture) == "function" then
        pcall(rl.UnloadRenderTexture, rounded_texture_render_target)
    end
    rounded_texture_render_target = nil
    rounded_texture_render_target_width = 0
    rounded_texture_render_target_height = 0
end

local function _get_rounded_texture_render_target(width, height)
    if type(rl.LoadRenderTexture) ~= "function" then
        return nil
    end

    width = math.max(1, math.floor((tonumber(width) or 1) + 0.5))
    height = math.max(1, math.floor((tonumber(height) or 1) + 0.5))
    if rounded_texture_render_target
        and rounded_texture_render_target_width == width
        and rounded_texture_render_target_height == height
        and (type(rl.IsRenderTextureValid) ~= "function" or rl.IsRenderTextureValid(rounded_texture_render_target) == true)
    then
        return rounded_texture_render_target, width, height
    end

    _release_rounded_texture_render_target()

    local ok, target = pcall(rl.LoadRenderTexture, width, height)
    if ok and target and (type(rl.IsRenderTextureValid) ~= "function" or rl.IsRenderTextureValid(target) == true) then
        rounded_texture_render_target = target
        rounded_texture_render_target_width = width
        rounded_texture_render_target_height = height
        return rounded_texture_render_target, width, height
    end

    return nil
end

local function _draw_texture_pro(texture, draw_rect, alpha, source_rect)
    rl.DrawTexturePro(
        texture,
        source_rect or rl.Rectangle(0, 0, math.max(1, tonumber(texture.width) or 1), math.max(1, tonumber(texture.height) or 1)),
        rl.Rectangle(draw_rect.x, draw_rect.y, draw_rect.w, draw_rect.h),
        rl.Vector2(0, 0),
        0,
        _to_rl_color({r = 1, g = 1, b = 1, a = 1}, alpha))
end

local function _draw_texture_rounded(texture, draw_rect, alpha, corner_roundness, source_rect)
    local roundness = _clamp(tonumber(corner_roundness) or 0, 0, 1)
    if not texture or not draw_rect or draw_rect.w <= 0 or draw_rect.h <= 0 then
        return
    end
    if roundness <= 0 then
        _draw_texture_pro(texture, draw_rect, alpha, source_rect)
        return
    end

    local shader = _get_rounded_texture_shader()
    if not shader then
        _draw_texture_pro(texture, draw_rect, alpha, source_rect)
        return
    end

    shader:use()
    shader:set("u_size", rl.Vector2(math.max(1, draw_rect.w), math.max(1, draw_rect.h)))
    shader:set("u_radius", math.min(draw_rect.w, draw_rect.h) * 0.5 * roundness)
    local ok, err = pcall(_draw_texture_pro, texture, draw_rect, alpha, source_rect)
    shader:unuse()
    if not ok then
        error(err, 0)
    end
end

local function _draw_texture_with_shader(texture, draw_rect, alpha, shader, context)
    ShaderRuntime.draw_with_shader(shader, function()
        _draw_texture_pro(texture, draw_rect, alpha)
    end, context)
end

local function _draw_texture_with_shader_rounded(texture, draw_rect, alpha, corner_roundness, shader, context)
    local roundness = _clamp(tonumber(corner_roundness) or 0, 0, 1)
    if roundness <= 0 then
        _draw_texture_with_shader(texture, draw_rect, alpha, shader, context)
        return
    end

    local target, target_width, target_height = _get_rounded_texture_render_target(draw_rect.w, draw_rect.h)
    if not target or type(rl.BeginTextureMode) ~= "function" or type(rl.EndTextureMode) ~= "function" then
        _draw_texture_with_shader(texture, draw_rect, alpha, shader, context)
        return
    end

    local did_begin = false
    local ok, err = xpcall(function()
        rl.BeginTextureMode(target)
        did_begin = true
        rl.ClearBackground(rl.Color(0, 0, 0, 0))
        _draw_texture_with_shader(
            texture,
            _make_rect(0, 0, target_width, target_height),
            alpha,
            shader,
            context)
    end, debug.traceback)
    if did_begin then
        rl.EndTextureMode()
    end
    if not ok then
        error(err, 0)
    end

    _draw_texture_rounded(
        target.texture,
        draw_rect,
        1,
        corner_roundness,
        rl.Rectangle(0, 0, target_width, -target_height))
end

local function _normalize_runtime_document_options(options)
    options = type(options) == "table" and options or {}
    return
    {
        allow_unsaved_snapshot = options.allow_unsaved_snapshot == true,
    }
end

local function _resolve_runtime_document(reference, options)
    local resolve_options = _normalize_runtime_document_options(options)
    local manager_ok, manager = pcall(require, "application.framework.ui_workspace_manager")
    if manager_ok and type(manager) == "table" and type(manager.resolve_runtime_document) == "function" then
        local runtime_info, err = manager.resolve_runtime_document(reference, resolve_options)
        if runtime_info then
            return runtime_info, nil
        end
        if err ~= "找不到界面资源" then
            return nil, err
        end
    end

    local ResourceIndex = require("application.framework.resource_index")
    local guid = ResourceIndex.resolve_guid("ui", reference)
    if not guid then
        return nil, "找不到界面资源"
    end
    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return nil, "找不到界面资源"
    end

    local document, err = UI.load(meta.path)
    if not document then
        return nil, err or "无法加载界面文件"
    end

    return
    {
        guid = guid,
        path = meta.path,
        document = document,
    }, nil
end

local function _make_runtime_instance_label(entry, runtime_info)
    local instance_id = tostring(entry and entry.instance_id or "")
    local source_label = tostring(
        (runtime_info and (runtime_info.guid or runtime_info.path))
        or (entry and (entry.source_guid or entry.source_path))
        or "ui")
    if instance_id ~= "" then
        return string.format("%s (%s)", instance_id, source_label)
    end
    return source_label
end

local function _collect_runtime_widget_id_pool(document_snapshot)
    local widget_id_pool = {}
    UI.walk_widgets(document_snapshot, function(widget)
        widget_id_pool[widget.id] = true
        return false
    end)
    return widget_id_pool
end

local function _validate_runtime_flow_reference(reference)
    local ResourceIndex = require("application.framework.resource_index")
    local guid = ResourceIndex.resolve_guid("flow", reference)
    if not guid then
        return false, "找不到界面行为流程资源"
    end

    local meta = ResourceIndex.find_by_guid(guid)
    if not meta then
        return false, "界面行为流程资源不存在"
    end

    local flow_manager = _get_flow_manager()
    if type(flow_manager.create_runtime_document_snapshot) == "function" then
        local document = flow_manager.create_runtime_document_snapshot(reference,
        {
            usage = "flow_runtime",
        })
        if not document then
            return false, "无法加载界面行为流程"
        end
        if document.dispose then
            document:dispose()
        end
    end

    return true
end

local function _validate_runtime_document_dependencies(runtime_info, entry)
    local document_snapshot = runtime_info and runtime_info.document or nil
    if type(document_snapshot) ~= "table" then
        return false, "界面文档快照无效"
    end

    local instance_label = _make_runtime_instance_label(entry, runtime_info)
    local behavior_flow = type(entry) == "table" and entry.behavior_flow or nil
    if behavior_flow then
        local flow_ok, flow_err = _validate_runtime_flow_reference(behavior_flow)
        if not flow_ok then
            return false, string.format("界面实例 %s 的行为流程无法恢复：%s", instance_label, tostring(flow_err))
        end
    end

    local widget_state = type(entry) == "table" and entry.widget_state or nil
    if type(widget_state) == "table" then
        local widget_id_pool = _collect_runtime_widget_id_pool(document_snapshot)
        local missing_widget_id_list = {}
        local missing_count = 0
        for widget_id in pairs(widget_state) do
            if not widget_id_pool[widget_id] then
                missing_count = missing_count + 1
                if #missing_widget_id_list < 5 then
                    missing_widget_id_list[#missing_widget_id_list + 1] = tostring(widget_id)
                end
            end
        end
        if missing_count > 0 then
            local preview_text = #missing_widget_id_list > 0 and table.concat(missing_widget_id_list, ", ") or "unknown"
            if missing_count > #missing_widget_id_list then
                preview_text = string.format("%s ...", preview_text)
            end
            return false, string.format("界面实例 %s 有 %d 组件状态无法映射到当前文档：%s",
                instance_label,
                missing_count,
                preview_text)
        end
    end

    return true
end

local function _destroy_widget_runtime(widget)
    if not widget then
        return
    end

    for _, child in ipairs(widget.children or {}) do
        _destroy_widget_runtime(child)
    end

    if widget.text_wrapper and widget.text_wrapper.dispose then
        widget.text_wrapper:dispose()
        widget.text_wrapper = nil
    end
    if type(widget.text_wrapper_pool) == "table" then
        for key, wrapper in pairs(widget.text_wrapper_pool) do
            if wrapper and wrapper.dispose then
                wrapper:dispose()
            end
            widget.text_wrapper_pool[key] = nil
        end
    end
end

local function _build_runtime_widget(instance, widget_data, parent)
    local widget =
    {
        instance = instance,
        id = widget_data.id,
        name = widget_data.name,
        type = widget_data.type,
        props = UI.clone(widget_data.props or {}),
        events = UI.clone(widget_data.events or {}),
        parent = parent,
        children = {},
        rect = _make_rect(0, 0, 0, 0),
        content_rect = _make_rect(0, 0, 0, 0),
        layout_parent_rect = nil,
        clip_rect = nil,
        hovered = false,
        pressed = false,
        text_wrapper = nil,
        _text_signature = nil,
        scroll_max_y = 0,
        scroll_max_y_design = 0,
    }

    instance.widget_by_id[widget.id] = widget
    for _, child_data in ipairs(widget_data.children or {}) do
        table.insert(widget.children, _build_runtime_widget(instance, child_data, widget))
    end
    return widget
end

local function _try_get_instance_style_value(instance, domain, key, expected_type_id)
    if not instance or not instance.style_sheet then
        return nil, false
    end

    local style_domain = instance.style_sheet.domains and instance.style_sheet.domains[domain] or nil
    local field = style_domain and style_domain.fields and style_domain.fields[key] or nil
    if not field or field.has_value ~= true then
        return nil, false
    end

    if expected_type_id and field.type_id ~= expected_type_id then
        return nil, false
    end

    return _clone_value(field.value), true
end

local responsive_vec2_key_pool =
{
    preferred_size = true,
    min_size = true,
}

local responsive_float_key_pool =
{
    gap = "uniform",
    gap_x = "x",
    gap_y = "y",
    border_thickness = "uniform",
    scroll_content_height = "y",
}

local function _scale_responsive_number(value, scale)
    local number = tonumber(value)
    if number == nil then
        return value
    end
    return number * scale
end

local function _scale_responsive_property(widget, key, value, property_def)
    local layout_scale = _get_responsive_layout_scale(widget)
    if type(layout_scale) ~= "table" or value == nil or not property_def then
        return value
    end

    if property_def.type_id == "vec2" and responsive_vec2_key_pool[key] then
        local vec = _normalize_vec2(value, 0, 0)
        return
        {
            x = vec.x * layout_scale.x,
            y = vec.y * layout_scale.y,
        }
    end

    if property_def.type_id == "padding" and key == "padding" then
        local padding = _normalize_padding(value)
        return
        {
            left = padding.left * layout_scale.x,
            top = padding.top * layout_scale.y,
            right = padding.right * layout_scale.x,
            bottom = padding.bottom * layout_scale.y,
        }
    end

    if (property_def.type_id == "int" or property_def.type_id == "float") and key == "font_size" then
        return math.max(1, _round(_scale_responsive_number(value, layout_scale.font)))
    end

    if property_def.type_id == "float" and responsive_float_key_pool[key] then
        local axis = responsive_float_key_pool[key]
        local scale = axis == "x" and layout_scale.x or axis == "y" and layout_scale.y or layout_scale.uniform
        return _scale_responsive_number(value, scale)
    end

    return value
end

local function _resolve_widget_prop(widget, key)
    local property_def = UIWidgetRegistry.get_property(widget.type, key)
    local domain = _trim(widget.props and widget.props.style_domain or nil)
    if domain and property_def then
        local style_value, ok = StyleManager.try_get_value(domain, key, property_def.type_id)
        if ok then
            return _scale_responsive_property(widget, key, style_value, property_def)
        end
        local themed_value, themed_ok = _try_get_instance_style_value(widget.instance, domain, key, property_def.type_id)
        if themed_ok then
            return _scale_responsive_property(widget, key, themed_value, property_def)
        end
    end
    return _scale_responsive_property(widget, key, widget.props and widget.props[key] or nil, property_def)
end

local function _get_widget_corner_roundness(widget)
    if not widget or widget.type == "Canvas" or widget.type == "Text" or widget.type == "SaveSlotGrid" then
        return 0
    end
    return _normalize_corner_roundness(_resolve_widget_prop(widget, "corner_radius"))
end

local function _get_widget_raw_prop(widget, key)
    if widget and type(widget.props) == "table" and widget.props[key] ~= nil then
        return widget.props[key], true
    end
    return nil, false
end

local function _get_image_fit_mode(widget)
    local mode = _trim(_resolve_widget_prop(widget, "image_fit_mode"))
    if mode == "fill" then
        return "fill"
    end
    if mode == "preserve_aspect" then
        return "preserve_aspect"
    end
    return "preserve_aspect"
end

local function _should_show_progress(widget)
    local value, ok = _get_widget_raw_prop(widget, "show_progress")
    if ok then
        return value == true
    end
    return _resolve_widget_prop(widget, "show_progress") ~= false
end

local function _normalize_consume_input_mode(value)
    local mode = _trim(value) or "block"
    if mode == "auto" or mode == "always" then
        return "block"
    end
    if mode == "never" then
        return "pass"
    end
    if mode ~= "block" and mode ~= "pass" then
        return "block"
    end
    return mode
end

local function _is_hit_test_enabled(widget)
    return widget ~= nil and _resolve_widget_prop(widget, "hit_test_enabled") ~= false
end

local function _blocks_background_input(widget)
    return widget ~= nil and _resolve_widget_prop(widget, "block_background_input") == true
end

local function _find_background_input_blocker(widget)
    local current = widget
    while current do
        if _blocks_background_input(current) then
            return current
        end
        current = current.parent
    end
    return nil
end

local function _has_widget_event_bindings(widget)
    if type(widget) ~= "table" or type(widget.events) ~= "table" then
        return false
    end

    for _, action in pairs(widget.events) do
        if type(action) == "table"
            and (_trim(action.kind)
                or _trim(action.target)
                or _trim(action.message)
                or _trim(action.event_name)
                or action.ui ~= nil
                or action.flow ~= nil
                or _trim(action.entry)
                or _trim(action.instance_id))
        then
            return true
        end
    end
    return false
end

local function _is_input_target_widget(widget)
    if not widget then
        return false
    end
    if _blocks_background_input(widget) then
        return true
    end
    if not _is_hit_test_enabled(widget) then
        return false
    end

    return _is_focusable_widget(widget)
        or widget.type == "ScrollView"
        or _has_widget_event_bindings(widget)
        or _normalize_consume_input_mode(_resolve_widget_prop(widget, "consume_input")) == "block"
end

local function _should_consume_pointer_input(widget)
    if not widget then
        return false
    end
    if _blocks_background_input(widget) then
        return true
    end
    if not _is_hit_test_enabled(widget) then
        return false
    end

    local mode = _normalize_consume_input_mode(_resolve_widget_prop(widget, "consume_input"))
    if mode == "block" then
        return true
    end
    if mode == "pass" then
        return false
    end
    return true
end

local function _should_consume_submit_input(widget)
    if not widget or not _is_hit_test_enabled(widget) then
        return false
    end

    local mode = _normalize_consume_input_mode(_resolve_widget_prop(widget, "consume_input"))
    if mode == "block" then
        return true
    end
    if mode == "pass" then
        return false
    end
    return true
end

local function _should_consume_wheel_input(widget)
    if not widget then
        return false
    end
    if _blocks_background_input(widget) then
        return true
    end
    if not _is_hit_test_enabled(widget) then
        return false
    end

    local mode = _normalize_consume_input_mode(_resolve_widget_prop(widget, "consume_input"))
    if mode == "block" then
        return true
    end
    if mode == "pass" then
        return false
    end
    return true
end

local function _resolve_font(value)
    if type(value) == "table" or type(value) == "userdata" then
        if type(value.get) == "function" or (getmetatable(value) and getmetatable(value).__index and getmetatable(value).__index.get) then
            return value
        end
    end
    return value and ResourcesManager.find_font(value) or GlobalContext.font_wrapper_sdl
end

local function _resolve_texture(value)
    if type(value) == "table" or type(value) == "userdata" then
        if value.width and value.height then
            return value
        end
    end
    return value and ResourcesManager.find_texture(value) or nil
end

local function _clear_widget_text_wrapper(widget)
    if widget and widget.text_wrapper and widget.text_wrapper.dispose then
        widget.text_wrapper:dispose()
        widget.text_wrapper = nil
        widget._text_signature = nil
    end
end

local function _ensure_text_wrapper(widget, text, font_wrapper, font_size, color, wrap_len)
    if not font_wrapper or type(font_wrapper.get) ~= "function" then
        return nil
    end
    local resolved_font_size = math.max(1, math.floor(tonumber(font_size) or 1))

    local signature = table.concat(
    {
        tostring(text or ""),
        tostring(font_wrapper),
        tostring(resolved_font_size),
        tostring(TextWrapper.get_wrap_signature_value(wrap_len)),
        tostring(color.r),
        tostring(color.g),
        tostring(color.b),
        tostring(color.a),
    }, "|")

    if widget._text_signature ~= signature then
        if widget.text_wrapper and widget.text_wrapper.dispose then
            widget.text_wrapper:dispose()
            widget.text_wrapper = nil
        end
        widget.text_wrapper = TextWrapper.new(font_wrapper, tostring(text or ""), color, wrap_len, resolved_font_size)
        widget._text_signature = signature
    end

    return widget.text_wrapper
end

local function _ensure_text_wrapper_keyed(widget, key, text, font_wrapper, font_size, color, wrap_len)
    if not font_wrapper or type(font_wrapper.get) ~= "function" then
        return nil
    end
    widget.text_wrapper_pool = widget.text_wrapper_pool or {}
    widget._text_signature_pool = widget._text_signature_pool or {}
    local resolved_font_size = math.max(1, math.floor(tonumber(font_size) or 1))
    local signature = table.concat(
    {
        tostring(text or ""),
        tostring(font_wrapper),
        tostring(resolved_font_size),
        tostring(TextWrapper.get_wrap_signature_value(wrap_len)),
        tostring(color.r),
        tostring(color.g),
        tostring(color.b),
        tostring(color.a),
    }, "|")
    if widget._text_signature_pool[key] ~= signature then
        local old_wrapper = widget.text_wrapper_pool[key]
        if old_wrapper and old_wrapper.dispose then
            old_wrapper:dispose()
        end
        widget.text_wrapper_pool[key] = TextWrapper.new(font_wrapper, tostring(text or ""), color, wrap_len, resolved_font_size)
        widget._text_signature_pool[key] = signature
    end
    return widget.text_wrapper_pool[key]
end

local function _refresh_text_wrapper_for_content_rect(widget)
    if not widget or widget.type ~= "Text" or not widget.content_rect then
        return nil
    end

    local color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
    local wrap_len = widget.content_rect.w > 0 and math.max(1, math.floor(widget.content_rect.w + 0.5)) or nil
    return _ensure_text_wrapper(
        widget,
        _resolve_widget_prop(widget, "text") or "",
        _resolve_font(_resolve_widget_prop(widget, "font")),
        tonumber(_resolve_widget_prop(widget, "font_size")) or 28,
        color,
        wrap_len)
end

local function _draw_text_keyed(widget, key, text, rect, font_size, color, alpha, align_x, align_y)
    if not rect or rect.w <= 0 or rect.h <= 0 then
        return
    end
    local wrapper = _ensure_text_wrapper_keyed(
        widget,
        key,
        text,
        GlobalContext.font_wrapper_sdl,
        font_size,
        color,
        math.max(1, math.floor(rect.w + 0.5)))
    if not wrapper or not wrapper.texture then
        return
    end
    local x = rect.x
    local y = rect.y
    if align_x == "center" then
        x = rect.x + (rect.w - wrapper.w) * 0.5
    elseif align_x == "end" then
        x = rect.x + rect.w - wrapper.w
    end
    if align_y == "center" then
        y = rect.y + (rect.h - wrapper.h) * 0.5
    elseif align_y == "end" then
        y = rect.y + rect.h - wrapper.h
    end
    rl.DrawTextureV(wrapper.texture, rl.Vector2(x, y), _to_rl_color(color, alpha))
end

local function _measure_widget_intrinsic(widget, width_hint)
    if widget.type == "Text" then
        local color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
        local wrap_len = width_hint and width_hint > 0 and math.max(1, math.floor(width_hint + 0.5)) or nil
        local wrapper = _ensure_text_wrapper(
            widget,
            _resolve_widget_prop(widget, "text") or "",
            _resolve_font(_resolve_widget_prop(widget, "font")),
            tonumber(_resolve_widget_prop(widget, "font_size")) or 28,
            color,
            wrap_len)
        if wrapper then
            return wrapper.w, wrapper.h
        end
        return 0, tonumber(_resolve_widget_prop(widget, "font_size")) or 28
    end

    if widget.type == "Button" then
        local padding = _normalize_padding(_resolve_widget_prop(widget, "padding"))
        local color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
        local wrapper = _ensure_text_wrapper(
            widget,
            _resolve_widget_prop(widget, "text") or "",
            _resolve_font(_resolve_widget_prop(widget, "font")),
            tonumber(_resolve_widget_prop(widget, "font_size")) or 28,
            color,
            nil)
        local text_w = wrapper and wrapper.w or 0
        local text_h = wrapper and wrapper.h or (tonumber(_resolve_widget_prop(widget, "font_size")) or 28)
        return text_w + padding.left + padding.right, text_h + padding.top + padding.bottom
    end

    if widget.type == "Toggle" then
        local padding = _normalize_padding(_resolve_widget_prop(widget, "padding"))
        local font_size = tonumber(_resolve_widget_prop(widget, "font_size")) or 26
        local color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
        local wrapper = _ensure_text_wrapper(
            widget,
            _resolve_widget_prop(widget, "text") or "",
            _resolve_font(_resolve_widget_prop(widget, "font")),
            font_size,
            color,
            nil)
        local text_w = wrapper and wrapper.w or 0
        local text_h = wrapper and wrapper.h or font_size
        return text_w + padding.left + padding.right, text_h + padding.top + padding.bottom
    end

    if widget.type == "ProgressBar" then
        local preferred = _normalize_vec2(_resolve_widget_prop(widget, "preferred_size"), 240, 36)
        if _should_show_progress(widget) then
            local min_value = tonumber(_resolve_widget_prop(widget, "min_value")) or 0
            local max_value = tonumber(_resolve_widget_prop(widget, "max_value")) or 1
            local raw_value = tonumber(_resolve_widget_prop(widget, "value")) or min_value
            local ratio = max_value ~= min_value and _clamp((raw_value - min_value) / (max_value - min_value), 0, 1) or 0
            local text_color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
            _ensure_text_wrapper(
                widget,
                string.format("%d%%", math.floor(ratio * 100 + 0.5)),
                _resolve_font(_resolve_widget_prop(widget, "font")),
                tonumber(_resolve_widget_prop(widget, "font_size")) or 22,
                text_color,
                nil)
        else
            _clear_widget_text_wrapper(widget)
        end
        return math.max(160, preferred.x), math.max(24, preferred.y)
    end

    local preferred = _normalize_vec2(_resolve_widget_prop(widget, "preferred_size"), 0, 0)
    return preferred.x, preferred.y
end

local function _apply_intrinsic_size(widget, rect, parent_rect)
    local preferred = _normalize_vec2(_resolve_widget_prop(widget, "preferred_size"), 0, 0)
    local min_size = _normalize_vec2(_resolve_widget_prop(widget, "min_size"), 0, 0)
    local width_hint = rect.w > 0 and rect.w or preferred.x
    local intrinsic_w, intrinsic_h = _measure_widget_intrinsic(widget, width_hint)

    local width = rect.w
    local height = rect.h
    if width <= 0 then
        width = math.max(min_size.x, preferred.x, intrinsic_w)
    end
    if height <= 0 then
        height = math.max(min_size.y, preferred.y, intrinsic_h)
    end

    local pivot = _normalize_vec2(_resolve_widget_prop(widget, "pivot"), 0, 0)
    if rect.w <= 0 then
        rect.x = rect.x - width * pivot.x
    end
    if rect.h <= 0 then
        rect.y = rect.y - height * pivot.y
    end

    rect.w = width
    rect.h = height

    return rect
end

local function _layout_widget_tree(widget, parent_content_rect, ordered_widget_list, inherited_clip_rect)
    widget.layout_parent_rect = _copy_rect(parent_content_rect)
    local rect = widget._layout_override and _copy_rect(widget._layout_override) or _compute_anchor_rect(parent_content_rect, widget)
    widget._layout_override = nil
    rect = _apply_intrinsic_size(widget, rect, parent_content_rect)

    widget.rect = rect
    widget.visible = _resolve_widget_prop(widget, "visible") ~= false and rect.w > 0 and rect.h > 0
    local padding = _normalize_padding(_resolve_widget_prop(widget, "padding"))
    widget.content_rect = _inset_rect(rect, padding)
    widget.clip_rect = inherited_clip_rect and _rect_intersection(inherited_clip_rect, rect) or _copy_rect(rect)
    _refresh_text_wrapper_for_content_rect(widget)
    table.insert(ordered_widget_list, widget)

    if #widget.children == 0 then
        return
    end

    if widget.type == "VerticalContainer" or widget.type == "HorizontalContainer" then
        local is_vertical = widget.type == "VerticalContainer"
        local gap = tonumber(_resolve_widget_prop(widget, "gap")) or 0
        local cross_align = tostring(_resolve_widget_prop(widget, "cross_align") or "stretch")
        local content_rect = widget.content_rect
        local stretch_count = 0
        local fixed_main_total = 0
        local desired_size_pool = {}

        for index, child in ipairs(widget.children) do
            local preferred = _normalize_vec2(_resolve_widget_prop(child, "preferred_size"), 0, 0)
            local min_size = _normalize_vec2(_resolve_widget_prop(child, "min_size"), 0, 0)
            local intrinsic_w, intrinsic_h = _measure_widget_intrinsic(child, content_rect.w)
            local desired_w = math.max(preferred.x, min_size.x, intrinsic_w)
            local desired_h = math.max(preferred.y, min_size.y, intrinsic_h)
            desired_size_pool[index] = {w = desired_w, h = desired_h}

            if _resolve_widget_prop(child, "layout_stretch") == true then
                stretch_count = stretch_count + 1
            else
                fixed_main_total = fixed_main_total + (is_vertical and desired_h or desired_w)
            end
        end

        local total_gap = math.max(0, (#widget.children - 1) * gap)
        local available_main = is_vertical and content_rect.h or content_rect.w
        local remaining = math.max(0, available_main - fixed_main_total - total_gap)
        local stretch_main = stretch_count > 0 and (remaining / stretch_count) or 0
        local cursor = is_vertical and content_rect.y or content_rect.x

        for index, child in ipairs(widget.children) do
            local desired = desired_size_pool[index]
            local cross_available = is_vertical and content_rect.w or content_rect.h
            local child_w = desired.w
            local child_h = desired.h
            if _resolve_widget_prop(child, "layout_stretch") == true then
                if is_vertical then
                    child_h = math.max(child_h, stretch_main)
                else
                    child_w = math.max(child_w, stretch_main)
                end
            end

            local child_x = content_rect.x
            local child_y = content_rect.y

            if is_vertical then
                child_y = cursor
                if cross_align == "stretch" then
                    child_w = cross_available
                elseif cross_align == "center" then
                    child_x = content_rect.x + (cross_available - child_w) * 0.5
                elseif cross_align == "end" then
                    child_x = content_rect.x + cross_available - child_w
                end
                cursor = cursor + child_h + gap
            else
                child_x = cursor
                if cross_align == "stretch" then
                    child_h = cross_available
                elseif cross_align == "center" then
                    child_y = content_rect.y + (cross_available - child_h) * 0.5
                elseif cross_align == "end" then
                    child_y = content_rect.y + cross_available - child_h
                end
                cursor = cursor + child_w + gap
            end

            child._layout_override = _make_rect(child_x, child_y, child_w, child_h)
            _layout_widget_tree(child, widget.content_rect, ordered_widget_list, widget.clip_rect)
        end
        return
    end

    if widget.type == "ScrollView" then
        local content_rect = widget.content_rect
        local layout_scale = _get_responsive_layout_scale(widget)
        local scroll_scale_y = layout_scale and math.max(0.001, tonumber(layout_scale.y) or 1) or 1
        local raw_scroll_y = math.max(0, tonumber(widget.props and widget.props.scroll_y) or 0)
        local scroll_y = raw_scroll_y * scroll_scale_y
        local clip_rect = _rect_intersection(widget.clip_rect, content_rect)
        local scroll_content_height = math.max(0, tonumber(_resolve_widget_prop(widget, "scroll_content_height")) or 0)
        local layout_content_height = math.max(content_rect.h, scroll_content_height)
        local layout_root_rect = _make_rect(content_rect.x, content_rect.y - scroll_y, content_rect.w, layout_content_height)
        local max_bottom = layout_root_rect.y + layout_content_height

        for _, child in ipairs(widget.children) do
            _layout_widget_tree(child, layout_root_rect, ordered_widget_list, clip_rect)
            max_bottom = math.max(max_bottom, child.rect.y + child.rect.h)
        end

        widget.scroll_max_y = math.max(0, max_bottom + scroll_y - content_rect.y - content_rect.h)
        widget.scroll_max_y_design = widget.scroll_max_y / scroll_scale_y
        if raw_scroll_y > widget.scroll_max_y_design then
            widget.props.scroll_y = widget.scroll_max_y_design
        end
        return
    end

    if widget.type == "GridContainer" then
        local content_rect = widget.content_rect
        local columns = math.max(1, math.floor(tonumber(_resolve_widget_prop(widget, "columns")) or 1))
        local gap_x = tonumber(_resolve_widget_prop(widget, "gap_x")) or 0
        local gap_y = tonumber(_resolve_widget_prop(widget, "gap_y")) or 0
        local total_gap_x = math.max(0, (columns - 1) * gap_x)
        local cell_width = columns > 0 and math.max(0, (content_rect.w - total_gap_x) / columns) or content_rect.w

        local column = 0
        local cursor_y = content_rect.y
        local row_height = 0

        for _, child in ipairs(widget.children) do
            local preferred = _normalize_vec2(_resolve_widget_prop(child, "preferred_size"), 0, 0)
            local min_size = _normalize_vec2(_resolve_widget_prop(child, "min_size"), 0, 0)
            local intrinsic_w, intrinsic_h = _measure_widget_intrinsic(child, cell_width)
            local child_height = math.max(preferred.y, min_size.y, intrinsic_h)
            local child_x = content_rect.x + column * (cell_width + gap_x)
            local child_y = cursor_y
            child._layout_override = _make_rect(child_x, child_y, cell_width, child_height)
            _layout_widget_tree(child, widget.content_rect, ordered_widget_list, widget.clip_rect)

            row_height = math.max(row_height, child.rect.h)
            column = column + 1
            if column >= columns then
                column = 0
                cursor_y = cursor_y + row_height + gap_y
                row_height = 0
            end
        end
        return
    end

    for _, child in ipairs(widget.children) do
        _layout_widget_tree(child, widget.content_rect, ordered_widget_list, widget.clip_rect)
    end
end

local function _get_save_grid_options(widget)
    local instance_options = widget and widget.instance and widget.instance.options or {}
    local mode = _trim(instance_options.save_panel_mode) or _trim(_resolve_widget_prop(widget, "mode")) or "save"
    if mode ~= "save" and mode ~= "load" then
        mode = "save"
    end
    local profile_options = SaveSlotGridModel.get_profile_options()
    local category = profile_options.category
    local total_pages = profile_options.page_count
    local page = _clamp(math.max(1, math.floor(tonumber(instance_options.save_page) or 1)), 1, total_pages)
    local per_page = profile_options.slots_per_page
    return mode, category, page, per_page, total_pages
end

local function _set_save_grid_page(widget, page)
    local _, _, _, _, total_pages = _get_save_grid_options(widget)
    local next_page = _clamp(math.max(1, math.floor(tonumber(page) or 1)), 1, total_pages)
    local previous_page = nil
    if widget and widget.instance then
        previous_page = widget.instance.options.save_page
        widget.instance.options.save_page = next_page
    end
    local runtime = widget and widget.instance and widget.instance.runtime or nil
    if runtime and runtime.mark_layout_dirty and previous_page ~= next_page then
        runtime:mark_layout_dirty()
    end
    return next_page
end

local function _get_save_grid_header_layout(widget)
    local rect = widget.content_rect or widget.rect
    if not rect or rect.w <= 0 or rect.h <= 0 then
        return nil
    end

    local font_size = tonumber(_resolve_widget_prop(widget, "font_size")) or 22
    local header_h = math.max(34, font_size + 14)
    if rect.h < header_h + 96 then
        return nil
    end

    local gap = math.min(10, math.max(0, tonumber(_resolve_widget_prop(widget, "gap")) or 12))
    local button_w = math.max(44, math.floor(header_h * 1.35 + 0.5))
    local header_rect = _make_rect(rect.x, rect.y, rect.w, header_h)
    local prev_rect = _make_rect(rect.x, rect.y, button_w, header_h)
    local next_rect = _make_rect(rect.x + rect.w - button_w, rect.y, button_w, header_h)
    local label_rect = _make_rect(prev_rect.x + prev_rect.w + gap, rect.y, math.max(0, rect.w - button_w * 2 - gap * 2), header_h)
    local card_rect = _make_rect(rect.x, rect.y + header_h + gap, rect.w, math.max(0, rect.h - header_h - gap))
    return header_rect, prev_rect, next_rect, label_rect, card_rect
end

local function _get_save_grid_card_area(widget)
    local _, _, _, _, card_rect = _get_save_grid_header_layout(widget)
    return card_rect or widget.content_rect or widget.rect
end

local function _hit_save_grid_nav(widget, x, y)
    local _, prev_rect, next_rect = _get_save_grid_header_layout(widget)
    if prev_rect and _rect_contains(prev_rect, x, y) then
        return "prev"
    end
    if next_rect and _rect_contains(next_rect, x, y) then
        return "next"
    end
    return nil
end

local function _get_save_grid_card_rect(widget, item_index)
    local _, _, _, per_page = _get_save_grid_options(widget)
    local columns = math.min(2, per_page)
    local rows = math.max(1, math.ceil(per_page / columns))
    local gap = math.max(0, tonumber(_resolve_widget_prop(widget, "gap")) or 12)
    local rect = _get_save_grid_card_area(widget)
    local card_w = (rect.w - gap * (columns - 1)) / columns
    local card_h = (rect.h - gap * (rows - 1)) / rows
    local zero_index = item_index - 1
    local col = zero_index % columns
    local row = math.floor(zero_index / columns)
    return _make_rect(rect.x + col * (card_w + gap), rect.y + row * (card_h + gap), card_w, card_h)
end

local function _hit_save_grid_index(widget, x, y)
    local mode, category, page, per_page = _get_save_grid_options(widget)
    for index = 1, per_page do
        local card_rect = _get_save_grid_card_rect(widget, index)
        if _rect_contains(card_rect, x, y) then
            return index, mode, category, page, per_page
        end
    end
    return nil, mode, category, page, per_page
end

local function _draw_save_slot_grid(widget, alpha)
    local mode, category, page, per_page, total_pages = _get_save_grid_options(widget)
    local entries = {}
    local ok, result = pcall(function()
        return SaveSlotGridModel.list_page(page, per_page)
    end)
    if ok and type(result) == "table" then
        entries = result
    end

    local font_size = tonumber(_resolve_widget_prop(widget, "font_size")) or 22
    local text_color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
    local muted_color = _normalize_color(_resolve_widget_prop(widget, "muted_text_color"), 1)
    local bg_color = _normalize_color(_resolve_widget_prop(widget, "background_color"), 1)
    local hover_color = _normalize_color(_resolve_widget_prop(widget, "hover_color"), 1)
    local nav_background_color = _normalize_color(_resolve_widget_prop(widget, "disabled_color"), 1)
    local border_color = _normalize_color(_resolve_widget_prop(widget, "border_color"), 1)
    local border_thickness = tonumber(_resolve_widget_prop(widget, "border_thickness")) or 0
    local corner_roundness = _get_widget_corner_roundness(widget)
    local pointer_x = widget.hovered and tonumber(widget._last_pointer_x) or nil
    local pointer_y = widget.hovered and tonumber(widget._last_pointer_y) or nil
    local hovered_index = pointer_x and pointer_y and _hit_save_grid_index(widget, pointer_x, pointer_y) or nil
    local hovered_nav = pointer_x and pointer_y and _hit_save_grid_nav(widget, pointer_x, pointer_y) or nil

    local header_rect, prev_rect, next_rect, label_rect = _get_save_grid_header_layout(widget)
    if header_rect then
        local function draw_nav_button(rect, key, text, enabled, hovered)
            local fill = enabled and (hovered and hover_color or nav_background_color) or nav_background_color
            _draw_rectangle(rect, _to_rl_color(fill, alpha), corner_roundness)
            if border_thickness > 0 and border_color.a > 0.001 then
                _draw_border(rect, border_thickness, _to_rl_color(border_color, alpha), corner_roundness)
            end
            _draw_text_keyed(widget, key, text, rect, math.max(18, font_size), enabled and text_color or muted_color, alpha, "center", "center")
        end

        local function draw_page_label(rect, text)
            _draw_text_keyed(widget, "nav_label", text, rect, math.max(16, font_size - 1), text_color, alpha, "center", "center")
        end

        draw_nav_button(prev_rect, "nav_prev", "<", page > 1, hovered_nav == "prev" and page > 1)
        draw_nav_button(next_rect, "nav_next", ">", page < total_pages, hovered_nav == "next" and page < total_pages)
        local page_text = total_pages > 1
            and string.format("%d/%d", page, total_pages)
            or tostring(page)
        draw_page_label(label_rect, page_text)
    end

    for index = 1, per_page do
        local entry = entries[index] or {empty = true, category = category}
        local card_rect = _get_save_grid_card_rect(widget, index)
        local is_empty = type(entry) ~= "table" or entry.empty == true
        local disabled = mode == "load" and is_empty
        local fill = disabled and bg_color or (hovered_index == index and hover_color or bg_color)
        _draw_rectangle(card_rect, _to_rl_color(fill, alpha), corner_roundness)
        if border_thickness > 0 and border_color.a > 0.001 then
            _draw_border(card_rect, border_thickness, _to_rl_color(border_color, alpha), corner_roundness)
        end

        local inset = math.max(8, math.floor(card_rect.h * 0.06 + 0.5))
        local thumbnail_area = _make_rect(card_rect.x + inset, card_rect.y + inset, math.max(0, card_rect.w * 0.38), math.max(0, card_rect.h - inset * 2))
        local thumbnail_rect = thumbnail_area
        local thumbnail_content_rect = SaveSlotGridModel.fit_16_9_rect(thumbnail_area) or thumbnail_area
        local text_rect = _make_rect(thumbnail_area.x + thumbnail_area.w + inset, card_rect.y + inset, math.max(0, card_rect.x + card_rect.w - thumbnail_area.x - thumbnail_area.w - inset * 2), math.max(0, card_rect.h - inset * 2))

        local view = SaveSlotGridModel.build_slot_view(entry, {page = page, index = index})
        local thumbnail_path = is_empty and nil or view.thumbnail_path
        local texture = nil
        if thumbnail_path then
            local ok_texture, loaded_texture = pcall(SaveThumbnailCache.get_texture, thumbnail_path)
            if ok_texture then
                texture = loaded_texture
            end
        end
        _draw_rectangle(thumbnail_rect, _to_rl_color({r = 0, g = 0, b = 0, a = 1}, alpha), corner_roundness)
        if texture then
            local texture_rect = SaveSlotGridModel.fit_rect_preserve_aspect(thumbnail_content_rect, texture.width, texture.height) or thumbnail_content_rect
            _draw_texture_rounded(texture, texture_rect, alpha, corner_roundness)
        end

        if is_empty then
            _draw_text_keyed(widget, string.format("empty_%d", index), view.title, text_rect, math.max(14, font_size - 2), muted_color, alpha, "center", "center")
        else
            _draw_text_keyed(widget, string.format("title_%d", index), view.title, _make_rect(text_rect.x, text_rect.y, text_rect.w, font_size + 8), font_size, disabled and muted_color or text_color, alpha, "start", "start")
            _draw_text_keyed(widget, string.format("time_%d", index), view.time_text, _make_rect(text_rect.x, text_rect.y + font_size + 12, text_rect.w, font_size + 6), math.max(12, font_size - 4), muted_color, alpha, "start", "start")
        end
    end
end

local function _render_widget(widget, parent_alpha)
    if not widget.visible then
        return
    end

    local opacity = _clamp(tonumber(_resolve_widget_prop(widget, "opacity")) or 1, 0, 1)
    local alpha = (parent_alpha or 1) * opacity
    local rect = widget.rect
    local corner_roundness = _get_widget_corner_roundness(widget)

    if widget.type == "Canvas" or widget.type == "Panel" then
        local background_texture = _resolve_texture(_resolve_widget_prop(widget, "background_image"))
        if background_texture then
            _draw_texture_pro(background_texture, rect, alpha)
        else
            local background_color = _normalize_color(_resolve_widget_prop(widget, "background_color"), 0)
            if background_color.a > 0.001 then
                _draw_rectangle(rect, _to_rl_color(background_color, alpha), corner_roundness)
            end
        end
        local border_color = _normalize_color(_resolve_widget_prop(widget, "border_color"), 0)
        local border_thickness = tonumber(_resolve_widget_prop(widget, "border_thickness")) or 0
        if border_thickness > 0 and border_color.a > 0.001 then
            _draw_border(rect, border_thickness, _to_rl_color(border_color, alpha), corner_roundness)
        end
    elseif widget.type == "Image" then
        local texture = _resolve_texture(_resolve_widget_prop(widget, "texture"))
        if texture then
            local draw_rect = _copy_rect(rect)
            if _get_image_fit_mode(widget) == "preserve_aspect" and texture.width and texture.height and texture.width > 0 and texture.height > 0 then
                local scale = math.min(draw_rect.w / texture.width, draw_rect.h / texture.height)
                local width = texture.width * scale
                local height = texture.height * scale
                draw_rect.x = draw_rect.x + (draw_rect.w - width) * 0.5
                draw_rect.y = draw_rect.y + (draw_rect.h - height) * 0.5
                draw_rect.w = width
                draw_rect.h = height
            end
            local root_rect = widget.instance and widget.instance.root and widget.instance.root.rect or rect
            local shader_reference = _resolve_widget_prop(widget, "shader")
            local shader = shader_reference and ShaderRuntime.resolve_layer_shader("ui", shader_reference) or nil
            local shader_context =
            {
                layer = "ui",
                texture = texture,
                texture_width = texture.width,
                texture_height = texture.height,
                resolution_width = root_rect.w,
                resolution_height = root_rect.h,
                alpha = alpha,
            }
            if shader then
                _draw_texture_with_shader_rounded(texture, draw_rect, alpha, corner_roundness, shader, shader_context)
            else
                _draw_texture_rounded(texture, draw_rect, alpha, corner_roundness)
            end
        end
    elseif widget.type == "Text" then
        local color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
        local wrap_len = widget.content_rect.w > 0 and math.max(1, math.floor(widget.content_rect.w + 0.5)) or nil
        local wrapper = _ensure_text_wrapper(
            widget,
            _resolve_widget_prop(widget, "text") or "",
            _resolve_font(_resolve_widget_prop(widget, "font")),
            tonumber(_resolve_widget_prop(widget, "font_size")) or 28,
            color,
            wrap_len)
        if wrapper and wrapper.texture then
            local draw_x = widget.content_rect.x
            local draw_y = widget.content_rect.y
            local align_x = tostring(_resolve_widget_prop(widget, "align_x") or "start")
            local align_y = tostring(_resolve_widget_prop(widget, "align_y") or "start")
            if align_x == "center" then
                draw_x = widget.content_rect.x + (widget.content_rect.w - wrapper.w) * 0.5
            elseif align_x == "end" then
                draw_x = widget.content_rect.x + widget.content_rect.w - wrapper.w
            end
            if align_y == "center" then
                draw_y = widget.content_rect.y + (widget.content_rect.h - wrapper.h) * 0.5
            elseif align_y == "end" then
                draw_y = widget.content_rect.y + widget.content_rect.h - wrapper.h
            end
            rl.DrawTextureV(wrapper.texture, rl.Vector2(draw_x, draw_y), _to_rl_color(color, alpha))
        end
    elseif widget.type == "Button" then
        local background_texture = _resolve_texture(_resolve_widget_prop(widget, "background_image"))
        if background_texture then
            _draw_texture_pro(background_texture, rect, alpha)
        else
            local background_color = _resolve_widget_prop(widget, "background_color")
            if widget.pressed then
                background_color = _resolve_widget_prop(widget, "pressed_color")
            elseif widget.hovered then
                background_color = _resolve_widget_prop(widget, "hover_color")
            end
            _draw_rectangle(rect, _to_rl_color(_normalize_color(background_color, 1), alpha), corner_roundness)
        end
        local border_thickness = tonumber(_resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(_resolve_widget_prop(widget, "border_color"), 1)
        if border_thickness > 0 and border_color.a > 0.001 then
            _draw_border(rect, border_thickness, _to_rl_color(border_color, alpha), corner_roundness)
        end

        local padding = _normalize_padding(_resolve_widget_prop(widget, "padding"))
        local text_rect = _inset_rect(rect, padding)
        local text_color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
        local wrapper = _ensure_text_wrapper(
            widget,
            _resolve_widget_prop(widget, "text") or "",
            _resolve_font(_resolve_widget_prop(widget, "font")),
            tonumber(_resolve_widget_prop(widget, "font_size")) or 28,
            text_color,
            nil)
        if wrapper and wrapper.texture then
            local draw_x = text_rect.x + (text_rect.w - wrapper.w) * 0.5
            local draw_y = text_rect.y + (text_rect.h - wrapper.h) * 0.5
            rl.DrawTextureV(wrapper.texture, rl.Vector2(draw_x, draw_y), _to_rl_color(text_color, alpha))
        end
    elseif widget.type == "Toggle" then
        local is_checked = _resolve_widget_prop(widget, "value") == true
        local background_color = is_checked and _resolve_widget_prop(widget, "checked_color") or _resolve_widget_prop(widget, "background_color")
        if widget.hovered then
            background_color = _resolve_widget_prop(widget, "hover_color")
        end
        _draw_rectangle(rect, _to_rl_color(_normalize_color(background_color, 1), alpha), corner_roundness)

        local border_thickness = tonumber(_resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(_resolve_widget_prop(widget, "border_color"), 1)
        if border_thickness > 0 and border_color.a > 0.001 then
            _draw_border(rect, border_thickness, _to_rl_color(border_color, alpha), corner_roundness)
        end

        local padding = _normalize_padding(_resolve_widget_prop(widget, "padding"))
        local font_size = tonumber(_resolve_widget_prop(widget, "font_size")) or 26
        local text_rect = _inset_rect(rect, padding)
        local text_color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
        local wrapper = _ensure_text_wrapper(
            widget,
            _resolve_widget_prop(widget, "text") or "",
            _resolve_font(_resolve_widget_prop(widget, "font")),
            font_size,
            text_color,
            nil)
        if wrapper and wrapper.texture then
            local draw_x = text_rect.x + (text_rect.w - wrapper.w) * 0.5
            local draw_y = text_rect.y + (text_rect.h - wrapper.h) * 0.5
            rl.DrawTextureV(wrapper.texture, rl.Vector2(draw_x, draw_y), _to_rl_color(text_color, alpha))
        end
    elseif widget.type == "ProgressBar" then
        local min_value = tonumber(_resolve_widget_prop(widget, "min_value")) or 0
        local max_value = tonumber(_resolve_widget_prop(widget, "max_value")) or 1
        local raw_value = tonumber(_resolve_widget_prop(widget, "value")) or min_value
        local ratio = max_value ~= min_value and _clamp((raw_value - min_value) / (max_value - min_value), 0, 1) or 0
        local background_color = _normalize_color(_resolve_widget_prop(widget, "background_color"), 1)
        local fill_color = _normalize_color(_resolve_widget_prop(widget, "fill_color"), 1)
        _draw_rectangle(rect, _to_rl_color(background_color, alpha), corner_roundness)
        local padding = _normalize_padding(_resolve_widget_prop(widget, "padding"))
        local fill_rect = _inset_rect(rect, padding)
        fill_rect.w = fill_rect.w * ratio
        _draw_rectangle(fill_rect, _to_rl_color(fill_color, alpha), corner_roundness)
        local border_thickness = tonumber(_resolve_widget_prop(widget, "border_thickness")) or 0
        local border_color = _normalize_color(_resolve_widget_prop(widget, "border_color"), 1)
        if border_thickness > 0 and border_color.a > 0.001 then
            _draw_border(rect, border_thickness, _to_rl_color(border_color, alpha), corner_roundness)
        end
        if _should_show_progress(widget) then
            local text_color = _normalize_color(_resolve_widget_prop(widget, "text_color"), 1)
            local text_value = string.format("%d%%", math.floor(ratio * 100 + 0.5))
            local wrapper = _ensure_text_wrapper(
                widget,
                text_value,
                _resolve_font(_resolve_widget_prop(widget, "font")),
                tonumber(_resolve_widget_prop(widget, "font_size")) or 22,
                text_color,
                nil)
            if wrapper and wrapper.texture then
                local draw_x = rect.x + (rect.w - wrapper.w) * 0.5
                local draw_y = rect.y + (rect.h - wrapper.h) * 0.5
                rl.DrawTextureV(wrapper.texture, rl.Vector2(draw_x, draw_y), _to_rl_color(text_color, alpha))
            end
        else
            _clear_widget_text_wrapper(widget)
        end
    elseif widget.type == "SaveSlotGrid" then
        _draw_save_slot_grid(widget, alpha)
    elseif widget.type == "Spacer" then
        local background_color = _normalize_color(_resolve_widget_prop(widget, "background_color"), 0)
        if background_color.a > 0.001 then
            _draw_rectangle(rect, _to_rl_color(background_color, alpha), corner_roundness)
        end
    elseif widget.type == "VerticalContainer" or widget.type == "HorizontalContainer" or widget.type == "OverlayContainer" or widget.type == "ScrollView" or widget.type == "GridContainer" then
        local background_color = _normalize_color(_resolve_widget_prop(widget, "background_color"), 0)
        if background_color.a > 0.001 then
            _draw_rectangle(rect, _to_rl_color(background_color, alpha), corner_roundness)
        end
        local border_color = _normalize_color(_resolve_widget_prop(widget, "border_color"), 0)
        local border_thickness = tonumber(_resolve_widget_prop(widget, "border_thickness")) or 0
        if border_thickness > 0 and border_color.a > 0.001 then
            _draw_border(rect, border_thickness, _to_rl_color(border_color, alpha), corner_roundness)
        end
    end

    if widget.type == "ScrollView" then
        local clip = _rect_intersection(widget.clip_rect, widget.content_rect)
        if clip and clip.w > 0 and clip.h > 0 then
            rl.BeginScissorMode(
                math.floor(clip.x + 0.5),
                math.floor(clip.y + 0.5),
                math.max(0, math.floor(clip.w + 0.5)),
                math.max(0, math.floor(clip.h + 0.5)))
            for _, child in ipairs(widget.children) do
                _render_widget(child, alpha)
            end
            rl.EndScissorMode()
        end
        return
    end

    for _, child in ipairs(widget.children) do
        _render_widget(child, alpha)
    end
end

local function _pick_widget_recursive(widget, x, y, allow_noninteractive)
    if not widget.visible then
        return nil
    end
    if widget.clip_rect and not _rect_contains(widget.clip_rect, x, y) then
        return nil
    end
    if not _rect_contains(widget.rect, x, y) then
        return nil
    end

    for index = #widget.children, 1, -1 do
        local child = widget.children[index]
        local hit = _pick_widget_recursive(child, x, y, allow_noninteractive)
        if hit then
            return hit
        end
    end

    if allow_noninteractive then
        if _is_hit_test_enabled(widget) then
            return widget
        end
        return nil
    end

    if _is_input_target_widget(widget) then
        return widget
    end
    return nil
end

local function _find_scroll_ancestor(widget)
    local current = widget
    while current do
        if current.type == "ScrollView" then
            return current
        end
        current = current.parent
    end
    return nil
end

local function _build_ui_event_payload(instance, widget, event_type, action, extra)
    extra = type(extra) == "table" and extra or {}
    action = type(action) == "table" and action or nil

    return
    {
        event_type = tostring(event_type or extra.event_type or ""),
        instance_id = instance and instance.id or "",
        source_guid = instance and instance.source_guid or nil,
        source_path = instance and instance.source_path or nil,
        widget_id = widget and widget.id or "",
        widget_name = widget and widget.name or "",
        widget_type = widget and widget.type or "",
        event_name = _trim(extra.event_name)
            or _trim(action and action.event_name)
            or (widget and _trim(_resolve_widget_prop(widget, "event_name")) or nil)
            or "",
        message = _trim(extra.message) or "",
        value = _clone_value(extra.value),
        previous_value = _clone_value(extra.previous_value),
        custom_payload = _clone_value(extra.custom_payload),
    }
end

local function _resolve_widget_event_action(widget, event_type)
    local action = type(widget.events) == "table" and widget.events[event_type] or nil
    if type(action) == "table"
        and (_trim(action.kind)
            or _trim(action.target)
            or _trim(action.message)
            or _trim(action.event_name)
            or action.ui ~= nil
            or action.flow ~= nil
            or _trim(action.entry)
            or _trim(action.instance_id)
            or _trim(action.slot_id)
            or _trim(action.save_category)
            or _trim(action.reentry_policy)
            or action.auto_advance_interval ~= nil
            or action.auto_close_current == true)
    then
        local action_kind = _trim(action.kind) or "none"
        if event_type == "on_click" then
            action_kind = _normalize_click_action_kind(action_kind)
        end
        return
        {
            kind = action_kind,
            target = _trim(action.target) or "self",
            message = _trim(action.message) or "",
            event_name = _trim(action.event_name) or "",
            ui = _clone_value(action.ui),
            flow = _clone_value(action.flow),
            entry = _trim(action.entry) or "",
            instance_id = _trim(action.instance_id) or "",
            slot_id = _trim(action.slot_id) or "",
            save_category = _trim(action.save_category) or "manual",
            auto_advance_interval = _normalize_auto_advance_interval(action.auto_advance_interval),
            auto_close_current = action.auto_close_current == true,
            reentry_policy = _normalize_reentry_policy(action.reentry_policy),
        }
    end

    if event_type ~= "on_click" then
        return
        {
            kind = "none",
            target = "self",
            message = "",
            event_name = "",
            ui = nil,
            flow = nil,
            entry = "",
            instance_id = "",
            slot_id = "",
            save_category = "manual",
            auto_advance_interval = 1.0,
            auto_close_current = false,
            reentry_policy = "repeatable",
        }
    end

    return
    {
        kind = "none",
        target = "self",
        message = "",
        event_name = "",
        ui = nil,
        flow = nil,
        entry = "",
        instance_id = "",
        slot_id = "",
        save_category = "manual",
        auto_advance_interval = 1.0,
        auto_close_current = false,
        reentry_policy = "repeatable",
    }
end

local runtime_control_action_kind_pool =
{
    fast_forward = true,
    auto_advance = true,
    rollback = true,
}

local runtime_control_toggle_action_kind_pool =
{
    fast_forward = true,
    auto_advance = true,
}

local function _is_runtime_control_action(action)
    return type(action) == "table" and runtime_control_action_kind_pool[action.kind] == true
end

local function _get_widget_click_action(widget)
    if not widget then
        return nil
    end
    return _resolve_widget_event_action(widget, "on_click")
end

local function _is_runtime_control_toggle(widget)
    local action = widget and widget.type == "Toggle" and _get_widget_click_action(widget) or nil
    return action ~= nil and runtime_control_toggle_action_kind_pool[action.kind] == true
end

local function _can_auto_close_current_after_click(action)
    if type(action) ~= "table" or action.auto_close_current ~= true then
        return false
    end

    local kind = _trim(action.kind) or "none"
    return kind == "none"
        or kind == "close_ui"
        or kind == "open_ui"
        or kind == "quick_save"
        or kind == "quick_load"
        or kind == "save_game"
        or kind == "load_game"
end

local function _is_runtime_instance_active(self, instance)
    if not self or type(instance) ~= "table" then
        return false
    end

    if self._instance_by_id[instance.id] == instance then
        return true
    end

    for _, item in ipairs(self._instance_list or {}) do
        if item == instance then
            return true
        end
    end
    return false
end

local function _block_scene_interaction(self, reason)
    local scene = self and self._scene or nil
    if scene and scene.block_runtime_interaction_until_release then
        scene:block_runtime_interaction_until_release(reason)
    end
end

local function _auto_close_current_after_click(self, instance, action)
    if not _can_auto_close_current_after_click(action) then
        return false
    end
    if not _is_runtime_instance_active(self, instance) then
        return false
    end

    self:close_instance(instance)
    return true
end

local function _log_flow_runtime_payload(payload)
    local nav_data = payload and payload.context and FlowRuntimeError.build_nav_data and FlowRuntimeError.build_nav_data(payload.context) or nil
    LogManager.log(payload and payload.message or "界面事件流程执行失败", "error", nav_data)
end

local function _build_ui_event_locals(payload)
    payload = type(payload) == "table" and payload or {}
    return
    {
        ui_event = payload,
        ui_event_type = tostring(payload.event_type or ""),
        ui_event_name = tostring(payload.event_name or ""),
        ui_event_instance_id = tostring(payload.instance_id or ""),
        ui_event_widget_id = tostring(payload.widget_id or ""),
        ui_event_widget_name = tostring(payload.widget_name or ""),
        ui_event_widget_type = tostring(payload.widget_type or ""),
        ui_event_message = tostring(payload.message or ""),
        ui_event_value = payload.value,
        ui_event_previous_value = payload.previous_value,
    }
end

local function _destroy_runtime_session(session)
    if not session then
        return
    end

    local runtime = session.runtime or session
    if runtime and runtime.destroy then
        runtime:destroy()
    end
end

local function _find_runtime_session_index(session_list, session)
    if type(session_list) ~= "table" or not session then
        return nil
    end

    for index = #session_list, 1, -1 do
        if session_list[index] == session then
            return index
        end
    end
    return nil
end

local function _append_callback_list(target, source)
    for _, callback in ipairs(source or {}) do
        target[#target + 1] = callback
    end
end

local function _detach_instance_sessions(runtime, instance)
    if not runtime or not instance or type(instance.session_list) ~= "table" then
        return
    end

    for index = #instance.session_list, 1, -1 do
        local session = table.remove(instance.session_list, index)
        if session then
            table.insert(runtime._detached_session_list, session)
        end
    end
end

local function _clear_session_list(session_list)
    if type(session_list) ~= "table" then
        return
    end

    for _, session in ipairs(session_list) do
        _destroy_runtime_session(session)
    end
    for index = #session_list, 1, -1 do
        table.remove(session_list, index)
    end
end

local function _update_session_list(session_list, delta)
    local finish_callback_list = {}
    for index = #session_list, 1, -1 do
        local session = session_list[index]
        if session and session.runtime and session.runtime.update then
            session.runtime:update(delta)
        end

        local current_index = _find_runtime_session_index(session_list, session)
        if current_index and (not session or not session.runtime or session.runtime._ended) then
            local on_finish = session and session.on_finish or nil
            _destroy_runtime_session(session)
            table.remove(session_list, current_index)
            if type(on_finish) == "function" then
                finish_callback_list[#finish_callback_list + 1] = on_finish
            end
        end
    end
    return finish_callback_list
end

local function _make_auto_advance_binding_key(instance, widget)
    return string.format("%s:%s", tostring(instance and instance.id or ""), tostring(widget and widget.id or ""))
end

local function _apply_runtime_control_state_to_widget(widget, control_state)
    if not widget then
        return false
    end

    local changed = false
    local action = widget.type == "Toggle" and _get_widget_click_action(widget) or nil
    local desired_value = nil
    if action and action.kind == "fast_forward" then
        desired_value = control_state.fast_forward_enabled == true
    elseif action and action.kind == "auto_advance" then
        desired_value = control_state.auto_advance_enabled == true
    end

    if desired_value ~= nil then
        widget.props = widget.props or {}
        if widget.props.value ~= desired_value then
            widget.props.value = desired_value
            changed = true
        end
    end

    for _, child in ipairs(widget.children or {}) do
        if _apply_runtime_control_state_to_widget(child, control_state) == true then
            changed = true
        end
    end

    return changed
end

function UIRuntime:ctor(scene, options)
    options = options or {}
    self._scene = scene
    self._instance_list = {}
    self._instance_by_id = {}
    self._closed_instance_result_pool = {}
    self._detached_session_list = {}
    self._input_state = nil
    self._pressed_widget = nil
    self._hovered_widget = nil
    self._hovered_instance = nil
    self._focused_widget = nil
    self._focused_instance = nil
    self._input_capture_result = RuntimeInputState.make_empty_capture_result()
    self._frame_input_processed = false
    self._allow_actions = options.allow_actions ~= false
    self._preview_mode = options.preview_mode == true
    self._next_instance_serial = 0
    self._canvas_width_override = nil
    self._canvas_height_override = nil
    self._behavior_warning_pool = {}
    self._layout_dirty = true
    self._layout_updated_this_frame = false
    self._suppress_runtime_control_sync = false
end

function UIRuntime:mark_layout_dirty()
    self._layout_dirty = true
end

function UIRuntime:set_canvas_size_override(width, height)
    local previous_width = self._canvas_width_override
    local previous_height = self._canvas_height_override
    local normalized_width = tonumber(width)
    local normalized_height = tonumber(height)
    if normalized_width and normalized_height and normalized_width > 0 and normalized_height > 0 then
        self._canvas_width_override = math.floor(normalized_width + 0.5)
        self._canvas_height_override = math.floor(normalized_height + 0.5)
        if previous_width ~= self._canvas_width_override or previous_height ~= self._canvas_height_override then
            self:mark_layout_dirty()
        end
        return
    end

    self._canvas_width_override = nil
    self._canvas_height_override = nil
    if previous_width ~= nil or previous_height ~= nil then
        self:mark_layout_dirty()
    end
end

function UIRuntime:set_input_state(state)
    self._input_state = type(state) == "table" and RuntimeInputState.normalize_state(_clone_value(state)) or nil
end

function UIRuntime:_get_input_state()
    if type(self._input_state) == "table" then
        return RuntimeInputState.normalize_state(self._input_state)
    end

    return RuntimeInputState.read_current_state()
end

function UIRuntime:get_input_capture_result()
    return RuntimeInputState.clone_state(self._input_capture_result)
end

function UIRuntime:_make_instance(document_snapshot, options)
    options = options or {}
    local source_guid = options.source_guid
    local source_path = options.source_path
    self._next_instance_serial = self._next_instance_serial + 1
    local instance_id = _trim(options.instance_id)
        or source_guid
        or source_path
        or string.format("ui_instance_%d", self._next_instance_serial)

    local instance =
    {
        id = instance_id,
        source_guid = source_guid,
        source_path = source_path,
        document = UI.normalize_document(document_snapshot),
        behavior_flow = _normalize_runtime_flow_reference(options.behavior_flow),
        options = _clone_value(options),
        widget_by_id = {},
        ordered_widget_list = {},
        session_list = {},
        queued_behavior_list = {},
        root = nil,
        runtime = self,
        style_sheet = nil,
    }
    instance.options.behavior_flow = _clone_value(instance.behavior_flow)

    instance.root = _build_runtime_widget(instance, instance.document.root, nil)
    return instance
end

function UIRuntime:refresh_runtime_control_widgets(options)
    if self._suppress_runtime_control_sync == true then
        return false
    end
    if self._preview_mode == true or self._allow_actions == false or not self._scene then
        return false
    end

    local runtime_flow_control = _get_runtime_flow_control()
    local control_state = runtime_flow_control.get_control_state and runtime_flow_control.get_control_state() or
    {
        fast_forward_enabled = runtime_flow_control.is_fast_forward_enabled and runtime_flow_control.is_fast_forward_enabled() or false,
        auto_advance_enabled = runtime_flow_control.is_auto_advance_enabled and runtime_flow_control.is_auto_advance_enabled() or false,
    }
    local changed = false
    for _, instance in ipairs(self._instance_list or {}) do
        if _apply_runtime_control_state_to_widget(instance and instance.root or nil, control_state) == true then
            changed = true
        end
    end
    if changed == true then
        self:mark_layout_dirty()
        return true
    end

    return false
end

function UIRuntime:sync_runtime_control_bindings(options)
    return self:refresh_runtime_control_widgets(options)
end

function UIRuntime:open_document(document_or_reference, options)
    local open_options = options or {}
    local runtime_info = nil
    local document_snapshot = nil

    if type(document_or_reference) == "table" and document_or_reference.document then
        runtime_info = document_or_reference
        document_snapshot = runtime_info.document
    elseif type(document_or_reference) == "table" and document_or_reference.root then
        document_snapshot = document_or_reference
    else
        local err = nil
        runtime_info, err = _resolve_runtime_document(document_or_reference,
        {
            allow_unsaved_snapshot = self._preview_mode == true,
        })
        if not runtime_info then
            return nil, err or "无法打开界面文档"
        end
        document_snapshot = runtime_info.document
    end

    local instance = self:_make_instance(document_snapshot,
    {
        instance_id = open_options.instance_id,
        source_guid = runtime_info and runtime_info.guid or open_options.source_guid,
        source_path = runtime_info and runtime_info.path or open_options.source_path,
        behavior_flow = open_options.behavior_flow,
        on_event = open_options.on_event,
        system_save_panel = open_options.system_save_panel == true,
        save_panel_mode = open_options.save_panel_mode,
        save_category = open_options.save_category,
        save_page = open_options.save_page,
        global_overlay = open_options.global_overlay == true,
    })

    if self._instance_by_id[instance.id] then
        self:close_instance(instance.id)
    end

    self._closed_instance_result_pool[instance.id] = nil
    self._instance_by_id[instance.id] = instance
    table.insert(self._instance_list, instance)
    self:mark_layout_dirty()
    self:_emit_instance_event(instance, "on_open", nil, nil, nil)
    self:_run_document_behavior(instance, "on_open", nil, nil, nil, false)
    _block_scene_interaction(self, "ui_open")
    self:sync_runtime_control_bindings({force = true})
    return instance
end

function UIRuntime:open_save_panel(options)
    local panel_options = type(options) == "table" and options or {}
    return self:open_document(
    {
        path_hint = "ui/存档界面模板.ui",
    },
    {
        instance_id = panel_options.instance_id or "__system_save_panel",
        system_save_panel = true,
        save_panel_mode = panel_options.mode == "load" and "load" or "save",
        save_category = panel_options.category or "manual",
        save_page = tonumber(panel_options.page) or 1,
    })
end

function UIRuntime:open_load_panel(options)
    local panel_options = type(options) == "table" and options or {}
    panel_options.mode = "load"
    panel_options.instance_id = panel_options.instance_id or "__system_load_panel"
    return self:open_save_panel(panel_options)
end

function UIRuntime:close_instance(value)
    local instance = type(value) == "table" and value or self._instance_by_id[value]
    if not instance then
        return false
    end
    local close_result =
    {
        instance_id = tostring(instance.id or ""),
        return_value = tostring(instance.return_value or ""),
        close_reason = tostring(instance.close_reason or (instance.return_value ~= nil and "返回" or "关闭")),
        source_guid = instance.source_guid,
        source_path = instance.source_path,
    }

    self:_emit_instance_event(instance, "on_close", nil, nil, nil)
    self:_run_document_behavior(instance, "on_close", nil, nil, nil, false, true)

    self._instance_by_id[instance.id] = nil
    for index = #self._instance_list, 1, -1 do
        if self._instance_list[index] == instance then
            table.remove(self._instance_list, index)
            break
        end
    end
    _detach_instance_sessions(self, instance)
    instance.queued_behavior_list = {}
    _destroy_widget_runtime(instance.root)
    if self._pressed_widget and self._pressed_widget.instance == instance then
        self._pressed_widget = nil
    end
    if self._hovered_widget and self._hovered_widget.instance == instance then
        self._hovered_widget = nil
        self._hovered_instance = nil
    end
    if self._focused_widget and self._focused_widget.instance == instance then
        self._focused_widget = nil
        self._focused_instance = nil
    end
    if close_result.instance_id ~= "" then
        self._closed_instance_result_pool[close_result.instance_id] = close_result
    end
    self:mark_layout_dirty()
    _block_scene_interaction(self, "ui_close")
    self:sync_runtime_control_bindings({force = true})
    return true
end

function UIRuntime:return_instance(value, return_value)
    local instance = type(value) == "table" and value or self._instance_by_id[value]
    if not instance then
        return false
    end
    instance.return_value = tostring(return_value or "")
    instance.close_reason = "返回"
    return self:close_instance(instance)
end

function UIRuntime:close_by_source(reference)
    local target_guid = nil
    local ResourceIndex = require("application.framework.resource_index")
    if reference ~= nil then
        target_guid = ResourceIndex.resolve_guid("ui", reference)
    end

    local closed = false
    for index = #self._instance_list, 1, -1 do
        local instance = self._instance_list[index]
        if reference == nil
            or (target_guid and instance.source_guid == target_guid)
            or instance.id == reference
        then
            self:close_instance(instance)
            closed = true
        end
    end
    return closed
end

function UIRuntime:find_instance(value)
    if type(value) == "table" then
        return value
    end
    return self._instance_by_id[value]
end

function UIRuntime:consume_closed_instance_result(value)
    local instance_id = tostring(value or "")
    if instance_id == "" then
        return nil
    end
    local result = self._closed_instance_result_pool[instance_id]
    self._closed_instance_result_pool[instance_id] = nil
    return result
end

function UIRuntime:get_instances()
    return self._instance_list
end

function UIRuntime:find_widget(instance_or_id, widget_id)
    local instance = self:find_instance(instance_or_id)
    if not instance then
        return nil
    end
    return instance.widget_by_id[widget_id]
end

function UIRuntime:resolve_widget_prop(widget, key)
    return _resolve_widget_prop(widget, key)
end

function UIRuntime:resolve_widget_texture(widget, key)
    return _resolve_texture(_resolve_widget_prop(widget, key))
end

function UIRuntime:reload_instance(value, document_snapshot, options)
    local instance = self:find_instance(value)
    if not instance then
        return nil, "无法定位界面实例"
    end

    local next_options = _clone_value(instance.options or {})
    if type(options) == "table" then
        for key, item in pairs(options) do
            next_options[key] = _clone_value(item)
        end
    end

    local instance_id = instance.id
    local source_guid = instance.source_guid
    local source_path = instance.source_path
    self:close_instance(instance)
    return self:open_document(document_snapshot,
    {
        instance_id = instance_id,
        source_guid = source_guid,
        source_path = source_path,
        behavior_flow = next_options.behavior_flow,
        on_event = next_options.on_event,
    })
end

function UIRuntime:pick_widget(instance_or_id, x, y, options)
    local instance = self:find_instance(instance_or_id)
    if not instance or not instance.root then
        return nil
    end
    options = options or {}
    return _pick_widget_recursive(instance.root, x, y, options.allow_noninteractive == true)
end

function UIRuntime:_start_document_behavior(instance, event_type, widget, action, extra, emit_callback, detached, session_options)
    if self._preview_mode or not self._scene then
        return false
    end

    local flow_reference = action and action.flow or (instance and instance.behavior_flow)
    if not flow_reference then
        return false
    end

    local document = _get_flow_manager().get_document(flow_reference, "flow_runtime")
    if not document then
        LogManager.log(string.format("无法打开界面事件流程：%s", tostring(flow_reference.path_hint or flow_reference.guid or flow_reference)), "warning")
        return false
    end

    local payload = _build_ui_event_payload(instance, widget, event_type, action,
    {
        event_name = extra and extra.event_name or nil,
        message = extra and extra.message or nil,
        value = extra and extra.value or nil,
        previous_value = extra and extra.previous_value or nil,
        custom_payload = extra and extra.custom_payload or nil,
    })
    if emit_callback == true then
        self:_emit_instance_event(instance, event_type, widget, action, payload)
    end

    local runtime = self:_create_document_runtime(document, payload, action)
    if not runtime then
        return false
    end

    if detached == true then
        self:_push_detached_session(runtime, session_options)
    else
        self:_push_instance_session(instance, runtime, session_options)
    end
    return true
end

function UIRuntime:_drain_instance_behavior_queue(instance)
    if not instance
        or type(instance.queued_behavior_list) ~= "table"
        or #instance.queued_behavior_list == 0
        or #instance.session_list > 0
    then
        return false
    end

    local request = table.remove(instance.queued_behavior_list, 1)
    if not request then
        return false
    end

    return self:_start_document_behavior(
        instance,
        request.event_type,
        request.widget,
        request.action,
        request.extra,
        request.emit_callback,
        request.detached,
        request.session_options)
end

function UIRuntime:_set_focused_widget(instance, widget)
    if self._focused_widget == widget and self._focused_instance == instance then
        return false
    end

    self._focused_widget = widget
    self._focused_instance = instance
    return true
end

function UIRuntime:_dispatch_widget_event(instance, event_type, widget, extra, detached)
    if not instance then
        return false
    end

    local action = widget and _resolve_widget_event_action(widget, event_type) or nil
    local payload = _build_ui_event_payload(instance, widget, event_type, action, extra)
    self:_emit_instance_event(instance, event_type, widget, action, payload)
    self:_run_document_behavior(instance, event_type, widget, action, extra, false, detached)
    return true
end

local function _make_responsive_layout_scale(canvas, canvas_width, canvas_height)
    local design_width = math.max(1, tonumber(canvas and canvas.design_width) or tonumber(canvas and canvas.width) or canvas_width)
    local design_height = math.max(1, tonumber(canvas and canvas.design_height) or tonumber(canvas and canvas.height) or canvas_height)
    local scale_x = canvas_width / design_width
    local scale_y = canvas_height / design_height
    local uniform = math.min(scale_x, scale_y)
    return
    {
        x = scale_x,
        y = scale_y,
        uniform = uniform,
        font = uniform,
    }
end

function UIRuntime:_update_layout()
    local width, height = ScreenManager.get_size()
    if self._canvas_width_override and self._canvas_height_override then
        width = self._canvas_width_override
        height = self._canvas_height_override
    end

    for _, instance in ipairs(self._instance_list) do
        instance.ordered_widget_list = {}
        local canvas = instance.document.canvas or {}
        local canvas_mode = tostring(canvas.mode or "fixed")
        local use_project_canvas = canvas_mode == "project" or canvas_mode == "responsive"
        local canvas_width = use_project_canvas and width or math.max(1, math.floor(tonumber(canvas.width) or width))
        local canvas_height = use_project_canvas and height or math.max(1, math.floor(tonumber(canvas.height) or height))
        instance._responsive_layout_scale = canvas_mode == "responsive"
            and _make_responsive_layout_scale(canvas, canvas_width, canvas_height)
            or nil
        local root_rect = _make_rect(0, 0, canvas_width, canvas_height)
        _layout_widget_tree(instance.root, root_rect, instance.ordered_widget_list, root_rect)
    end
    self._layout_dirty = false
    self._layout_updated_this_frame = true
end

function UIRuntime:_update_sessions(delta)
    local finish_callback_list = {}
    for index = #self._instance_list, 1, -1 do
        local instance = self._instance_list[index]
        _append_callback_list(finish_callback_list, _update_session_list(instance.session_list, delta))
        if _is_runtime_instance_active(self, instance) then
            self:_drain_instance_behavior_queue(instance)
        end
    end
    _append_callback_list(finish_callback_list, _update_session_list(self._detached_session_list, delta))

    for _, callback in ipairs(finish_callback_list) do
        callback()
    end
end

function UIRuntime:_push_instance_session(instance, runtime, options)
    if not instance or not runtime then
        return false
    end

    table.insert(instance.session_list,
    {
        runtime = runtime,
        on_finish = type(options) == "table" and options.on_finish or nil,
    })
    return true
end

function UIRuntime:_push_detached_session(runtime, options)
    if not runtime then
        return false
    end

    table.insert(self._detached_session_list,
    {
        runtime = runtime,
        on_finish = type(options) == "table" and options.on_finish or nil,
    })
    return true
end

function UIRuntime:_create_document_runtime(document, payload, action)
    if document.kind == "text" then
        if document._compile_dirty then
            document:compile_document({force = true})
        end

        local program = document.get_compiled_program and document:get_compiled_program() or document._compiled_program
        local diagnostics = document.get_diagnostics and document:get_diagnostics() or document._diagnostics or {}
        if not program or FlowTextDiagnostics.has_errors(diagnostics) then
            LogManager.log(string.format("界面事件流程存在编译错误：%s", document._resource_id or document._id or "未知流程"), "error")
            return nil
        end

        return FlowTextRuntime.new(document, program, self._scene,
        {
            entry_label = action and action.entry ~= "" and action.entry or nil,
            owns_scene_context = false,
            update_scene_context = false,
            detach_document_lifecycle = true,
            initial_locals = _build_ui_event_locals(payload),
            on_error = function(runtime_payload)
                _log_flow_runtime_payload(runtime_payload)
            end,
        })
    end

    if document.kind == "graph" then
        local event_context =
        {
            event_type = payload.event_type,
            payload = payload,
        }
        local entry_node_id, miss_reason = UIFlowGraphRuntime.find_entry_node_id(document, event_context)
        if not entry_node_id then
            if _should_log_missing_entry(payload.event_type, action) then
                local warning_key = string.format(
                    "missing_ui_entry:%s:%s:%s:%s:%s:%s",
                    _document_key(document) or "unknown",
                    tostring(payload.event_type or ""),
                    tostring(payload.source_path or payload.source_guid or ""),
                    tostring(payload.instance_id or ""),
                    tostring(payload.widget_id or ""),
                    tostring(payload.event_name or ""))
                local event_text = UIFlowGraphRuntime.describe_event_context
                    and UIFlowGraphRuntime.describe_event_context(event_context)
                    or _describe_ui_event_payload(payload)
                local panel_hint = _get_panel_action_hint(action and action.kind)
                local detail = tostring(miss_reason or "请检查事件节点过滤条件")
                if panel_hint then
                    detail = string.format("%s。%s", detail, panel_hint)
                end
                _log_warning_once(self, warning_key, string.format(
                    "界面事件没有找到响应流程：%s。流程=%s。该组件明确要求执行界面行为流程，但流程里没有匹配的事件节点；请检查界面文件和组件名称。原因=%s",
                    event_text,
                    _document_display_name(document),
                    detail))
            end
            return nil
        end

        local runtime = UIFlowGraphRuntime.new(document, self._scene,
        {
            event_context = event_context,
            on_error = function(runtime_payload)
                _log_flow_runtime_payload(runtime_payload)
            end,
        })
        local started, err = runtime:start(entry_node_id)
        if not started then
            LogManager.log(err or "无法启动界面行为图运行时", "warning")
            return nil
        end
        return runtime
    end

    LogManager.log(string.format("当前不支持在界面事件中附着执行该流程类型：%s", tostring(document.kind or "unknown")), "warning")
    return nil
end

function UIRuntime:_run_document_behavior(instance, event_type, widget, action, extra, emit_callback, detached, session_options)
    local action_kind = _trim(action and action.kind) or "none"
    local action_requests_behavior = type(action) == "table"
        and (action_kind == "run_flow"
            or action.flow ~= nil
            or _trim(action.entry) ~= nil
            or _trim(action.event_name) ~= nil)
    if not action_requests_behavior and not (instance and instance.behavior_flow) then
        return false
    end

    if detached == true or not instance then
        return self:_start_document_behavior(instance, event_type, widget, action, extra, emit_callback, true, session_options)
    end

    local session_list = instance.session_list or {}
    if #session_list > 0 then
        local reentry_policy = _normalize_reentry_policy(action and action.reentry_policy)
        if reentry_policy == "repeatable" then
            instance.queued_behavior_list = instance.queued_behavior_list or {}
            table.insert(instance.queued_behavior_list,
            {
                event_type = event_type,
                widget = widget,
                action = _clone_value(action),
                extra = _clone_value(extra),
                emit_callback = emit_callback == true,
                detached = detached == true,
                session_options = session_options,
            })
            return true
        end
        return false
    end

    return self:_start_document_behavior(instance, event_type, widget, action, extra, emit_callback, detached, session_options)
end

function UIRuntime:_emit_instance_event(instance, event_type, widget, action, prepared_payload)
    local callback = instance.options and instance.options.on_event
    if type(callback) == "function" then
        local payload = prepared_payload or _build_ui_event_payload(instance, widget, event_type, action)
        local callback_kind = tostring(event_type or ""):gsub("^on_", "")
        callback(
        {
            kind = callback_kind,
            action_kind = action and action.kind or nil,
            payload = payload,
        })
    end
end

local terminal_system_action_pool =
{
    save_game = true,
    load_game = true,
    quick_save = true,
    quick_load = true,
    open_save_panel = true,
    open_load_panel = true,
    fast_forward = true,
    auto_advance = true,
    rollback = true,
}

local function _is_terminal_system_action(action)
    return type(action) == "table" and terminal_system_action_pool[action.kind] == true
end

local function _abort_after_runtime_switch(runtime, instance, result)
    if not result or result.abort_current_context ~= true then
        return
    end
    if instance then
        _clear_session_list(instance.session_list)
        instance.queued_behavior_list = {}
    end
    _clear_session_list(runtime and runtime._detached_session_list)
end

local function _apply_save_slot_grid_action(runtime, instance, widget)
    local x = widget._last_pointer_x or widget._pressed_pointer_x
    local y = widget._last_pointer_y or widget._pressed_pointer_y
    local nav = _hit_save_grid_nav(widget, x or -1, y or -1)
    if nav then
        local _, _, page, _, total_pages = _get_save_grid_options(widget)
        if nav == "prev" and page > 1 then
            _set_save_grid_page(widget, page - 1)
        elseif nav == "next" and page < total_pages then
            _set_save_grid_page(widget, page + 1)
        end
        return
    end

    local index, mode, category, page, per_page = _hit_save_grid_index(widget, x or -1, y or -1)
    if not index then
        return
    end
    local entries = SaveSlotGridModel.list_page(page, per_page) or {}
    local entry = entries[index]
    if type(entry) ~= "table" then
        return
    end
    if mode == "load" then
        if entry.empty == true then
            _notify_load_failed()
            LogManager.log("读取存档失败：空存档位置", "warning")
            return
        end
        local result = _get_save_manager().load_location(entry.location or entry.slot_id)
        if not result or result.ok ~= true then
            LogManager.log(string.format("读取存档失败：%s", tostring(result and result.error or "未知错误")), "warning")
            return
        end
        _abort_after_runtime_switch(runtime, instance, result)
        return
    end

    local previous_thumbnail_path = entry.empty ~= true
        and _get_save_manager().resolve_thumbnail_path(entry.location or entry.slot_id)
        or nil
    local actual_slot_id, err = _get_snapshot_coordinator().request_save(entry.location or
    {
        category = category,
        page = page,
        index = index,
    },
    {
        source = "ui_action",
        category = category,
    })
    if actual_slot_id == false then
        LogManager.log(string.format("保存存档失败：%s", tostring(err or "未知错误")), "warning")
    elseif previous_thumbnail_path then
        SaveThumbnailCache.release(previous_thumbnail_path)
    end
end

function UIRuntime:_apply_widget_builtin_action(instance, widget, action)
    if not _is_runtime_instance_active(self, instance) then
        return
    end

    action = type(action) == "table" and action or _resolve_widget_event_action(widget, "on_click")
    local action_kind = action.kind
    if action_kind == "return_value" then
        self:return_instance(instance, action.message)
        return
    end

    if action_kind == "none" then
        _auto_close_current_after_click(self, instance, action)
        return
    end

    if action_kind == "fast_forward" then
        local runtime_flow_control = _get_runtime_flow_control()
        local runtime_document = GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil
        local action_options =
        {
            source = "ui_action",
            reason = "fast_forward",
            label = "快进",
        }
        if widget and widget.type == "Toggle" and runtime_flow_control.set_fast_forward_enabled then
            runtime_flow_control.set_fast_forward_enabled(runtime_document, widget.props and widget.props.value == true, action_options)
        else
            runtime_flow_control.toggle_fast_forward(runtime_document, action_options)
        end
        self:refresh_runtime_control_widgets({force = true})
        return
    end

    if action_kind == "auto_advance" then
        local runtime_flow_control = _get_runtime_flow_control()
        local runtime_document = GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil
        if widget and widget.type == "Toggle" then
            runtime_flow_control.set_auto_advance_enabled(
                runtime_document,
                widget.props and widget.props.value == true,
                action.auto_advance_interval,
                {
                    source = "ui_action",
                    reason = "auto_advance",
                    label = "自动推进",
                    binding_key = _make_auto_advance_binding_key(instance, widget),
                })
            self:refresh_runtime_control_widgets({force = true})
            return
        end

        runtime_flow_control.toggle_auto_advance(
            runtime_document,
            action.auto_advance_interval,
            {
                source = "ui_action",
                reason = "auto_advance",
                label = "自动推进",
            })
        self:refresh_runtime_control_widgets({force = true})
        return
    end

    if action_kind == "rollback" then
        _get_runtime_flow_control().request_rollback(
            {
                source = "ui_action",
                reason = "rollback",
                label = "回退",
            })
        self:refresh_runtime_control_widgets({force = true})
        return
    end

    local action_target = action.target
    if action_kind == "close_ui" then
        if action_target == "self" or action_target == "current" then
            self:close_instance(instance)
        else
            self:close_instance(action_target)
            _auto_close_current_after_click(self, instance, action)
        end
        return
    end

    if action_kind == "open_ui" then
        local ui_reference = action.ui
        if ui_reference then
            local opened_instance = self:open_document(ui_reference,
            {
                instance_id = action.instance_id ~= "" and action.instance_id or nil,
                behavior_flow = instance.behavior_flow,
            })
            if opened_instance then
                _auto_close_current_after_click(self, instance, action)
            end
        end
        return
    end

    if action_kind == "quick_save" then
        local ok, err = _get_snapshot_coordinator().request_quick_save(
        {
            source = "ui_action",
        })
        if ok == false then
            LogManager.log(string.format("界面快速存档失败：%s", tostring(err or "未知错误")), "warning")
        else
            _auto_close_current_after_click(self, instance, action)
        end
        return
    end

    if action_kind == "quick_load" then
        local ok, result = _get_save_manager().quick_load()
        if ok ~= true or not result or result.ok ~= true then
            LogManager.log(string.format("界面快速读档失败：%s", tostring(result and result.error or result or "未知错误")), "warning")
        else
            _auto_close_current_after_click(self, instance, action)
            _abort_after_runtime_switch(self, instance, result)
        end
        return
    end

    if action_kind == "save_game" then
        local ok, err = _get_snapshot_coordinator().request_save(_trim(action.slot_id),
        {
            source = "ui_action",
            category = _trim(action.save_category) or "manual",
        })
        if ok == false then
            LogManager.log(string.format("界面存档失败：%s", tostring(err or "未知错误")), "warning")
        else
            _auto_close_current_after_click(self, instance, action)
        end
        return
    end

    if action_kind == "load_game" then
        local slot_id = _trim(action.slot_id)
        if not slot_id then
            local continue_slot = _get_save_manager().get_latest_continue_slot()
            slot_id = continue_slot and continue_slot.slot_id or nil
        end
        if not slot_id then
            _notify_load_failed()
            LogManager.log("界面读档失败：当前没有可用的继续游戏存档", "warning")
            return
        end

        local result = _get_save_manager().load_location(slot_id)
        if not result or result.ok ~= true then
            LogManager.log(string.format("界面读档失败：%s", tostring(result and result.error or "未知错误")), "warning")
        else
            _auto_close_current_after_click(self, instance, action)
            _abort_after_runtime_switch(self, instance, result)
        end
        return
    end

    if action_kind == "open_save_panel" or action_kind == "open_load_panel" then
        local opened = action_kind == "open_load_panel"
            and self:open_load_panel({category = _trim(action.save_category) or "manual"})
            or self:open_save_panel({category = _trim(action.save_category) or "manual"})
        if opened then
            _auto_close_current_after_click(self, instance, action)
        end
        return
    end
end

function UIRuntime:_consume_widget_click_action(instance, widget)
    if not _is_runtime_instance_active(self, instance) or not widget then
        return false
    end

    local action = _resolve_widget_event_action(widget, "on_click")
    if _is_runtime_control_action(action) then
        return true
    end
    if _normalize_reentry_policy(action and action.reentry_policy) ~= "once" then
        return true
    end
    if widget._click_action_consumed == true then
        return false
    end

    widget._click_action_consumed = true
    return true
end

function UIRuntime:_apply_widget_action(instance, widget)
    local action = _resolve_widget_event_action(widget, "on_click")

    self:_emit_instance_event(instance, "on_click", widget, action, nil)
    self:_run_document_behavior(instance, "on_click", widget, action, nil, false)

    if widget.type == "SaveSlotGrid" then
        if self._allow_actions then
            _apply_save_slot_grid_action(self, instance, widget)
        end
        return
    end

    if not self._allow_actions then
        return
    end

    if _is_terminal_system_action(action) then
        self:_apply_widget_builtin_action(instance, widget, action)
        return
    end

    self:_apply_widget_builtin_action(instance, widget, action)
end

function UIRuntime:_process_input(input)
    local capture_result = RuntimeInputState.make_empty_capture_result()
    local hovered_widget = nil
    local hovered_instance = nil
    for index = #self._instance_list, 1, -1 do
        local instance = self._instance_list[index]
        local hit = _pick_widget_recursive(instance.root, input.mouse_x or -1, input.mouse_y or -1, false)
        if hit then
            hovered_widget = hit
            hovered_instance = instance
            break
        end
    end
    capture_result.hovered_widget_id = hovered_widget and hovered_widget.id or nil
    if hovered_widget then
        hovered_widget._last_pointer_x = input.mouse_x
        hovered_widget._last_pointer_y = input.mouse_y
    end

    local previous_hovered_widget = self._hovered_widget
    local previous_hovered_instance = self._hovered_instance
    if previous_hovered_widget ~= hovered_widget or previous_hovered_instance ~= hovered_instance then
        if previous_hovered_widget and previous_hovered_instance then
            self:_dispatch_widget_event(previous_hovered_instance, "on_unhover", previous_hovered_widget)
        end
        if hovered_widget and hovered_instance then
            self:_dispatch_widget_event(hovered_instance, "on_hover", hovered_widget)
        end
        self._hovered_widget = hovered_widget
        self._hovered_instance = hovered_instance
    end

    for _, instance in ipairs(self._instance_list) do
        for _, widget in ipairs(instance.ordered_widget_list) do
            widget.hovered = (widget == hovered_widget)
            if widget ~= self._pressed_widget then
                widget.pressed = false
            end
        end
    end

    local scroll_widget = hovered_widget and _find_scroll_ancestor(hovered_widget) or nil
    if scroll_widget and tonumber(input.wheel_y) and input.wheel_y ~= 0 then
        local current_scroll = math.max(0, tonumber(scroll_widget.props.scroll_y) or 0)
        local speed = tonumber(_resolve_widget_prop(scroll_widget, "wheel_speed")) or 36
        local next_scroll = current_scroll - input.wheel_y * speed
        local next_scroll_clamped = _clamp(next_scroll, 0, scroll_widget.scroll_max_y_design or scroll_widget.scroll_max_y or 0)
        if next_scroll_clamped ~= current_scroll then
            scroll_widget.props.scroll_y = next_scroll_clamped
            self:mark_layout_dirty()
        end
    end
    if tonumber(input.wheel_y) and input.wheel_y ~= 0 then
        if scroll_widget and _should_consume_wheel_input(scroll_widget) then
            capture_result.wheel_consumed = true
        elseif hovered_widget and _find_background_input_blocker(hovered_widget) then
            capture_result.wheel_consumed = true
        end
    end

    if input.mouse_pressed then
        local focus_widget = _is_focusable_widget(hovered_widget) and hovered_widget or nil
        local focus_instance = focus_widget and hovered_instance or nil
        self:_set_focused_widget(focus_instance, focus_widget)
        if hovered_widget
            and (_should_consume_pointer_input(hovered_widget) or _find_background_input_blocker(hovered_widget))
        then
            capture_result.pointer_pressed_consumed = true
        end
    end
    capture_result.focused_widget_id = self._focused_widget and self._focused_widget.id or nil

    local submit_pressed = input.submit_pressed == true
    if submit_pressed and self._focused_widget and self._focused_instance then
        if _should_consume_submit_input(self._focused_widget) then
            capture_result.submit_consumed = true
        end
        if self._focused_widget.type == "Button" then
            if self:_consume_widget_click_action(self._focused_instance, self._focused_widget) then
                self:_apply_widget_action(self._focused_instance, self._focused_widget)
            end
        elseif self._focused_widget.type == "Toggle" then
            if self:_consume_widget_click_action(self._focused_instance, self._focused_widget) then
                local previous_value = self._focused_widget.props.value == true
                local next_value = not previous_value
                self._focused_widget.props.value = next_value
                self:mark_layout_dirty()
                self:_apply_widget_action(self._focused_instance, self._focused_widget)
            end
        end
    end

    if input.mouse_pressed and _is_pressable_widget(hovered_widget) then
        self._pressed_widget = hovered_widget
        hovered_widget.pressed = true
        hovered_widget._pressed_pointer_x = input.mouse_x
        hovered_widget._pressed_pointer_y = input.mouse_y
    end

    if self._pressed_widget and (not input.mouse_down) then
        local pressed_widget = self._pressed_widget
        local pressed_instance = pressed_widget.instance
        local should_trigger = hovered_widget == pressed_widget and hovered_instance == pressed_instance
        if input.mouse_released
            and (_should_consume_pointer_input(pressed_widget) or _find_background_input_blocker(pressed_widget))
        then
            capture_result.pointer_released_consumed = true
        end
        self._pressed_widget.pressed = false
        self._pressed_widget = nil
        if should_trigger then
            if pressed_widget.type == "Button" then
                if self:_consume_widget_click_action(pressed_instance, pressed_widget) then
                    self:_apply_widget_action(pressed_instance, pressed_widget)
                end
            elseif pressed_widget.type == "Toggle" then
                if self:_consume_widget_click_action(pressed_instance, pressed_widget) then
                    local previous_value = pressed_widget.props.value == true
                    local next_value = not previous_value
                    pressed_widget.props.value = next_value
                    self:mark_layout_dirty()
                    self:_apply_widget_action(pressed_instance, pressed_widget)
                end
            elseif pressed_widget.type == "SaveSlotGrid" then
                self:_apply_widget_action(pressed_instance, pressed_widget)
            end
        end
    elseif input.mouse_released
        and hovered_widget
        and (_should_consume_pointer_input(hovered_widget) or _find_background_input_blocker(hovered_widget))
    then
        capture_result.pointer_released_consumed = true
    end

    self._input_capture_result = capture_result
    return capture_result
end

local function _collect_widget_state_recursive(widget, result)
    if not widget then
        return
    end

    local props = _clone_value(widget.props or {})
    if _is_runtime_control_toggle(widget) then
        props.value = nil
    end
    result[widget.id] =
    {
        props = props,
    }
    for _, child in ipairs(widget.children or {}) do
        _collect_widget_state_recursive(child, result)
    end
end

local function _apply_widget_state_recursive(instance, widget, widget_state)
    if not widget then
        return
    end

    local state_entry = widget_state and widget_state[widget.id] or nil
    if type(state_entry) == "table" and type(state_entry.props) == "table" then
        local previous_value = widget.props and widget.props.value or nil
        widget.props = _clone_value(state_entry.props)
        if _is_runtime_control_toggle(widget) then
            widget.props = widget.props or {}
            widget.props.value = previous_value == true
        end
    end

    for _, child in ipairs(widget.children or {}) do
        _apply_widget_state_recursive(instance, child, widget_state)
    end
end

local function _collect_instance_save_entry(instance)
    if not instance then
        return nil
    end

    local instance_id = tostring(instance.id or "")
    if instance_id == "" then
        return nil
    end

    local widget_state = {}
    _collect_widget_state_recursive(instance.root, widget_state)
    return
    {
        instance_id = instance_id,
        source_guid = instance.source_guid,
        source_path = instance.source_path,
        behavior_flow = _clone_value(instance.behavior_flow),
        document = (instance.source_guid or instance.source_path) and nil or UI.clone(instance.document),
        widget_state = widget_state,
        global_overlay = instance.options and instance.options.global_overlay == true or false,
    }
end

function UIRuntime:can_save_now(options)
    local save_options = type(options) == "table" and options or {}
    local skip_instance_id_set = save_options.skip_instance_id_set or {}
    local allow_active_managed_ui_sessions = save_options.allow_active_managed_ui_sessions == true

    if type(self._detached_session_list) == "table" and #self._detached_session_list > 0 then
        return false, "当前存在仍在执行中的界面脱离流程"
    end

    for _, instance in ipairs(self._instance_list or {}) do
        local instance_id = tostring(instance and instance.id or "")
        if skip_instance_id_set[instance_id] and allow_active_managed_ui_sessions then
            goto continue
        end
        if type(instance.session_list) == "table" and #instance.session_list > 0 then
            return false, string.format("界面实例“%s”仍在执行事件流程", tostring(instance.id or "ui"))
        end
        if type(instance.queued_behavior_list) == "table" and #instance.queued_behavior_list > 0 then
            return false, string.format("界面实例“%s”仍存在待执行的行为流程", tostring(instance.id or "ui"))
        end
        if skip_instance_id_set[instance_id] then
            goto continue
        end
        ::continue::
    end

    return true
end

function UIRuntime:collect_save_state(options)
    local collect_options = type(options) == "table" and options or {}
    local skip_instance_id_set = collect_options.skip_instance_id_set or {}
    local instance_list = {}

    for _, instance in ipairs(self._instance_list or {}) do
        local instance_id = tostring(instance.id or "")
        if instance_id ~= "" and not skip_instance_id_set[instance_id] then
            local entry = _collect_instance_save_entry(instance)
            if entry then
                instance_list[#instance_list + 1] = entry
            end
        end
    end

    return
    {
        schema_version = 1,
        instance_list = instance_list,
    }
end

function UIRuntime:collect_global_overlay_state()
    local instance_list = {}
    for _, instance in ipairs(self._instance_list or {}) do
        if instance and instance.options and instance.options.global_overlay == true then
            local entry = _collect_instance_save_entry(instance)
            if entry then
                entry.global_overlay = true
                instance_list[#instance_list + 1] = entry
            end
        end
    end
    return
    {
        schema_version = 1,
        instance_list = instance_list,
    }
end

function UIRuntime.validate_save_state(state, options)
    local snapshot = type(state) == "table" and state or {}
    local validate_options = type(options) == "table" and options or {}
    local skip_instance_id_set = validate_options.skip_instance_id_set or {}
    for _, entry in ipairs(snapshot.instance_list or {}) do
        local instance_id = tostring(entry.instance_id or "")
        if instance_id == "" then
            return false, "存档中的界面实例缺少实例 ID"
        end
        if skip_instance_id_set[instance_id] then
            goto continue
        end

        local document_or_reference = entry.document
        if not document_or_reference then
            document_or_reference =
            {
                guid = entry.source_guid,
                path_hint = entry.source_path,
            }
        end

        local runtime_info, err = nil, nil
        if type(document_or_reference) == "table" and document_or_reference.root then
            runtime_info = {document = document_or_reference}
        elseif type(document_or_reference) == "table" and document_or_reference.document then
            runtime_info = document_or_reference
        else
            runtime_info, err = _resolve_runtime_document(document_or_reference,
            {
                allow_unsaved_snapshot = false,
            })
        end

        if not runtime_info then
            local source_label = tostring(entry.source_guid or entry.source_path or err or instance_id)
            return false, string.format("存档对应的界面实例 %s 无法恢复：%s", tostring(instance_id), source_label)
        end

        local valid_dependencies, validation_err = _validate_runtime_document_dependencies(runtime_info, entry)
        if valid_dependencies ~= true then
            return false, validation_err or string.format("界面实例 %s 的依赖资源无法恢复", tostring(instance_id))
        end

        ::continue::
    end

    return true
end

function UIRuntime:apply_save_state(state, options)
    local snapshot = type(state) == "table" and state or {}
    local apply_options = type(options) == "table" and options or {}
    local skip_instance_id_set = apply_options.skip_instance_id_set or {}
    local previous_suppress_sync = self._suppress_runtime_control_sync
    self._suppress_runtime_control_sync = true

    for index = #self._instance_list, 1, -1 do
        local instance = self._instance_list[index]
        local instance_id = tostring(instance and instance.id or "")
        if not skip_instance_id_set[instance_id] then
            self:close_instance(instance)
        end
    end

    for _, entry in ipairs(snapshot.instance_list or {}) do
        local instance_id = tostring(entry.instance_id or "")
        if instance_id ~= "" and not skip_instance_id_set[instance_id] then
            local document_or_reference = entry.document
            if not document_or_reference then
                document_or_reference =
                {
                    guid = entry.source_guid,
                    path_hint = entry.source_path,
                }
            end

            local instance, open_err = self:open_document(document_or_reference,
            {
                instance_id = instance_id,
                source_guid = entry.source_guid,
                source_path = entry.source_path,
                behavior_flow = entry.behavior_flow,
                global_overlay = entry.global_overlay == true,
            })
            if not instance then
                local source_label = tostring(entry.source_guid or entry.source_path or "ui")
                local detail = open_err and open_err ~= "" and string.format("%s (%s)", source_label, tostring(open_err)) or source_label
                self._suppress_runtime_control_sync = previous_suppress_sync
                self:sync_runtime_control_bindings({force = true})
                return false, string.format("存档对应的界面实例 %s 无法恢复：%s", tostring(instance_id), detail)
            end

            local runtime_info =
            {
                guid = instance.source_guid,
                path = instance.source_path,
                document = instance.document,
            }
            local valid_dependencies, validation_err = _validate_runtime_document_dependencies(runtime_info, entry)
            if valid_dependencies ~= true then
                self:close_instance(instance)
                self._suppress_runtime_control_sync = previous_suppress_sync
                self:sync_runtime_control_bindings({force = true})
                return false, validation_err or string.format("界面实例 %s 的依赖资源无法恢复", tostring(instance_id))
            end

            if instance.root then
                _apply_widget_state_recursive(instance, instance.root, entry.widget_state or {})
                self:mark_layout_dirty()
            end
        end
    end

    self._suppress_runtime_control_sync = previous_suppress_sync
    self:sync_runtime_control_bindings({force = true})
    return true
end

function UIRuntime:apply_global_overlay_state(state)
    local snapshot = type(state) == "table" and state or {}
    local previous_suppress_sync = self._suppress_runtime_control_sync
    self._suppress_runtime_control_sync = true
    for _, entry in ipairs(snapshot.instance_list or {}) do
        if entry and entry.global_overlay == true then
            local document_or_reference = entry.document
            if not document_or_reference then
                document_or_reference =
                {
                    guid = entry.source_guid,
                    path_hint = entry.source_path,
                }
            end

            local instance = self:open_document(document_or_reference,
            {
                instance_id = entry.instance_id,
                source_guid = entry.source_guid,
                source_path = entry.source_path,
                behavior_flow = entry.behavior_flow,
                global_overlay = true,
            })
            if instance and instance.root then
                _apply_widget_state_recursive(instance, instance.root, entry.widget_state or {})
                self:mark_layout_dirty()
            end
        end
    end
    self._suppress_runtime_control_sync = previous_suppress_sync
    self:sync_runtime_control_bindings({force = true})
    return true
end

function UIRuntime:begin_frame(input_state)
    self._layout_updated_this_frame = false
    if input_state ~= nil then
        self:set_input_state(input_state)
    end

    local input = self:_get_input_state()
    self:_update_layout()
    self._frame_input_processed = true
    return self:_process_input(input)
end

function UIRuntime:update(delta)
    if not self._frame_input_processed then
        self:begin_frame()
    end
    self:_update_sessions(delta)
    self:refresh_runtime_control_widgets()
    if self._layout_dirty then
        self:_update_layout()
    end
    self._layout_updated_this_frame = false
    self._frame_input_processed = false
end

local function _should_render_instance(instance, options)
    local render_options = type(options) == "table" and options or nil
    if not render_options or render_options.suppress_resource_ui ~= true then
        return true
    end
    if not instance then
        return false
    end
    local instance_options = type(instance.options) == "table" and instance.options or {}
    if instance_options.system_save_panel == true then
        return false
    end
    return not (_trim(instance.source_guid) or _trim(instance.source_path))
end

function UIRuntime:render(options)
    for _, instance in ipairs(self._instance_list) do
        if _should_render_instance(instance, options) then
            _render_widget(instance.root, 1)
        end
    end
end

function UIRuntime:destroy()
    local previous_suppress_sync = self._suppress_runtime_control_sync
    self._suppress_runtime_control_sync = true
    for index = #self._instance_list, 1, -1 do
        self:close_instance(self._instance_list[index])
    end
    for _, session in ipairs(self._detached_session_list) do
        _destroy_runtime_session(session)
    end
    self._detached_session_list = {}
    self._instance_list = {}
    self._instance_by_id = {}
    self._closed_instance_result_pool = {}
    self._pressed_widget = nil
    self._suppress_runtime_control_sync = previous_suppress_sync
end

return UIRuntime

local imgui = Engine.ImGUI

local Class = require("application.framework.class")
local FlowRuntimeError = require("application.framework.flow_runtime_error")
local GlobalContext = require("application.framework.global_context")
local PinRegistry = require("application.framework.pin_registry")
local ResourceReferenceField = require("application.framework.resource_reference_field")

local size_icon <const> = imgui.ImVec2(24, 24)
local default_pin_item_spacing <const> = 8
local compact_frame_padding_x <const> = 4
local rounded_frame_threshold <const> = 6
local max_rounded_widget_width_extra <const> = 48
local rounded_type_width_extra =
{
    vector2 = 36,
    float = 18,
    int = 18,
    string = 24,
    color = 16,
}
local icon_visual_right_padding_cache = {}
local icon_alignment_right_padding_cache = {}
local widget_interaction_hold_frames <const> = 2

local function _normalize_display_name(name)
    if type(name) ~= "string" then
        return name
    end

    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil
    end
    return trimmed
end

local function _calc_text_width(text)
    if not text or text == "" then
        return 0
    end
    return imgui.CalcTextSize(text).x
end

local function _is_point_in_rect(point, rect_min, rect_max)
    if not point or not rect_min or not rect_max then
        return false
    end

    local ok, point_x, point_y, min_x, min_y, max_x, max_y = pcall(function()
        return point.x, point.y, rect_min.x, rect_min.y, rect_max.x, rect_max.y
    end)
    if not ok then
        return false
    end

    point_x, point_y = tonumber(point_x), tonumber(point_y)
    min_x, min_y = tonumber(min_x), tonumber(min_y)
    max_x, max_y = tonumber(max_x), tonumber(max_y)
    if not point_x or not point_y or not min_x or not min_y or not max_x or not max_y then
        return false
    end
    if point_x ~= point_x or point_y ~= point_y or min_x ~= min_x or min_y ~= min_y or max_x ~= max_x or max_y ~= max_y then
        return false
    end

    return point_x >= min_x
        and point_y >= min_y
        and point_x <= max_x
        and point_y <= max_y
end

local function _normalize_style_binding(binding)
    if type(binding) ~= "table" then
        return nil
    end

    local domain = type(binding.domain) == "string" and binding.domain:match("^%s*(.-)%s*$") or nil
    local field = type(binding.field) == "string" and binding.field:match("^%s*(.-)%s*$") or nil
    if not domain or domain == "" or not field or field == "" then
        return nil
    end

    return
    {
        domain = domain,
        field = field,
        policy = binding.policy or "linked_or_style_then_pin",
        type_id = binding.type_id,
    }
end

local function _get_item_spacing_x()
    local success, style = pcall(imgui.GetStyle)
    if success and style and style.ItemSpacing and type(style.ItemSpacing.x) == "number" then
        return style.ItemSpacing.x
    end
    return default_pin_item_spacing
end

local function _get_rounded_widget_width_extra()
    local success, style = pcall(imgui.GetStyle)
    if not success or not style then
        return 0
    end

    local frame_rounding = tonumber(style.FrameRounding) or 0
    if frame_rounding <= rounded_frame_threshold then
        return 0
    end

    local frame_padding_x = style.FramePadding and tonumber(style.FramePadding.x) or compact_frame_padding_x
    local extra = math.max(0, (frame_padding_x - compact_frame_padding_x) * 2)
    return math.min(max_rounded_widget_width_extra, extra)
end

local function _get_type_widget_width_extra(type_id, rounded_extra)
    if rounded_extra <= 0 then
        return 0
    end
    return rounded_type_width_extra[type_id] or 0
end

local function _get_icon_visual_right_padding_fallback(icon_type, is_filled)
    local width = size_icon.x
    local outline_scale = width / 24.0

    if icon_type == imgui.NodeEditor.IconType.Flow then
        return is_filled and 4 or 3
    end

    local rect_offset = -math.floor(width * 0.25 * 0.25)
    local rect_center_x = width * 0.5 + rect_offset * 0.5

    if icon_type == imgui.NodeEditor.IconType.Circle
        or icon_type == imgui.NodeEditor.IconType.Square
        or icon_type == imgui.NodeEditor.IconType.RoundSquare then
        local outer_radius = width * 0.25
        if not is_filled then
            outer_radius = outer_radius - 0.5 + outline_scale
        end
        local visible_right = rect_center_x + outer_radius
        return math.max(0, width - visible_right)
    end

    if icon_type == imgui.NodeEditor.IconType.Diamond then
        local outer_radius = 0.607 * width * 0.5
        if not is_filled then
            outer_radius = outer_radius - 0.5 + outline_scale
        end
        local visible_right = rect_center_x + outer_radius
        return math.max(0, width - visible_right)
    end

    if icon_type == imgui.NodeEditor.IconType.Grid then
        return 2
    end

    return 0
end

local function _get_icon_visual_right_padding(icon_type, is_filled)
    local cache_key = string.format("%s:%s", tostring(icon_type), is_filled and "1" or "0")
    local cached = icon_visual_right_padding_cache[cache_key]
    if type(cached) == "number" then
        return cached
    end

    if imgui.NodeEditor and type(imgui.NodeEditor.GetIconVisualRightPadding) == "function" then
        local success, padding = pcall(imgui.NodeEditor.GetIconVisualRightPadding, size_icon, icon_type, is_filled)
        if success and type(padding) == "number" then
            padding = math.max(0, padding)
            icon_visual_right_padding_cache[cache_key] = padding
            return padding
        end
    end

    local padding = _get_icon_visual_right_padding_fallback(icon_type, is_filled)
    icon_visual_right_padding_cache[cache_key] = padding
    return padding
end

local function _get_icon_alignment_right_padding(icon_type)
    local cached = icon_alignment_right_padding_cache[icon_type]
    if type(cached) == "number" then
        return cached
    end

    -- 输出列对齐需要对同一种图标保持稳定，不能因为空心/填充态切换而改变前置补偿。
    -- 这里取两种状态中“更靠右”的那一档，即更小的右侧留白，从而避免已连接时整行被向右推开。
    local padding_unfilled = _get_icon_visual_right_padding(icon_type, false)
    local padding_filled = _get_icon_visual_right_padding(icon_type, true)
    local padding = math.min(padding_unfilled, padding_filled)
    icon_alignment_right_padding_cache[icon_type] = padding
    return padding
end

local BlueprintPin = Class.define("BlueprintPin")

function BlueprintPin:ctor(id, owner_id, is_output, type_id, icon_type, name, color)
    self._id = imgui.NodeEditor.PinId(id)
    self._owner_id = owner_id
    self._linked_pin_id = nil
    self._type_id = type_id
    self._is_output = is_output
    self._icon_type = icon_type
    self._name = _normalize_display_name(name)
    self._on_tick_widgets = nil
    self._color = color
    self._def = nil
    self._options = {}
    self._last_draw_width = 0
    self._compact_mode = false
    self._cached_name_text = nil
    self._cached_name_line_height = nil
    self._cached_name_width = nil
    self._cached_widget_visible = nil
    self._cached_layout_measure_revision = nil
    self._cached_layout_widget_width = nil
    self._cached_width_input = nil
    self._cached_option_width_input = nil
    self._cached_widget_width = nil
    self._cached_row_widget_width = nil
    self._cached_row_label_width = nil
    self._cached_row_spacing = nil
    self._cached_estimated_row_width = nil
    self._name_tint_color = nil
    self._name_overlay_tooltip_text = nil
    self._key = nil
    self._legacy_index = nil
    self._style_binding = nil
    self._style_local_override = false
    self._widget_hovered = false
    self._widget_active = false
    self._widget_focused = false
    self._widget_clicked = false
    self._widget_interacting = false
    self._widget_focus_owned = false
    self._widget_interaction_hold_frames = 0
    self._widget_rect_min = nil
    self._widget_rect_max = nil
    self._owner_blueprint = nil
end

function BlueprintPin:_is_widget_visible()
    return self._on_tick_widgets ~= nil
end

function BlueprintPin:_get_name_width()
    local text = self._name or ""
    local line_height = imgui.GetTextLineHeight()
    if self._cached_name_text ~= text or self._cached_name_line_height ~= line_height then
        self._cached_name_text = text
        self._cached_name_line_height = line_height
        self._cached_name_width = _calc_text_width(text)
    end
    return self._cached_name_width or 0
end

function BlueprintPin:_get_widget_width()
    local option = self._options or {}
    local widget_visible = self:_is_widget_visible()
    local layout_measure_revision = rawget(self, "_layout_measure_revision")
    local layout_widget_width = rawget(self, "_layout_widget_width")
    local width_input = rawget(self, "_width_input")
    local option_width_input = option.width_input
    local rounded_widget_width_extra = _get_rounded_widget_width_extra()
    local widget_width_extra = rounded_widget_width_extra + _get_type_widget_width_extra(self._type_id, rounded_widget_width_extra)

    if self._cached_widget_visible ~= widget_visible
        or self._cached_layout_measure_revision ~= layout_measure_revision
        or self._cached_layout_widget_width ~= layout_widget_width
        or self._cached_width_input ~= width_input
        or self._cached_option_width_input ~= option_width_input
        or self._cached_widget_width_extra ~= widget_width_extra then
        local width = 0
        if widget_visible and type(self._measure_widget_width) == "function" then
            local success, measured_width = pcall(self._measure_widget_width, self)
            if success and type(measured_width) == "number" and measured_width > 0 then
                width = measured_width
            end
        end

        if width <= 0 and widget_visible and type(layout_widget_width) == "number" and layout_widget_width > 0 then
            width = layout_widget_width
        end
        if width <= 0 and widget_visible and type(width_input) == "number" and width_input > 0 then
            width = width_input
        end
        if width <= 0 and widget_visible and type(option_width_input) == "number" and option_width_input > 0 then
            width = option_width_input
        end
        if width > 0 then
            width = math.max(1, math.floor(width + widget_width_extra + 0.5))
        end

        self._cached_widget_visible = widget_visible
        self._cached_layout_measure_revision = layout_measure_revision
        self._cached_layout_widget_width = layout_widget_width
        self._cached_width_input = width_input
        self._cached_option_width_input = option_width_input
        self._cached_widget_width_extra = widget_width_extra
        self._cached_widget_width = width
    end

    return self._cached_widget_width or 0
end

function BlueprintPin:get_widget_input_width(base_width)
    local width = tonumber(base_width) or 0
    if width <= 0 then
        return width
    end
    local rounded_widget_width_extra = _get_rounded_widget_width_extra()
    local widget_width_extra = rounded_widget_width_extra + _get_type_widget_width_extra(self._type_id, rounded_widget_width_extra)
    return math.max(1, math.floor(width + widget_width_extra + 0.5))
end

function BlueprintPin:get_estimated_row_width()
    local widget_width = self:_get_widget_width()
    local label_width = self:_get_name_width()
    local spacing = _get_item_spacing_x()
    if self._cached_estimated_row_width ~= nil
        and self._cached_row_widget_width == widget_width
        and self._cached_row_label_width == label_width
        and self._cached_row_spacing == spacing then
        return self._cached_estimated_row_width
    end

    local width = size_icon.x

    if widget_width > 0 then
        width = width + spacing + widget_width
    end
    if label_width > 0 then
        width = width + spacing + label_width
    end

    self._cached_row_widget_width = widget_width
    self._cached_row_label_width = label_width
    self._cached_row_spacing = spacing
    self._cached_estimated_row_width = width
    return width
end

function BlueprintPin:get_layout_row_width()
    return math.max(self._last_draw_width or 0, self:get_estimated_row_width())
end

function BlueprintPin:get_output_alignment_width()
    local width = self:get_layout_row_width()
    if not self._is_output then
        return width
    end
    return width - _get_icon_alignment_right_padding(self._icon_type)
end

function BlueprintPin:_draw_name()
    if not self._name then
        return
    end

    if self._name_tint_color then
        imgui.TextColored(self._name_tint_color, self._name)
    else
        imgui.Text(self._name)
    end

    if self._name_overlay_tooltip_text and imgui.IsItemHovered() then
        ResourceReferenceField.queue_overlay_tooltip(self._name_overlay_tooltip_text)
    end
end

function BlueprintPin:_reset_widget_interaction_state()
    self._widget_hovered = false
    self._widget_active = false
    self._widget_focused = false
    self._widget_clicked = false
    self._widget_interacting = false
    self._widget_focus_owned = false
    self._widget_interaction_hold_frames = 0
    self._widget_rect_min = nil
    self._widget_rect_max = nil
end

function BlueprintPin:_queue_owner_node_selection()
    if not self._owner_id then
        return
    end

    local node_id = self._owner_id:get()
    local blueprint = self._owner_blueprint
    if not blueprint then
        local node = self:_get_runtime_node()
        blueprint = node and node._blueprint or nil
    end
    if not blueprint then
        return
    end

    blueprint._flow_pending_widget_select_node_id = node_id
end

function BlueprintPin:_draw_widget_group()
    self._widget_hovered = false
    self._widget_active = false
    self._widget_focused = false
    self._widget_clicked = false

    imgui.BeginGroup()
        self:_on_tick_widgets()
    imgui.EndGroup()

    local rect_min = imgui.GetItemRectMin()
    local rect_max = imgui.GetItemRectMax()
    local widget_rect_min = self._widget_rect_min or {}
    local widget_rect_max = self._widget_rect_max or {}
    widget_rect_min.x, widget_rect_min.y = rect_min.x, rect_min.y
    widget_rect_max.x, widget_rect_max.y = rect_max.x, rect_max.y
    self._widget_rect_min = widget_rect_min
    self._widget_rect_max = widget_rect_max
    local mouse_pos = imgui.GetMousePos()
    local rect_hovered = _is_point_in_rect(mouse_pos, rect_min, rect_max)
    local item_hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false
    local hovered = item_hovered or rect_hovered
    local item_active = imgui.IsItemActive and imgui.IsItemActive() or false
    local item_focused = imgui.IsItemFocused and imgui.IsItemFocused() or false
    local left_clicked = imgui.IsMouseClicked and imgui.IsMouseClicked(0, false) or false
    local mouse_clicked = left_clicked
        or (imgui.IsMouseClicked and (imgui.IsMouseClicked(1, false) or imgui.IsMouseClicked(2, false)) or false)
    local clicked = rect_hovered and left_clicked == true

    if clicked then
        self:_queue_owner_node_selection()
        self._widget_focus_owned = true
    elseif mouse_clicked and not hovered then
        self._widget_focus_owned = false
    end

    if item_active or item_focused then
        self._widget_focus_owned = true
    end

    local any_active = imgui.IsAnyItemActive and imgui.IsAnyItemActive() or false
    local any_focused = imgui.IsAnyItemFocused and imgui.IsAnyItemFocused() or false
    local owns_focus = self._widget_focus_owned == true and (any_active or any_focused)
    if not owns_focus and not hovered then
        self._widget_focus_owned = false
    end

    local active = item_active or (self._widget_focus_owned == true and any_active)
    local focused = item_focused or (self._widget_focus_owned == true and any_focused)
    if hovered or clicked or active or focused then
        self._widget_interaction_hold_frames = widget_interaction_hold_frames
    elseif (self._widget_interaction_hold_frames or 0) > 0 then
        self._widget_interaction_hold_frames = self._widget_interaction_hold_frames - 1
    end

    self._widget_hovered = hovered
    self._widget_active = active
    self._widget_focused = focused
    self._widget_clicked = clicked
    self._widget_interacting = hovered
        or clicked
        or active
        or focused
        or (self._widget_interaction_hold_frames or 0) > 0
end

function BlueprintPin:on_update(alignment_width)
    local kind = imgui.NodeEditor.PinKind.Input
    if self._is_output then kind = imgui.NodeEditor.PinKind.Output end
    local show_widget = self:_is_widget_visible()

    if self._is_output and alignment_width and alignment_width > 0 then
        local spacer_width = alignment_width - self:get_output_alignment_width()
        if spacer_width > 0.5 then
            imgui.Dummy(imgui.ImVec2(spacer_width, 0))
            imgui.SameLine(0, 0)
        end
    end

    local row_begin = imgui.GetCursorScreenPos()
    if not show_widget then
        self:_reset_widget_interaction_state()
    end
    if self._is_output then
        if show_widget then self:_draw_widget_group() imgui.SameLine() end
        self:_draw_name()
        if show_widget or self._name then imgui.SameLine() end
        imgui.NodeEditor.BeginPin(self._id, kind)
            imgui.NodeEditor.Icon(size_icon, self._icon_type, self._linked_pin_id, self._color)
        imgui.NodeEditor.EndPin()
    else
        imgui.NodeEditor.BeginPin(self._id, kind)
            imgui.NodeEditor.Icon(size_icon, self._icon_type, self._linked_pin_id, self._color)
        imgui.NodeEditor.EndPin()
        if show_widget or self._name then imgui.SameLine() end
        if show_widget then self:_draw_widget_group() imgui.SameLine() end
        self:_draw_name()
    end

    self._last_draw_width = math.max(imgui.GetItemRectMax().x - row_begin.x, self:get_estimated_row_width())
end

function BlueprintPin:on_load(data)
    if data and rawget(data, "name") ~= nil then
        self._name = _normalize_display_name(data.name)
    end
    if self._key == nil and data and rawget(data, "key") ~= nil then
        self._key = data.key
    end
    self._style_local_override = _normalize_style_binding(self._style_binding) ~= nil
        and data and data.style_local_override == true
        or false
end

function BlueprintPin:on_save()
    -- SAVE TRACE: base pin_data collected inside node input/output pin lists.
    -- Fields: id, type_id, is_output, name, key; concrete pin types may append val.
    local data = {
        id = self._id:get(),
        type_id = self._type_id,
        is_output = self._is_output,
        name = self._name,
        key = self._key,
    }
    if self._style_local_override == true then
        data.style_local_override = true
    end
    return data
end

function BlueprintPin:set_val(val)

end

function BlueprintPin:get_val()

end

function BlueprintPin:set_style_local_override(enabled)
    self._style_local_override = enabled == true and _normalize_style_binding(self._style_binding) ~= nil
end

function BlueprintPin:has_style_local_override()
    return self._style_local_override == true
end

function BlueprintPin:_get_runtime_node()
    if self._owner_id then
        return GlobalContext.runtime_find_node(self._owner_id:get())
    end
    return nil
end

function BlueprintPin:_get_runtime_context(extra)
    local context = {}
    if type(extra) == "table" then
        for key, value in pairs(extra) do
            context[key] = value
        end
    end

    context.pin = self
    context.node = context.node or self:_get_runtime_node()
    context.blueprint = context.blueprint or (context.node and context.node._blueprint) or nil
    return context
end

function BlueprintPin:_describe_expected_type(type_id)
    local definition = PinRegistry.get(type_id)
    if definition and definition.runtime and definition.runtime.display_name then
        return definition.runtime.display_name
    end
    if definition and definition.display_name then
        return definition.display_name
    end
    return tostring(type_id or self._type_id or "值")
end

function BlueprintPin:_describe_pin_name()
    return FlowRuntimeError.describe_pin(self)
end

function BlueprintPin:_resolve_runtime_source_pin()
    if self._is_output or not self._linked_pin_id then
        return nil, nil
    end

    local linked_pin_id = self._linked_pin_id:get()
    local linked_pin = GlobalContext.runtime_find_pin(linked_pin_id)
    if linked_pin then
        return linked_pin, nil
    end

    return nil,
    {
        code = "missing_link",
        linked_pin_id = linked_pin_id,
    }
end

function BlueprintPin:_resolve_runtime_input_value(local_value)
    if self._is_output then
        return local_value
    end

    if self._linked_pin_id then
        local linked_pin = self:_resolve_runtime_source_pin()
        if linked_pin then
            return linked_pin:get_val()
        end
        return nil
    end

    return local_value
end

function BlueprintPin:_resolve_value_for_expectation(expectation)
    if self._is_output then
        return self:get_val()
    end

    if self._linked_pin_id then
        local linked_pin, link_err = self:_resolve_runtime_source_pin()
        if not linked_pin then
            return nil, link_err, nil
        end
        return linked_pin:get_val(), nil,
        {
            source = "linked",
            source_pin = linked_pin,
        }
    end

    local local_value = self:get_val()
    local binding = self._style_binding
    if not binding then
        return local_value, nil,
        {
            source = "local",
        }
    end

    local expected = self:_normalize_check_expectation(expectation)
    local StyleManager = require("application.framework.style_manager")
    local style_value, found_style_value, style_field = StyleManager.try_resolve_pin_binding(self, binding, expected)
    local policy = binding.policy or "linked_or_style_then_pin"

    if policy == "style_only_optional" then
        if found_style_value then
            return style_value, nil,
            {
                source = "style",
                style_field = style_field,
            }
        end
        return nil, nil,
        {
            source = "style",
            style_field = style_field,
        }
    end

    if self:has_style_local_override() then
        return local_value, nil,
        {
            source = "local",
        }
    end

    if policy == "pin_then_style" then
        if local_value ~= nil then
            return local_value, nil,
            {
                source = "local",
            }
        end
        if found_style_value then
            return style_value, nil,
            {
                source = "style",
                style_field = style_field,
            }
        end
        return local_value, nil,
        {
            source = "local",
        }
    end

    if found_style_value then
        return style_value, nil,
        {
            source = "style",
            style_field = style_field,
        }
    end

    return local_value, nil,
    {
        source = "local",
    }
end

function BlueprintPin:get_raw_val()
    local value, err = self:_resolve_value_for_expectation({type_id = self._type_id})
    return value, err
end

function BlueprintPin:_normalize_check_expectation(expectation)
    if expectation == nil then
        return {type_id = self._type_id}
    end

    if type(expectation) == "string" then
        return {type_id = expectation}
    end

    if type(expectation) == "table" then
        local normalized = {}
        for key, value in pairs(expectation) do
            normalized[key] = value
        end
        normalized.type_id = normalized.type_id or self._type_id
        return normalized
    end

    return {type_id = self._type_id}
end

function BlueprintPin:_get_validator(type_id)
    local definition = PinRegistry.get(type_id)
    local runtime = definition and definition.runtime or nil
    local validate = runtime and runtime.validate or nil
    return definition, validate
end

function BlueprintPin:_normalize_validation_error(err, opts, value)
    local normalized = {}
    if type(err) == "table" then
        for key, field in pairs(err) do
            normalized[key] = field
        end
    end

    normalized.code = normalized.code or "validation_failed"
    normalized.expected_type_id = normalized.expected_type_id or opts.type_id or self._type_id
    normalized.expected_display_name = normalized.expected_display_name or self:_describe_expected_type(normalized.expected_type_id)
    normalized.actual_type = normalized.actual_type or type(value)
    normalized.actual_class_name = normalized.actual_class_name
        or (normalized.actual_type == "table" and FlowRuntimeError.get_class_name(value) or nil)
    return normalized
end

function BlueprintPin:_build_validation_message(err)
    local pin_name = self:_describe_pin_name()
    local node = self:_get_runtime_node()
    local node_id = node and node._id and node._id:get() or "?"
    local expected_name = err.expected_display_name or self:_describe_expected_type(err.expected_type_id)

    if err.message and err.message ~= "" then
        return string.format("节点[#%s]：输入引脚“%s”%s", tostring(node_id), pin_name, err.message)
    end

    if err.code == "missing_link" then
        return string.format("节点[#%s]：输入引脚“%s”连接的上游引脚已失效", tostring(node_id), pin_name)
    end
    if err.code == "flow_value_forbidden" then
        return string.format("节点[#%s]：流程引脚“%s”不能作为数据值读取", tostring(node_id), pin_name)
    end
    if err.code == "nil_value" then
        return string.format("节点[#%s]：输入引脚“%s”需要“%s”，但当前值为空", tostring(node_id), pin_name, expected_name)
    end
    if err.code == "int_non_integral" then
        return string.format("节点[#%s]：输入引脚“%s”需要“%s”，但当前值“%s”不能安全转换为整数",
            tostring(node_id), pin_name, expected_name, tostring(err.actual_value))
    end
    if err.code == "number_not_finite" then
        return string.format("节点[#%s]：输入引脚“%s”需要“%s”，但当前值不是有限数字",
            tostring(node_id), pin_name, expected_name)
    end
    if err.code == "string_empty" then
        return string.format("节点[#%s]：输入引脚“%s”需要非空文本", tostring(node_id), pin_name)
    end
    if err.code == "resource_unset" then
        return string.format("节点[#%s]：输入引脚“%s”未设置%s", tostring(node_id), pin_name, expected_name)
    end
    if err.code == "resource_unavailable" then
        local detail = err.issue and err.issue ~= "" and string.format("（%s）", err.issue) or ""
        return string.format("节点[#%s]：输入引脚“%s”引用的%s当前不可用%s",
            tostring(node_id), pin_name, expected_name, detail)
    end
    if err.code == "instance_mismatch" then
        local actual_name = err.actual_class_name or err.actual_type or "未知类型"
        return string.format("节点[#%s]：输入引脚“%s”需要“%s”，但当前值实际为“%s”",
            tostring(node_id), pin_name, expected_name, actual_name)
    end
    if err.code == "runtime_object_stale" then
        return string.format("节点[#%s]：输入引脚“%s”引用的运行时对象已失效，请从当前场景重新获取对象",
            tostring(node_id), pin_name)
    end

    local actual_name = err.actual_class_name or err.actual_type or "未知类型"
    return string.format("节点[#%s]：输入引脚“%s”需要“%s”，但当前值类型为“%s”",
        tostring(node_id), pin_name, expected_name, actual_name)
end

function BlueprintPin:try_check_val(expectation)
    local opts = self:_normalize_check_expectation(expectation)
    local raw_value, raw_err, value_meta = self:_resolve_value_for_expectation(opts)
    if raw_err then
        return nil, false, self:_normalize_validation_error(raw_err, opts, raw_value)
    end

    local _, validate = self:_get_validator(opts.type_id)
    if type(validate) ~= "function" then
        return raw_value, true, nil
    end

    local source_pin = value_meta and value_meta.source_pin or nil

    local ok, normalized_value, err = validate(raw_value, opts, self:_get_runtime_context(
    {
        expected_type_id = opts.type_id,
        source_pin = source_pin,
        source_type_id = source_pin and source_pin._type_id or nil,
        style_field = value_meta and value_meta.style_field or nil,
        value_source = value_meta and value_meta.source or nil,
    }))

    if ok then
        return normalized_value, true, nil
    end

    return nil, false, self:_normalize_validation_error(err, opts, raw_value)
end

function BlueprintPin:check_val(expectation)
    local value, ok, err = self:try_check_val(expectation)
    if ok then
        return value
    end

    FlowRuntimeError.raise("pin_validation_error", self:_build_validation_message(err), self:_get_runtime_context(
    {
        error = err,
        expected_type_id = err and err.expected_type_id or nil,
    }))
end

function BlueprintPin:try_check_instance(target_class, opts)
    local expectation = {}
    if type(opts) == "table" then
        for key, value in pairs(opts) do
            expectation[key] = value
        end
    end
    expectation.type_id = expectation.type_id or "object"
    expectation.class = target_class
    expectation.expected_display_name = expectation.expected_display_name or FlowRuntimeError.get_class_name(target_class)
    return self:try_check_val(expectation)
end

function BlueprintPin:check_instance(target_class, opts)
    local value, ok, err = self:try_check_instance(target_class, opts)
    if ok then
        return value
    end

    FlowRuntimeError.raise("pin_validation_error", self:_build_validation_message(err), self:_get_runtime_context(
    {
        error = err,
        expected_type_id = err and err.expected_type_id or "object",
    }))
end

function BlueprintPin:get_definition()
    return self._def
end

function BlueprintPin:get_key()
    return self._key
end

function BlueprintPin:get_display_name()
    return self._name or (self._def and self._def.display_name) or self._key or self._type_id
end

function BlueprintPin:get_options()
    return self._options
end

function BlueprintPin:get_style_binding()
    return _normalize_style_binding(self._style_binding)
end

return BlueprintPin

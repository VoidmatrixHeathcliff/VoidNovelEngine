local imgui = Engine.ImGUI

local Common = require("application.framework.builtin_pin_common")
local ResourceIndex = require("application.framework.resource_index")
local ResourceReferenceField = require("application.framework.resource_reference_field")

local BlueprintPin = Common.BlueprintPin
local LogManager = Common.LogManager
local UndoManager = Common.UndoManager
local GlobalContext = Common.GlobalContext
local ResourcesManager = Common.ResourcesManager

local module = {}
local alert_color <const> = imgui.ImVec4(imgui.ImColor(197, 61, 67, 255).value)
local resource_field_default_width <const> = 140
local dynamic_width_extra_padding <const> = 16
local asset_type_label_map <const> =
{
    texture = "纹理",
    audio = "音频",
    video = "视频",
    font = "字体",
    shader = "着色器",
    ui = "界面",
}

local function _clone_reference(reference)
    if type(reference) ~= "table" then
        return nil
    end

    local copy = {}
    for key, value in pairs(reference) do
        copy[key] = value
    end
    return copy
end

local function _same_reference(left, right)
    if left == nil and right == nil then
        return true
    end
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    return tostring(left.guid or "") == tostring(right.guid or "")
        and tostring(left.path_hint or "") == tostring(right.path_hint or "")
end

local function _build_display_text(asset_type, reference)
    local text = ResourceIndex.get_display_path(asset_type, reference)
    if text and text ~= "" then
        return text
    end
    return ""
end

local function _get_style_vec_x(style, field_name, fallback)
    local value = style and style[field_name] or nil
    if value and type(value.x) == "number" then
        return value.x
    end
    return fallback or 0
end

local function _get_clear_button_reserve(style)
    local icon_size = imgui.GetTextLineHeight()
    return icon_size
        + _get_style_vec_x(style, "FramePadding", 0) * 2
        + _get_style_vec_x(style, "ItemSpacing", 0)
end

local function _bump_layout_revision(pin)
    pin._layout_measure_revision = (pin._layout_measure_revision or 0) + 1
end

local function _get_resource_field_base_width(pin)
    local base_width = tonumber(pin._width_input) or resource_field_default_width
    if pin._dynamic_width_input ~= true then
        return base_width
    end

    local display_text = pin._prev_text or ""
    if display_text == "" then
        return base_width
    end

    local style = imgui.GetStyle()
    local text_width = imgui.CalcTextSize(display_text).x
    local button_text_reserve = math.max(20, _get_style_vec_x(style, "FramePadding", 4) * 2 + 4)
    local desired_width = text_width
        + button_text_reserve
        + _get_clear_button_reserve(style)
        + dynamic_width_extra_padding
    if type(pin._dynamic_width_max) == "number" and pin._dynamic_width_max > 0 then
        desired_width = math.min(desired_width, pin._dynamic_width_max)
    end
    return math.max(base_width, math.ceil(desired_width))
end

local function _get_asset_type_label(asset_type)
    return asset_type_label_map[asset_type] or asset_type or "资源"
end

local function _resolve_issue_text(asset_type, reference, custom_issue_text)
    if custom_issue_text and custom_issue_text ~= "" then
        return custom_issue_text
    end

    if reference == nil then
        return string.format("当前未设置%s资源", _get_asset_type_label(asset_type))
    end

    if ResourceIndex.resolve_guid(asset_type, reference) == nil then
        return "无效的资源引用"
    end

    return nil
end

local runtime_finder_pool =
{
    texture = function(reference)
        return ResourcesManager.find_texture(reference)
    end,
    audio = function(reference)
        return ResourcesManager.find_audio(reference)
    end,
    video = function(reference)
        return ResourcesManager.find_video(reference)
    end,
    font = function(reference)
        return ResourcesManager.find_font(reference)
    end,
    shader = function(reference)
        return ResourcesManager.find_shader(reference)
    end,
}

function module.setup(pin, ctx, asset_type, finder, on_preview, describe_issue)
    local id = ctx.pin_id
    local extra_args = ctx.options
    on_preview = on_preview or function() end

    local _base_load = function(self, data)
        return BlueprintPin.on_load(self, data)
    end
    local _base_save = function(self)
        return BlueprintPin.on_save(self)
    end

    pin._resource_ref = nil
    pin._prev_text = ""
    pin._width_input = resource_field_default_width
    if extra_args then
        pin._width_input = extra_args.width_input or pin._width_input
        pin._dynamic_width_input = extra_args.dynamic_width_input == true
        pin._dynamic_width_max = tonumber(extra_args.dynamic_width_max)
    end
    if pin._dynamic_width_input == true then
        pin._measure_widget_width = function(self)
            return _get_resource_field_base_width(self)
        end
    end

    pin._apply_resource_value = function(self, value)
        self._resource_ref = ResourceIndex.make_reference(asset_type, value)
        self._prev_text = _build_display_text(asset_type, self._resource_ref)
        _bump_layout_revision(self)
    end

    pin._record_resource_change = function(self, old_value, new_value)
        local old_ref = _clone_reference(self._resource_ref)
        local old_text = self._prev_text
        local old_style_override = self:has_style_local_override()

        local new_ref = ResourceIndex.make_reference(asset_type, new_value)
        if _same_reference(old_ref, new_ref) then
            return false
        end
        local new_text = _build_display_text(asset_type, new_ref)
        self._resource_ref = new_ref
        self._prev_text = new_text
        self:set_style_local_override(true)
        _bump_layout_revision(self)

        UndoManager.record(function(data)
                self._resource_ref = _clone_reference(data.old_ref)
                self._prev_text = data.old_text
                self:set_style_local_override(data.old_style_override)
                _bump_layout_revision(self)
            end, function(data)
                self._resource_ref = _clone_reference(data.new_ref)
                self._prev_text = data.new_text
                self:set_style_local_override(data.new_style_override)
                _bump_layout_revision(self)
            end,
            {
                old_ref = old_ref,
                old_text = old_text,
                old_style_override = old_style_override,
                new_ref = _clone_reference(new_ref),
                new_text = new_text,
                new_style_override = true,
            })
        return true
    end

    pin._on_tick_widgets = function(self)
        local issue_text = nil
        if self._is_output or (not self._is_output and not self._linked_pin_id) then
            local reference = self:get_reference()
            issue_text = _resolve_issue_text(
                asset_type,
                reference,
                describe_issue and describe_issue(self, reference) or nil)
        end

        self._name_tint_color = issue_text and alert_color or nil
        self._name_overlay_tooltip_text = issue_text

        imgui.BeginDisabled(not self._is_output and self._linked_pin_id)
            local popup_id = string.format("resource_pin_picker_%s_%s", asset_type, id)
            local field_width = self:get_widget_input_width(_get_resource_field_base_width(self))
            local selected_value, changed, invalid_payload = ResourceReferenceField.draw(
            {
                popup_id = popup_id,
                asset_type = asset_type,
                value = self._resource_ref,
                width = field_width,
                disabled = not self._is_output and self._linked_pin_id ~= nil,
                allow_clear = true,
                use_node_editor_overlay = true,
                alert_text = issue_text,
            })
            if invalid_payload then
                LogManager.log(
                    string.format("错误的引脚赋值类型，使用“%s”类型资产为“%s”类型引脚赋值", invalid_payload.type, asset_type),
                    "warning")
            elseif changed then
                self:_record_resource_change(self._resource_ref, selected_value)
            end

            if self._is_output or (not self._is_output and not self._linked_pin_id) then
                on_preview(self, self:get_reference())
            end
        imgui.EndDisabled()
    end

    pin.on_load = function(self, data)
        _base_load(self, data)
        self:_apply_resource_value(data.val)
    end

    pin.on_save = function(self)
        local data = _base_save(self)
        -- SAVE TRACE: resource pin appends a cloned asset reference as val.
        data.val = _clone_reference(self._resource_ref)
        return data
    end

    pin.set_val = function(self, val)
        self:_apply_resource_value(val)
    end

    pin.get_reference = function(self)
        if self._is_output then
            return _clone_reference(self._resource_ref)
        end
        if self._linked_pin_id then
            local linked_pin = self:_resolve_runtime_source_pin()
            if linked_pin and linked_pin.get_reference then
                return linked_pin:get_reference()
            end
            return nil
        end
        return _clone_reference(self._resource_ref)
    end

    pin.get_val = function(self)
        if self._is_output then
            return finder(self._resource_ref)
        end
        if self._linked_pin_id then
            local linked_pin = self:_resolve_runtime_source_pin()
            if linked_pin then
                return linked_pin:get_val()
            end
            return nil
        end
        return finder(self._resource_ref)
    end
end

function module.make_runtime_validator(asset_type, describe_issue)
    return function(value, opts, ctx)
        local pin = ctx and ctx.pin or nil
        local expected_display_name = opts and opts.expected_display_name or _get_asset_type_label(asset_type)
        local reference = ResourceIndex.make_reference(asset_type, value)
        local pin_reference = pin and pin.get_reference and pin:get_reference() or nil
        local runtime_value = value
        local runtime_value_type = type(runtime_value)
        local has_resolved_runtime_value = runtime_value ~= nil
            and reference == nil
            and (runtime_value_type == "table" or runtime_value_type == "userdata")

        if reference ~= nil then
            local runtime_finder = runtime_finder_pool[asset_type]
            if runtime_finder then
                runtime_value = runtime_finder(reference)
            end
        elseif pin_reference ~= nil then
            reference = pin_reference
        end

        if pin and pin._linked_pin_id then
            local linked_pin = pin:_resolve_runtime_source_pin()
            if not linked_pin then
                return false, nil,
                {
                    code = "missing_link",
                    expected_type_id = asset_type,
                    expected_display_name = expected_display_name,
                }
            end
        end

        if reference == nil and not has_resolved_runtime_value then
            return false, nil,
            {
                code = "resource_unset",
                expected_type_id = asset_type,
                expected_display_name = expected_display_name,
            }
        end

        if runtime_value == nil and not has_resolved_runtime_value then
            return false, nil,
            {
                code = "resource_unavailable",
                expected_type_id = asset_type,
                expected_display_name = expected_display_name,
                issue = describe_issue and describe_issue(pin, reference) or nil,
            }
        end

        return true, runtime_value
    end
end

return module

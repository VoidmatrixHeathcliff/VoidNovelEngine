local Common = require("application.framework.builtin_pin_common")

local util = Common.util
local imgui = Common.imgui
local StyleAdapterFactory = Common.StyleAdapterFactory

local ResourceIndex = require("application.framework.resource_index")
local ResourceReferenceField = require("application.framework.resource_reference_field")

local BlueprintPin = Common.BlueprintPin
local LogManager = Common.LogManager
local UndoManager = Common.UndoManager
local alert_color <const> = imgui.ImVec4(imgui.ImColor(197, 61, 67, 255).value)
local resource_locator_button_width <const> = 84

return Common.make_definition({
    type_id = "string",
    display_name = "字符串",
    icon_type = imgui.NodeEditor.IconType.Circle,
    style_adapter = StyleAdapterFactory.make_string_adapter(),
    runtime =
    {
        validate = function(value, opts)
            if value == nil then
                if opts and opts.allow_nil then
                    return true, nil
                end
                return false, nil, {code = "nil_value"}
            end
            if type(value) ~= "string" then
                return false, nil, {code = "type_mismatch", actual_type = type(value)}
            end
            if opts and opts.allow_empty == false and value == "" then
                return false, nil, {code = "string_empty", actual_type = "string"}
            end
            return true, value
        end,
    }
}, function(pin, ctx)
    local id = ctx.pin_id
    local extra_args = ctx.options
    local _base_load = function(self, data)
        return BlueprintPin.on_load(self, data)
    end
    local _base_save = function(self)
        return BlueprintPin.on_save(self)
    end

    pin._cstring = util.CString()
    pin._prev_text = pin._cstring:get()
    pin._width_input = 50
    if extra_args then
        pin._width_input = extra_args.width_input or pin._width_input
    end
    pin._can_edit = true
    if extra_args and extra_args.can_edit ~= nil then
        pin._can_edit = extra_args.can_edit
    end
    pin._resource_locator_asset_type = extra_args and extra_args.resource_locator_asset_type or nil
    pin._resource_locator_manual = not (extra_args and extra_args.resource_locator_manual == false)

    local function _normalize_string_value(value)
        if value == nil then
            return ""
        end
        if type(value) ~= "string" then
            return tostring(value)
        end
        return value
    end

    local function _resource_value_to_locator(asset_type, value)
        local display_path = ResourceIndex.get_display_path(asset_type, value)
        if display_path and display_path ~= "" then
            return display_path
        end
        if type(value) == "table" then
            return _normalize_string_value(value.path_hint or value.relative_path or value.id or value.path or value.guid)
        end
        return _normalize_string_value(value)
    end

    local function _record_text_change(self, next_text)
        next_text = _normalize_string_value(next_text)
        if next_text == self._prev_text then
            return false
        end

        local old_style_override = self:has_style_local_override()
        UndoManager.record(function(data)
                self._cstring:set(data.old)
                self._prev_text = data.old
                self:set_style_local_override(data.old_style_override)
            end,
            function(data)
                self._cstring:set(data.new)
                self._prev_text = data.new
                self:set_style_local_override(data.new_style_override)
            end,
            {
                old = self._prev_text,
                new = next_text,
                old_style_override = old_style_override,
                new_style_override = true,
            })
        self._cstring:set(next_text)
        self._prev_text = next_text
        self:set_style_local_override(true)
        return true
    end

    local function _draw_text_input(self, width)
        imgui.SetNextItemWidth(width)
        imgui.InputText("##string" .. id, self._cstring)
        if imgui.IsItemDeactivatedAfterEdit() then
            _record_text_change(self, self._cstring:get())
        end
    end

    local function _draw_resource_locator_input(self, asset_type, disabled)
        local total_width = self:get_widget_input_width(self._width_input)
        local style = imgui.GetStyle()
        local spacing_x = style and style.ItemSpacing and style.ItemSpacing.x or 4
        local use_manual_input = self._resource_locator_manual ~= false
        local picker_width = use_manual_input and math.min(resource_locator_button_width, math.max(72, total_width))
            or total_width
        local input_width = math.max(48, total_width - picker_width - spacing_x)
        local current_text = self._cstring:get()
        local issue_text = nil

        if current_text ~= "" and not disabled and ResourceIndex.resolve_guid(asset_type, current_text) == nil then
            issue_text = string.format("无法找到 flow 资源：%s", current_text)
        end
        self._name_tint_color = issue_text and alert_color or nil
        self._name_overlay_tooltip_text = issue_text

        if use_manual_input then
            _draw_text_input(self, input_width)
            imgui.SameLine()
        end

        local selected_value, changed, invalid_payload = ResourceReferenceField.draw(
        {
            popup_id = string.format("string_resource_locator_%s_%s", asset_type, id),
            asset_type = asset_type,
            value = current_text,
            width = picker_width,
            disabled = disabled,
            allow_clear = false,
            use_node_editor_overlay = true,
            alert_text = issue_text,
        })
        if invalid_payload then
            LogManager.log(
                string.format("错误的引脚赋值类型，使用“%s”类型资源为“%s”定位字段赋值", invalid_payload.type, asset_type),
                "warning")
        elseif changed then
            _record_text_change(self, _resource_value_to_locator(asset_type, selected_value))
        end
    end

    if pin._can_edit then
        pin._on_tick_widgets = function(self)
            local disabled = not self._is_output and self._linked_pin_id ~= nil
            imgui.BeginDisabled(disabled)
                if self._resource_locator_asset_type then
                    _draw_resource_locator_input(self, self._resource_locator_asset_type, disabled)
                else
                    self._name_tint_color = nil
                    self._name_overlay_tooltip_text = nil
                    _draw_text_input(self, self:get_widget_input_width(self._width_input))
                end
            imgui.EndDisabled()
        end
    end

    pin.on_load = function(self, data)
        _base_load(self, data)
        local value = _normalize_string_value(data and data.val)
        if self._resource_locator_asset_type and self._resource_locator_manual == false then
            value = _resource_value_to_locator(self._resource_locator_asset_type, value)
        end
        self._cstring:set(value)
        self._prev_text = value
    end

    pin.on_save = function(self)
        local data = _base_save(self)
        -- SAVE TRACE: concrete string pin appends its editable value.
        data.val = self._cstring:get()
        return data
    end

    pin.set_val = function(self, val)
        local value = _normalize_string_value(val)
        self._cstring:set(value)
        self._prev_text = value
    end

    pin.get_val = function(self)
        return self:_resolve_runtime_input_value(self._cstring:get())
    end
end)

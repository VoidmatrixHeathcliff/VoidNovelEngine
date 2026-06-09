local util = Engine.Util
local imgui = Engine.ImGUI

local ResourceIndex = require("application.framework.resource_index")
local ResourceReferenceField = require("application.framework.resource_reference_field")

local module = {}

local function _query_item_active(state, interacted, deactivated)
    return imgui.IsItemActive()
end

local function _clone_table(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_table(item)
    end
    return copy
end

local function _normalize_number(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        return fallback or 0
    end
    return number
end

local function _normalize_color(value)
    if type(value) ~= "table" then
        return {x = 1, y = 1, z = 1, w = 1}
    end

    return
    {
        x = _normalize_number(value.x or value.r, 1),
        y = _normalize_number(value.y or value.g, 1),
        z = _normalize_number(value.z or value.b, 1),
        w = _normalize_number(value.w or value.a, 1),
    }
end

local function _normalize_vector2(value)
    if type(value) ~= "table" then
        return {x = 0, y = 0}
    end

    return
    {
        x = _normalize_number(value.x, 0),
        y = _normalize_number(value.y, 0),
    }
end

local function _copy_color_to_widget(widget, value)
    local normalized = _normalize_color(value)
    widget.value.x = normalized.x
    widget.value.y = normalized.y
    widget.value.z = normalized.z
    widget.value.w = normalized.w
end

local function _copy_vector_to_widget(widget, value)
    local normalized = _normalize_vector2(value)
    widget.x = normalized.x
    widget.y = normalized.y
end

local function _wrap_disabled(disabled, draw_func)
    imgui.BeginDisabled(disabled == true)
        local changed, value = draw_func()
    imgui.EndDisabled()
    return changed, value
end

local function _normalize_reference(asset_type, value)
    return ResourceIndex.make_reference(asset_type, value)
end

local function _clone_reference(value)
    if type(value) ~= "table" then
        return nil
    end

    return
    {
        guid = value.guid,
        path_hint = value.path_hint,
    }
end

local function _equal_reference(left, right)
    local left_ref = _normalize_reference("", left)
    local right_ref = _normalize_reference("", right)
    if left_ref == nil and right_ref == nil then
        return true
    end
    if left_ref == nil or right_ref == nil then
        return false
    end
    return (left_ref.guid or "") == (right_ref.guid or "")
        and (left_ref.path_hint or "") == (right_ref.path_hint or "")
end

module.make_int_adapter = function()
    local adapter = {}

    adapter.normalize_value = function(value)
        local integer = math.tointeger(value)
        if integer ~= nil then
            return integer
        end
        return math.tointeger(_normalize_number(value, 0)) or 0
    end

    adapter.clone_value = function(value)
        return adapter.normalize_value(value)
    end

    adapter.equal_value = function(left, right)
        return adapter.normalize_value(left) == adapter.normalize_value(right)
    end

    adapter.draw_editor = function(ctx)
        local state = ctx.state
        state.widget = state.widget or imgui.Int(adapter.normalize_value(ctx.value))
        local current_value = adapter.normalize_value(ctx.value)
        if state.active ~= true or state.committed_value ~= current_value then
            state.widget.val = current_value
            state.committed_value = current_value
        end

        local changed, value = _wrap_disabled(ctx.disabled, function()
            if ctx.width and ctx.width > 0 then
                imgui.SetNextItemWidth(ctx.width)
            end
            local interacted = imgui.InputInt(ctx.id, state.widget)
            local deactivated = imgui.IsItemDeactivatedAfterEdit()
            state.active = _query_item_active(state, interacted, deactivated)
            if (ctx.live_commit == true and interacted) or deactivated then
                local next_value = adapter.normalize_value(state.widget.val)
                if state.committed_value ~= next_value then
                    state.committed_value = next_value
                    return true, next_value
                end
            end
            return false, nil
        end)
        return changed, value
    end

    return adapter
end

module.make_float_adapter = function()
    local adapter = {}

    adapter.normalize_value = function(value)
        return _normalize_number(value, 0)
    end

    adapter.clone_value = function(value)
        return adapter.normalize_value(value)
    end

    adapter.equal_value = function(left, right)
        return math.abs(adapter.normalize_value(left) - adapter.normalize_value(right)) < 0.00001
    end

    adapter.draw_editor = function(ctx)
        local state = ctx.state
        state.widget = state.widget or imgui.Float(adapter.normalize_value(ctx.value))
        local current_value = adapter.normalize_value(ctx.value)
        if state.active ~= true or not adapter.equal_value(state.committed_value, current_value) then
            state.widget.val = current_value
            state.committed_value = current_value
        end

        local changed, value = _wrap_disabled(ctx.disabled, function()
            if ctx.width and ctx.width > 0 then
                imgui.SetNextItemWidth(ctx.width)
            end
            local interacted = imgui.InputFloat(ctx.id, state.widget)
            local deactivated = imgui.IsItemDeactivatedAfterEdit()
            state.active = _query_item_active(state, interacted, deactivated)
            if (ctx.live_commit == true and interacted) or deactivated then
                local next_value = adapter.normalize_value(state.widget.val)
                if not adapter.equal_value(state.committed_value, next_value) then
                    state.committed_value = next_value
                    return true, next_value
                end
            end
            return false, nil
        end)
        return changed, value
    end

    return adapter
end

module.make_bool_adapter = function()
    local adapter = {}

    adapter.normalize_value = function(value)
        return value == true
    end

    adapter.clone_value = function(value)
        return adapter.normalize_value(value)
    end

    adapter.equal_value = function(left, right)
        return adapter.normalize_value(left) == adapter.normalize_value(right)
    end

    adapter.draw_editor = function(ctx)
        local state = ctx.state
        state.widget = state.widget or imgui.Bool(adapter.normalize_value(ctx.value))
        local current_value = adapter.normalize_value(ctx.value)
        state.widget.val = current_value

        local changed, value = _wrap_disabled(ctx.disabled, function()
            if imgui.Checkbox(ctx.id, state.widget) then
                local next_value = adapter.normalize_value(state.widget.val)
                return true, next_value
            end
            return false, nil
        end)
        return changed, value
    end

    return adapter
end

module.make_string_adapter = function()
    local adapter = {}

    adapter.normalize_value = function(value)
        if type(value) == "string" then
            return value
        end
        return value == nil and "" or tostring(value)
    end

    adapter.clone_value = function(value)
        return adapter.normalize_value(value)
    end

    adapter.equal_value = function(left, right)
        return adapter.normalize_value(left) == adapter.normalize_value(right)
    end

    adapter.draw_editor = function(ctx)
        local state = ctx.state
        state.widget = state.widget or util.CString(adapter.normalize_value(ctx.value))
        local current_value = adapter.normalize_value(ctx.value)
        if state.active ~= true or state.committed_value ~= current_value then
            state.widget:set(current_value)
            state.committed_value = current_value
        end

        local changed, value = _wrap_disabled(ctx.disabled, function()
            if ctx.width and ctx.width > 0 then
                imgui.SetNextItemWidth(ctx.width)
            end
            local interacted = imgui.InputText(ctx.id, state.widget)
            local deactivated = imgui.IsItemDeactivatedAfterEdit()
            state.active = _query_item_active(state, interacted, deactivated)
            if (ctx.live_commit == true and interacted) or deactivated then
                local next_value = adapter.normalize_value(state.widget:get())
                if state.committed_value ~= next_value then
                    state.committed_value = next_value
                    return true, next_value
                end
            end
            return false, nil
        end)
        return changed, value
    end

    return adapter
end

module.make_vector2_adapter = function()
    local adapter = {}

    adapter.normalize_value = function(value)
        return _normalize_vector2(value)
    end

    adapter.clone_value = function(value)
        return _clone_table(adapter.normalize_value(value))
    end

    adapter.equal_value = function(left, right)
        local left_value = adapter.normalize_value(left)
        local right_value = adapter.normalize_value(right)
        return math.abs(left_value.x - right_value.x) < 0.00001
            and math.abs(left_value.y - right_value.y) < 0.00001
    end

    adapter.draw_editor = function(ctx)
        local state = ctx.state
        state.widget = state.widget or imgui.ImVec2(0, 0)
        local current_value = adapter.normalize_value(ctx.value)
        if state.active ~= true or not adapter.equal_value(state.committed_value, current_value) then
            _copy_vector_to_widget(state.widget, current_value)
            state.committed_value = adapter.clone_value(current_value)
        end

        local changed, value = _wrap_disabled(ctx.disabled, function()
            if ctx.width and ctx.width > 0 then
                imgui.SetNextItemWidth(ctx.width)
            end
            local interacted = imgui.InputFloat2(ctx.id, state.widget, nil, nil)
            local deactivated = imgui.IsItemDeactivatedAfterEdit()
            state.active = _query_item_active(state, interacted, deactivated)
            if (ctx.live_commit == true and interacted) or deactivated then
                local next_value =
                {
                    x = _normalize_number(state.widget.x, 0),
                    y = _normalize_number(state.widget.y, 0),
                }
                if not adapter.equal_value(state.committed_value, next_value) then
                    state.committed_value = adapter.clone_value(next_value)
                    return true, next_value
                end
            end
            return false, nil
        end)
        return changed, value
    end

    return adapter
end

module.make_color_adapter = function()
    local adapter = {}

    adapter.normalize_value = function(value)
        return _normalize_color(value)
    end

    adapter.clone_value = function(value)
        return _clone_table(adapter.normalize_value(value))
    end

    adapter.equal_value = function(left, right)
        local left_value = adapter.normalize_value(left)
        local right_value = adapter.normalize_value(right)
        return math.abs(left_value.x - right_value.x) < 0.00001
            and math.abs(left_value.y - right_value.y) < 0.00001
            and math.abs(left_value.z - right_value.z) < 0.00001
            and math.abs(left_value.w - right_value.w) < 0.00001
    end

    adapter.draw_editor = function(ctx)
        local state = ctx.state
        state.widget = state.widget or imgui.ImColor(255, 255, 255, 255)
        local current_value = adapter.normalize_value(ctx.value)
        if state.active ~= true or not adapter.equal_value(state.committed_value, current_value) then
            _copy_color_to_widget(state.widget, current_value)
            state.committed_value = adapter.clone_value(current_value)
        end

        local changed, value = _wrap_disabled(ctx.disabled, function()
            if ctx.width and ctx.width > 0 then
                imgui.SetNextItemWidth(ctx.width)
            end
            local flag = imgui.ColorEditFlags.NoTooltip
                | imgui.ColorEditFlags.NoOptions
                | imgui.ColorEditFlags.NoPicker
                | imgui.ColorEditFlags.AlphaBar
            local interacted = imgui.ColorEdit4(ctx.id, state.widget, flag)
            local deactivated = imgui.IsItemDeactivatedAfterEdit()
            state.active = _query_item_active(state, interacted, deactivated)
            if (ctx.live_commit == true and interacted) or deactivated then
                local next_value =
                {
                    x = state.widget.value.x,
                    y = state.widget.value.y,
                    z = state.widget.value.z,
                    w = state.widget.value.w,
                }
                if not adapter.equal_value(state.committed_value, next_value) then
                    state.committed_value = adapter.clone_value(next_value)
                    return true, next_value
                end
            end
            return false, nil
        end)
        return changed, value
    end

    return adapter
end

module.make_resource_adapter = function(asset_type)
    local adapter = {}

    adapter.normalize_value = function(value)
        return _normalize_reference(asset_type, value)
    end

    adapter.clone_value = function(value)
        return _clone_reference(adapter.normalize_value(value))
    end

    adapter.equal_value = function(left, right)
        local left_ref = adapter.normalize_value(left)
        local right_ref = adapter.normalize_value(right)
        if left_ref == nil and right_ref == nil then
            return true
        end
        if left_ref == nil or right_ref == nil then
            return false
        end
        return (left_ref.guid or "") == (right_ref.guid or "")
            and (left_ref.path_hint or "") == (right_ref.path_hint or "")
    end

    adapter.draw_editor = function(ctx)
        local popup_key = tostring(ctx.id or ""):match("##(.+)$") or tostring(ctx.id or "")
        local selected_value, changed = ResourceReferenceField.draw(
        {
            popup_id = string.format("style_field_%s_%s", asset_type, popup_key),
            asset_type = asset_type,
            value = ctx.value,
            width = ctx.width,
            suffix_label = ctx.label_text,
            disabled = ctx.disabled == true,
            allow_clear = ctx.allow_clear == true,
            alert_text = ctx.alert_text,
        })
        if changed then
            return true, adapter.normalize_value(selected_value)
        end
        return false, nil
    end

    return adapter
end

module.clone_value = _clone_table
module.equal_reference = _equal_reference

return module

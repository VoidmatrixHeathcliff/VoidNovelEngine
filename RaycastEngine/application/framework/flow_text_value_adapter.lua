local imgui = Engine.ImGUI

local Diagnostics = require("application.framework.flow_text_diagnostics")
local ResourceIndex = require("application.framework.resource_index")

local module = {}

local asset_type_pool =
{
    texture = true,
    audio = true,
    video = true,
    font = true,
    shader = true,
    style = true,
    flow = true,
    ui = true,
}

local function _apply_adapter(value, adapter)
    if adapter == "bool_to_loop_count" and type(value) == "boolean" then
        return value and -1 or 0
    end
    return value
end

local function _to_color_channel(hex)
    return tonumber(hex, 16) / 255
end

local function _parse_color(hex)
    if #hex == 6 then
        return imgui.ImVec4(
            _to_color_channel(hex:sub(1, 2)),
            _to_color_channel(hex:sub(3, 4)),
            _to_color_channel(hex:sub(5, 6)),
            1.0)
    end

    if #hex == 8 then
        return imgui.ImVec4(
            _to_color_channel(hex:sub(1, 2)),
            _to_color_channel(hex:sub(3, 4)),
            _to_color_channel(hex:sub(5, 6)),
            _to_color_channel(hex:sub(7, 8)))
    end

    return nil
end

local function _read_scoped_value(runtime, scope, name)
    if not runtime or type(name) ~= "string" then
        return nil
    end

    local has_resolver = type(runtime.resolve_runtime_local_value) == "function"
    if scope == "global" then
        local target = runtime._global_vars or {}
        for part in name:gmatch("[^%.]+") do
            if type(target) ~= "table" then
                return nil
            end
            target = target[part]
            if has_resolver then
                target = runtime:resolve_runtime_local_value(target)
            end
        end
        return target
    end

    local pool = runtime._locals or {}
    local value = pool[name]
    if has_resolver then
        value = runtime:resolve_runtime_local_value(value)
        if pool[name] ~= value and value ~= nil then
            pool[name] = value
        end
    end
    return value
end

local function _coerce_literal(value_spec, expected_type_id, runtime, adapter)
    if not value_spec then
        return nil
    end

    local kind = value_spec.kind
    if kind == "variable" then
        return _apply_adapter(_read_scoped_value(runtime, value_spec.scope, value_spec.name), adapter)
    end

    if kind == "null" then
        return nil
    end

    if kind == "string" then
        return _apply_adapter(value_spec.value, adapter)
    end

    if kind == "bool" then
        return _apply_adapter(value_spec.value, adapter)
    end

    if kind == "number" then
        if expected_type_id == "int" then
            return _apply_adapter(math.floor(tonumber(value_spec.value) or 0), adapter)
        end
        return _apply_adapter(tonumber(value_spec.value), adapter)
    end

    if kind == "vector2" then
        local x = _coerce_literal(value_spec.x, "float", runtime)
        local y = _coerce_literal(value_spec.y, "float", runtime)
        return _apply_adapter(imgui.ImVec2(tonumber(x) or 0, tonumber(y) or 0), adapter)
    end

    if kind == "color" then
        return _apply_adapter(_parse_color(value_spec.value), adapter)
    end

    if kind == "asset" then
        if adapter == "flow_locator" then
            if value_spec.asset_type ~= "flow" then
                return nil
            end
            return value_spec.locator
        end
        if asset_type_pool[expected_type_id] and value_spec.asset_type ~= expected_type_id then
            return nil
        end
        if asset_type_pool[expected_type_id] then
            return _apply_adapter(ResourceIndex.make_reference(expected_type_id, value_spec.locator), adapter)
        end
        if expected_type_id == "string" then
            return _apply_adapter(value_spec.locator, adapter)
        end
        return _apply_adapter(ResourceIndex.make_reference(value_spec.asset_type, value_spec.locator), adapter)
    end

    if kind == "label_ref" then
        return _apply_adapter(value_spec.name, adapter)
    end

    return _apply_adapter(value_spec.value, adapter)
end

module.resolve_runtime_value = function(value_spec, expected_type_id, runtime, adapter)
    return _coerce_literal(value_spec, expected_type_id, runtime, adapter)
end

module.validate_literal = function(value_spec, expected_type_id, adapter)
    if not value_spec or value_spec.kind == "variable" then
        return true, nil
    end

    local value = _coerce_literal(value_spec, expected_type_id, nil, adapter)
    if expected_type_id == "int" or expected_type_id == "float" then
        if type(value) ~= "number" then
            return false, Diagnostics.error("type_mismatch", "数值参数类型不匹配", value_spec.line, value_spec.column)
        end
        return true, nil
    end
    if expected_type_id == "bool" then
        if type(value) ~= "boolean" then
            return false, Diagnostics.error("type_mismatch", "布尔参数类型不匹配", value_spec.line, value_spec.column)
        end
        return true, nil
    end
    if expected_type_id == "string" then
        if type(value) ~= "string" then
            return false, Diagnostics.error("type_mismatch", "字符串参数类型不匹配", value_spec.line, value_spec.column)
        end
        return true, nil
    end
    if expected_type_id == "vector2" then
        if type(value) ~= "userdata" and type(value) ~= "table" then
            return false, Diagnostics.error("type_mismatch", "Vector2 参数类型不匹配", value_spec.line, value_spec.column)
        end
        return true, nil
    end
    if expected_type_id == "color" then
        if value == nil then
            return false, Diagnostics.error("type_mismatch", "颜色参数类型不匹配", value_spec.line, value_spec.column)
        end
        return true, nil
    end
    if asset_type_pool[expected_type_id] or expected_type_id == "style" then
        if value == nil then
            return false, Diagnostics.error("type_mismatch", "资源参数类型不匹配", value_spec.line, value_spec.column)
        end
        return true, nil
    end

    return true, nil
end

return module

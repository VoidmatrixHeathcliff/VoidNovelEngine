local rl = Engine.Raylib

local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local StyleManager = require("application.framework.style_manager")

local module = {}

local warning_pool = {}

local function _warn_once(key, message)
    if warning_pool[key] then
        return
    end
    warning_pool[key] = true
    if LogManager and LogManager.log then
        LogManager.log(message, "warning")
    end
end

local function _normalize_reference(value)
    return ResourceIndex.make_reference("shader", value)
end

local function _resolve_shader_reference(reference)
    local normalized = _normalize_reference(reference)
    if not normalized then
        return nil
    end

    local ok, shader_or_err = pcall(ResourcesManager.find_shader, normalized)
    if ok then
        return shader_or_err
    end

    local key = normalized.guid or normalized.path_hint or tostring(reference)
    _warn_once(
        string.format("shader:%s", tostring(key)),
        string.format("Unable to resolve shader resource: %s\n%s", tostring(key), tostring(shader_or_err)))
    return nil
end

local function _try_style_shader(field_key)
    local ok, value, found, err = pcall(StyleManager.try_get_raw_value, "shader", field_key, "shader")
    if not ok then
        _warn_once(
            string.format("style_shader:%s", tostring(field_key)),
            string.format("Unable to read style shader field shader.%s\n%s", tostring(field_key), tostring(value)))
        return nil, false, "style_error"
    end
    if found then
        return _normalize_reference(value), true, nil
    end
    return nil, false, err
end

local function _is_active_shader(shader)
    if not shader then
        return false
    end
    if shader.is_empty and shader:is_empty() then
        return false
    end
    if shader.is_valid and not shader:is_valid() then
        return false
    end
    return type(shader.use) == "function" and type(shader.unuse) == "function"
end

local function _set_uniform(shader, name, value, opt)
    if not shader or type(shader.set) ~= "function" then
        return
    end
    pcall(shader.set, shader, name, value, opt)
end

function module.resolve_layer_shader(layer, explicit_shader_reference)
    local explicit_reference = _normalize_reference(explicit_shader_reference)
    if explicit_reference then
        return _resolve_shader_reference(explicit_reference)
    end

    local layer_key = tostring(layer or "")
    if layer_key ~= "" then
        local style_reference, found, err = _try_style_shader(layer_key)
        if found then
            return _resolve_shader_reference(style_reference)
        end
        if err then
            return nil
        end
    end

    return nil
end

function module.resolve_global_shader()
    local style_reference, found, err = _try_style_shader("global")
    if found then
        return _resolve_shader_reference(style_reference)
    end
    if err == "resource_unavailable" or err == "type_mismatch" or err == "style_error" then
        return nil
    end
    return GlobalContext.shader_postprocess
end

function module.is_active(shader)
    return _is_active_shader(shader)
end

function module.apply_common_uniforms(shader, context)
    if not _is_active_shader(shader) then
        return
    end

    context = type(context) == "table" and context or {}
    local texture = context.texture
    local texture_width = tonumber(context.texture_width) or (texture and tonumber(texture.width)) or 0
    local texture_height = tonumber(context.texture_height) or (texture and tonumber(texture.height)) or 0
    local resolution_width = tonumber(context.resolution_width or context.width) or tonumber(GlobalContext.width_game_window) or texture_width
    local resolution_height = tonumber(context.resolution_height or context.height) or tonumber(GlobalContext.height_game_window) or texture_height
    local mouse_x = tonumber(context.mouse_x) or 0
    local mouse_y = tonumber(context.mouse_y) or 0
    local alpha = tonumber(context.alpha)
    if alpha == nil then
        alpha = 1
    end

    local time_value = rl.GetTime and rl.GetTime() or 0
    local resolution_value = rl.Vector2(resolution_width, resolution_height)
    local texture_size_value = rl.Vector2(texture_width, texture_height)
    local mouse_value = rl.Vector2(mouse_x, mouse_y)

    _set_uniform(shader, "time", time_value)
    _set_uniform(shader, "u_time", time_value)
    _set_uniform(shader, "resolution", resolution_value)
    _set_uniform(shader, "u_resolution", resolution_value)
    _set_uniform(shader, "texture_size", texture_size_value)
    _set_uniform(shader, "u_texture_size", texture_size_value)
    _set_uniform(shader, "mouse", mouse_value)
    _set_uniform(shader, "u_mouse", mouse_value)
    _set_uniform(shader, "alpha", alpha)
    _set_uniform(shader, "u_alpha", alpha)
end

function module.draw_with_shader(shader, draw_func, context)
    if type(draw_func) ~= "function" then
        return
    end
    if not _is_active_shader(shader) then
        return draw_func()
    end

    local did_begin = false
    local ok, result = xpcall(function()
        shader:use()
        did_begin = true
        module.apply_common_uniforms(shader, context)
        return draw_func()
    end, debug.traceback)

    if did_begin or (type(shader) == "table" and rawget(shader, "_is_in_use") == true) then
        pcall(shader.unuse, shader)
    end

    if not ok then
        error(result, 0)
    end
    return result
end

function module.clear_warning_cache()
    warning_pool = {}
end

return module

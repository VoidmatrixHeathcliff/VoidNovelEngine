local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local NativeIO = require("application.framework.native_io")
local NodeRuntimeHelper = require("application.framework.node_runtime_helper")
local PlugResourceContext = require("application.framework.plug_resource_context")
local ResourcesManager = require("application.framework.resources_manager")

local module = {}
local unpack_args = table.unpack or unpack

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

local function _normalize_path(path)
    return (tostring(path or ""):gsub("\\", "/"))
end

local function _is_flow_pin(pin_spec)
    return type(pin_spec) == "table" and pin_spec.type_id == "flow"
end

local keepalive_resource_pin_type_pool =
{
    texture = true,
    audio = true,
    video = true,
    font = true,
    shader = true,
}

local function _read_pin_value(node, pin_spec)
    local key = _trim(pin_spec and pin_spec.key)
    if not key then
        return nil
    end

    local pin = node and node.resolve_input_pin and node:resolve_input_pin(key) or nil
    if not pin then
        return nil
    end

    local ok, value = pcall(function()
        return NodeRuntimeHelper.check_input(node, key, {type_id = pin_spec.type_id or "object"})
    end)
    if ok then
        return value
    end

    return pin_spec.default
end

local function _collect_plugin_args(node, manifest)
    local args = {}
    for _, pin_spec in ipairs(type(manifest.input_pins) == "table" and manifest.input_pins or {}) do
        if not _is_flow_pin(pin_spec) then
            local key = _trim(pin_spec.key)
            if key then
                args[key] = _read_pin_value(node, pin_spec)
            end
        end
    end
    return args
end

local function _collect_plugin_resource_inputs(node, manifest)
    local result = {}
    for _, pin_spec in ipairs(type(manifest.input_pins) == "table" and manifest.input_pins or {}) do
        if not _is_flow_pin(pin_spec) then
            local type_id = _trim(pin_spec.type_id)
            if keepalive_resource_pin_type_pool[type_id] == true then
                local key = _trim(pin_spec.key)
                local pin = key and node and node.resolve_input_pin and node:resolve_input_pin(key) or nil
                if pin and pin.get_reference then
                    result[key] =
                    {
                        type = type_id,
                        reference = pin:get_reference(),
                    }
                end
            end
        end
    end
    return result
end

local function _acquire_resource_input_keepalives(resource_inputs, manifest)
    local tickets = {}
    for key, input in pairs(type(resource_inputs) == "table" and resource_inputs or {}) do
        local asset_type = input and input.type or nil
        local reference = input and input.reference or nil
        if asset_type and reference then
            local ticket = ResourcesManager.acquire_keepalive(reference,
                string.format("plugin_%s_input_%s", tostring(manifest and manifest.id or "unknown"), tostring(key)),
                "runtime",
                asset_type)
            if ticket then
                tickets[#tickets + 1] = ticket
            end
        end
    end
    return tickets
end

local function _release_keepalive_list(ticket_list)
    for index = #ticket_list, 1, -1 do
        ResourcesManager.release_keepalive(ticket_list[index])
        ticket_list[index] = nil
    end
end

local function _release_scene_runtime_resources(scene)
    if type(scene) ~= "table" then
        return
    end

    local keepalive_list = rawget(scene, "_vne_plugin_resource_keepalives")
    if type(keepalive_list) == "table" then
        _release_keepalive_list(keepalive_list)
        scene._vne_plugin_resource_keepalives = nil
    end

    local resource_context = rawget(scene, "_vne_plugin_resources")
    if resource_context and resource_context.dispose then
        pcall(resource_context.dispose, resource_context)
        scene._vne_plugin_resources = nil
    end
end

local function _set_plugin_outputs(node, manifest, plugin_scene)
    local output_values = type(plugin_scene) == "table" and type(plugin_scene._output_values) == "table"
        and plugin_scene._output_values
        or {}

    for _, pin_spec in ipairs(type(manifest.output_pins) == "table" and manifest.output_pins or {}) do
        if not _is_flow_pin(pin_spec) then
            local key = _trim(pin_spec.key)
            if key and output_values[key] ~= nil then
                NodeRuntimeHelper.set_output(node, key, output_values[key])
            end
        end
    end
end

local function _reset_package_modules(package_path)
    local normalized_root = _normalize_path(package_path)
    if normalized_root == "" then
        return
    end
    if normalized_root:sub(-1) ~= "/" then
        normalized_root = normalized_root .. "/"
    end

    for key, _ in pairs(package.loaded) do
        local normalized_key = type(key) == "string" and _normalize_path(key:gsub("%.", "/")) or ""
        if normalized_key:sub(1, #normalized_root) == normalized_root then
            package.loaded[key] = nil
        end
    end
end

local function _load_scene_module(manifest)
    local entry_path = _trim(manifest.entry_path)
    if not entry_path then
        return nil, "插件缺少入口场景文件"
    end
    if not NativeIO.file_exists(entry_path) then
        return nil, string.format("插件入口场景不存在：%s", entry_path)
    end

    if manifest.reload_modules ~= false then
        _reset_package_modules(manifest.package_path)
    end

    local chunk, load_err = NativeIO.load_lua_chunk(entry_path)
    if not chunk then
        return nil, load_err
    end

    local ok, scene_module = pcall(chunk)
    if not ok then
        return nil, scene_module
    end
    if type(scene_module) ~= "table" or type(scene_module.new) ~= "function" then
        return nil, "插件入口必须返回带 new() 的 Scene 类"
    end
    return scene_module
end

local function _set_active_plugin(manifest)
    GlobalContext.active_plugin_id = manifest and manifest.id or nil
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

local function _capture_scene_owner(node)
    local blueprint = node and node._blueprint or nil
    local runtime = blueprint and blueprint._flow_text_runtime or nil
    local document = runtime and runtime._document or nil
    return
    {
        blueprint = blueprint,
        runtime = runtime,
        document = document,
        previous_blueprint_scene = blueprint and blueprint._scene_context or nil,
        previous_runtime_scene = runtime and runtime._scene_context or nil,
        previous_document_scene = document and document._scene_context or nil,
        previous_active_plugin_id = GlobalContext.active_plugin_id,
    }
end

local function _set_scene_context(owner, scene_context)
    if owner.blueprint then
        owner.blueprint._scene_context = scene_context
    end
    if owner.runtime then
        owner.runtime._scene_context = scene_context
    end
    if owner.document then
        owner.document._scene_context = scene_context
    end
end

local function _restore_scene_context(owner)
    if owner.blueprint then
        owner.blueprint._scene_context = owner.previous_blueprint_scene
    end
    if owner.runtime then
        owner.runtime._scene_context = owner.previous_runtime_scene
    end
    if owner.document then
        owner.document._scene_context = owner.previous_document_scene
    end
    GlobalContext.active_plugin_id = owner.previous_active_plugin_id
end

local function _safe_scene_call(scene, method_name, ...)
    local method = scene and scene[method_name] or nil
    if type(method) ~= "function" then
        return true
    end
    return pcall(method, scene, ...)
end

local function _destroy_scene_quietly(scene)
    if type(scene) ~= "table" or rawget(scene, "_vne_plugin_runtime_destroyed") then
        return
    end
    scene._vne_plugin_runtime_destroyed = true
    _safe_scene_call(scene, "on_exit")
    _safe_scene_call(scene, "destroy")
    _release_scene_runtime_resources(scene)
end

local function _wrap_plugin_scene_destroy(plugin_scene)
    if type(plugin_scene) ~= "table" or rawget(plugin_scene, "_vne_plugin_destroy_wrapped") == true then
        return
    end

    plugin_scene._vne_plugin_destroy_wrapped = true
    local original_on_destroy = plugin_scene.on_destroy
    plugin_scene.on_destroy = function(self, ...)
        local ok, result_or_err = true, nil
        if type(original_on_destroy) == "function" then
            ok, result_or_err = pcall(original_on_destroy, self, ...)
        end
        _release_scene_runtime_resources(self)
        if not ok then
            error(result_or_err)
        end
        return result_or_err
    end
end

local function _active_plugin_scene(node, scene)
    local active_scene = node and rawget(node, "_active_plugin_scene") or nil
    if type(active_scene) == "table" then
        return active_scene
    end
    if type(scene) == "table" and rawget(scene, "_vne_plugin_runtime_node") == node then
        return scene
    end
    return nil
end

local function _wrap_plugin_scene_method(node, owner, plugin_scene, method_name)
    local method = plugin_scene and plugin_scene[method_name] or nil
    if type(method) ~= "function" then
        return
    end

    plugin_scene[method_name] = function(self, ...)
        if rawget(self, "_vne_plugin_runtime_aborted") then
            return
        end

        local args = {...}
        local ok, result = xpcall(function()
            return method(self, unpack_args(args))
        end, debug.traceback)
        if ok then
            return result
        end

        self._vne_plugin_runtime_aborted = true
        node._active_plugin_scene = nil
        node._active_plugin_manifest = nil
        _restore_scene_context(owner)
        _destroy_scene_quietly(self)
        NodeRuntimeHelper.fail(
            node,
            string.format("插件场景 %s 执行失败：%s", tostring(method_name), tostring(result)),
            "plugin_runtime_error")
    end
end

function module.make_plugin_executor(manifest)
    local runtime_manifest = manifest
    return function(node, scene)
        local owner = _capture_scene_owner(node)
        if not owner.blueprint then
            NodeRuntimeHelper.abort(node, "插件节点缺少蓝图运行时上下文")
        end

        local plugin_args = _collect_plugin_args(node, runtime_manifest)
        local resource_context = PlugResourceContext.new(runtime_manifest)
        local resource_inputs = _collect_plugin_resource_inputs(node, runtime_manifest)
        local resource_keepalives = _acquire_resource_input_keepalives(resource_inputs, runtime_manifest)
        plugin_args.manifest = runtime_manifest
        plugin_args.host_scene = scene
        plugin_args.node = node
        plugin_args.resources = resource_context
        plugin_args.resource_inputs = resource_inputs

        local scene_module, scene_err = _load_scene_module(runtime_manifest)
        if not scene_module then
            _release_keepalive_list(resource_keepalives)
            resource_context:dispose()
            NodeRuntimeHelper.abort(node, string.format("无法加载插件场景：%s", tostring(scene_err)))
        end

        local ok, plugin_scene = pcall(scene_module.new, plugin_args)
        if not ok or type(plugin_scene) ~= "table" then
            _release_keepalive_list(resource_keepalives)
            resource_context:dispose()
            NodeRuntimeHelper.abort(node, string.format("无法创建插件场景：%s", tostring(plugin_scene)))
        end

        local completed = false
        local function complete(output_ref)
            if completed then
                return
            end
            completed = true

            node._active_plugin_scene = nil
            node._active_plugin_manifest = nil
            _destroy_scene_quietly(plugin_scene)
            _restore_scene_context(owner)
            _set_plugin_outputs(node, runtime_manifest, plugin_scene)
            NodeRuntimeHelper.execute_next_node(node, output_ref)
        end

        local function complete_from_scene(first_arg, second_arg)
            local output_ref = first_arg
            if first_arg == plugin_scene then
                output_ref = second_arg
            end
            complete(output_ref)
        end

        plugin_scene._execute_next_node = complete_from_scene
        plugin_scene.complete = complete_from_scene
        plugin_scene._vne_plugin_resources = resource_context
        plugin_scene._vne_plugin_resource_keepalives = resource_keepalives
        plugin_scene._vne_plugin_runtime_node = node
        plugin_scene._vne_plugin_manifest_id = runtime_manifest.id
        _wrap_plugin_scene_destroy(plugin_scene)
        _wrap_plugin_scene_method(node, owner, plugin_scene, "on_update")
        _wrap_plugin_scene_method(node, owner, plugin_scene, "on_render")

        node._active_plugin_scene = plugin_scene
        node._active_plugin_manifest = runtime_manifest
        _set_scene_context(owner, plugin_scene)
        _set_active_plugin(runtime_manifest)

        local enter_ok, enter_err = _safe_scene_call(plugin_scene, "on_enter")
        if not enter_ok then
            node._active_plugin_scene = nil
            node._active_plugin_manifest = nil
            _restore_scene_context(owner)
            _destroy_scene_quietly(plugin_scene)
            NodeRuntimeHelper.abort(node, string.format("插件场景启动失败：%s", tostring(enter_err)))
        end
    end
end

function module.make_plugin_node_builder(manifest)
    return function(ctx)
        local node = ctx:create_base_node()
        local builder = ctx.builder

        for _, pin_spec in ipairs(type(manifest.input_pins) == "table" and manifest.input_pins or {}) do
            builder:add_input(pin_spec)
        end
        for _, pin_spec in ipairs(type(manifest.output_pins) == "table" and manifest.output_pins or {}) do
            builder:add_output(pin_spec)
        end

        node.on_execute = module.make_plugin_executor(manifest)
        node.can_save_now = function(self, scene)
            if manifest.supports_save ~= true then
                return false, string.format("插件未声明支持存档：%s", tostring(manifest.id))
            end

            local plugin_scene = _active_plugin_scene(self, scene)
            if type(plugin_scene) ~= "table" then
                return false, "插件场景尚未进入可保存状态"
            end
            if type(plugin_scene.can_save_now) == "function" then
                local ok, saveable, reason = pcall(plugin_scene.can_save_now, plugin_scene,
                {
                    plugin_manifest = manifest,
                    source = "plugin_runtime",
                })
                if not ok then
                    return false, string.format("插件存档状态检查失败：%s", tostring(saveable))
                end
                if saveable ~= true then
                    return false, reason or "插件场景尚未进入可保存状态"
                end
            end
            return true
        end

        node.collect_runtime_save_state = function(self, scene)
            if manifest.supports_save ~= true then
                return nil
            end

            local plugin_scene = _active_plugin_scene(self, scene)
            if type(plugin_scene) ~= "table" then
                return nil
            end

            local plugin_state = nil
            if type(plugin_scene.collect_plugin_state) == "function" then
                local ok, state_or_err = pcall(plugin_scene.collect_plugin_state, plugin_scene)
                if not ok then
                    LogManager.log(string.format(
                        "插件存档状态收集失败：%s\n%s",
                        tostring(manifest.id),
                        tostring(state_or_err)), "warning")
                    return nil
                end
                plugin_state = state_or_err
            end

            return
            {
                resume_mode = "reexecute",
                state =
                {
                    plugin_id = manifest.id,
                    plugin_version = manifest.version,
                    plugin_state = _clone_value(plugin_state),
                },
            }
        end

        node.on_runtime_apply_state = function(self, scene, runtime, state)
            local saved_state = type(state) == "table" and state or {}
            if saved_state.plugin_id ~= nil and saved_state.plugin_id ~= manifest.id then
                NodeRuntimeHelper.abort(self, string.format(
                    "插件存档与当前插件不匹配：%s -> %s",
                    tostring(saved_state.plugin_id),
                    tostring(manifest.id)))
            end

            local plugin_scene = _active_plugin_scene(self, scene)
            if type(plugin_scene) ~= "table" then
                return false, "插件场景尚未恢复"
            end
            if type(plugin_scene.apply_plugin_state) == "function" then
                local ok, result, err = pcall(plugin_scene.apply_plugin_state, plugin_scene, saved_state.plugin_state)
                if not ok then
                    NodeRuntimeHelper.abort(self, string.format("插件存档状态恢复失败：%s", tostring(result)))
                end
                if result == false then
                    NodeRuntimeHelper.abort(self, err or "插件拒绝恢复存档状态")
                end
            end
            return true
        end

        return node
    end
end

return module

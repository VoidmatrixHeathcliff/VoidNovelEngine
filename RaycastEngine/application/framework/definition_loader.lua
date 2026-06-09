local rl = Engine.Raylib
local json = Engine.JSON

local LogManager = require("application.framework.log_manager")
local NodeRegistry = require("application.framework.node_registry")
local PinRegistry = require("application.framework.pin_registry")
local FlowTextCommandRegistry = require("application.framework.flow_text_command_registry")
local FlowTextExecutionBridge = require("application.framework.flow_text_execution_bridge")
local NativeIO = require("application.framework.native_io")
local PlugLoader = require("application.framework.plug_loader")

local module = {}
local definition_manifest_path <const> = "application/definition_manifest.json"

local function _read_definition_manifest()
    if not NativeIO.file_exists(definition_manifest_path) then
        return nil
    end

    local content, err = NativeIO.read_text(definition_manifest_path)
    if not content then
        return nil, err or "无法读取定义清单"
    end

    local ok, data = json.ParseToLua(content)
    if not ok or type(data) ~= "table" then
        return nil, "无法解析定义清单"
    end

    local function normalize_path_list(list)
        local result = {}
        local path_pool = {}
        for _, path in ipairs(type(list) == "table" and list or {}) do
            if type(path) == "string" and path ~= "" and not path_pool[path] then
                path_pool[path] = true
                table.insert(result, path)
            end
        end
        table.sort(result)
        return result
    end

    return
    {
        pin_paths = normalize_path_list(data.pin_paths),
        node_paths = normalize_path_list(data.node_paths),
    }
end

local function _collect_lua_file_list(path_folder)
    local result = {}
    if not NativeIO.directory_exists(path_folder) then
        return result
    end

    local path_list, err = NativeIO.list_directory_array(path_folder, true, true)
    if not path_list then
        return result
    end
    for _, path in ipairs(path_list) do
        local ext = string.lower(rl.GetFileExtension(path))
        if ext ~= ".lua" then
            goto continue
        end
        local name = rl.GetFileName(path)
        if #name > 0 and string.sub(name, 1, 1) ~= "_" then
            table.insert(result, path)
        end
        ::continue::
    end
    table.sort(result)
    return result
end

local function _validate_node_definition(definition)
    if type(definition) ~= "table" then
        return false, "定义返回值必须是 table"
    end
    if definition.kind ~= "node" then
        return false, "节点定义 kind 必须为 node"
    end
    if type(definition.type_id) ~= "string" or #definition.type_id == 0 then
        return false, "节点定义缺少有效的 type_id"
    end
    if type(definition.title or definition.name) ~= "string" then
        return false, "节点定义缺少标题"
    end
    if definition.icon_id == nil then
        return false, "节点定义缺少 icon_id"
    end
    if definition.color == nil then
        return false, "节点定义缺少 color"
    end
    if type(definition.build) ~= "function" then
        return false, "节点定义缺少 build 函数"
    end
    return true
end

local function _validate_pin_definition(definition)
    if type(definition) ~= "table" then
        return false, "定义返回值必须是 table"
    end
    if definition.kind ~= "pin" then
        return false, "引脚定义 kind 必须为 pin"
    end
    if type(definition.type_id) ~= "string" or #definition.type_id == 0 then
        return false, "引脚定义缺少有效的 type_id"
    end
    if type(definition.display_name or definition.name) ~= "string" then
        return false, "引脚定义缺少 display_name"
    end
    if definition.icon_type == nil then
        return false, "引脚定义缺少 icon_type"
    end
    if definition.color == nil then
        return false, "引脚定义缺少 color"
    end
    if type(definition.setup) ~= "function" then
        return false, "引脚定义缺少 setup 函数"
    end
    return true
end

local function _load_definition_file(path, validate_func, register_func, counter)
    local chunk, err = NativeIO.load_lua_chunk(path)
    if not chunk then
        counter.failure = counter.failure + 1
        LogManager.log(string.format("加载定义脚本失败：%s\n%s", path, err), "error")
        return
    end

    local ok, definition = pcall(chunk)
    if not ok then
        counter.failure = counter.failure + 1
        LogManager.log(string.format("执行定义脚本失败：%s\n%s", path, definition), "error")
        return
    end

    local valid, message = validate_func(definition)
    if not valid then
        counter.failure = counter.failure + 1
        LogManager.log(string.format("定义脚本校验失败：%s\n%s", path, message), "error")
        return
    end

    local success, normalized = pcall(register_func, definition, path)
    if not success then
        counter.failure = counter.failure + 1
        LogManager.log(string.format("注册定义失败：%s\n%s", path, normalized), "error")
        return
    end

    counter.success = counter.success + 1
    return normalized
end

local function _load_dir(path_folder, validate_func, register_func, counter)
    local file_list = _collect_lua_file_list(path_folder)
    for _, path in ipairs(file_list) do
        _load_definition_file(path, validate_func, register_func, counter)
    end
end

module.load = function()
    NodeRegistry.clear()
    PinRegistry.clear()
    FlowTextCommandRegistry.invalidate()
    FlowTextExecutionBridge.invalidate_schema_cache()

    local counter_pin = {success = 0, failure = 0}
    local counter_node = {success = 0, failure = 0}

    local manifest, manifest_err = _read_definition_manifest()
    if manifest then
        for _, path in ipairs(manifest.pin_paths or {}) do
            _load_definition_file(path, _validate_pin_definition, PinRegistry.register, counter_pin)
        end
        for _, path in ipairs(manifest.node_paths or {}) do
            _load_definition_file(path, _validate_node_definition, NodeRegistry.register, counter_node)
        end
    else
        if manifest_err then
            LogManager.log(string.format("读取定义清单失败，已回退到目录扫描：%s", manifest_err), "warning")
        end
        _load_dir("application\\pin\\builtin", _validate_pin_definition, PinRegistry.register, counter_pin)
        _load_dir("application\\pin\\custom", _validate_pin_definition, PinRegistry.register, counter_pin)
        _load_dir("application\\node\\builtin", _validate_node_definition, NodeRegistry.register, counter_node)
        _load_dir("application\\node\\custom", _validate_node_definition, NodeRegistry.register, counter_node)
    end

    local plug_report = PlugLoader.scan_and_load("plugins")
    counter_node.success = counter_node.success + (plug_report.success_count or 0)
    counter_node.failure = counter_node.failure + (plug_report.failure_count or 0)

    if not PinRegistry.has("flow") then
        error("缺少内置 flow 引脚定义")
    end
    if not NodeRegistry.has("entry") then
        error("缺少内置 entry 节点定义")
    end

    LogManager.log(string.format("已加载 Pin 定义：成功 %d，失败 %d", counter_pin.success, counter_pin.failure), "info")
    LogManager.log(string.format("已加载 Node 定义：成功 %d，失败 %d", counter_node.success, counter_node.failure), "info")
end

module.unload = function()
    NodeRegistry.clear()
    PinRegistry.clear()
    FlowTextCommandRegistry.invalidate()
    FlowTextExecutionBridge.invalidate_schema_cache()
end

return module

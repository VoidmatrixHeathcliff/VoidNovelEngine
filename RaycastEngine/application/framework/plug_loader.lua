local imgui = Engine.ImGUI
local json = Engine.JSON

local FlowTextCommandRegistry = require("application.framework.flow_text_command_registry")
local FlowTextExecutionBridge = require("application.framework.flow_text_execution_bridge")
local GlobalContext = require("application.framework.global_context")
local LogManager = require("application.framework.log_manager")
local NativeIO = require("application.framework.native_io")
local NodeRegistry = require("application.framework.node_registry")
local PinRegistry = require("application.framework.pin_registry")
local PlugRuntime = require("application.framework.plug_runtime")

local module = {}

local default_root_path <const> = "plugins"
local supported_api_version <const> = 1
local loaded_plugin_pool = {}
local last_report = nil

local reserved_windows_name_pool =
{
    con = true,
    prn = true,
    aux = true,
    nul = true,
    com1 = true,
    com2 = true,
    com3 = true,
    com4 = true,
    com5 = true,
    com6 = true,
    com7 = true,
    com8 = true,
    com9 = true,
    lpt1 = true,
    lpt2 = true,
    lpt3 = true,
    lpt4 = true,
    lpt5 = true,
    lpt6 = true,
    lpt7 = true,
    lpt8 = true,
    lpt9 = true,
}

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
    local value = _trim(path)
    if not value then
        return nil
    end
    value = value:gsub("\\", "/")
    value = value:gsub("//+", "/")
    return value
end

local function _join_path(...)
    local parts = {}
    for _, item in ipairs({...}) do
        local value = _normalize_path(item)
        if value then
            value = value:gsub("^/+", ""):gsub("/+$", "")
            if value ~= "" then
                parts[#parts + 1] = value
            end
        end
    end
    return table.concat(parts, "/")
end

local function _basename(path)
    local value = _normalize_path(path)
    return value and value:match("([^/]+)$") or nil
end

local function _safe_relative_path(path)
    local value = _normalize_path(path)
    if not value then
        return nil
    end
    if value:find("^[/\\]") or value:find("^[A-Za-z]:") or value:find("..", 1, true) then
        return nil
    end
    return value
end

local function _validate_plugin_id(id)
    if type(id) ~= "string" or id == "" then
        return false, "插件缺少 id"
    end
    if id:match("[^%w_%-%.]") then
        return false, "插件 id 只能包含字母、数字、下划线、中划线和点"
    end
    if id == "." or id == ".." or id:sub(1, 1) == "." or id:sub(-1) == "." then
        return false, "插件 id 不能使用点号路径语义"
    end
    if id:find("..", 1, true) then
        return false, "插件 id 不能包含连续点号"
    end

    local first_segment = string.lower(id:match("^([^%.]+)") or id)
    if reserved_windows_name_pool[first_segment] == true then
        return false, "插件 id 不能使用 Windows 保留设备名"
    end
    return true
end

local function _invalidate_plugin_dependent_caches()
    FlowTextCommandRegistry.invalidate()
    FlowTextExecutionBridge.invalidate_schema_cache()
end

local function _normalize_resource_map(raw_resources)
    if raw_resources == nil then
        return {}
    end
    if type(raw_resources) ~= "table" then
        return nil, "resources 必须是对象"
    end

    local result = {}
    for key, value in pairs(raw_resources) do
        local resource_key = _trim(key)
        if not resource_key then
            return nil, "resources 存在空 key"
        end
        local resource_path = _safe_relative_path(value)
        if not resource_path then
            return nil, string.format("resources.%s 必须是插件 resources 目录内的相对路径", resource_key)
        end
        result[resource_key] = resource_path
    end
    return result
end

local function _copy_table(source)
    local result = {}
    for key, value in pairs(type(source) == "table" and source or {}) do
        result[key] = value
    end
    return result
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

local function _copy_pin_spec(source)
    local spec = _copy_table(source)
    spec.key = _trim(spec.key)
    spec.type_id = _trim(spec.type_id) or "object"
    spec.name = _trim(spec.name)
    spec.options = type(spec.options) == "table" and _copy_table(spec.options) or spec.options
    return spec
end

local function _validate_pin_list(pin_list, direction)
    local key_pool = {}
    local flow_count = 0
    for index, spec in ipairs(type(pin_list) == "table" and pin_list or {}) do
        local type_id = _trim(spec.type_id)
        if not type_id then
            return false, string.format("%s[%d] 缺少 type_id", direction, index)
        end
        if not PinRegistry.has(type_id) then
            return false, string.format("%s[%d] 使用了未注册的引脚类型：%s", direction, index, type_id)
        end

        local key = _trim(spec.key)
        if key then
            if key_pool[key] then
                return false, string.format("%s 存在重复 key：%s", direction, key)
            end
            key_pool[key] = true
        end
        if type_id == "flow" then
            flow_count = flow_count + 1
        end
    end
    return true, flow_count
end

local function _normalize_pin_list(raw_list, fallback_list)
    local result = {}
    local source = type(raw_list) == "table" and raw_list or fallback_list
    for _, item in ipairs(type(source) == "table" and source or {}) do
        if type(item) == "table" then
            result[#result + 1] = _copy_pin_spec(item)
        end
    end
    return result
end

local function _clamp_byte(value)
    return math.max(0, math.min(255, math.floor(tonumber(value) or 0)))
end

local function _normalize_color(value)
    local r, g, b, a = 113, 143, 199, 255
    if type(value) == "table" then
        r = tonumber(value[1] or value.r) or r
        g = tonumber(value[2] or value.g) or g
        b = tonumber(value[3] or value.b) or b
        a = tonumber(value[4] or value.a) or a
    end
    return imgui.ImVec4(imgui.ImColor(
        _clamp_byte(r),
        _clamp_byte(g),
        _clamp_byte(b),
        _clamp_byte(a)).value)
end

local function _read_manifest(path)
    local manifest_path = _join_path(path, "manifest.json")
    if not NativeIO.file_exists(manifest_path) then
        return nil, "缺少 manifest.json"
    end

    local content, err = NativeIO.read_text(manifest_path)
    if not content then
        return nil, err or "无法读取 manifest.json"
    end

    local ok, data = json.ParseToLua(content)
    if not ok or type(data) ~= "table" then
        return nil, "manifest.json 解析失败"
    end

    return data
end

local function _normalize_manifest(path, raw_manifest)
    local package_path = _normalize_path(path)
    local id = _trim(raw_manifest.id) or _basename(package_path)
    local id_ok, id_err = _validate_plugin_id(id)
    if not id_ok then
        return nil, id_err
    end

    if raw_manifest.kind ~= nil and raw_manifest.kind ~= "plugin" then
        return nil, "manifest.kind 必须为 plugin"
    end

    local api_version = math.floor(tonumber(raw_manifest.api_version) or 1)
    if api_version < 1 or api_version > supported_api_version then
        return nil, string.format("不支持的插件 api_version：%s", tostring(raw_manifest.api_version))
    end

    local entry_point = _trim(raw_manifest.entry_point) or "scene.lua"
    if not _safe_relative_path(entry_point) then
        return nil, "entry_point 必须是插件目录内的相对路径"
    end

    local entry_path = _join_path(package_path, entry_point)
    if not NativeIO.file_exists(entry_path) then
        return nil, string.format("找不到插件入口：%s", entry_point)
    end

    local raw_resource_root = _trim(raw_manifest.resource_root)
    local resource_root = raw_resource_root and _safe_relative_path(raw_resource_root) or "resources"
    if raw_resource_root and not resource_root then
        return nil, "resource_root 必须是插件目录内的相对路径"
    end
    local resources, resources_err = _normalize_resource_map(raw_manifest.resources)
    if not resources then
        return nil, resources_err
    end

    local manifest =
    {
        kind = "plugin",
        api_version = api_version,
        id = id,
        display_name = _trim(raw_manifest.display_name) or id,
        version = _trim(raw_manifest.version) or "0.0.0",
        author = _trim(raw_manifest.author) or "",
        description = _trim(raw_manifest.description) or "",
        icon_id = _trim(raw_manifest.icon_id) or "game-2-fill",
        color = raw_manifest.color,
        category = _trim(raw_manifest.category) or "插件场景",
        category_order = tonumber(raw_manifest.category_order) or 10,
        category_default_open = raw_manifest.category_default_open ~= false,
        order = tonumber(raw_manifest.order) or 100,
        menu_visible = raw_manifest.menu_visible ~= false,
        entry_point = entry_point,
        entry_path = entry_path,
        package_path = package_path,
        resource_root = resource_root,
        resources = resources,
        node_type_id = _trim(raw_manifest.node_type_id) or ("plug_" .. id:gsub("[^%w_]", "_")),
        input_pins = _normalize_pin_list(raw_manifest.input_pins,
        {
            {key = "in", type_id = "flow"},
        }),
        output_pins = _normalize_pin_list(raw_manifest.output_pins,
        {
            {key = "out", type_id = "flow"},
        }),
        supports_save = raw_manifest.supports_save == true,
        reload_modules = raw_manifest.reload_modules ~= false,
        raw = raw_manifest,
    }

    local input_ok, input_err_or_flow_count = _validate_pin_list(manifest.input_pins, "input_pins")
    if not input_ok then
        return nil, input_err_or_flow_count
    end
    local output_ok, output_err_or_flow_count = _validate_pin_list(manifest.output_pins, "output_pins")
    if not output_ok then
        return nil, output_err_or_flow_count
    end
    if input_err_or_flow_count <= 0 then
        return nil, "插件节点至少需要一个 flow 输入引脚"
    end
    if output_err_or_flow_count <= 0 then
        return nil, "插件节点至少需要一个 flow 输出引脚"
    end
    return manifest
end

local function _load_custom_node_definition(manifest)
    local node_def_path = _join_path(manifest.package_path, "node_def.lua")
    if not NativeIO.file_exists(node_def_path) then
        return nil
    end

    local chunk, err = NativeIO.load_lua_chunk(node_def_path)
    if not chunk then
        return nil, err
    end

    local ok, definition = pcall(chunk, manifest)
    if not ok then
        return nil, definition
    end
    if type(definition) ~= "table" then
        return nil, "node_def.lua 必须返回节点定义 table"
    end
    return definition
end

function module.validate_package(path)
    local raw_manifest, read_err = _read_manifest(path)
    if not raw_manifest then
        return false, read_err
    end
    local manifest, normalize_err = _normalize_manifest(path, raw_manifest)
    if not manifest then
        return false, normalize_err
    end
    return true, manifest
end

function module.build_node_definition(manifest)
    local custom_definition, custom_err = _load_custom_node_definition(manifest)
    if custom_err then
        LogManager.log(string.format("插件节点定义加载失败，使用自动定义：%s\n%s", manifest.id, tostring(custom_err)), "warning")
    end
    if custom_definition then
        custom_definition.type_id = manifest.node_type_id
        custom_definition.kind = "node"
        custom_definition.title = custom_definition.title or custom_definition.name or manifest.display_name
        custom_definition.name = custom_definition.title
        custom_definition.icon_id = custom_definition.icon_id or manifest.icon_id
        custom_definition.color = custom_definition.color or _normalize_color(manifest.color)
        custom_definition.category = custom_definition.category or manifest.category
        custom_definition.category_order = custom_definition.category_order or manifest.category_order
        custom_definition.category_default_open = custom_definition.category_default_open
        if custom_definition.category_default_open == nil then
            custom_definition.category_default_open = manifest.category_default_open
        end
        custom_definition.order = custom_definition.order or manifest.order
        custom_definition.menu_visible = custom_definition.menu_visible ~= false and manifest.menu_visible ~= false
        custom_definition.plugin_manifest = manifest
        custom_definition.build = custom_definition.build or PlugRuntime.make_plugin_node_builder(manifest)
        return custom_definition
    end

    return
    {
        kind = "node",
        type_id = manifest.node_type_id,
        title = manifest.display_name,
        name = manifest.display_name,
        icon_id = manifest.icon_id,
        color = _normalize_color(manifest.color),
        comment = manifest.description,
        category = manifest.category,
        category_order = manifest.category_order,
        category_default_open = manifest.category_default_open,
        order = manifest.order,
        menu_visible = manifest.menu_visible,
        plugin_manifest = manifest,
        build = PlugRuntime.make_plugin_node_builder(manifest),
    }
end

local function _validate_node_definition(definition)
    if type(definition) ~= "table" then
        return false, "节点定义必须是 table"
    end
    if type(definition.type_id) ~= "string" or definition.type_id == "" then
        return false, "节点定义缺少 type_id"
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

local function _sync_global_registry()
    GlobalContext.plugin_registry = module.list_loaded()
    GlobalContext.plugin_registry_revision = (tonumber(GlobalContext.plugin_registry_revision) or 0) + 1
end

local function _make_empty_report(root)
    return
    {
        root_path = root,
        success_count = 0,
        failure_count = 0,
        unloaded_count = 0,
        reloaded_count = 0,
        items = {},
    }
end

local function _load_package(path, report)
    local ok, manifest_or_err = module.validate_package(path)
    if not ok then
        report.failure_count = report.failure_count + 1
        report.items[#report.items + 1] = {path = path, ok = false, error = manifest_or_err}
        LogManager.log(string.format("插件加载失败：%s\n%s", tostring(path), tostring(manifest_or_err)), "warning")
        return
    end

    local manifest = manifest_or_err
    if loaded_plugin_pool[manifest.id] then
        report.failure_count = report.failure_count + 1
        report.items[#report.items + 1] = {path = path, id = manifest.id, ok = false, error = "重复插件 id"}
        LogManager.log(string.format("插件 id 重复，已跳过：%s", manifest.id), "warning")
        return
    end
    if NodeRegistry.has(manifest.node_type_id) then
        report.failure_count = report.failure_count + 1
        report.items[#report.items + 1] = {path = path, id = manifest.id, ok = false, error = "重复节点 type_id"}
        LogManager.log(string.format("插件节点 type_id 重复，已跳过：%s", manifest.node_type_id), "warning")
        return
    end

    local definition = module.build_node_definition(manifest)
    if NodeRegistry.has(definition.type_id) then
        report.failure_count = report.failure_count + 1
        report.items[#report.items + 1] = {path = path, id = manifest.id, ok = false, error = "重复节点 type_id"}
        LogManager.log(string.format("插件节点 type_id 重复，已跳过：%s", definition.type_id), "warning")
        return
    end
    local valid, validate_err = _validate_node_definition(definition)
    if not valid then
        report.failure_count = report.failure_count + 1
        report.items[#report.items + 1] = {path = path, id = manifest.id, ok = false, error = validate_err}
        LogManager.log(string.format("插件节点定义无效：%s\n%s", manifest.id, tostring(validate_err)), "warning")
        return
    end

    NodeRegistry.register_category(manifest.category,
    {
        order = manifest.category_order,
        default_open = manifest.category_default_open,
    })
    local register_ok, register_err = pcall(NodeRegistry.register, definition, manifest.package_path)
    if not register_ok then
        report.failure_count = report.failure_count + 1
        report.items[#report.items + 1] = {path = path, id = manifest.id, ok = false, error = register_err}
        LogManager.log(string.format("插件节点注册失败：%s\n%s", manifest.id, tostring(register_err)), "warning")
        return
    end

    loaded_plugin_pool[manifest.id] =
    {
        manifest = manifest,
        definition = definition,
    }
    report.success_count = report.success_count + 1
    report.items[#report.items + 1] = {path = path, id = manifest.id, ok = true}
end

function module.scan_and_load(root_path)
    local root = _normalize_path(root_path) or default_root_path
    for _, entry in pairs(loaded_plugin_pool) do
        local node_type_id = entry.definition and entry.definition.type_id
            or entry.manifest and entry.manifest.node_type_id
            or nil
        if node_type_id then
            NodeRegistry.unregister(node_type_id)
        end
    end
    loaded_plugin_pool = {}
    local report = _make_empty_report(root)

    if not NativeIO.directory_exists(root) then
        _sync_global_registry()
        last_report = report
        return report
    end

    local path_list, list_err = NativeIO.list_directory_array(root, false, false)
    if not path_list then
        report.failure_count = report.failure_count + 1
        report.items[#report.items + 1] = {path = root, ok = false, error = list_err or "无法扫描插件目录"}
        _sync_global_registry()
        last_report = report
        return report
    end

    table.sort(path_list)
    for _, path in ipairs(path_list) do
        if NativeIO.directory_exists(path) then
            _load_package(path, report)
        end
    end

    if report.success_count > 0 or report.failure_count > 0 then
        _invalidate_plugin_dependent_caches()
        LogManager.log(string.format(
            "插件扫描完成：成功 %d，失败 %d",
            report.success_count,
            report.failure_count), report.failure_count > 0 and "warning" or "info")
    end

    _sync_global_registry()
    last_report = report
    return report
end

function module.reload_all(root_path)
    local root = _normalize_path(root_path) or default_root_path
    local previous_by_id = {}
    for id, entry in pairs(loaded_plugin_pool) do
        previous_by_id[id] = entry.definition and entry.definition.type_id
            or entry.manifest and entry.manifest.node_type_id
            or nil
    end

    for _, node_type_id in pairs(previous_by_id) do
        if node_type_id then
            NodeRegistry.unregister(node_type_id)
        end
    end

    local report = module.scan_and_load(root)
    local current_by_id = {}
    for id, entry in pairs(loaded_plugin_pool) do
        current_by_id[id] = entry.definition and entry.definition.type_id
            or entry.manifest and entry.manifest.node_type_id
            or nil
        if previous_by_id[id] then
            report.reloaded_count = report.reloaded_count + 1
        end
    end
    for id, _ in pairs(previous_by_id) do
        if not current_by_id[id] then
            report.unloaded_count = report.unloaded_count + 1
        end
    end
    if report.unloaded_count > 0 or report.reloaded_count > 0 then
        _invalidate_plugin_dependent_caches()
    end
    last_report = report
    return report
end

function module.unload(id)
    local entry = loaded_plugin_pool[id]
    if not entry then
        return false, "插件未加载"
    end

    local node_type_id = entry.definition and entry.definition.type_id
        or entry.manifest and entry.manifest.node_type_id
        or nil
    if node_type_id then
        NodeRegistry.unregister(node_type_id)
    end
    loaded_plugin_pool[id] = nil
    _sync_global_registry()
    _invalidate_plugin_dependent_caches()
    return true
end

function module.list_loaded()
    local result = {}
    for id, entry in pairs(loaded_plugin_pool) do
        result[id] = _clone_value(entry.manifest)
    end
    return result
end

function module.get(id)
    local entry = loaded_plugin_pool[id]
    return entry and entry.manifest or nil
end

function module.get_last_report()
    return last_report
end

return module

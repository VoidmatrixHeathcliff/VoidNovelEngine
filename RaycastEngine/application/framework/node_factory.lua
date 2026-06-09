local BlueprintNode = require("application.framework.blueprint_node")
local NodeBuilder = require("application.framework.node_builder")
local NodeRegistry = require("application.framework.node_registry")
local NodeRuntimeHelper = require("application.framework.node_runtime_helper")
local PinRegistry = require("application.framework.pin_registry")
local ResourcesManager = require("application.framework.resources_manager")
local TableUtil = require("application.framework.table_util")

local module = {}

local missing_node_definition_pool = {}

local function _normalize_args(...)
    local first = select(1, ...)
    if type(first) == "table" then
        return first
    end

    local blueprint, node_type, data = ...
    return
    {
        blueprint = blueprint,
        type_id = node_type,
        data = data,
    }
end

local function _normalize_runtime_callbacks(node)
    local on_execute = rawget(node, "on_execute") or rawget(node, "on_exetute") or BlueprintNode.on_execute
    local on_execute_update = rawget(node, "on_execute_update") or rawget(node, "on_exetute_update") or BlueprintNode.on_execute_update

    node.on_execute = on_execute
    node.on_execute_update = on_execute_update
    node.on_exetute = rawget(node, "on_exetute") or on_execute
    node.on_exetute_update = rawget(node, "on_exetute_update") or on_execute_update
end

local function _prepare_node_data(definition, data)
    if type(data) ~= "table" then
        return data
    end

    local pin_schema_version = tonumber(definition and definition.pin_schema_version) or 1
    local source_version = tonumber(rawget(data, "pin_schema_version"))
    local should_migrate = type(definition and definition.migrate_pins) == "function"
        and (rawget(data, "pin_schema_version") == nil or (source_version or 0) < pin_schema_version)

    if not should_migrate then
        return data
    end

    local migrated_data = TableUtil.deep_copy(data)
    local context =
    {
        definition = definition,
        source_pin_schema_version = source_version,
        target_pin_schema_version = pin_schema_version,
        registry = NodeRegistry,
        helpers = NodeRuntimeHelper,
    }

    local result = definition.migrate_pins(migrated_data, context)
    if result ~= nil then
        assert(type(result) == "table", "node migrate_pins must return a table or nil")
        migrated_data = result
    end
    migrated_data.pin_schema_version = pin_schema_version
    return migrated_data
end

local function _build_missing_node_definition(type_id)
    local definition = missing_node_definition_pool[type_id]
    if definition then
        return definition
    end

    definition =
    {
        kind = "node",
        type_id = type_id,
        title = string.format("缺失节点：%s", type_id),
        name = string.format("缺失节点：%s", type_id),
        icon_id = "alert-triangle-fill",
        comment = "该节点定义当前不可用，可能来自已删除或加载失败的插件。",
        category = "缺失节点",
        category_order = 9999,
        menu_visible = false,
        build = function(ctx)
            local node = ctx:create_base_node(
            {
                title = string.format("缺失节点：%s", type_id),
                comment = "节点定义不可用",
                icon = ResourcesManager.find_icon("alert-triangle-fill"),
                header_color = nil,
                use_definition_style = false,
            })
            local builder = ctx.builder
            local raw_data = type(ctx.data) == "table" and ctx.data or {}
            for _, pin_data in ipairs(raw_data.input_pin_list or {}) do
                if type(pin_data) == "table" and type(pin_data.type_id) == "string" then
                    local pin_type_id = PinRegistry.has(pin_data.type_id) and pin_data.type_id or "object"
                    builder:add_input(
                    {
                        type_id = pin_type_id,
                        key = pin_data.key,
                        name = pin_data.name or (pin_type_id ~= pin_data.type_id and ("缺失引脚：" .. pin_data.type_id) or nil),
                        raw_data = pin_data,
                    })
                end
            end
            for _, pin_data in ipairs(raw_data.output_pin_list or {}) do
                if type(pin_data) == "table" and type(pin_data.type_id) == "string" then
                    local pin_type_id = PinRegistry.has(pin_data.type_id) and pin_data.type_id or "object"
                    builder:add_output(
                    {
                        type_id = pin_type_id,
                        key = pin_data.key,
                        name = pin_data.name or (pin_type_id ~= pin_data.type_id and ("缺失引脚：" .. pin_data.type_id) or nil),
                        raw_data = pin_data,
                    })
                end
            end
            node.on_execute = function(self)
                NodeRuntimeHelper.abort(self, string.format("节点类型当前不可用：%s", type_id), "missing_node_definition")
            end
            node.can_save_now = function()
                return false, string.format("节点类型当前不可用：%s", type_id)
            end
            return node
        end,
    }
    missing_node_definition_pool[type_id] = definition
    return definition
end

module.create = function(...)
    local args = _normalize_args(...)
    assert(type(args) == "table", "NodeFactory.create expects a table")
    assert(args.blueprint, "NodeFactory.create missing blueprint")
    assert(type(args.type_id) == "string" and #args.type_id > 0, "NodeFactory.create missing type_id")

    local definition = NodeRegistry.get(args.type_id) or _build_missing_node_definition(args.type_id)
    local node_data = _prepare_node_data(definition, args.data)

    local ctx =
    {
        blueprint = args.blueprint,
        data = node_data,
        definition = definition,
        node = nil,
        builder = nil,
        registry = NodeRegistry,
        helpers = NodeRuntimeHelper,
    }

    function ctx:create_base_node(option)
        option = option or {}
        local use_definition_style = option.use_definition_style ~= false
        local node = BlueprintNode.new(
            args.blueprint,
            node_data,
            option.type_id or definition.type_id,
            option.icon ~= nil and option.icon
                or (use_definition_style and definition.icon_id and ResourcesManager.find_icon(definition.icon_id) or nil),
            option.header_color ~= nil and option.header_color
                or (use_definition_style and definition.color or nil),
            option.title ~= nil and option.title
                or (use_definition_style and definition.title or nil),
            option.comment ~= nil and option.comment
                or (use_definition_style and definition.comment or nil))
        node._def = definition
        ctx.node = node
        ctx.builder = NodeBuilder.new(node, node_data)
        return node
    end

    local node = definition.build(ctx)
    assert(node, string.format("node definition did not return a node: %s", args.type_id))

    if not ctx.builder then
        ctx.builder = NodeBuilder.new(node, node_data)
    end

    node._def = definition
    _normalize_runtime_callbacks(node)
    return node
end

return module

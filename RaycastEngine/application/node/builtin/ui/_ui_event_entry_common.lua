local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper
local ResourceIndex = require("application.framework.resource_index")

local module = {}

local scope_filter_list =
{
    {key = "ui_filter", type_id = "ui", name = "界面文件", width_input = 128},
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

local function _get_ui_event_context(node)
    local blueprint = node and node._blueprint or nil
    if blueprint and type(blueprint.get_ui_event_context) == "function" then
        local context = blueprint:get_ui_event_context()
        if type(context) == "table" then
            return context
        end
    end

    local context = blueprint and blueprint._ui_event_runtime_context or nil
    return type(context) == "table" and context or {}
end

local function _read_filter_text(node, key)
    local pin = node and node.find_input_pin and node:find_input_pin(key) or nil
    if not pin or type(pin.get_val) ~= "function" then
        return ""
    end
    return _trim(pin:get_val()) or ""
end

local function _read_filter_reference(node, key, asset_type)
    local pin = node and node.find_input_pin and node:find_input_pin(key) or nil
    if not pin or type(pin.get_reference) ~= "function" then
        return nil
    end
    return ResourceIndex.make_reference(asset_type, pin:get_reference())
end

local function _matches_ui_reference(filter_reference, payload)
    if type(filter_reference) ~= "table" then
        return true
    end

    local filter_guid = ResourceIndex.resolve_guid("ui", filter_reference)
    local payload_guid = ResourceIndex.resolve_guid("ui", payload and (payload.source_guid or payload.source_path) or nil)
    if filter_guid and payload_guid then
        return filter_guid == payload_guid
    end

    local hint = _trim(filter_reference.path_hint)
    if not hint then
        return true
    end
    return hint == tostring(payload and payload.source_path or "")
        or hint == tostring(payload and payload.source_guid or "")
end

local function _matches_scope_filters(node, payload)
    local ui_filter = _read_filter_reference(node, "ui_filter", "ui")
    if not _matches_ui_reference(ui_filter, payload) then
        return false
    end
    return true
end

local function _find_pin_data(pin_list, key)
    for _, pin in ipairs(type(pin_list) == "table" and pin_list or {}) do
        if pin.key == key then
            return pin
        end
    end
    return nil
end

local function _ensure_filter_pin_data(data, filter)
    if type(data) ~= "table" then
        return
    end
    data.input_pin_list = type(data.input_pin_list) == "table" and data.input_pin_list or {}
    local pin = _find_pin_data(data.input_pin_list, filter.key)
    if not pin then
        pin =
        {
            key = filter.key,
            type_id = filter.type_id or "string",
            name = filter.name,
            is_output = false,
        }
        table.insert(data.input_pin_list, pin)
    end
    pin.name = filter.name
    pin.type_id = filter.type_id or pin.type_id or "string"
    pin.is_output = false
    if pin.type_id == "string" and type(pin.val) ~= "string" then
        pin.val = ""
    end
end

local function _compose_filter_list(config)
    local list = {}
    if config.use_scope_filters ~= false then
        for _, filter in ipairs(scope_filter_list) do
            list[#list + 1] = filter
        end
    end
    for _, filter in ipairs(config.filter_list or {}) do
        list[#list + 1] = filter
    end
    return list
end

local function _migrate_user_labels(data, filter_list)
    for _, filter in ipairs(filter_list or {}) do
        _ensure_filter_pin_data(data, filter)
    end
    return data
end

function module.create_definition(config)
    local filter_list = _compose_filter_list(config)
    local NodeDef =
    {
        type_id = config.type_id,
        pin_schema_version = config.pin_schema_version or 8,
        icon_id = config.icon_id,
        color = config.color,
        name = config.name,
        comment = config.comment,
        category = "界面逻辑",
        category_order = 4,
        order = config.order or 1,
        menu_visible = config.menu_visible ~= false,
        migrate_pins = function(data)
            if type(config.migrate_pins) == "function" then
                data = config.migrate_pins(data) or data
            end
            return _migrate_user_labels(data, filter_list)
        end,
    }
    return Common.make_definition(NodeDef, function(ctx)
        local node = ctx:create_base_node()
        local builder = ctx.builder

        for _, filter in ipairs(filter_list or {}) do
            builder:add_input(
            {
                key = filter.key,
                type_id = filter.type_id or "string",
                name = filter.name,
                options = {width_input = filter.width_input or 96},
                default = filter.default or "",
            })
        end

        builder:add_output({key = "out", type_id = "flow"})

        node.on_execute = function(self, scene)
            local event_context = _get_ui_event_context(self)
            local payload = type(event_context.payload) == "table" and event_context.payload or {}
            if not _matches_scope_filters(self, payload) then
                return
            end
            if type(config.matches) == "function" and not config.matches(self, event_context, payload, _read_filter_text) then
                return
            end

            NodeRuntimeHelper.execute_next_node(self, "out")
        end

        return node
    end)
end

module.color = imgui.ImVec4(imgui.ImColor(72, 138, 104, 255).value)

return module

local module = {}
local FlowDocNormalizer = require("application.framework.flow_doc_normalizer")

local def_pool = {}
local ordered_def_list = {}
local asset_payload_pool = {}

local default_category_meta =
{
    ["演出控制"] = {order = 1, default_open = true},
    ["音频控制"] = {order = 2, default_open = false},
    ["流程控制"] = {order = 3, default_open = false},
    ["对象功能"] = {order = 4, default_open = false},
    ["环境变量"] = {order = 5, default_open = false},
    ["值节点"] = {order = 6, default_open = false},
    ["运算与逻辑"] = {order = 7, default_open = false},
    ["资产节点"] = {order = 8, default_open = false},
    ["其他"] = {order = 9, default_open = false},
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

local function _copy_table(src)
    local dst = {}
    if not src then return dst end
    for key, value in pairs(src) do
        dst[key] = value
    end
    return dst
end

local function _normalize_script_meta(script_meta, type_id)
    return FlowDocNormalizer.normalize_script_meta(script_meta, type_id)
end

local function _sort_def_list()
    table.sort(ordered_def_list, function(left, right)
        local category_left = left.category_order or 1000
        local category_right = right.category_order or 1000
        if category_left ~= category_right then
            return category_left < category_right
        end

        local order_left = left.order or 1000
        local order_right = right.order or 1000
        if order_left ~= order_right then
            return order_left < order_right
        end

        return left.type_id < right.type_id
    end)
end

module.clear = function()
    def_pool = {}
    ordered_def_list = {}
    asset_payload_pool = {}
end

module.register_category = function(name, meta)
    local category_name = _trim(name)
    if not category_name then
        return false
    end

    local source = type(meta) == "table" and meta or {}
    default_category_meta[category_name] =
    {
        order = tonumber(source.order) or tonumber(source.category_order) or 1000,
        default_open = source.default_open == true or source.category_default_open == true,
    }
    return true
end

module.register = function(definition, source_path)
    assert(type(definition) == "table", "node definition must be a table")
    assert(type(definition.type_id) == "string" and #definition.type_id > 0, "node definition missing type_id")

    if def_pool[definition.type_id] then
        error(string.format("duplicate node type id: %s", definition.type_id))
    end

    local def = _copy_table(definition)
    def.api_version = def.api_version or 1
    def.kind = "node"
    def.pin_schema_version = tonumber(def.pin_schema_version) or 1
    def.title = def.title or def.name or def.type_id
    def.name = def.title
    def.category = def.category or "其他"
    def.menu_visible = def.menu_visible ~= false
    def.order = def.order or 1000

    local category_meta = default_category_meta[def.category] or {}
    def.category_order = def.category_order or category_meta.order or 1000
    def.category_default_open = def.category_default_open
    if def.category_default_open == nil then
        def.category_default_open = category_meta.default_open or false
    end

    def.keywords = def.keywords or {}
    def.source_path = source_path
    def.script = _normalize_script_meta(def.script, def.type_id)

    if def.asset_payload then
        if asset_payload_pool[def.asset_payload] then
            error(string.format("duplicate asset payload node mapping: %s", def.asset_payload))
        end
        asset_payload_pool[def.asset_payload] = def
    end

    def_pool[def.type_id] = def
    table.insert(ordered_def_list, def)
    _sort_def_list()
    return def
end

module.unregister = function(type_id)
    local key = _trim(type_id)
    if not key then
        return false
    end

    local definition = def_pool[key]
    if not definition then
        return false
    end

    def_pool[key] = nil
    if definition.asset_payload and asset_payload_pool[definition.asset_payload] == definition then
        asset_payload_pool[definition.asset_payload] = nil
    end
    for index = #ordered_def_list, 1, -1 do
        if ordered_def_list[index] == definition or ordered_def_list[index].type_id == key then
            table.remove(ordered_def_list, index)
        end
    end
    return true
end

module.get = function(type_id)
    return def_pool[type_id]
end

module.has = function(type_id)
    return def_pool[type_id] ~= nil
end

module.list = function()
    local result = {}
    for index, definition in ipairs(ordered_def_list) do
        result[index] = definition
    end
    return result
end

module.find_by_asset_payload = function(payload_type)
    return asset_payload_pool[payload_type]
end

module.get_menu_tree = function()
    local category_pool = {}
    local category_list = {}

    for _, definition in ipairs(ordered_def_list) do
        if definition.menu_visible then
            local category = category_pool[definition.category]
            if not category then
                category =
                {
                    name = definition.category,
                    order = definition.category_order or 1000,
                    default_open = definition.category_default_open == true,
                    node_list = {},
                }
                category_pool[definition.category] = category
                table.insert(category_list, category)
            end
            table.insert(category.node_list, definition)
        end
    end

    table.sort(category_list, function(left, right)
        if left.order ~= right.order then
            return left.order < right.order
        end
        return left.name < right.name
    end)

    for _, category in ipairs(category_list) do
        table.sort(category.node_list, function(left, right)
            local order_left = left.order or 1000
            local order_right = right.order or 1000
            if order_left ~= order_right then
                return order_left < order_right
            end
            return left.type_id < right.type_id
        end)
    end

    return category_list
end

module.list_menu_tree = module.get_menu_tree

module.list_by_category = function()
    return module.get_menu_tree()
end

return module

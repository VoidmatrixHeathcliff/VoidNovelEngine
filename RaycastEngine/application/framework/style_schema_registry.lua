local PinRegistry = require("application.framework.pin_registry")

local module = {}

local domain_pool = {}
local ordered_domain_list = {}
local initialized = false

local builtin_domain_defs =
{
    {
        id = "dialog_box",
        display_name = "对话框",
        order = 1,
        field_list =
        {
            {key = "position", display_name = "位置", type_id = "vector2", order = 1},
            {key = "width", display_name = "宽度", type_id = "float", order = 2},
            {key = "fade_time", display_name = "淡入时间", type_id = "float", order = 3},
            {key = "fade_out_time", display_name = "淡出时间", type_id = "float", order = 4},
            {key = "role_font", display_name = "角色字体", type_id = "font", order = 5},
            {key = "dialogue_font", display_name = "内容字体", type_id = "font", order = 6},
            {key = "role_font_size", display_name = "角色字号", type_id = "int", order = 7},
            {key = "dialogue_font_size", display_name = "内容字号", type_id = "int", order = 8},
            {key = "role_color", display_name = "角色颜色", type_id = "color", order = 9},
            {key = "dialogue_color", display_name = "内容颜色", type_id = "color", order = 10},
            {key = "background_color", display_name = "背景颜色", type_id = "color", order = 11},
            {key = "background_image", display_name = "背景图片", type_id = "texture", order = 12},
        }
    },
    {
        id = "subtitle",
        display_name = "字幕",
        order = 2,
        field_list =
        {
            {key = "char_interval", display_name = "字符时间间隔", type_id = "float", order = 1},
            {key = "bottom_distance", display_name = "底部距离", type_id = "float", order = 2},
            {key = "font", display_name = "字体", type_id = "font", order = 3},
            {key = "font_size", display_name = "字号", type_id = "int", order = 4},
            {key = "color", display_name = "颜色", type_id = "color", order = 5},
        }
    },
    {
        id = "choice_button",
        display_name = "分支按钮",
        order = 3,
        field_list =
        {
            {key = "font", display_name = "字体", type_id = "font", order = 1},
            {key = "font_size", display_name = "字号", type_id = "int", order = 2},
            {key = "text_color", display_name = "默认颜色", type_id = "color", order = 3},
            {key = "hover_color", display_name = "高亮颜色", type_id = "color", order = 4},
            {key = "background_color", display_name = "背景颜色", type_id = "color", order = 5},
            {key = "border_color", display_name = "边框颜色", type_id = "color", order = 6},
            {key = "button_spacing", display_name = "按钮间隔", type_id = "int", order = 7},
            {key = "button_padding", display_name = "按钮内边距", type_id = "vector2", order = 8},
            {key = "bottom_distance", display_name = "底部距离", type_id = "float", order = 9},
            {key = "minimum_width", display_name = "最小宽度", type_id = "float", order = 10},
            {key = "background_image", display_name = "背景图片", type_id = "texture", order = 11},
        }
    },
    {
        id = "shader",
        display_name = "着色器",
        order = 4,
        field_list =
        {
            {key = "global", display_name = "全局后处理", type_id = "shader", order = 1},
            {key = "background", display_name = "背景", type_id = "shader", order = 2},
            {key = "foreground", display_name = "前景", type_id = "shader", order = 3},
            {key = "video", display_name = "视频", type_id = "shader", order = 4},
        }
    },
}

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

local function _sort_domain_list()
    table.sort(ordered_domain_list, function(left, right)
        local left_order = left.order or 1000
        local right_order = right.order or 1000
        if left_order ~= right_order then
            return left_order < right_order
        end
        return left.id < right.id
    end)
end

local function _sort_field_list(domain)
    table.sort(domain.field_list, function(left, right)
        local left_order = left.order or 1000
        local right_order = right.order or 1000
        if left_order ~= right_order then
            return left_order < right_order
        end
        return left.key < right.key
    end)
end

function module.clear()
    domain_pool = {}
    ordered_domain_list = {}
    initialized = false
end

function module.register_domain(definition)
    assert(type(definition) == "table", "style domain definition must be a table")
    local id = assert(_trim(definition.id), "style domain definition missing id")
    if domain_pool[id] then
        error(string.format("duplicate style domain id: %s", id))
    end

    local domain =
    {
        id = id,
        display_name = _trim(definition.display_name) or id,
        order = tonumber(definition.order) or 1000,
        builtin = definition.builtin ~= false,
        field_pool = {},
        field_list = {},
    }

    domain_pool[id] = domain
    table.insert(ordered_domain_list, domain)
    _sort_domain_list()
    return domain
end

function module.register_field(domain_id, definition)
    local domain = domain_pool[domain_id]
    assert(domain, string.format("unknown style domain id: %s", tostring(domain_id)))
    assert(type(definition) == "table", "style field definition must be a table")

    local key = assert(_trim(definition.key), "style field definition missing key")
    if domain.field_pool[key] then
        error(string.format("duplicate style field key: %s.%s", domain_id, key))
    end

    local field =
    {
        domain_id = domain_id,
        key = key,
        display_name = _trim(definition.display_name) or key,
        type_id = assert(_trim(definition.type_id), "style field definition missing type_id"),
        order = tonumber(definition.order) or 1000,
        builtin = definition.builtin ~= false,
    }

    domain.field_pool[key] = field
    table.insert(domain.field_list, field)
    _sort_field_list(domain)
    return field
end

local function _ensure_initialized()
    if initialized then
        return
    end

    initialized = true
    for _, domain_def in ipairs(builtin_domain_defs) do
        local domain = module.register_domain(
        {
            id = domain_def.id,
            display_name = domain_def.display_name,
            order = domain_def.order,
            builtin = true,
        })
        for _, field_def in ipairs(domain_def.field_list or {}) do
            module.register_field(domain.id,
            {
                key = field_def.key,
                display_name = field_def.display_name,
                type_id = field_def.type_id,
                order = field_def.order,
                builtin = true,
            })
        end
    end
end

function module.get_domain(domain_id)
    _ensure_initialized()
    return domain_pool[_trim(domain_id)]
end

function module.get_field(domain_id, field_key)
    local domain = module.get_domain(domain_id)
    if not domain then
        return nil
    end
    return domain.field_pool[_trim(field_key)]
end

function module.list_domains()
    _ensure_initialized()
    local result = {}
    for index, domain in ipairs(ordered_domain_list) do
        result[index] =
        {
            id = domain.id,
            display_name = domain.display_name,
            order = domain.order,
            builtin = domain.builtin,
            field_list = module.list_fields(domain.id),
        }
    end
    return result
end

function module.list_fields(domain_id)
    local domain = module.get_domain(domain_id)
    if not domain then
        return {}
    end

    local result = {}
    for index, field in ipairs(domain.field_list) do
        result[index] = _clone_table(field)
    end
    return result
end

function module.is_builtin_domain(domain_id)
    local domain = module.get_domain(domain_id)
    return domain and domain.builtin == true or false
end

function module.is_builtin_field(domain_id, field_key)
    local field = module.get_field(domain_id, field_key)
    return field and field.builtin == true or false
end

function module.list_styleable_pin_types()
    local result = {}
    for _, definition in ipairs(PinRegistry.list()) do
        if definition.style_adapter and definition.style_adapter.allow_custom_field ~= false then
            table.insert(result,
            {
                type_id = definition.type_id,
                display_name = definition.display_name or definition.name or definition.type_id,
                definition = definition,
            })
        end
    end

    table.sort(result, function(left, right)
        return left.display_name < right.display_name
    end)
    return result
end

return module

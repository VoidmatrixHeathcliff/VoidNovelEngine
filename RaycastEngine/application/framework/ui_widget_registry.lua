local module = {}

local definition_pool = {}
local ordered_definition_list = {}
local initialized = false

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
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

local function _sort_definitions()
    table.sort(ordered_definition_list, function(left, right)
        local left_category = tostring(left.category or "")
        local right_category = tostring(right.category or "")
        if left_category ~= right_category then
            return left_category < right_category
        end

        local left_order = tonumber(left.order) or 1000
        local right_order = tonumber(right.order) or 1000
        if left_order ~= right_order then
            return left_order < right_order
        end
        return tostring(left.type_id) < tostring(right.type_id)
    end)
end

local function _sort_property_list(definition)
    table.sort(definition.property_list, function(left, right)
        local left_section = tostring(left.section or "")
        local right_section = tostring(right.section or "")
        if left_section ~= right_section then
            return left_section < right_section
        end

        local left_order = tonumber(left.order) or 1000
        local right_order = tonumber(right.order) or 1000
        if left_order ~= right_order then
            return left_order < right_order
        end
        return tostring(left.key) < tostring(right.key)
    end)
end

local function _register(definition)
    local type_id = assert(_trim(definition.type_id), "ui widget definition missing type_id")
    if definition_pool[type_id] then
        error(string.format("duplicate ui widget definition: %s", type_id))
    end

    local normalized =
    {
        type_id = type_id,
        display_name = _trim(definition.display_name) or type_id,
        default_name = _trim(definition.default_name) or (_trim(definition.display_name) or type_id),
        category = _trim(definition.category) or "基础",
        order = tonumber(definition.order) or 1000,
        can_have_children = definition.can_have_children ~= false,
        property_list = {},
        property_pool = {},
        event_list = _clone_value(definition.event_list or definition.events or {}),
        slot_list = _clone_value(definition.slot_list or definition.slots or {}),
        style_domain = _trim(definition.style_domain),
        hidden_from_create = definition.hidden_from_create == true,
        create_runtime = definition.create_runtime,
        draw_inspector = definition.draw_inspector,
    }

    for _, property in ipairs(definition.property_list or {}) do
        local key = assert(_trim(property.key), string.format("ui widget property missing key: %s", type_id))
        local item = _clone_value(property)
        item.key = key
        item.display_name = _trim(item.display_name) or key
        item.section = _trim(item.section) or "属性"
        item.order = tonumber(item.order) or 1000
        normalized.property_pool[key] = item
        table.insert(normalized.property_list, item)
    end

    _sort_property_list(normalized)
    definition_pool[type_id] = normalized
    table.insert(ordered_definition_list, normalized)
    _sort_definitions()
    return normalized
end

local function _vec2(x, y)
    return {x = x, y = y}
end

local function _color(r, g, b, a)
    return {r = r, g = g, b = b, a = a}
end

local function _padding(left, top, right, bottom)
    return {left = left, top = top, right = right, bottom = bottom}
end

local function _resource(path_hint)
    return {path_hint = path_hint}
end

local function _common_rect_property_list()
    return
    {
        {key = "visible", display_name = "可见", type_id = "bool", section = "布局", order = 1, default = true},
        {key = "opacity", display_name = "透明度", type_id = "float", section = "布局", order = 2, default = 1.0, min = 0.0, max = 1.0, step = 0.05},
        {key = "hit_test_enabled", display_name = "接收鼠标点击", type_id = "bool", section = "交互", order = 1, default = true, description = "兼容字段，普通编辑不用改。"},
        {key = "consume_input", display_name = "阻止背景输入", type_id = "enum", section = "交互", order = 2, default = "block", option_list = {"block", "pass"}, description = "组件被点中时是否阻止背景继续响应同一次输入。"},
        {key = "block_background_input", display_name = "背景输入兼容", type_id = "bool", section = "交互", order = 3, default = false, description = "旧文档兼容字段，普通编辑不用改。"},
        {key = "anchor_min", display_name = "锚点起始", type_id = "vec2", section = "布局", order = 10, default = _vec2(0, 0)},
        {key = "anchor_max", display_name = "锚点结束", type_id = "vec2", section = "布局", order = 11, default = _vec2(0, 0)},
        {key = "offset_min", display_name = "偏移起始", type_id = "vec2", section = "布局", order = 12, default = _vec2(0, 0)},
        {key = "offset_max", display_name = "偏移结束", type_id = "vec2", section = "布局", order = 13, default = _vec2(320, 180)},
        {key = "pivot", display_name = "枢轴", type_id = "vec2", section = "布局", order = 14, default = _vec2(0, 0)},
        {key = "preferred_size", display_name = "首选尺寸", type_id = "vec2", section = "布局", order = 15, default = _vec2(0, 0)},
        {key = "min_size", display_name = "最小尺寸", type_id = "vec2", section = "布局", order = 16, default = _vec2(0, 0)},
        {key = "layout_stretch", display_name = "容器拉伸", type_id = "bool", section = "布局", order = 17, default = false},
        {key = "style_domain", display_name = "样式域", type_id = "string", section = "样式", order = 100, default = ""},
    }
end

local function _append_property_list(target_list, property_list)
    for _, item in ipairs(property_list or {}) do
        table.insert(target_list, item)
    end
    return target_list
end

local function _common_rounded_rect_property_list()
    return _append_property_list(_common_rect_property_list(),
    {
        {key = "corner_radius", display_name = "圆角程度", type_id = "int", section = "外观", order = 4, default = 0, min = 0, max = 100, step = 1},
    })
end

local function _ensure_initialized()
    if initialized then
        return
    end
    initialized = true

    _register(
    {
        type_id = "Canvas",
        display_name = "画布",
        default_name = "根画布",
        category = "基础",
        order = 1,
        can_have_children = true,
        property_list = _append_property_list(_common_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0, 0, 0, 0)},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(0, 0, 0, 0)},
        }),
    })

    _register(
    {
        type_id = "Panel",
        display_name = "面板",
        category = "基础",
        order = 2,
        can_have_children = true,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0.11, 0.12, 0.14, 0.92)},
            {key = "border_color", display_name = "边框颜色", type_id = "color", section = "外观", order = 2, default = _color(0.34, 0.37, 0.42, 0.92)},
            {key = "border_thickness", display_name = "边框粗细", type_id = "float", section = "外观", order = 3, default = 1.0, min = 0.0, max = 8.0, step = 0.5},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(16, 16, 16, 16)},
        }),
    })

    _register(
    {
        type_id = "Text",
        display_name = "文本",
        category = "基础",
        order = 3,
        can_have_children = false,
        property_list = _append_property_list(_common_rect_property_list(),
        {
            {key = "text", display_name = "文本内容", type_id = "multiline", section = "文本", order = 1, default = "文本"},
            {key = "font", display_name = "字体", type_id = "resource", resource_type = "font", section = "文本", order = 2, default = _resource("font/font.otf")},
            {key = "font_size", display_name = "字号", type_id = "int", section = "文本", order = 3, default = 28, min = 8, max = 96, step = 1},
            {key = "text_color", display_name = "文字颜色", type_id = "color", section = "文本", order = 4, default = _color(1, 1, 1, 1)},
            {key = "align_x", display_name = "水平对齐", type_id = "enum", section = "文本", order = 6, default = "start", option_list = {"start", "center", "end"}},
            {key = "align_y", display_name = "垂直对齐", type_id = "enum", section = "文本", order = 7, default = "start", option_list = {"start", "center", "end"}},
        }),
    })

    _register(
    {
        type_id = "Image",
        display_name = "图片",
        category = "基础",
        order = 4,
        can_have_children = false,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "texture", display_name = "纹理", type_id = "resource", resource_type = "texture", section = "外观", order = 1, default = nil},
            {key = "shader", display_name = "着色器", type_id = "resource", resource_type = "shader", section = "外观", order = 2, default = nil, allow_clear = true},
            {key = "image_fit_mode", display_name = "显示方式", type_id = "enum", section = "样式", order = 1000, default = "preserve_aspect", option_list = {"fill", "preserve_aspect"}},
        }),
    })

    _register(
    {
        type_id = "SaveSlotGrid",
        display_name = "存档网格",
        category = "系统",
        order = 9,
        can_have_children = false,
        property_list = _append_property_list(_common_rect_property_list(),
        {
            {key = "mode", display_name = "操作", type_id = "enum", section = "交互", order = 0, default = "save", option_list = {"save", "load"}},
            {key = "gap", display_name = "卡片间距", type_id = "float", section = "布局", order = 21, default = 12, min = 0, max = 80, step = 1},
            {key = "font_size", display_name = "字号", type_id = "int", section = "文本", order = 30, default = 22, min = 8, max = 48, step = 1},
            {key = "text_color", display_name = "文字颜色", type_id = "color", section = "外观", order = 31, default = _color(1, 1, 1, 1)},
            {key = "muted_text_color", display_name = "辅助文字颜色", type_id = "color", section = "外观", order = 32, default = _color(0.64, 0.68, 0.74, 1)},
            {key = "background_color", display_name = "卡片底色", type_id = "color", section = "外观", order = 40, default = _color(0.13, 0.15, 0.18, 0.96)},
            {key = "disabled_color", display_name = "翻页控件底色", type_id = "color", section = "外观", order = 41, default = _color(0.09, 0.10, 0.12, 0.82)},
            {key = "hover_color", display_name = "悬停底色", type_id = "color", section = "外观", order = 42, default = _color(0.18, 0.22, 0.27, 0.98)},
            {key = "border_color", display_name = "边框颜色", type_id = "color", section = "外观", order = 43, default = _color(0.34, 0.38, 0.44, 0.92)},
            {key = "border_thickness", display_name = "边框粗细", type_id = "float", section = "外观", order = 44, default = 1.0, min = 0, max = 8, step = 0.5},
        }),
    })

    _register(
    {
        type_id = "Button",
        display_name = "按钮",
        category = "交互",
        order = 10,
        can_have_children = false,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "text", display_name = "按钮文本", type_id = "string", section = "文本", order = 1, default = "按钮"},
            {key = "font", display_name = "字体", type_id = "resource", resource_type = "font", section = "文本", order = 2, default = _resource("font/font.otf")},
            {key = "font_size", display_name = "字号", type_id = "int", section = "文本", order = 3, default = 28, min = 8, max = 96, step = 1},
            {key = "text_color", display_name = "文字颜色", type_id = "color", section = "文本", order = 4, default = _color(1, 1, 1, 1)},
            {key = "background_color", display_name = "默认底色", type_id = "color", section = "外观", order = 10, default = _color(0.17, 0.20, 0.24, 0.95)},
            {key = "hover_color", display_name = "悬停底色", type_id = "color", section = "外观", order = 11, default = _color(0.23, 0.29, 0.35, 0.98)},
            {key = "pressed_color", display_name = "按下底色", type_id = "color", section = "外观", order = 12, default = _color(0.11, 0.15, 0.19, 1.0)},
            {key = "border_color", display_name = "边框颜色", type_id = "color", section = "外观", order = 13, default = _color(0.42, 0.47, 0.54, 0.95)},
            {key = "border_thickness", display_name = "边框粗细", type_id = "float", section = "外观", order = 14, default = 1.0, min = 0.0, max = 8.0, step = 0.5},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(18, 10, 18, 10)},
        }),
    })

    _register(
    {
        type_id = "Toggle",
        display_name = "切换按钮",
        category = "交互",
        order = 11,
        can_have_children = false,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "text", display_name = "按钮文本", type_id = "string", section = "文本", order = 1, default = "开关项"},
            {key = "font", display_name = "字体", type_id = "resource", resource_type = "font", section = "文本", order = 2, default = _resource("font/font.otf")},
            {key = "font_size", display_name = "字号", type_id = "int", section = "文本", order = 3, default = 26, min = 8, max = 96, step = 1},
            {key = "text_color", display_name = "文字颜色", type_id = "color", section = "文本", order = 4, default = _color(1, 1, 1, 1)},
            {key = "value", display_name = "当前值", type_id = "bool", section = "交互", order = 5, default = false},
            {key = "background_color", display_name = "默认底色", type_id = "color", section = "外观", order = 10, default = _color(0.11, 0.13, 0.16, 0.96)},
            {key = "hover_color", display_name = "悬停底色", type_id = "color", section = "外观", order = 11, default = _color(0.16, 0.19, 0.23, 0.98)},
            {key = "checked_color", display_name = "选中底色", type_id = "color", section = "外观", order = 12, default = _color(0.18, 0.34, 0.27, 1.0)},
            {key = "border_color", display_name = "边框颜色", type_id = "color", section = "外观", order = 13, default = _color(0.42, 0.47, 0.54, 0.95)},
            {key = "border_thickness", display_name = "边框粗细", type_id = "float", section = "外观", order = 15, default = 1.0, min = 0.0, max = 8.0, step = 0.5},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(16, 10, 16, 10)},
        }),
    })

    _register(
    {
        type_id = "ProgressBar",
        display_name = "进度条",
        category = "基础",
        order = 5,
        can_have_children = false,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "value", display_name = "当前值", type_id = "float", section = "数值", order = 1, default = 0.5, min = 0, max = 1, step = 0.01},
            {key = "min_value", display_name = "最小值", type_id = "float", section = "数值", order = 2, default = 0, min = -99999, max = 99999, step = 0.1},
            {key = "max_value", display_name = "最大值", type_id = "float", section = "数值", order = 3, default = 1, min = -99999, max = 99999, step = 0.1},
            {key = "show_progress", display_name = "是否显示进度", type_id = "bool", section = "数值", order = 4, default = true},
            {key = "font", display_name = "字体", type_id = "resource", resource_type = "font", section = "文本", order = 5, default = _resource("font/font.otf")},
            {key = "font_size", display_name = "字号", type_id = "int", section = "文本", order = 6, default = 22, min = 8, max = 96, step = 1},
            {key = "background_color", display_name = "底色", type_id = "color", section = "外观", order = 10, default = _color(0.11, 0.13, 0.16, 0.95)},
            {key = "fill_color", display_name = "填充色", type_id = "color", section = "外观", order = 11, default = _color(0.25, 0.58, 0.42, 1.0)},
            {key = "text_color", display_name = "文字颜色", type_id = "color", section = "外观", order = 12, default = _color(1, 1, 1, 1)},
            {key = "border_color", display_name = "边框颜色", type_id = "color", section = "外观", order = 13, default = _color(0.42, 0.47, 0.54, 0.95)},
            {key = "border_thickness", display_name = "边框粗细", type_id = "float", section = "外观", order = 14, default = 1.0, min = 0.0, max = 8.0, step = 0.5},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(4, 4, 4, 4)},
        }),
    })

    _register(
    {
        type_id = "Spacer",
        display_name = "留白",
        category = "布局",
        order = 20,
        can_have_children = false,
        hidden_from_create = true,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0, 0, 0, 0)},
        }),
    })

    _register(
    {
        type_id = "VerticalContainer",
        display_name = "垂直容器",
        category = "布局",
        order = 21,
        can_have_children = true,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0, 0, 0, 0)},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(16, 16, 16, 16)},
            {key = "gap", display_name = "子项间距", type_id = "float", section = "布局", order = 19, default = 12, min = 0, max = 120, step = 1},
            {key = "cross_align", display_name = "交叉轴对齐", type_id = "enum", section = "布局", order = 20, default = "stretch", option_list = {"stretch", "start", "center", "end"}},
        }),
    })

    _register(
    {
        type_id = "HorizontalContainer",
        display_name = "水平容器",
        category = "布局",
        order = 22,
        can_have_children = true,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0, 0, 0, 0)},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(16, 16, 16, 16)},
            {key = "gap", display_name = "子项间距", type_id = "float", section = "布局", order = 19, default = 12, min = 0, max = 120, step = 1},
            {key = "cross_align", display_name = "交叉轴对齐", type_id = "enum", section = "布局", order = 20, default = "stretch", option_list = {"stretch", "start", "center", "end"}},
        }),
    })

    _register(
    {
        type_id = "OverlayContainer",
        display_name = "叠加容器",
        category = "布局",
        order = 23,
        can_have_children = true,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0, 0, 0, 0)},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(0, 0, 0, 0)},
        }),
    })

    _register(
    {
        type_id = "ScrollView",
        display_name = "滚动视图",
        category = "布局",
        order = 24,
        can_have_children = true,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0.06, 0.07, 0.09, 0.82)},
            {key = "border_color", display_name = "边框颜色", type_id = "color", section = "外观", order = 2, default = _color(0.25, 0.29, 0.35, 0.88)},
            {key = "border_thickness", display_name = "边框粗细", type_id = "float", section = "外观", order = 3, default = 1.0, min = 0.0, max = 8.0, step = 0.5},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(12, 12, 12, 12)},
            {key = "scroll_content_height", display_name = "内容高度", type_id = "float", section = "布局", order = 19, default = 720, min = 0, max = 99999, step = 10},
            {key = "scroll_y", display_name = "滚动偏移", type_id = "float", section = "布局", order = 20, default = 0, min = 0, max = 99999, step = 4},
            {key = "wheel_speed", display_name = "滚轮速度", type_id = "float", section = "布局", order = 21, default = 36, min = 1, max = 200, step = 1},
        }),
    })

    _register(
    {
        type_id = "GridContainer",
        display_name = "网格容器",
        category = "布局",
        order = 25,
        can_have_children = true,
        property_list = _append_property_list(_common_rounded_rect_property_list(),
        {
            {key = "background_color", display_name = "背景颜色", type_id = "color", section = "外观", order = 1, default = _color(0, 0, 0, 0)},
            {key = "padding", display_name = "内边距", type_id = "padding", section = "布局", order = 18, default = _padding(12, 12, 12, 12)},
            {key = "gap_x", display_name = "水平间距", type_id = "float", section = "布局", order = 19, default = 12, min = 0, max = 120, step = 1},
            {key = "gap_y", display_name = "垂直间距", type_id = "float", section = "布局", order = 20, default = 12, min = 0, max = 120, step = 1},
            {key = "columns", display_name = "列数", type_id = "int", section = "布局", order = 21, default = 2, min = 1, max = 12, step = 1},
        }),
    })
end

function module.get(type_id)
    _ensure_initialized()
    return definition_pool[_trim(type_id)]
end

function module.register(definition)
    _ensure_initialized()
    return _register(definition)
end

function module.list()
    _ensure_initialized()
    local result = {}
    for index, definition in ipairs(ordered_definition_list) do
        result[index] = _clone_value(definition)
    end
    return result
end

function module.get_property(type_id, key)
    local definition = module.get(type_id)
    if not definition then
        return nil
    end
    return definition.property_pool[_trim(key)]
end

function module.create_widget(type_id, options)
    _ensure_initialized()
    local definition = assert(module.get(type_id), string.format("unknown ui widget type: %s", tostring(type_id)))
    options = options or {}

    local widget =
    {
        id = _trim(options.id) or "",
        name = _trim(options.name) or definition.default_name,
        type = definition.type_id,
        props = {},
        events = {},
        children = {},
    }

    for _, property in ipairs(definition.property_list) do
        widget.props[property.key] = _clone_value(property.default)
    end

    if type(options.props) == "table" then
        for key, value in pairs(options.props) do
            widget.props[key] = _clone_value(value)
        end
    end

    if type(options.events) == "table" then
        for key, value in pairs(options.events) do
            widget.events[key] = _clone_value(value)
        end
    end

    if type(options.children) == "table" then
        for _, child in ipairs(options.children) do
            table.insert(widget.children, _clone_value(child))
        end
    end

    return widget
end

function module.clear()
    definition_pool = {}
    ordered_definition_list = {}
    initialized = false
end

return module

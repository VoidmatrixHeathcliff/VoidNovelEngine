local SettingsManager = require("application.framework.settings_manager")
local RuntimeLayout = require("application.framework.runtime_layout_context")
local UI = require("application.framework.ui")

local module = {}

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

local function _clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function _normalize_positive_number(value, fallback)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        number = fallback or 1
    end
    return math.max(1, number)
end

local function _normalize_vec2(value, default_x, default_y)
    if type(value) == "userdata" then
        return
        {
            x = tonumber(value.x) or default_x or 0,
            y = tonumber(value.y) or default_y or 0,
        }
    end

    if type(value) ~= "table" then
        return {x = default_x or 0, y = default_y or 0}
    end

    return
    {
        x = tonumber(value.x) or tonumber(value[1]) or default_x or 0,
        y = tonumber(value.y) or tonumber(value[2]) or default_y or 0,
    }
end

local function _normalize_color(value, default_r, default_g, default_b, default_a)
    if type(value) == "userdata" then
        return
        {
            r = tonumber(value.x) or default_r or 1,
            g = tonumber(value.y) or default_g or 1,
            b = tonumber(value.z) or default_b or 1,
            a = tonumber(value.w) or default_a or 1,
        }
    end

    if type(value) ~= "table" then
        return
        {
            r = default_r or 1,
            g = default_g or 1,
            b = default_b or 1,
            a = default_a or 1,
        }
    end

    return
    {
        r = tonumber(value.r) or tonumber(value.x) or tonumber(value[1]) or default_r or 1,
        g = tonumber(value.g) or tonumber(value.y) or tonumber(value[2]) or default_g or 1,
        b = tonumber(value.b) or tonumber(value.z) or tonumber(value[3]) or default_b or 1,
        a = tonumber(value.a) or tonumber(value.w) or tonumber(value[4]) or default_a or 1,
    }
end

local function _make_widget(type_id, id, name, props, children, events)
    return
    {
        id = id,
        name = name,
        type = type_id,
        props = props or {},
        children = children or {},
        events = events or {},
    }
end

local function _make_canvas(children)
    local width, height = RuntimeLayout.get_canvas_size()
    return UI.normalize_document(
    {
        version = 1,
        canvas = {width = width, height = height},
        root = _make_widget("Canvas", "root", "根画布",
        {
            anchor_min = {x = 0, y = 0},
            anchor_max = {x = 1, y = 1},
            offset_min = {x = 0, y = 0},
            offset_max = {x = 0, y = 0},
            background_color = {r = 0, g = 0, b = 0, a = 0},
        }, children),
    })
end

function module.is_enabled()
    return SettingsManager.get("presentation_ui_backend_enabled") == true
end

function module.build_dialog_document(config)
    local position = _normalize_vec2(config.position, 900, 200)
    local raw_width = math.floor(_normalize_positive_number(config.width, 420) + 0.5)
    local width = RuntimeLayout.resolve_dialog_width(raw_width)
    local padding_x = math.max(12, RuntimeLayout.round(RuntimeLayout.scale_x(20)))
    local padding_top = math.max(10, RuntimeLayout.round(RuntimeLayout.scale_y(16)))
    local padding_bottom = padding_top
    local gap_y = math.max(6, RuntimeLayout.round(RuntimeLayout.scale_y(8)))
    local role_font_size = RuntimeLayout.scale_font_size(tonumber(config.role_font_size) or 20)
    local dialogue_font_size = RuntimeLayout.scale_font_size(tonumber(config.dialogue_font_size) or 25)
    local role_height = math.max(28, math.floor(role_font_size * 1.8 + 0.5))
    local dialogue_height = math.max(72, math.floor(dialogue_font_size * 4.2 + 0.5))
    local height = padding_top + role_height + gap_y + dialogue_height + padding_bottom
    local x, y = RuntimeLayout.resolve_dialog_position(position.x, position.y)
    local content_width = math.max(1, width - padding_x * 2)
    local content_height = math.max(1, height - padding_top - padding_bottom)

    local panel = _make_widget("Panel", "dialog_panel", "对话框",
    {
        anchor_min = {x = 0, y = 0},
        anchor_max = {x = 0, y = 0},
        offset_min = {x = x, y = y},
        offset_max = {x = x + width, y = y + height},
        padding = {left = padding_x, top = padding_top, right = padding_x, bottom = padding_bottom},
        background_color = _normalize_color(config.background_color, 0, 0, 0, 0.7),
        background_image = config.background_image,
        border_color = {r = 1, g = 1, b = 1, a = 0},
    },
    {
        _make_widget("Text", "role_text", "角色文本",
        {
            anchor_min = {x = 0, y = 0},
            anchor_max = {x = 0, y = 0},
            offset_min = {x = 0, y = 0},
            offset_max = {x = content_width, y = role_height},
            text = tostring(config.role_text or ""),
            font = config.role_font,
            font_size = role_font_size,
            text_color = _normalize_color(config.role_color, 0.95, 0.95, 0.95, 1),
            wrap = false,
        }),
        _make_widget("Text", "dialogue_text", "对话正文",
        {
            anchor_min = {x = 0, y = 0},
            anchor_max = {x = 0, y = 0},
            offset_min = {x = 0, y = role_height + gap_y},
            offset_max = {x = content_width, y = content_height},
            text = tostring(config.dialogue_text or ""),
            font = config.dialogue_font,
            font_size = dialogue_font_size,
            text_color = _normalize_color(config.dialogue_color, 0.75, 0.75, 0.75, 1),
            wrap = true,
        }),
    })

    return _make_canvas({panel})
end

function module.build_subtitle_document(config)
    local bottom_distance = RuntimeLayout.round(RuntimeLayout.scale_y(tonumber(config.bottom_distance) or 40))
    local font_size = RuntimeLayout.scale_font_size(tonumber(config.font_size) or 25)
    local height = math.floor(font_size * 2.2 + 0.5)

    local subtitle_text = _make_widget("Text", "subtitle_text", "字幕文本",
    {
        anchor_min = {x = 0, y = 1},
        anchor_max = {x = 1, y = 1},
        offset_min = {x = 0, y = -bottom_distance - height},
        offset_max = {x = 0, y = -bottom_distance},
        text = tostring(config.text or ""),
        font = config.font,
        font_size = font_size,
        text_color = _normalize_color(config.color, 0.95, 0.95, 0.95, 1),
        wrap = true,
        align_x = "center",
        align_y = "end",
    })

    return _make_canvas({subtitle_text})
end

function module.build_choice_document(config)
    local choice_list = {}
    for _, item in ipairs(config.choice_list or {}) do
        if type(item) == "table" and _trim(item.text) then
            table.insert(choice_list,
            {
                id = _trim(item.id) or string.format("choice_%d", #choice_list + 1),
                text = _trim(item.text),
            })
        end
    end

    local count = #choice_list
    local minimum_width = RuntimeLayout.round(RuntimeLayout.scale_x(tonumber(config.minimum_width) or 400))
    local button_spacing = RuntimeLayout.round(RuntimeLayout.scale_y(tonumber(config.button_spacing) or 20))
    local button_padding = _normalize_vec2(config.button_padding, 100, 12)
    button_padding.x = RuntimeLayout.round(RuntimeLayout.scale_x(button_padding.x))
    button_padding.y = RuntimeLayout.round(RuntimeLayout.scale_y(button_padding.y))
    local font_size = RuntimeLayout.scale_font_size(tonumber(config.font_size) or 25)
    local button_height = math.floor(font_size + button_padding.y * 2 + 8 + 0.5)
    local total_height = count * button_height + math.max(0, count - 1) * button_spacing
    local bottom_distance = RuntimeLayout.round(RuntimeLayout.scale_y(tonumber(config.bottom_distance) or 150))

    local button_list = {}
    for index, item in ipairs(choice_list) do
        button_list[index] = _make_widget("Button", item.id, string.format("选项%d", index),
        {
            preferred_size = {x = minimum_width, y = button_height},
            layout_stretch = false,
            text = item.text,
            font = config.font,
            font_size = font_size,
            text_color = _normalize_color(config.text_color, 1, 1, 1, 0.76),
            hover_color = _normalize_color(config.hover_color, 0.41, 0.64, 0.27, 0.88),
            background_color = _normalize_color(config.background_color, 0, 0, 0, 0.69),
            background_image = config.background_image,
            border_color = _normalize_color(config.border_color, 0.37, 0.37, 0.37, 0.69),
            border_thickness = 1,
            padding = {left = button_padding.x, top = button_padding.y, right = button_padding.x, bottom = button_padding.y},
            action_kind = "close_ui",
            event_name = item.id,
        })
    end

    local container = _make_widget("VerticalContainer", "choice_container", "选项列表",
    {
        anchor_min = {x = 0.5, y = 1},
        anchor_max = {x = 0.5, y = 1},
        offset_min = {x = -minimum_width * 0.5, y = -bottom_distance - total_height},
        offset_max = {x = minimum_width * 0.5, y = -bottom_distance},
        gap = button_spacing,
        padding = {left = 0, top = 0, right = 0, bottom = 0},
        cross_align = "stretch",
        background_color = {r = 0, g = 0, b = 0, a = 0},
    }, button_list)

    return _make_canvas({container})
end

function module.open_dialog_box(scene, config)
    return scene:open_ui(module.build_dialog_document(config),
    {
        instance_id = _trim(config.instance_id),
        on_event = config.on_event,
    })
end

function module.open_subtitle(scene, config)
    return scene:open_ui(module.build_subtitle_document(config),
    {
        instance_id = _trim(config.instance_id),
        on_event = config.on_event,
    })
end

function module.open_choice_button(scene, config)
    return scene:open_ui(module.build_choice_document(config),
    {
        instance_id = _trim(config.instance_id),
        on_event = config.on_event,
    })
end

function module.set_instance_opacity(instance, opacity)
    if not instance or not instance.root or not instance.root.props then
        return false
    end
    instance.root.props.opacity = _clamp(tonumber(opacity) or 1, 0, 1)
    return true
end

function module.set_widget_text(instance, widget_id, text)
    if not instance or not instance.widget_by_id then
        return false
    end
    local widget = instance.widget_by_id[widget_id]
    if not widget or not widget.props then
        return false
    end
    local next_text = tostring(text or "")
    if widget.props.text == next_text then
        return true
    end
    widget.props.text = next_text
    local runtime = instance.runtime
    if runtime and runtime.mark_layout_dirty then
        runtime:mark_layout_dirty()
    end
    return true
end

return module

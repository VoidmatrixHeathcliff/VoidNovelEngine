local json = Engine.JSON

local NativeIO = require("application.framework.native_io")
local UIWidgetRegistry = require("application.framework.ui_widget_registry")

local module = {}

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

local function _normalize_vec2(value, default_x, default_y)
    if type(value) ~= "table" then
        return {x = default_x or 0, y = default_y or 0}
    end
    return
    {
        x = tonumber(value.x) or tonumber(value[1]) or default_x or 0,
        y = tonumber(value.y) or tonumber(value[2]) or default_y or 0,
    }
end

local function _normalize_padding(value)
    if type(value) ~= "table" then
        return {left = 0, top = 0, right = 0, bottom = 0}
    end
    return
    {
        left = tonumber(value.left) or tonumber(value[1]) or 0,
        top = tonumber(value.top) or tonumber(value[2]) or 0,
        right = tonumber(value.right) or tonumber(value[3]) or 0,
        bottom = tonumber(value.bottom) or tonumber(value[4]) or 0,
    }
end

local function _normalize_color(value, default_alpha)
    if type(value) ~= "table" then
        return {r = 1, g = 1, b = 1, a = default_alpha or 1}
    end
    return
    {
        r = tonumber(value.r) or tonumber(value.x) or tonumber(value[1]) or 1,
        g = tonumber(value.g) or tonumber(value.y) or tonumber(value[2]) or 1,
        b = tonumber(value.b) or tonumber(value.z) or tonumber(value[3]) or 1,
        a = tonumber(value.a) or tonumber(value.w) or tonumber(value[4]) or default_alpha or 1,
    }
end

local function _normalize_resource_reference(value)
    if value == nil then
        return nil
    end

    if type(value) == "table" then
        local guid = _trim(value.guid)
        local path_hint = _trim(value.path_hint or value.path or value.relative_path or value.id)
        if not guid and not path_hint then
            return nil
        end
        return
        {
            guid = guid,
            path_hint = path_hint,
        }
    end

    local text = _trim(value)
    if not text then
        return nil
    end

    return
    {
        path_hint = text,
    }
end

local function _normalize_canvas(value)
    local canvas = type(value) == "table" and value or {}
    local mode = _trim(canvas.mode) or "fixed"
    if mode ~= "fixed" and mode ~= "project" and mode ~= "responsive" then
        mode = "fixed"
    end

    local width = math.max(1, math.floor(tonumber(canvas.width) or 1920))
    local height = math.max(1, math.floor(tonumber(canvas.height) or 1080))
    return
    {
        width = width,
        height = height,
        mode = mode,
        design_width = math.max(1, math.floor(tonumber(canvas.design_width) or width)),
        design_height = math.max(1, math.floor(tonumber(canvas.design_height) or height)),
    }
end

local supported_click_action_kind_pool =
{
    none = true,
    close_ui = true,
    open_ui = true,
    quick_save = true,
    quick_load = true,
    return_value = true,
    fast_forward = true,
    auto_advance = true,
    rollback = true,
}

local function _normalize_auto_advance_interval(value)
    local interval = tonumber(value) or 1.0
    if interval < 0.1 then
        interval = 0.1
    end
    if interval > 60 then
        interval = 60
    end
    return interval
end

local function _normalize_event_action_kind(kind, event_type)
    local kind_id = _trim(kind) or "none"
    if event_type == "on_click" and supported_click_action_kind_pool[kind_id] ~= true then
        kind_id = "none"
    end
    return kind_id
end

local function _normalize_event_action(value, event_type)
    if type(value) ~= "table" then
        return
        {
            kind = "none",
            reentry_policy = "repeatable",
        }
    end

    local reentry_policy = _trim(value.reentry_policy) or "repeatable"
    if reentry_policy == "ignore" then
        reentry_policy = "once"
    elseif reentry_policy == "restart" or reentry_policy == "queue" then
        reentry_policy = "repeatable"
    elseif reentry_policy ~= "once" and reentry_policy ~= "repeatable" then
        reentry_policy = "repeatable"
    end

    return
    {
        kind = _normalize_event_action_kind(value.kind, event_type),
        target = _trim(value.target) or "self",
        message = _trim(value.message) or "",
        event_name = _trim(value.event_name) or "",
        ui = _normalize_resource_reference(value.ui),
        flow = _normalize_resource_reference(value.flow),
        entry = _trim(value.entry) or "",
        instance_id = _trim(value.instance_id) or "",
        slot_id = _trim(value.slot_id) or "",
        save_category = _trim(value.save_category) or "manual",
        auto_advance_interval = _normalize_auto_advance_interval(value.auto_advance_interval),
        auto_close_current = value.auto_close_current == true,
        reentry_policy = reentry_policy,
    }
end

local function _normalize_consume_input(value)
    local mode = _trim(value) or "block"
    if mode == "auto" or mode == "always" then
        return "block"
    end
    if mode == "never" then
        return "pass"
    end
    if mode ~= "block" and mode ~= "pass" then
        return "block"
    end
    return mode
end

local function _normalize_image_fit_mode(value)
    local mode = _trim(value)
    if mode == "preserve_aspect" then
        return "preserve_aspect"
    end
    if mode == "fill" then
        return "fill"
    end
    return "preserve_aspect"
end

local legacy_action_prop_pool =
{
    action_kind = true,
    action_target = true,
    action_message = true,
    action_ui = true,
    action_instance_id = true,
    action_slot_id = true,
    action_save_category = true,
    action_auto_advance_interval = true,
    action_auto_close_current = true,
}

local removed_widget_prop_pool =
{
    preserve_aspect = true,
    show_text = true,
    tint = true,
    wrap = true,
}

local removed_widget_type_prop_pool =
{
    SaveSlotGrid =
    {
        category = true,
        page = true,
        per_page = true,
        total_pages = true,
    },
}

local function _normalize_legacy_click_action(props)
    if type(props) ~= "table" then
        return nil
    end

    local kind = _trim(props.action_kind)
    local has_action = kind ~= nil
        or _trim(props.action_target) ~= nil
        or _trim(props.action_message) ~= nil
        or props.action_ui ~= nil
        or _trim(props.action_instance_id) ~= nil
        or _trim(props.action_slot_id) ~= nil
        or _trim(props.action_save_category) ~= nil
        or _trim(props.action_auto_advance_interval) ~= nil
        or props.action_auto_close_current == true
    if not has_action then
        return nil
    end

    return _normalize_event_action(
    {
        kind = kind or "none",
        target = props.action_target,
        message = props.action_message,
        ui = props.action_ui,
        instance_id = props.action_instance_id,
        slot_id = props.action_slot_id,
        save_category = props.action_save_category,
        auto_advance_interval = props.action_auto_advance_interval,
        auto_close_current = props.action_auto_close_current == true,
        reentry_policy = props.reentry_policy,
        event_name = props.event_name,
        flow = props.event_flow,
        entry = props.event_entry,
    }, "on_click")
end

local function _normalize_props(type_id, props)
    local definition = UIWidgetRegistry.get(type_id) or UIWidgetRegistry.get("Panel")
    local normalized = {}

    for _, property in ipairs(definition.property_list or {}) do
        normalized[property.key] = _clone_value(property.default)
    end

    for key, value in pairs(type(props) == "table" and props or {}) do
        if legacy_action_prop_pool[key] then
            goto continue
        end
        if removed_widget_prop_pool[key] then
            goto continue
        end
        if removed_widget_type_prop_pool[type_id] and removed_widget_type_prop_pool[type_id][key] then
            goto continue
        end
        local property = definition.property_pool[key]
        if property then
            if property.type_id == "vec2" then
                normalized[key] = _normalize_vec2(value)
            elseif property.type_id == "padding" then
                normalized[key] = _normalize_padding(value)
            elseif property.type_id == "color" then
                normalized[key] = _normalize_color(value)
            elseif property.type_id == "resource" then
                normalized[key] = _normalize_resource_reference(value)
            elseif key == "consume_input" then
                normalized[key] = _normalize_consume_input(value)
            else
                normalized[key] = _clone_value(value)
            end
        else
            normalized[key] = _clone_value(value)
        end
        ::continue::
    end

    if type_id == "Image" then
        normalized.image_fit_mode = _normalize_image_fit_mode(normalized.image_fit_mode)
    elseif type_id == "ProgressBar" then
        normalized.show_progress = normalized.show_progress ~= false
    end
    if type_id == "Canvas" or type_id == "Text" or type_id == "SaveSlotGrid" then
        normalized.corner_radius = nil
    end

    return normalized
end

local function _normalize_widget(widget, state)
    local raw_type = _trim(type(widget) == "table" and (widget.type or widget.type_id) or nil) or "Panel"
    local definition = UIWidgetRegistry.get(raw_type) or UIWidgetRegistry.get("Panel")
    local type_id = definition and definition.type_id or "Panel"

    state.next_id = (state.next_id or 0) + 1
    local raw_id = _trim(type(widget) == "table" and widget.id or nil)
    local widget_id = raw_id or string.format("widget_%d", state.next_id)
    while state.id_pool[widget_id] do
        state.next_id = state.next_id + 1
        widget_id = string.format("%s_%d", raw_id or "widget", state.next_id)
    end
    state.id_pool[widget_id] = true
    if type(state.id_remap) == "table" and raw_id then
        state.id_remap[raw_id] = widget_id
    end

    local normalized = UIWidgetRegistry.create_widget(type_id,
    {
        id = widget_id,
        name = _trim(type(widget) == "table" and widget.name or nil) or definition.default_name,
        props = _normalize_props(type_id, type(widget) == "table" and widget.props or nil),
        events = {},
        children = {},
    })

    local raw_events = type(widget) == "table" and widget.events or nil
    if type(raw_events) == "table" then
        for event_key, event_value in pairs(raw_events) do
            normalized.events[event_key] = _normalize_event_action(event_value, event_key)
        end
    end
    if normalized.events.on_click == nil then
        local legacy_action = _normalize_legacy_click_action(type(widget) == "table" and widget.props or nil)
        if legacy_action then
            normalized.events.on_click = legacy_action
        end
    end

    local child_list = type(widget) == "table" and widget.children or nil
    if type(child_list) == "table" then
        for _, child in ipairs(child_list) do
            table.insert(normalized.children, _normalize_widget(child, state))
        end
    end

    return normalized
end

local function _normalize_document(raw_document)
    local document = type(raw_document) == "table" and raw_document or {}
    local state = {id_pool = {}, next_id = 0}
    local root = _normalize_widget(document.root, state)

    if root.type ~= "Canvas" then
        root.type = "Canvas"
        root.name = root.name ~= "" and root.name or "根画布"
        root.props = _normalize_props("Canvas", root.props)
    end

    return
    {
        version = tonumber(document.version) or 1,
        canvas = _normalize_canvas(document.canvas),
        root = root,
        exposed_properties = _clone_value(type(document.exposed_properties) == "table" and document.exposed_properties or {}),
        exposed_events = _clone_value(type(document.exposed_events) == "table" and document.exposed_events or {}),
        bindings = _clone_value(type(document.bindings) == "table" and document.bindings or {}),
        named_slots = _clone_value(type(document.named_slots) == "table" and document.named_slots or {}),
        animation_clips = _clone_value(type(document.animation_clips) == "table" and document.animation_clips or {}),
    }
end

local function _read_json_file(path)
    local content, err = NativeIO.read_text(path)
    if not content then
        return nil, err
    end

    local ok, data = json.ParseToLua(content)
    if not ok then
        return nil, "JSON 解析失败"
    end
    return data
end

local function _write_json_file(path, data)
    local content = json.PrintFromLua(data)
    return NativeIO.write_text(path, content)
end

local function _walk_widget(widget, parent, visitor)
    if not widget or type(visitor) ~= "function" then
        return false
    end

    if visitor(widget, parent) == true then
        return true
    end

    for _, child in ipairs(widget.children or {}) do
        if _walk_widget(child, widget, visitor) then
            return true
        end
    end
    return false
end

local function _find_widget(document_or_widget, widget_id)
    local root = document_or_widget and document_or_widget.root or document_or_widget
    local result_widget, result_parent, result_index = nil, nil, nil
    if not root then
        return nil, nil, nil
    end

    _walk_widget(root, nil, function(widget, parent)
        if widget.id == widget_id then
            result_widget = widget
            result_parent = parent
            if parent then
                for index, child in ipairs(parent.children or {}) do
                    if child == widget then
                        result_index = index
                        break
                    end
                end
            end
            return true
        end
        return false
    end)

    return result_widget, result_parent, result_index
end

local function _contains_widget_id(widget, target_id)
    if not widget then
        return false
    end
    if widget.id == target_id then
        return true
    end
    for _, child in ipairs(widget.children or {}) do
        if _contains_widget_id(child, target_id) then
            return true
        end
    end
    return false
end

function module.clone(value)
    return _clone_value(value)
end

function module.new_document()
    local root = UIWidgetRegistry.create_widget("Canvas",
    {
        id = "root",
        name = "根画布",
        props =
        {
            anchor_min = {x = 0, y = 0},
            anchor_max = {x = 1, y = 1},
            offset_min = {x = 0, y = 0},
            offset_max = {x = 0, y = 0},
        },
    })

    return module.normalize_document(
    {
        version = 1,
        canvas = {width = 1920, height = 1080, mode = "project", design_width = 1920, design_height = 1080},
        root = root,
        exposed_properties = {},
        exposed_events = {},
        bindings = {},
        named_slots = {},
        animation_clips = {},
    })
end

function module.normalize_document(document)
    return _normalize_document(document)
end

function module.load(path)
    local raw_document, err = _read_json_file(path)
    if not raw_document then
        return nil, err
    end
    return module.normalize_document(raw_document)
end

function module.save(path, document)
    return _write_json_file(path, module.normalize_document(document))
end

function module.walk_widgets(document_or_widget, visitor)
    local root = document_or_widget and document_or_widget.root or document_or_widget
    return _walk_widget(root, nil, visitor)
end

function module.find_widget(document_or_widget, widget_id)
    return _find_widget(document_or_widget, widget_id)
end

function module.insert_widget(document, parent_id, widget, index)
    local normalized = module.normalize_document(document)
    local parent = _find_widget(normalized, parent_id or "root")
    if not parent then
        return nil, "无法定位父组件"
    end
    local raw_type = _trim(type(widget) == "table" and (widget.type or widget.type_id) or nil) or "Panel"
    if raw_type == "Canvas" then
        return nil, "画布只能作为界面根组件"
    end
    local parent_definition = UIWidgetRegistry.get(parent.type)
    if parent_definition and parent_definition.can_have_children == false then
        return nil, "目标父组件不支持子级"
    end

    parent.children = parent.children or {}
    local child_state = {id_pool = {}, next_id = 0, id_remap = {}}
    module.walk_widgets(normalized, function(item)
        child_state.id_pool[item.id] = true
    end)
    local normalized_widget = _normalize_widget(widget, child_state)

    local insert_index = math.max(1, math.min(tonumber(index) or (#parent.children + 1), #parent.children + 1))
    table.insert(parent.children, insert_index, normalized_widget)
    return normalized, normalized_widget
end

function module.remove_widget(document, widget_id)
    if widget_id == "root" then
        return nil, "根组件无法删除"
    end

    local normalized = module.normalize_document(document)
    local widget, parent, index = _find_widget(normalized, widget_id)
    if not widget or not parent or not index then
        return nil, "无法定位组件"
    end

    table.remove(parent.children, index)
    return normalized, widget
end

function module.move_widget(document, widget_id, new_parent_id, index)
    if widget_id == "root" then
        return nil, "根组件无法移动"
    end

    local normalized = module.normalize_document(document)
    local widget, parent, widget_index = _find_widget(normalized, widget_id)
    local new_parent = _find_widget(normalized, new_parent_id or "root")
    if not widget or not parent or not widget_index then
        return nil, "无法定位组件"
    end
    if not new_parent then
        return nil, "无法定位目标父组件"
    end
    local parent_definition = UIWidgetRegistry.get(new_parent.type)
    if parent_definition and parent_definition.can_have_children == false then
        return nil, "目标父组件不支持子级"
    end

    if new_parent.id == widget.id or _contains_widget_id(widget, new_parent.id) then
        return nil, "目标父组件不能是当前组件或其子组件"
    end

    table.remove(parent.children, widget_index)
    new_parent.children = new_parent.children or {}
    local insert_index = math.max(1, math.min(tonumber(index) or (#new_parent.children + 1), #new_parent.children + 1))
    table.insert(new_parent.children, insert_index, widget)
    return normalized, widget
end

return module

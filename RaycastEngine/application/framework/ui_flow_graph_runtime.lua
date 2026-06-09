local FlowRuntimeError = require("application.framework.flow_runtime_error")
local FlowRuntimeGuard = require("application.framework.flow_runtime_guard")
local GlobalContext = require("application.framework.global_context")
local NodeFactory = require("application.framework.node_factory")
local ResourceIndex = require("application.framework.resource_index")

local module = {}
local UIFlowGraphRuntime = {}
UIFlowGraphRuntime.__index = UIFlowGraphRuntime

local EVENT_NODE_TYPE_BY_NAME =
{
    on_open = "ui_on_open",
    on_close = "ui_on_close",
    on_click = "ui_on_click",
    on_hover = "ui_on_hover",
    on_unhover = "ui_on_unhover",
}

local EVENT_LABEL_BY_NAME =
{
    on_open = "界面打开时",
    on_close = "界面关闭后",
    on_click = "组件被点击",
    on_hover = "组件悬停时",
    on_unhover = "组件离开时",
}

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

local function _safe_id(value)
    if value == nil then
        return nil
    end

    if type(value) == "table" or type(value) == "userdata" then
        local ok, result = pcall(function()
            return value:get()
        end)
        if ok then
            return result
        end
    end

    local numeric = tonumber(value)
    return numeric ~= nil and numeric or value
end

local function _save_node_snapshot_list(document)
    local snapshot_list = {}
    for _, node in pairs(document and document._node_pool or {}) do
        if node and node.on_save then
            table.insert(snapshot_list, node:on_save())
        end
    end
    table.sort(snapshot_list, function(left, right)
        return (left.id or 0) < (right.id or 0)
    end)
    return snapshot_list
end

local function _save_link_snapshot_list(document)
    local snapshot_list = {}
    for _, link in pairs(document and document._link_pool or {}) do
        if link and link.input and link.output then
            table.insert(snapshot_list,
            {
                id = _safe_id(link.id),
                input_pin_id = _safe_id(link.input._id),
                output_pin_id = _safe_id(link.output._id),
            })
        end
    end
    table.sort(snapshot_list, function(left, right)
        return (left.id or 0) < (right.id or 0)
    end)
    return snapshot_list
end

local function _read_local_string_pin(node, key)
    local pin = node and node.find_input_pin and node:find_input_pin(key) or nil
    if not pin or type(pin.get_val) ~= "function" then
        return ""
    end

    return _trim(pin:get_val()) or ""
end

local function _read_local_resource_pin(node, key, asset_type)
    local pin = node and node.find_input_pin and node:find_input_pin(key) or nil
    if not pin or type(pin.get_reference) ~= "function" then
        return nil
    end
    return ResourceIndex.make_reference(asset_type, pin:get_reference())
end

local function _matches_text_filter(filter_text, ...)
    if filter_text == "" then
        return true
    end

    for index = 1, select("#", ...) do
        if filter_text == tostring(select(index, ...) or "") then
            return true
        end
    end
    return false
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

local function _display_text(value)
    local text = _trim(tostring(value or ""))
    return text or "空"
end

local function _describe_event_context(event_context)
    local payload = type(event_context and event_context.payload) == "table" and event_context.payload or {}
    local event_type = tostring(event_context and event_context.event_type or payload.event_type or "")
    local event_label = EVENT_LABEL_BY_NAME[event_type] or event_type
    local widget_name = _display_text(payload.widget_name)
    local widget_id = _display_text(payload.widget_id)
    return string.format(
        "事件=%s；界面=%s；实例名=%s；组件名称=%s；内部组件ID=%s；界面事件=%s",
        _display_text(event_label),
        _display_text(payload.source_path or payload.source_guid),
        _display_text(payload.instance_id),
        widget_name,
        widget_id,
        _display_text(payload.event_name))
end

local function _add_reason(reason_pool, reason)
    reason = _trim(reason) or "未知原因"
    reason_pool[reason] = (reason_pool[reason] or 0) + 1
end

local function _format_reason_summary(reason_pool)
    local reason_list = {}
    for reason, count in pairs(reason_pool or {}) do
        reason_list[#reason_list + 1] = count > 1 and string.format("%s x%d", reason, count) or reason
    end
    table.sort(reason_list)
    return #reason_list > 0 and table.concat(reason_list, "；") or "没有入口节点通过过滤条件"
end

local function _match_entry_node(document, node, event_context)
    if not node or not event_context then
        return false, "事件上下文无效"
    end

    local target_type = EVENT_NODE_TYPE_BY_NAME[event_context.event_type]
    if not target_type or node._type_id ~= target_type then
        return false, "入口节点类型不匹配"
    end

    local payload = type(event_context.payload) == "table" and event_context.payload or {}
    local ui_filter = _read_local_resource_pin(node, "ui_filter", "ui")
    if not _matches_ui_reference(ui_filter, payload) then
        return false, "界面文件不匹配"
    end

    local widget_filter = _read_local_string_pin(node, "widget_id_filter")
    if not _matches_text_filter(widget_filter, payload.widget_id, payload.widget_name) then
        return false, string.format("组件过滤不匹配：当前组件名称=%s，内部组件ID=%s", _display_text(payload.widget_name), _display_text(payload.widget_id))
    end

    return true
end

local function _entry_specificity_score(node)
    local score = 0
    if _read_local_resource_pin(node, "ui_filter", "ui") then
        score = score + 1
    end
    if _read_local_string_pin(node, "widget_id_filter") ~= "" then
        score = score + 4
    end
    return score
end

local function _find_entry_node_id(document, event_context)
    local event_type = tostring(event_context and event_context.event_type or "")
    local target_type = EVENT_NODE_TYPE_BY_NAME[event_type]
    if not target_type then
        return nil, string.format("不支持的界面事件类型：%s", _display_text(event_type))
    end

    local matched_node_id = nil
    local matched_score = -1
    local target_count = 0
    local reason_pool = {}
    for node_id, node in pairs(document and document._node_pool or {}) do
        if node and node._type_id == target_type then
            target_count = target_count + 1
        end

        local matched, reason = _match_entry_node(document, node, event_context)
        if matched then
            local numeric_node_id = tonumber(node_id) or node_id
            local specificity_score = _entry_specificity_score(node)
            if matched_node_id == nil
                or specificity_score > matched_score
                or (specificity_score == matched_score and numeric_node_id < matched_node_id)
            then
                matched_node_id = numeric_node_id
                matched_score = specificity_score
            end
        elseif node and node._type_id == target_type then
            _add_reason(reason_pool, reason)
        end
    end

    if matched_node_id then
        return matched_node_id
    end

    local event_label = EVENT_LABEL_BY_NAME[event_type] or event_type
    if target_count == 0 then
        return nil, string.format("事件流程里没有“%s”入口节点", _display_text(event_label))
    end
    return nil, string.format(
        "已找到 %d 个“%s”入口节点，但过滤条件不匹配：%s",
        target_count,
        _display_text(event_label),
        _format_reason_summary(reason_pool))
end

local function _attach_runtime_node(runtime_blueprint, node, flow_document)
    runtime_blueprint._node_pool[node._id:get()] = node
    node._flow_document = flow_document

    for _, pin in ipairs(node._input_pin_list or {}) do
        runtime_blueprint._pin_pool[pin._id:get()] = pin
    end
    for _, pin in ipairs(node._output_pin_list or {}) do
        runtime_blueprint._pin_pool[pin._id:get()] = pin
    end
end

local function _restore_runtime_links(runtime_blueprint, link_snapshot_list)
    for _, link_data in ipairs(link_snapshot_list or {}) do
        local input_pin = runtime_blueprint._pin_pool[link_data.input_pin_id]
        local output_pin = runtime_blueprint._pin_pool[link_data.output_pin_id]
        if input_pin and output_pin then
            input_pin._linked_pin_id = output_pin._id
            output_pin._linked_pin_id = input_pin._id
            runtime_blueprint._link_pool[link_data.id] =
            {
                id = link_data.id,
                input = input_pin,
                output = output_pin,
            }
        end
    end
end

local function _restore_runtime_binding(previous_state, switched_document)
    if switched_document then
        return
    end

    GlobalContext.current_flow_document = previous_state.current_flow_document
    GlobalContext.current_blueprint = previous_state.current_blueprint
    GlobalContext.debug_flow_document = previous_state.debug_flow_document
    GlobalContext.debug_blueprint = previous_state.debug_blueprint
end

local function _with_runtime_binding(runtime, callback)
    local previous_runtime_document = GlobalContext.get_runtime_flow_document
        and GlobalContext.get_runtime_flow_document()
        or GlobalContext.current_flow_document
    local previous_save_target = GlobalContext.get_runtime_save_anchor_document
        and GlobalContext.get_runtime_save_anchor_document()
        or nil
    local save_target = previous_save_target or previous_runtime_document
    local save_target_token = nil
    local previous_state =
    {
        current_flow_document = GlobalContext.current_flow_document,
        current_blueprint = GlobalContext.current_blueprint,
        debug_flow_document = GlobalContext.debug_flow_document,
        debug_blueprint = GlobalContext.debug_blueprint,
    }

    if save_target and save_target ~= runtime._runtime_blueprint and GlobalContext.push_runtime_save_target then
        save_target_token = GlobalContext.push_runtime_save_target(save_target)
    end

    GlobalContext.set_runtime_flow_document(runtime._runtime_blueprint, {transient = true})
    local ok, call_ok, call_payload = pcall(callback)
    local active_document = GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil
    local switched_document = active_document ~= runtime._runtime_blueprint
    if save_target_token and GlobalContext.pop_runtime_save_target then
        GlobalContext.pop_runtime_save_target(save_target_token)
    end
    _restore_runtime_binding(previous_state, switched_document)

    if not ok then
        return false, call_ok, switched_document
    end

    return call_ok, call_payload, switched_document
end

local function _report_runtime_error(runtime, payload)
    local prepared = FlowRuntimeError.prepare(payload,
    {
        blueprint = runtime._runtime_blueprint,
        flow_document = runtime._source_document,
    })

    if runtime._on_error then
        runtime._on_error(prepared)
        return
    end

    FlowRuntimeError.report(prepared,
    {
        blueprint = runtime._runtime_blueprint,
        flow_document = runtime._source_document,
    })
end

function UIFlowGraphRuntime:ctor(document, scene_context, options)
    options = options or {}
    self._source_document = document
    self._scene_context = scene_context
    self._event_context = _clone_value(type(options.event_context) == "table" and options.event_context or {})
    self._runtime_blueprint = nil
    self._next_node = nil
    self._next_node_entry_pin = nil
    self._current_node = nil
    self._ended = false
    self._on_error = type(options.on_error) == "function" and options.on_error or nil
    return self
end

function UIFlowGraphRuntime:_schedule_next(next_node, entry_pin)
    self._next_node = next_node
    self._next_node_entry_pin = entry_pin
    if not next_node then
        self._current_node = nil
        self._ended = true
    end
end

function UIFlowGraphRuntime:_build_runtime_blueprint()
    local runtime_blueprint =
    {
        kind = "graph",
        _id = self._source_document._id,
        _path = self._source_document._path,
        _resource_guid = self._source_document._resource_guid,
        _resource_id = self._source_document._resource_id,
        _display_name = self._source_document._display_name,
        _max_uid = tonumber(self._source_document._max_uid) or 0,
        _node_pool = {},
        _pin_pool = {},
        _link_pool = {},
        _disable_editor_binding = true,
    }

    function runtime_blueprint:gen_next_uid()
        self._max_uid = self._max_uid + 1
        return self._max_uid
    end

    function runtime_blueprint:execute_node(next_node, entry_pin)
        return self._runtime_owner:_schedule_next(next_node, entry_pin)
    end

    function runtime_blueprint:runtime_find_node(id)
        return self._node_pool[id]
    end

    function runtime_blueprint:runtime_find_pin(id)
        return self._pin_pool[id]
    end

    function runtime_blueprint:get_ui_event_context()
        return self._runtime_owner._event_context
    end

    runtime_blueprint._runtime_owner = self
    self._runtime_blueprint = runtime_blueprint

    for _, node_data in ipairs(_save_node_snapshot_list(self._source_document)) do
        local node = NodeFactory.create(
        {
            blueprint = runtime_blueprint,
            type_id = node_data.type_id,
            data = node_data,
        })
        _attach_runtime_node(runtime_blueprint, node, self._source_document)
    end

    _restore_runtime_links(runtime_blueprint, _save_link_snapshot_list(self._source_document))
end

function UIFlowGraphRuntime:start(entry_node_id)
    if self._ended then
        return false, "界面行为图运行时已结束"
    end

    self:_build_runtime_blueprint()
    local entry_node = self._runtime_blueprint._node_pool[entry_node_id]
    if not entry_node then
        self._ended = true
        return false, "无法定位界面事件入口节点"
    end

    self:_schedule_next(entry_node, nil)
    self._ended = false
    return true
end

function UIFlowGraphRuntime:update(delta)
    if self._ended then
        return
    end

    while self._next_node do
        self._current_node = self._next_node
        self._next_node = nil
        self._current_node._runtime_wait_interaction_state = nil

        local executed, payload, switched_document = _with_runtime_binding(self, function()
            return FlowRuntimeGuard.call_node_captured(
                self._current_node,
                "on_execute",
                self._scene_context,
                self._next_node_entry_pin)
        end)
        if not executed then
            self._ended = true
            _report_runtime_error(self, payload)
            return
        end

        if switched_document then
            self._ended = true
            return
        end

        if self._ended then
            return
        end
    end

    if not self._current_node then
        self._ended = true
        return
    end

    local executed, payload, switched_document = _with_runtime_binding(self, function()
        return FlowRuntimeGuard.call_node_captured(
            self._current_node,
            "on_execute_update",
            self._scene_context,
            delta)
    end)
    if not executed then
        self._ended = true
        _report_runtime_error(self, payload)
        return
    end

    if switched_document then
        self._ended = true
        return
    end

end

function UIFlowGraphRuntime:destroy()
    self._ended = true
    self._next_node = nil
    self._next_node_entry_pin = nil
    self._current_node = nil
    self._runtime_blueprint = nil
end

module.find_entry_node_id = function(document, event_context)
    return _find_entry_node_id(document, event_context)
end

module.describe_event_context = function(event_context)
    return _describe_event_context(event_context)
end

module.new = function(document, scene_context, options)
    return setmetatable({}, UIFlowGraphRuntime):ctor(document, scene_context, options)
end

return module

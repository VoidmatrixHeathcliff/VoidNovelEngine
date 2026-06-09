local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "close_ui",
    pin_schema_version = 4,
    icon_id = "layout-3-line",
    color = imgui.ImVec4(imgui.ImColor(107, 187, 133, 255).value),
    name = "关闭界面",
    comment = "关闭当前或指定界面",
    category = "界面逻辑",
    category_order = 4,
    order = 0.3,
    menu_visible = true,
    script =
    {
        aliases = {"hide_ui"},
        summary = "关闭当前场景中的界面实例。",
        detail = "普通用法只需要选择界面资源；在界面事件流程中，未指定界面时会关闭触发事件的当前界面。",
        signature =
        {
            {name = "ui", pin = "ui", doc = "要关闭的界面资源。"},
        },
        default_flow_output = "out",
    },
    migrate_pins = function(data)
        for _, pin in ipairs(data and data.input_pin_list or {}) do
            if pin.key == "ui" then
                pin.name = "指定界面"
            end
        end
        return data
    end,
}

local function _get_current_event_instance_id(node)
    local blueprint = node and node._blueprint or nil
    local context = nil
    if blueprint and type(blueprint.get_ui_event_context) == "function" then
        context = blueprint:get_ui_event_context()
    end
    context = type(context) == "table" and context or {}
    local payload = type(context.payload) == "table" and context.payload or {}
    return tostring(payload.instance_id or "")
end

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "ui", type_id = "ui", name = "指定界面"})
    builder:add_output({key = "out", type_id = "flow"})

    node.on_execute = function(self, scene)
        local close_target = nil
        local pin = NodeRuntimeHelper.get_input_pin(self, "ui")
        local has_reference = pin and pin.get_reference and pin:get_reference() ~= nil
        if has_reference then
            close_target = NodeRuntimeHelper.check_resource(self, "ui", "ui")
        end
        if close_target == nil then
            local current_instance_id = _get_current_event_instance_id(self)
            if current_instance_id ~= "" then
                close_target = current_instance_id
            end
        end

        if close_target ~= nil then
            scene:close_ui(close_target)
        end
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

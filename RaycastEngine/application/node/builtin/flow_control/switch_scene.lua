local Common = require("application.framework.builtin_node_common")
local FlowManager = require("application.framework.flow_manager")

local imgui = Common.imgui
local GlobalContext = Common.GlobalContext
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "switch_scene",
    icon_id = "arrow-right-up-box-fill",
    color = imgui.ImVec4(imgui.ImColor(175, 23, 30, 255).value),
    name = "跳转到场景",
    comment = "切换到指定的流程或内置场景",
    category = "流程控制",
    category_order = 3,
    order = 4,
    menu_visible = true,
    script =
    {
        aliases = {"scene"},
        summary = "切换到另一个流程场景并开始执行。",
        detail = "target 支持 flow_locator 语义，可在文本剧本中直接补全到 `.flow` 或 `.vns` 资源。切场前会清理上一场景的运行时状态。",
        signature =
        {
            {name = "target", pin = "target", positional = true, required = true, aliases = {"scene_id"}, adapter = "flow_locator", doc = "目标流程资源 ID 或可解析的 flow 定位字符串。"},
        },
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "string", name = "目标场景", options = {width_input = 165, resource_locator_asset_type = "flow", resource_locator_manual = false}})

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "target"
    node._input_pin_map["target"] = node._input_pin_list[2]

    node.on_execute = function(self, scene)
        local scene_id = NodeRuntimeHelper.check_string(self, "target", {allow_empty = false})
        local previous_document = GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document()
            or GlobalContext.current_flow_document
        local document = FlowManager.get_document(scene_id, "flow_runtime")
        local global_ui_state = nil

        if not document then
            NodeRuntimeHelper.abort(self, "无法找到指定 ID 的场景")
        end

        local previous_scene = previous_document
            and previous_document.get_runtime_scene_context
            and previous_document:get_runtime_scene_context()
            or nil
        if previous_scene and previous_scene.collect_global_ui_state then
            global_ui_state = previous_scene:collect_global_ui_state()
        end

        if previous_document and previous_document ~= document and GlobalContext.reset_flow_runtime_state then
            GlobalContext.reset_flow_runtime_state(previous_document)
            if previous_document._is_temporary_runtime_document == true and previous_document.dispose then
                previous_document:dispose()
            end
        end

        if GlobalContext.set_runtime_flow_document then
            GlobalContext.set_runtime_flow_document(document)
        else
            GlobalContext.current_flow_document = document
            GlobalContext.current_blueprint = document.kind == "graph" and document or nil
        end

        document:execute()
        local next_scene = document.get_runtime_scene_context and document:get_runtime_scene_context() or nil
        if next_scene and next_scene.apply_global_ui_state and type(global_ui_state) == "table" then
            next_scene:apply_global_ui_state(global_ui_state)
        end
    end

    return node
end)

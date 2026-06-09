local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "switch_to_game_scene",
    icon_id = "game-2-fill",
    color = imgui.ImVec4(imgui.ImColor(233, 82, 149, 255).value),
    name = "切换到自定义场景",
    comment = "将当前场景变更为脚本扩展的场景",
    category = "流程控制",
    category_order = 3,
    order = 5,
    menu_visible = true,
}

return Common.make_definition(NodeDef, function(ctx)
    local blueprint = ctx.blueprint
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "string", name = "场景文件", options = {width_input = 135}})
    builder:add_output({type_id = "flow"})

    node.on_execute = function(self, scene)
        local scene_file = NodeRuntimeHelper.check_string(self, 2, {allow_empty = false})
        local success, GameScene = pcall(require, scene_file)
        if not success then
            NodeRuntimeHelper.abort(self, string.format("无法加载指定路径的场景文件\n%s", tostring(GameScene)))
        end

        local game_scene = GameScene.new()
        local prev_scene_context = blueprint._scene_context
        game_scene._execute_next_node = function()
            blueprint._scene_context:on_exit()
            blueprint._scene_context = prev_scene_context
            NodeRuntimeHelper.execute_next_node(self)
        end

        blueprint._scene_context = game_scene
        blueprint._scene_context:on_enter()
    end

    return node
end)

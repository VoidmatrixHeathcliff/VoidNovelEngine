local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper
local PinMigration = require("application.node.builtin.save._pin_migration")
local SaveManager = require("application.framework.save_manager")

local function _read_location_input(node)
    return
    {
        category = "manual",
        page = math.max(1, NodeRuntimeHelper.check_int(node, "page")),
        index = math.max(1, NodeRuntimeHelper.check_int(node, "index")),
    }
end

local NodeDef =
{
    type_id = "delete_slot",
    pin_schema_version = 4,
    icon_id = "delete-bin-5-fill",
    color = imgui.ImVec4(imgui.ImColor(84, 132, 219, 255).value),
    name = "删除存档",
    category = "存档系统",
    category_order = 6,
    order = 5,
    menu_visible = true,
    script =
    {
        summary = "删除指定的存档位置。",
        detail = "删除成功后从“成功”继续；若删除失败，则从“失败”输出继续，并可读取错误信息。",
        signature =
        {
            {name = "page", pin = "page", doc = "手动存档页码。默认第 1 页。"},
            {name = "index", pin = "index", doc = "本页位置。默认第 1 位。"},
        },
        default_flow_output = "success",
    },
    migrate_pins = function(data)
        return PinMigration.rename(data,
        {
            input =
            {
                page = "页码",
                index = "本页位置",
            },
            output =
            {
                error_message = "错误信息",
            },
        })
    end,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "page", type_id = "int", name = "页码", default = 1})
    builder:add_input({key = "index", type_id = "int", name = "本页位置", default = 1})
    builder:add_output({key = "success", type_id = "flow"})
    builder:add_output({key = "failed", type_id = "flow", name = "失败"})
    builder:add_output({key = "error_message", type_id = "string", name = "错误信息", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local ok, err = SaveManager.delete_slot(_read_location_input(self))
        if ok ~= true then
            NodeRuntimeHelper.set_output(self, "error_message", tostring(err or "未知错误"))
            NodeRuntimeHelper.execute_next_node(self, "failed")
            return
        end

        NodeRuntimeHelper.set_output(self, "error_message", "")
        NodeRuntimeHelper.execute_next_node(self, "success")
    end

    return node
end)

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
    type_id = "load_slot",
    pin_schema_version = 4,
    icon_id = "inbox-unarchive-fill",
    color = imgui.ImVec4(imgui.ImColor(84, 132, 219, 255).value),
    name = "读取存档",
    comment = nil,
    category = "存档系统",
    category_order = 6,
    order = 3,
    menu_visible = true,
    script =
    {
        summary = "读取指定存档位置并立即切换到目标运行时。",
        detail = "读取成功后，当前流程上下文会被新的存档运行时替换，因此不会再从当前节点继续向后执行；只有失败时才会走“失败”输出。",
        signature =
        {
            {name = "page", pin = "page", doc = "手动存档页码。默认第 1 页。"},
            {name = "index", pin = "index", doc = "本页位置。默认第 1 位。"},
        },
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
    builder:add_output({key = "failed", type_id = "flow", name = "失败"})
    builder:add_output({key = "error_message", type_id = "string", name = "错误信息", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local result = SaveManager.load_location(_read_location_input(self))
        if not result or result.ok ~= true then
            NodeRuntimeHelper.set_output(self, "error_message", tostring(result and result.error or "未知错误"))
            NodeRuntimeHelper.execute_next_node(self, "failed")
            return
        end
    end

    return node
end)

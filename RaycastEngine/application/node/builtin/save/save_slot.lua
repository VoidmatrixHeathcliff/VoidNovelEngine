local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper
local PinMigration = require("application.node.builtin.save._pin_migration")
local SaveManager = require("application.framework.save_manager")
local SnapshotCoordinator = require("application.framework.snapshot_coordinator")

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
    type_id = "save_slot",
    pin_schema_version = 4,
    icon_id = "inbox-archive-fill",
    color = imgui.ImVec4(imgui.ImColor(84, 132, 219, 255).value),
    name = "保存存档",
    comment = nil,
    category = "存档系统",
    category_order = 6,
    order = 1,
    menu_visible = true,
    script =
    {
        summary = "执行到这里时尝试保存到指定存档位置。",
        detail = "这是流程里的保存命令，常用于自动保存或明确的保存步骤。普通界面按钮请优先在界面设计视图里设置“保存存档”。",
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
                actual_slot_id = "保存位置",
                error_message = "错误信息",
            },
            output_legacy =
            {
                ["实际槽位ID"] = "保存位置",
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
    builder:add_output({key = "actual_slot_id", type_id = "string", name = "保存位置", options = {can_edit = false}})
    builder:add_output({key = "error_message", type_id = "string", name = "错误信息", options = {can_edit = false}})

    node.on_execute = function(self, scene)
        local actual_slot_id, err = SnapshotCoordinator.request_save(_read_location_input(self),
        {
            source = "flow_node",
            category = "manual",
        })
        if actual_slot_id == false then
            NodeRuntimeHelper.set_output(self, "actual_slot_id", "")
            NodeRuntimeHelper.set_output(self, "error_message", tostring(err or "未知错误"))
            NodeRuntimeHelper.execute_next_node(self, "failed")
            return
        end

        NodeRuntimeHelper.set_output(self, "actual_slot_id", SaveManager.get_slot_display_name(actual_slot_id))
        NodeRuntimeHelper.set_output(self, "error_message", "")
        NodeRuntimeHelper.execute_next_node(self, "success")
    end

    node.can_save_now = function(self, scene, runtime)
        return true
    end

    node.collect_runtime_save_state = function(self, scene, runtime)
        return
        {
            resume_mode = "continue",
            output_ref = "success",
        }
    end

    return node
end)

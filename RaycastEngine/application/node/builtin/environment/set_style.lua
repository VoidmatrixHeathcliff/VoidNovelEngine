local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper
local LogManager = Common.LogManager

local ResourceIndex = require("application.framework.resource_index")
local StyleManager = require("application.framework.style_manager")

local function _describe_style_reference(style_reference)
    local display_path = ResourceIndex.get_display_path("style", style_reference)
    if display_path ~= "" then
        return display_path
    end
    if type(style_reference) == "table" then
        return style_reference.path_hint or style_reference.guid or "未知样式"
    end
    return tostring(style_reference or "未知样式")
end

local NodeDef =
{
    type_id = "set_style",
    icon_id = "palette-line",
    color = imgui.ImVec4(imgui.ImColor(131, 79, 172, 255).value),
    name = "设置当前样式",
    comment = nil,
    category = "环境变量",
    category_order = 5,
    order = 3,
    menu_visible = true,
    script =
    {
        summary = "将指定样式资源设为当前激活样式。",
        detail = "样式会影响对话框、分支按钮、字幕等运行时界面表现，通常用于章节切换或特殊演出场景。",
        signature =
        {
            {name = "style", pin = "style", positional = true, required = true, doc = "要激活的样式资源。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "style", type_id = "style", name = "样式"})
    builder:add_output({key = "out", type_id = "flow"})

    node.on_execute = function(self, scene)
        local style_reference = NodeRuntimeHelper.check_resource(self, "style", "style")
        local ok, err = StyleManager.set_active_style(style_reference)
        if not ok then
            NodeRuntimeHelper.abort(self, string.format("无法设置当前样式：%s", tostring(err or "未知错误")), "style_runtime_error")
            return
        end
        LogManager.log(string.format("运行时样式已激活：%s", _describe_style_reference(style_reference)), "info")
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

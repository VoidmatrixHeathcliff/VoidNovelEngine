--[[
自定义节点模板说明：
1. 当前文件名以下划线开头，启动扫描时会被自动忽略，可安全作为模板长期保留。
2. 使用时请复制一份并重命名为非下划线开头的 .lua 文件。
3. 请务必修改 type_id，且保证在当前工程中唯一。
4. 节点负责“逻辑”和“执行”，引脚负责“类型”和“数据约束”。
5. 运行时读取输入值时，优先使用 NodeRuntimeHelper.check_* API，而不是直接调用 get_val()。
]]

local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local ColorHelper = Common.ColorHelper
local NodeRuntimeHelper = Common.NodeRuntimeHelper

return Common.make_definition(
{
    type_id = "your_custom_node",
    title = "你的自定义节点",
    icon_id = "puzzle-fill",
    color = ColorHelper.ValueTypeColorPool.string,
    category = "其他",
    category_order = 99,
    order = 999,
    comment = "请复制模板后修改 type_id、标题、分类和执行逻辑",
    menu_visible = true,
    keywords = {"模板", "custom", "example"},
}, function(ctx)
    -- ctx.blueprint: 当前蓝图对象
    -- ctx.data: 反序列化加载时的原始节点数据，新建节点时为 nil
    -- ctx.definition: 当前节点定义表
    -- ctx.registry: NodeRegistry
    -- ctx.helpers: NodeRuntimeHelper
    -- ctx:create_base_node({...}): 创建节点基础对象
    -- ctx.builder: NodeBuilder，在 create_base_node 之后可用

    local node = ctx:create_base_node()
    local builder = ctx.builder

    -- 新节点请为每个引脚声明稳定 key。
    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({
        key = "input_text",
        type_id = "string",
        name = "输入文本",
        options = {width_input = 120},
        default = "自定义节点模板",
    })
    builder:add_output({key = "out", type_id = "flow", name = "完成"})
    builder:add_output({key = "output_text", type_id = "string", name = "输出文本", options = {width_input = 120}})

    -- 运行逻辑入口统一使用 on_execute / on_execute_update；
    -- 引擎仍兼容旧的 on_exetute / on_exetute_update。
    node.on_execute = function(self, scene, entry_pin)
        local input_text = NodeRuntimeHelper.check_string(self, "input_text")
        NodeRuntimeHelper.set_output(self, "output_text", string.format("节点收到：%s", tostring(input_text)))
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    node.on_execute_update = function(self, scene, delta)
        -- 如果节点存在异步等待、Tween、Timer、交互推进等逻辑，可在这里处理。
        -- 普通同步节点通常不需要实现该函数。
    end

    node.query_menu_id = function(self)
        -- 如果需要右键菜单，可返回唯一 popup id；否则可直接省略。
        return string.format("custom_node_menu_%d", self._id:get())
    end

    node.on_show_menu = function(self)
        imgui.Text("这里可以放自定义节点的右键菜单内容")
        imgui.TextDisabled("如无需要菜单，可删除 query_menu_id / on_show_menu")
    end

    return node
end)

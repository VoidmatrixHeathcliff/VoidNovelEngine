--[[
自定义场景模板说明：
1. 当前文件名以下划线开头，不会被普通场景入口直接使用，可安全作为模板长期保留。
2. 使用时请复制一份并重命名为非下划线开头的 .lua 文件，例如 custom_battle.lua。
3. 在“切换到自定义场景”节点里，场景文件请填写 require 路径，例如 application.scene.custom_battle。
4. 当前流程链路会 require 场景模块，调用 YourScene.new() 创建实例，再调用 on_enter()。
5. 流程运行期间会每帧调用 on_update(delta) / on_render()；如需回到后续流程，请调用 self:_finish_scene()。
6. 如需使用 add_object、open_ui、运行时输入、存档对象等 Scene 基类能力，请保留 on_update / on_render / on_destroy 里的父类调用。
]]

local rl = Engine.Raylib

local Class = require("application.framework.class")
local Scene = require("application.framework.scene")

local CustomSceneTemplate = Class.define("CustomSceneTemplate", Scene)

function CustomSceneTemplate:ctor()
    Class.call_super(CustomSceneTemplate, self, "ctor")
    self._elapsed = 0
    self._finished = false
end

function CustomSceneTemplate:on_enter()
    self._elapsed = 0
    self._finished = false

    -- 场景进入时初始化资源、对象或界面。
    -- 示例：self:open_ui("ui/你的界面")
end

function CustomSceneTemplate:on_exit()
    -- 流程切回后续节点时会调用 on_exit，但不一定立刻调用 on_destroy。
    -- 需要确定释放的临时资源请放在这里处理。
end

function CustomSceneTemplate:on_update(delta)
    Class.call_super(CustomSceneTemplate, self, "on_update", delta)

    if self._finished then
        return
    end

    self._elapsed = self._elapsed + delta

    -- 示例：玩家确认后结束自定义场景并继续执行下一个流程节点。
    if self:is_runtime_submit_pressed() or self:is_runtime_pointer_pressed() then
        self:_finish_scene()
        return
    end
end

function CustomSceneTemplate:on_render()
    -- 先绘制自定义场景内容，再交给基类绘制 add_object / open_ui 管理的对象和界面。
    rl.DrawText("自定义场景模板", 64, 64, 32, rl.Color(255, 255, 255, 255))
    rl.DrawText("按确认键或点击鼠标继续流程", 64, 108, 22, rl.Color(180, 180, 180, 255))

    Class.call_super(CustomSceneTemplate, self, "on_render")
end

function CustomSceneTemplate:on_destroy()
    -- 调试停止、流程重置或 SceneManager 关闭时会调用 destroy。
    Class.call_super(CustomSceneTemplate, self, "on_destroy")
end

function CustomSceneTemplate:_finish_scene()
    if self._finished then
        return
    end

    if not self._execute_next_node then
        -- 如果该场景不是由“切换到自定义场景”节点创建，这里不会有后续流程可继续。
        -- 需要作为应用级场景使用时，请在这里改为 SceneManager.switch_to("目标场景")。
        return
    end

    self._finished = true
    self:_execute_next_node()
end

return CustomSceneTemplate

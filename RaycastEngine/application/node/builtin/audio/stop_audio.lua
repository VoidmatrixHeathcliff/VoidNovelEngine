local Common = require("application.framework.builtin_node_common")
local AudioPlaybackManager = require("application.framework.audio_playback_manager")

local imgui = Common.imgui
local LogManager = Common.LogManager
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "stop_audio",
    icon_id = "volume-mute-line",
    color = imgui.ImVec4(imgui.ImColor(255, 111, 91, 255).value),
    name = "停止音频",
    comment = nil,
    category = "音频控制",
    category_order = 2,
    order = 2,
    menu_visible = true,
    script =
    {
        aliases = {"audio_stop", "stop_sound"},
        summary = "停止指定播放令牌对应的音频。",
        detail = "token 一般来自 play_audio 的输出。可选的 fade_time 用于平滑淡出，而不是立刻中断。",
        signature =
        {
            {name = "token", pin = "token", positional = true, required = true, aliases = {"channel"}, doc = "目标音频播放令牌。"},
            {name = "fade_time", pin = "fade_time", aliases = {"duration"}, doc = "停止前的淡出时间。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "int", name = "频道", options = {can_edit = false}})
    builder:add_input({type_id = "float", name = "淡出时间"})
    builder:add_output({type_id = "flow"})

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "token"
    node._input_pin_map["token"] = node._input_pin_list[2]
    node._input_pin_list[3]._key = "fade_time"
    node._input_pin_map["fade_time"] = node._input_pin_list[3]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]

    if not ctx.data then
        node._input_pin_list[2]:set_val(-1)
    end

    node.on_execute = function(self, scene)
        local token = NodeRuntimeHelper.check_int(self, "token")
        local time = NodeRuntimeHelper.check_float(self, "fade_time")
        if token < 0 then
            NodeRuntimeHelper.abort(self, "无效的播放令牌输入")
        end
        if time < 0 then
            time = 0
        end

        if AudioPlaybackManager.stop(token, time) ~= true and LogManager and LogManager.log then
            LogManager.log(string.format("停止音频失败：播放令牌已失效或不存在（token=%s）", tostring(token)), "warning")
        end
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

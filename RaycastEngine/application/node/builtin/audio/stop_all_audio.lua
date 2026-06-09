local Common = require("application.framework.builtin_node_common")
local AudioPlaybackManager = require("application.framework.audio_playback_manager")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "stop_all_audio",
    icon_id = "volume-mute-line",
    color = imgui.ImVec4(imgui.ImColor(255, 111, 91, 255).value),
    name = "停止全部音频",
    comment = nil,
    category = "音频控制",
    category_order = 2,
    order = 3,
    menu_visible = true,
    script =
    {
        aliases = {"audio_stop_all", "stop_all_sound"},
        summary = "停止当前所有正在播放的音频。",
        detail = "适合切场、回收环境音或强制打断全部音频状态。fade_time 会对所有活动音频统一生效。",
        signature =
        {
            {name = "fade_time", pin = "fade_time", positional = true, aliases = {"duration"}, doc = "统一淡出时间。"},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({type_id = "flow"})
    builder:add_input({type_id = "float", name = "淡出时间"})
    builder:add_output({type_id = "flow"})

    node._input_pin_list[1]._key = "in"
    node._input_pin_map["in"] = node._input_pin_list[1]
    node._input_pin_list[2]._key = "fade_time"
    node._input_pin_map["fade_time"] = node._input_pin_list[2]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]

    node.on_execute = function(self, scene)
        local time = NodeRuntimeHelper.check_float(self, "fade_time")
        if time < 0 then
            time = 0
        end
        AudioPlaybackManager.stop_all(time)
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

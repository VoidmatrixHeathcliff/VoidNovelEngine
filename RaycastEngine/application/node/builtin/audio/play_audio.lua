local Common = require("application.framework.builtin_node_common")
local AudioPlaybackManager = require("application.framework.audio_playback_manager")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "play_audio",
    icon_id = "volume-up-line",
    color = imgui.ImVec4(imgui.ImColor(255, 111, 91, 255).value),
    name = "播放音频",
    comment = nil,
    category = "音频控制",
    category_order = 2,
    order = 1,
    menu_visible = true,
    script =
    {
        aliases = {"audio", "sound"},
        summary = "播放一段音频资源，并输出播放令牌。",
        detail = "常用于背景音乐与音效播放。loop_count 可为 -1 表示循环，token 输出可交给 stop_audio 精准停止某一段播放。",
        docs =
        {
            brief = "播放一段音频资源，并输出播放令牌。",
            description = [=[
常用于背景音乐与音效播放。输出的 [pin token] 可交给 [command stop_audio] 精准停止某一段播放。
]=],
            usage =
            {
                '@audio(&audio("audio/bgm/title"))',
                '@audio(&audio("audio/se/click"), loop_count: 0, volume: 0.8)',
            },
            notes =
            {
                {kind = "tip", text = "loop_count 设为 -1 表示无限循环。"},
            },
            see_also =
            {
                {kind = "command", target = "stop_audio"},
                {kind = "command", target = "stop_all_audio"},
            },
            outputs =
            {
                {pin = "token", brief = "音频播放令牌，可用于后续精准停止。"},
            },
        },
        signature =
        {
            {name = "audio", pin = "audio", positional = true, required = true, doc = {brief = "要播放的音频资源。"}},
            {name = "loop_count", pin = "loop_count", aliases = {"loop"}, adapter = "bool_to_loop_count", doc = {brief = "循环次数，-1 表示无限循环；也支持布尔语义的快捷写法。", default = "0"}},
            {name = "volume", pin = "volume", doc = {brief = "播放音量，范围通常为 0 到 1。", default = "1.0", value_hint = "0 ~ 1"}},
            {name = "fade_time", pin = "fade_time", aliases = {"fade_in"}, doc = {brief = "淡入时间。", default = "0"}},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "audio", type_id = "audio"})
    builder:add_input({type_id = "int", name = "循环次数"})
    builder:add_input({type_id = "float", name = "音量"})
    builder:add_input({type_id = "float", name = "淡入时间"})
    builder:add_output({type_id = "flow"})

    node._input_pin_list[3]._key = "loop_count"
    node._input_pin_map["loop_count"] = node._input_pin_list[3]
    node._input_pin_list[4]._key = "volume"
    node._input_pin_map["volume"] = node._input_pin_list[4]
    node._input_pin_list[5]._key = "fade_time"
    node._input_pin_map["fade_time"] = node._input_pin_list[5]
    node._output_pin_list[1]._key = "out"
    node._output_pin_map["out"] = node._output_pin_list[1]
    builder:add_output({type_id = "int", name = "频道", options = {can_edit = false}})

    node._output_pin_list[2]._key = "token"
    node._output_pin_map["token"] = node._output_pin_list[2]

    if not ctx.data then
        node._input_pin_list[4]:set_val(1.0)
    end

    node.on_execute = function(self, scene)
        local audio = NodeRuntimeHelper.check_resource(self, "audio", "audio")
        local loop = NodeRuntimeHelper.check_int(self, "loop_count")
        local time = NodeRuntimeHelper.check_float(self, "fade_time")
        local volume = math.clamp(NodeRuntimeHelper.check_float(self, "volume"), 0, 1)

        if loop < 0 then
            loop = -1
        end
        if time < 0 then
            time = 0
        end

        local token, err = AudioPlaybackManager.play(audio,
        {
            loop_count = loop,
            volume = volume,
            fade_in_seconds = time,
        })

        if not token then
            local suffix = err and ("\n" .. tostring(err)) or ""
            NodeRuntimeHelper.abort(self, "音频播放失败，请检查资源与解码状态" .. suffix)
        end

        NodeRuntimeHelper.set_output(self, "token", token)
        NodeRuntimeHelper.execute_next_node(self, "out")
    end

    return node
end)

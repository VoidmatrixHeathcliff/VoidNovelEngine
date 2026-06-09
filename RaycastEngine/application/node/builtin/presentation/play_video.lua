local Common = require("application.framework.builtin_node_common")

local imgui = Common.imgui
local NodeRuntimeHelper = Common.NodeRuntimeHelper
local VideoDecoder = Common.VideoDecoder
local VideoRendererObject = Common.VideoRendererObject

local NodeDef =
{
    type_id = "play_video",
    pin_schema_version = 3,
    icon_id = "movie-2-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "播放视频",
    comment = "使用全屏效果播放指定的视频资源",
    category = "演出控制",
    category_order = 1,
    order = 16,
    menu_visible = true,
    script =
    {
        aliases = {"video"},
        summary = "播放一个全屏视频资源。",
        detail = "视频播放期间会接管主要画面输出，常用于 OP、过场和章节切换演出。当前脚本接口主要暴露视频资源与音量两个常用参数。",
        signature =
        {
            {name = "video", pin = "video", positional = true, required = true, doc = "要播放的视频资源。"},
            {name = "volume", pin = "volume", doc = "视频音轨音量。"},
            {name = "shader", pin = "shader", doc = "可选视频着色器资源；为空时走样式 shader.video。"},
        },
        default_flow_output = "out",
    },
    migrate_pins = function(node_data, migrate_ctx)
        local input_pin_list = type(node_data) == "table" and node_data.input_pin_list or nil
        local output_pin_list = type(node_data) == "table" and node_data.output_pin_list or nil
        local source_version = migrate_ctx and migrate_ctx.source_pin_schema_version or nil

        if type(input_pin_list) ~= "table" then
            node_data.pin_schema_version = migrate_ctx and migrate_ctx.target_pin_schema_version or 3
            return node_data
        end

        local frame_rate_pin = input_pin_list[3]
        local resolution_pin = input_pin_list[4]
        local volume_pin = input_pin_list[5]
        local is_legacy_layout = source_version == nil
            and type(frame_rate_pin) == "table" and frame_rate_pin.type_id == "int"
            and type(resolution_pin) == "table" and resolution_pin.type_id == "vector2"
            and type(volume_pin) == "table" and volume_pin.type_id == "float"

        if is_legacy_layout then
            node_data.input_pin_list =
            {
                input_pin_list[1],
                input_pin_list[2],
                input_pin_list[5],
            }
            node_data.output_pin_list =
            {
                output_pin_list and output_pin_list[1] or nil,
            }
        end

        node_data.pin_schema_version = migrate_ctx and migrate_ctx.target_pin_schema_version or 3
        return node_data
    end,
}

return Common.make_definition(NodeDef, function(ctx)
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "video", type_id = "video", options = {show_preview = true}})
    builder:add_input({key = "volume", type_id = "float", name = "音量", default = 1.0})
    builder:add_input({key = "shader", type_id = "shader", name = "着色器"})
    builder:add_output({key = "out", type_id = "flow"})

    node.on_execute = function(self, scene)
        local video = NodeRuntimeHelper.check_resource(self, "video", "video")
        local volume = math.clamp(NodeRuntimeHelper.check_float(self, "volume"), 0, 1)
        local shader_pin = self._input_pin_map["shader"]
        local shader_reference = shader_pin and shader_pin.get_reference and shader_pin:get_reference() or nil

        local video_decoder = VideoDecoder.new(video)
        if not video_decoder then
            NodeRuntimeHelper.abort(self, "无法正确创建视频播放会话")
        end

        video_decoder:set_volume(volume)
        video_decoder:play()

        local video_renderer = VideoRendererObject.new(video_decoder, function()
            NodeRuntimeHelper.execute_next_node(self, "out")
        end, function(error_message)
            NodeRuntimeHelper.fail(self, string.format("视频播放失败\n%s", tostring(error_message or "未知错误")))
        end, shader_reference)
        scene:add_object(video_renderer, "bp-video_render", 101)
    end

    return node
end)

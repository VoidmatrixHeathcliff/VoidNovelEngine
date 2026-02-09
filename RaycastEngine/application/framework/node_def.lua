local module = {}

local imgui = Engine.ImGUI

local ColorHelper = require("application.framework.color_helper")

module["comment"] = 
{
    type_id = "comment",
    icon_id = "message-2-fill",
    color = imgui.ImVec4(imgui.ImColor(255, 255, 255, 255).value),
    name = "注释节点",
    comment = nil,
}

module["extend_pins"] = 
{
    type_id = "extend_pins",
    icon_id = "node-tree",
    color = imgui.ImVec4(imgui.ImColor(121, 124, 127, 255).value),
    name = "扩展引脚",
    comment = nil,
}

module["merge_flow"] = 
{
    type_id = "merge_flow",
    icon_id = "node-tree-flip",
    color = imgui.ImVec4(imgui.ImColor(121, 124, 127, 255).value),
    name = "合并流程",
    comment = nil,
}

module["entry"] = 
{
    type_id = "entry",
    icon_id = "arrow-right-up-box-fill",
    color = imgui.ImVec4(imgui.ImColor(175, 23, 30, 255).value),
    name = "流程场景进入",
    comment = "当前流程脚本入口节点",
}

module["branch"] = 
{
    type_id = "branch",
    icon_id = "git-branch-fill",
    color = imgui.ImVec4(imgui.ImColor(218, 144, 97, 255).value),
    name = "分支判断",
    comment = nil,
}

module["loop"] = 
{
    type_id = "loop",
    icon_id = "loop-right-fill",
    color = imgui.ImVec4(imgui.ImColor(218, 144, 97, 255).value),
    name = "循环执行",
    comment = nil,
}

module["switch_scene"] = 
{
    type_id = "switch_scene",
    icon_id = "arrow-right-up-box-fill",
    color = imgui.ImVec4(imgui.ImColor(175, 23, 30, 255).value),
    name = "跳转到场景",
    comment = "切换到指定的流程或内置场景",
}

module["find_object"] = 
{
    type_id = "find_object",
    icon_id = "search-line",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "查找对象",
    comment = nil,
}

module["save_global"] = 
{
    type_id = "save_global",
    icon_id = "inbox-archive-fill",
    color = imgui.ImVec4(imgui.ImColor(131, 79, 172, 255).value),
    name = "存储到全局环境",
    comment = nil,
}

module["load_global"] = 
{
    type_id = "load_global",
    icon_id = "inbox-unarchive-fill",
    color = imgui.ImVec4(imgui.ImColor(131, 79, 172, 255).value),
    name = "从全局环境中加载",
    comment = nil,
}

module["vector2"] = 
{
    type_id = "vector2",
    icon_id = "drag-move-fill",
    color = ColorHelper.ValueTypeColorPool.vector2,
    name = "二维向量",
    comment = nil,
}

module["color"] = 
{
    type_id = "color",
    icon_id = "color-filter-line",
    color = ColorHelper.ValueTypeColorPool.color,
    name = "颜色",
    comment = nil,
}

module["string"] = 
{
    type_id = "string",
    icon_id = "text",
    color = ColorHelper.ValueTypeColorPool.string,
    name = "字符串",
    comment = nil,
}

module["int"] = 
{
    type_id = "int",
    icon_id = "number-8",
    color = ColorHelper.ValueTypeColorPool.int,
    name = "整数",
    comment = nil,
}

module["float"] = 
{
    type_id = "float",
    icon_id = "number-8",
    color = ColorHelper.ValueTypeColorPool.float,
    name = "浮点数",
    comment = nil,
}

module["bool"] = 
{
    type_id = "bool",
    icon_id = "checkbox-line",
    color = ColorHelper.ValueTypeColorPool.bool,
    name = "布尔值",
    comment = nil,
}

module["random_int"] = 
{
    type_id = "random_int",
    icon_id = "dice-3-line",
    color = ColorHelper.ValueTypeColorPool.int,
    name = "随机整数",
    comment = nil,
}

module["assemble_vector2"] = 
{
    type_id = "assemble_vector2",
    icon_id = "organization-chart",
    color = ColorHelper.ValueTypeColorPool.vector2,
    name = "拼装二维向量",
    comment = nil,
}

module["equal"] = 
{
    type_id = "equal",
    icon_id = "equal-fill",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "等于",
    comment = nil,
}

module["less"] = 
{
    type_id = "less",
    icon_id = "arrow-left-s-line",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "小于",
    comment = nil,
}

module["greater"] = 
{
    type_id = "greater",
    icon_id = "arrow-right-s-line",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "大于",
    comment = nil,
}

module["floor"] = 
{
    type_id = "floor",
    icon_id = "skip-down-fill",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "向下取整",
    comment = nil,
}

module["ceil"] = 
{
    type_id = "ceil",
    icon_id = "skip-up-fill",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "向上取整",
    comment = nil,
}

module["round"] = 
{
    type_id = "round",
    icon_id = "formula",
    color = imgui.ImVec4(imgui.ImColor(62, 179, 112, 255).value),
    name = "四舍五入",
    comment = nil,
}

module["font"] = 
{
    type_id = "font",
    icon_id = "font-size",
    color = ColorHelper.AssetTypeColorPool.font,
    name = "字体引用",
    comment = nil,
}

module["audio"] = 
{
    type_id = "audio",
    icon_id = "headphone-fill",
    color = ColorHelper.AssetTypeColorPool.audio,
    name = "音频引用",
    comment = nil,
}

module["video"] = 
{
    type_id = "video",
    icon_id = "movie-2-fill",
    color = ColorHelper.AssetTypeColorPool.video,
    name = "视频引用",
    comment = nil,
}

module["shader"] = 
{
    type_id = "shader",
    icon_id = "paint-brush-fill",
    color = ColorHelper.AssetTypeColorPool.shader,
    name = "着色器引用",
    comment = nil,
}

module["texture"] = 
{
    type_id = "texture",
    icon_id = "image-fill",
    color = ColorHelper.AssetTypeColorPool.texture,
    name = "纹理引用",
    comment = nil,
}

module["print"] = 
{
    type_id = "print",
    icon_id = "terminal-box-fill",
    color = imgui.ImVec4(imgui.ImColor(243, 152, 0, 255).value),
    name = "打印到控制台",
    comment = "仅供调试模式下使用",
}

module["play_audio"] = 
{
    type_id = "play_audio",
    icon_id = "volume-up-line",
    color = imgui.ImVec4(imgui.ImColor(255, 111, 91, 255).value),
    name = "播放音频",
    comment = nil,
}

module["stop_audio"] = 
{
    type_id = "stop_audio",
    icon_id = "volume-mute-line",
    color = imgui.ImVec4(imgui.ImColor(255, 111, 91, 255).value),
    name = "停止音频",
    comment = nil,
}

module["stop_all_audio"] = 
{
    type_id = "stop_all_audio",
    icon_id = "volume-mute-line",
    color = imgui.ImVec4(imgui.ImColor(255, 111, 91, 255).value),
    name = "停止全部音频",
    comment = nil,
}

module["delay"] = 
{
    type_id = "delay",
    icon_id = "time-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "延迟执行",
    comment = nil,
}

module["wait_interaction"] = 
{
    type_id = "wait_interaction",
    icon_id = "click-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "等待互动",
    comment = "鼠标左键或空格键推进流程",
}

module["switch_background"] = 
{
    type_id = "switch_background",
    icon_id = "image-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "切换背景图片",
    comment = nil,
}

module["add_foreground"] = 
{
    type_id = "add_foreground",
    icon_id = "body-scan-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "添加前景图片",
    comment = nil,
}

module["remove_foreground"] = 
{
    type_id = "remove_foreground",
    icon_id = "body-scan-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "删除前景图片",
    comment = nil,
}

module["move_foreground"] = 
{
    type_id = "move_foreground",
    icon_id = "body-scan-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "移动前景图片",
    comment = nil,
}

module["show_letterboxing"] = 
{
    type_id = "show_letterboxing",
    icon_id = "film-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示宽银幕遮幅",
    comment = nil,
}

module["hide_letterboxing"] = 
{
    type_id = "hide_letterboxing",
    icon_id = "film-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "隐藏宽银幕遮幅",
    comment = nil,
}

module["show_subtitle"] = 
{
    type_id = "show_subtitle",
    icon_id = "text-spacing",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示字幕",
    comment = "打字机效果呈现的水平居中文本",
}

module["hide_subtitle"] = 
{
    type_id = "hide_subtitle",
    icon_id = "text-spacing",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "隐藏字幕",
    comment = nil,
}

module["show_dialog_box"] = 
{
    type_id = "show_dialog_box",
    icon_id = "text-block",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示对话框",
    comment = nil,
}

module["hide_dialog_box"] = 
{
    type_id = "hide_dialog_box",
    icon_id = "text-block",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "隐藏对话框",
    comment = nil,
}

module["transition_fade_in"] = 
{
    type_id = "transition_fade_in",
    icon_id = "slideshow-2-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "淡入转场",
    comment = nil,
}

module["transition_fade_out"] = 
{
    type_id = "transition_fade_out",
    icon_id = "slideshow-2-line",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "淡出转场",
    comment = nil,
}

module["show_choice_button"] = 
{
    type_id = "show_choice_button",
    icon_id = "list-check-2",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示分支按钮",
    comment = "玩家点击对应选项后自动收起",
}

module["play_video"] = 
{
    type_id = "play_video",
    icon_id = "movie-2-fill",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "播放视频",
    comment = "使用全屏效果播放制定的视频资产",
}

module["switch_to_game_scene"] = 
{
    type_id = "switch_to_game_scene",
    icon_id = "game-2-fill",
    color = imgui.ImVec4(imgui.ImColor(233, 82, 149, 255).value),
    name = "切换到自定义场景",
    comment = "将当前场景变更为脚本扩展的场景",
}

return module
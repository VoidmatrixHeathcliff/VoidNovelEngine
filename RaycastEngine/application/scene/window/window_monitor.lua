local module = {}

local imgui = Engine.ImGUI

local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")

local meta_def_pool = 
{
    ["GameObject"] = 
    {
        icon_id = "game-fill",
        color = imgui.ImVec4(imgui.ImColor(215, 215, 215, 255).value),
        name = "未知游戏对象"
    },
    ["Tween"] = 
    {
        icon_id = "clapperboard-fill",
        color = imgui.ImVec4(imgui.ImColor(162, 215, 221, 255).value),
        name = "补间动画控制器"
    },
    ["Timer"] = 
    {
        icon_id = "time-fill",
        color = imgui.ImVec4(imgui.ImColor(162, 215, 221, 255).value),
        name = "定时器"
    },
    ["BackgroundObject"] = 
    {
        icon_id = "image-fill",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "背景图片对象"
    },
    ["ForegroundObject"] = 
    {
        icon_id = "body-scan-fill",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "前景图片对象"
    },
    ["Letterboxing"] = 
    {
        icon_id = "film-line",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "宽银幕遮幅对象"
    },
    ["Subtitle"] = 
    {
        icon_id = "text-spacing",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "字幕对象"
    },
    ["DialogBox"] = 
    {
        icon_id = "text-block",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "对话框对象"
    },
    ["TransitionFade"] = 
    {
        icon_id = "slideshow-2-line",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "转场遮罩对象"
    },
    ["ChoiceButton"] = 
    {
        icon_id = "list-check-2",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "分支按钮对象"
    },
    ["VideoRenderer"] = 
    {
        icon_id = "movie-2-fill",
        color = imgui.ImVec4(imgui.ImColor(249, 200, 155, 255).value),
        name = "视频渲染器对象"
    },
}

local color_key <const> = imgui.ImVec4(imgui.ImColor(238, 130, 124, 255).value)
local color_value <const> = imgui.ImVec4(imgui.ImColor(147, 202, 118, 255).value)

module.on_enter = function()

end

module.on_update = function(self, delta)
    imgui.Begin("监控视图")
        if imgui.BeginTabBar("TabBar_Monitor") then
            imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x / 2)
            if imgui.BeginTabItem("场景数据") then
                if not GlobalContext.is_debug_game then
                    imgui.TextDisabled("启动调试以检查场景数据…")
                else
                    imgui.BeginChild("scene_data")
                        local height <const> = imgui.GetTextLineHeight()
                        local size_icon <const> = imgui.ImVec2(height, height)
                        local flags <const> = imgui.TreeNodeFlags.DefaultOpen | imgui.TreeNodeFlags.SpanFullWidth
                        for idx, game_object in ipairs(GlobalContext.current_blueprint._scene_context._go_list) do
                            local open = imgui.TreeNode(string.format("##game_object_%d", idx), flags)
                            imgui.SameLine()
                            local meta_def = meta_def_pool[game_object._metaname] or meta_def_pool["GameObject"]
                            imgui.Image(ResourcesManager.find_icon(meta_def.icon_id), size_icon, nil, nil, meta_def.color, nil)
                            imgui.SameLine()
                            imgui.Text(string.format("[%s] %s (%d)", meta_def.name, game_object._id, game_object._z_idx))
                            if open then
                                imgui.BeginGroup()
                                    for k, _ in pairs(game_object) do
                                        imgui.TextColored(color_key, tostring(k))
                                    end
                                imgui.EndGroup()
                                imgui.SameLine()
                                imgui.BeginGroup()
                                    for _, _ in pairs(game_object) do
                                        imgui.Text("-")
                                    end
                                imgui.EndGroup()
                                imgui.SameLine()
                                imgui.BeginGroup()
                                    for _, v in pairs(game_object) do
                                        imgui.TextColored(color_value, tostring(v))
                                    end
                                imgui.EndGroup()
                                imgui.TreePop()
                            end
                        end
                    imgui.EndChild()
                end
                imgui.EndTabItem()
            end
            imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
            if imgui.BeginTabItem("存档数据") then
                imgui.TextDisabled("当前版本暂不支持存档功能…")
                imgui.EndTabItem()
            end
            imgui.EndTabBar()
        end
    imgui.End()
end

module.on_render = function()

end

return module
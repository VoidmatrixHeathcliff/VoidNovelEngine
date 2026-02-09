local module = {}

local rl = Engine.Raylib
local imgui = Engine.ImGUI

local ImGUIHelper = require("application.framework.imgui_helper")
local SettingsManager = require("application.framework.settings_manager")

local window_size = {x = imgui.Int(0), y = imgui.Int(0)}

local idx_filter_mode = 1
local filter_mode_list = 
{
    {name = "临近采样", val = rl.TextureFilter.POINT},
    {name = "双线性过滤", val = rl.TextureFilter.BILINEAR},
    {name = "三线性过滤", val = rl.TextureFilter.TRILINEAR},
}

local function _show_need_restart_msg()
    imgui.TextDisabled("* 需要重启以应用变更")
end

module.on_enter = function()
    window_size.x.val = SettingsManager.get("width_game_window")
    window_size.y.val = SettingsManager.get("height_game_window")
    local filter_mode = SettingsManager.get("filter_mode")
    for idx, mode in ipairs(filter_mode_list) do
        if mode.val == filter_mode then
            idx_filter_mode = idx
            break
        end
    end
end

module.on_update = function(self, delta)
    imgui.Begin("项目设置")
        imgui.SeparatorText("基础")
        imgui.Columns(2, "基础")

        imgui.Text("画布尺寸")
        ImGUIHelper.HoveredTooltip("定义游戏渲染的基础分辨率，并作为游戏窗口的默认初始大小")
        imgui.NextColumn()
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
        imgui.InputInt2("##窗口尺寸", window_size.x, window_size.y)
        if imgui.IsItemDeactivatedAfterEdit() then
            SettingsManager.set("width_game_window", window_size.x.val)
            SettingsManager.set("height_game_window", window_size.y.val)
        end
        _show_need_restart_msg()
        imgui.NextColumn()

        imgui.Columns(1)

        imgui.SeparatorText("渲染")
        imgui.Columns(2, "渲染")

        imgui.Text("采样模式")
        ImGUIHelper.HoveredTooltip([[控制纹理在缩放等情况下的像素插值策略，影响游戏画面的视觉质量和渲染性能
    * 临近采样：缩放时保持原始像素的锐利边缘和清晰轮廓，适合像素风格游戏，性能开销最低
    * 双线性过滤：放大时产生轻微模糊效果边缘更平滑，缩小时产生轻微锯齿感，性能开销中等
    * 三线性过滤：在缩放时表现更加平滑自然，提供最佳的视觉效果，性能开销较高]])
        imgui.NextColumn()
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x)
        if imgui.BeginCombo("##采样模式", filter_mode_list[idx_filter_mode].name) then
            for idx, mode in ipairs(filter_mode_list) do
                if imgui.Selectable(mode.name, idx_filter_mode == idx) then
                    idx_filter_mode = idx
                    SettingsManager.set("filter_mode", mode.val)
                end
            end
            imgui.EndCombo()
        end
        if imgui.IsItemDeactivatedAfterEdit() then
            SettingsManager.set("width_game_window", window_size.x.val)
            SettingsManager.set("height_game_window", window_size.y.val)
        end
        _show_need_restart_msg()
        imgui.NextColumn()
        
        imgui.Columns(1) 
    imgui.End()
end

return module
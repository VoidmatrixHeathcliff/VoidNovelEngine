local module = {}

local ut = Engine.Util
local sdl = Engine.SDL
local imgui = Engine.ImGUI

local ImGUIHelper = require("application.framework.imgui_helper")
local ColorHelper = require("application.framework.color_helper")
local ResourcesManager = require("application.framework.resources_manager")

local cstr_filter = nil

local asset_list = {}
local asset_list_filtered = {}

local asset_icon_pool = {}
local asset_type_filtered_pool = 
{
    font = imgui.Bool(true),
    audio = imgui.Bool(true),
    shader = imgui.Bool(true),
    texture = imgui.Bool(true),
}

local is_alt_key_pressed = false

local channel_audio = -1

local function _init_asset_list(asset_type, asset_pool)
    for id, asset in pairs(asset_pool) do
        table.insert(asset_list, 
        {
            id = id,
            asset = asset,
            type = asset_type,
        })
    end
end

local function _re_filter_assets()
    asset_list_filtered = {}
    local str_filter <const> = cstr_filter:get()
    for _, asset in ipairs(asset_list) do
        if asset_type_filtered_pool[asset.type].val then
            if string.find(asset.id, str_filter) then
                table.insert(asset_list_filtered, asset)
            end
        end
    end
end

module.on_enter = function()
    asset_icon_pool["font"] = ResourcesManager.find_icon("font-size")
    asset_icon_pool["audio"] = ResourcesManager.find_icon("headphone-fill")
    asset_icon_pool["shader"] = ResourcesManager.find_icon("paint-brush-fill")
    asset_icon_pool["texture"] = ResourcesManager.find_icon("image-fill")

    _init_asset_list("font", ResourcesManager.get_font_pool())
    _init_asset_list("audio", ResourcesManager.get_audio_pool())
    _init_asset_list("shader", ResourcesManager.get_shader_pool())
    _init_asset_list("texture", ResourcesManager.get_texture_pool())

    table.sort(asset_list, function(asset_1, asset_2)
        return asset_1.id < asset_2.id
    end)

    cstr_filter = ut.CString()
end

module.on_update = function(self, delta)
    imgui.Begin("资产视图")
        -- 绘制搜索栏和筛选按钮
        imgui.SetNextItemWidth(imgui.GetContentRegionAvail().x - 32)
        imgui.InputText("##filter", cstr_filter)
        imgui.SameLine()
        if imgui.ImageButton("filter", ResourcesManager.find_icon("filter-2-line"), imgui.ImVec2(18, 18), nil, nil, nil, nil) then
            imgui.OpenPopup("popup_filter_type")
        end
        ImGUIHelper.HoveredTooltip("筛选资源类型")

        -- 绘制列表内容
        local target_list = asset_list
        local is_filtered_type = false
        -- 遍历所有类型筛选判断当前是否正在筛选
        for _, val in pairs(asset_type_filtered_pool) do
            if not val.val then is_filtered_type = true break end
        end
        -- 如果正在筛选类型或者搜索栏中存在内容则更新列表和遍历目标
        if is_filtered_type or not cstr_filter:empty() then
            _re_filter_assets()
            target_list = asset_list_filtered
        end
        imgui.BeginChild("asset_list")
            local size_icon = imgui.ImVec2(imgui.GetTextLineHeight(), imgui.GetTextLineHeight())
            for idx, asset in ipairs(target_list) do
                local pos = imgui.GetCursorPos()
                imgui.Selectable("##"..idx, false, imgui.SelectableFlags.SpanAllColumns)
                if imgui.BeginDragDropSource() then
                    imgui.SetDragDropPayload("asset", asset)
                    imgui.SetTooltip("拖拽以创建资源节点或为对应类型引脚赋值")
                    imgui.EndDragDropSource()
                end
                if imgui.IsItemHovered() then
                    if imgui.IsKeyPressed(imgui.ImGuiKey.LeftAlt) then
                        is_alt_key_pressed = true
                    end
                    if imgui.IsKeyReleased(imgui.ImGuiKey.LeftAlt) then
                        is_alt_key_pressed = false
                    end
                    if asset.type == "texture" then
                        imgui.BeginTooltip()
                            if is_alt_key_pressed then
                                imgui.BeginChild("texture_preview", imgui.ImVec2(240, 120))
                                    local texture = ResourcesManager.find_sdl_texture(asset.id)
                                    local texture_info = sdl.QueryTexture(texture)
                                    local pos_begin = imgui.GetCursorPos()
                                    local size_content = imgui.GetContentRegionAvail()
                                    local scale = math.min(size_content.x / texture_info.w, size_content.y / texture_info.h)
                                    local size_image = imgui.ImVec2(texture_info.w * scale, texture_info.h * scale)
                                    imgui.SetCursorPos(imgui.ImVec2(pos_begin.x + (size_content.x - size_image.x) / 2, pos_begin.y + (size_content.y - size_image.y) / 2))
                                    imgui.Image(texture, size_image, nil, nil, nil, nil)
                                imgui.EndChild()
                            else
                                imgui.TextDisabled("按住“左Alt”以预览纹理")
                            end
                        imgui.EndTooltip()
                    elseif asset.type == "audio" then
                        if imgui.IsKeyPressed(imgui.ImGuiKey.LeftAlt, false) then
                            if channel_audio >= 0 then channel_audio = -1 end
                            channel_audio = sdl.PlayChannel(-1, asset.asset, 0)
                        end
                        imgui.BeginTooltip()
                            imgui.TextDisabled("按住“左Alt”以预览试听音频")
                        imgui.EndTooltip()
                    end
                end
                imgui.SetCursorPos(pos)
                imgui.Image(asset_icon_pool[asset.type], size_icon, nil, nil, ColorHelper.AssetTypeColorPool[asset.type], nil)
                imgui.SameLine()
                imgui.Text(asset.id)
            end
        imgui.EndChild()

        -- 绘制类型筛选菜单
        if imgui.BeginPopup("popup_filter_type") then
            imgui.Checkbox("字体", asset_type_filtered_pool.font)
            imgui.Checkbox("音频", asset_type_filtered_pool.audio)
            imgui.Checkbox("纹理", asset_type_filtered_pool.texture)
            imgui.Checkbox("着色器", asset_type_filtered_pool.shader)
            imgui.EndPopup()
        end

    imgui.End()

    -- 当左Alt键抬起时停止播放试听音频
    if channel_audio >= 0 and imgui.IsKeyReleased(imgui.ImGuiKey.LeftAlt) then
        sdl.HaltChannel(channel_audio)
        channel_audio = -1
    end
end

return module
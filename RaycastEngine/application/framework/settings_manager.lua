local module = {}

local rl = Engine.Raylib
local json = Engine.JSON

local LogManager = nil

local file_path = "project.vne"

local data = 
{
    -- 采样模式
    filter_mode = rl.TextureFilter.TRILINEAR,
    -- 画布宽度
    width_game_window = 1920,
    -- 画布高度
    height_game_window = 1080,
    -- 默认全屏
    default_fullscreen = false,
    -- 入口流程
    entry_flow = "",
    -- 项目引擎版本
    project_version = "0.1.0-dev.2",
    -- 是否在调试窗口中显示帧率
    is_show_debug_fps = true,
    -- 编辑器缩放比例
    editor_zoom_ratio = 1.0,
    -- 图标路径
    icon_path = "application/resources/icon.png",
    -- 游戏窗口标题
    title = "Void Novel Engine Game",
    -- 单文件模式
    single_file = true,
    -- 开发者
    developer = "",
    -- 文件描述
    file_description = "",
    -- 发布版本
    release_version = "",
    -- 是否运行在发布模式下
    release_mode = false,
}

module.copy = function()
    local copy_data = {}
    for k, v in pairs(data) do
        copy_data[k] = v
    end
    return copy_data
end

module.set_logger = function(log_mgr)
    LogManager = log_mgr
end

module.load = function()
    local file = io.open(file_path, "r")
    if not file then
        LogManager.log("无法打开项目配置文件，将使用默认设置生成", "warning")
        module.save()
        return
    end
    local result, file_data = json.ParseToLua(file:read("*a"))
    file:close()
    if not file then
        LogManager.log("无法解析项目配置文件，将使用默认属性生成", "error")
        module.save()
        return
    end
    data = file_data
end

module.save = function(dst, target_data)
    local file = io.open(dst or file_path, "w")
    if not dst and not file then
        LogManager.log("保存项目配置失败：无法打开文件", "error")
        return
    end
    local str_json = json.PrintFromLua(dst and target_data or data)
    file:write(str_json) file:flush() file:close()
    if not dst then LogManager.log("成功保存项目配置", "success") end
end

module.get = function(key)
    return data[key]
end

module.set = function(key, val)
    data[key] = val
    module.save()
end

return module
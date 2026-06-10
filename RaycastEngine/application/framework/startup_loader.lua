local rl = Engine.Raylib
local sdl = Engine.SDL
local imgui = Engine.ImGUI

local DefinitionLoader = require("application.framework.definition_loader")
local FlowManager = require("application.framework.flow_manager")
local GlobalContext = require("application.framework.global_context")
local ImGUIHelper = require("application.framework.imgui_helper")
local LogManager = require("application.framework.log_manager")
local NativeIO = require("application.framework.native_io")
local ResourceIndex = require("application.framework.resource_index")
local ResourcesManager = require("application.framework.resources_manager")
local ResourceTaskRunner = require("application.framework.resource_task_runner")
local ScreenManager = require("application.framework.screen_manager")
local SettingsManager = require("application.framework.settings_manager")
local TextWrapper = require("application.framework.text_wrapper")
local UIWorkspaceManager = require("application.framework.ui_workspace_manager")
local VideoImporter = require("application.framework.video_importer")

local module = {}

local StartupLoader = {}
StartupLoader.__index = StartupLoader
local save_manager_module = false
local startup_spinner_path <const> = "application/icon/loader-5-line.png"
local startup_spinner_rotation_speed <const> = math.pi * 2 * 1.6

local function _get_save_manager()
    if save_manager_module == false then
        save_manager_module = require("application.framework.save_manager")
    end
    return save_manager_module
end

local function _needs_video_transcode(meta, status)
    if not meta then
        return false
    end
    return VideoImporter.should_schedule_transcode(meta.guid, {status = status})
end

local function _cleanup_orphan_video_cache()
    local result, err = VideoImporter.cleanup_orphan_cache()
    if not result then
        LogManager.log(string.format("清理孤立视频缓存失败：%s", err or "未知错误"), "warning")
        return nil, err
    end
    if (result.removed_count or 0) > 0 then
        LogManager.log(string.format("已清理 %d 个孤立视频缓存目录", result.removed_count), "info")
    end
    return result
end

local function _load_spinner_texture(is_release_mode)
    local buffer, err = NativeIO.read_bytes(startup_spinner_path)
    if not buffer then
        LogManager.log(string.format("启动加载图标读取失败：%s\n%s", startup_spinner_path, err or "未知错误"), "warning")
        return nil
    end

    if is_release_mode then
        local image = rl.LoadImageFromMemory(string.lower(rl.GetFileExtension(startup_spinner_path)), buffer)
        NativeIO.dispose_buffer(buffer)
        if not image or (rl.IsImageValid and not rl.IsImageValid(image)) then
            LogManager.log(string.format("启动加载图标解析失败：%s", startup_spinner_path), "warning")
            return nil
        end
        local texture = rl.LoadTextureFromImage(image)
        rl.UnloadImage(image)
        if not texture or (rl.IsTextureValid and not rl.IsTextureValid(texture)) then
            LogManager.log(string.format("启动加载图标创建失败：%s", startup_spinner_path), "warning")
            return nil
        end
        if rl.SetTextureFilter then
            rl.SetTextureFilter(texture, rl.TextureFilter.BILINEAR)
        end
        return texture
    end

    local texture = sdl.LoadTextureFromMemory(GlobalContext.renderer, buffer)
    NativeIO.dispose_buffer(buffer)
    if not texture then
        LogManager.log(string.format("启动加载图标创建失败：%s", startup_spinner_path), "warning")
        return nil
    end
    if sdl.SetTextureScaleMode then
        sdl.SetTextureScaleMode(texture, sdl.ScaleMode.BEST)
    end
    return texture
end

local function _destroy_spinner_texture(texture, is_release_mode)
    if not texture then
        return
    end

    if is_release_mode then
        if rl.UnloadTexture then
            pcall(rl.UnloadTexture, texture)
        end
    elseif sdl.DestroyTexture then
        pcall(sdl.DestroyTexture, texture)
    end
end

local function _rotated_point(center, x, y, cos_angle, sin_angle)
    return imgui.ImVec2(
        center.x + x * cos_angle - y * sin_angle,
        center.y + x * sin_angle + y * cos_angle)
end

local function _draw_imgui_loading_status(texture, status_text)
    local viewport = imgui.GetMainViewport()
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio") or 1.0
    local icon_size = 28 * editor_zoom_ratio
    local half_size = icon_size * 0.5
    local margin = 30 * editor_zoom_ratio
    local gap = 10 * editor_zoom_ratio
    local center = imgui.ImVec2(
        viewport.Pos.x + margin + half_size,
        viewport.Pos.y + viewport.Size.y - margin - half_size)
    local draw_list = imgui.GetWindowDrawList()
    local text_x = viewport.Pos.x + margin

    if texture then
        local angle = rl.GetTime() * startup_spinner_rotation_speed
        local cos_angle = math.cos(angle)
        local sin_angle = math.sin(angle)

        draw_list:AddImageQuad(
            texture,
            _rotated_point(center, -half_size, -half_size, cos_angle, sin_angle),
            _rotated_point(center, half_size, -half_size, cos_angle, sin_angle),
            _rotated_point(center, half_size, half_size, cos_angle, sin_angle),
            _rotated_point(center, -half_size, half_size, cos_angle, sin_angle),
            nil,
            nil,
            nil,
            nil,
            imgui.ImColor(255, 255, 255, 255):to_u32())
        text_x = center.x + half_size + gap
    end

    if type(status_text) == "string" and status_text ~= "" then
        local text_height = imgui.GetTextLineHeight()
        local max_text_width = math.max(60, viewport.Pos.x + viewport.Size.x - margin - text_x)
        local display_text = ImGUIHelper.EllipsisTail(status_text, max_text_width)
        draw_list:AddText(
            imgui.ImVec2(text_x, center.y - text_height * 0.5),
            imgui.ImColor(220, 220, 220, 255):to_u32(),
            display_text)
    end
end

local function _dispose_status_text_wrapper(self)
    if self._status_text_wrapper and self._status_text_wrapper.dispose then
        self._status_text_wrapper:dispose()
    end
    self._status_text_wrapper = nil
    self._status_text_cache = nil
    self._status_text_wrap_width = nil
    self._status_text_font_size = nil
end

local function _get_status_text_wrapper(self, status_text, wrap_width, font_size)
    if not GlobalContext.font_wrapper_sdl then
        return nil
    end

    wrap_width = math.max(1, math.floor(tonumber(wrap_width) or 1))
    font_size = math.max(1, math.floor(tonumber(font_size) or 1))
    if self._status_text_wrapper
        and self._status_text_cache == status_text
        and self._status_text_wrap_width == wrap_width
        and self._status_text_font_size == font_size then
        return self._status_text_wrapper
    end

    _dispose_status_text_wrapper(self)
    self._status_text_wrapper = TextWrapper.new(
        GlobalContext.font_wrapper_sdl,
        status_text,
        sdl.Color(220, 220, 220, 255),
        wrap_width,
        font_size)
    self._status_text_cache = status_text
    self._status_text_wrap_width = wrap_width
    self._status_text_font_size = font_size
    return self._status_text_wrapper
end

local function _draw_raylib_loading_status(self, texture, status_text)
    if type(status_text) ~= "string" or status_text == "" then
        return
    end

    local width, height = ScreenManager.get_size()
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio") or 1.0
    local icon_size = 28 * editor_zoom_ratio
    local half_size = icon_size * 0.5
    local margin = 30 * editor_zoom_ratio
    local gap = 10 * editor_zoom_ratio
    local center_x = margin + half_size
    local center_y = height - margin - half_size
    local text_x = margin

    if not texture then
        center_x = margin
    else
        local angle_degrees = rl.GetTime() * startup_spinner_rotation_speed * 180 / math.pi
        rl.DrawTexturePro(
            texture,
            rl.Rectangle(0, 0, texture.width, texture.height),
            rl.Rectangle(center_x, center_y, icon_size, icon_size),
            rl.Vector2(half_size, half_size),
            angle_degrees,
            rl.Color(255, 255, 255, 255))
        text_x = center_x + half_size + gap
    end

    local wrap_width = math.max(1, width - text_x - margin)
    local font_size = math.max(16, math.floor(20 * editor_zoom_ratio + 0.5))
    local wrapper = _get_status_text_wrapper(self, status_text, wrap_width, font_size)
    if wrapper and wrapper.texture then
        local text_y = center_y - (wrapper.h or font_size) * 0.5
        rl.DrawTextureV(wrapper.texture, rl.Vector2(text_x, text_y), rl.Color(255, 255, 255, 255))
    else
        rl.DrawText(status_text, math.floor(text_x), math.floor(center_y - font_size * 0.5), font_size, rl.Color(220, 220, 220, 255))
    end
end

local function _get_startup_status_text(runner)
    if runner and type(runner.get_compact_status_text) == "function" then
        local ok, text = pcall(runner.get_compact_status_text, runner)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
    end

    local stage_text = runner and runner.stage_name ~= "" and runner.stage_name or "准备中"
    local label_text = runner and runner.current_label ~= "" and runner.current_label or "正在准备资源任务..."
    local total_stage_count = runner and tonumber(runner.total_stage_count) or 0
    if total_stage_count > 0 then
        local stage_index = runner.is_finished and total_stage_count or math.max(1, math.min(runner._stage_index or 1, total_stage_count))
        return string.format("(%d/%d) %s - %s", stage_index, total_stage_count, stage_text, label_text)
    end
    return string.format("%s - %s", stage_text, label_text)
end

module.create = function(config)
    config = config or {}
    local shared = {target_scene_id = config.target_scene_id}
    local is_release_mode = SettingsManager.get("release_mode")

    local function _capture_startup_snapshot()
        local indexed_count_by_type = {}
        local indexed_total_count = 0
        for _, asset_type in ipairs(
        {
            "flow",
            "style",
            "ui",
            "texture",
            "audio",
            "video",
            "font",
            "shader",
        }) do
            local count = #ResourceIndex.list_by_type(asset_type)
            indexed_count_by_type[asset_type] = count
            indexed_total_count = indexed_total_count + count
        end

        return
        {
            indexed_count_by_type = indexed_count_by_type,
            indexed_total_count = indexed_total_count,
            resource_stats = ResourcesManager.get_stats(),
            flow_stats = FlowManager.get_stats and FlowManager.get_stats() or nil,
        }
    end

    local runner = ResourceTaskRunner.new(
    {
        is_modal = false,
        frame_budget_ms = 6,
        present_before_start_frames = 8,
        present_before_start_seconds = 0.20,
        shared = shared,
        stages =
        {
            {
                name = "加载节点与引脚定义",
                tasks =
                {
                    {
                        label = "扫描并注册 Node / Pin 定义",
                        run = function()
                            DefinitionLoader.load()
                        end
                    }
                }
            },
            {
                name = "扫描资源目录",
                tasks =
                {
                    {
                        label = "建立资源索引并校验 .meta 文件",
                        run = function()
                            ResourceIndex.scan()
                            GlobalContext.resource_index_revision = GlobalContext.resource_index_revision + 1
                        end
                    }
                }
            },
            {
                name = "同步项目资源配置",
                tasks =
                {
                    {
                        label = "解析入口流程与窗口图标资源引用",
                        run = function()
                            SettingsManager.resolve_resource_fields()
                        end
                    }
                }
            },
            {
                name = "清理孤立视频缓存",
                tasks =
                {
                    {
                        label = "移除未被当前资源索引引用的视频缓存目录",
                        run = function()
                            _cleanup_orphan_video_cache()
                        end
                    }
                }
            },
            {
                name = "初始化存档系统",
                tasks =
                {
                    {
                        label = "解析存档目录并准备运行时存档结构",
                        run = function()
                            _get_save_manager().init()
                        end
                    }
                }
            },
            {
                name = "校验视频导入状态",
                build_tasks = function()
                    if SettingsManager.get("release_mode") then
                        return {}
                    end

                    local tasks = {}
                    for _, meta in ipairs(ResourceIndex.list_by_type("video")) do
                        table.insert(tasks,
                        {
                            label = string.format("校验视频资源：%s", meta.relative_path),
                            run = function()
                                local status, err = VideoImporter.refresh_guid(meta.guid,
                                {
                                    allow_transcode = false,
                                })
                                if not status then
                                    LogManager.log(string.format("视频资源导入校验失败：%s\n%s", meta.relative_path, err or "未知错误"), "warning")
                                end
                            end
                        })
                    end
                    return tasks
                end
            },
            {
                name = "转码不兼容视频",
                build_tasks = function()
                    if SettingsManager.get("release_mode") then
                        return {}
                    end

                    local tasks = {}
                    for _, meta in ipairs(ResourceIndex.list_by_type("video")) do
                        local status = VideoImporter.get_status(meta.guid)
                        if _needs_video_transcode(meta, status) then
                            local task = VideoImporter.create_transcode_task(meta.guid,
                            {
                                on_error = function(task_meta, err)
                                    LogManager.log(string.format("视频资源自动转码失败：%s\n%s", task_meta.relative_path, err or "未知错误"), "warning")
                                end
                            })
                            if task then
                                table.insert(tasks, task)
                            end
                        end
                    end
                    return tasks
                end
            },
            {
                name = "记录资源基线统计",
                tasks =
                {
                    {
                        label = "汇总当前资源索引与驻留状态",
                        run = function()
                            shared.startup_snapshot = _capture_startup_snapshot()
                        end
                    }
                }
            },
            {
                name = "加载编辑器图标",
                build_tasks = function()
                    if is_release_mode then
                        return {}
                    end

                    return
                    {
                        {
                            label = "加载编辑器界面图标资源",
                            run = function()
                                ResourcesManager.reload_editor_icons()
                            end
                        }
                    }
                end
            },
            {
                name = "加载流程脚本文档",
                build_tasks = function()
                    FlowManager.begin_load()
                    local tasks = {}
                    for _, meta in ipairs(ResourceIndex.list_by_type("flow")) do
                        table.insert(tasks,
                        {
                            label = string.format("登记流程索引：%s", meta.relative_path),
                            run = function()
                                FlowManager.load_blueprint_meta(meta)
                            end
                        })
                    end

                    table.insert(tasks,
                    {
                        label = "整理流程列表与标签页",
                        run = function()
                            FlowManager.finalize_load()
                        end
                    })

                    table.insert(tasks,
                    {
                        label = "恢复流程视图工作区状态",
                        run = function()
                            if not is_release_mode then
                                FlowManager.apply_workspace_state()
                            end
                        end
                    })

                    table.insert(tasks,
                    {
                        label = "按需预加载入口流程文档",
                        run = function()
                            local entry_flow_guid = SettingsManager.get_entry_flow_guid()
                            if SettingsManager.get("release_mode") and entry_flow_guid then
                                FlowManager.get_blueprint(entry_flow_guid, "flow_runtime")
                            end
                        end
                    })

                    table.insert(tasks,
                    {
                        label = "记录流程文档基线",
                        run = function()
                            shared.startup_snapshot = shared.startup_snapshot or {}
                            shared.startup_snapshot.flow_stats = FlowManager.get_stats and FlowManager.get_stats() or {}
                        end
                    })
                    return tasks
                end
            },
            {
                name = "加载界面文档",
                build_tasks = function()
                    if is_release_mode then
                        return {}
                    end

                    UIWorkspaceManager.begin_load()
                    local tasks = {}
                    for _, meta in ipairs(ResourceIndex.list_by_type("ui")) do
                        table.insert(tasks,
                        {
                            label = string.format("登记界面索引：%s", meta.relative_path),
                            run = function()
                                UIWorkspaceManager.load_ui_meta(meta)
                            end
                        })
                    end

                    table.insert(tasks,
                    {
                        label = "整理界面列表与标签页",
                        run = function()
                            UIWorkspaceManager.finalize_load()
                        end
                    })

                    table.insert(tasks,
                    {
                        label = "恢复界面设计工作区状态",
                        run = function()
                            UIWorkspaceManager.apply_workspace_state()
                        end
                    })

                    return tasks
                end
            },
            {
                name = "应用窗口配置",
                tasks =
                {
                    {
                        label = "更新窗口图标",
                        run = function()
                            if GlobalContext.refresh_window_icon then
                                GlobalContext.refresh_window_icon()
                            end
                        end
                    }
                }
            },
        }
    })

    return setmetatable(
    {
        runner = runner,
        _spinner_texture = _load_spinner_texture(is_release_mode),
        _spinner_uses_raylib = is_release_mode,
        _status_text_wrapper = nil,
        _status_text_cache = nil,
        _status_text_wrap_width = nil,
        _status_text_font_size = nil,
    }, StartupLoader)
end

function StartupLoader:update(delta)
    self.runner:update(delta)
end

function StartupLoader:draw_loading_screen()
    self.runner:notify_presented()
    if self._spinner_uses_raylib then
        return
    end

    local viewport = imgui.GetMainViewport()
    local flags = imgui.WindowFlags.NoDocking
        | imgui.WindowFlags.NoTitleBar
        | imgui.WindowFlags.NoCollapse
        | imgui.WindowFlags.NoResize
        | imgui.WindowFlags.NoMove
        | imgui.WindowFlags.NoScrollbar
        | imgui.WindowFlags.NoScrollWithMouse
        | imgui.WindowFlags.NoSavedSettings
        | imgui.WindowFlags.NoInputs

    imgui.SetNextWindowPos(viewport.Pos, imgui.ImGuiCond.Always)
    imgui.SetNextWindowSize(viewport.Size, imgui.ImGuiCond.Always)
    imgui.SetNextWindowViewport(viewport.ID)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVar(imgui.StyleVar.WindowRounding, 0)
    imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.ImGuiCol.WindowBg, imgui.ImColor(0, 0, 0, 255).value)
    imgui.Begin("##startup_loading_screen", nil, flags)
    imgui.PopStyleColor()
    imgui.PopStyleVar(3)
    _draw_imgui_loading_status(self._spinner_texture, _get_startup_status_text(self.runner))
    imgui.End()
end

function StartupLoader:render_loading_screen()
    if self._spinner_uses_raylib then
        _draw_raylib_loading_status(self, self._spinner_texture, _get_startup_status_text(self.runner))
    end
end

function StartupLoader:destroy()
    _destroy_spinner_texture(self._spinner_texture, self._spinner_uses_raylib)
    self._spinner_texture = nil
    _dispose_status_text_wrapper(self)
end

function StartupLoader:is_finished()
    return self.runner.is_finished
end

function StartupLoader:get_error_message()
    return self.runner.error_message
end

return module

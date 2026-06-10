local rl = Engine.Raylib
local imgui = Engine.ImGUI

local Class = require("application.framework.class")
local EditorThemeManager = require("application.framework.editor_theme_manager")
local ImGUIHelper = require("application.framework.imgui_helper")
local SettingsManager = require("application.framework.settings_manager")

local module = {}

module.TaskState =
{
    PENDING = "__resource_task_runner_pending__",
}

local ResourceTaskRunner = Class.define("ResourceTaskRunner")

local function _normalize_tasks(tasks)
    if type(tasks) ~= "table" then
        return {}
    end

    local result = {}
    for _, task in ipairs(tasks) do
        if type(task) == "function" then
            table.insert(result, {label = "", run = task})
        elseif type(task) == "table" and type(task.run) == "function" then
            table.insert(result, task)
        end
    end
    return result
end

local function _refresh_progress(self)
    if self.is_finished then
        self.progress_ratio = 1
        return
    end

    if self.total_stage_count <= 0 then
        self.progress_ratio = 0
        return
    end

    local stage_ratio = 0
    if self._stage_total_count > 0 then
        stage_ratio = (self._stage_finished_count + (self._current_task_progress_ratio or 0)) / self._stage_total_count
    end

    self.progress_ratio = math.min(1, (self.finished_stage_count + stage_ratio) / self.total_stage_count)
end

local function _is_start_gate_active(self)
    if self.is_finished or self._startup_present_gate_released then
        return false
    end

    if self._present_before_start_frames <= 0 and self._present_before_start_seconds <= 0 then
        self._startup_present_gate_released = true
        return false
    end

    if self._presented_frame_count < self._present_before_start_frames then
        return true
    end

    if self._present_before_start_seconds > 0 then
        if not self._first_present_time then
            return true
        end
        if rl.GetTime() - self._first_present_time < self._present_before_start_seconds then
            return true
        end
    end

    self._startup_present_gate_released = true
    return false
end

local function _notify_presented(self)
    if not self._startup_present_gate_released and not self.is_finished then
        self._presented_frame_count = self._presented_frame_count + 1
        if not self._first_present_time then
            self._first_present_time = rl.GetTime()
        end
    end
end

local function _get_stage_index(self)
    if self.total_stage_count <= 0 then
        return 0
    end
    if self.is_finished then
        return self.total_stage_count
    end
    return math.max(1, math.min(self._stage_index, self.total_stage_count))
end

local function _get_progress_percent(self)
    local progress_percent = math.floor((self.progress_ratio or 0) * 100 + 0.5)
    return math.max(0, math.min(100, progress_percent))
end

local function _build_compact_status_text(self)
    local raw_stage_text = self.stage_name ~= "" and self.stage_name or "准备中"
    local raw_label_text = self.current_label ~= "" and self.current_label or "正在准备资源任务..."
    local detail_text = raw_label_text
    if detail_text == raw_stage_text then
        detail_text = ""
    end

    local main_text = raw_stage_text
    if detail_text ~= "" then
        main_text = string.format("%s - %s", raw_stage_text, detail_text)
    end

    if self.total_stage_count > 0 then
        return string.format(
            "(%d/%d) %s · %d%%",
            _get_stage_index(self),
            self.total_stage_count,
            main_text,
            _get_progress_percent(self))
    end

    return string.format("%s · %d%%", main_text, _get_progress_percent(self))
end

local function _prepare_next_stage(self)
    if self._current_stage then
        self.finished_stage_count = math.min(self.total_stage_count, self.finished_stage_count + 1)
    end

    self._stage_index = self._stage_index + 1
    local stage = self._stage_list[self._stage_index]
    if not stage then
        self.stage_name = "已完成"
        self.current_label = ""
        self._current_stage = nil
        self._current_task_list = nil
        self._stage_total_count = 0
        self.progress_ratio = 1
        self.is_finished = true
        return
    end

    self.stage_name = stage.name or string.format("阶段 %d", self._stage_index)
    self.current_label = ""
    self._current_stage = stage
    self._current_task_index = 1
    self._stage_finished_count = 0
    self._current_task_progress_ratio = 0
    self._current_task_list = _normalize_tasks(stage.build_tasks and stage.build_tasks(self.shared, self) or stage.tasks)
    self._stage_total_count = #self._current_task_list
    self.total_count = self.total_count + self._stage_total_count
    _refresh_progress(self)

    if self._stage_total_count == 0 then
        _prepare_next_stage(self)
    end
end

function ResourceTaskRunner:ctor(config)
    config = config or {}
    local stage_list = config.stages or {}

    self.title = config.title or "处理中"
    self.stage_name = ""
    self.current_label = ""
    self.progress_ratio = 0
    self.finished_count = 0
    self.total_count = 0
    self.finished_stage_count = 0
    self.total_stage_count = #stage_list
    self.is_modal = config.is_modal ~= false
    self.is_finished = false
    self.error_message = nil
    self.shared = config.shared or {}
    self._popup_id = config.popup_id or string.format("resource_task_runner_%s", tostring(self))
    self._modal_closed = false
    self._dismissed = false
    self._stage_index = 0
    self._stage_finished_count = 0
    self._stage_total_count = 0
    self._current_task_index = 1
    self._current_task_progress_ratio = 0
    self._current_task_list = nil
    self._current_stage = nil
    self._stage_list = stage_list
    self._frame_budget_ms = config.frame_budget_ms or 5
    self._error_button_label = config.error_button_label or "关闭"
    self._auto_close_on_finish = config.auto_close_on_finish ~= false
    self._on_finish = config.on_finish
    self._finish_called = false
    self._present_before_start_frames = math.max(0, math.floor(config.present_before_start_frames or 0))
    self._present_before_start_seconds = math.max(0, tonumber(config.present_before_start_seconds) or 0)
    self._presented_frame_count = 0
    self._first_present_time = nil
    self._startup_present_gate_released = self._present_before_start_frames <= 0 and self._present_before_start_seconds <= 0
end

function ResourceTaskRunner:pending()
    return module.TaskState.PENDING
end

function ResourceTaskRunner:set_task_progress(progress_ratio, label)
    self._current_task_progress_ratio = math.max(0, math.min(0.999, tonumber(progress_ratio) or 0))
    if type(label) == "string" and label ~= "" then
        self.current_label = label
    end
    _refresh_progress(self)
end

function ResourceTaskRunner:clear_task_progress()
    self._current_task_progress_ratio = 0
    _refresh_progress(self)
end

function ResourceTaskRunner:update(delta)
    if self.is_finished and self._finish_called then
        return
    end

    if not self._current_task_list and not self.is_finished then
        _prepare_next_stage(self)
    end

    local current_task = self._current_task_list and self._current_task_list[self._current_task_index] or nil
    if _is_start_gate_active(self) then
        self.current_label = current_task and (current_task.label or self.stage_name or "") or (self.stage_name or "")
        _refresh_progress(self)
        return
    end

    local start_time = rl.GetTime()
    local frame_budget_seconds = math.max(0.001, self._frame_budget_ms / 1000.0)

    while not self.is_finished do
        local task = self._current_task_list and self._current_task_list[self._current_task_index] or nil
        if not task then
            self._current_task_list = nil
            self._current_task_progress_ratio = 0
            _prepare_next_stage(self)
            task = self._current_task_list and self._current_task_list[self._current_task_index] or nil
            if not task then
                break
            end
        end

        self.current_label = task.label or self.stage_name or ""
        if task.present_before_run and not task._presented_before_run then
            task._presented_before_run = true
            _refresh_progress(self)
            break
        end

        local ok, task_state = pcall(task.run, self.shared, self, delta)
        if not ok then
            self.error_message = tostring(task_state)
            self.is_finished = true
            break
        end

        if task_state == module.TaskState.PENDING then
            _refresh_progress(self)
            break
        end

        task._presented_before_run = nil
        self._current_task_progress_ratio = 0
        self._current_task_index = self._current_task_index + 1
        self._stage_finished_count = self._stage_finished_count + 1
        self.finished_count = self.finished_count + 1
        _refresh_progress(self)

        if rl.GetTime() - start_time >= frame_budget_seconds then
            break
        end
    end

    if self.is_finished and not self._finish_called then
        self._finish_called = true
        if self.total_count == 0 then
            self.progress_ratio = 1
        end
        if self._on_finish then
            self._on_finish(self.shared, self)
        end
    end
end

function ResourceTaskRunner:notify_presented()
    _notify_presented(self)
end

function ResourceTaskRunner:get_compact_status_text()
    return _build_compact_status_text(self)
end

function ResourceTaskRunner:draw_modal()
    if not self.is_modal or self._modal_closed then
        return
    end

    local viewport = imgui.GetMainViewport()
    local editor_zoom_ratio = SettingsManager.get("editor_zoom_ratio") or 1.0
    local has_error = self.error_message ~= nil
    local window_width = 560 * editor_zoom_ratio
    local window_height = (has_error and 236 or 176) * editor_zoom_ratio
    local center = imgui.ImVec2(
        viewport.WorkPos.x + viewport.WorkSize.x * 0.5,
        viewport.WorkPos.y + viewport.WorkSize.y * 0.5)

    local overlay_flags = imgui.WindowFlags.NoDocking
        | imgui.WindowFlags.NoTitleBar
        | imgui.WindowFlags.NoCollapse
        | imgui.WindowFlags.NoResize
        | imgui.WindowFlags.NoMove
        | imgui.WindowFlags.NoScrollbar
        | imgui.WindowFlags.NoScrollWithMouse
        | imgui.WindowFlags.NoSavedSettings

    imgui.SetNextWindowPos(viewport.WorkPos, imgui.ImGuiCond.Always)
    imgui.SetNextWindowSize(viewport.WorkSize, imgui.ImGuiCond.Always)
    imgui.SetNextWindowViewport(viewport.ID)
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVar(imgui.StyleVar.WindowRounding, 0)
    imgui.PushStyleVar(imgui.StyleVar.WindowBorderSize, 0)
    imgui.PushStyleColor(imgui.ImGuiCol.WindowBg, EditorThemeManager.get_modal_overlay_color())
    imgui.Begin(string.format("##resource_task_runner_overlay_%s", self._popup_id), nil, overlay_flags)
    imgui.SetCursorScreenPos(viewport.WorkPos)
    imgui.PushStyleColor(imgui.ImGuiCol.Button, imgui.ImColor(0, 0, 0, 0).value)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonHovered, imgui.ImColor(0, 0, 0, 0).value)
    imgui.PushStyleColor(imgui.ImGuiCol.ButtonActive, imgui.ImColor(0, 0, 0, 0).value)
    imgui.Button(string.format("##resource_task_runner_overlay_blocker_%s", self._popup_id), imgui.ImVec2(viewport.WorkSize.x, viewport.WorkSize.y))
    imgui.PopStyleColor(3)
    imgui.PopStyleColor()
    imgui.PopStyleVar(3)

    imgui.SetCursorScreenPos(imgui.ImVec2(center.x - window_width * 0.5, center.y - window_height * 0.5))
    imgui.PushStyleVar(imgui.StyleVar.WindowPadding, imgui.ImVec2(16 * editor_zoom_ratio, 14 * editor_zoom_ratio))
    imgui.PushStyleVar(imgui.StyleVar.ChildRounding, 10 * editor_zoom_ratio)
    imgui.PushStyleVar(imgui.StyleVar.ChildBorderSize, 1)
    imgui.PushStyleColor(imgui.ImGuiCol.ChildBg, EditorThemeManager.get_modal_panel_bg_color())
    imgui.PushStyleColor(imgui.ImGuiCol.Border, EditorThemeManager.get_modal_panel_border_color())
    imgui.BeginChild(
        string.format("##resource_task_runner_content_%s", self._popup_id),
        imgui.ImVec2(window_width, window_height),
        imgui.ChildFlags.Borders,
        imgui.WindowFlags.NoMove | imgui.WindowFlags.NoScrollbar | imgui.WindowFlags.NoScrollWithMouse | imgui.WindowFlags.NoSavedSettings)
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)

    _notify_presented(self)

    local content_width = imgui.GetContentRegionAvail().x
    local raw_stage_text = self.stage_name ~= "" and self.stage_name or "准备中"
    local raw_label_text = self.current_label ~= "" and self.current_label or "正在准备资源任务..."
    local progress_percent = math.floor((self.progress_ratio or 0) * 100 + 0.5)
    local overlay_text = string.format("%d%%", math.max(0, math.min(100, progress_percent)))
    local stage_index = self.total_stage_count > 0 and math.max(1, math.min(self._stage_index, self.total_stage_count)) or 0
    local stage_text = ImGUIHelper.EllipsisTail(
        string.format("当前阶段：%s", raw_stage_text),
        math.max(60, content_width))
    local label_text = ImGUIHelper.EllipsisTail(
        string.format("正在处理：%s", raw_label_text),
        math.max(60, content_width))
    local stage_summary_text = "等待阶段信息"

    if self.total_stage_count > 0 then
        stage_index = self.is_finished and self.total_stage_count or stage_index
        local total_count = math.max(self.total_count or 0, 0)
        local finished_count = math.min(math.max(self.finished_count or 0, 0), total_count)
        if total_count > 0 then
            stage_summary_text = string.format(
                "第 %d/%d 阶段 · 已完成 %d/%d 项",
                stage_index,
                self.total_stage_count,
                finished_count,
                total_count)
        else
            stage_summary_text = string.format("第 %d/%d 阶段", stage_index, self.total_stage_count)
        end
    end

    stage_summary_text = ImGUIHelper.EllipsisTail(stage_summary_text, math.max(60, content_width))

    local progress_bar_height = math.max(
        imgui.GetTextLineHeight() + 6 * editor_zoom_ratio,
        20 * editor_zoom_ratio)

    imgui.Text(ImGUIHelper.EllipsisTail(self.title, math.max(60, content_width)))
    imgui.Dummy(imgui.ImVec2(0, 3 * editor_zoom_ratio))
    imgui.TextDisabled(stage_text)
    imgui.Dummy(imgui.ImVec2(0, 4 * editor_zoom_ratio))
    imgui.Text(label_text)
    imgui.Dummy(imgui.ImVec2(0, 5 * editor_zoom_ratio))
    imgui.ProgressBar(self.progress_ratio, imgui.ImVec2(-1, progress_bar_height), overlay_text)
    imgui.Dummy(imgui.ImVec2(0, 3 * editor_zoom_ratio))
    imgui.TextDisabled(stage_summary_text)

    if self.error_message then
        imgui.Dummy(imgui.ImVec2(0, 8 * editor_zoom_ratio))
        imgui.TextColored(
            imgui.ImColor(197, 61, 67, 255).value,
            ImGUIHelper.EllipsisTail(self.error_message, math.max(60, content_width)))
        imgui.Dummy(imgui.ImVec2(0, 6 * editor_zoom_ratio))
        if imgui.Button(self._error_button_label, imgui.ImVec2(-1, 0)) then
            self._dismissed = true
            self._modal_closed = true
        end
    elseif self.is_finished and self._auto_close_on_finish then
        self._modal_closed = true
    end

    imgui.EndChild()
    imgui.End()
end

function ResourceTaskRunner:is_closed()
    return self._modal_closed
end

function ResourceTaskRunner:is_dismissed()
    return self._dismissed
end

module.new = function(config)
    return ResourceTaskRunner.new(config)
end

module.ResourceTaskRunner = ResourceTaskRunner

return module

local module = {}

local function _trim(text)
    if type(text) ~= "string" then
        return nil
    end

    local value = text:match("^%s*(.-)%s*$")
    if value == "" then
        return nil
    end
    return value
end

local function _copy_hint(hint)
    if type(hint) ~= "table" then
        return nil
    end
    return
    {
        kind = _trim(hint.kind) or "info",
        label = _trim(hint.label) or "流程节点",
        description = _trim(hint.description) or "",
        color = type(hint.color) == "table" and
        {
            r = tonumber(hint.color.r) or 128,
            g = tonumber(hint.color.g) or 128,
            b = tonumber(hint.color.b) or 128,
            a = tonumber(hint.color.a) or 255,
        } or nil,
    }
end

local hint_pool =
{
    wait_interaction =
    {
        kind = "saveable_wait",
        label = "可存档等待点",
        description = "流程会停住等待玩家点击或按键，这里可以保存。",
        color = {r = 82, g = 168, b = 105, a = 255},
    },
    show_dialog_box =
    {
        kind = "saveable_wait",
        label = "文本完成后可存",
        description = "文本显示完成并等待互动时可以保存；打字机播放中不可保存。",
        color = {r = 82, g = 168, b = 105, a = 255},
    },
    show_subtitle =
    {
        kind = "saveable_wait",
        label = "字幕完成后可存",
        description = "字幕显示完成并等待互动时可以保存；字幕播放中不可保存。",
        color = {r = 82, g = 168, b = 105, a = 255},
    },
    show_choice_button =
    {
        kind = "choice_wait",
        label = "可存档：等待选择",
        description = "选项出现后流程停住等待玩家选择，这里可以保存。",
        color = {r = 82, g = 168, b = 105, a = 255},
    },
    call_ui =
    {
        kind = "ui_call_wait",
        label = "可存档：等待界面",
        description = "打开界面并暂停主流程。界面关闭或返回结果后主流程继续，等待期间可以保存。",
        color = {r = 82, g = 168, b = 105, a = 255},
    },
    show_ui =
    {
        kind = "overlay_ui",
        label = "不暂停主流程",
        description = "只显示界面覆盖层，主流程会继续。能否保存取决于主流程后面是否停在等待点。",
        color = {r = 96, g = 146, b = 210, a = 255},
    },
    close_ui =
    {
        kind = "command",
        label = "关闭界面命令",
        description = "关闭界面后继续执行，不会自己形成存档点。",
        color = {r = 142, g = 150, b = 160, a = 255},
    },
    quick_save =
    {
        kind = "save_action",
        label = "保存命令",
        description = "执行到这里会尝试写入快速存档位置；成功后从成功出口继续。界面按钮存档请在界面设计视图里设置。",
        color = {r = 84, g = 132, b = 219, a = 255},
    },
    save_slot =
    {
        kind = "save_action",
        label = "保存命令",
        description = "执行到这里会尝试写入指定存档位置；成功后从成功出口继续。界面按钮存档请在界面设计视图里设置。",
        color = {r = 84, g = 132, b = 219, a = 255},
    },
    quick_load =
    {
        kind = "load_action",
        label = "读取后切换",
        description = "读取成功后会切换到存档状态，不会继续执行当前节点后面的连线。",
        color = {r = 84, g = 132, b = 219, a = 255},
    },
    load_slot =
    {
        kind = "load_action",
        label = "读取后切换",
        description = "读取成功后会切换到存档状态，不会继续执行当前节点后面的连线。",
        color = {r = 84, g = 132, b = 219, a = 255},
    },
    switch_background =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "动画播放中不能存档；如果勾选“等待互动”，动画结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    add_foreground =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "前景出现动画中不能存档；如果勾选“等待互动”，动画结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    move_foreground =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "前景移动中不能存档；如果勾选“等待互动”，移动结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    remove_foreground =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "前景移除动画中不能存档；如果勾选“等待互动”，动画结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    transition_fade_in =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "淡入中不能存档；如果勾选“等待互动”，淡入结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    transition_fade_out =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "淡出中不能存档；如果勾选“等待互动”，淡出结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    show_letterboxing =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "黑边动画中不能存档；如果勾选“等待互动”，动画结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    hide_letterboxing =
    {
        kind = "effect_optional_wait",
        label = "动画后等待",
        description = "黑边动画中不能存档；如果勾选“等待互动”，动画结束后会停住，并成为可存档点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    play_video =
    {
        kind = "running_effect",
        label = "播放中不可存",
        description = "视频播放期间默认不形成存档点；需要保存请在视频结束后的等待点保存。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
    delay =
    {
        kind = "running_effect",
        label = "计时中不可存",
        description = "等待计时期间不形成存档点；计时结束后会继续到后续节点。",
        color = {r = 219, g = 162, b = 64, a = 255},
    },
}

local ui_event_entry_hint =
{
    kind = "ui_event_entry",
    label = "界面事件入口",
    description = "组件事件触发后从这里进入界面行为流程；事件流程执行中不是主存档点。",
    color = {r = 96, g = 146, b = 210, a = 255},
}

local checkpoint_label_pool =
{
    stable_boundary = "稳定边界",
    interaction_boundary = "等待玩家操作",
    node_enter = "节点进入",
    node_exit = "节点完成后",
    running_resumable = "运行中可恢复点",
    input_wait = "等待玩家操作",
    choice_wait = "等待玩家选择",
    ui_call_wait = "等待界面返回",
    node_waiting = "节点等待中",
    bridge_waiting = "文本命令等待中",
}

local function _format_anchor_text(runtime_state)
    local state = type(runtime_state) == "table" and runtime_state or {}
    local anchor = type(state.anchor) == "table" and state.anchor
        or type(state.current_source_anchor) == "table" and state.current_source_anchor
        or {}

    local label = _trim(anchor.label)
    if label then
        return string.format("#%s", label)
    end

    local node_title = _trim(anchor.node_title)
    if node_title then
        return node_title
    end

    local node_id = tonumber(anchor.node_id or state.current_node_id or state.next_node_id)
    if node_id then
        return string.format("节点 #%d", node_id)
    end

    local line = tonumber(anchor.line)
    if line then
        return string.format("第 %d 行", line)
    end

    return nil
end

local function _has_list_items(value)
    return type(value) == "table" and #value > 0
end

function module.get_node_hint(type_id, definition)
    local custom_hint = type(definition) == "table" and definition.save_boundary_hint or nil
    local normalized_type = tostring(type_id or "")
    if custom_hint then
        return _copy_hint(custom_hint)
    end
    if normalized_type:match("^ui_on_") then
        return _copy_hint(ui_event_entry_hint)
    end
    return _copy_hint(hint_pool[normalized_type])
end

function module.get_checkpoint_label(kind)
    local key = _trim(kind) or "stable_boundary"
    return checkpoint_label_pool[key] or "运行边界"
end

function module.describe_runtime_state(runtime_state)
    if type(runtime_state) ~= "table" then
        return
        {
            checkpoint_kind = "unknown",
            checkpoint_label = "未记录",
            restore_label = "未记录恢复方式",
            anchor_text = nil,
            summary = "当前运行态没有提供可保存边界。",
        }
    end

    local checkpoint_kind = _trim(runtime_state.checkpoint_kind) or "stable_boundary"
    local restore_label = "从当前稳定边界恢复"
    if type(runtime_state.pending_resume) == "table" then
        restore_label = "读档后仍等待玩家操作"
    elseif runtime_state.current_node_resume_mode == "reexecute" then
        if _has_list_items(runtime_state.skip_ui_instance_ids) then
            restore_label = "读档后重新打开等待中的界面"
        else
            restore_label = "读档后重新进入当前等待节点"
        end
    elseif type(runtime_state.continue_route) == "table" then
        restore_label = "读档后从下一节点继续"
    elseif runtime_state.kind == "text" then
        restore_label = "读档后恢复文本剧本位置"
    end

    local anchor_text = _format_anchor_text(runtime_state)
    local checkpoint_label = module.get_checkpoint_label(checkpoint_kind)
    local summary = anchor_text and string.format("%s：%s，%s", checkpoint_label, anchor_text, restore_label)
        or string.format("%s：%s", checkpoint_label, restore_label)

    return
    {
        checkpoint_kind = checkpoint_kind,
        checkpoint_label = checkpoint_label,
        restore_label = restore_label,
        anchor_text = anchor_text,
        summary = summary,
    }
end

function module.format_block_reason(reason)
    local text = _trim(tostring(reason or "")) or "当前不能存档"
    local path_detail = text:match("%(path:[^)]+%)")
    local rule_list =
    {
        {"当前没有运行中的流程", "当前没有运行中的流程，不能存档。"},
        {"当前流程图运行时尚未启动", "当前流程图还没有开始运行，不能存档。"},
        {"当前文本流程尚未启动", "当前文本剧本还没有开始运行，不能存档。"},
        {"当前文本流程已经结束", "当前流程已结束，不能存档。"},
        {"当前流程不支持存档", "当前没有可恢复的剧情等待点，不能存档。"},
        {"尚未进入可保存的稳定检查点", "当前流程还没有停在玩家等待点，暂时不能存档。"},
        {"尚未进入可保存的稳定等待点", "当前节点还没有停在玩家等待点，暂时不能存档。"},
        {"未处于等待状态", "当前节点没有进入等待状态，暂时不能存档。"},
        {"正在进入等待状态", "当前节点正在进入等待状态，输入释放后才能存档。"},
        {"没有启用等待并可存档", "这个界面只是覆盖显示，没有暂停主流程；需要存档请使用“调用界面并等待”。"},
        {"没有启用等待关闭后继续", "这个界面只是覆盖显示，没有暂停主流程；需要存档请使用“调用界面并等待”。"},
        {"界面已关闭，即将继续执行后续流程", "界面已经关闭，主流程即将继续，稍后再存档。"},
        {"还没有打开有效界面", "界面还没有打开完成，暂时不能存档。"},
        {"尚未打开有效界面实例", "界面还没有打开完成，暂时不能存档。"},
        {"正在执行中的界面脱离流程", "界面事件流程还在执行，结束后才能存档。"},
        {"仍在执行事件流程", "界面按钮事件还在执行，结束后才能存档。"},
        {"仍存在待执行的行为流程", "界面还有待执行事件，结束后才能存档。"},
        {"当前场景尚未进入可保存", "当前场景还有演出或对象状态未稳定，暂时不能存档。"},
        {"当前场景对象尚未进入可保存状态", "当前场景对象还在演出或变化中，暂时不能存档。"},
        {"检测到循环引用", "当前存档数据里混入了运行时对象或循环引用，不能写入存档。"},
        {"持久化数据嵌套过深", "当前存档数据嵌套过深，不能安全写入存档。"},
        {"持久化数据包含不能写入的键", "当前存档数据里混入了运行时对象，不能写入存档。"},
        {"生成存档快照失败", "生成存档快照时发生错误，不能写入存档。"},
        {"整理存档数据失败", "整理存档数据时发生错误，不能写入存档。"},
        {"不能保存的运行时对象", "当前存档数据里混入了运行时对象，不能写入存档。"},
        {"不支持持久化类型", "当前存档数据包含不能写入的值，不能存档。"},
    }

    for _, rule in ipairs(rule_list) do
        if text:find(rule[1], 1, true) then
            if path_detail then
                return string.format("%s %s", rule[2], path_detail)
            end
            return rule[2]
        end
    end

    return text
end

return module

local imgui = Engine.ImGUI

local module =
{
    hidden_property_pool =
    {
        visible = true,
        opacity = true,
        action_kind = true,
        action_target = true,
        action_message = true,
        action_ui = true,
        action_instance_id = true,
        action_slot_id = true,
        action_save_category = true,
        action_auto_advance_interval = true,
        reentry_policy = true,
        event_name = true,
        event_flow = true,
        event_entry = true,
        hit_test_enabled = true,
        block_background_input = true,
        padding = true,
        anchor_min = true,
        anchor_max = true,
        offset_min = true,
        offset_max = true,
        pivot = true,
        preferred_size = true,
        min_size = true,
        layout_stretch = true,
        style_domain = true,
        category = true,
        page = true,
        per_page = true,
        total_pages = true,
    },

    widget_tree_marker_color_pool =
    {
        Canvas = imgui.ImColor(235, 74, 88, 255):to_u32(),
        Panel = imgui.ImColor(64, 150, 255, 255):to_u32(),
        Text = imgui.ImColor(246, 202, 75, 255):to_u32(),
        Image = imgui.ImColor(186, 106, 255, 255):to_u32(),
        Button = imgui.ImColor(255, 145, 65, 255):to_u32(),
        Toggle = imgui.ImColor(245, 91, 128, 255):to_u32(),
        ProgressBar = imgui.ImColor(43, 205, 177, 255):to_u32(),
        SaveSlotGrid = imgui.ImColor(96, 189, 255, 255):to_u32(),
        Spacer = imgui.ImColor(160, 166, 176, 255):to_u32(),
        VerticalContainer = imgui.ImColor(46, 214, 124, 255):to_u32(),
        HorizontalContainer = imgui.ImColor(33, 196, 216, 255):to_u32(),
        OverlayContainer = imgui.ImColor(142, 116, 255, 255):to_u32(),
        ScrollView = imgui.ImColor(255, 185, 63, 255):to_u32(),
        GridContainer = imgui.ImColor(112, 221, 86, 255):to_u32(),
    },

    widget_tree_marker_default_color = imgui.ImColor(174, 181, 192, 255):to_u32(),
    widget_tree_marker_icon_id = "radio-button-fill",
    widget_tree_arrow_marker_gap = 10,
    widget_tree_marker_gap = 12,
    widget_tree_marker_min_radius = 5,
    widget_tree_font_scale = 1.3,
    widget_tree_vertical_spacing_scale = 2,
    widget_tree_connector_color = imgui.ImColor(126, 139, 158, 150):to_u32(),
    widget_tree_connector_thickness = 2,
    widget_tree_connector_gap = 2,
    widget_tree_connector_branch_length = 6,
    widget_tree_indent_spacing = 36,
    ui_designer_yellow = imgui.ImColor(255, 190, 72, 255).value,
    widget_tree_drag_payload_type = "ui_designer_widget_tree",
    preview_safe_area_letterbox_height = 200,
    preview_safe_area_reference_height = 1080,

    canvas_preset_list =
    {
        {name = "1080p 横屏 16:9", width = 1920, height = 1080},
        {name = "720p 横屏 16:9", width = 1280, height = 720},
        {name = "1080p 竖屏 9:16", width = 1080, height = 1920},
        {name = "720p 竖屏 9:16", width = 720, height = 1280},
        {name = "正方形 1:1 1080", width = 1080, height = 1080},
        {name = "正方形 1:1 720", width = 720, height = 720},
    },

    canvas_mode_list =
    {
        {id = "fixed", label = "固定尺寸"},
        {id = "project", label = "跟随项目尺寸"},
        {id = "responsive", label = "响应式缩放"},
    },

    create_widget_category_order =
    {
        "交互",
        "基础",
        "布局",
        "系统",
    },

    click_action_kind_list =
    {
        "none",
        "close_ui",
        "open_ui",
        "quick_save",
        "quick_load",
        "fast_forward",
        "auto_advance",
        "rollback",
    },

    click_action_label_pool =
    {
        none = "不执行动作",
        close_ui = "关闭当前界面",
        return_value = "返回结果并关闭",
        open_ui = "打开另一个界面",
        quick_save = "快速存档",
        quick_load = "快速读档",
        fast_forward = "快进",
        auto_advance = "自动推进",
        rollback = "回退",
    },

    reentry_policy_label_pool =
    {
        once = "仅生效一次",
        repeatable = "可重复点击",
        ignore = "仅生效一次",
        restart = "可重复点击",
        queue = "可重复点击",
    },

    property_enum_label_pool =
    {
        consume_input =
        {
            block = "阻止",
            pass = "不阻止",
            auto = "阻止",
            always = "阻止",
            never = "不阻止",
        },
        image_fit_mode =
        {
            fill = "填充",
            preserve_aspect = "保持比例",
        },
        mode =
        {
            save = "存档",
            load = "读档",
        },
        align_x =
        {
            start = "左对齐",
            center = "居中",
            ["end"] = "右对齐",
        },
        align_y =
        {
            start = "顶部",
            center = "居中",
            ["end"] = "底部",
        },
        cross_align =
        {
            stretch = "拉伸填满",
            start = "靠起点",
            center = "居中",
            ["end"] = "靠终点",
        },
    },

    preview_zoom_min = 0.25,
    preview_zoom_max = 4.0,
    preview_view_smooth_factor = 0.24,
    preview_pan_mouse_button_list = {1, 2},
    preview_resize_handle_visual_size = 8,
    preview_resize_handle_hit_padding = 5,
    preview_min_widget_extent = 8,
    preview_snap_screen_threshold = 10,
    preview_transform_color = {r = 1, g = 1, b = 1, a = 1},

    preview_resize_handle_list =
    {
        {key = "nw", ox = 0.0, oy = 0.0},
        {key = "n", ox = 0.5, oy = 0.0},
        {key = "ne", ox = 1.0, oy = 0.0},
        {key = "e", ox = 1.0, oy = 0.5},
        {key = "se", ox = 1.0, oy = 1.0},
        {key = "s", ox = 0.5, oy = 1.0},
        {key = "sw", ox = 0.0, oy = 1.0},
        {key = "w", ox = 0.0, oy = 0.5},
    },

    preview_auto_layout_parent_pool =
    {
        VerticalContainer = true,
        HorizontalContainer = true,
        GridContainer = true,
    },

    inspector_label_sample = "组件名称",
    inspector_min_field_width = 80,
    inspector_hard_min_field_width = 28,
    inspector_bool_field_width = 24,
}

return module

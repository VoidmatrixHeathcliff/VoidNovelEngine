local module = {}

local default_document =
{
    version = 1,
    domains =
    {
        dialog_box =
        {
            custom = false,
            display_name = "对话框",
            fields =
            {
                position =
                {
                    value = {x = 140, y = 760},
                    custom = false,
                    has_value = true,
                    type_id = "vector2",
                    display_name = "位置",
                },
                width =
                {
                    value = 1640,
                    custom = false,
                    has_value = true,
                    type_id = "float",
                    display_name = "宽度",
                },
                fade_time =
                {
                    value = 0.2,
                    custom = false,
                    has_value = true,
                    type_id = "float",
                    display_name = "淡入时间",
                },
                fade_out_time =
                {
                    value = 1,
                    custom = false,
                    has_value = true,
                    type_id = "float",
                    display_name = "淡出时间",
                },
                role_font =
                {
                    value =
                    {
                        guid = "d4298d94-ccd9-4bd9-b4ba-b03f304852e4",
                        path_hint = "font/font.otf",
                    },
                    custom = false,
                    has_value = true,
                    type_id = "font",
                    display_name = "角色字体",
                },
                dialogue_font =
                {
                    value =
                    {
                        guid = "d4298d94-ccd9-4bd9-b4ba-b03f304852e4",
                        path_hint = "font/font.otf",
                    },
                    custom = false,
                    has_value = true,
                    type_id = "font",
                    display_name = "内容字体",
                },
                role_font_size =
                {
                    value = 28,
                    custom = false,
                    has_value = true,
                    type_id = "int",
                    display_name = "角色字号",
                },
                dialogue_font_size =
                {
                    value = 25,
                    custom = false,
                    has_value = true,
                    type_id = "int",
                    display_name = "内容字号",
                },
                role_color =
                {
                    value = {x = 1, y = 0.9, z = 0.65, w = 1},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "角色颜色",
                },
                dialogue_color =
                {
                    value = {x = 0.96, y = 0.96, z = 0.96, w = 1},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "内容颜色",
                },
                background_color =
                {
                    value = {x = 0.06, y = 0.09, z = 0.13, w = 0.86},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "背景颜色",
                },
                background_image =
                {
                    custom = false,
                    has_value = false,
                    type_id = "texture",
                    display_name = "背景图片",
                },
            },
        },
        subtitle =
        {
            custom = false,
            display_name = "字幕",
            fields =
            {
                char_interval =
                {
                    value = 0.03,
                    custom = false,
                    has_value = true,
                    type_id = "float",
                    display_name = "字符时间间隔",
                },
                bottom_distance =
                {
                    value = 54,
                    custom = false,
                    has_value = true,
                    type_id = "float",
                    display_name = "底部距离",
                },
                font =
                {
                    value =
                    {
                        guid = "d4298d94-ccd9-4bd9-b4ba-b03f304852e4",
                        path_hint = "font/font.otf",
                    },
                    custom = false,
                    has_value = true,
                    type_id = "font",
                    display_name = "字体",
                },
                font_size =
                {
                    value = 40,
                    custom = false,
                    has_value = true,
                    type_id = "int",
                    display_name = "字号",
                },
                color =
                {
                    value = {x = 0.95, y = 0.95, z = 0.95, w = 1},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "颜色",
                },
            },
        },
        choice_button =
        {
            custom = false,
            display_name = "分支按钮",
            fields =
            {
                font =
                {
                    value =
                    {
                        guid = "d4298d94-ccd9-4bd9-b4ba-b03f304852e4",
                        path_hint = "font/font.otf",
                    },
                    custom = false,
                    has_value = true,
                    type_id = "font",
                    display_name = "字体",
                },
                font_size =
                {
                    value = 24,
                    custom = false,
                    has_value = true,
                    type_id = "int",
                    display_name = "字号",
                },
                text_color =
                {
                    value = {x = 1, y = 1, z = 1, w = 0.82},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "默认颜色",
                },
                hover_color =
                {
                    value = {x = 0.44, y = 0.8, z = 0.57, w = 0.96},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "高亮颜色",
                },
                background_color =
                {
                    value = {x = 0.05, y = 0.06, z = 0.09, w = 0.78},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "背景颜色",
                },
                border_color =
                {
                    value = {x = 0.4, y = 0.46, z = 0.54, w = 0.86},
                    custom = false,
                    has_value = true,
                    type_id = "color",
                    display_name = "边框颜色",
                },
                button_spacing =
                {
                    value = 18,
                    custom = false,
                    has_value = true,
                    type_id = "int",
                    display_name = "按钮间隔",
                },
                button_padding =
                {
                    value = {x = 96, y = 12},
                    custom = false,
                    has_value = true,
                    type_id = "vector2",
                    display_name = "按钮内边距",
                },
                bottom_distance =
                {
                    value = 148,
                    custom = false,
                    has_value = true,
                    type_id = "float",
                    display_name = "底部距离",
                },
                minimum_width =
                {
                    value = 420,
                    custom = false,
                    has_value = true,
                    type_id = "float",
                    display_name = "最小宽度",
                },
                background_image =
                {
                    custom = false,
                    has_value = false,
                    type_id = "texture",
                    display_name = "背景图片",
                },
            },
        },
        shader =
        {
            custom = false,
            display_name = "着色器",
            fields =
            {
                global =
                {
                    custom = false,
                    has_value = false,
                    type_id = "shader",
                    display_name = "全局后处理",
                },
                background =
                {
                    custom = false,
                    has_value = false,
                    type_id = "shader",
                    display_name = "背景",
                },
                foreground =
                {
                    custom = false,
                    has_value = false,
                    type_id = "shader",
                    display_name = "前景",
                },
                video =
                {
                    custom = false,
                    has_value = false,
                    type_id = "shader",
                    display_name = "视频",
                },
            },
        },
    },
}

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, item in pairs(value) do
        copy[key] = _clone_value(item)
    end
    return copy
end

function module.get_document()
    return _clone_value(default_document)
end

return module

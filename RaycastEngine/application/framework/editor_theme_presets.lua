local module = {}

local default_preset_id <const> = "vne_void_dark"
local color_menu_group_order =
{
    official = 1,
    workspace = 2,
    stylized = 3,
    light = 4,
}

local function _clone_value(value)
    if type(value) ~= "table" then
        return value
    end

    local clone = {}
    for key, item in pairs(value) do
        clone[key] = _clone_value(item)
    end
    return clone
end

local preset_list =
{
    {
        id = "imgui_dark",
        display_name = "ImGui Dark",
        base_style = "dark",
        menu_group = "official",
        tokens =
        {
            bg_0 = "#15181D",
            bg_1 = "#1C2128",
            bg_2 = "#242B35",
            bg_3 = "#313B49",
            fg = "#E8ECF3",
            fg_muted = "#A0AABB",
            border = "#414D5F",
            accent_primary = "#4B8DDA",
            accent_secondary = "#74A7FF",
            flow_pin = "#74C2FF",
            flow_link = "#5AB3F7",
            node_canvas_bg = "#10151B",
            node_grid = "#293342",
            node_bg = "#232A34",
            node_border = "#445165",
        },
    },
    {
        id = "moonlight",
        display_name = "LineCat Midnight",
        base_style = "dark",
        menu_group = "workspace",
        menu_order = 11,
        source = "https://github.com/Madam-Herta/Moonlight",
        tokens =
        {
            bg_0 = "#0C0E12",
            bg_1 = "#14161A",
            bg_2 = "#1D2027",
            bg_3 = "#282B31",
            fg = "#FFFFFF",
            fg_muted = "#465173",
            border = "#282B31",
            accent_primary = "#F8FF7F",
            accent_secondary = "#7F83FF",
            accent_success = "#9FE870",
            accent_warning = "#FFCB7F",
            accent_danger = "#FF6B8A",
            flow_pin = "#F8FF7F",
            flow_link = "#7F83FF",
            selection = "#EEEEEEFF",
            modal_overlay = "#111318A6",
            modal_panel_bg = "#14161A",
            modal_panel_border = "#282B31",
            console_bg = "#0C0E12",
            node_canvas_bg = "#0C0E12",
            node_grid = "#252A36",
            node_bg = "#181D25",
            node_border = "#282F3D",
            node_hover_highlight = "#444AFF",
            node_select_highlight = "#7F83FF",
            node_selection_rect = "#7F83FF",
            flow_animation = "#FFCB7F",
            flow_animation_marker = "#F8FF7F",
            node_comment = "#A0A7BE",
            ui_icon = "#F8FF7F",
            ui_icon_disabled = "#465173",
            tab_soft_border = "#7F83FF8A",
        },
        imgui_colors =
        {
            Text = {1.0, 1.0, 1.0, 1.0},
            TextDisabled = {0.2745098173618317, 0.3176470696926117, 0.4509803950786591, 1.0},
            WindowBg = {0.0784313753247261, 0.08627451211214066, 0.1019607856869698, 1.0},
            ChildBg = {0.09250493347644806, 0.100297249853611, 0.1158798336982727, 1.0},
            PopupBg = {0.0784313753247261, 0.08627451211214066, 0.1019607856869698, 1.0},
            Border = {0.1568627506494522, 0.168627455830574, 0.1921568661928177, 1.0},
            BorderShadow = {0.0784313753247261, 0.08627451211214066, 0.1019607856869698, 1.0},
            FrameBg = {0.1620669096708298, 0.1762156516313553, 0.2045064449310303, 1.0},
            FrameBgHovered = {0.2068627506494522, 0.218627455830574, 0.2421568661928177, 1.0},
            FrameBgActive = {0.2148627506494522, 0.226627455830574, 0.2501568661928177, 1.0},
            TitleBg = {0.0470588244497776, 0.05490196123719215, 0.07058823853731155, 1.0},
            TitleBgActive = {0.0470588244497776, 0.05490196123719215, 0.07058823853731155, 1.0},
            TitleBgCollapsed = {0.0784313753247261, 0.08627451211214066, 0.1019607856869698, 1.0},
            MenuBarBg = {0.09803921729326248, 0.105882354080677, 0.1215686276555061, 1.0},
            ScrollbarBg = {0.0470588244497776, 0.05490196123719215, 0.07058823853731155, 1.0},
            ScrollbarGrab = {0.1176470592617989, 0.1333333402872086, 0.1490196138620377, 1.0},
            ScrollbarGrabHovered = {0.1568627506494522, 0.168627455830574, 0.1921568661928177, 1.0},
            ScrollbarGrabActive = {0.1176470592617989, 0.1333333402872086, 0.1490196138620377, 1.0},
            CheckMark = {0.9725490212440491, 1.0, 0.4980392158031464, 1.0},
            SliderGrab = {0.971993625164032, 1.0, 0.4980392456054688, 1.0},
            SliderGrabActive = {1.0, 0.7953379154205322, 0.4980392456054688, 1.0},
            Button = {0.1176470592617989, 0.1333333402872086, 0.1490196138620377, 1.0},
            ButtonHovered = {0.1821731775999069, 0.1897992044687271, 0.1974248886108398, 1.0},
            ButtonActive = {0.1545050293207169, 0.1545048952102661, 0.1545064449310303, 1.0},
            Header = {0.1414651423692703, 0.1629818230867386, 0.2060086131095886, 1.0},
            HeaderHovered = {0.1072951927781105, 0.107295036315918, 0.1072961091995239, 1.0},
            HeaderActive = {0.0784313753247261, 0.08627451211214066, 0.1019607856869698, 1.0},
            Separator = {0.1293079704046249, 0.1479243338108063, 0.1931330561637878, 1.0},
            SeparatorHovered = {0.1568627506494522, 0.1843137294054031, 0.250980406999588, 1.0},
            SeparatorActive = {0.1568627506494522, 0.1843137294054031, 0.250980406999588, 1.0},
            ResizeGrip = {0.1459212601184845, 0.1459220051765442, 0.1459227204322815, 1.0},
            ResizeGripHovered = {0.9725490212440491, 1.0, 0.4980392158031464, 1.0},
            ResizeGripActive = {0.999999463558197, 1.0, 0.9999899864196777, 1.0},
            InputTextCursor = {0.266094446182251, 0.2890366911888123, 1.0, 1.0},
            Tab = {0.0784313753247261, 0.08627451211214066, 0.1019607856869698, 1.0},
            TabHovered = {0.1176470592617989, 0.1333333402872086, 0.1490196138620377, 1.0},
            TabActive = {0.1176470592617989, 0.1333333402872086, 0.1490196138620377, 1.0},
            TabUnfocused = {0.0784313753247261, 0.08627451211214066, 0.1019607856869698, 1.0},
            TabUnfocusedActive = {0.1249424293637276, 0.2735691666603088, 0.5708154439926147, 1.0},
            TabSelectedOverline = {0.4980392158031464, 0.5137255191802979, 1.0, 1.0},
            TabDimmedSelectedOverline = {0.4980392158031464, 0.5137255191802979, 1.0, 0.65},
            DockingPreview = {0.4980392158031464, 0.5137255191802979, 1.0, 0.72},
            DockingEmptyBg = {0.0470588244497776, 0.05490196123719215, 0.07058823853731155, 1.0},
            PlotLines = {0.5215686559677124, 0.6000000238418579, 0.7019608020782471, 1.0},
            PlotLinesHovered = {0.03921568766236305, 0.9803921580314636, 0.9803921580314636, 1.0},
            PlotHistogram = {0.8841201663017273, 0.7941429018974304, 0.5615870356559753, 1.0},
            PlotHistogramHovered = {0.9570815563201904, 0.9570719599723816, 0.9570761322975159, 1.0},
            TableHeaderBg = {0.0470588244497776, 0.05490196123719215, 0.07058823853731155, 1.0},
            TableBorderStrong = {0.0470588244497776, 0.05490196123719215, 0.07058823853731155, 1.0},
            TableBorderLight = {0.0, 0.0, 0.0, 1.0},
            TableRowBg = {0.1176470592617989, 0.1333333402872086, 0.1490196138620377, 1.0},
            TableRowBgAlt = {0.09803921729326248, 0.105882354080677, 0.1215686276555061, 1.0},
            TextLink = {0.4980392158031464, 0.5137255191802979, 1.0, 1.0},
            TextSelectedBg = {0.9356134533882141, 0.9356129765510559, 0.9356223344802856, 1.0},
            TreeLines = {0.1568627506494522, 0.168627455830574, 0.1921568661928177, 1.0},
            DragDropTarget = {0.4980392158031464, 0.5137255191802979, 1.0, 1.0},
            NavHighlight = {0.266094446182251, 0.2890366911888123, 1.0, 1.0},
            NavWindowingHighlight = {0.4980392158031464, 0.5137255191802979, 1.0, 1.0},
            NavWindowingDimBg = {0.06666666666666667, 0.07450980392156863, 0.09411764705882353, 0.6509803921568628},
            ModalWindowDimBg = {0.06666666666666667, 0.07450980392156863, 0.09411764705882353, 0.6509803921568628},
        },
    },
    {
        id = "imgui_light",
        display_name = "ImGui Light",
        base_style = "light",
        menu_group = "official",
        tokens =
        {
            bg_0 = "#D9DEE6",
            bg_1 = "#ECEFF4",
            bg_2 = "#E2E7EE",
            bg_3 = "#CCD4DF",
            fg = "#232A34",
            fg_muted = "#697382",
            border = "#AAB5C3",
            accent_primary = "#4F7FC4",
            accent_secondary = "#6E9ACF",
            flow_pin = "#4B679E",
            flow_link = "#436092",
            node_canvas_bg = "#D7DEE8",
            node_grid = "#AEB9C7",
            node_bg = "#F4F6FA",
            node_border = "#9EACBD",
        },
    },
    {
        id = "imgui_classic",
        display_name = "ImGui Classic",
        base_style = "classic",
        menu_group = "official",
        tokens =
        {
            bg_0 = "#17131E",
            bg_1 = "#211A2A",
            bg_2 = "#2A2234",
            bg_3 = "#382E46",
            fg = "#EEE8F8",
            fg_muted = "#A89DBC",
            border = "#5F5374",
            accent_primary = "#9B7AE6",
            accent_secondary = "#C7A6F6",
            flow_pin = "#B391F1",
            flow_link = "#D1AFFA",
            node_canvas_bg = "#120E18",
            node_grid = "#433756",
            node_bg = "#261F30",
            node_border = "#6C5D84",
        },
    },
    {
        id = "vne_void_dark",
        display_name = "Void Midnight",
        base_style = "dark",
        menu_group = "workspace",
        menu_order = 10,
        tokens =
        {
            bg_0 = "#0C1016",
            bg_1 = "#111721",
            bg_2 = "#182131",
            bg_3 = "#233047",
            fg = "#EAF0FA",
            fg_muted = "#97A4BB",
            border = "#354661",
            accent_primary = "#6C7EFF",
            accent_secondary = "#E6BC5C",
            flow_pin = "#F0CB72",
            flow_link = "#F6DEA0",
            node_canvas_bg = "#090D13",
            node_grid = "#223047",
            node_bg = "#171F2A",
            node_border = "#384A64",
        },
    },
    {
        id = "vne_noir_contrast",
        display_name = "Noir Contrast",
        base_style = "dark",
        menu_group = "workspace",
        tokens =
        {
            bg_0 = "#040506",
            bg_1 = "#090B0D",
            bg_2 = "#12161B",
            bg_3 = "#1D232B",
            fg = "#F5F7FA",
            fg_muted = "#B4BCC8",
            border = "#6A7481",
            accent_primary = "#FFFFFF",
            accent_secondary = "#FFB454",
            flow_pin = "#F4F6FA",
            flow_link = "#FFFFFF",
            node_canvas_bg = "#020304",
            node_grid = "#3A414A",
            node_bg = "#0E1217",
            node_border = "#808A97",
            ui_icon = "#FFFFFF",
        },
    },
    {
        id = "vne_vs_black",
        display_name = "VS Black",
        base_style = "dark",
        menu_group = "workspace",
        tokens =
        {
            bg_0 = "#181818",
            bg_1 = "#1E1E1E",
            bg_2 = "#252526",
            bg_3 = "#2D2D30",
            fg = "#D4D4D4",
            fg_muted = "#9A9A9A",
            border = "#3C3C3C",
            accent_primary = "#569CD6",
            accent_secondary = "#D7BA7D",
            flow_pin = "#D7BA7D",
            flow_link = "#C9A86A",
            node_canvas_bg = "#161616",
            node_grid = "#303030",
            node_bg = "#252526",
            node_border = "#4A4A4A",
        },
    },
    {
        id = "vne_carbon_blue",
        display_name = "Carbon Blue",
        base_style = "dark",
        menu_group = "workspace",
        tokens =
        {
            bg_0 = "#071019",
            bg_1 = "#0D151E",
            bg_2 = "#14202B",
            bg_3 = "#203244",
            fg = "#E3EDF7",
            fg_muted = "#8EA4B7",
            border = "#355166",
            accent_primary = "#41B9FF",
            accent_secondary = "#7FE7FF",
            flow_pin = "#7FE7FF",
            flow_link = "#47CBFF",
            node_canvas_bg = "#050D14",
            node_grid = "#1F4151",
            node_bg = "#121D27",
            node_border = "#386178",
        },
    },
    {
        id = "vne_cyber_neon",
        display_name = "Cyber Neon",
        base_style = "dark",
        menu_group = "stylized",
        tokens =
        {
            bg_0 = "#06070B",
            bg_1 = "#0B0E14",
            bg_2 = "#131924",
            bg_3 = "#1D2635",
            fg = "#FFFCEE",
            fg_muted = "#B8BFCA",
            border = "#455165",
            accent_primary = "#FFE600",
            accent_secondary = "#00F0FF",
            accent_danger = "#FF4FB3",
            flow_pin = "#FF57C6",
            flow_link = "#00F4FF",
            node_canvas_bg = "#05070D",
            node_grid = "#2B3450",
            node_bg = "#121722",
            node_border = "#55617B",
            ui_icon = "#FFE95C",
        },
        style =
        {
            frame_rounding = 3,
        },
    },
    {
        id = "vne_sakura_mix",
        display_name = "Sakura Twin",
        base_style = "dark",
        menu_group = "stylized",
        tokens =
        {
            bg_0 = "#12111A",
            bg_1 = "#171723",
            bg_2 = "#222334",
            bg_3 = "#313957",
            fg = "#FBF5FF",
            fg_muted = "#B6B0C8",
            border = "#4A5071",
            accent_primary = "#FF78B5",
            accent_secondary = "#7EDCFF",
            flow_pin = "#FF9DCF",
            flow_link = "#8EDDFF",
            node_canvas_bg = "#110F18",
            node_grid = "#394463",
            node_bg = "#212335",
            node_border = "#5A6288",
        },
    },
    {
        id = "vne_ocean_night",
        display_name = "Ocean Night",
        base_style = "dark",
        menu_group = "stylized",
        tokens =
        {
            bg_0 = "#07141A",
            bg_1 = "#0B1B22",
            bg_2 = "#11262F",
            bg_3 = "#183B46",
            fg = "#E4F3F0",
            fg_muted = "#8DAAA8",
            border = "#2D5A5E",
            accent_primary = "#23C8A4",
            accent_secondary = "#5FD0FF",
            flow_pin = "#4EE0C7",
            flow_link = "#72C7FF",
            node_canvas_bg = "#051015",
            node_grid = "#19424D",
            node_bg = "#0F2128",
            node_border = "#2F6A71",
        },
    },
    {
        id = "vne_matcha_latte",
        display_name = "Matcha Latte",
        base_style = "light",
        menu_group = "light",
        tokens =
        {
            bg_0 = "#EDE5D6",
            bg_1 = "#F6F1E8",
            bg_2 = "#ECE3D4",
            bg_3 = "#DDD1BC",
            fg = "#2E312B",
            fg_muted = "#6B7168",
            border = "#B9AE97",
            accent_primary = "#5BA35B",
            accent_secondary = "#D68C45",
            flow_pin = "#4B7B3E",
            flow_link = "#8A6130",
            node_canvas_bg = "#E7DECD",
            node_grid = "#BDAF97",
            node_bg = "#FCF8F1",
            node_border = "#B8AB92",
            ui_icon = "#556145",
        },
        style =
        {
            frame_rounding = 5,
        },
    },
}

local preset_by_id = {}
for _, preset in ipairs(preset_list) do
    preset_by_id[preset.id] = preset
end

local default_style_id <const> = "classic_compact"
local style_preset_list =
{
    {
        id = "classic_compact",
        display_name = "Void Theme",
        menu_group = "built_in",
        metrics =
        {
            Alpha = 1.0,
            DisabledAlpha = 0.6,
            WindowPadding = {8, 8},
            WindowRounding = 4,
            WindowBorderSize = 1,
            WindowMinSize = {32, 32},
            WindowTitleAlign = {0, 0.5},
            WindowMenuButtonPosition = 0,
            ChildRounding = 0,
            ChildBorderSize = 1,
            PopupRounding = 4,
            PopupBorderSize = 1,
            FramePadding = {4, 3},
            FrameRounding = 4,
            FrameBorderSize = 1,
            ItemSpacing = {8, 4},
            ItemInnerSpacing = {4, 4},
            CellPadding = {4, 2},
            IndentSpacing = 21,
            ColumnsMinSpacing = 6,
            ScrollbarSize = 14,
            ScrollbarRounding = 4,
            GrabMinSize = 12,
            GrabRounding = 0,
            ImageBorderSize = 0,
            TabRounding = 4,
            TabBorderSize = 1,
            TabBarBorderSize = 1,
            TabCloseButtonMinWidthSelected = 0,
            TabCloseButtonMinWidthUnselected = 0,
            ColorButtonPosition = 1,
            ButtonTextAlign = {0.5, 0.5},
            SelectableTextAlign = {0, 0},
            SeparatorTextBorderSize = 3,
            SeparatorTextAlign = {0, 0.5},
            SeparatorTextPadding = {20, 3},
            DockingSeparatorSize = 2,
        },
    },
    {
        id = "moonlight",
        display_name = "LineCat Theme",
        menu_group = "stylized",
        source = "https://github.com/Madam-Herta/Moonlight",
        metrics =
        {
            Alpha = 1.0,
            DisabledAlpha = 1.0,
            WindowPadding = {20.0, 12.0},
            WindowRounding = 11.5,
            WindowBorderSize = 0.0,
            WindowMinSize = {20.0, 20.0},
            WindowTitleAlign = {0.5, 0.5},
            WindowMenuButtonPosition = 1,
            ChildRounding = 0.0,
            ChildBorderSize = 1.0,
            PopupRounding = 11.5,
            PopupBorderSize = 0.0,
            FramePadding = {20.0, 3.400000095367432},
            FrameRounding = 11.89999961853027,
            FrameBorderSize = 0.0,
            ItemSpacing = {4.300000190734863, 5.5},
            ItemInnerSpacing = {7.099999904632568, 1.799999952316284},
            CellPadding = {12.10000038146973, 9.199999809265137},
            IndentSpacing = 21.0,
            ColumnsMinSpacing = 4.900000095367432,
            ScrollbarSize = 11.60000038146973,
            ScrollbarRounding = 15.89999961853027,
            GrabMinSize = 3.700000047683716,
            GrabRounding = 20.0,
            TabRounding = 0.0,
            TabBorderSize = 0.0,
            TabBarBorderSize = 0.0,
            TabCloseButtonMinWidthSelected = 0.0,
            TabCloseButtonMinWidthUnselected = 0.0,
            ColorButtonPosition = 1,
            ButtonTextAlign = {0.5, 0.5},
            SelectableTextAlign = {0.0, 0.0},
        },
    },
}

local style_preset_by_id = {}
for _, preset in ipairs(style_preset_list) do
    style_preset_by_id[preset.id] = preset
end

module.get_default_id = function()
    return default_preset_id
end

module.get_default_color_id = function()
    return default_preset_id
end

module.get_default_style_id = function()
    return default_style_id
end

module.has = function(preset_id)
    return preset_by_id[preset_id] ~= nil
end

module.has_color = function(preset_id)
    return preset_by_id[preset_id] ~= nil
end

module.has_style = function(preset_id)
    return style_preset_by_id[preset_id] ~= nil
end

module.normalize_id = function(preset_id)
    if type(preset_id) == "string" and preset_by_id[preset_id] then
        return preset_id
    end
    return default_preset_id
end

module.normalize_color_id = function(preset_id)
    return module.normalize_id(preset_id)
end

module.normalize_style_id = function(preset_id)
    if type(preset_id) == "string" and style_preset_by_id[preset_id] then
        return preset_id
    end
    return default_style_id
end

module.get = function(preset_id)
    local normalized_id = module.normalize_id(preset_id)
    return _clone_value(preset_by_id[normalized_id])
end

module.get_color = function(preset_id)
    return module.get(preset_id)
end

module.get_style = function(preset_id)
    local normalized_id = module.normalize_style_id(preset_id)
    return _clone_value(style_preset_by_id[normalized_id])
end

module.list = function()
    return _clone_value(preset_list)
end

module.list_colors = function()
    local list = module.list()
    local original_order = {}
    for index, preset in ipairs(list) do
        original_order[preset.id] = index
    end

    table.sort(list, function(left, right)
        local left_group_order = color_menu_group_order[left.menu_group] or 99
        local right_group_order = color_menu_group_order[right.menu_group] or 99
        if left_group_order ~= right_group_order then
            return left_group_order < right_group_order
        end

        local left_order = tonumber(left.menu_order) or ((original_order[left.id] or 0) + 1000)
        local right_order = tonumber(right.menu_order) or ((original_order[right.id] or 0) + 1000)
        if left_order ~= right_order then
            return left_order < right_order
        end

        return tostring(left.display_name or left.id) < tostring(right.display_name or right.id)
    end)
    return list
end

module.list_styles = function()
    return _clone_value(style_preset_list)
end

return module

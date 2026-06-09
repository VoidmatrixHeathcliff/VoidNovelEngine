local Common = require("application.framework.builtin_node_common")
local PresentationUIBridge = require("application.framework.presentation_ui_bridge")
local StyleManager = require("application.framework.style_manager")
local GlobalContext = Common.GlobalContext
local RuntimeFlowControl = require("application.framework.runtime_flow_control")

local imgui = Common.imgui
local BranchSelector = Common.BranchSelector
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local NodeDef =
{
    type_id = "show_choice_button",
    icon_id = "list-check-2",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示分支按钮",
    comment = "玩家点击对应选项后自动收起",
    category = "演出控制",
    category_order = 1,
    order = 15,
    menu_visible = true,
    script =
    {
        summary = "显示一组可点击的分支按钮，玩家点击后沿对应流程输出。",
        detail = "文本剧本中的 @choice 块最终会编译为该节点。choice_text_1 到 choice_text_5 对应最多五个可见选项，其余参数用于控制按钮样式与布局。",
        signature =
        {
            {name = "choice_text_1", pin = "choice_text_1", doc = "第 1 个分支按钮显示文本。"},
            {name = "choice_text_2", pin = "choice_text_2", doc = "第 2 个分支按钮显示文本。"},
            {name = "choice_text_3", pin = "choice_text_3", doc = "第 3 个分支按钮显示文本。"},
            {name = "choice_text_4", pin = "choice_text_4", doc = "第 4 个分支按钮显示文本。"},
            {name = "choice_text_5", pin = "choice_text_5", doc = "第 5 个分支按钮显示文本。"},
            {name = "font", pin = "font", doc = "分支按钮文本使用的字体资源。"},
            {name = "font_size", pin = "font_size", doc = "分支按钮文本字号。"},
            {name = "text_color", pin = "text_color", doc = "按钮默认文本颜色。"},
            {name = "hover_color", pin = "hover_color", doc = "鼠标悬停选项时的高亮颜色。"},
            {name = "background_color", pin = "background_color", doc = "按钮背景颜色。"},
            {name = "border_color", pin = "border_color", doc = "按钮边框颜色。"},
            {name = "button_spacing", pin = "button_spacing", doc = "多行按钮之间的垂直间距。"},
            {name = "button_padding", pin = "button_padding", doc = "按钮内部左右与上下留白。"},
            {name = "bottom_distance", pin = "bottom_distance", doc = "按钮组距屏幕底部的距离。"},
            {name = "minimum_width", pin = "minimum_width", doc = "单个按钮允许的最小宽度。"},
        },
    },
}

local object_id <const> = "bp-choice-button"

local function _get_style_reference(binding, type_id)
    if type(binding) ~= "table" then
        return nil, false
    end

    local value, ok = StyleManager.try_get_raw_value(binding.domain, binding.field, type_id)
    if ok then
        return value, true
    end
    return nil, false
end

local function _get_input_reference(node, key, type_id)
    local pin = node and node.find_input_pin and node:find_input_pin(key) or nil
    if not pin or not pin.get_reference then
        return nil
    end

    if pin._linked_pin_id then
        return pin:get_reference()
    end

    local binding = pin.get_style_binding and pin:get_style_binding() or nil
    if not binding then
        return pin:get_reference()
    end

    local local_reference = pin:get_reference()
    if pin.has_style_local_override and pin:has_style_local_override() then
        return local_reference
    end

    local style_reference, found_style_reference = _get_style_reference(binding, type_id)
    if found_style_reference then
        return style_reference
    end
    return local_reference
end

local function _get_style_background_image()
    local value, ok = _get_style_reference(
    {
        domain = "choice_button",
        field = "background_image",
    }, "texture")
    return ok and value or nil
end

local function _can_save_choice_button_now(node, scene)
    if node._ui_backend_active then
        local instance = scene and scene.find_ui_instance and scene:find_ui_instance(object_id) or nil
        if not instance then
            return false, "当前选项界面尚未创建完成"
        end
        return true
    end

    local choice_button = scene and scene.find_object and scene:find_object(object_id) or nil
    if not choice_button then
        return false, "当前选项对象尚未创建完成"
    end
    return true
end

return Common.make_definition(NodeDef, function(ctx)
    local convert_color = NodeRuntimeHelper.convert_imvec4_to_raylib_color
    local node = ctx:create_base_node()
    local builder = ctx.builder
    local choice_text_key_list =
    {
        "choice_text_1",
        "choice_text_2",
        "choice_text_3",
        "choice_text_4",
        "choice_text_5",
    }
    local choice_route_key_list =
    {
        "choice_1",
        "choice_2",
        "choice_3",
        "choice_4",
        "choice_5",
    }

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = choice_text_key_list[1], type_id = "string", name = "分支文本1", options = {width_input = 100}})
    builder:add_input({key = choice_text_key_list[2], type_id = "string", name = "分支文本2", options = {width_input = 100}})
    builder:add_input({key = choice_text_key_list[3], type_id = "string", name = "分支文本3", options = {width_input = 100}})
    builder:add_input({key = choice_text_key_list[4], type_id = "string", name = "分支文本4", options = {width_input = 100}})
    builder:add_input({key = choice_text_key_list[5], type_id = "string", name = "分支文本5", options = {width_input = 100}})
    builder:add_input({key = "font", type_id = "font", name = "字体", default_factory = Common.default_font_reference, style_binding = {domain = "choice_button", field = "font"}})
    builder:add_input({key = "font_size", type_id = "int", name = "字号", options = {width_input = 100}, default = 25, style_binding = {domain = "choice_button", field = "font_size"}})
    builder:add_input({
        key = "text_color",
        type_id = "color",
        name = "默认颜色",
        options = {full_edit = false},
        style_binding = {domain = "choice_button", field = "text_color"},
        default_factory = function()
            return imgui.ImColor(255, 255, 255, 195).value
        end,
    })
    builder:add_input({
        key = "hover_color",
        type_id = "color",
        name = "高亮颜色",
        options = {full_edit = false},
        style_binding = {domain = "choice_button", field = "hover_color"},
        default_factory = function()
            return imgui.ImColor(104, 163, 68, 225).value
        end,
    })
    builder:add_input({
        key = "background_color",
        type_id = "color",
        name = "背景颜色",
        options = {full_edit = false},
        style_binding = {domain = "choice_button", field = "background_color"},
        default_factory = function()
            return imgui.ImColor(0, 0, 0, 175).value
        end,
    })
    builder:add_input({
        key = "border_color",
        type_id = "color",
        name = "边框颜色",
        options = {full_edit = false},
        style_binding = {domain = "choice_button", field = "border_color"},
        default_factory = function()
            return imgui.ImColor(95, 95, 95, 175).value
        end,
    })
    builder:add_input({key = "button_spacing", type_id = "int", name = "按钮间隔", default = 20, style_binding = {domain = "choice_button", field = "button_spacing"}})
    builder:add_input({
        key = "button_padding",
        type_id = "vector2",
        name = "按钮内边距",
        options = {width_input = 100},
        style_binding = {domain = "choice_button", field = "button_padding"},
        default_factory = function()
            return imgui.ImVec2(100, 12)
        end,
    })
    builder:add_input({key = "bottom_distance", type_id = "float", name = "屏幕底部距离", default = 150, style_binding = {domain = "choice_button", field = "bottom_distance"}})
    builder:add_input({key = "minimum_width", type_id = "float", name = "按钮最小宽度", default = 400, style_binding = {domain = "choice_button", field = "minimum_width"}})
    builder:add_output({key = choice_route_key_list[1], type_id = "flow", name = "分支1"})
    builder:add_output({key = choice_route_key_list[2], type_id = "flow", name = "分支2"})
    builder:add_output({key = choice_route_key_list[3], type_id = "flow", name = "分支3"})
    builder:add_output({key = choice_route_key_list[4], type_id = "flow", name = "分支4"})
    builder:add_output({key = choice_route_key_list[5], type_id = "flow", name = "分支5"})

    node._ui_backend_active = false

    node.on_execute = function(self, scene)
        local font_size = NodeRuntimeHelper.check_int(self, "font_size")
        if font_size < 1 then
            NodeRuntimeHelper.abort(self, "无效的字号输入")
        end

        self._ui_backend_active = false

        local text_values = {}
        for _, key in ipairs(choice_text_key_list) do
            text_values[key] = NodeRuntimeHelper.check_string(self, key)
        end

        local last_text_key_index = 1
        for index = #choice_text_key_list, 1, -1 do
            if #text_values[choice_text_key_list[index]] ~= 0 then
                last_text_key_index = index
                break
            end
        end

        local text_list = {}
        for index = 1, last_text_key_index do
            local text = text_values[choice_text_key_list[index]]
            if #text == 0 then
                text = " "
            end
            table.insert(text_list, text)
        end

        if PresentationUIBridge.is_enabled() and scene and scene.open_ui then
            local choice_list = {}
            for index, text in ipairs(text_list) do
                choice_list[index] =
                {
                    id = choice_route_key_list[index],
                    text = text,
                }
            end

            local instance, err = PresentationUIBridge.open_choice_button(scene,
            {
                instance_id = object_id,
                choice_list = choice_list,
                font = _get_input_reference(self, "font", "font"),
                font_size = font_size,
                text_color = NodeRuntimeHelper.check_color(self, "text_color"),
                hover_color = NodeRuntimeHelper.check_color(self, "hover_color"),
                background_color = NodeRuntimeHelper.check_color(self, "background_color"),
                background_image = _get_style_background_image(),
                border_color = NodeRuntimeHelper.check_color(self, "border_color"),
                button_spacing = NodeRuntimeHelper.check_int(self, "button_spacing"),
                button_padding = NodeRuntimeHelper.check_vector2(self, "button_padding"),
                bottom_distance = NodeRuntimeHelper.check_float(self, "bottom_distance"),
                minimum_width = NodeRuntimeHelper.check_float(self, "minimum_width"),
                on_event = function(event)
                    if type(event) ~= "table" or event.kind ~= "click" or type(event.payload) ~= "table" then
                        return
                    end
                    local route_key = tostring(event.payload.event_name or "")
                    if route_key ~= "" then
                        RuntimeFlowControl.capture_before_transition(
                            GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil,
                            {
                                source = "ui_action",
                                reason = "choice_select",
                                label = "选项分支选择",
                            })
                        NodeRuntimeHelper.execute_next_node(self, route_key)
                    end
                end,
            })
            if not instance then
                NodeRuntimeHelper.abort(self, string.format("无法打开 UI 选项列表：%s", tostring(err or "未知错误")))
            end
            self._ui_backend_active = true
            NodeRuntimeHelper.commit_full_slice(self,
            {
                kind = "choice_wait",
                label = "等待玩家选择",
                node_id = self._id and self._id:get() or nil,
                node_title = self._title,
            })
            return
        end

        local choice_button = scene:find_object(object_id)
        if not choice_button then
            choice_button = BranchSelector.new()
            scene:add_object(choice_button, object_id, 90)
        end

        local font = NodeRuntimeHelper.check_resource(self, "font", "font")
        choice_button:set_style(
            NodeRuntimeHelper.check_int(self, "button_spacing"),
            NodeRuntimeHelper.check_vector2(self, "button_padding"),
            NodeRuntimeHelper.check_float(self, "bottom_distance"),
            NodeRuntimeHelper.check_float(self, "minimum_width"),
            font,
            font_size,
            convert_color(NodeRuntimeHelper.check_color(self, "text_color")),
            convert_color(NodeRuntimeHelper.check_color(self, "hover_color")),
            convert_color(NodeRuntimeHelper.check_color(self, "background_color")),
            convert_color(NodeRuntimeHelper.check_color(self, "border_color")),
            _get_style_background_image())

        choice_button:set_text(text_list)
        choice_button:set_callback(function(idx_clicked)
            NodeRuntimeHelper.execute_next_node(self, choice_route_key_list[idx_clicked])
        end)
        NodeRuntimeHelper.commit_full_slice(self,
        {
            kind = "choice_wait",
            label = "等待玩家选择",
            node_id = self._id and self._id:get() or nil,
            node_title = self._title,
        })
    end

    node.can_save_now = function(self, scene, runtime)
        return _can_save_choice_button_now(self, scene)
    end

    node.collect_runtime_save_state = function(self, scene, runtime)
        local ok = _can_save_choice_button_now(self, scene)
        if ok ~= true then
            return nil
        end

        return
        {
            resume_mode = "reexecute",
            managed_object_ids = self._ui_backend_active and {} or {object_id},
            managed_ui_instance_ids = self._ui_backend_active and {object_id} or {},
        }
    end

    return node
end)

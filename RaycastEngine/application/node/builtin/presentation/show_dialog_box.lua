local Common = require("application.framework.builtin_node_common")
local PresentationUIBridge = require("application.framework.presentation_ui_bridge")
local RuntimeLayout = require("application.framework.runtime_layout_context")
local StyleManager = require("application.framework.style_manager")

local imgui = Common.imgui
local Billboard = Common.Billboard
local NodeRuntimeHelper = Common.NodeRuntimeHelper

local function _default_dialog_position()
    return imgui.ImVec2(140, 760)
end

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

local function _get_resolved_input_reference(node, key, type_id)
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

    local policy = binding.policy or "linked_or_style_then_pin"
    local local_reference = pin:get_reference()
    if pin.has_style_local_override and pin:has_style_local_override() then
        return local_reference
    end
    if policy == "pin_then_style" then
        if local_reference ~= nil then
            return local_reference
        end
        local style_reference, found_style_reference = _get_style_reference(binding, type_id)
        return found_style_reference and style_reference or local_reference
    end

    local style_reference, found_style_reference = _get_style_reference(binding, type_id)
    if found_style_reference then
        return style_reference
    end
    if policy == "style_only_optional" then
        return nil
    end
    return local_reference
end

local function _get_style_background_image()
    local value, ok = _get_style_reference(
    {
        domain = "dialog_box",
        field = "background_image",
    }, "texture")
    return ok and value or nil
end

local function _build_dialog_box_save_state(node)
    return
    {
        layout_schema_version = 2,
        design_width = 1920,
        design_height = 1080,
        name = NodeRuntimeHelper.check_string(node, "role_text"),
        dialogue = NodeRuntimeHelper.check_string(node, "dialogue_text"),
        x = NodeRuntimeHelper.check_vector2(node, "position").x,
        y = NodeRuntimeHelper.check_vector2(node, "position").y,
        width = NodeRuntimeHelper.check_float(node, "width"),
        role_font_reference = _get_resolved_input_reference(node, "role_font", "font"),
        dialogue_font_reference = _get_resolved_input_reference(node, "dialogue_font", "font"),
        role_font_size = NodeRuntimeHelper.check_int(node, "role_font_size"),
        dialogue_font_size = NodeRuntimeHelper.check_int(node, "dialogue_font_size"),
        role_color = NodeRuntimeHelper.convert_imvec4_to_color_table(NodeRuntimeHelper.check_color(node, "role_color")),
        dialogue_color = NodeRuntimeHelper.convert_imvec4_to_color_table(NodeRuntimeHelper.check_color(node, "dialogue_color")),
        background_color = NodeRuntimeHelper.convert_imvec4_to_color_table(NodeRuntimeHelper.check_color(node, "background_color")),
        background_image_reference = _get_style_background_image(),
    }
end

local function _can_save_dialog_box_now(node, scene, object_id)
    if NodeRuntimeHelper.check_bool(node, "wait_interaction") ~= true then
        return false, "当前对话框节点未处于等待互动状态"
    end

    if node._ui_backend_active then
        local instance = node._runtime_dialog_box and scene and scene.find_ui_instance and scene:find_ui_instance(node._runtime_dialog_box.id or object_id) or nil
        if not instance then
            return false, "当前对话框界面尚未创建完成"
        end
        if node._ui_fade_time > 0 and node._ui_fade_elapsed < node._ui_fade_time then
            return false, "当前对话框仍在淡入中"
        end
        return true
    end

    local dialog_box = scene and scene.find_object and scene:find_object(object_id) or nil
    if not dialog_box then
        return false, "当前对话框对象尚未创建完成"
    end
    if tonumber(dialog_box._progress) ~= 1 then
        return false, "当前对话框仍在淡入中"
    end
    return true
end

local NodeDef =
{
    type_id = "show_dialog_box",
    icon_id = "text-block",
    color = imgui.ImVec4(imgui.ImColor(0, 148, 200, 255).value),
    name = "显示对话框",
    comment = nil,
    category = "演出控制",
    category_order = 1,
    order = 11,
    menu_visible = true,
    script =
    {
        aliases = {"say", "dialog"},
        summary = "显示带角色名的对话框，并在需要时等待玩家推进。",
        detail = "role 与 text 是最常用的两个脚本参数，其余参数用于覆盖样式系统中的位置、字号、字体与颜色设置。执行后还会输出当前对话框对象，便于后续节点读取。",
        docs =
        {
            brief = "显示带角色名的对话框，并在需要时等待玩家推进。",
            description = [=[
默认情况下，[command set_style] 提供的大部分位置、字体、字号与颜色配置都会自动生效。
[b]role[/b] 与 [b]text[/b] 是最常用的两个脚本参数；其余参数通常只在需要临时覆盖样式时填写。
]=],
            usage =
            {
                '@say("...", "...")',
                '@say("...", "...", fade_time: 0.15)',
            },
            notes =
            {
                {kind = "tip", text = "最小写法通常只需要 role 与 text 两个参数。"},
                {kind = "warning", text = "覆盖 role_font 或 dialogue_font 前，请先确保字体资源存在且样式链路可用。"},
            },
            examples =
            {
                {
                    title = "最小写法",
                    language = "vns",
                    code = '@say("...", "...")',
                },
                {
                    title = "覆盖淡入时间",
                    language = "vns",
                    code = '@say("...", "...", fade_time: 0.15)',
                },
            },
            outputs =
            {
                {pin = "dialog_box", brief = "当前创建出的对话框对象。"},
            },
            see_also =
            {
                {kind = "command", target = "show_subtitle"},
                {kind = "command", target = "show_choice_button"},
            },
        },
        signature =
        {
            {name = "role", pin = "role_text", positional = true, required = true, aliases = {"name"}, doc = {brief = "对话框中显示的角色名文本。", examples = {'"..."'}}},
            {name = "text", pin = "dialogue_text", positional = true, required = true, aliases = {"dialogue"}, doc = {brief = "对话正文内容。", examples = {'"..."'}, value_hint = "任意字符串"}},
            {name = "position", pin = "position", doc = {brief = "对话框左上角位置，按设计坐标缩放到当前画布。"}},
            {name = "width", pin = "width", doc = {brief = "对话框宽度。"}},
            {name = "fade_time", pin = "fade_time", doc = {brief = "对话框淡入时间，单位为秒。", default = "1.0", value_hint = ">= 0", examples = {"fade_time: 0.15"}}},
            {name = "role_font", pin = "role_font", doc = {brief = "角色名使用的字体资源。"}},
            {name = "dialogue_font", pin = "dialogue_font", doc = {brief = "正文使用的字体资源。"}},
            {name = "role_font_size", pin = "role_font_size", doc = {brief = "角色名字号。"}},
            {name = "dialogue_font_size", pin = "dialogue_font_size", doc = {brief = "正文字号。"}},
            {name = "role_color", pin = "role_color", doc = {brief = "角色名颜色。"}},
            {name = "dialogue_color", pin = "dialogue_color", doc = {brief = "正文颜色。"}},
            {name = "background_color", pin = "background_color", doc = {brief = "对话框背景颜色。"}},
            {name = "wait", pin = "wait_interaction", aliases = {"wait_interaction"}, doc = {brief = "是否在文本显示完成后等待玩家互动再继续执行。", default = "true"}},
        },
        default_flow_output = "out",
    },
}

return Common.make_definition(NodeDef, function(ctx)
    local convert_color = NodeRuntimeHelper.convert_imvec4_to_sdl_color
    local node = ctx:create_base_node()
    local builder = ctx.builder

    builder:add_input({key = "in", type_id = "flow"})
    builder:add_input({key = "role_text", type_id = "string", name = "角色文本", options = {width_input = 100}})
    builder:add_input({key = "dialogue_text", type_id = "string", name = "内容文本", options = {width_input = 100}})
    builder:add_input({key = "position", type_id = "vector2", name = "位置", options = {width_input = 100}, default_factory = _default_dialog_position, style_binding = {domain = "dialog_box", field = "position"}})
    builder:add_input({key = "width", type_id = "float", name = "宽度", default = 1640, style_binding = {domain = "dialog_box", field = "width"}})
    builder:add_input({key = "fade_time", type_id = "float", name = "淡入时间", default = 0.2, style_binding = {domain = "dialog_box", field = "fade_time"}})
    builder:add_input({key = "role_font", type_id = "font", name = "角色字体", default_factory = Common.default_font_reference, style_binding = {domain = "dialog_box", field = "role_font"}})
    builder:add_input({key = "dialogue_font", type_id = "font", name = "内容字体", default_factory = Common.default_font_reference, style_binding = {domain = "dialog_box", field = "dialogue_font"}})
    builder:add_input({key = "role_font_size", type_id = "int", name = "角色字号", options = {width_input = 100}, default = 28, style_binding = {domain = "dialog_box", field = "role_font_size"}})
    builder:add_input({key = "dialogue_font_size", type_id = "int", name = "内容字号", options = {width_input = 100}, default = 25, style_binding = {domain = "dialog_box", field = "dialogue_font_size"}})
    builder:add_input({
        key = "role_color",
        type_id = "color",
        name = "角色颜色",
        options = {full_edit = false},
        style_binding = {domain = "dialog_box", field = "role_color"},
        default_factory = function()
            return imgui.ImVec4(1, 0.9, 0.65, 1)
        end,
    })
    builder:add_input({
        key = "dialogue_color",
        type_id = "color",
        name = "内容颜色",
        options = {full_edit = false},
        style_binding = {domain = "dialog_box", field = "dialogue_color"},
        default_factory = function()
            return imgui.ImVec4(0.96, 0.96, 0.96, 1)
        end,
    })
    builder:add_input({
        key = "background_color",
        type_id = "color",
        name = "背景颜色",
        options = {full_edit = false},
        style_binding = {domain = "dialog_box", field = "background_color"},
        default_factory = function()
            return imgui.ImVec4(0.06, 0.09, 0.13, 0.86)
        end,
    })
    builder:add_input({key = "wait_interaction", type_id = "bool", name = "等待互动", default = true})
    builder:add_output({key = "out", type_id = "flow"})
    builder:add_output({key = "dialog_box", type_id = "object", name = "对话框", options = {object_type = "dialog_box"}})

    local object_id <const> = string.format("dialog_box_%d", node._id:get())
    node._ui_backend_active = false
    node._runtime_dialog_box = nil
    node._ui_fade_time = 0
    node._ui_fade_elapsed = 0

    node.on_execute = function(self, scene)
        local role_text = NodeRuntimeHelper.check_string(self, "role_text")
        local dialogue_text = NodeRuntimeHelper.check_string(self, "dialogue_text")
        local position = NodeRuntimeHelper.check_vector2(self, "position")
        local width = NodeRuntimeHelper.check_float(self, "width")
        local fade_time = NodeRuntimeHelper.check_float(self, "fade_time")
        local font_name = NodeRuntimeHelper.check_resource(self, "role_font", "font")
        local font_dialog = NodeRuntimeHelper.check_resource(self, "dialogue_font", "font")
        local font_size_name = NodeRuntimeHelper.check_int(self, "role_font_size")
        local font_size_dialog = NodeRuntimeHelper.check_int(self, "dialogue_font_size")
        if font_size_name < 1 or font_size_dialog < 1 then
            NodeRuntimeHelper.abort(self, "无效的字号输入")
        end

        self._ui_backend_active = false
        self._runtime_dialog_box = nil
        self._ui_fade_time = math.max(0, fade_time)
        self._ui_fade_elapsed = 0

        if PresentationUIBridge.is_enabled() and scene and scene.open_ui and scene.find_ui_instance then
            local instance, err = PresentationUIBridge.open_dialog_box(scene,
            {
                instance_id = object_id,
                role_text = role_text,
                dialogue_text = dialogue_text,
                position = position,
                width = width,
                role_font = _get_resolved_input_reference(self, "role_font", "font"),
                dialogue_font = _get_resolved_input_reference(self, "dialogue_font", "font"),
                role_font_size = font_size_name,
                dialogue_font_size = font_size_dialog,
                role_color = NodeRuntimeHelper.check_color(self, "role_color"),
                dialogue_color = NodeRuntimeHelper.check_color(self, "dialogue_color"),
                background_color = NodeRuntimeHelper.check_color(self, "background_color"),
                background_image = _get_style_background_image(),
            })
            if not instance then
                NodeRuntimeHelper.abort(self, string.format("无法打开 UI 对话框：%s", tostring(err or "未知错误")))
            end

            self._ui_backend_active = true
            self._runtime_dialog_box = instance
            PresentationUIBridge.set_instance_opacity(instance, self._ui_fade_time > 0 and 0 or 1)
            NodeRuntimeHelper.set_output(self, "dialog_box", instance)
            return
        end

        local dialog_box = Billboard.new(
            role_text,
            dialogue_text,
            position.x,
            position.y,
            width,
            font_name,
            font_dialog,
            convert_color(NodeRuntimeHelper.check_color(self, "role_color")),
            convert_color(NodeRuntimeHelper.check_color(self, "dialogue_color")),
            convert_color(NodeRuntimeHelper.check_color(self, "background_color")),
            fade_time < 0 and 0 or fade_time,
            _get_style_background_image(),
            RuntimeLayout.scale_font_size(font_size_name),
            RuntimeLayout.scale_font_size(font_size_dialog))
        dialog_box:set_runtime_save_data(_build_dialog_box_save_state(self))
        scene:add_object(dialog_box, object_id, 50)
        NodeRuntimeHelper.set_output(self, "dialog_box", dialog_box)
    end

    node.on_execute_update = function(self, scene, delta)
        if self._ui_backend_active then
            local instance = self._runtime_dialog_box and scene:find_ui_instance(self._runtime_dialog_box.id or object_id) or nil
            if instance then
                if self._ui_fade_time > 0 and self._ui_fade_elapsed < self._ui_fade_time then
                    self._ui_fade_elapsed = math.min(self._ui_fade_time, self._ui_fade_elapsed + delta)
                    PresentationUIBridge.set_instance_opacity(instance, self._ui_fade_elapsed / self._ui_fade_time)
                else
                    PresentationUIBridge.set_instance_opacity(instance, 1)
                end
            end

            local is_ready = self._ui_fade_time <= 0 or self._ui_fade_elapsed >= self._ui_fade_time
            if is_ready then
                if NodeRuntimeHelper.check_bool(self, "wait_interaction") then
                    NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
                else
                    NodeRuntimeHelper.execute_next_node(self, "out")
                end
            end
            return
        end

        local dialog_box = scene:find_object(object_id)
        if dialog_box and dialog_box._progress == 1 then
            if NodeRuntimeHelper.check_bool(self, "wait_interaction") then
                NodeRuntimeHelper.wait_interact_to_next_node(self, "out")
            else
                NodeRuntimeHelper.execute_next_node(self, "out")
            end
        end
    end

    node.can_save_now = function(self, scene, runtime)
        return _can_save_dialog_box_now(self, scene, object_id)
    end

    node.collect_runtime_save_state = function(self, scene, runtime)
        local ok = _can_save_dialog_box_now(self, scene, object_id)
        if ok ~= true then
            return nil
        end

        return
        {
            resume_mode = "interaction",
            output_ref = "out",
        }
    end

    return node
end)

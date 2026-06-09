local sdl = Engine.SDL
local rl = Engine.Raylib

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local Tween = require("application.framework.tween")
local Timer = require("application.framework.timer")
local TextWrapper = require("application.framework.text_wrapper")
local GlobalContext = require("application.framework.global_context")
local ResourcesManager = require("application.framework.resources_manager")
local RuntimeLayout = require("application.framework.runtime_layout_context")
local runtime_flow_control_module = false

local function _get_runtime_flow_control()
    if runtime_flow_control_module == false then
        runtime_flow_control_module = require("application.framework.runtime_flow_control")
    end
    return runtime_flow_control_module
end

local ChoiceButton = Class.define("ChoiceButton", GameObject)

local margin_y = 20
local padding_x = 100
local height_branch = 51
local dis_from_bottom = 150
local min_width_branch = 400

local color_idle = rl.Color(255, 255, 255, 195)
local color_active = rl.Color(104, 163, 68, 225)
local color_background = rl.Color(0, 0, 0, 175)
local color_border = rl.Color(95, 95, 95, 175)

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

local function _read_number_field(value, key)
    if type(value) ~= "table" and type(value) ~= "userdata" then
        return nil
    end
    local ok, result = pcall(function()
        return value[key]
    end)
    if not ok then
        return nil
    end
    return tonumber(result)
end

local function _clamp_color_channel(value, default)
    local number = tonumber(value)
    if number == nil then
        number = default or 0
    end
    number = math.floor(number + 0.5)
    if number < 0 then return 0 end
    if number > 255 then return 255 end
    return number
end

local function _to_color_table(value, fallback)
    local source = value
    if type(source) ~= "table" and type(source) ~= "userdata" then
        source = fallback
    end
    local r = _read_number_field(source, "r") or _read_number_field(source, "x")
    local g = _read_number_field(source, "g") or _read_number_field(source, "y")
    local b = _read_number_field(source, "b") or _read_number_field(source, "z")
    local a = _read_number_field(source, "a") or _read_number_field(source, "w")
    local normalized = r ~= nil and g ~= nil and b ~= nil and a ~= nil
        and r <= 1 and g <= 1 and b <= 1 and a <= 1
    if normalized then
        r, g, b, a = r * 255, g * 255, b * 255, a * 255
    end
    return
    {
        r = _clamp_color_channel(r, 255),
        g = _clamp_color_channel(g, 255),
        b = _clamp_color_channel(b, 255),
        a = _clamp_color_channel(a, 255),
    }
end

local function _to_runtime_color(value, fallback)
    local color = _to_color_table(value, fallback)
    return rl.Color(color.r, color.g, color.b, color.a)
end

local function _make_rect(x, y, w, h)
    return
    {
        x = x,
        y = y,
        w = w,
        h = h,
    }
end

local function _draw_texture_fill(texture, rect, alpha)
    if not texture or not rect or rect.w <= 0 or rect.h <= 0 then
        return false
    end

    local texture_width = math.max(1, tonumber(texture.width) or 1)
    local texture_height = math.max(1, tonumber(texture.height) or 1)
    local tint = rl.Color(255, 255, 255, math.floor(255 * math.max(0, math.min(1, tonumber(alpha) or 1)) + 0.5))
    rl.DrawTexturePro(
        texture,
        rl.Rectangle(0, 0, texture_width, texture_height),
        rl.Rectangle(rect.x, rect.y, rect.w, rect.h),
        rl.Vector2(0, 0),
        0,
        tint)
    return true
end

local function _resolve_background_texture(reference)
    return reference and ResourcesManager.find_texture(reference) or nil
end

local function _get_runtime_pointer_position(scene)
    if scene and scene.get_runtime_pointer_position then
        return scene:get_runtime_pointer_position()
    end

    return
    {
        x = -100000,
        y = -100000,
    }
end

local function _is_runtime_pointer_down(scene)
    if scene and scene.is_runtime_pointer_down then
        return scene:is_runtime_pointer_down()
    end

    return false
end

function ChoiceButton:ctor()
    Class.call_super(ChoiceButton, self, "ctor")
    self._on_select = nil
    self._list_branch = {}
    self._idx_clicked = -1
    self._width_branch = -1
    self._is_visible = false
    self._idx_next_shown_branch = 1
    self._margin_y = margin_y
    self._padding_x = padding_x
    self._padding_y = math.max(0, math.floor((height_branch - 25) * 0.5))
    self._height_branch = height_branch
    self._dis_from_bottom = dis_from_bottom
    self._min_width_branch = min_width_branch
    self._font = nil
    self._color_idle = color_idle
    self._color_active = color_active
    self._color_background = color_background
    self._color_border = color_border
    self._background_image_reference = nil
    self._background_texture = nil
    self._font_size = 25
    self._font_wrapper = nil
    self._save_state = nil
    self._timer_show_branch = Timer.new(0.1, function(timer)
        local branch = self._list_branch[self._idx_next_shown_branch]
        if branch then
            branch._is_visible = true
        end
        self._idx_next_shown_branch = self._idx_next_shown_branch + 1
        if self._idx_next_shown_branch > #self._list_branch then
            timer:pause()
        end
    end)
end

function ChoiceButton:_dispose_branch_list()
    for _, branch in ipairs(self._list_branch) do
        if branch._text and branch._text.dispose then
            branch._text:dispose()
            branch._text = nil
        end
    end
    self._list_branch = {}
end

function ChoiceButton:reset()
    self:_dispose_branch_list()
    self._idx_clicked = -1
    self._is_visible = true
    self._width_branch = -1
    self._idx_next_shown_branch = 1
    self._timer_show_branch:restart()
end

function ChoiceButton:set_runtime_save_data(data)
    if type(data) ~= "table" then
        return
    end
    self._save_state = _clone_value(data)
    self._save_state.color_idle = _to_color_table(self._save_state.color_idle, color_idle)
    self._save_state.color_active = _to_color_table(self._save_state.color_active, color_active)
    self._save_state.color_background = _to_color_table(self._save_state.color_background, color_background)
    self._save_state.color_border = _to_color_table(self._save_state.color_border, color_border)
    self._background_image_reference = _clone_value(self._save_state.background_image_reference)
    self._background_texture = _resolve_background_texture(self._background_image_reference)
end

function ChoiceButton:set_style(_margin_y, _padding, _dis_from_bottom, _min_width_branch,
        _font_wrapper, _font_size, _color_idle, _color_active, _color_background, _color_border, _background_image_reference)
    local raw_margin_y = tonumber(_margin_y) or margin_y
    local raw_padding_x = tonumber(_padding and _padding.x) or padding_x
    local raw_padding_y = tonumber(_padding and _padding.y) or math.max(0, (height_branch - (tonumber(_font_size) or 25)) * 0.5)
    local raw_bottom_distance = tonumber(_dis_from_bottom) or dis_from_bottom
    local raw_min_width = tonumber(_min_width_branch) or min_width_branch
    local raw_font_size = tonumber(_font_size) or 25

    self._margin_y = RuntimeLayout.round(RuntimeLayout.scale_y(raw_margin_y))
    self._padding_x = RuntimeLayout.round(RuntimeLayout.scale_x(raw_padding_x))
    self._padding_y = RuntimeLayout.round(RuntimeLayout.scale_y(raw_padding_y))
    self._font_size = RuntimeLayout.scale_font_size(raw_font_size)
    self._height_branch = self._padding_y * 2 + self._font_size
    self._dis_from_bottom = RuntimeLayout.round(RuntimeLayout.scale_y(raw_bottom_distance))
    self._min_width_branch = RuntimeLayout.round(RuntimeLayout.scale_x(raw_min_width))
    self._font_wrapper = _font_wrapper
    self._font = _font_wrapper:get(self._font_size)
    self._color_idle = _to_runtime_color(_color_idle, color_idle)
    self._color_active = _to_runtime_color(_color_active, color_active)
    self._color_background = _to_runtime_color(_color_background, color_background)
    self._color_border = _to_runtime_color(_color_border, color_border)
    self._background_image_reference = _clone_value(_background_image_reference)
    self._background_texture = _resolve_background_texture(self._background_image_reference)
    self._save_state = self._save_state or {}
    self._save_state.layout_schema_version = 2
    self._save_state.margin_y = raw_margin_y
    self._save_state.padding_x = raw_padding_x
    self._save_state.padding_y = raw_padding_y
    self._save_state.dis_from_bottom = raw_bottom_distance
    self._save_state.min_width_branch = raw_min_width
    self._save_state.font_size = raw_font_size
    self._save_state.color_idle = _to_color_table(self._color_idle, color_idle)
    self._save_state.color_active = _to_color_table(self._color_active, color_active)
    self._save_state.color_background = _to_color_table(self._color_background, color_background)
    self._save_state.color_border = _to_color_table(self._color_border, color_border)
    self._save_state.background_image_reference = _clone_value(self._background_image_reference)
end

function ChoiceButton:set_text(list)
    assert(#list ~= 0)
    self:reset()
    local choice_button = self
    local _, canvas_height = RuntimeLayout.get_canvas_size()
    local bottom_y = canvas_height - self._dis_from_bottom

    for i = #list, 1, -1 do
        local branch_y = bottom_y - self._height_branch * (#list - i + 1) - self._margin_y * (#list - i)
        local branch =
        {
            _idx = i,
            _tween = nil,
            _state = "in",
            _is_visible = false,
            _is_focused = false,
            _outline_progress = { val = 0 },
            _box_slide_progress = { val = 0 },
            _y = branch_y,
            _text = TextWrapper.new(self._font_wrapper or self._font, list[i], sdl.Color(255, 255, 255, 255), nil, self._font_size),

            hide = function(self)
                self._state = "out"
                self._tween = Tween.new(self._box_slide_progress, "val", 1, 0, 0.5, function()
                    self._is_visible = false
                end, "in")
            end,

            on_update = function(self, delta)
                if not self._is_visible then return end
                if self._tween then
                    self._tween:on_update(delta)
                end
                if self._state == "idle" then
                    local pointer = _get_runtime_pointer_position(choice_button._scene)
                    local current_canvas_width = RuntimeLayout.get_canvas_size()
                    local rect_x = (current_canvas_width - choice_button._width_branch) / 2
                    local is_focused = rl.CheckCollisionPointRec(rl.Vector2(pointer.x, pointer.y),
                        rl.Rectangle(rect_x, self._y, choice_button._width_branch, choice_button._height_branch))
                    if not self._is_focused and is_focused then
                        self._tween = Tween.new(self._outline_progress, "val", self._outline_progress.val, 1, 0.8, nil, "out")
                    elseif self._is_focused and not is_focused then
                        self._tween = Tween.new(self._outline_progress, "val", self._outline_progress.val, 0, 0.8, nil, "out")
                    end
                    self._is_focused = is_focused
                    if self._is_focused and _is_runtime_pointer_down(choice_button._scene) then
                        _get_runtime_flow_control().capture_before_transition(
                            GlobalContext.get_runtime_flow_document and GlobalContext.get_runtime_flow_document() or nil,
                            {
                                source = "ui_action",
                                reason = "choice_select",
                                label = "选项分支选择前",
                            })
                        for _, other_branch in ipairs(choice_button._list_branch) do
                            if other_branch ~= self then
                                other_branch:hide()
                            else
                                choice_button._idx_clicked = other_branch._idx
                            end
                        end
                        self._state = "out"
                        self._outline_progress.val = 1
                        self._tween = Tween.new(self, "_y", self._y, self._y - RuntimeLayout.scale_y(20), 0.8, function()
                            self._tween = Tween.new(self._box_slide_progress, "val", 1, 0, 0.5, function()
                                if choice_button._on_select then choice_button._on_select(choice_button._idx_clicked) end
                                self._is_visible = false
                                choice_button._is_visible = false
                            end, "out")
                        end, "out")
                    end
                end
            end,

            on_render = function(self)
                if not self._is_visible then return end
                local current_canvas_width = RuntimeLayout.get_canvas_size()
                local draw_width = choice_button._width_branch * self._box_slide_progress.val
                local rect_x = (current_canvas_width - draw_width) / 2
                local full_rect_x = (current_canvas_width - choice_button._width_branch) / 2
                local line_thickness = math.max(1, RuntimeLayout.round(RuntimeLayout.scale_uniform(4)))
                if choice_button._background_texture then
                    _draw_texture_fill(
                        choice_button._background_texture,
                        _make_rect(rect_x, self._y, draw_width, choice_button._height_branch),
                        self._box_slide_progress.val)
                else
                    rl.DrawRectangleV(rl.Vector2(rect_x, self._y),
                        rl.Vector2(draw_width, choice_button._height_branch),
                        rl.Color(choice_button._color_background.r, choice_button._color_background.g, choice_button._color_background.b, math.floor(choice_button._color_background.a * self._box_slide_progress.val)))
                end
                rl.DrawTextureV(self._text.texture, rl.Vector2(full_rect_x + (choice_button._width_branch - self._text.w) / 2, self._y + (choice_button._height_branch - self._text.h) / 2),
                    rl.Color(
                        math.floor(math.lerp(choice_button._color_idle.r, choice_button._color_active.r, self._outline_progress.val)),
                        math.floor(math.lerp(choice_button._color_idle.g, choice_button._color_active.g, self._outline_progress.val)),
                        math.floor(math.lerp(choice_button._color_idle.b, choice_button._color_active.b, self._outline_progress.val)),
                        math.floor(math.lerp(choice_button._color_idle.a, choice_button._color_active.a, self._outline_progress.val) * self._box_slide_progress.val)
                    )
                )
                rl.DrawLineEx(rl.Vector2(rect_x, self._y + choice_button._height_branch),
                    rl.Vector2(rect_x + draw_width, self._y + choice_button._height_branch), line_thickness, choice_button._color_border)
                if self._state == "idle" then
                    local outline_width = choice_button._width_branch * self._outline_progress.val
                    local outline_x = (current_canvas_width - outline_width) / 2
                    rl.DrawLineEx(rl.Vector2(outline_x, self._y + choice_button._height_branch),
                        rl.Vector2(outline_x + outline_width, self._y + choice_button._height_branch), line_thickness, choice_button._color_active)
                end
            end,
        }

        branch._tween = Tween.new(branch._box_slide_progress, "val", 0, 1, 0.5, function()
            branch._state = "idle"
        end, "out")

        table.insert(self._list_branch, branch)
        self._width_branch = math.max(self._width_branch, branch._text.w)
    end
    self._width_branch = math.max(self._width_branch + self._padding_x * 2, self._min_width_branch)
    self._save_state = self._save_state or {}
    self._save_state.text_list = _clone_value(list)
end

function ChoiceButton:set_callback(callback)
    self._on_select = callback
end

function ChoiceButton:on_update(delta)
    if not self._is_visible then return end
    self._timer_show_branch:on_update(delta)
    for _, branch in ipairs(self._list_branch) do
        branch:on_update(delta)
    end
end

function ChoiceButton:on_render()
    if not self._is_visible then return end
    for _, branch in ipairs(self._list_branch) do
        branch:on_render()
    end
end

function ChoiceButton:on_destroy()
    self:_dispose_branch_list()
    if self._timer_show_branch then
        self._timer_show_branch:destroy()
        self._timer_show_branch = nil
    end
end

function ChoiceButton:collect_save_state()
    local snapshot = _clone_value(self._save_state or {})
    snapshot.type = "ChoiceButton"
    snapshot.is_visible = self._is_visible == true
    snapshot.idx_clicked = self._idx_clicked
    snapshot.width_branch = self._width_branch
    snapshot.idx_next_shown_branch = self._idx_next_shown_branch
    return snapshot
end

function ChoiceButton:apply_save_state(state)
    local snapshot = type(state) == "table" and _clone_value(state) or {}
    self._save_state = _clone_value(snapshot)

    local font_wrapper = GlobalContext.font_wrapper_sdl
    local font_size = math.max(1, math.floor(tonumber(snapshot.font_size) or 25))
    local padding =
    {
        x = tonumber(snapshot.padding_x) or padding_x,
        y = tonumber(snapshot.padding_y) or math.max(0, math.floor((height_branch - font_size) * 0.5)),
    }

    self:set_style(
        tonumber(snapshot.margin_y) or margin_y,
        padding,
        tonumber(snapshot.dis_from_bottom) or dis_from_bottom,
        tonumber(snapshot.min_width_branch) or min_width_branch,
        font_wrapper,
        font_size,
        snapshot.color_idle or color_idle,
        snapshot.color_active or color_active,
        snapshot.color_background or color_background,
        snapshot.color_border or color_border,
        snapshot.background_image_reference)

    local text_list = snapshot.text_list or {}
    if #text_list > 0 then
        self:set_text(text_list)
    else
        self:_dispose_branch_list()
        self._is_visible = false
        self._width_branch = -1
    end
    self._is_visible = snapshot.is_visible == true
    self._idx_clicked = tonumber(snapshot.idx_clicked) or -1
    self._idx_next_shown_branch = tonumber(snapshot.idx_next_shown_branch) or (#self._list_branch + 1)
    self._timer_show_branch:pause()

    for _, branch in ipairs(self._list_branch) do
        branch._is_visible = self._is_visible
        branch._state = "idle"
        branch._outline_progress.val = 0
        branch._box_slide_progress.val = 1
        branch._tween = nil
    end
end

function ChoiceButton.create_from_save_state(state)
    local object = ChoiceButton.new()
    object:apply_save_state(state)
    return object
end

return ChoiceButton

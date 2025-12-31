local GameObject = require("application.framework.game_object")

local module = GameObject.new()

local sdl = Engine.SDL
local rl = Engine.Raylib

local Tween = require("application.framework.tween")
local Timer = require("application.framework.timer")
local TextWrapper = require("application.framework.text_wrapper")
local ScreenManager = require("application.framework.screen_manager")

local on_select = nil
local list_branch = {}
local idx_clicked = -1
local width_branch = -1
local is_visible = false
local idx_next_shown_branch = 1

local timer_show_branch = Timer.new(0.1, function(timer)
    list_branch[idx_next_shown_branch]._is_visible = true
    idx_next_shown_branch = idx_next_shown_branch + 1
    if idx_next_shown_branch > #list_branch then
        timer:pause()
    end
end)

-- 分支按钮间隔外边距
local margin_y = 20
-- 分支按钮文本内边距
local padding_x = 100
-- 分支按钮高度
local heigth_branch = 51
-- 分支按钮最底部到屏幕下方距离
local dis_from_bottom = 150
-- 分支按钮最小宽度
local min_width_branch = 400

local font = nil
local color_idle = rl.Color(255, 255, 255, 195)
local color_active = rl.Color(104, 163, 68, 225)
local color_background = rl.Color(0, 0, 0, 175)
local color_border = rl.Color(95, 95, 95, 175)

local function reset()
    idx_clicked = -1
    list_branch = {}
    is_visible = true
    width_branch = -1
    idx_next_shown_branch = 1
    timer_show_branch:restart()
end

module.set_style = function(_margin_y, _padding, _dis_from_bottom, _min_width_branch, 
        _font_wrapper, _font_size, _color_idle, _color_active, _color_background, _color_border)
    margin_y = _margin_y
    padding_x = _padding.x
    heigth_branch = _padding.y * 2 + _font_size
    dis_from_bottom = _dis_from_bottom
    min_width_branch = _min_width_branch
    font = _font_wrapper:get(_font_size)
    color_idle = _color_idle
    color_active = _color_active
    color_background = _color_background
    color_border = _color_border

end

module.set_text = function(list)
    assert(#list ~= 0) 
    reset()
    for i = #list, 1, -1 do
        local branch = 
        {
            _idx = i,
            _tween = nil,
            _state = "in",
            _is_visible = false,
            _is_focused = false,
            _outline_progress = { val = 0 },
            _box_slide_progress = { val = 0 },
            _y = 1080 - dis_from_bottom - heigth_branch * (#list - i + 1) - margin_y * (#list - i + 1 - 1),
            _text = TextWrapper.new(font, list[i], sdl.Color(255, 255, 255, 255)),

            hide = function(self)
                self._state = "out"
                self._tween = Tween.new(self._box_slide_progress, "val", 1, 0, 0.5, function() 
                    self._is_visible = false
                end, "in")
            end,

            on_update = function(self, delta)
                if not self._is_visible then return end
                self._tween:on_update(delta)
                if self._state == "idle" then
                    local is_focused = rl.CheckCollisionPointRec(rl.Vector2(ScreenManager.get_mouse_pos()), 
                        rl.Rectangle((1920 - width_branch) / 2, self._y, width_branch, heigth_branch))
                    if not self._is_focused and is_focused then
                        self._tween = Tween.new(self._outline_progress, "val", self._outline_progress.val, 1, 0.8, nil, "out")
                    elseif self._is_focused and not is_focused then
                        self._tween = Tween.new(self._outline_progress, "val", self._outline_progress.val, 0, 0.8, nil, "out")
                    end
                    self._is_focused = is_focused
                    if self._is_focused and rl.IsMouseButtonDown(rl.MouseButton.LEFT) then
                        -- 隐藏其余分支，记录自身索引
                        for _, branch in ipairs(list_branch) do
                            if branch ~= self then
                                branch:hide()
                            else
                                idx_clicked = branch._idx
                            end
                        end
                        -- 设置动画：先上浮，后消失
                        self._state = "out"
                        self._outline_progress.val = 1
                        self._tween = Tween.new(self, "_y", self._y, self._y - 20, 0.8, function()
                            self._tween = Tween.new(self._box_slide_progress, "val", 1, 0, 0.5, function()
                                -- 当消失动画结束后，调用回调函数并设置所有内容不可见
                                if on_select then on_select(idx_clicked) end
                                self._is_visible = false
                                is_visible = false
                            end, "out")
                        end, "out")
                    end
                end
            end,

            on_render = function(self)
                if not self._is_visible then return end
                rl.DrawRectangleV(rl.Vector2((1920 - width_branch * self._box_slide_progress.val) / 2, self._y), 
                    rl.Vector2(width_branch * self._box_slide_progress.val, heigth_branch), 
                    rl.Color(color_background.r, color_background.g, color_background.b, math.floor(color_background.a * self._box_slide_progress.val)))
                rl.DrawTextureV(self._text.texture, rl.Vector2((1920 - self._text.w) / 2, self._y + (heigth_branch - self._text.h) / 2), 
                    rl.Color(
                        math.floor(math.lerp(color_idle.r, color_active.r, self._outline_progress.val)),
                        math.floor(math.lerp(color_idle.g, color_active.g, self._outline_progress.val)),
                        math.floor(math.lerp(color_idle.b, color_active.b, self._outline_progress.val)),
                        math.floor(math.lerp(color_idle.a, color_active.a, self._outline_progress.val) * self._box_slide_progress.val)
                    )
                )
                rl.DrawLineEx(rl.Vector2((1920 - width_branch * self._box_slide_progress.val) / 2, self._y + heigth_branch),
                    rl.Vector2((1920 + width_branch * self._box_slide_progress.val) / 2, self._y + heigth_branch), 4, color_border)
                if self._state == "idle" then
                    rl.DrawLineEx(rl.Vector2((1920 - width_branch * self._outline_progress.val) / 2, self._y + heigth_branch),
                        rl.Vector2((1920 + width_branch * self._outline_progress.val) / 2, self._y + heigth_branch), 4, color_active)
                end
            end,
        }

        branch._tween = Tween.new(branch._box_slide_progress, "val", 0, 1, 0.5, function() 
            branch._state = "idle"
        end, "out")

        table.insert(list_branch, branch)

        -- 此处先比较并记录最宽的文本内容长度
        width_branch = math.max(width_branch, branch._text.w)
    end

    -- 此时计算最终的分支按钮长度
    width_branch = math.max(width_branch + padding_x * 2, min_width_branch)
end

module.set_callback = function(callback)
    on_select = callback
end

module.on_update = function(self, delta)
    if not is_visible then return end
    timer_show_branch:on_update(delta)
    for _, v in ipairs(list_branch) do
        v:on_update(delta)
    end
end

module.on_render = function()
    if not is_visible then return end
    for _, v in ipairs(list_branch) do
        v:on_render()
    end
end

return module
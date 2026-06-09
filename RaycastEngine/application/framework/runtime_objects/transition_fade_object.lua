local rl = Engine.Raylib

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local RuntimeLayout = require("application.framework.runtime_layout_context")

local TransitionFadeObject = Class.define("TransitionFade", GameObject)

function TransitionFadeObject:ctor()
    Class.call_super(TransitionFadeObject, self, "ctor")
    self.alpha = 0
end

function TransitionFadeObject:on_render()
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    rl.DrawRectangle(0, 0, canvas_width, canvas_height, rl.Color(0, 0, 0, math.floor(255 * self.alpha)))
end

function TransitionFadeObject:on_fade_in_complete()
    self.alpha = 0
end

function TransitionFadeObject:on_fade_out_complete()
    self.alpha = 1
end

function TransitionFadeObject:collect_save_state()
    return
    {
        type = "TransitionFadeObject",
        alpha = self.alpha,
    }
end

function TransitionFadeObject:apply_save_state(state)
    local snapshot = type(state) == "table" and state or {}
    self.alpha = tonumber(snapshot.alpha) or 0
end

function TransitionFadeObject.create_from_save_state(state)
    local object = TransitionFadeObject.new()
    object:apply_save_state(state)
    return object
end

return TransitionFadeObject

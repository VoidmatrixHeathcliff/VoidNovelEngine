local rl = Engine.Raylib

local Class = require("application.framework.class")
local GameObject = require("application.framework.game_object")
local ColorHelper = require("application.framework.color_helper")
local RuntimeLayout = require("application.framework.runtime_layout_context")

local LetterboxingObject = Class.define("Letterboxing", GameObject)

function LetterboxingObject:ctor()
    Class.call_super(LetterboxingObject, self, "ctor")
    self.progress = 0
    self.full_height = 0
end

function LetterboxingObject:on_render()
    local canvas_width, canvas_height = RuntimeLayout.get_canvas_size()
    local height = RuntimeLayout.scale_y(self.full_height) * self.progress
    local rect = rl.Rectangle(0, 0, canvas_width, height)
    rl.DrawRectangleRec(rect, ColorHelper.BLACK)
    rect.y = canvas_height - rect.height
    rl.DrawRectangleRec(rect, ColorHelper.BLACK)
end

function LetterboxingObject:on_show_complete()
    self.progress = 1
end

function LetterboxingObject:on_hide_complete()
    self.progress = 0
end

function LetterboxingObject:collect_save_state()
    return
    {
        type = "LetterboxingObject",
        progress = self.progress,
        full_height = self.full_height,
        layout_schema_version = 2,
        design_width = 1920,
        design_height = 1080,
    }
end

function LetterboxingObject:apply_save_state(state)
    local snapshot = type(state) == "table" and state or {}
    self.progress = tonumber(snapshot.progress) or 0
    self.full_height = tonumber(snapshot.full_height) or 0
end

function LetterboxingObject.create_from_save_state(state)
    local object = LetterboxingObject.new()
    object:apply_save_state(state)
    return object
end

return LetterboxingObject

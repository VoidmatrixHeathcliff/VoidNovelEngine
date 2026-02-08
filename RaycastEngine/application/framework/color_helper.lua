local module = {}

local rl = Engine.Raylib
local imgui = Engine.ImGUI

module.LIGHTGRAY = rl.Color(200, 200, 200, 255)
module.GRAY = rl.Color(130, 130, 130, 255)
module.DARKGRAY = rl.Color(80, 80, 80, 255)
module.YELLOW = rl.Color(253, 249, 0, 255)
module.GOLD = rl.Color(255, 203, 0, 255)
module.ORANGE = rl.Color(255, 161, 0, 255)
module.PINK = rl.Color(255, 109, 194, 255)
module.RED = rl.Color(230, 41, 55, 255)
module.MAROON = rl.Color(190, 33, 55, 255)
module.GREEN = rl.Color(0, 228, 48, 255)
module.LIME = rl.Color(0, 158, 47, 255)
module.DARKGREEN = rl.Color(0, 117, 44, 255)
module.SKYBLUE = rl.Color(102, 191, 255, 255)
module.BLUE = rl.Color(0, 121, 241, 255)
module.DARKBLUE = rl.Color(0, 82, 172, 255)
module.PURPLE = rl.Color(200, 122, 255, 255)
module.VIOLET = rl.Color(135, 60, 190, 255)
module.DARKPURPLE = rl.Color(112, 31, 126, 255)
module.BEIGE = rl.Color(211, 176, 131, 255)
module.BROWN = rl.Color(127, 106, 79, 255)
module.DARKBROWN = rl.Color(76, 63, 47, 255)
module.WHITE = rl.Color(255, 255, 255, 255)
module.BLACK = rl.Color(0, 0, 0, 255)
module.BLANK = rl.Color(0, 0, 0, 0)
module.MAGENTA = rl.Color(255, 0, 255, 255)
module.RAYWHITE = rl.Color(245, 245, 245, 255)

module.IMGUI_WHITE = imgui.ImVec4(imgui.ImColor(255, 255, 255, 255).value)

module.AssetTypeColorPool = 
{
    font = imgui.ImVec4(imgui.ImColor(192, 198, 201, 255).value),
    audio = imgui.ImVec4(imgui.ImColor(0, 149, 217, 255).value),
    video = imgui.ImVec4(imgui.ImColor(2, 135, 96, 255).value),
    shader = imgui.ImVec4(imgui.ImColor(188, 100, 164, 255).value),
    texture = imgui.ImVec4(imgui.ImColor(228, 158, 97, 255).value),
}

module.ValueTypeColorPool = 
{
    vector2 = imgui.ImVec4(imgui.ImColor(200, 195, 245, 255).value),
    color = imgui.ImVec4(imgui.ImColor(255, 180, 188, 255).value),
    string = imgui.ImVec4(imgui.ImColor(252, 200, 0, 255).value),
    int = imgui.ImVec4(imgui.ImColor(0, 164, 151, 255).value),
    float = imgui.ImVec4(imgui.ImColor(30, 80, 162, 255).value),
    bool = imgui.ImVec4(imgui.ImColor(200, 73, 80, 255).value),
}

return module
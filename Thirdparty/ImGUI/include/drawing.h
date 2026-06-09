# pragma once
# include <imgui.h>

namespace ax {
namespace Drawing {

enum class IconType: ImU32 { Flow, Circle, Square, Grid, RoundSquare, Diamond };

void DrawIcon(ImDrawList* drawList, const ImVec2& a, const ImVec2& b, IconType type, bool filled, ImU32 color, ImU32 innerColor);
float GetIconVisualRightPadding(const ImVec2& size, IconType type, bool filled);

} // namespace Drawing
} // namespace ax

#include "module_imgui_ext.h"

#include <vector>
#include <imgui_internal.h>

#include <algorithm>

static inline ImRect ImGui_GetItemRect()
{
    return ImRect(ImGui::GetItemRectMin(), ImGui::GetItemRectMax());
}

static inline ImRect ImRect_Expanded(const ImRect& rect, float x, float y)
{
    auto result = rect;
    result.Min.x -= x;
    result.Min.y -= y;
    result.Max.x += x;
    result.Max.y += y;
    return result;
}

void ImGUI_NodeEditor_AddNodeHeaderBackground(ax::NodeEditor::NodeId id, ImTextureID texture, const ImVec2& size_texture, const ImVec4& color, const ImVec2& min_rect, const ImVec2& max_rect)
{
	auto alpha = static_cast<int>(255 * ImGui::GetStyle().Alpha);
    const auto halfBorderWidth = ax::NodeEditor::GetStyle().NodeBorderWidth * 0.5f;

	auto drawList = ax::NodeEditor::GetNodeBackgroundDrawList(id);
	auto headerColor = IM_COL32(0, 0, 0, alpha) | (ImColor(color) & IM_COL32(255, 255, 255, 0));
	if ((max_rect.x > min_rect.x) && (max_rect.y > min_rect.y) && (ImTextureID)texture)
	{
		auto uv = ImVec2(
			std::clamp((max_rect.x - min_rect.x) / (float)(6.0f * size_texture.x), 0.0f, 1.0f),
            std::clamp((max_rect.y - min_rect.y) / (float)(6.0f * size_texture.y), 0.0f, 1.0f));

		drawList->AddImageRounded((ImTextureID)texture,
			ImVec2(min_rect.x + halfBorderWidth, min_rect.y + halfBorderWidth), 
            ImVec2(max_rect.x - halfBorderWidth, max_rect.y), ImVec2(0.0f, 0.0f), uv,
			headerColor, ax::NodeEditor::GetStyle().NodeRounding, ImDrawFlags_RoundCornersTop);

		drawList->AddLine(
			ImVec2(min_rect.x, max_rect.y),
			ImVec2(max_rect.x, max_rect.y),
			ImColor(255, 255, 255, 96 * alpha / (3 * 255)), 1.0f);
	}
}

void ImGUI_NodeEditor_Comment(ax::NodeEditor::NodeId id, const char* name, const ImVec2& size)
{
    const float commentAlpha = 0.75f;

    ImGui::PushStyleVar(ImGuiStyleVar_Alpha, commentAlpha);
    ax::NodeEditor::PushStyleColor(ax::NodeEditor::StyleColor_NodeBg, ImColor(255, 255, 255, 64));
    ax::NodeEditor::PushStyleColor(ax::NodeEditor::StyleColor_NodeBorder, ImColor(255, 255, 255, 64));
    ax::NodeEditor::BeginNode(id);
    ImGui::TextUnformatted(name);
    ax::NodeEditor::Group(size);
    ax::NodeEditor::EndNode();
    ax::NodeEditor::PopStyleColor(2);
    ImGui::PopStyleVar();

    if (ax::NodeEditor::BeginGroupHint(id))
    {
        auto bgAlpha = static_cast<int>(ImGui::GetStyle().Alpha * 255);

        auto min = ax::NodeEditor::GetGroupMin();

        ImGui::SetCursorScreenPos(ImVec2(min.x - (-8), min.y - (ImGui::GetTextLineHeightWithSpacing() + 4)));
        ImGui::BeginGroup();
        ImGui::TextUnformatted(name);
        ImGui::EndGroup();

        auto drawList = ax::NodeEditor::GetHintBackgroundDrawList();

        auto hintBounds = ImGui_GetItemRect();
        auto hintFrameBounds = ImRect_Expanded(hintBounds, 8, 4);

        drawList->AddRectFilled(
            hintFrameBounds.GetTL(),
            hintFrameBounds.GetBR(),
            IM_COL32(255, 255, 255, 64 * bgAlpha / 255), 4.0f);

        drawList->AddRect(
            hintFrameBounds.GetTL(),
            hintFrameBounds.GetBR(),
            IM_COL32(255, 255, 255, 128 * bgAlpha / 255), 4.0f);

        //ImGui::PopStyleVar();
    }
    ax::NodeEditor::EndGroupHint();
}

void ImGUI_NodeEditor_ShowAllNodeID()
{
    auto editorMin = ImGui::GetItemRectMin();
    auto editorMax = ImGui::GetItemRectMax();

    int nodeCount = ax::NodeEditor::GetNodeCount();
    std::vector<ax::NodeEditor::NodeId> orderedNodeIds;
    orderedNodeIds.resize(static_cast<size_t>(nodeCount));
    ax::NodeEditor::GetOrderedNodeIds(orderedNodeIds.data(), nodeCount);

    auto drawList = ImGui::GetWindowDrawList();
    drawList->PushClipRect(editorMin, editorMax);

    for (auto& nodeId : orderedNodeIds)
    {
        auto p0 = ax::NodeEditor::GetNodePosition(nodeId);
        auto size = ax::NodeEditor::GetNodeSize(nodeId);
        auto p1 = ImVec2(p0.x + size.x, p0.y + size.y);
        p0 = ax::NodeEditor::CanvasToScreen(p0);
        p1 = ax::NodeEditor::CanvasToScreen(p1);

        ImGuiTextBuffer builder;
        builder.appendf("#%d", nodeId);

        auto textSize = ImGui::CalcTextSize(builder.c_str());
        auto padding = ImVec2(2.0f, 2.0f);
        auto widgetSize = ImVec2(textSize.x + padding.x * 2, textSize.y + padding.y * 2);

        auto widgetPosition = ImVec2(p1.x, p0.y - widgetSize.y);
        auto p_max = ImVec2(widgetPosition.x + widgetSize.x, widgetPosition.y + widgetSize.y);

        drawList->AddRectFilled(widgetPosition, p_max, IM_COL32(100, 80, 80, 190), 3.0f, ImDrawFlags_RoundCornersAll);
        drawList->AddRect(widgetPosition, p_max, IM_COL32(200, 160, 160, 190), 3.0f, ImDrawFlags_RoundCornersAll);
        drawList->AddText(ImVec2(widgetPosition.x + padding.x, widgetPosition.y + padding.y), IM_COL32(255, 255, 255, 255), builder.c_str());
    }

    drawList->PopClipRect();
}
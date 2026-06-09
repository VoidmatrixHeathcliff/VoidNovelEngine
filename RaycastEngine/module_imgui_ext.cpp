#include "module_imgui_ext.h"

#include <SDL.h>
#include <vector>
#include <imgui_internal.h>
#include <imgui_impl_sdlrenderer2.h>
// Read NodeEditor runtime transitions from the internal context without forking third-party sources.
#define private public
#include <imgui_node_editor_internal.h>
#undef private

#include <algorithm>
#include <cmath>
#include <memory>

namespace ed = ax::NodeEditor::Detail;

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
    if (!texture || size_texture.x <= 0.0f || size_texture.y <= 0.0f)
        return;

    constexpr float kNodeHeaderOpacity = 0.94f;
	auto alpha = static_cast<int>(255 * ImGui::GetStyle().Alpha * std::clamp(color.w, 0.0f, 1.0f) * kNodeHeaderOpacity);
    const auto halfBorderWidth = ax::NodeEditor::GetStyle().NodeBorderWidth * 0.5f;

	auto drawList = ax::NodeEditor::GetNodeBackgroundDrawList(id);
    if (drawList == nullptr)
        return;
	auto headerColor = IM_COL32(0, 0, 0, alpha) | (ImColor(color) & IM_COL32(255, 255, 255, 0));
	if ((max_rect.x > min_rect.x) && (max_rect.y > min_rect.y))
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

bool ImGUI_NodeEditor_GetRuntimeState(ImGUI_NodeEditor_RuntimeState& state)
{
    auto* currentEditor = ax::NodeEditor::GetCurrentEditor();
    if (currentEditor == nullptr)
        return false;

    auto* editor = reinterpret_cast<ed::EditorContext*>(currentEditor);
    if (editor == nullptr)
        return false;

    const auto& view = editor->GetView();
    const auto canvasRect = editor->GetRect();
    const auto viewRect = editor->GetViewRect();

    state.is_focused = ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows);
    state.is_hovered = editor->IsHovered();
    state.is_hovered_without_overlap = editor->IsHoveredWithoutOverlapp();
    state.can_accept_user_input = editor->CanAcceptUserInput();
    state.has_current_action = editor->GetCurrentAction() != nullptr;
    state.has_live_animation = !editor->m_LiveAnimations.empty();
    state.is_navigating = editor->m_NavigateAction.m_IsActive || editor->m_NavigateAction.IsMovingOverEdge();
    state.is_suspended = editor->IsSuspended();
    state.hovered_node_id = static_cast<size_t>(editor->GetHoveredNode());
    state.hovered_pin_id = static_cast<size_t>(editor->GetHoveredPin());
    state.hovered_link_id = static_cast<size_t>(editor->GetHoveredLink());
    state.view_origin = view.Origin;
    state.view_scale = view.Scale;
    state.canvas_rect = ImVec4(canvasRect.Min.x, canvasRect.Min.y, canvasRect.Max.x, canvasRect.Max.y);
    state.view_rect = ImVec4(viewRect.Min.x, viewRect.Min.y, viewRect.Max.x, viewRect.Max.y);
    return true;
}

bool ImGUI_NodeEditor_SetViewRect(float min_x, float min_y, float max_x, float max_y)
{
    if (max_x <= min_x || max_y <= min_y)
        return false;

    auto* currentEditor = ax::NodeEditor::GetCurrentEditor();
    if (currentEditor == nullptr)
        return false;

    auto* editor = reinterpret_cast<ed::EditorContext*>(currentEditor);
    if (editor == nullptr)
        return false;

    const ImRect targetRect(ImVec2(min_x, min_y), ImVec2(max_x, max_y));
    editor->m_NavigateAction.StopNavigation();
    editor->m_NavigateAction.SetViewRect(targetRect);
    editor->m_Canvas.SetView(editor->m_NavigateAction.GetView());
    return true;
}

bool ImGUI_NodeEditor_NavigateToViewRect(float min_x, float min_y, float max_x, float max_y, float duration)
{
    if (max_x <= min_x || max_y <= min_y)
        return false;

    auto* currentEditor = ax::NodeEditor::GetCurrentEditor();
    if (currentEditor == nullptr)
        return false;

    auto* editor = reinterpret_cast<ed::EditorContext*>(currentEditor);
    if (editor == nullptr)
        return false;

    if (duration < 0.0f)
        duration = ax::NodeEditor::GetStyle().ScrollDuration;

    const ImRect targetRect(ImVec2(min_x, min_y), ImVec2(max_x, max_y));
    editor->m_NavigateAction.NavigateTo(
        targetRect,
        ed::NavigateAction::ZoomMode::Exact,
        duration,
        ed::NavigateAction::NavigationReason::Object);
    return true;
}

static void ImGUI_FlowViewCache_DestroyTexture(ImGUI_FlowViewCache* cache)
{
    if (cache == nullptr || cache->texture == nullptr)
        return;

    SDL_DestroyTexture(cache->texture);
    cache->texture = nullptr;
    cache->texture_width = 0;
    cache->texture_height = 0;
    cache->valid = false;
}

static bool ImGUI_FlowViewCache_EnsureTarget(ImGUI_FlowViewCache* cache, SDL_Renderer* renderer, const ImVec2& logicalSize, const ImVec2& framebufferScale)
{
    if (cache == nullptr || renderer == nullptr)
        return false;

    const float logicalWidth = std::max(1.0f, logicalSize.x);
    const float logicalHeight = std::max(1.0f, logicalSize.y);
    const float scaleX = framebufferScale.x > 0.0f ? framebufferScale.x : 1.0f;
    const float scaleY = framebufferScale.y > 0.0f ? framebufferScale.y : 1.0f;
    const int textureWidth = std::max(1, static_cast<int>(std::ceil(logicalWidth * scaleX)));
    const int textureHeight = std::max(1, static_cast<int>(std::ceil(logicalHeight * scaleY)));

    const bool canReuse =
        cache->texture != nullptr
        && cache->texture_width == textureWidth
        && cache->texture_height == textureHeight
        && std::fabs(cache->logical_width - logicalWidth) < 0.5f
        && std::fabs(cache->logical_height - logicalHeight) < 0.5f
        && std::fabs(cache->framebuffer_scale_x - scaleX) < 0.001f
        && std::fabs(cache->framebuffer_scale_y - scaleY) < 0.001f;

    if (canReuse)
        return true;

    ImGUI_FlowViewCache_DestroyTexture(cache);

    cache->texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_TARGET, textureWidth, textureHeight);
    if (cache->texture == nullptr)
        return false;

    SDL_SetTextureBlendMode(cache->texture, SDL_BLENDMODE_NONE);
    SDL_SetTextureScaleMode(cache->texture, SDL_ScaleModeNearest);
    cache->logical_width = logicalWidth;
    cache->logical_height = logicalHeight;
    cache->framebuffer_scale_x = scaleX;
    cache->framebuffer_scale_y = scaleY;
    cache->texture_width = textureWidth;
    cache->texture_height = textureHeight;
    cache->valid = false;
    return true;
}

static ImU32 ImGUI_FlowViewCache_GetWindowBgColor(ImGuiWindow* window)
{
    if (window == nullptr)
        return ImGui::GetColorU32(ImGuiCol_WindowBg);

    const bool useChildBg =
        (window->Flags & ImGuiWindowFlags_ChildWindow) != 0
        && (window->Flags & ImGuiWindowFlags_Popup) == 0
        && (window->Flags & ImGuiWindowFlags_Tooltip) == 0;

    return ImGui::GetColorU32(useChildBg ? ImGuiCol_ChildBg : ImGuiCol_WindowBg);
}

static ImU32 ImGUI_FlowViewCache_ResolveOpaqueBackdropColor()
{
    ImGuiWindow* window = ImGui::GetCurrentWindowRead();
    ImGuiWindow* backgroundWindow = window;

    while (backgroundWindow != nullptr && (backgroundWindow->Flags & ImGuiWindowFlags_NoBackground) != 0)
        backgroundWindow = backgroundWindow->ParentWindow;

    ImVec4 background = backgroundWindow != nullptr
        ? ImGui::ColorConvertU32ToFloat4(ImGUI_FlowViewCache_GetWindowBgColor(backgroundWindow))
        : ImGui::GetStyleColorVec4(ImGuiCol_WindowBg);

    // Docked document windows often use semi-transparent WindowBg over DockingEmptyBg.
    // Resolve that blend once here so the cached frame matches the live frame instead of
    // alpha-blending the same background twice through an offscreen texture.
    if (backgroundWindow != nullptr && backgroundWindow->DockIsActive && background.w < 0.999f)
    {
        const ImVec4 dockingBg = ImGui::GetStyleColorVec4(ImGuiCol_DockingEmptyBg);
        background.x = background.x * background.w + dockingBg.x * (1.0f - background.w);
        background.y = background.y * background.w + dockingBg.y * (1.0f - background.w);
        background.z = background.z * background.w + dockingBg.z * (1.0f - background.w);
    }

    background.w = 1.0f;
    return ImGui::ColorConvertFloat4ToU32(background);
}

ImGUI_FlowViewCache* ImGUI_FlowViewCache_Create()
{
    return new ImGUI_FlowViewCache();
}

void ImGUI_FlowViewCache_Destroy(ImGUI_FlowViewCache* cache)
{
    if (cache == nullptr)
        return;

    ImGUI_FlowViewCache_DestroyTexture(cache);
    delete cache;
}

void ImGUI_FlowViewCache_Invalidate(ImGUI_FlowViewCache* cache)
{
    if (cache == nullptr)
        return;

    cache->valid = false;
}

void ImGUI_FlowViewCache_ReleaseTarget(ImGUI_FlowViewCache* cache)
{
    ImGUI_FlowViewCache_DestroyTexture(cache);
}

bool ImGUI_FlowViewCache_IsValid(const ImGUI_FlowViewCache* cache)
{
    return cache != nullptr && cache->valid && cache->texture != nullptr;
}

bool ImGUI_FlowViewCache_CaptureCurrentWindow(ImGUI_FlowViewCache* cache, SDL_Renderer* renderer)
{
    if (cache == nullptr || renderer == nullptr || ImGui::GetCurrentContext() == nullptr)
        return false;

    ImDrawList* drawList = ImGui::GetWindowDrawList();
    if (drawList == nullptr)
        return false;

    const ImVec2 windowPos = ImGui::GetWindowPos();
    const ImVec2 windowSize = ImGui::GetWindowSize();
    if (windowSize.x <= 1.0f || windowSize.y <= 1.0f)
    {
        cache->valid = false;
        return false;
    }

    const ImVec2 framebufferScale = ImGui::GetIO().DisplayFramebufferScale;
    if (!ImGUI_FlowViewCache_EnsureTarget(cache, renderer, windowSize, framebufferScale))
        return false;

    std::unique_ptr<ImDrawList> snapshot(drawList->CloneOutput());
    if (!snapshot || snapshot->CmdBuffer.Size == 0 || snapshot->VtxBuffer.Size == 0 || snapshot->IdxBuffer.Size == 0)
    {
        cache->valid = false;
        return false;
    }

    for (ImDrawVert& vertex : snapshot->VtxBuffer)
    {
        vertex.pos.x -= windowPos.x;
        vertex.pos.y -= windowPos.y;
    }

    for (ImDrawCmd& command : snapshot->CmdBuffer)
    {
        if (command.UserCallback == nullptr)
        {
            command.ClipRect.x -= windowPos.x;
            command.ClipRect.y -= windowPos.y;
            command.ClipRect.z -= windowPos.x;
            command.ClipRect.w -= windowPos.y;
        }
    }

    ImDrawData drawData = {};
    drawData.Valid = true;
    drawData.DisplayPos = ImVec2(0.0f, 0.0f);
    drawData.DisplaySize = windowSize;
    drawData.FramebufferScale = ImVec2(
        framebufferScale.x > 0.0f ? framebufferScale.x : 1.0f,
        framebufferScale.y > 0.0f ? framebufferScale.y : 1.0f);
    drawData.AddDrawList(snapshot.get());

    SDL_Texture* previousTarget = SDL_GetRenderTarget(renderer);
    Uint8 oldR = 0;
    Uint8 oldG = 0;
    Uint8 oldB = 0;
    Uint8 oldA = 0;
    SDL_GetRenderDrawColor(renderer, &oldR, &oldG, &oldB, &oldA);
    const ImU32 clearColor = ImGUI_FlowViewCache_ResolveOpaqueBackdropColor();

    if (SDL_SetRenderTarget(renderer, cache->texture) != 0)
    {
        SDL_SetRenderDrawColor(renderer, oldR, oldG, oldB, oldA);
        return false;
    }

    SDL_SetRenderDrawColor(
        renderer,
        static_cast<Uint8>((clearColor >> IM_COL32_R_SHIFT) & 0xFF),
        static_cast<Uint8>((clearColor >> IM_COL32_G_SHIFT) & 0xFF),
        static_cast<Uint8>((clearColor >> IM_COL32_B_SHIFT) & 0xFF),
        255);
    SDL_RenderClear(renderer);
    ImGui_ImplSDLRenderer2_RenderDrawData(&drawData, renderer);
    SDL_SetRenderTarget(renderer, previousTarget);
    SDL_SetRenderDrawColor(renderer, oldR, oldG, oldB, oldA);
    cache->valid = true;
    return true;
}

bool ImGUI_FlowViewCache_DrawCurrentWindow(const ImGUI_FlowViewCache* cache)
{
    if (!ImGUI_FlowViewCache_IsValid(cache))
        return false;

    const ImVec2 windowPos = ImGui::GetWindowPos();
    const ImVec2 windowSize = ImGui::GetWindowSize();
    if (windowSize.x <= 1.0f || windowSize.y <= 1.0f)
        return false;

    ImGui::GetWindowDrawList()->AddImage(
        cache->texture,
        windowPos,
        ImVec2(windowPos.x + windowSize.x, windowPos.y + windowSize.y),
        ImVec2(0.0f, 0.0f),
        ImVec2(1.0f, 1.0f),
        IM_COL32_WHITE);
    return true;
}

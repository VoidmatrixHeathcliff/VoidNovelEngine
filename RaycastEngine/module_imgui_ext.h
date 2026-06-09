#pragma once

#ifndef IMGUI_DEFINE_MATH_OPERATORS
#define IMGUI_DEFINE_MATH_OPERATORS
#endif

#include <imgui.h>
#include <imgui_node_editor.h>

struct SDL_Renderer;
struct SDL_Texture;

struct ImGUI_NodeEditor_RuntimeState
{
    bool is_focused = false;
    bool is_hovered = false;
    bool is_hovered_without_overlap = false;
    bool can_accept_user_input = false;
    bool has_current_action = false;
    bool has_live_animation = false;
    bool is_navigating = false;
    bool is_suspended = false;
    size_t hovered_node_id = 0;
    size_t hovered_pin_id = 0;
    size_t hovered_link_id = 0;
    ImVec2 view_origin = ImVec2(0.0f, 0.0f);
    float view_scale = 1.0f;
    ImVec4 canvas_rect = ImVec4(0.0f, 0.0f, 0.0f, 0.0f);
    ImVec4 view_rect = ImVec4(0.0f, 0.0f, 0.0f, 0.0f);
};

struct ImGUI_FlowViewCache
{
    SDL_Texture* texture = nullptr;
    float logical_width = 0.0f;
    float logical_height = 0.0f;
    float framebuffer_scale_x = 1.0f;
    float framebuffer_scale_y = 1.0f;
    int texture_width = 0;
    int texture_height = 0;
    bool valid = false;
};

void ImGUI_NodeEditor_AddNodeHeaderBackground(ax::NodeEditor::NodeId id, ImTextureID texture, const ImVec2& size_texture, const ImVec4& color, const ImVec2& min_rect, const ImVec2& max_rect);

void ImGUI_NodeEditor_Comment(ax::NodeEditor::NodeId id, const char* name, const ImVec2& size);

void ImGUI_NodeEditor_ShowAllNodeID();

bool ImGUI_NodeEditor_GetRuntimeState(ImGUI_NodeEditor_RuntimeState& state);
bool ImGUI_NodeEditor_SetViewRect(float min_x, float min_y, float max_x, float max_y);
bool ImGUI_NodeEditor_NavigateToViewRect(float min_x, float min_y, float max_x, float max_y, float duration);

ImGUI_FlowViewCache* ImGUI_FlowViewCache_Create();
void ImGUI_FlowViewCache_Destroy(ImGUI_FlowViewCache* cache);
void ImGUI_FlowViewCache_Invalidate(ImGUI_FlowViewCache* cache);
void ImGUI_FlowViewCache_ReleaseTarget(ImGUI_FlowViewCache* cache);
bool ImGUI_FlowViewCache_IsValid(const ImGUI_FlowViewCache* cache);
bool ImGUI_FlowViewCache_CaptureCurrentWindow(ImGUI_FlowViewCache* cache, SDL_Renderer* renderer);
bool ImGUI_FlowViewCache_DrawCurrentWindow(const ImGUI_FlowViewCache* cache);

#pragma once

#include <imgui_node_editor.h>

void ImGUI_NodeEditor_AddNodeHeaderBackground(ax::NodeEditor::NodeId id, ImTextureID texture, const ImVec2& size_texture, const ImVec4& color, const ImVec2& min_rect, const ImVec2& max_rect);

void ImGUI_NodeEditor_Comment(ax::NodeEditor::NodeId id, const char* name, const ImVec2& size);

void ImGUI_NodeEditor_ShowAllNodeID();
/**********************************************************************************************
*
*   raylibExtras * Utilities and Shared Components for Raylib
*
*   rlImGui * basic ImGui integration
*
*   LICENSE: ZLIB
*
*   Copyright (c) 2024 Jeffery Myers
*
*   Permission is hereby granted, free of charge, to any person obtaining a copy
*   of this software and associated documentation files (the "Software"), to deal
*   in the Software without restriction, including without limitation the rights
*   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
*   copies of the Software, and to permit persons to whom the Software is
*   furnished to do so, subject to the following conditions:
*
*   The above copyright notice and this permission notice shall be included in all
*   copies or substantial portions of the Software.
*
*   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
*   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
*   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
*   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
*   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
*   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*   SOFTWARE.
*
**********************************************************************************************/
#include "rlImGui.h"

#include "imgui_impl_raylib.h"

#include "raylib.h"
#include "rlgl.h"

#include "imgui.h"

#include <math.h>
#include <map>
#include <limits>
#include <cstdint>

#ifndef NO_FONT_AWESOME
#include "extras/FA6FreeSolidFontData.h"
#endif

static ImGuiMouseCursor CurrentMouseCursor = ImGuiMouseCursor_COUNT;
static MouseCursor MouseCursorMap[ImGuiMouseCursor_COUNT];

ImGuiContext* GlobalContext = nullptr;

static std::map<KeyboardKey, ImGuiKey> RaylibKeyMap;

static bool LastFrameFocused = false;

static bool LastControlPressed = false;
static bool LastShiftPressed = false;
static bool LastAltPressed = false;
static bool LastSuperPressed = false;

// internal only functions
bool rlImGuiIsControlDown() { return IsKeyDown(KEY_RIGHT_CONTROL) || IsKeyDown(KEY_LEFT_CONTROL); }
bool rlImGuiIsShiftDown() { return IsKeyDown(KEY_RIGHT_SHIFT) || IsKeyDown(KEY_LEFT_SHIFT); }
bool rlImGuiIsAltDown() { return IsKeyDown(KEY_RIGHT_ALT) || IsKeyDown(KEY_LEFT_ALT); }
bool rlImGuiIsSuperDown() { return IsKeyDown(KEY_RIGHT_SUPER) || IsKeyDown(KEY_LEFT_SUPER); }

struct ImGui_ImplRaylib_Data
{
};

ImGui_ImplRaylib_Data* ImGui_ImplRaylib_GetBackendData()
{
    return ImGui::GetCurrentContext() ? static_cast<ImGui_ImplRaylib_Data*>(ImGui::GetPlatformIO().Renderer_RenderState) : nullptr;
}

void ImGui_ImplRaylib_CreateBackendData()
{
    if (!ImGui::GetCurrentContext() || ImGui::GetPlatformIO().Renderer_RenderState)
        return;

    ImGui::GetPlatformIO().Renderer_RenderState = MemAlloc(sizeof(ImGui_ImplRaylib_Data));
}

void ImGui_ImplRaylib_FreeBackendData()
{
    if (!ImGui::GetCurrentContext())
        return;

    MemFree(ImGui::GetPlatformIO().Renderer_RenderState);
}


Vector2 GetDisplayScale()
{
#if defined(__EMSCRIPTEN__)
    return Vector2{ 1,1 };
#else
    return GetWindowScaleDPI();
#endif
}

static const char* GetClipTextCallback(ImGuiContext*)
{
    return GetClipboardText();
}

static void SetClipTextCallback(ImGuiContext*, const char* text)
{
    SetClipboardText(text);
}

static void ImGuiNewFrame(float deltaTime)
{
    ImGuiIO& io = ImGui::GetIO();
    auto* platData = ImGui_ImplRaylib_GetBackendData();
    if (!platData)
    {
        ImGui_ImplRaylib_CreateBackendData();
        platData = ImGui_ImplRaylib_GetBackendData();
        if (!platData)
            return;
    }

    Vector2 resolutionScale = GetDisplayScale();

#ifndef PLATFORM_DRM
    if (IsWindowFullscreen())
    {
        int monitor = GetCurrentMonitor();
        io.DisplaySize.x = float(GetMonitorWidth(monitor));
        io.DisplaySize.y = float(GetMonitorHeight(monitor));
    }
    else
    {
        io.DisplaySize.x = float(GetScreenWidth());
        io.DisplaySize.y = float(GetScreenHeight());
    }

#if !defined(__APPLE__)
    if (!IsWindowState(FLAG_WINDOW_HIGHDPI))
        resolutionScale = Vector2{ 1,1 };
#endif
#else
    io.DisplaySize.x = float(GetScreenWidth());
    io.DisplaySize.y = float(GetScreenHeight());
#endif

    io.DisplayFramebufferScale = ImVec2(resolutionScale.x, resolutionScale.y);

    if (deltaTime <= 0)
        deltaTime = 0.001f;

    io.DeltaTime = deltaTime;

    if (ImGui::GetIO().BackendFlags & ImGuiBackendFlags_HasMouseCursors)
    {
        if ((io.ConfigFlags & ImGuiConfigFlags_NoMouseCursorChange) == 0)
        {
            ImGuiMouseCursor imgui_cursor = ImGui::GetMouseCursor();
            if (imgui_cursor != CurrentMouseCursor || io.MouseDrawCursor)
            {
                CurrentMouseCursor = imgui_cursor;
                if (io.MouseDrawCursor || imgui_cursor == ImGuiMouseCursor_None)
                {
                    HideCursor();
                }
                else
                {
                    ShowCursor();

                    if (!(io.ConfigFlags & ImGuiConfigFlags_NoMouseCursorChange))
                    {
                        SetMouseCursor((imgui_cursor > -1 && imgui_cursor < ImGuiMouseCursor_COUNT) ? MouseCursorMap[imgui_cursor] : MOUSE_CURSOR_DEFAULT);
                    }
                }
            }
        }
    }
}

static void ImGuiTriangleVert(const ImDrawVert& idx_vert)
{
#ifdef __cpp_designated_initializers
    Color c {
       .r = static_cast<unsigned char>(idx_vert.col>>0),
       .g = static_cast<unsigned char>(idx_vert.col>>8),
       .b = static_cast<unsigned char>(idx_vert.col>>16),
       .a = static_cast<unsigned char>(idx_vert.col>>24),
    };
#else
    Color c {
       static_cast<unsigned char>(idx_vert.col>>0),
       static_cast<unsigned char>(idx_vert.col>>8),
       static_cast<unsigned char>(idx_vert.col>>16),
       static_cast<unsigned char>(idx_vert.col>>24),
    };
#endif
    rlColor4ub(c.r, c.g, c.b, c.a);
    rlTexCoord2f(idx_vert.uv.x, idx_vert.uv.y);
    rlVertex2f(idx_vert.pos.x, idx_vert.pos.y);
}

static void ImGuiRenderTriangles(unsigned int count, int indexStart, const ImVector<ImDrawIdx>& indexBuffer, const ImVector<ImDrawVert>& vertBuffer, ImTextureID texturePtr)
{
    if (count < 3)
        return;

    unsigned int textureId = static_cast<unsigned int>(texturePtr);

    rlBegin(RL_TRIANGLES);
    rlSetTexture(textureId);

    for (unsigned int i = 0; i <= (count - 3); i += 3)
    {
        ImDrawIdx indexA = indexBuffer[indexStart + i];
        ImDrawIdx indexB = indexBuffer[indexStart + i + 1];
        ImDrawIdx indexC = indexBuffer[indexStart + i + 2];

        ImDrawVert vertexA = vertBuffer[indexA];
        ImDrawVert vertexB = vertBuffer[indexB];
        ImDrawVert vertexC = vertBuffer[indexC];

        ImGuiTriangleVert(vertexA);
        ImGuiTriangleVert(vertexB);
        ImGuiTriangleVert(vertexC);
    }
    rlEnd();
}

static void EnableScissor(float x, float y, float width, float height)
{
    rlEnableScissorTest();
    ImGuiIO& io = ImGui::GetIO();

    ImVec2 scale = io.DisplayFramebufferScale;
#if !defined(__APPLE__)
    if (!IsWindowState(FLAG_WINDOW_HIGHDPI))
    {
        scale.x = 1;
        scale.y = 1;
    }
#endif

    rlScissor((int)(x * scale.x),
        int((io.DisplaySize.y - (int)(y + height)) * scale.y),
        (int)(width * scale.x),
        (int)(height * scale.y));
}

static void SetupMouseCursors(void)
{
    MouseCursorMap[ImGuiMouseCursor_Arrow] = MOUSE_CURSOR_ARROW;
    MouseCursorMap[ImGuiMouseCursor_TextInput] = MOUSE_CURSOR_IBEAM;
    MouseCursorMap[ImGuiMouseCursor_Hand] = MOUSE_CURSOR_POINTING_HAND;
    MouseCursorMap[ImGuiMouseCursor_ResizeAll] = MOUSE_CURSOR_RESIZE_ALL;
    MouseCursorMap[ImGuiMouseCursor_ResizeEW] = MOUSE_CURSOR_RESIZE_EW;
    MouseCursorMap[ImGuiMouseCursor_ResizeNESW] = MOUSE_CURSOR_RESIZE_NESW;
    MouseCursorMap[ImGuiMouseCursor_ResizeNS] = MOUSE_CURSOR_RESIZE_NS;
    MouseCursorMap[ImGuiMouseCursor_ResizeNWSE] = MOUSE_CURSOR_RESIZE_NWSE;
    MouseCursorMap[ImGuiMouseCursor_NotAllowed] = MOUSE_CURSOR_NOT_ALLOWED;
}

void SetupFontAwesome(void)
{
#ifndef NO_FONT_AWESOME
    static const ImWchar icons_ranges[] = { ICON_MIN_FA, ICON_MAX_FA, 0 };
    ImFontConfig icons_config;
    icons_config.MergeMode = true;
    icons_config.PixelSnapH = true;
    icons_config.FontDataOwnedByAtlas = false;

    icons_config.GlyphMaxAdvanceX = std::numeric_limits<float>::max();
    icons_config.RasterizerMultiply = 1.0f;
    icons_config.OversampleH = 2;
    icons_config.OversampleV = 1;

    icons_config.GlyphRanges = icons_ranges;

    ImGuiIO& io = ImGui::GetIO();

    float size = FONT_AWESOME_ICON_SIZE;
#if !defined(__APPLE__)
    if (!IsWindowState(FLAG_WINDOW_HIGHDPI))
        size *= GetDisplayScale().y;

    icons_config.RasterizerMultiply = GetDisplayScale().y;
#endif

    io.Fonts->AddFontFromMemoryCompressedTTF((void*)fa_solid_900_compressed_data, fa_solid_900_compressed_size, size, &icons_config, icons_ranges);
#endif

}

void SetupBackend(void)
{
    ImGuiIO& io = ImGui::GetIO();
    io.BackendPlatformName = "imgui_impl_raylib";
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad | ImGuiBackendFlags_HasSetMousePos | ImGuiBackendFlags_RendererHasTextures;

#ifndef PLATFORM_DRM
    io.BackendFlags |= ImGuiBackendFlags_HasMouseCursors;
#endif

    io.MousePos = ImVec2(0, 0);

    ImGuiPlatformIO& platformIO = ImGui::GetPlatformIO();

    platformIO.Platform_SetClipboardTextFn = SetClipTextCallback;
    platformIO.Platform_GetClipboardTextFn = GetClipTextCallback;

    platformIO.Platform_ClipboardUserData = nullptr;

    ImGui_ImplRaylib_CreateBackendData();
}

void rlImGuiEndInitImGui(void)
{
    ImGui::SetCurrentContext(GlobalContext);

    SetupFontAwesome();

    SetupMouseCursors();

    SetupBackend();
}

static void SetupKeymap(void)
{
    if (!RaylibKeyMap.empty())
        return;

    // build up a map of raylib keys to ImGuiKeys
    RaylibKeyMap[KEY_APOSTROPHE] = ImGuiKey_Apostrophe;
    RaylibKeyMap[KEY_COMMA] = ImGuiKey_Comma;
    RaylibKeyMap[KEY_MINUS] = ImGuiKey_Minus;
    RaylibKeyMap[KEY_PERIOD] = ImGuiKey_Period;
    RaylibKeyMap[KEY_SLASH] = ImGuiKey_Slash;
    RaylibKeyMap[KEY_ZERO] = ImGuiKey_0;
    RaylibKeyMap[KEY_ONE] = ImGuiKey_1;
    RaylibKeyMap[KEY_TWO] = ImGuiKey_2;
    RaylibKeyMap[KEY_THREE] = ImGuiKey_3;
    RaylibKeyMap[KEY_FOUR] = ImGuiKey_4;
    RaylibKeyMap[KEY_FIVE] = ImGuiKey_5;
    RaylibKeyMap[KEY_SIX] = ImGuiKey_6;
    RaylibKeyMap[KEY_SEVEN] = ImGuiKey_7;
    RaylibKeyMap[KEY_EIGHT] = ImGuiKey_8;
    RaylibKeyMap[KEY_NINE] = ImGuiKey_9;
    RaylibKeyMap[KEY_SEMICOLON] = ImGuiKey_Semicolon;
    RaylibKeyMap[KEY_EQUAL] = ImGuiKey_Equal;
    RaylibKeyMap[KEY_A] = ImGuiKey_A;
    RaylibKeyMap[KEY_B] = ImGuiKey_B;
    RaylibKeyMap[KEY_C] = ImGuiKey_C;
    RaylibKeyMap[KEY_D] = ImGuiKey_D;
    RaylibKeyMap[KEY_E] = ImGuiKey_E;
    RaylibKeyMap[KEY_F] = ImGuiKey_F;
    RaylibKeyMap[KEY_G] = ImGuiKey_G;
    RaylibKeyMap[KEY_H] = ImGuiKey_H;
    RaylibKeyMap[KEY_I] = ImGuiKey_I;
    RaylibKeyMap[KEY_J] = ImGuiKey_J;
    RaylibKeyMap[KEY_K] = ImGuiKey_K;
    RaylibKeyMap[KEY_L] = ImGuiKey_L;
    RaylibKeyMap[KEY_M] = ImGuiKey_M;
    RaylibKeyMap[KEY_N] = ImGuiKey_N;
    RaylibKeyMap[KEY_O] = ImGuiKey_O;
    RaylibKeyMap[KEY_P] = ImGuiKey_P;
    RaylibKeyMap[KEY_Q] = ImGuiKey_Q;
    RaylibKeyMap[KEY_R] = ImGuiKey_R;
    RaylibKeyMap[KEY_S] = ImGuiKey_S;
    RaylibKeyMap[KEY_T] = ImGuiKey_T;
    RaylibKeyMap[KEY_U] = ImGuiKey_U;
    RaylibKeyMap[KEY_V] = ImGuiKey_V;
    RaylibKeyMap[KEY_W] = ImGuiKey_W;
    RaylibKeyMap[KEY_X] = ImGuiKey_X;
    RaylibKeyMap[KEY_Y] = ImGuiKey_Y;
    RaylibKeyMap[KEY_Z] = ImGuiKey_Z;
    RaylibKeyMap[KEY_SPACE] = ImGuiKey_Space;
    RaylibKeyMap[KEY_ESCAPE] = ImGuiKey_Escape;
    RaylibKeyMap[KEY_ENTER] = ImGuiKey_Enter;
    RaylibKeyMap[KEY_TAB] = ImGuiKey_Tab;
    RaylibKeyMap[KEY_BACKSPACE] = ImGuiKey_Backspace;
    RaylibKeyMap[KEY_INSERT] = ImGuiKey_Insert;
    RaylibKeyMap[KEY_DELETE] = ImGuiKey_Delete;
    RaylibKeyMap[KEY_RIGHT] = ImGuiKey_RightArrow;
    RaylibKeyMap[KEY_LEFT] = ImGuiKey_LeftArrow;
    RaylibKeyMap[KEY_DOWN] = ImGuiKey_DownArrow;
    RaylibKeyMap[KEY_UP] = ImGuiKey_UpArrow;
    RaylibKeyMap[KEY_PAGE_UP] = ImGuiKey_PageUp;
    RaylibKeyMap[KEY_PAGE_DOWN] = ImGuiKey_PageDown;
    RaylibKeyMap[KEY_HOME] = ImGuiKey_Home;
    RaylibKeyMap[KEY_END] = ImGuiKey_End;
    RaylibKeyMap[KEY_CAPS_LOCK] = ImGuiKey_CapsLock;
    RaylibKeyMap[KEY_SCROLL_LOCK] = ImGuiKey_ScrollLock;
    RaylibKeyMap[KEY_NUM_LOCK] = ImGuiKey_NumLock;
    RaylibKeyMap[KEY_PRINT_SCREEN] = ImGuiKey_PrintScreen;
    RaylibKeyMap[KEY_PAUSE] = ImGuiKey_Pause;
    RaylibKeyMap[KEY_F1] = ImGuiKey_F1;
    RaylibKeyMap[KEY_F2] = ImGuiKey_F2;
    RaylibKeyMap[KEY_F3] = ImGuiKey_F3;
    RaylibKeyMap[KEY_F4] = ImGuiKey_F4;
    RaylibKeyMap[KEY_F5] = ImGuiKey_F5;
    RaylibKeyMap[KEY_F6] = ImGuiKey_F6;
    RaylibKeyMap[KEY_F7] = ImGuiKey_F7;
    RaylibKeyMap[KEY_F8] = ImGuiKey_F8;
    RaylibKeyMap[KEY_F9] = ImGuiKey_F9;
    RaylibKeyMap[KEY_F10] = ImGuiKey_F10;
    RaylibKeyMap[KEY_F11] = ImGuiKey_F11;
    RaylibKeyMap[KEY_F12] = ImGuiKey_F12;
    RaylibKeyMap[KEY_LEFT_SHIFT] = ImGuiKey_LeftShift;
    RaylibKeyMap[KEY_LEFT_CONTROL] = ImGuiKey_LeftCtrl;
    RaylibKeyMap[KEY_LEFT_ALT] = ImGuiKey_LeftAlt;
    RaylibKeyMap[KEY_LEFT_SUPER] = ImGuiKey_LeftSuper;
    RaylibKeyMap[KEY_RIGHT_SHIFT] = ImGuiKey_RightShift;
    RaylibKeyMap[KEY_RIGHT_CONTROL] = ImGuiKey_RightCtrl;
    RaylibKeyMap[KEY_RIGHT_ALT] = ImGuiKey_RightAlt;
    RaylibKeyMap[KEY_RIGHT_SUPER] = ImGuiKey_RightSuper;
    RaylibKeyMap[KEY_KB_MENU] = ImGuiKey_Menu;
    RaylibKeyMap[KEY_LEFT_BRACKET] = ImGuiKey_LeftBracket;
    RaylibKeyMap[KEY_BACKSLASH] = ImGuiKey_Backslash;
    RaylibKeyMap[KEY_RIGHT_BRACKET] = ImGuiKey_RightBracket;
    RaylibKeyMap[KEY_GRAVE] = ImGuiKey_GraveAccent;
    RaylibKeyMap[KEY_KP_0] = ImGuiKey_Keypad0;
    RaylibKeyMap[KEY_KP_1] = ImGuiKey_Keypad1;
    RaylibKeyMap[KEY_KP_2] = ImGuiKey_Keypad2;
    RaylibKeyMap[KEY_KP_3] = ImGuiKey_Keypad3;
    RaylibKeyMap[KEY_KP_4] = ImGuiKey_Keypad4;
    RaylibKeyMap[KEY_KP_5] = ImGuiKey_Keypad5;
    RaylibKeyMap[KEY_KP_6] = ImGuiKey_Keypad6;
    RaylibKeyMap[KEY_KP_7] = ImGuiKey_Keypad7;
    RaylibKeyMap[KEY_KP_8] = ImGuiKey_Keypad8;
    RaylibKeyMap[KEY_KP_9] = ImGuiKey_Keypad9;
    RaylibKeyMap[KEY_KP_DECIMAL] = ImGuiKey_KeypadDecimal;
    RaylibKeyMap[KEY_KP_DIVIDE] = ImGuiKey_KeypadDivide;
    RaylibKeyMap[KEY_KP_MULTIPLY] = ImGuiKey_KeypadMultiply;
    RaylibKeyMap[KEY_KP_SUBTRACT] = ImGuiKey_KeypadSubtract;
    RaylibKeyMap[KEY_KP_ADD] = ImGuiKey_KeypadAdd;
    RaylibKeyMap[KEY_KP_ENTER] = ImGuiKey_KeypadEnter;
    RaylibKeyMap[KEY_KP_EQUAL] = ImGuiKey_KeypadEqual;
}

static void SetupGlobals(void)
{
    LastFrameFocused = IsWindowFocused();
    LastControlPressed = false;
    LastShiftPressed = false;
    LastAltPressed = false;
    LastSuperPressed = false;
}

void rlImGuiBeginInitImGui(void)
{
    SetupGlobals();
    if (GlobalContext == nullptr)
        GlobalContext = ImGui::CreateContext(nullptr);
    SetupKeymap();

    ImGuiIO& io = ImGui::GetIO();

    ImFontConfig defaultConfig;

    static constexpr int DefaultFonSize = 13;

    defaultConfig.SizePixels = DefaultFonSize;
#if !defined(__APPLE__)
    if (!IsWindowState(FLAG_WINDOW_HIGHDPI))
        defaultConfig.SizePixels = ceilf(defaultConfig.SizePixels * GetDisplayScale().y);

    defaultConfig.RasterizerMultiply = GetDisplayScale().y;
#endif

    defaultConfig.PixelSnapH = true;
    io.Fonts->AddFontDefault(&defaultConfig);
}

void rlImGuiSetup(bool dark)
{
    rlImGuiBeginInitImGui();

    if (dark)
        ImGui::StyleColorsDark();
    else
        ImGui::StyleColorsLight();

    rlImGuiEndInitImGui();
}

void rlImGuiBegin(void)
{
    ImGui::SetCurrentContext(GlobalContext);
    rlImGuiBeginDelta(GetFrameTime());
}

void rlImGuiBeginDelta(float deltaTime)
{
    ImGui::SetCurrentContext(GlobalContext);

    ImGuiNewFrame(deltaTime);
    ImGui_ImplRaylib_ProcessEvents();
    ImGui::NewFrame();
}

void rlImGuiEnd(void)
{
    ImGui::SetCurrentContext(GlobalContext);
    ImGui::Render();
    ImGui_ImplRaylib_RenderDrawData(ImGui::GetDrawData());
}

void rlImGuiShutdown(void)
{
    if (GlobalContext == nullptr)
        return;

    ImGui::SetCurrentContext(GlobalContext);
    ImGui_ImplRaylib_Shutdown();

    ImGui::DestroyContext(GlobalContext);
    GlobalContext = nullptr;
}

void rlImGuiImage(const Texture* image)
{
    if (!image)
        return;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);
    
    ImGui::Image(ImTextureID(image->id), ImVec2(float(image->width), float(image->height)));
}

bool rlImGuiImageButton(const char* name, const Texture* image)
{
    if (!image)
        return false;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);
    
    return ImGui::ImageButton(name, ImTextureID(image->id), ImVec2(float(image->width), float(image->height)));
}

bool rlImGuiImageButtonSize(const char* name, const Texture* image, Vector2 size)
{
    if (!image)
        return false;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);
   
    return ImGui::ImageButton(name, ImTextureID(image->id), ImVec2(size.x, size.y));
}

void rlImGuiImageSize(const Texture* image, int width, int height)
{
    if (!image)
        return;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);
    
    ImGui::Image(ImTextureID(image->id), ImVec2(float(width), float(height)));
}

void rlImGuiImageSizeV(const Texture* image, Vector2 size)
{
    if (!image)
        return;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);
    
    ImGui::Image(ImTextureID(image->id), ImVec2(size.x, size.y));
}

void rlImGuiImageRect(const Texture* image, int destWidth, int destHeight, Rectangle sourceRect)
{
    if (!image)
        return;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);
    
    ImVec2 uv0;
    ImVec2 uv1;

    if (sourceRect.width < 0)
    {
        uv0.x = -sourceRect.x / image->width;
        uv1.x = (uv0.x - float(fabs(sourceRect.width) / image->width));
    }
    else
    {
        uv0.x = sourceRect.x / image->width;
        uv1.x = uv0.x + float(sourceRect.width / image->width);
    }

    if (sourceRect.height < 0)
    {
        uv0.y = -sourceRect.y / image->height;
        uv1.y = (uv0.y - fabsf(sourceRect.height) / image->height);
    }
    else
    {
        uv0.y = sourceRect.y / image->height;
        uv1.y = uv0.y + sourceRect.height / image->height;
    }

    ImGui::Image((ImTextureID)image->id, ImVec2(float(destWidth), float(destHeight)), uv0, uv1);
}

void rlImGuiImageRenderTexture(const RenderTexture* image)
{
    if (!image)
        return;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);
    
    rlImGuiImageRect(&image->texture, image->texture.width, image->texture.height, Rectangle{ 0,0, float(image->texture.width), -float(image->texture.height) });
}

void rlImGuiImageRenderTextureFit(const RenderTexture* image, bool center)
{
    if (!image)
        return;
    
    if (GlobalContext)
        ImGui::SetCurrentContext(GlobalContext);

    ImVec2 area = ImGui::GetContentRegionAvail();

    float scale =  area.x / image->texture.width;

    float y = image->texture.height * scale;
    if (y > area.y)
    {
        scale = area.y / image->texture.height;
    }

    int sizeX = int(image->texture.width * scale);
    int sizeY = int(image->texture.height * scale);

    if (center)
    {
        ImGui::SetCursorPosX(0);
        ImGui::SetCursorPosX(area.x/2 - sizeX/2);
        ImGui::SetCursorPosY(ImGui::GetCursorPosY() + (area.y / 2 - sizeY / 2));
    }

    rlImGuiImageRect(&image->texture, sizeX, sizeY, Rectangle{ 0,0, float(image->texture.width), -float(image->texture.height) });
}

// raw ImGui backend API
bool ImGui_ImplRaylib_Init(void)
{
    SetupGlobals();

    SetupKeymap();

    SetupMouseCursors();

    SetupBackend();

    return true;
}


void ImGui_ImplRaylib_Shutdown()
{
    ImGuiIO& io =ImGui::GetIO();

    for (auto& texture : ImGui::GetPlatformIO().Textures)
    {
        if (texture->Status != ImTextureStatus_Destroyed)
        {
            Texture* backendData = (Texture*)texture->BackendUserData;
            if (backendData && IsTextureValid(*backendData))
            {
                UnloadTexture(*backendData);
            }
            if (backendData)
                MemFree(backendData);

            texture->BackendUserData = nullptr;
            texture->Status = ImTextureStatus_Destroyed;
            texture->SetTexID(ImTextureID_Invalid);
        }
    }

    ImGui_ImplRaylib_FreeBackendData();
}

void ImGui_ImplRaylib_NewFrame(void)
{
    ImGuiNewFrame(GetFrameTime());
}

void ImGui_ImplRaylib_UpdateTexture(ImTextureData* tex)
{
    switch (tex->Status)
    {
        case ImTextureStatus_OK:
        case ImTextureStatus_Destroyed:
        default:
            break;

        case ImTextureStatus_WantCreate:
        {
            Image img = { 0 };
            img.width = tex->Width;
            img.height = tex->Height;

            img.format = tex->Format == ImTextureFormat_Alpha8 ? PIXELFORMAT_UNCOMPRESSED_GRAYSCALE : PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;
            img.mipmaps = 1;
            img.data = tex->GetPixels();

            Texture* texture = (Texture*)MemAlloc(sizeof(Texture));
            tex->BackendUserData = texture;;
            *texture = LoadTextureFromImage(img);
            tex->SetTexID(ImTextureID(texture->id));
            tex->Status = ImTextureStatus_OK;
        }
            break;

        case ImTextureStatus_WantUpdates:
        {
            Texture* texture = (Texture*)tex->BackendUserData;
            if (!texture)
                break;

            UpdateTexture(*texture, tex->GetPixels());

            tex->Status = ImTextureStatus_OK;
        }
            break;

        case ImTextureStatus_WantDestroy:
        {
            Texture* texture = (Texture*)tex->BackendUserData;

            if (!texture)
                break;
            UnloadTexture(*texture);
            tex->Status = ImTextureStatus_Destroyed;
            MemFree(texture);
            tex->BackendUserData = nullptr;
            tex->SetTexID(ImTextureID_Invalid);
        }
        break;
    }
}

void ImGui_ImplRaylib_RenderDrawData(ImDrawData* draw_data)
{
    if (draw_data->Textures != nullptr)
    {
        for (ImTextureData* tex : *draw_data->Textures)
        {
            if (tex->Status != ImTextureStatus_OK)
                ImGui_ImplRaylib_UpdateTexture(tex);
        }
    }

    rlDrawRenderBatchActive();
    rlDisableBackfaceCulling();

    for (int l = 0; l < draw_data->CmdListsCount; ++l)
    {
        const ImDrawList* commandList = draw_data->CmdLists[l];

        for (const auto& cmd : commandList->CmdBuffer)
        {
            EnableScissor(cmd.ClipRect.x - draw_data->DisplayPos.x, cmd.ClipRect.y - draw_data->DisplayPos.y, cmd.ClipRect.z - (cmd.ClipRect.x - draw_data->DisplayPos.x), cmd.ClipRect.w - (cmd.ClipRect.y - draw_data->DisplayPos.y));
            if (cmd.UserCallback != nullptr)
            {
                cmd.UserCallback(commandList, &cmd);

                continue;
            }

            ImGuiRenderTriangles(cmd.ElemCount, cmd.IdxOffset, commandList->IdxBuffer, commandList->VtxBuffer, cmd.GetTexID());
            rlDrawRenderBatchActive();
        }
    }

    rlSetTexture(0);
    rlDisableScissorTest();
    rlEnableBackfaceCulling();
}

void HandleGamepadButtonEvent(ImGuiIO& io, GamepadButton button, ImGuiKey key)
{
    if (IsGamepadButtonPressed(0, button))
        io.AddKeyEvent(key, true);
    else if (IsGamepadButtonReleased(0, button))
        io.AddKeyEvent(key, false);
}

void HandleGamepadStickEvent(ImGuiIO& io, GamepadAxis axis, ImGuiKey negKey, ImGuiKey posKey)
{
    constexpr float deadZone = 0.20f;

    float axisValue = GetGamepadAxisMovement(0, axis);

    io.AddKeyAnalogEvent(negKey, axisValue < -deadZone, axisValue < -deadZone ? -axisValue : 0);
    io.AddKeyAnalogEvent(posKey, axisValue > deadZone, axisValue > deadZone ? axisValue : 0);
}

bool ImGui_ImplRaylib_ProcessEvents(void)
{
    ImGuiIO& io = ImGui::GetIO();

    bool focused = IsWindowFocused();
    if (focused != LastFrameFocused)
        io.AddFocusEvent(focused);
    LastFrameFocused = focused;

    // handle the modifyer key events so that shortcuts work
    bool ctrlDown = rlImGuiIsControlDown();
    if (ctrlDown != LastControlPressed)
        io.AddKeyEvent(ImGuiMod_Ctrl, ctrlDown);
    LastControlPressed = ctrlDown;

    bool shiftDown = rlImGuiIsShiftDown();
    if (shiftDown != LastShiftPressed)
        io.AddKeyEvent(ImGuiMod_Shift, shiftDown);
    LastShiftPressed = shiftDown;

    bool altDown = rlImGuiIsAltDown();
    if (altDown != LastAltPressed)
        io.AddKeyEvent(ImGuiMod_Alt, altDown);
    LastAltPressed = altDown;

    bool superDown = rlImGuiIsSuperDown();
    if (superDown != LastSuperPressed)
        io.AddKeyEvent(ImGuiMod_Super, superDown);
    LastSuperPressed = superDown;

    // walk the keymap and check for up and down events
    for (const auto keyItr : RaylibKeyMap)
    {
        if (IsKeyReleased(keyItr.first))
            io.AddKeyEvent(keyItr.second, false);
        else if(IsKeyPressed(keyItr.first))
            io.AddKeyEvent(keyItr.second, true);
    }

    if (io.WantCaptureKeyboard)
    {
        // add the text input in order
        unsigned int pressed = GetCharPressed();
        while (pressed != 0)
        {
            io.AddInputCharacter(pressed);
            pressed = GetCharPressed();
        }
    }

    bool processsMouse = focused;

#if defined(RLIMGUI_ALWAYS_TRACK_MOUSE)
    processsMouse = true;
#endif

    if (processsMouse)
    {
        if (!io.WantSetMousePos)
        {
            io.AddMousePosEvent(float(GetMouseX()), float(GetMouseY()));
        }

        auto setMouseEvent = [&io](int rayMouse, int imGuiMouse)
            {
                if (IsMouseButtonPressed(rayMouse))
                    io.AddMouseButtonEvent(imGuiMouse, true);
                else if (IsMouseButtonReleased(rayMouse))
                    io.AddMouseButtonEvent(imGuiMouse, false);
            };

        setMouseEvent(MOUSE_BUTTON_LEFT, ImGuiMouseButton_Left);
        setMouseEvent(MOUSE_BUTTON_RIGHT, ImGuiMouseButton_Right);
        setMouseEvent(MOUSE_BUTTON_MIDDLE, ImGuiMouseButton_Middle);
        setMouseEvent(MOUSE_BUTTON_FORWARD, ImGuiMouseButton_Middle + 1);
        setMouseEvent(MOUSE_BUTTON_BACK, ImGuiMouseButton_Middle + 2);

        {
            Vector2 mouseWheel = GetMouseWheelMoveV();
            io.AddMouseWheelEvent(mouseWheel.x, mouseWheel.y);
        }
    }
    else
    {
        io.AddMousePosEvent(std::numeric_limits<float>::min(), std::numeric_limits<float>::min());
    }

    if (io.ConfigFlags & ImGuiConfigFlags_NavEnableGamepad && IsGamepadAvailable(0))
    {
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_LEFT_FACE_UP, ImGuiKey_GamepadDpadUp);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_LEFT_FACE_RIGHT, ImGuiKey_GamepadDpadRight);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_LEFT_FACE_DOWN, ImGuiKey_GamepadDpadDown);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_LEFT_FACE_LEFT, ImGuiKey_GamepadDpadLeft);

        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_RIGHT_FACE_UP, ImGuiKey_GamepadFaceUp);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_RIGHT_FACE_RIGHT, ImGuiKey_GamepadFaceLeft);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_RIGHT_FACE_DOWN, ImGuiKey_GamepadFaceDown);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_RIGHT_FACE_LEFT, ImGuiKey_GamepadFaceRight);

        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_LEFT_TRIGGER_1, ImGuiKey_GamepadL1);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_LEFT_TRIGGER_2, ImGuiKey_GamepadL2);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_RIGHT_TRIGGER_1, ImGuiKey_GamepadR1);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_RIGHT_TRIGGER_2, ImGuiKey_GamepadR2);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_LEFT_THUMB, ImGuiKey_GamepadL3);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_RIGHT_THUMB, ImGuiKey_GamepadR3);

        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_MIDDLE_LEFT, ImGuiKey_GamepadStart);
        HandleGamepadButtonEvent(io, GAMEPAD_BUTTON_MIDDLE_RIGHT, ImGuiKey_GamepadBack);

        // left stick
        HandleGamepadStickEvent(io, GAMEPAD_AXIS_LEFT_X, ImGuiKey_GamepadLStickLeft, ImGuiKey_GamepadLStickRight);
        HandleGamepadStickEvent(io, GAMEPAD_AXIS_LEFT_Y, ImGuiKey_GamepadLStickUp, ImGuiKey_GamepadLStickDown);

        // right stick
        HandleGamepadStickEvent(io, GAMEPAD_AXIS_RIGHT_X, ImGuiKey_GamepadRStickLeft, ImGuiKey_GamepadRStickRight);
        HandleGamepadStickEvent(io, GAMEPAD_AXIS_RIGHT_Y, ImGuiKey_GamepadRStickUp, ImGuiKey_GamepadRStickDown);
    }

    return true;
}

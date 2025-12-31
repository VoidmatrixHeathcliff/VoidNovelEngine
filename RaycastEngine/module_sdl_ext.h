#pragma once

#include <SDL.h>
#include <lua.hpp>
#include <LuaBridge.h>

bool SDL_ShowConfirmBox(Uint32 flags, const char* title, const char* message, SDL_Window* window, luabridge::LuaRef btn_ok, luabridge::LuaRef btn_cancel);
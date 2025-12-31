#pragma once

#include <cJSON.h>
#include <lua.hpp>

int JSON_ParseToLua(lua_State* pLuaVM);
int JSON_PrintFromLua(lua_State* pLuaVM);
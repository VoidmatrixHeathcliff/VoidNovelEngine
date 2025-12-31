// https://github.com/kunitoki/LuaBridge3
// Copyright 2023, Lucio Asnaghi
// SPDX-License-Identifier: MIT

#pragma once

#include "Config.h"
#include "Stack.h"

namespace luabridge {

//=================================================================================================
/**
 * @brief Get a global value from the lua_State.
 *
 * @note This works on any type specialized by `Stack`, including `LuaRef` and its table proxies.
*/
template <class T>
TypeResult<T> getGlobal(lua_State* L, const char* name)
{
    lua_getglobal(L, name);

    auto result = luabridge::Stack<T>::get(L, -1);

    lua_pop(L, 1);

    return result;
}

//=================================================================================================
/**
 * @brief Set a global value in the lua_State.
 *
 * @note This works on any type specialized by `Stack`, including `LuaRef` and its table proxies.
 */
template <class T>
bool setGlobal(lua_State* L, T&& t, const char* name)
{
    if (auto result = push(L, std::forward<T>(t)))
    {
        lua_setglobal(L, name);
        return true;
    }

    return false;
}

} // namespace luabridge

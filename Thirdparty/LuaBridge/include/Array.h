// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2020, Dmitry Tarakanov
// SPDX-License-Identifier: MIT

#pragma once

#include "detail/Stack.h"

#include <array>

namespace luabridge {

//=================================================================================================
/**
 * @brief Stack specialization for `std::array`.
 */
template <class T, std::size_t Size>
struct Stack<std::array<T, Size>>
{
    using Type = std::array<T, Size>;

    [[nodiscard]] static Result push(lua_State* L, const Type& array)
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(L, 3))
            return makeErrorCode(ErrorCode::LuaStackOverflow);
#endif

        StackRestore stackRestore(L);

        lua_createtable(L, static_cast<int>(Size), 0);

        for (std::size_t i = 0; i < Size; ++i)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(i + 1));

            auto result = Stack<T>::push(L, array[i]);
            if (! result)
                return result;

            lua_settable(L, -3);
        }
        
        stackRestore.reset();
        return {};
    }

    [[nodiscard]] static TypeResult<Type> get(lua_State* L, int index)
    {
        if (!lua_istable(L, index))
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        if (get_length(L, index) != Size)
            return makeErrorCode(ErrorCode::InvalidTableSizeInCast);

        const StackRestore stackRestore(L);

        Type array;

        int absIndex = lua_absindex(L, index);
        lua_pushnil(L);

        int arrayIndex = 0;
        while (lua_next(L, absIndex) != 0)
        {
            auto item = Stack<T>::get(L, -1);
            if (!item)
                return makeErrorCode(ErrorCode::InvalidTypeCast);

            array[arrayIndex++] = *item;
            lua_pop(L, 1);
        }

        return array;
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index)
    {
        return lua_istable(L, index) && get_length(L, index) == Size;
    }
};

} // namespace luabridge

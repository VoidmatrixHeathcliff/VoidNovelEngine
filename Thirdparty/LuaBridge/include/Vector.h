// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2018, Dmitry Tarakanov
// SPDX-License-Identifier: MIT

#pragma once

#include "detail/Stack.h"

#include <vector>

namespace luabridge {

//=================================================================================================
/**
 * @brief Stack specialization for `std::vector`.
 */
template <class T>
struct Stack<std::vector<T>>
{
    using Type = std::vector<T>;

    [[nodiscard]] static Result push(lua_State* L, const Type& vector)
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(L, 3))
            return makeErrorCode(ErrorCode::LuaStackOverflow);
#endif

        StackRestore stackRestore(L);

        lua_createtable(L, static_cast<int>(vector.size()), 0);

        for (std::size_t i = 0; i < vector.size(); ++i)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(i + 1));
            
            auto result = Stack<T>::push(L, vector[i]);
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

        const StackRestore stackRestore(L);

        Type vector;
        vector.reserve(static_cast<std::size_t>(get_length(L, index)));

        int absIndex = lua_absindex(L, index);
        lua_pushnil(L);

        while (lua_next(L, absIndex) != 0)
        {
            auto item = Stack<T>::get(L, -1);
            if (! item)
                return makeErrorCode(ErrorCode::InvalidTypeCast);

            vector.emplace_back(*item);
            lua_pop(L, 1);
        }

        return vector;
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index)
    {
        return lua_istable(L, index);
    }
};

} // namespace luabridge

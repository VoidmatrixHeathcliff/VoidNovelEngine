// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2019, Dmitry Tarakanov
// Copyright 2012, Vinnie Falco <vinnie.falco@gmail.com>
// SPDX-License-Identifier: MIT

#pragma once

#include "Config.h"
#include "ClassInfo.h"
#include "Errors.h"
#include "FuncTraits.h"
#include "LuaHelpers.h"
#include "Options.h"
#include "Stack.h"
#include "TypeTraits.h"
#include "Userdata.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <string>

namespace luabridge {

class LuaRef;

namespace detail {

//=================================================================================================
/**
 * @brief Make argument lists extracting them from the lua state, starting at a stack index.
 *
 * @tparam ArgsPack Arguments pack to extract from the lua stack.
 * @tparam Start Start index where stack variables are located in the lua stack.
 */
template <class T>
auto unwrap_argument_or_error(lua_State* L, std::size_t index, std::size_t start)
{
    auto result = Stack<T>::get(L, static_cast<int>(index + start));
    if (! result)
        raise_lua_error(L, "Error decoding argument #%d: %s", static_cast<int>(index + 1), result.message().c_str());

    return std::move(*result);
}

template <class ArgsPack, std::size_t Start, std::size_t... Indices>
auto make_arguments_list_impl([[maybe_unused]] lua_State* L, std::index_sequence<Indices...>)
{
    return tupleize(unwrap_argument_or_error<std::tuple_element_t<Indices, ArgsPack>>(L, Indices, Start)...);
}

template <class ArgsPack, std::size_t Start>
auto make_arguments_list(lua_State* L)
{
    return make_arguments_list_impl<ArgsPack, Start>(L, std::make_index_sequence<std::tuple_size_v<ArgsPack>>());
}

//=================================================================================================
/**
 * @brief Helpers for iterating through tuple arguments, pushing each argument to the lua stack.
 */
template <std::size_t Index = 0, class... Types>
auto push_arguments(lua_State*, std::tuple<Types...>)
    -> std::enable_if_t<Index == sizeof...(Types), std::tuple<Result, std::size_t>>
{
    return std::make_tuple(Result(), Index + 1);
}

template <std::size_t Index = 0, class... Types>
auto push_arguments(lua_State* L, std::tuple<Types...> t)
    -> std::enable_if_t<Index < sizeof...(Types), std::tuple<Result, std::size_t>>
{
    using T = std::tuple_element_t<Index, std::tuple<Types...>>;

    auto result = Stack<T>::push(L, std::get<Index>(t));
    if (! result)
        return std::make_tuple(result, Index + 1);

    return push_arguments<Index + 1, Types...>(L, std::move(t));
}

//=================================================================================================
/**
 * @brief Helpers for iterating through tuple arguments, popping each argument from the lua stack.
 */
template <std::ptrdiff_t Start, std::ptrdiff_t Index = 0, class... Types>
auto pop_arguments(lua_State*, std::tuple<Types...>&)
    -> std::enable_if_t<Index == sizeof...(Types), std::size_t>
{
    return sizeof...(Types);
}

template <std::ptrdiff_t Start, std::ptrdiff_t Index = 0, class... Types>
auto pop_arguments(lua_State* L, std::tuple<Types...>& t)
    -> std::enable_if_t<Index < sizeof...(Types), std::size_t>
{
    using T = std::tuple_element_t<Index, std::tuple<Types...>>;

    std::get<Index>(t) = Stack<T>::get(L, Start - Index);

    return pop_arguments<Start, Index + 1, Types...>(L, t);
}

//=================================================================================================
/**
 * @brief Check if a method name is a metamethod.
 */
template <class T = void, class... Args>
constexpr auto make_array(Args&&... args)
{
    if constexpr (std::is_same_v<void, T>)
        return std::array<std::common_type_t<std::decay_t<Args>...>, sizeof...(Args)>{{ std::forward<Args>(args)... }};
    else
        return std::array<T, sizeof...(Args)>{{ std::forward<Args>(args)... }};
}

inline bool is_metamethod(std::string_view method_name)
{
    static constexpr auto metamethods = make_array<std::string_view>(
        "__add",
        "__band",
        "__bnot",
        "__bor",
        "__bxor",
        "__call",
        "__close",
        "__concat",
        "__div",
        "__eq",
        "__gc",
        "__idiv",
        "__index",
        "__ipairs",
        "__le",
        "__len",
        "__lt",
        "__metatable",
        "__mod",
        "__mode",
        "__mul",
        "__name",
        "__newindex",
        "__pairs",
        "__pow",
        "__shl",
        "__shr",
        "__sub",
        "__tostring",
        "__unm"
    );

    if (method_name.size() <= 2 || method_name[0] != '_' || method_name[1] != '_')
        return false;

    auto result = std::lower_bound(metamethods.begin(), metamethods.end(), method_name);
    return result != metamethods.end() && *result == method_name;
}

/**
 * @brief Make super method name.
 */
inline std::string make_super_method_name(const char* name)
{
    LUABRIDGE_ASSERT(name != nullptr);

    return (std::string_view(name).find("_") == 0u)
        ? (std::string("super") + name)
        : (std::string("super_") + name);
}

//=================================================================================================
/**
 * @brief Make super method name.
 */
inline Options get_class_options(lua_State* L, int index)
{
    LUABRIDGE_ASSERT(lua_istable(L, index)); // Stack: mt

    Options options = defaultOptions;

    lua_rawgetp(L, index, getClassOptionsKey()); // Stack: mt, ifb (may be nil)
    if (lua_isnumber(L, -1))
        options = Options::fromUnderlying(lua_tointeger(L, -1));

    lua_pop(L, 1);

    return options;
}

//=================================================================================================
/**
 * @brief Push class or const table onto stack.
 */
inline void push_class_or_const_table(lua_State* L, int index)
{
    LUABRIDGE_ASSERT(lua_istable(L, index)); // Stack: mt

    lua_rawgetp(L, index, getClassKey()); // Stack: mt, class table (ct) | nil
    if (! lua_istable(L, -1)) // Stack: mt, nil
    {
        lua_pop(L, 1); // Stack: mt

        lua_rawgetp(L, index, getConstKey()); // Stack: mt, const table (co) | nil
        if (! lua_istable(L, -1)) // Stack: mt, nil
            return;
    }
}

//=================================================================================================
/**
 * @brief __index metamethod for a namespace or class static and non-static members.
 *
 * Retrieves functions from metatables and properties from propget tables. Looks through the class hierarchy if inheritance is present.
 */

inline std::optional<int> try_call_index_fallback(lua_State* L)
{
    LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt

    lua_rawgetp(L, -1, getIndexFallbackKey()); // Stack: mt, ifb (may be nil)
    if (! lua_iscfunction(L, -1))
    {
        lua_pop(L, 1); // Stack: mt
        return std::nullopt;
    }

    lua_pushvalue(L, 1); // Stack: mt, ifb, arg1
    lua_pushvalue(L, 2); // Stack: mt, ifb, arg1, arg2
    lua_call(L, 2, 1); // Stack: mt, ifbresult

    if (! lua_isnoneornil(L, -1))
    {
        lua_remove(L, -2); // Stack: ifbresult
        return 1;
    }

    lua_pop(L, 1); // Stack: mt
    return std::nullopt;
}

template <bool IsObject>
inline std::optional<int> try_call_index_extensible(lua_State* L, const char* key)
{
    LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt

    if constexpr (IsObject)
        push_class_or_const_table(L, -1); // Stack: mt, cl | co
    else
        lua_rawgetp(L, -1, getStaticKey()); // Stack: mt, st

    LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt, cl | co | st
    rawgetfield(L, -1, key); // Stack: mt, st, ifbresult | nil

    if (! lua_isnoneornil(L, -1)) // Stack: mt, cl | co | st, ifbresult
    {
        lua_remove(L, -2); // Stack: mt, ifbresult
        lua_remove(L, -2); // Stack: ifbresult
        return 1;
    }

    lua_pop(L, 2); // Stack: mt
    return std::nullopt;
}

template <bool IsObject>
inline int index_metamethod(lua_State* L)
{
#if LUABRIDGE_SAFE_STACK_CHECKS
    luaL_checkstack(L, 3, detail::error_lua_stack_overflow);
#endif

    LUABRIDGE_ASSERT(lua_istable(L, 1) || lua_isuserdata(L, 1)); // Stack (further not shown): table | userdata, name

    lua_getmetatable(L, 1); // Stack: class/const table (mt)
    LUABRIDGE_ASSERT(lua_istable(L, -1));

    // Protect internal meta methods
    const char* key = lua_tostring(L, 2);
    if (key != nullptr && is_metamethod(key))
    {
        lua_pushnil(L);
        return 1;
    }

    for (;;)
    {
        if constexpr (IsObject)
        {
            // Repeat the lookup in the index fallback
            if (auto result = try_call_index_fallback(L))
                return *result;
        }

        // Search into self or metatable
        if (lua_istable(L, 1))
        {
            if constexpr (IsObject)
                lua_pushvalue(L, 1); // Stack: mt, self
            else
                push_class_or_const_table(L, -1); // Stack: mt, cl | co

            if (lua_istable(L, -1))
            {
                lua_pushvalue(L, 2); // Stack: mt, self | cl | co, field name
                lua_rawget(L, -2); // Stack: mt, self | cl | co, field | nil
                lua_remove(L, -2); // Stack: mt, field | nil
                if (! lua_isnil(L, -1)) // Stack: mt, field
                {
                    lua_remove(L, -2); // Stack: field
                    return 1;
                }
            }

            lua_pop(L, 1); // Stack: mt
        }

        lua_pushvalue(L, 2); // Stack: mt, field name
        lua_rawget(L, -2); // Stack: mt, field | nil
        if (! lua_isnil(L, -1)) // Stack: mt, field
        {
            lua_remove(L, -2); // Stack: field
            return 1;
        }

        LUABRIDGE_ASSERT(lua_isnil(L, -1)); // Stack: mt, nil
        lua_pop(L, 1); // Stack: mt

        // Repeat the lookup in the index extensible, for method overrides
        const Options options = get_class_options(L, -1); // Stack: mt
        if (options.test(extensibleClass | allowOverridingMethods))
        {
            if (auto result = try_call_index_extensible<IsObject>(L, key))
                return *result;
        }

        // Try in the propget key
        lua_rawgetp(L, -1, getPropgetKey()); // Stack: mt, propget table (pg)
        LUABRIDGE_ASSERT(lua_istable(L, -1));

        lua_pushvalue(L, 2); // Stack: mt, pg, field name
        lua_rawget(L, -2); // Stack: mt, pg, getter | nil
        lua_remove(L, -2); // Stack: mt, getter | nil

        if (lua_iscfunction(L, -1)) // Stack: mt, getter
        {
            lua_remove(L, -2); // Stack: getter
            lua_pushvalue(L, 1); // Stack: getter, table | userdata
            lua_call(L, 1, 1); // Stack: value
            return 1;
        }

        LUABRIDGE_ASSERT(lua_isnil(L, -1)); // Stack: mt, nil
        lua_pop(L, 1); // Stack: mt

        // It may mean that the field may be in const table and it's constness violation.

        // Repeat the lookup in the parent metafield, or fallback to extensible class check.
        lua_rawgetp(L, -1, getParentKey()); // Stack: mt, parent mt | nil
        if (lua_isnil(L, -1)) // Stack: mt, nil
        {
            lua_pop(L, 2); // Stack: -
            break;
        }

        // Remove the metatable and repeat the search in the parent one.
        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt, parent mt
        lua_remove(L, -2); // Stack: parent mt
    }

    lua_getmetatable(L, 1); // Stack: class/const table (mt)
    LUABRIDGE_ASSERT(lua_istable(L, -1));

    for (;;)
    {
        const Options options = get_class_options(L, -1); // Stack: mt

        if (options.test(extensibleClass | ~allowOverridingMethods))
        {
            if (auto result = try_call_index_extensible<IsObject>(L, key))
                return *result;
        }

        // Repeat the lookup in the parent metafield, or return nil if the field doesn't exist.
        lua_rawgetp(L, -1, getParentKey()); // Stack: mt, parent mt | nil
        if (lua_isnil(L, -1)) // Stack: mt, nil
        {
            lua_remove(L, -2); // Stack: nil
            return 1;
        }

        // Remove the metatable and repeat the search in the parent one.
        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt, parent mt
        lua_remove(L, -2); // Stack: parent mt
    }

    // no return
}

//=================================================================================================
/**
 * @brief __newindex metamethod for non-static members.
 *
 * Retrieves properties from propset tables.
 */

inline std::optional<int> try_call_newindex_fallback(lua_State* L)
{
    LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt

    lua_rawgetp(L, -1, getNewIndexFallbackKey()); // Stack: mt, nifb (may be nil)
    if (! lua_iscfunction(L, -1))
    {
        lua_pop(L, 1); // Stack: mt
        return std::nullopt;
    }

    lua_pushvalue(L, 1); // stack: mt, nifb, arg1
    lua_pushvalue(L, 2); // stack: mt, nifb, arg1, arg2
    lua_pushvalue(L, 3); // stack: mt, nifb, arg1, arg2, arg3
    lua_call(L, 3, 0); // stack: mt

    return 0;
}

inline std::optional<int> try_call_newindex_extensible(lua_State* L, const char* key)
{
    LUABRIDGE_ASSERT(key != nullptr);
    LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt

    lua_pushvalue(L, -1); // Stack: mt, mt

    for (;;)
    {
        push_class_or_const_table(L, -1); // Stack: mt, mt, class table (ct) | nil
        if (! lua_istable(L, -1)) // Stack: mt, mt, nil
        {
            lua_pop(L, 2); // Stack: mt
            return std::nullopt;
        }

        lua_pushvalue(L, 2); // Stack: mt, mt, ct | co, field name
        lua_rawget(L, -2); // Stack: mt, mt, ct | co, field | nil

        if (! lua_isnil(L, -1)) // Stack: mt, mt, ct | co, field
        {
            if (! lua_iscfunction(L, -1))
            {
                lua_pop(L, 1);
                break;
            }

            // Obtain class options
            const Options options = get_class_options(L, -2); // Stack: mt, mt, ct | co, field
            if (! options.test(allowOverridingMethods))
                luaL_error(L, "immutable member '%s'", key);

            rawsetfield(L, -2, make_super_method_name(key).c_str()); // Stack: mt, mt, ct | co
            break;
        }

        lua_pop(L, 1); // Stack: mt, mt, ct | co

        lua_rawgetp(L, -2, getParentKey()); // Stack: mt, mt, ct | co, parent mt (pmt) | nil
        if (lua_isnil(L, -1)) // Stack: mt, mt, ct | co, nil
        {
            lua_pop(L, 1); // Stack: mt, mt, ct | co
            break;
        }

        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt, mt, ct | co, pmt
        lua_remove(L, -2); // Stack: mt, mt, pmt
        lua_remove(L, -2); // Stack: mt, pmt
    }

    lua_remove(L, -2); // Stack: mt, ct | co
    lua_getmetatable(L, -1); // Stack: mt, ct | co, mt2
    lua_pushvalue(L, 3); // Stack: mt, ct | co, mt2, arg3
    rawsetfield(L, -2, key); // Stack: mt, ct | co, mt2

    lua_pop(L, 2); // Stack: mt

    return 0;
}

template <bool IsObject>
inline int newindex_metamethod(lua_State* L)
{
#if LUABRIDGE_SAFE_STACK_CHECKS
    luaL_checkstack(L, 3, detail::error_lua_stack_overflow);
#endif

    LUABRIDGE_ASSERT(lua_istable(L, 1) || lua_isuserdata(L, 1)); // Stack (further not shown): table | userdata, name, new value

    lua_getmetatable(L, 1); // Stack: metatable (mt)
    LUABRIDGE_ASSERT(lua_istable(L, -1));

    const char* key = lua_tostring(L, 2);

    for (;;)
    {
        const Options options = get_class_options(L, -1);

        // Try in the property set table
        lua_rawgetp(L, -1, getPropsetKey()); // Stack: mt, propset table (ps) | nil
        if (lua_isnil(L, -1)) // Stack: mt, nil
            luaL_error(L, "no member named '%s'", key);

        LUABRIDGE_ASSERT(lua_istable(L, -1));

        lua_pushvalue(L, 2); // Stack: mt, ps, field name
        lua_rawget(L, -2); // Stack: mt, ps, setter | nil
        lua_remove(L, -2); // Stack: mt, setter | nil

        if (lua_iscfunction(L, -1)) // Stack: mt, setter
        {
            lua_remove(L, -2); // Stack: setter
            if constexpr (IsObject)
                lua_pushvalue(L, 1); // Stack: setter, table | userdata
            lua_pushvalue(L, 3); // Stack: setter, table | userdata, new value
            lua_call(L, IsObject ? 2 : 1, 0); // Stack: -
            return 0;
        }

        LUABRIDGE_ASSERT(lua_isnil(L, -1)); // Stack: mt, nil
        lua_pop(L, 1); // Stack: mt

        if constexpr (IsObject)
        {
            // Try in the new index fallback
            if (auto result = try_call_newindex_fallback(L))
                return *result;
        }
        else
        {
            // Try in the new index extensible
            if (options.test(extensibleClass))
            {
                if (auto result = try_call_newindex_extensible(L, key))
                    return *result;
            }
        }

        // Try in the parent
        lua_rawgetp(L, -1, getParentKey()); // Stack: mt, parent mt | nil
        if (lua_isnil(L, -1)) // Stack: mt, nil
            luaL_error(L, "no writable member '%s'", key);

        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: mt, parent mt
        lua_remove(L, -2); // Stack: parent mt

        // Repeat the search in the parent
    }

    return 0;
}

//=================================================================================================
/**
 * @brief lua_CFunction to report an error writing to a read-only value.
 *
 * The name of the variable is in the first upvalue.
 */
inline int read_only_error(lua_State* L)
{
    std::stringstream ss;

    ss << "'" << lua_tostring(L, lua_upvalueindex(1)) << "' is read-only";

    raise_lua_error(L, "%s", ss.str().c_str());

    return 0;
}

//=================================================================================================
/**
 * @brief __tostring metamethod for a class.
 */
template <class C>
int tostring_metamethod(lua_State* L)
{
    const void* ptr = lua_topointer(L, 1);

    lua_getmetatable(L, -1); // Stack: metatable (mt)
    lua_rawgetp(L, -1, getTypeKey()); // Stack: mt, classname (cn)
    lua_remove(L, -2); // Stack: cn

    std::stringstream ss;
    ss << ": 0x" << std::hex << reinterpret_cast<std::uintptr_t>(const_cast<void*>(ptr));
    lua_pushstring(L, ss.str().c_str()); // Stack: cn, address string (astr)
    lua_concat(L, 2); // Stack: astr

    return 1;
}

//=================================================================================================
/**
 * @brief __destruct metamethod for a class.
 */
template <class C>
int destruct_metamethod(lua_State* L)
{
    LUABRIDGE_ASSERT(lua_isuserdata(L, 1)); // Stack: userdata (ud)
    const auto top = lua_gettop(L);

    const int result = lua_getmetatable(L, 1); // Stack: ud, object metatable (ot) | nothing
    if (result == 0)
        return 0;

    LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: ud, ot

    lua_rawgetp(L, LUA_REGISTRYINDEX, detail::getClassRegistryKey<C>()); // Stack: ud, ot, registry metatable (rt) | nil
    if (lua_istable(L, -1)) // Stack: ud, ot, rt
    {
        rawgetfield(L, -1, "__destruct"); // Stack: ud, ot, rt, ud, function | nil
        if (lua_isfunction(L, -1))
        {
            lua_pushvalue(L, 1); // Stack: ud, ot, rt, function, ud
            lua_pcall(L, 1, 0, 0); // Stack: ud, ot, rt
        }
    }

    lua_settop(L, top); // Stack: ud
    return 0;
}

//=================================================================================================
/**
 * @brief __gc metamethod for a class.
 */
template <class C>
int gc_metamethod(lua_State* L)
{
    destruct_metamethod<C>(L);

    Userdata* ud = Userdata::getExact<C>(L, 1);
    LUABRIDGE_ASSERT(ud);

    ud->~Userdata();

    return 0;
}

//=================================================================================================

template <class T, class C = void>
struct property_getter;

/**
 * @brief lua_CFunction to get a variable.
 *
 * This is used for global variables or class static data members. The pointer to the data is in the first upvalue.
 */
template <class T>
struct property_getter<T, void>
{
    static int call(lua_State* L)
    {
        LUABRIDGE_ASSERT(lua_islightuserdata(L, lua_upvalueindex(1)));

        T* ptr = static_cast<T*>(lua_touserdata(L, lua_upvalueindex(1)));
        LUABRIDGE_ASSERT(ptr != nullptr);

        auto result = Stack<T&>::push(L, *ptr);
        if (! result)
            raise_lua_error(L, "%s", result.message().c_str());

        return 1;
    }
};

/**
 * @brief lua_CFunction to get a class data member.
 *
 * The pointer-to-member is in the first upvalue. The class userdata object is at the top of the Lua stack.
 */
template <class T, class C>
struct property_getter
{
    static int call(lua_State* L)
    {
        C* c = Userdata::get<C>(L, 1, true);

        T C::** mp = static_cast<T C::**>(lua_touserdata(L, lua_upvalueindex(1)));

        Result result;

#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            result = Stack<T&>::push(L, c->**mp);

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        if (! result)
            raise_lua_error(L, "%s", result.message().c_str());

        return 1;
    }
};

/**
 * @brief Helper function to push a property getter on a table at a specific index.
 */
inline void add_property_getter(lua_State* L, const char* name, int tableIndex)
{
#if LUABRIDGE_SAFE_STACK_CHECKS
    luaL_checkstack(L, 2, detail::error_lua_stack_overflow);
#endif

    LUABRIDGE_ASSERT(name != nullptr);
    LUABRIDGE_ASSERT(lua_istable(L, tableIndex));
    LUABRIDGE_ASSERT(lua_iscfunction(L, -1)); // Stack: getter

    lua_rawgetp(L, tableIndex, getPropgetKey()); // Stack: getter, propget table (pg)
    lua_pushvalue(L, -2); // Stack: getter, pg, getter
    rawsetfield(L, -2, name); // Stack: getter, pg
    lua_pop(L, 2); // Stack: -
}

//=================================================================================================

template <class T, class C = void>
struct property_setter;

/**
 * @brief lua_CFunction to set a variable.
 *
 * This is used for global variables or class static data members. The pointer to the data is in the first upvalue.
 */
template <class T>
struct property_setter<T, void>
{
    static int call(lua_State* L)
    {
        LUABRIDGE_ASSERT(lua_islightuserdata(L, lua_upvalueindex(1)));

        T* ptr = static_cast<T*>(lua_touserdata(L, lua_upvalueindex(1)));
        LUABRIDGE_ASSERT(ptr != nullptr);

        auto result = Stack<T>::get(L, 1);
        if (! result)
            raise_lua_error(L, "%s", result.error().message().c_str());

        *ptr = std::move(*result);

        return 0;
    }
};

/**
 * @brief lua_CFunction to set a class data member.
 *
 * The pointer-to-member is in the first upvalue. The class userdata object is at the top of the Lua stack.
 */
template <class T, class C>
struct property_setter
{
    static int call(lua_State* L)
    {
        C* c = Userdata::get<C>(L, 1, false);

        T C::** mp = static_cast<T C::**>(lua_touserdata(L, lua_upvalueindex(1)));

#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            auto result = Stack<T>::get(L, 2);
            if (! result)
                raise_lua_error(L, "%s", result.error().message().c_str());

            c->** mp = std::move(*result);

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        return 0;
    }
};

/**
 * @brief Helper function to push a property setter on a table at a specific index.
 */
inline void add_property_setter(lua_State* L, const char* name, int tableIndex)
{
#if LUABRIDGE_SAFE_STACK_CHECKS
    luaL_checkstack(L, 2, detail::error_lua_stack_overflow);
#endif

    LUABRIDGE_ASSERT(name != nullptr);
    LUABRIDGE_ASSERT(lua_istable(L, tableIndex));
    LUABRIDGE_ASSERT(lua_iscfunction(L, -1)); // Stack: setter

    lua_rawgetp(L, tableIndex, getPropsetKey()); // Stack: setter, propset table (ps)
    lua_pushvalue(L, -2); // Stack: setter, ps, setter
    rawsetfield(L, -2, name); // Stack: setter, ps
    lua_pop(L, 2); // Stack: -
}

//=================================================================================================
/**
 * @brief Function generator.
 */
template <class ReturnType, class ArgsPack, std::size_t Start = 1u>
struct function
{
    template <class F>
    static int call(lua_State* L, F&& func)
    {
        Result result;

#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            result = Stack<ReturnType>::push(L, std::apply(std::forward<F>(func), make_arguments_list<ArgsPack, Start>(L)));

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        if (! result)
            raise_lua_error(L, "%s", result.message().c_str());

        return 1;
    }

    template <class T, class F>
    static int call(lua_State* L, T* ptr, F&& func)
    {
        Result result;

#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            auto f = [ptr, func = std::forward<F>(func)](auto&&... args) -> ReturnType { return (ptr->*func)(std::forward<decltype(args)>(args)...); };

            result = Stack<ReturnType>::push(L, std::apply(f, make_arguments_list<ArgsPack, Start>(L)));

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        if (! result)
            raise_lua_error(L, "%s", result.message().c_str());

        return 1;
    }
};

template <class ArgsPack, std::size_t Start>
struct function<void, ArgsPack, Start>
{
    template <class F>
    static int call(lua_State* L, F&& func)
    {
#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            std::apply(std::forward<F>(func), make_arguments_list<ArgsPack, Start>(L));

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        return 0;
    }

    template <class T, class F>
    static int call(lua_State* L, T* ptr, F&& func)
    {
#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            auto f = [ptr, func = std::forward<F>(func)](auto&&... args) { (ptr->*func)(std::forward<decltype(args)>(args)...); };

            std::apply(f, make_arguments_list<ArgsPack, Start>(L));

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        return 0;
    }
};

//=================================================================================================
/**
 * @brief lua_CFunction to call a class member function with a return value.
 *
 * The member function pointer is in the first upvalue. The class userdata object is at the top of the Lua stack.
 */
template <class F, class T>
int invoke_member_function(lua_State* L)
{
    using FnTraits = function_traits<F>;

    LUABRIDGE_ASSERT(isfulluserdata(L, lua_upvalueindex(1)));

    T* ptr = Userdata::get<T>(L, 1, false);

    const F& func = *static_cast<const F*>(lua_touserdata(L, lua_upvalueindex(1)));
    LUABRIDGE_ASSERT(func != nullptr);

    return function<typename FnTraits::result_type, typename FnTraits::argument_types, 2>::call(L, ptr, func);
}

template <class F, class T>
int invoke_const_member_function(lua_State* L)
{
    using FnTraits = function_traits<F>;

    LUABRIDGE_ASSERT(isfulluserdata(L, lua_upvalueindex(1)));

    const T* ptr = Userdata::get<T>(L, 1, true);

    const F& func = *static_cast<const F*>(lua_touserdata(L, lua_upvalueindex(1)));
    LUABRIDGE_ASSERT(func != nullptr);

    return function<typename FnTraits::result_type, typename FnTraits::argument_types, 2>::call(L, ptr, func);
}

//=================================================================================================
/**
 * @brief lua_CFunction to call a class member lua_CFunction.
 *
 * The member function pointer is in the first upvalue. The object userdata ('this') value is at top ot the Lua stack.
 */
template <class T>
int invoke_member_cfunction(lua_State* L)
{
    using F = int (T::*)(lua_State* L);

    LUABRIDGE_ASSERT(isfulluserdata(L, lua_upvalueindex(1)));

    T* t = Userdata::get<T>(L, 1, false);

    const F& func = *static_cast<const F*>(lua_touserdata(L, lua_upvalueindex(1)));
    LUABRIDGE_ASSERT(func != nullptr);

#if LUABRIDGE_HAS_EXCEPTIONS
    try
    {
#endif
        return (t->*func)(L);

#if LUABRIDGE_HAS_EXCEPTIONS
    }
    catch (const std::exception& e)
    {
        raise_lua_error(L, "%s", e.what());
    }
    
    return 0;
#endif
}

template <class T>
int invoke_const_member_cfunction(lua_State* L)
{
    using F = int (T::*)(lua_State * L) const;

    LUABRIDGE_ASSERT(isfulluserdata(L, lua_upvalueindex(1)));

    const T* t = Userdata::get<T>(L, 1, true);

    const F& func = *static_cast<const F*>(lua_touserdata(L, lua_upvalueindex(1)));
    LUABRIDGE_ASSERT(func != nullptr);

#if LUABRIDGE_HAS_EXCEPTIONS
    try
    {
#endif
        return (t->*func)(L);

#if LUABRIDGE_HAS_EXCEPTIONS
    }
    catch (const std::exception& e)
    {
        raise_lua_error(L, "%s", e.what());
    }
    
    return 0;
#endif
}

//=================================================================================================
/**
 * @brief lua_CFunction to call on a object via function pointer.
 *
 * The proxy function pointer (lightuserdata) is in the first upvalue. The class userdata object is at the top of the Lua stack.
 */
template <class F>
int invoke_proxy_function(lua_State* L)
{
    using FnTraits = function_traits<F>;

    LUABRIDGE_ASSERT(lua_islightuserdata(L, lua_upvalueindex(1)));

    auto func = reinterpret_cast<F>(lua_touserdata(L, lua_upvalueindex(1)));
    LUABRIDGE_ASSERT(func != nullptr);

    return function<typename FnTraits::result_type, typename FnTraits::argument_types, 1>::call(L, func);
}

//=================================================================================================
/**
 * @brief lua_CFunction to call on a object via functor (lambda wrapped in a std::function).
 *
 * The proxy std::function (lightuserdata) is in the first upvalue. The class userdata object is at the top of the Lua stack.
 */
template <class F>
int invoke_proxy_functor(lua_State* L)
{
    using FnTraits = function_traits<std::remove_reference_t<F>>;

    LUABRIDGE_ASSERT(isfulluserdata(L, lua_upvalueindex(1)));

    auto& func = *align<std::remove_reference_t<F>>(lua_touserdata(L, lua_upvalueindex(1)));

    return function<typename FnTraits::result_type, typename FnTraits::argument_types, 1>::call(L, func);
}

//=================================================================================================
/**
 * @brief lua_CFunction to call safely by trapping exceptions
 */
#if LUABRIDGE_SAFE_LUA_C_EXCEPTION_HANDLING && LUABRIDGE_HAS_EXCEPTIONS
inline int invoke_safe_cfunction(lua_State* L)
{
    LUABRIDGE_ASSERT(lua_iscfunction(L, lua_upvalueindex(1)));

    auto func = lua_tocfunction(L, lua_upvalueindex(1));

    try
    {
        return func(L);
    }
    catch (const std::exception& e)
    {
        raise_lua_error(L, "%s", e.what());
    }

    return 0;
}
#endif

//=================================================================================================
/**
 * @brief lua_CFunction to call on a object constructor via functor (lambda wrapped in a std::function).
 *
 * The proxy std::function (lightuserdata) is in the first upvalue. The class userdata object will be pushed at the top of the Lua stack.
 */
template <class F>
int invoke_proxy_constructor(lua_State* L)
{
    using FnTraits = function_traits<F>;

    LUABRIDGE_ASSERT(isfulluserdata(L, lua_upvalueindex(1)));

    auto& func = *align<F>(lua_touserdata(L, lua_upvalueindex(1)));

    function<void, typename FnTraits::argument_types, 1>::call(L, func);

    return 1;
}

//=================================================================================================
/**
 * @brief lua_CFunction to call on a object constructor via functor (lambda wrapped in a std::function).
 *
 * The proxy std::function (lightuserdata) is in the first upvalue. The class userdata object will be pushed at the top of the Lua stack.
 */
template <class F>
int invoke_proxy_destructor(lua_State* L)
{
    using FnTraits = function_traits<F>;

    LUABRIDGE_ASSERT(isfulluserdata(L, lua_upvalueindex(1)));

    auto& func = *align<F>(lua_touserdata(L, lua_upvalueindex(1)));

    function<void, typename FnTraits::argument_types, 1>::call(L, func);

    return 1;
}

//=================================================================================================
/**
 * @brief lua_CFunction to resolve an invocation between several overloads.
 *
 * The list of overloads is in the first upvalue. The arguments of the function call are at the top of the Lua stack.
 */
template <bool Member>
inline int try_overload_functions(lua_State* L)
{
    const int nargs = lua_gettop(L);
    const int effective_args = nargs - (Member ? 1 : 0);

    // get the list of overloads
    lua_pushvalue(L, lua_upvalueindex(1));
    LUABRIDGE_ASSERT(lua_istable(L, -1));
    const int idx_overloads = nargs + 1;
    const int num_overloads = get_length(L, idx_overloads);

    // create table to hold error messages
    lua_createtable(L, num_overloads, 0);
    const int idx_errors = nargs + 2;
    int nerrors = 0;

    // iterate through table, snippet taken from Lua docs
    lua_pushnil(L);  // first key
    while (lua_next(L, idx_overloads) != 0)
    {
        LUABRIDGE_ASSERT(lua_istable(L, -1));

        // check matching arity
        lua_rawgeti(L, -1, 1);
        LUABRIDGE_ASSERT(lua_isnumber(L, -1));

        const int overload_arity = static_cast<int>(lua_tointeger(L, -1));
        if (overload_arity >= 0 && overload_arity != effective_args)
        {
            // store error message and try next overload
            lua_pushfstring(L, "Skipped overload #%d with unmatched arity of %d instead of %d", nerrors, overload_arity, effective_args);
            lua_rawseti(L, idx_errors, ++nerrors);

            lua_pop(L, 2); // pop arity, value (table)
            continue;
        }

        lua_pop(L, 1); // pop arity

        // push function
        lua_pushnumber(L, 2);
        lua_gettable(L, -2);
        LUABRIDGE_ASSERT(lua_isfunction(L, -1));

        // push arguments
        for (int i = 1; i <= nargs; ++i)
            lua_pushvalue(L, i);

        // call f, this pops the function and its args, pushes result(s)
        const int err = lua_pcall(L, nargs, LUA_MULTRET, 0);
        if (err == LUABRIDGE_LUA_OK)
        {
            // calculate number of return values and return
            return lua_gettop(L) - nargs - 4; // 4: overloads, errors, key, table
        }
        else if (err == LUA_ERRRUN)
        {
            // store error message and try next overload
            lua_rawseti(L, idx_errors, ++nerrors);
        }
        else
        {
            return lua_error_x(L);  // critical error: rethrow
        }

        lua_pop(L, 1); // pop value (table)
    }

    lua_Debug debug;
    lua_getstack_info_x(L, 0, "n", &debug);
    lua_pushfstring(L, "All %d overloads of %s returned an error:", nerrors, debug.name);

    // Concatenate error messages of each overload
    for (int i = 1; i <= nerrors; ++i)
    {
        lua_pushfstring(L, "\n%d: ", i);
        lua_rawgeti(L, idx_errors, i);
    }
    lua_concat(L, nerrors * 2 + 1);

    return lua_error_x(L); // throw error message just built
}

//=================================================================================================

// Lua CFunction
inline void push_function(lua_State* L, lua_CFunction fp, const char* debugname)
{
#if LUABRIDGE_SAFE_LUA_C_EXCEPTION_HANDLING && LUABRIDGE_HAS_EXCEPTIONS
    lua_pushcfunction_x(L, fp, debugname);
    lua_pushcclosure_x(L, invoke_safe_cfunction, debugname, 1);
#else
    lua_pushcfunction_x(L, fp, debugname);
#endif
}

// Generic function pointer
template <class ReturnType, class... Params>
inline void push_function(lua_State* L, ReturnType (*fp)(Params...), const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class ReturnType, class... Params>
inline void push_function(lua_State* L, ReturnType (*fp)(Params...) noexcept, const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

// Callable object (lambdas)
template <class F, class = std::enable_if<is_callable_v<F> && !std::is_pointer_v<F> && !std::is_member_function_pointer_v<F>>>
inline void push_function(lua_State* L, F&& f, const char* debugname)
{
    lua_newuserdata_aligned<F>(L, std::forward<F>(f));
    lua_pushcclosure_x(L, &invoke_proxy_functor<F>, debugname, 1);
}

//=================================================================================================
// Lua CFunction
template <class T>
void push_member_function(lua_State* L, lua_CFunction fp, const char* debugname)
{
#if LUABRIDGE_SAFE_LUA_C_EXCEPTION_HANDLING && LUABRIDGE_HAS_EXCEPTIONS
    lua_pushcfunction_x(L, fp, debugname);
    lua_pushcclosure_x(L, invoke_safe_cfunction, debugname, 1);
#else    
    lua_pushcfunction_x(L, fp, debugname);
#endif
}

// Generic function pointer
template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(T*, Params...), const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(T&, Params...), const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(T*, Params...) noexcept, const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(T&, Params...) noexcept, const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(const T*, Params...), const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(const T&, Params...), const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(const T*, Params...) noexcept, const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

template <class T, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (*fp)(const T&, Params...) noexcept, const char* debugname)
{
    using FnType = decltype(fp);

    lua_pushlightuserdata(L, reinterpret_cast<void*>(fp));
    lua_pushcclosure_x(L, &invoke_proxy_function<FnType>, debugname, 1);
}

// Callable object (lambdas)
template <class T, class F, class = std::enable_if<
    is_callable_v<F> &&
        std::is_object_v<F> &&
        !std::is_pointer_v<F> &&
        !std::is_member_function_pointer_v<F>>>
void push_member_function(lua_State* L, F&& f, const char* debugname)
{
    static_assert(std::is_same_v<T, remove_cvref_t<std::remove_pointer_t<function_argument_or_void_t<0, F>>>>);

    lua_newuserdata_aligned<F>(L, std::forward<F>(f));
    lua_pushcclosure_x(L, &invoke_proxy_functor<F>, debugname, 1);
}

// Non const member function pointer
template <class T, class U, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (U::*mfp)(Params...), const char* debugname)
{
    static_assert(std::is_same_v<T, U> || std::is_base_of_v<U, T>);

    using F = decltype(mfp);

    new (lua_newuserdata_x<F>(L, sizeof(F))) F(mfp);
    lua_pushcclosure_x(L, &invoke_member_function<F, T>, debugname, 1);
}

template <class T, class U, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (U::*mfp)(Params...) noexcept, const char* debugname)
{
    static_assert(std::is_same_v<T, U> || std::is_base_of_v<U, T>);

    using F = decltype(mfp);

    new (lua_newuserdata_x<F>(L, sizeof(F))) F(mfp);
    lua_pushcclosure_x(L, &invoke_member_function<F, T>, debugname, 1);
}

// Const member function pointer
template <class T, class U, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (U::*mfp)(Params...) const, const char* debugname)
{
    static_assert(std::is_same_v<T, U> || std::is_base_of_v<U, T>);

    using F = decltype(mfp);

    new (lua_newuserdata_x<F>(L, sizeof(F))) F(mfp);
    lua_pushcclosure_x(L, &detail::invoke_const_member_function<F, T>, debugname, 1);
}

template <class T, class U, class ReturnType, class... Params>
void push_member_function(lua_State* L, ReturnType (U::*mfp)(Params...) const noexcept, const char* debugname)
{
    static_assert(std::is_same_v<T, U> || std::is_base_of_v<U, T>);

    using F = decltype(mfp);

    new (lua_newuserdata_x<F>(L, sizeof(F))) F(mfp);
    lua_pushcclosure_x(L, &detail::invoke_const_member_function<F, T>, debugname, 1);
}

// Non const member Lua CFunction pointer
template <class T, class U = T>
void push_member_function(lua_State* L, int (U::*mfp)(lua_State*), const char* debugname)
{
    static_assert(std::is_same_v<T, U> || std::is_base_of_v<U, T>);

    using F = decltype(mfp);

    new (lua_newuserdata_x<F>(L, sizeof(F))) F(mfp);
    lua_pushcclosure_x(L, &invoke_member_cfunction<T>, debugname, 1);
}

// Const member Lua CFunction pointer
template <class T, class U = T>
void push_member_function(lua_State* L, int (U::*mfp)(lua_State*) const, const char* debugname)
{
    static_assert(std::is_same_v<T, U> || std::is_base_of_v<U, T>);

    using F = decltype(mfp);

    new (lua_newuserdata_x<F>(L, sizeof(F))) F(mfp);
    lua_pushcclosure_x(L, &invoke_const_member_cfunction<T>, debugname, 1);
}

//=================================================================================================
/**
 * @brief
 */
template <class T, class = std::enable_if_t<
    (std::is_base_of_v<T, LuaRef> || !detail::is_callable_v<T*>)>>
void push_property_getter(lua_State* L, const T* value, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(const_cast<T*>(value)));
    lua_pushcclosure_x(L, &property_getter<T>::call, debugname, 1);
}

template <class T>
void push_property_getter(lua_State* L, T (*getter)(), const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)()>, debugname, 1);
}

template <class T>
void push_property_getter(lua_State* L, T (*getter)() noexcept, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)()  noexcept>, debugname, 1);
}

template <class T, class = std::enable_if_t<
    detail::is_callable_v<T>>>
void push_property_getter(lua_State* L, T getter, const char* debugname)
{
    if constexpr (std::is_same_v<T, lua_CFunction>)
    {
        lua_pushcfunction_x(L, getter, debugname);
    }
    else
    {
        lua_newuserdata_aligned<T>(L, std::move(getter));
        lua_pushcclosure_x(L, &invoke_proxy_functor<T>, debugname, 1);
    }
}

//=================================================================================================
/**
 * @brief
 */
template <class C, class T, class U>
void push_class_property_getter(lua_State* L, T (U::*value), const char* debugname)
{
    using MemberValue = decltype(value);

    new (lua_newuserdata_x<MemberValue>(L, sizeof(MemberValue))) MemberValue(value);
    lua_pushcclosure_x(L, &property_getter<T, C>::call, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (C::*getter)() const, const char* debugname)
{
    using GetType = decltype(getter);

    new (lua_newuserdata_x<GetType>(L, sizeof(GetType))) GetType(getter);
    lua_pushcclosure_x(L, &invoke_const_member_function<GetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (C::*getter)() const noexcept, const char* debugname)
{
    using GetType = decltype(getter);

    new (lua_newuserdata_x<GetType>(L, sizeof(GetType))) GetType(getter);
    lua_pushcclosure_x(L, &invoke_const_member_function<GetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (C::*getter)(lua_State*) const, const char* debugname)
{
    using GetType = decltype(getter);

    new (lua_newuserdata_x<GetType>(L, sizeof(GetType))) GetType(getter);
    lua_pushcclosure_x(L, &invoke_const_member_function<GetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (C::*getter)(lua_State*) const noexcept, const char* debugname)
{
    using GetType = decltype(getter);

    new (lua_newuserdata_x<GetType>(L, sizeof(GetType))) GetType(getter);
    lua_pushcclosure_x(L, &invoke_const_member_function<GetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C*), const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C*)>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C&), const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C&)>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C*, lua_State*), const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C*, lua_State*)>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C&, lua_State*), const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C&, lua_State*)>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C*) noexcept, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C*) noexcept>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C&) noexcept, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C&) noexcept>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C*, lua_State*) noexcept, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C*)>, debugname, 1);
}

template <class C, class T>
void push_class_property_getter(lua_State* L, T (*getter)(const C&, lua_State*) noexcept, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(getter));
    lua_pushcclosure_x(L, &invoke_proxy_function<T (*)(const C&, lua_State*) noexcept>, debugname, 1);
}

template <class C>
void push_class_property_getter(lua_State* L, lua_CFunction getter, const char* debugname)
{
    lua_pushcfunction_x(L, getter, debugname);
}

template <class C, class T, class = std::enable_if_t<
    !std::is_pointer_v<T> && detail::is_callable_v<T>>>
void push_class_property_getter(lua_State* L, T getter, const char* debugname)
{
    using FirstArg = detail::function_argument_t<0, T>;
    static_assert(std::is_same_v<std::decay_t<std::remove_reference_t<std::remove_pointer_t<FirstArg>>>, C>);

    lua_newuserdata_aligned<T>(L, std::move(getter));
    lua_pushcclosure_x(L, &invoke_proxy_functor<T>, debugname, 1);
}

//=================================================================================================
/**
 * @brief
 */
template <class T, class = std::enable_if_t<
    (std::is_base_of_v<T, LuaRef> || !detail::is_callable_v<T*>)>>
void push_property_setter(lua_State* L, T* value, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(value));
    lua_pushcclosure_x(L, &property_setter<T>::call, debugname, 1);
}

template <class T>
void push_property_setter(lua_State* L, void (*setter)(T), const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &detail::invoke_proxy_function<void (*)(T)>, debugname, 1);
}

template <class T>
void push_property_setter(lua_State* L, void (*setter)(T) noexcept, const char* debugname)
{
    lua_pushlightuserdata(L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &detail::invoke_proxy_function<void (*)(T) noexcept>, debugname, 1);
}

template <class T, class = std::enable_if_t<
    detail::is_callable_v<T>>>
void push_property_setter(lua_State* L, T setter, const char* debugname)
{
    if constexpr (std::is_same_v<T, lua_CFunction>)
    {
        lua_pushcfunction_x(L, setter, debugname);
    }
    else
    {
        lua_newuserdata_aligned<T>(L, std::move(setter));
        lua_pushcclosure_x(L, &invoke_proxy_functor<T>, debugname, 1);
    }
}

//=================================================================================================
/**
 * @brief
 */
template <class C, class T, class U>
void push_class_property_setter(lua_State* L, T U::*value, const char* debugname)
{
    using MemberValue = decltype(value);

    new (lua_newuserdata_x<MemberValue>(L, sizeof(MemberValue))) MemberValue(value);
    lua_pushcclosure_x(L, &property_setter<T, C>::call, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (C::*setter)(T), const char* debugname)
{
    using SetType = decltype(setter);

    new (lua_newuserdata_x<SetType>(L, sizeof(SetType))) SetType(setter);
    lua_pushcclosure_x(L, &invoke_member_function<SetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (C::*setter)(T) noexcept, const char* debugname)
{
    using SetType = decltype(setter);

    new (lua_newuserdata_x<SetType>(L, sizeof(SetType))) SetType(setter);
    lua_pushcclosure_x(L, &invoke_member_function<SetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (C::*setter)(T, lua_State*), const char* debugname)
{
    using SetType = decltype(setter);

    new (lua_newuserdata_x<SetType>(L, sizeof(SetType))) SetType(setter);
    lua_pushcclosure_x(L, &invoke_member_function<SetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (C::*setter)(T, lua_State*) noexcept, const char* debugname)
{
    using SetType = decltype(setter);

    new (lua_newuserdata_x<SetType>(L, sizeof(SetType))) SetType(setter);
    lua_pushcclosure_x(L, &invoke_member_function<SetType, C>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C*, T), const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C*, T)>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C&, T), const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C&, T)>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C*, T, lua_State*), const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C*, T, lua_State*)>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C&, T, lua_State*), const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C&, T, lua_State*)>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C*, T) noexcept, const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C*, T) noexcept>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C&, T) noexcept, const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C&, T) noexcept>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C*, T, lua_State*) noexcept, const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C*, T, lua_State*) noexcept>, debugname, 1);
}

template <class C, class T>
void push_class_property_setter(lua_State* L, void (*setter)(C&, T, lua_State*) noexcept, const char* debugname)
{
    lua_pushlightuserdata( L, reinterpret_cast<void*>(setter));
    lua_pushcclosure_x(L, &invoke_proxy_function<void (*)(C&, T, lua_State*) noexcept>, debugname, 1);
}

template <class C>
void push_class_property_setter(lua_State* L, lua_CFunction setter, const char* debugname)
{
    lua_pushcfunction_x(L, setter, debugname);
}

template <class C, class T, class = std::enable_if_t<
    !std::is_pointer_v<T> && detail::is_callable_v<T>>>
void push_class_property_setter(lua_State* L, T setter, const char* debugname)
{
    using FirstArg = detail::function_argument_t<0, T>;
    static_assert(std::is_same_v<std::decay_t<std::remove_pointer_t<FirstArg>>, C>);

    lua_newuserdata_aligned<T>(L, std::move(setter));
    lua_pushcclosure_x(L, &invoke_proxy_functor<T>, debugname, 1);
}

//=================================================================================================
/**
 * @brief
 */
inline void push_property_readonly(lua_State* L, const char* debugname)
{
    lua_pushstring(L, debugname);
    lua_pushcclosure_x(L, &detail::read_only_error, debugname, 1);
}

//=================================================================================================
/**
 * @brief Constructor generators.
 *
 * These templates call operator new with the contents of a type/value list passed to the constructor. Two versions of call() are provided.
 * One performs a regular new, the other performs a placement new.
 */
template <class T, class Args>
struct constructor
{
    static T* construct(const Args& args)
    {
        auto alloc = [](auto&&... args) { return new T(std::forward<decltype(args)>(args)...); };

        return std::apply(alloc, args);
    }

    static T* construct(void* ptr, const Args& args)
    {
        auto alloc = [ptr](auto&&... args) { return new (ptr) T(std::forward<decltype(args)>(args)...); };

        return std::apply(alloc, args);
    }
};

//=================================================================================================
/**
 * @brief Placement constructor generators.
 */
template <class T>
struct placement_constructor
{
    template <class F, class Args>
    static T* construct(void* ptr, F&& func, const Args& args)
    {
        auto alloc = [ptr, func = std::forward<F>(func)](auto&&... args) { return func(ptr, std::forward<decltype(args)>(args)...); };

        return std::apply(alloc, args);
    }
};

//=================================================================================================
/**
 * @brief Container allocator generators.
 */
template <class C>
struct container_constructor
{
    template <class F, class Args>
    static C construct(F&& func, const Args& args)
    {
        auto alloc = [func = std::forward<F>(func)](auto&&... args) { return func(std::forward<decltype(args)>(args)...); };

        return std::apply(alloc, args);
    }
};

//=================================================================================================
/**
 * @brief External allocator generators.
 */
template <class T>
struct external_constructor
{
    template <class F, class Args>
    static T* construct(F&& func, const Args& args)
    {
        auto alloc = [func = std::forward<F>(func)](auto&&... args) { return func(std::forward<decltype(args)>(args)...); };

        return std::apply(alloc, args);
    }
};

//=================================================================================================
/**
 * @brief lua_CFunction to construct a class object wrapped in a container.
 */
template <class C, class Args>
int constructor_container_proxy(lua_State* L)
{
    using T = typename ContainerTraits<C>::Type;

    T* object = nullptr;
    
#if LUABRIDGE_HAS_EXCEPTIONS
    try
    {
#endif
        object = constructor<T, Args>::construct(detail::make_arguments_list<Args, 2>(L));

#if LUABRIDGE_HAS_EXCEPTIONS
    }
    catch (const std::exception& e)
    {
        raise_lua_error(L, "%s", e.what());
    }
#endif

    auto result = UserdataSharedHelper<C, false>::push(L, object);
    if (! result)
        raise_lua_error(L, "%s", result.message().c_str());

    return 1;
}

/**
 * @brief lua_CFunction to construct a class object in-place in the userdata.
 */
template <class T, class Args>
int constructor_placement_proxy(lua_State* L)
{
    auto args = make_arguments_list<Args, 2>(L);

    std::error_code ec;
    auto* value = UserdataValue<T>::place(L, ec);
    if (! value)
        raise_lua_error(L, "%s", ec.message().c_str());

#if LUABRIDGE_HAS_EXCEPTIONS
    try
    {
#endif

        constructor<T, Args>::construct(value->getObject(), std::move(args));

#if LUABRIDGE_HAS_EXCEPTIONS
    }
    catch (const std::exception& e)
    {
        raise_lua_error(L, "%s", e.what());
    }
#endif
        
    value->commit();

    return 1;
}

//=================================================================================================
/**
 * @brief Constructor forwarder.
 */
template <class T, class F>
struct constructor_forwarder
{
    explicit constructor_forwarder(F f)
        : m_func(std::move(f))
    {
    }

    T* operator()(lua_State* L)
    {
        using FnTraits = function_traits<F>;
        using FnArgs = remove_first_type_t<typename FnTraits::argument_types>;

        auto args = make_arguments_list<FnArgs, 2>(L);

        std::error_code ec;
        auto* value = UserdataValue<T>::place(L, ec);
        if (! value)
            raise_lua_error(L, "%s", ec.message().c_str());

        T* object = nullptr;
        
#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            object = placement_constructor<T>::construct(value->getObject(), m_func, std::move(args));

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        value->commit();

        return object;
    }

private:
    F m_func;
};

//=================================================================================================
/**
 * @brief Constructor forwarder.
 */
template <class T, class F>
struct destructor_forwarder
{
    explicit destructor_forwarder(F f)
        : m_func(std::move(f))
    {
    }

    void operator()(lua_State* L)
    {
        auto* value = Userdata::get<T>(L, -1, false);
        if (value == nullptr)
            raise_lua_error(L, "invalid object destruction");

        std::invoke(m_func, value);
    }

private:
    F m_func;
};

//=================================================================================================
/**
 * @brief Constructor forwarder.
 */
template <class T, class Alloc, class Dealloc>
struct factory_forwarder
{
    explicit factory_forwarder(Alloc alloc, Dealloc dealloc)
        : m_alloc(std::move(alloc))
        , m_dealloc(std::move(dealloc))
    {
    }

    T* operator()(lua_State* L)
    {
        using FnTraits = function_traits<Alloc>;
        using FnArgs = typename FnTraits::argument_types;

        T* object = nullptr;
        
#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            object = external_constructor<T>::construct(m_alloc, make_arguments_list<FnArgs, 0>(L));

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        std::error_code ec;
        auto* value = UserdataValueExternal<T>::place(L, object, m_dealloc, ec);
        if (! value)
            raise_lua_error(L, "%s", ec.message().c_str());

        return object;
    }

private:
    Alloc m_alloc;
    Dealloc m_dealloc;
};

//=================================================================================================
/**
 * @brief Container forwarder.
 */
template <class C, class F>
struct container_forwarder
{
    explicit container_forwarder(F f)
        : m_func(std::move(f))
    {
    }

    C operator()(lua_State* L)
    {
        using FnTraits = function_traits<F>;
        using FnArgs = typename FnTraits::argument_types;

        C object;
        
#if LUABRIDGE_HAS_EXCEPTIONS
        try
        {
#endif
            object = container_constructor<C>::construct(m_func, make_arguments_list<FnArgs, 2>(L));

#if LUABRIDGE_HAS_EXCEPTIONS
        }
        catch (const std::exception& e)
        {
            raise_lua_error(L, "%s", e.what());
        }
#endif

        auto result = UserdataSharedHelper<C, false>::push(L, object);
        if (! result)
            raise_lua_error(L, "%s", result.message().c_str());

        return object;
    }

private:
    F m_func;
};

} // namespace detail
} // namespace luabridge

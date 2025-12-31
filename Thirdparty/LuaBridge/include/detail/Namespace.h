// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2019, Dmitry Tarakanov
// Copyright 2012, Vinnie Falco <vinnie.falco@gmail.com>
// Copyright 2007, Nathan Reed
// SPDX-License-Identifier: MIT

#pragma once

#include "Config.h"
#include "ClassInfo.h"
#include "FlagSet.h"
#include "LuaHelpers.h"
#include "LuaException.h"
#include "Options.h"
#include "TypeTraits.h"

#include <stdexcept>
#include <string_view>
#include <string>
#include <type_traits>
#include <utility>

namespace luabridge {

//=================================================================================================
/**
 * @brief Base for class and namespace registration.
 *
 * Maintains Lua stack in the proper state. Once beginNamespace, beginClass or deriveClass is called the parent object upon its destruction
 * may no longer clear the Lua stack.
 *
 * Then endNamespace or endClass is called, a new parent is created and the child transfers the responsibility for clearing stack to it.
 *
 * So there can be maximum one "active" registrar object.
 */
namespace detail {

class Registrar
{
protected:
    Registrar(lua_State* L)
        : L(L)
        , m_stackSize(0)
    {
    }

    Registrar(lua_State* L, int skipStackPops)
        : L(L)
        , m_stackSize(0)
        , m_skipStackPops(skipStackPops)
    {
    }

    Registrar(const Registrar& rhs) = delete;

    Registrar(Registrar&& rhs)
        : L(rhs.L)
        , m_stackSize(std::exchange(rhs.m_stackSize, 0))
        , m_skipStackPops(std::exchange(rhs.m_skipStackPops, 0))
    {
    }

    Registrar& operator=(const Registrar& rhs) = delete;

    Registrar& operator=(Registrar&& rhs)
    {
        m_stackSize = std::exchange(rhs.m_stackSize, 0);
        m_skipStackPops = std::exchange(rhs.m_skipStackPops, 0);

        return *this;
    }

    ~Registrar()
    {
        const int popsCount = m_stackSize - m_skipStackPops;
        if (popsCount > 0)
        {
            LUABRIDGE_ASSERT(popsCount <= lua_gettop(L));

            lua_pop(L, popsCount);
        }
    }

    void assertIsActive() const
    {
        if (m_stackSize == 0)
        {
            throw_or_assert<std::logic_error>("Unable to continue registration");
        }
    }

    lua_State* const L = nullptr;
    int m_stackSize = 0;
    int m_skipStackPops = 0;
};

} // namespace detail

//=================================================================================================
/**
 * @brief Provides C++ to Lua registration capabilities.
 *
 * This class is not instantiated directly, call `getGlobalNamespace` to start the registration process.
 */
class Namespace : public detail::Registrar
{
    //=============================================================================================
#if 0
    /**
     * @brief Error reporting.
     *
     * This function looks handy, why aren't we using it?
     */
    static int luaError(lua_State* L, std::string message)
    {
        LUABRIDGE_ASSERT(lua_isstring(L, lua_upvalueindex(1)));
        std::string s;

        // Get information on the caller's caller to format the message,
        // so the error appears to originate from the Lua source.
        lua_Debug ar;

        int result = lua_getstack(L, 2, &ar);
        if (result != 0)
        {
            lua_getinfo(L, "Sl", &ar);
            s = ar.short_src;
            if (ar.currentline != -1)
            {
                // poor mans int to string to avoid <strstrream>.
                lua_pushnumber(L, ar.currentline);
                s = s + ":" + lua_tostring(L, -1) + ": ";
                lua_pop(L, 1);
            }
        }

        s = s + message;

        luaL_error(L, "%s", s.c_str());

        return 0;
    }
#endif

    //=============================================================================================
    /**
     * @brief Factored base to reduce template instantiations.
     */
    class ClassBase : public detail::Registrar
    {
    public:
        explicit ClassBase(const char* name, Namespace parent)
            : Registrar(std::move(parent))
            , className(name == nullptr ? "" : name)
        {
        }

        using Registrar::operator=;

    protected:
        //=========================================================================================
        /**
         * @brief Create the const table.
         */
        void createConstTable(const char* name, bool trueConst, Options options)
        {
            LUABRIDGE_ASSERT(name != nullptr);

            std::string type_name = std::string(trueConst ? "const " : "") + name;

            // Stack: namespace table (ns)

            lua_newtable(L); // Stack: ns, const table (co)
            lua_pushvalue(L, -1); // Stack: ns, co, co
            lua_setmetatable(L, -2); // co.__metatable = co. Stack: ns, co

            pushunsigned(L, options.toUnderlying()); // Stack: ns, co, options
            lua_rawsetp(L, -2, detail::getClassOptionsKey()); // co [classOptionsKey] = options. Stack: ns, co

            lua_pushstring(L, type_name.c_str()); // Stack: ns, co, name
            lua_rawsetp(L, -2, detail::getTypeKey()); // co [typeKey] = name. Stack: ns, co

            lua_pushcfunction_x(L, &detail::index_metamethod<true>, "__index"); // Stack: ns, co, im
            rawsetfield(L, -2, "__index"); // Stack: ns, co

            lua_pushcfunction_x(L, &detail::newindex_metamethod<true>, "__newindex"); // Stack: ns, co, nim
            rawsetfield(L, -2, "__newindex"); // Stack: ns, co

            lua_newtable(L); // Stack: ns, co, tb
            lua_rawsetp(L, -2, detail::getPropgetKey()); // Stack: ns, co

            if (! options.test(visibleMetatables))
            {
                lua_pushboolean(L, 0);
                rawsetfield(L, -2, "__metatable");
            }
        }

        //=========================================================================================
        /**
         * @brief Create the class table.
         *
         * The Lua stack should have the const table on top.
         */
        void createClassTable(const char* name, Options options)
        {
            LUABRIDGE_ASSERT(name != nullptr);

            // Stack: namespace table (ns), const table (co)

            // Class table is the same as const table except the propset table
            createConstTable(name, false, options); // Stack: ns, co, cl

            lua_newtable(L); // Stack: ns, co, cl, propset table (ps)
            lua_rawsetp(L, -2, detail::getPropsetKey()); // cl [propsetKey] = ps. Stack: ns, co, cl

            lua_pushvalue(L, -2); // Stack: ns, co, cl, co
            lua_rawsetp(L, -2, detail::getConstKey()); // cl [constKey] = co. Stack: ns, co, cl

            lua_pushvalue(L, -1); // Stack: ns, co, cl, cl
            lua_rawsetp(L, -3, detail::getClassKey()); // co [classKey] = cl. Stack: ns, co, cl
        }

        //=========================================================================================
        /**
         * @brief Create the static table.
         */
        void createStaticTable(const char* name, Options options)
        {
            LUABRIDGE_ASSERT(name != nullptr);

            // Stack: namespace table (ns), const table (co), class table (cl)

            lua_newtable(L); // Stack: ns, co, cl, static table (st)
            lua_newtable(L); // Stack: ns, co, cl, st, static metatable (mt)
            lua_pushvalue(L, -1); // Stack: ns, co, cl, st, mt, mt
            lua_setmetatable(L, -3); // st.__metatable = mt. Stack: ns, co, cl, st, mt
            lua_insert(L, -2); // Stack: ns, co, cl, st, mt, st
            rawsetfield(L, -5, name); // ns [name] = st. Stack: ns, co, cl, st, mt

            pushunsigned(L, options.toUnderlying()); // Stack: ns, co, cl, st, mt, options
            lua_rawsetp(L, -2, detail::getClassOptionsKey()); // st [classOptionsKey] = options. Stack: ns, co, cl, st, mt

            lua_pushcfunction_x(L, &detail::index_metamethod<false>, "__index");
            rawsetfield(L, -2, "__index");

            lua_pushcfunction_x(L, &detail::newindex_metamethod<false>, "__newindex");
            rawsetfield(L, -2, "__newindex");

            lua_newtable(L); // Stack: ns, co, cl, st, proget table (pg)
            lua_rawsetp(L, -2, detail::getPropgetKey()); // st [propgetKey] = pg. Stack: ns, co, cl, st

            lua_newtable(L); // Stack: ns, co, cl, st, propset table (ps)
            lua_rawsetp(L, -2, detail::getPropsetKey()); // st [propsetKey] = pg. Stack: ns, co, cl, st

            lua_pushvalue(L, -2); // Stack: ns, co, cl, st, cl
            lua_rawsetp(L, -2, detail::getClassKey()); // st [classKey] = cl. Stack: ns, co, cl, st

            if (! options.test(visibleMetatables))
            {
                lua_pushboolean(L, 0);
                rawsetfield(L, -2, "__metatable");
            }
        }

        //=========================================================================================
        /**
         * @brief Asserts on stack state.
         */
        void assertStackState() const
        {
            // Stack: const table (co), class table (cl), static table (st)
            LUABRIDGE_ASSERT(lua_istable(L, -3));
            LUABRIDGE_ASSERT(lua_istable(L, -2));
            LUABRIDGE_ASSERT(lua_istable(L, -1));
        }

        //=========================================================================================
        const char* className = "";
    };

    //=============================================================================================
    /**
     * @brief Provides a class registration in a lua_State.
     *
     * After construction the Lua stack holds these objects:
     *   -1 static table
     *   -2 class table
     *   -3 const table
     *   -4 enclosing namespace table
     */
    template <class T>
    class Class : public ClassBase
    {
    public:
        //=========================================================================================

        /**
         * @brief Register a new class or add to an existing class registration.
         *
         * @param name   The new class name.
         * @param parent A parent namespace object.
         * @param options Class options.
         */
        Class(const char* name, Namespace parent, Options options)
            : ClassBase(name, std::move(parent))
        {
            LUABRIDGE_ASSERT(name != nullptr);
            LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

            rawgetfield(L, -1, name); // Stack: ns, static table (st) | nil

            if (lua_isnil(L, -1)) // Stack: ns, nil
            {
                lua_pop(L, 1); // Stack: ns

                createConstTable(name, true, options); // Stack: ns, const table (co)
                ++m_stackSize;
#if !defined(LUABRIDGE_ON_LUAU)
                lua_pushcfunction_x(L, &detail::gc_metamethod<T>, "__gc"); // Stack: ns, co, function
                rawsetfield(L, -2, "__gc"); // co ["__gc"] = function. Stack: ns, co
#endif
                lua_pushcfunction_x(L, &detail::tostring_metamethod<T>, "__tostring");
                rawsetfield(L, -2, "__tostring");

                createClassTable(name, options); // Stack: ns, co, class table (cl)
                ++m_stackSize;
#if !defined(LUABRIDGE_ON_LUAU)
                lua_pushcfunction_x(L, &detail::gc_metamethod<T>, "__gc"); // Stack: ns, co, cl, function
                rawsetfield(L, -2, "__gc"); // cl ["__gc"] = function. Stack: ns, co, cl
#endif

                lua_pushcfunction_x(L, &detail::tostring_metamethod<T>, "__tostring");
                rawsetfield(L, -2, "__tostring");

                createStaticTable(name, options); // Stack: ns, co, cl, st
                ++m_stackSize;

                lua_pushvalue(L, -1); // Stack: ns, co, cl, st, st
                lua_rawsetp(L, -2, detail::getStaticKey()); // cl [staticKey] = st. Stack: ns, co, cl, st
                lua_pushvalue(L, -1); // Stack: ns, co, cl, st, st
                lua_rawsetp(L, -3, detail::getStaticKey()); // co [staticKey] = st. Stack: ns, co, cl, st

                // Map T back to its tables.
                lua_pushvalue(L, -1); // Stack: ns, co, cl, st, st
                lua_rawsetp(L, LUA_REGISTRYINDEX, detail::getStaticRegistryKey<T>()); // Stack: ns, co, cl, st
                lua_pushvalue(L, -2); // Stack: ns, co, cl, st, cl
                lua_rawsetp(L, LUA_REGISTRYINDEX, detail::getClassRegistryKey<T>()); // Stack: ns, co, cl, st
                lua_pushvalue(L, -3); // Stack: ns, co, cl, st, co
                lua_rawsetp(L, LUA_REGISTRYINDEX, detail::getConstRegistryKey<T>()); // Stack: ns, co, cl, st
            }
            else
            {
                LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: ns, vst
                ++m_stackSize;

                lua_getmetatable(L, -1); // Stack: ns, vst, st
                lua_insert(L, -2); // Stack: ns, st, vst
                lua_pop(L, 1); // Stack: ns, st

                // Map T back from its stored tables
                lua_rawgetp(L, LUA_REGISTRYINDEX, detail::getConstRegistryKey<T>()); // Stack: ns, st, co
                LUABRIDGE_ASSERT(lua_istable(L, -1)); // Class was previously registered as table or namespace ?
                lua_insert(L, -2); // Stack: ns, co, st
                ++m_stackSize;

                lua_rawgetp(L, LUA_REGISTRYINDEX, detail::getClassRegistryKey<T>()); // Stack: ns, co, st, cl
                LUABRIDGE_ASSERT(lua_istable(L, -1)); // Class was previously registered as table or namespace ?
                lua_insert(L, -2); // Stack: ns, co, cl, st
                ++m_stackSize;
            }
        }

        //=========================================================================================
        /**
         * @brief Derive a new class.
         *
         * @param name The class name.
         * @param parent A parent namespace object.
         * @param staticKey Key where the class is stored.
        */
        Class(const char* name, Namespace parent, const void* const staticKey, Options options)
            : ClassBase(name, std::move(parent))
        {
            LUABRIDGE_ASSERT(name != nullptr);
            LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

            createConstTable(name, true, options); // Stack: ns, const table (co)
            ++m_stackSize;
#if !defined(LUABRIDGE_ON_LUAU)
            lua_pushcfunction_x(L, &detail::gc_metamethod<T>, "__gc"); // Stack: ns, co, function
            rawsetfield(L, -2, "__gc"); // co ["__gc"] = function. Stack: ns, co
#endif
            lua_pushcfunction_x(L, &detail::tostring_metamethod<T>, "__tostring");
            rawsetfield(L, -2, "__tostring");

            createClassTable(name, options); // Stack: ns, co, class table (cl)
            ++m_stackSize;
#if !defined(LUABRIDGE_ON_LUAU)
            lua_pushcfunction_x(L, &detail::gc_metamethod<T>, "__gc"); // Stack: ns, co, cl, function
            rawsetfield(L, -2, "__gc"); // cl ["__gc"] = function. Stack: ns, co, cl
#endif
            lua_pushcfunction_x(L, &detail::tostring_metamethod<T>, "__tostring");
            rawsetfield(L, -2, "__tostring");

            createStaticTable(name, options); // Stack: ns, co, cl, st
            ++m_stackSize;

            lua_pushvalue(L, -1); // Stack: ns, co, cl, st, st
            lua_rawsetp(L, -2, detail::getStaticKey()); // cl [staticKey] = st. Stack: ns, co, cl, st
            lua_pushvalue(L, -1); // Stack: ns, co, cl, st, st
            lua_rawsetp(L, -3, detail::getStaticKey()); // co [staticKey] = st. Stack: ns, co, cl, st

            lua_rawgetp(L, LUA_REGISTRYINDEX, staticKey); // Stack: ns, co, cl, st, parent st (pst) | nil
            if (lua_isnil(L, -1)) // Stack: ns, co, cl, st, nil
            {
                lua_pop(L, 1);

                throw_or_assert<std::logic_error>("Base class is not registered");
                return;
            }

            LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: ns, co, cl, st, pst

            lua_rawgetp(L, -1, detail::getClassKey()); // Stack: ns, co, cl, st, pst, parent cl (pcl)
            LUABRIDGE_ASSERT(lua_istable(L, -1));

            lua_rawgetp(L, -1, detail::getConstKey()); // Stack: ns, co, cl, st, pst, pcl, parent co (pco)
            LUABRIDGE_ASSERT(lua_istable(L, -1));

            lua_rawsetp(L, -6, detail::getParentKey()); // co [parentKey] = pco. Stack: ns, co, cl, st, pst, pcl
            lua_rawsetp(L, -4, detail::getParentKey()); // cl [parentKey] = pcl. Stack: ns, co, cl, st, pst
            lua_rawsetp(L, -2, detail::getParentKey()); // st [parentKey] = pst. Stack: ns, co, cl, st

            lua_pushvalue(L, -1); // Stack: ns, co, cl, st, st
            lua_rawsetp(L, LUA_REGISTRYINDEX, detail::getStaticRegistryKey<T>()); // Stack: ns, co, cl, st
            lua_pushvalue(L, -2); // Stack: ns, co, cl, st, cl
            lua_rawsetp(L, LUA_REGISTRYINDEX, detail::getClassRegistryKey<T>()); // Stack: ns, co, cl, st
            lua_pushvalue(L, -3); // Stack: ns, co, cl, st, co
            lua_rawsetp(L, LUA_REGISTRYINDEX, detail::getConstRegistryKey<T>()); // Stack: ns, co, cl, st
        }

        //=========================================================================================
        /**
         * @brief Continue registration in the enclosing namespace.
         *
         * @returns A parent registration object.
         */
        Namespace endClass()
        {
            LUABRIDGE_ASSERT(m_stackSize > 3);

            m_stackSize -= 3;
            lua_pop(L, 3);

            return Namespace(std::move(*this));
        }

        //=========================================================================================
        /**
         * @brief Add or replace a static property.
         */
        template <class Getter>
        Class<T>& addStaticProperty(const char* name, Getter get, bool) = delete;

        template <class Getter>
        Class<T>& addStaticProperty(const char* name, Getter get)
        {
            LUABRIDGE_ASSERT(name != nullptr);
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            detail::push_property_getter(L, std::move(get), name); // Stack: co, cl, st, function
            detail::add_property_getter(L, name, -2); // Stack: co, cl, st

            detail::push_property_readonly(L, name); // Stack: co, cl, st, function
            detail::add_property_setter(L, name, -2); // Stack: co, cl, st

            return *this;
        }

        template <class Getter, class Setter>
        Class<T>& addStaticProperty(const char* name, Getter get, Setter set)
        {
            LUABRIDGE_ASSERT(name != nullptr);
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            detail::push_property_getter(L, std::move(get), name); // Stack: co, cl, st, function
            detail::add_property_getter(L, name, -2); // Stack: co, cl, st

            detail::push_property_setter(L, std::move(set), name); // Stack: co, cl, st, function
            detail::add_property_setter(L, name, -2); // Stack: co, cl, st

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a single static function or multiple overloaded functions.
         *
         * @param name The overload name.
         * @param functions A single or set of static functions that will be invoked.
         *
         * @returns This class registration object.
         */
        template <class... Functions>
        auto addStaticFunction(const char* name, Functions... functions)
            -> std::enable_if_t<(detail::is_callable_v<Functions> && ...) && (sizeof...(Functions) > 0), Class<T>&>
        {
            LUABRIDGE_ASSERT(name != nullptr);
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            if constexpr (sizeof...(Functions) == 1)
            {
                ([&]
                {
                    detail::push_function(L, std::move(functions), name);

                } (), ...);
            }
            else
            {
                // create new closure of try_overloads with new table
                lua_createtable(L, static_cast<int>(sizeof...(Functions)), 0); // reserve space for N overloads

                int idx = 1;

                ([&]
                {
                    lua_createtable(L, 2, 0); // reserve space for: function, arity
                    lua_pushinteger(L, 1);
                    if constexpr (detail::is_any_cfunction_pointer_v<Functions>)
                        lua_pushinteger(L, -1);
                    else
                        lua_pushinteger(L, static_cast<int>(detail::function_arity_excluding_v<Functions, lua_State*>));
                    lua_settable(L, -3);
                    lua_pushinteger(L, 2);
                    detail::push_function(L, std::move(functions), name);
                    lua_settable(L, -3);

                    lua_rawseti(L, -2, idx);
                    ++idx;

                } (), ...);

                lua_pushcclosure_x(L, &detail::try_overload_functions<false>, name, 1);
            }

            rawsetfield(L, -2, name);

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a property member, by constructible by std::function.
         */
        template <class Getter>
        Class<T>& addProperty(const char* name, Getter getter, bool) = delete;

        template <class Getter>
        Class<T>& addProperty(const char* name, Getter getter)
        {
            LUABRIDGE_ASSERT(name != nullptr);
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            detail::push_class_property_getter<T>(L, std::move(getter), name); // Stack: co, cl, st, getter
            lua_pushvalue(L, -1); // Stack: co, cl, st, getter, getter
            detail::add_property_getter(L, name, -4); // Stack: co, cl, st, getter
            detail::add_property_getter(L, name, -4); // Stack: co, cl, st

            detail::push_property_readonly(L, name); // Stack: co, cl, st, function
            detail::add_property_setter(L, name, -3); // Stack: co, cl, st

            return *this;
        }

        template <class Getter, class Setter>
        Class<T>& addProperty(const char* name, Getter getter, Setter setter)
        {
            LUABRIDGE_ASSERT(name != nullptr);
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            detail::push_class_property_getter<T>(L, std::move(getter), name); // Stack: co, cl, st, getter
            lua_pushvalue(L, -1); // Stack: co, cl, st, getter, getter
            detail::add_property_getter(L, name, -4); // Stack: co, cl, st, getter
            detail::add_property_getter(L, name, -4); // Stack: co, cl, st

            detail::push_class_property_setter<T>(L, std::move(setter), name); // Stack: co, cl, st, setter
            detail::add_property_setter(L, name, -3); // Stack: co, cl, st

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a function that can operate on the class.
         *
         * @param name The function or overloaded functions name.
         * @param functions A single or set of functions that will be invoked.
         *
         * @returns This class registration object.
         */
        template <class... Functions>
        auto addFunction(const char* name, Functions... functions)
            -> std::enable_if_t<(detail::is_callable_v<Functions> && ...) && (sizeof...(Functions) > 0), Class<T>&>
        {
            LUABRIDGE_ASSERT(name != nullptr);
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            if (name == std::string_view("__gc"))
            {
                throw_or_assert<std::logic_error>("__gc metamethod registration is forbidden");
                return *this;
            }

            if constexpr (sizeof...(Functions) == 1)
            {
                ([&]
                {
                    detail::push_member_function<T>(L, std::move(functions), name);

                } (), ...);

                if constexpr (detail::const_functions_count<T, Functions...> == 1)
                {
                    lua_pushvalue(L, -1); // Stack: co, cl, st, function, function
                    rawsetfield(L, -4, name); // Stack: co, cl, st, function
                    rawsetfield(L, -4, name); // Stack: co, cl, st
                }
                else
                {
                    rawsetfield(L, -3, name); // Stack: co, cl, st
                }
            }
            else
            {
                // create new closure of const try_overload_functions with new table
                if constexpr (detail::const_functions_count<T, Functions...> > 0)
                {
                    lua_createtable(L, static_cast<int>(detail::const_functions_count<T, Functions...>), 0);

                    int idx = 1;

                    ([&]
                    {
                        if (!detail::is_const_function<T, Functions>)
                            return;

                        lua_createtable(L, 2, 0); // reserve space for: function, arity
                        lua_pushinteger(L, 1);
                        if constexpr (detail::is_any_cfunction_pointer_v<Functions>)
                            lua_pushinteger(L, -1);
                        else
                            lua_pushinteger(L, static_cast<int>(detail::member_function_arity_excluding_v<T, Functions, lua_State*>));
                        lua_settable(L, -3);
                        lua_pushinteger(L, 2);
                        detail::push_member_function<T>(L, std::move(functions), name);
                        lua_settable(L, -3);

                        lua_rawseti(L, -2, idx);
                        ++idx;

                    } (), ...);

                    LUABRIDGE_ASSERT(idx > 1);

                    lua_pushcclosure_x(L, &detail::try_overload_functions<true>, name, 1);
                    lua_pushvalue(L, -1); // Stack: co, cl, st, function, function
                    rawsetfield(L, -4, name); // Stack: co, cl, st, function
                    rawsetfield(L, -4, name); // Stack: co, cl, st
                }

                // create new closure of non const try_overload_functions with new table
                if constexpr (detail::non_const_functions_count<T, Functions...> > 0)
                {
                    lua_createtable(L, static_cast<int>(detail::non_const_functions_count<T, Functions...>), 0);

                    int idx = 1;

                    ([&]
                    {
                        if (detail::is_const_function<T, Functions>)
                            return;

                        lua_createtable(L, 2, 0); // reserve space for: function, arity
                        lua_pushinteger(L, 1);
                        if constexpr (detail::is_any_cfunction_pointer_v<Functions>)
                            lua_pushinteger(L, -1);
                        else
                            lua_pushinteger(L, static_cast<int>(detail::member_function_arity_excluding_v<T, Functions, lua_State*>));
                        lua_settable(L, -3);
                        lua_pushinteger(L, 2);
                        detail::push_member_function<T>(L, std::move(functions), name);
                        lua_settable(L, -3);

                        lua_rawseti(L, -2, idx);
                        ++idx;

                    } (), ...);

                    LUABRIDGE_ASSERT(idx > 1);

                    lua_pushcclosure_x(L, &detail::try_overload_functions<true>, name, 1);
                    rawsetfield(L, -3, name); // Stack: co, cl, st
                }
            }

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a primary Constructor.
         *
         * The primary Constructor is invoked when calling the class type table like a function.
         *
         * The template parameter should be a function pointer type that matches the desired Constructor (since you can't take the
         * address of a Constructor and pass it as an argument).
         */
        template <class... Functions>
        auto addConstructor()
            -> std::enable_if_t<(sizeof...(Functions) > 0), Class<T>&>
        {
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            if constexpr (sizeof...(Functions) == 1)
            {
                ([&]
                {
                    lua_pushcclosure_x(L, &detail::constructor_placement_proxy<T, detail::function_arguments_t<Functions>>, className, 0);

                } (), ...);
            }
            else
            {
                // create new closure of try_overloads with new table
                lua_createtable(L, static_cast<int>(sizeof...(Functions)), 0); // reserve space for N overloads

                int idx = 1;

                ([&]
                {
                    lua_createtable(L, 2, 0); // reserve space for: function, arity
                    lua_pushinteger(L, 1);
                    lua_pushinteger(L, static_cast<int>(detail::function_arity_excluding_v<Functions, lua_State*>));
                    lua_settable(L, -3);
                    lua_pushinteger(L, 2);
                    lua_pushcclosure_x(L, &detail::constructor_placement_proxy<T, detail::function_arguments_t<Functions>>, className, 0);
                    lua_settable(L, -3);
                    lua_rawseti(L, -2, idx);
                    ++idx;

                } (), ...);

                lua_pushcclosure_x(L, &detail::try_overload_functions<true>, className, 1);
            }

            rawsetfield(L, -2, "__call");

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a placement constructor.
         *
         * The primary placement constructor is invoked when calling the class type table like a function.
         *
         * The provider of the Function argument is responsible of doing placement new of the type T over the void* pointer provided to
         * the method as first argument.
         */
        template <class... Functions>
        auto addConstructor(Functions... functions)
            -> std::enable_if_t<(detail::is_callable_v<Functions> && ...) && (sizeof...(Functions) > 0), Class<T>&>
        {
            static_assert(((detail::function_arity_excluding_v<Functions, lua_State*> >= 1) && ...));
            static_assert(((std::is_same_v<detail::function_argument_t<0, Functions>, void*>) && ...));

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            if constexpr (sizeof...(Functions) == 1)
            {
                ([&]
                {
                    using F = detail::constructor_forwarder<T, Functions>;

                    lua_newuserdata_aligned<F>(L, F(std::move(functions))); // Stack: co, cl, st, upvalue
                    lua_pushcclosure_x(L, &detail::invoke_proxy_constructor<F>, className, 1); // Stack: co, cl, st, function

                } (), ...);
            }
            else
            {
                // create new closure of try_overloads with new table
                lua_createtable(L, static_cast<int>(sizeof...(Functions)), 0); // reserve space for N overloads

                int idx = 1;

                ([&]
                {
                    using F = detail::constructor_forwarder<T, Functions>;

                    lua_createtable(L, 2, 0); // reserve space for: function, arity
                    lua_pushinteger(L, 1);
                    if constexpr (detail::is_any_cfunction_pointer_v<Functions>)
                        lua_pushinteger(L, -1);
                    else
                        lua_pushinteger(L, static_cast<int>(detail::function_arity_excluding_v<Functions, lua_State*>) - 1); // 1: for void* ptr
                    lua_settable(L, -3);
                    lua_pushinteger(L, 2);
                    lua_newuserdata_aligned<F>(L, F(std::move(functions)));
                    lua_pushcclosure_x(L, &detail::invoke_proxy_constructor<F>, className, 1);
                    lua_settable(L, -3);
                    lua_rawseti(L, -2, idx);
                    ++idx;

                } (), ...);

                lua_pushcclosure_x(L, &detail::try_overload_functions<true>, className, 1);
            }

            rawsetfield(L, -2, "__call"); // Stack: co, cl, st

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a primary Constructor when the type is used from an intrusive container C.
         */
        template <class C, class... Functions>
        auto addConstructorFrom()
            -> std::enable_if_t<(sizeof...(Functions) > 0), Class<T>&>
        {
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            if constexpr (sizeof...(Functions) == 1)
            {
                ([&]
                {
                    lua_pushcclosure_x(L, &detail::constructor_container_proxy<C, detail::function_arguments_t<Functions>>, className, 0);

                } (), ...);
            }
            else
            {
                // create new closure of try_overloads with new table
                lua_createtable(L, static_cast<int>(sizeof...(Functions)), 0); // reserve space for N overloads

                int idx = 1;

                ([&]
                {
                    lua_createtable(L, 2, 0); // reserve space for: function, arity
                    lua_pushinteger(L, 1);
                    lua_pushinteger(L, static_cast<int>(detail::function_arity_excluding_v<Functions, lua_State*>));
                    lua_settable(L, -3);
                    lua_pushinteger(L, 2);
                    lua_pushcclosure_x(L, &detail::constructor_container_proxy<C, detail::function_arguments_t<Functions>>, className, 0);
                    lua_settable(L, -3);
                    lua_rawseti(L, -2, idx);
                    ++idx;

                } (), ...);

                lua_pushcclosure_x(L, &detail::try_overload_functions<true>, className, 1);
            }

            rawsetfield(L, -2, "__call");

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a primary Constructor when the type is used from an intrusive container C.
         *
         * The provider of the Function argument is responsible of constructing the container C forwarding arguments in the callable Functions passed in.
         */
        template <class C, class... Functions>
        auto addConstructorFrom(Functions... functions)
            -> std::enable_if_t<(detail::is_callable_v<Functions> && ...) && (sizeof...(Functions) > 0), Class<T>&>
        {
            static_assert(((std::is_same_v<detail::function_result_t<Functions>, C>) && ...));

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            if constexpr (sizeof...(Functions) == 1)
            {
                ([&]
                {
                    using F = detail::container_forwarder<C, Functions>;

                    lua_newuserdata_aligned<F>(L, F(std::move(functions))); // Stack: co, cl, st, upvalue
                    lua_pushcclosure_x(L, &detail::invoke_proxy_constructor<F>, className, 1); // Stack: co, cl, st, function

                } (), ...);
            }
            else
            {
                // create new closure of try_overloads with new table
                lua_createtable(L, static_cast<int>(sizeof...(Functions)), 0); // reserve space for N overloads

                int idx = 1;

                ([&]
                {
                    using F = detail::container_forwarder<C, Functions>;

                    lua_createtable(L, 2, 0); // reserve space for: function, arity
                    lua_pushinteger(L, 1);
                    if constexpr (detail::is_any_cfunction_pointer_v<Functions>)
                        lua_pushinteger(L, -1);
                    else
                        lua_pushinteger(L, static_cast<int>(detail::function_arity_excluding_v<Functions, lua_State*>));
                    lua_settable(L, -3);
                    lua_pushinteger(L, 2);
                    lua_newuserdata_aligned<F>(L, F(std::move(functions)));
                    lua_pushcclosure_x(L, &detail::invoke_proxy_constructor<F>, className, 1);
                    lua_settable(L, -3);
                    lua_rawseti(L, -2, idx);
                    ++idx;

                } (), ...);

                lua_pushcclosure_x(L, &detail::try_overload_functions<true>, className, 1);
            }

            rawsetfield(L, -2, "__call"); // Stack: co, cl, st

            return *this;
        }

        //=========================================================================================
        template <class Function>
        auto addDestructor(Function function)
            -> std::enable_if_t<detail::is_callable_v<Function>, Class<T>&>
        {
            static_assert(detail::function_arity_excluding_v<Function, lua_State*> == 1);
            static_assert(std::is_same_v<detail::function_argument_t<0, Function>, T*>);

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            using F = detail::destructor_forwarder<T, Function>;

            lua_newuserdata_aligned<F>(L, F(std::move(function))); // Stack: co, cl, st, upvalue
            lua_pushcclosure_x(L, &detail::invoke_proxy_destructor<F>, className, 1); // Stack: co, cl, st, function

            rawsetfield(L, -3, "__destruct"); // Stack: co, cl, st

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add or replace a factory.
         *
         * The primary Constructor is invoked when calling the class type table like a function.
         *
         * The template parameter should be a function pointer type that matches the desired Constructor (since you can't take the
         * address of a Constructor and pass it as an argument).
         */
        template <class Allocator, class Deallocator>
        Class<T>& addFactory(Allocator allocator, Deallocator deallocator)
        {
            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            using F = detail::factory_forwarder<T, Allocator, Deallocator>;

            lua_newuserdata_aligned<F>(L, F(std::move(allocator), std::move(deallocator))); // Stack: co, cl, st, upvalue
            lua_pushcclosure_x(L, &detail::invoke_proxy_constructor<F>, className, 1); // Stack: co, cl, st, function
            rawsetfield(L, -2, "__call"); // Stack: co, cl, st

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add an index metamethod function fallback that is triggered when no result is found in functions, properties or any other members.
         *
         * Let the user define a fallback index (__index) metamethod at its level.
         */
        template <class Function>
        auto addIndexMetaMethod(Function function)
            -> std::enable_if_t<!std::is_pointer_v<Function>
                && std::is_invocable_v<Function, T&, const LuaRef&, lua_State*>, Class<T>&>
        {
            using FnType = decltype(function);

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            lua_newuserdata_aligned<FnType>(L, std::move(function)); // Stack: co, cl, st, function userdata (ud)
            lua_pushcclosure_x(L, &detail::invoke_proxy_functor<FnType>, "__index", 1); // Stack: co, cl, st, function
            lua_rawsetp(L, -3, detail::getIndexFallbackKey());

            return *this;
        }

        Class<T>& addIndexMetaMethod(LuaRef (*idxf)(T&, const LuaRef&, lua_State*))
        {
            using FnType = decltype(idxf);

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            lua_pushlightuserdata(L, reinterpret_cast<void*>(idxf)); // Stack: co, cl, st, function ptr
            lua_pushcclosure_x(L, &detail::invoke_proxy_function<FnType>, "__index", 1); // Stack: co, cl, st, function
            lua_rawsetp(L, -3, detail::getIndexFallbackKey());

            return *this;
        }

        Class<T>& addIndexMetaMethod(LuaRef (T::* idxf)(const LuaRef&, lua_State*))
        {
            using MemFnPtr = decltype(idxf);

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            new (lua_newuserdata_x<MemFnPtr>(L, sizeof(MemFnPtr))) MemFnPtr(idxf);
            lua_pushcclosure_x(L, &detail::invoke_member_function<MemFnPtr, T>, "__index", 1);
            lua_rawsetp(L, -3, detail::getIndexFallbackKey());

            return *this;
        }

        //=========================================================================================
        /**
         * @brief Add an insert index metamethod function fallback that is triggered when no result is found in functions, properties or any other members.
         *
         * Let the user define a fallback insert index (___newindex) metamethod at its level.
         */
        template <class Function>
        auto addNewIndexMetaMethod(Function function)
            -> std::enable_if_t<!std::is_pointer_v<Function>
                && std::is_invocable_v<Function, T&, const LuaRef&, const LuaRef&, lua_State*>, Class<T>&>
        {
            using FnType = decltype(function);

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            lua_newuserdata_aligned<FnType>(L, std::move(function)); // Stack: co, cl, st, function userdata (ud)
            lua_pushcclosure_x(L, &detail::invoke_proxy_functor<FnType>, "__newindex", 1); // Stack: co, cl, st, function
            lua_rawsetp(L, -3, detail::getNewIndexFallbackKey());

            return *this;
        }

        Class<T>& addNewIndexMetaMethod(LuaRef (*idxf)(T&, const LuaRef&, const LuaRef&, lua_State*))
        {
            using FnType = decltype(idxf);

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            lua_pushlightuserdata(L, reinterpret_cast<void*>(idxf)); // Stack: co, cl, st, function ptr
            lua_pushcclosure_x(L, &detail::invoke_proxy_function<FnType>, "__newindex", 1); // Stack: co, cl, st, function
            lua_rawsetp(L, -3, detail::getNewIndexFallbackKey());

            return *this;
        }

        Class<T>& addNewIndexMetaMethod(LuaRef (T::* idxf)(const LuaRef&, const LuaRef&, lua_State*))
        {
            using MemFnPtr = decltype(idxf);

            assertStackState(); // Stack: const table (co), class table (cl), static table (st)

            new (lua_newuserdata_x<MemFnPtr>(L, sizeof(MemFnPtr))) MemFnPtr(idxf);
            lua_pushcclosure_x(L, &detail::invoke_member_function<MemFnPtr, T>, "__newindex", 1);
            lua_rawsetp(L, -3, detail::getNewIndexFallbackKey());

            return *this;
        }
    };

    class Table : public detail::Registrar
    {
    public:
        explicit Table(const char* name, Namespace parent)
            : Registrar(std::move(parent))
        {
            lua_newtable(L); // Stack: ns, table (tb)
            lua_pushvalue(L, -1); // Stack: ns, tb, tb
            rawsetfield(L, -3, name);
            ++m_stackSize;

            lua_newtable(L); // Stack: ns, table (tb)
            lua_pushvalue(L, -1); // Stack: ns, tb, tb
            lua_setmetatable(L, -3); // tb.__metatable = tb. Stack: ns, tb
            ++m_stackSize;
        }

        using Registrar::operator=;

        template <class Function>
        Table& addFunction(const char* name, Function function)
        {
            using FnType = decltype(function);

            LUABRIDGE_ASSERT(name != nullptr);
            LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

            lua_newuserdata_aligned<FnType>(L, std::move(function)); // Stack: ns, function userdata (ud)
            lua_pushcclosure_x(L, &detail::invoke_proxy_functor<FnType>, name, 1); // Stack: ns, function
            rawsetfield(L, -3, name); // Stack: ns

            return *this;
        }

        template <class Function>
        Table& addMetaFunction(const char* name, Function function)
        {
            using FnType = decltype(function);

            LUABRIDGE_ASSERT(name != nullptr);
            LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

            lua_newuserdata_aligned<FnType>(L, std::move(function)); // Stack: ns, function userdata (ud)
            lua_pushcclosure_x(L, &detail::invoke_proxy_functor<FnType>, name, 1); // Stack: ns, function
            rawsetfield(L, -2, name); // Stack: ns

            return *this;
        }

        Namespace endTable()
        {
            LUABRIDGE_ASSERT(m_stackSize > 2);

            m_stackSize -= 2;
            lua_pop(L, 2);

            return Namespace(std::move(*this));
        }
    };

private:
    struct FromStack {};

    //=============================================================================================
    /**
     * @brief Open the global namespace for registrations.
     *
     * @param L A Lua state.
     */
    explicit Namespace(lua_State* L)
        : Registrar(L)
    {
        lua_getglobal(L, "_G");

        ++m_stackSize;
    }

    //=============================================================================================
    /**
     * @brief Open the a namespace for registrations from a table on top of the stack.
     *
     * @param L A Lua state.
     */
    Namespace(lua_State* L, Options options, FromStack)
        : Registrar(L, 1)
    {
        LUABRIDGE_ASSERT(lua_istable(L, -1));

        lua_pushvalue(L, -1); // Stack: ns, ns

        // ns.__metatable = ns
        lua_setmetatable(L, -2); // Stack: ns

        // ns.__index = index_static_metamethod
        lua_pushcfunction_x(L, &detail::index_metamethod<false>, "__index");
        rawsetfield(L, -2, "__index"); // Stack: ns

        // ns.__newindex = newindex_static_metamethod
        //lua_pushcfunction_x(L, &detail::newindex_metamethod<false>, "__newindex");
        //rawsetfield(L, -2, "__newindex"); // Stack: pns, ns

        lua_newtable(L); // Stack: ns, mt, propget table (pg)
        lua_rawsetp(L, -2, detail::getPropgetKey()); // ns [propgetKey] = pg. Stack: ns

        lua_newtable(L); // Stack: ns, mt, propset table (ps)
        lua_rawsetp(L, -2, detail::getPropsetKey()); // ns [propsetKey] = ps. Stack: ns

        if (! options.test(visibleMetatables))
        {
            lua_pushboolean(L, 0);
            rawsetfield(L, -2, "__metatable");
        }

        ++m_stackSize;
    }

    //=============================================================================================
    /**
     * @brief Open a namespace for registrations.
     *
     * The namespace is created if it doesn't already exist.
     *
     * @param name The namespace name.
     * @param parent The parent namespace object.
     *
     * @pre The parent namespace is at the top of the Lua stack.
     */
    Namespace(const char* name, Namespace parent, Options options)
        : Registrar(std::move(parent))
    {
        LUABRIDGE_ASSERT(name != nullptr);
        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: parent namespace (pns)

        rawgetfield(L, -1, name); // Stack: pns, namespace (ns) | nil

        if (lua_isnil(L, -1)) // Stack: pns, nil
        {
            lua_pop(L, 1); // Stack: pns

            lua_newtable(L); // Stack: pns, ns
            lua_pushvalue(L, -1); // Stack: pns, ns, mt

            // ns.__metatable = ns
            lua_setmetatable(L, -2); // Stack: pns, ns

            // ns.__index = index_static_metamethod
            lua_pushcfunction_x(L, &detail::index_metamethod<false>, "__index");
            rawsetfield(L, -2, "__index"); // Stack: pns, ns

            // ns.__newindex = newindex_static_metamethod
            lua_pushcfunction_x(L, &detail::newindex_metamethod<false>, "__newindex");
            rawsetfield(L, -2, "__newindex"); // Stack: pns, ns

            lua_newtable(L); // Stack: pns, ns, propget table (pg)
            lua_rawsetp(L, -2, detail::getPropgetKey()); // ns [propgetKey] = pg. Stack: pns, ns

            lua_newtable(L); // Stack: pns, ns, propset table (ps)
            lua_rawsetp(L, -2, detail::getPropsetKey()); // ns [propsetKey] = ps. Stack: pns, ns

            if (! options.test(visibleMetatables))
            {
                lua_pushboolean(L, 0);
                rawsetfield(L, -2, "__metatable");
            }

            // pns [name] = ns
            lua_pushvalue(L, -1); // Stack: pns, ns, ns
            rawsetfield(L, -3, name); // Stack: pns, ns
        }

        ++m_stackSize;
    }

    //=============================================================================================
    /**
     * @brief Close the class and continue the namespace registrations.
     *
     * @param child A child class registration object.
     */
    explicit Namespace(ClassBase child)
        : Registrar(std::move(child))
    {
    }

    explicit Namespace(Table child)
        : Registrar(std::move(child))
    {
    }

    using Registrar::operator=;

public:
    //=============================================================================================
    /**
     * @brief Retrieve the global namespace.
     *
     * It is recommended to put your namespace inside the global namespace, and then add your classes and functions to it, rather than
     * adding many classes and functions directly to the global namespace.
     *
     * @param L A Lua state.
     *
     * @returns A namespace registration object.
     */
    static Namespace getGlobalNamespace(lua_State* L)
    {
        return Namespace(L);
    }

    /**
     * @brief Retrieve the namespace on top of the stack.
     *
     * You should have a table on top of the stack before calling this function. It will then use the table there as destination for registrations.
     *
     * @param L A Lua state.
     *
     * @returns A namespace registration object.
     */
    static Namespace getNamespaceFromStack(lua_State* L, Options options = defaultOptions)
    {
        return Namespace(L, options, FromStack{});
    }

    //=============================================================================================
    /**
     * @brief Open a new or existing namespace for registrations.
     *
     * @param name The namespace name.
     *
     * @returns A namespace registration object.
     */
    Namespace beginNamespace(const char* name, Options options = defaultOptions)
    {
        assertIsActive();
        return Namespace(name, std::move(*this), options);
    }

    //=============================================================================================
    /**
     * @brief Continue namespace registration in the parent.
     *
     * Do not use this on the global namespace.
     *
     * @returns A parent namespace registration object.
     */
    Namespace endNamespace()
    {
        if (m_stackSize == 1)
        {
            throw_or_assert<std::logic_error>("endNamespace() called on global namespace");

            return Namespace(std::move(*this));
        }

        LUABRIDGE_ASSERT(m_stackSize > 1);
        --m_stackSize;
        lua_pop(L, 1);

        return Namespace(std::move(*this));
    }

    //=============================================================================================
    /**
     * @brief Add or replace a variable that will be added in the namespace by copy of the passed value.
     *
     * @param name The variable name.
     * @param value A value object.
     *
     * @returns This namespace registration object.
     */
    template <class T>
    Namespace& addVariable(const char* name, const T& value)
    {
        LUABRIDGE_ASSERT(name != nullptr);
        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

        if constexpr (std::is_enum_v<T>)
        {
            using U = std::underlying_type_t<T>;

            if (auto result = Stack<U>::push(L, static_cast<U>(value)); ! result)
                throw_or_assert<std::logic_error>(result.message().c_str());
        }
        else
        {
            if (auto result = Stack<T>::push(L, value); ! result)
                throw_or_assert<std::logic_error>(result.message().c_str());
        }

        rawsetfield(L, -2, name); // Stack: ns

        return *this;
    }

    //=============================================================================================
    /**
     * @brief Add or replace a readonly property.
     *
     * @param name The property name.
     * @param get  A pointer to a property getter function.
     *
     * @returns This namespace registration object.
     */
    template <class Getter>
    Namespace& addProperty(const char* name, Getter getter)
    {
        LUABRIDGE_ASSERT(name != nullptr);
        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

        if (! checkTableHasPropertyGetter())
        {
            throw_or_assert<std::logic_error>("addProperty() called on global namespace");

            return *this;
        }

        detail::push_property_getter(L, std::move(getter), name); // Stack: ns, getter
        detail::add_property_getter(L, name, -2); // Stack: ns, getter

        detail::push_property_readonly(L, name); // Stack: ns, function
        detail::add_property_setter(L, name, -2); // Stack: ns

        return *this;
    }

    /**
     * @brief Add or replace a mutable property.
     *
     * @param name The property name.
     * @param get  A pointer to a property getter function.
     * @param set  A pointer to a property setter function.
     *
     * @returns This namespace registration object.
     */
    template <class Getter, class Setter>
    Namespace& addProperty(const char* name, Getter getter, Setter setter)
    {
        LUABRIDGE_ASSERT(name != nullptr);
        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

        if (! checkTableHasPropertyGetter())
        {
            throw_or_assert<std::logic_error>("addProperty() called on global namespace");

            return *this;
        }

        detail::push_property_getter(L, std::move(getter), name); // Stack: ns, getter
        detail::add_property_getter(L, name, -2); // Stack: ns

        detail::push_property_setter(L, std::move(setter), name); // Stack: ns, setter
        detail::add_property_setter(L, name, -2); // Stack: ns

        return *this;
    }

    //=============================================================================================
    /**
     * @brief Add or replace a single function or multiple overloaded functions.
     *
     * @param name The overload name.
     * @param functions A single or set of functions that will be invoked.
     *
     * @returns This namespace registration object.
     */
    template <class... Functions>
    auto addFunction(const char* name, Functions... functions)
        -> std::enable_if_t<(detail::is_callable_v<Functions> && ...) && (sizeof...(Functions) > 0), Namespace&>
    {
        LUABRIDGE_ASSERT(name != nullptr);
        LUABRIDGE_ASSERT(lua_istable(L, -1)); // Stack: namespace table (ns)

        if constexpr (sizeof...(Functions) == 1)
        {
            ([&]
            {
                detail::push_function(L, std::move(functions), name);

            } (), ...);
        }
        else
        {
            // create new closure of try_overloads with new table
            lua_createtable(L, static_cast<int>(sizeof...(Functions)), 0); // reserve space for N overloads

            int idx = 1;

            ([&]
            {
                lua_createtable(L, 2, 0); // reserve space for: function, arity
                lua_pushinteger(L, 1);
                if constexpr (detail::is_any_cfunction_pointer_v<Functions>)
                    lua_pushinteger(L, -1);
                else
                    lua_pushinteger(L, static_cast<int>(detail::function_arity_excluding_v<Functions, lua_State*>));
                lua_settable(L, -3);
                lua_pushinteger(L, 2);
                detail::push_function(L, std::move(functions), name);
                lua_settable(L, -3);

                lua_rawseti(L, -2, idx);
                ++idx;

            } (), ...);

            lua_pushcclosure_x(L, &detail::try_overload_functions<false>, name, 1);
        }

        rawsetfield(L, -2, name);

        return *this;
    }

    //=============================================================================================
    /**
     * @brief Open a new or existing table as namespace for registrations.
	 *
     * @param name The table name.
     *
     * @returns A table registration object.
     */
    Table beginTable(const char* name)
    {
        assertIsActive();
        return Table(name, std::move(*this));
    }

    //=============================================================================================
    /**
     * @brief Open a new or existing class for registrations.
     *
     * @param name The class name.
     * @param options The class options.
     *
     * @returns A class registration object.
     */
    template <class T>
    Class<T> beginClass(const char* name, Options options = defaultOptions)
    {
        assertIsActive();
        return Class<T>(name, std::move(*this), options);
    }

    //=============================================================================================
    /**
     * @brief Derive a new class for registrations.
     *
     * Call deriveClass() only once. To continue registrations for the class later, use beginClass().
     *
     * @param name The class name.
     * @param options The class options.
     *
     * @returns A class registration object.
     */
    template <class Derived, class Base>
    Class<Derived> deriveClass(const char* name, Options options = defaultOptions)
    {
        assertIsActive();
        return Class<Derived>(name, std::move(*this), detail::getStaticRegistryKey<Base>(), options);
    }
    
private:
    /**
     * @brief Checks if the table has a property getter metatable.
     */
    bool checkTableHasPropertyGetter() const
    {
        if (m_stackSize == 1 && lua_istable(L, -1))
        {
            lua_rawgetp(L, -1, detail::getPropgetKey());
            const bool propertyGetterTableIsValid = lua_istable(L, -1);
            lua_pop(L, 1);

            return propertyGetterTableIsValid;
        }
        
        return true;
    }
};

//=================================================================================================
/**
 * @brief Retrieve the global namespace.
 *
 * It is recommended to put your namespace inside the global namespace, and then add your classes and functions to it, rather than adding
 * many classes and functions directly to the global namespace.
 *
 * @param L A Lua state.
 *
 * @returns A namespace registration object.
 */
inline Namespace getGlobalNamespace(lua_State* L)
{
    return Namespace::getGlobalNamespace(L);
}

//=================================================================================================
/**
 * @brief Retrieve the namespace on top of the stack.
 *
 * You should have a table on top of the stack before calling this function. It will then use the table there as destination for registrations.
 *
 * @param L A Lua state.
 *
 * @returns A namespace registration object.
 */
inline Namespace getNamespaceFromStack(lua_State* L)
{
    return Namespace::getNamespaceFromStack(L);
}

//=================================================================================================
/**
 * @brief Registers main thread.
 *
 * This is a backward compatibility mitigation for lua 5.1 not supporting LUA_RIDX_MAINTHREAD.
 *
 * @param L The main Lua state that will be registered as main thread.
 *
 * @returns A namespace registration object.
 */
inline void registerMainThread(lua_State* L)
{
    register_main_thread(L);
}

} // namespace luabridge

// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2019, George Tokmaji
// Copyright 2018, Dmitry Tarakanov
// Copyright 2012, Vinnie Falco <vinnie.falco@gmail.com>
// Copyright 2008, Nigel Atkinson <suprapilot+LuaCode@gmail.com>
// SPDX-License-Identifier: MIT

#pragma once

#include "Config.h"
#include "Errors.h"
#include "Expected.h"
#include "Stack.h"

#include <iostream>
#include <exception>
#include <map>
#include <string>
#include <optional>
#include <type_traits>
#include <vector>

namespace luabridge {

class LuaResult;

//=================================================================================================
/**
 * @brief Type tag for representing LUA_TNIL.
 *
 * Construct one of these using `LuaNil ()` to represent a Lua nil. This is faster than creating a reference in the registry to nil.
 * Example:
 *
 * @code
 *     LuaRef t (LuaRef::createTable (L));
 *     ...
 *     t ["k"] = LuaNil (); // assign nil
 * @endcode
 */
struct LuaNil
{
};

/**
 * @brief Stack specialization for LuaNil.
 */
template <>
struct Stack<LuaNil>
{
    [[nodiscard]] static Result push(lua_State* L, const LuaNil&)
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(L, 1))
            return makeErrorCode(ErrorCode::LuaStackOverflow);
#endif

        lua_pushnil(L);
        return {};
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index)
    {
        return lua_type(L, index) == LUA_TNIL;
    }
};

//=================================================================================================
/**
 * @brief Base class for Lua variables and table item reference classes.
 */
template <class Impl, class LuaRef>
class LuaRefBase
{
protected:
    friend struct Stack<LuaRef>;

    //=============================================================================================
    /**
     * @brief Type tag for stack construction.
     */
    struct FromStack
    {
    };

    LuaRefBase(lua_State* L) noexcept
        : m_L(L)
    {
        LUABRIDGE_ASSERT(L != nullptr);
    }

    //=============================================================================================
    /**
     * @brief Create a reference to this reference.
     *
     * @returns An index in the Lua registry.
     */
    int createRef() const
    {
        impl().push(m_L);

        return luaL_ref(m_L, LUA_REGISTRYINDEX);
    }

public:
    //=============================================================================================
    /**
     * @brief Convert to a string using lua_tostring function.
     *
     * @returns A string representation of the referred Lua value.
     */
    std::string tostring() const
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(m_L, 2))
            return {};
#endif

        const StackRestore stackRestore(m_L);

        lua_getglobal(m_L, "tostring");

        impl().push(m_L);

        lua_call(m_L, 1, 1);

        const char* str = lua_tostring(m_L, -1);
        return str != nullptr ? str : "";
    }

    //=============================================================================================
    /**
     * @brief Print a text description of the value to a stream.
     *
     * This is used for diagnostics.
     *
     * @param os An output stream.
     */
    void print(std::ostream& os) const
    {
        switch (type())
        {
        case LUA_TNONE:
        case LUA_TNIL:
            os << "nil";
            break;

        case LUA_TNUMBER:
            os << unsafe_cast<lua_Number>();
            break;

        case LUA_TBOOLEAN:
            os << (unsafe_cast<bool>() ? "true" : "false");
            break;

        case LUA_TSTRING:
            os << '"' << unsafe_cast<const char*>() << '"';
            break;

        case LUA_TTABLE:
        case LUA_TFUNCTION:
        case LUA_TTHREAD:
        case LUA_TUSERDATA:
        case LUA_TLIGHTUSERDATA:
            os << tostring();
            break;

        default:
            os << "unknown";
            break;
        }
    }

    //=============================================================================================
    /**
     * @brief Insert a Lua value or table item reference to a stream.
     *
     * @param os  An output stream.
     * @param ref A Lua reference.
     *
     * @returns The output stream.
     */
    friend std::ostream& operator<<(std::ostream& os, const LuaRefBase& ref)
    {
        ref.print(os);
        return os;
    }

    //=============================================================================================
    /**
     * @brief Retrieve the lua_State associated with the reference.
     *
     * @returns A Lua state.
     */
    lua_State* state() const
    {
        return m_L;
    }

    //=============================================================================================
    /**
     * @brief Return the Lua type of the referred value.
     *
     * This invokes lua_type().
     *
     * @returns The type of the referred value.
     *
     * @see lua_type()
     */
    int type() const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        return lua_type(m_L, -1);
    }

    /**
     * @brief Indicate whether it is a nil reference.
     *
     * @returns True if this is a nil reference, false otherwise.
     */
    bool isNil() const { return type() == LUA_TNIL; }

    /**
     * @brief Indicate whether it is a reference to a boolean.
     *
     * @returns True if it is a reference to a boolean, false otherwise.
     */
    bool isBool() const { return type() == LUA_TBOOLEAN; }

    /**
     * @brief Indicate whether it is a reference to a number.
     *
     * @returns True if it is a reference to a number, false otherwise.
     */
    bool isNumber() const { return type() == LUA_TNUMBER; }

    /**
     * @brief Indicate whether it is a reference to a string.
     *
     * @returns True if it is a reference to a string, false otherwise.
     */
    bool isString() const { return type() == LUA_TSTRING; }

    /**
     * @brief Indicate whether it is a reference to a table.
     *
     * @returns True if it is a reference to a table, false otherwise.
     */
    bool isTable() const { return type() == LUA_TTABLE; }

    /**
     * @brief Indicate whether it is a reference to a function.
     *
     * @returns True if it is a reference to a function, false otherwise.
     */
    bool isFunction() const { return type() == LUA_TFUNCTION; }

    /**
     * @brief Indicate whether it is a reference to a full userdata.
     *
     * @returns True if it is a reference to a full userdata, false otherwise.
     */
    bool isUserdata() const { return type() == LUA_TUSERDATA; }

    /**
     * @brief Indicate whether it is a reference to a lua thread (coroutine).
     *
     * @returns True if it is a reference to a lua thread, false otherwise.
     */
    bool isThread() const { return type() == LUA_TTHREAD; }

    /**
     * @brief Indicate whether it is a reference to a light userdata.
     *
     * @returns True if it is a reference to a light userdata, false otherwise.
     */
    bool isLightUserdata() const { return type() == LUA_TLIGHTUSERDATA; }

    /**
     * @brief Indicate whether it is a callable.
     *
     * @returns True if it is a callable, false otherwise.
     */
    bool isCallable() const
    {
        if (isFunction())
            return true;

        auto metatable = getMetatable();
        return metatable.isTable() && metatable["__call"].isFunction();
    }

    /**
     * @brief Get the name of the class, only if it is a C++ registered class via the library.
     *
     * @returns An optional string containing the name used to register the class with `beginClass`, nullopt in case it's not a registered class.
     */
    std::optional<std::string> getClassName()
    {
        if (! isUserdata())
            return std::nullopt;

        const StackRestore stackRestore(m_L);

        impl().push(m_L);
        if (! lua_getmetatable(m_L, -1))
            return std::nullopt;

        lua_rawgetp(m_L, -1, detail::getTypeKey());
        if (lua_isstring(m_L, -1))
            return lua_tostring(m_L, -1);

        return std::nullopt;
    }

    //=============================================================================================
    /**
     * @brief Perform a safe explicit conversion to the type T.
     *
     * @returns An expected holding a value of the type T converted from this reference or an error code.
     */
    template <class T>
    TypeResult<T> cast() const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        return Stack<T>::get(m_L, -1);
    }

    /**
     * @brief Perform an unsafe explicit conversion to the type T.
     *
     * @returns A value of the type T converted from this reference.
     */
    template <class T>
    T unsafe_cast() const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        return *Stack<T>::get(m_L, -1);
    }

    //=============================================================================================
    /**
     * @brief Indicate if this reference is convertible to the type T.
     *
     * @returns True if the referred value is convertible to the type T, false otherwise.
     */
    template <class T>
    bool isInstance() const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        return Stack<T>::isInstance(m_L, -1);
    }

    //=============================================================================================
    /**
     * @brief Type cast operator.
     *
     * This operator calls cast<T> and always dereference the returned expected instance, resulting in exceptions being thrown if the
     * exceptions are enabled, or otherwise we'll enter the UB land (and a likely crash down the line).
     *
     * @returns A value of the type T converted from this reference.
     */
    template <class T>
    operator T() const
    {
        return cast<T>().value();
    }

    //=============================================================================================
    /**
     * @brief Get the metatable for the LuaRef.
     *
     * @returns A LuaRef holding the metatable of the lua object.
     */
    LuaRef getMetatable() const
    {
        if (isNil())
            return LuaRef(m_L);

        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        if (! lua_getmetatable(m_L, -1))
            return LuaRef(m_L);

        return LuaRef::fromStack(m_L);
    }

    //=============================================================================================
    /**
     * @brief Compare this reference with a specified value using lua_compare().
     *
     * This invokes metamethods.
     *
     * @param rhs A value to compare with.
     *
     * @returns True if the referred value is equal to the specified one.
     */
    template <class T>
    bool operator==(const T& rhs) const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        if (! Stack<T>::push(m_L, rhs))
            return false;

        return lua_compare(m_L, -2, -1, LUA_OPEQ) == 1;
    }

    /**
     * @brief Compare this reference with a specified value using lua_compare().
     *
     * This invokes metamethods.
     *
     * @param rhs A value to compare with.
     *
     * @returns True if the referred value is not equal to the specified one.
     */
    template <class T>
    bool operator!=(const T& rhs) const
    {
        return !(*this == rhs);
    }

    /**
     * @brief Compare this reference with a specified value using lua_compare().
     *
     * This invokes metamethods.
     *
     * @param rhs A value to compare with.
     *
     * @returns True if the referred value is less than the specified one.
     */
    template <class T>
    bool operator<(const T& rhs) const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        if (! Stack<T>::push(m_L, rhs))
            return false;

        const int lhsType = lua_type(m_L, -2);
        const int rhsType = lua_type(m_L, -1);
        if (lhsType != rhsType)
            return lhsType < rhsType;

        return lua_compare(m_L, -2, -1, LUA_OPLT) == 1;
    }

    /**
     * @brief Compare this reference with a specified value using lua_compare().
     *
     * This invokes metamethods.
     *
     * @param rhs A value to compare with.
     *
     * @returns True if the referred value is less than or equal to the specified one.
     */
    template <class T>
    bool operator<=(const T& rhs) const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        if (! Stack<T>::push(m_L, rhs))
            return false;

        const int lhsType = lua_type(m_L, -2);
        const int rhsType = lua_type(m_L, -1);
        if (lhsType != rhsType)
            return lhsType <= rhsType;

        return lua_compare(m_L, -2, -1, LUA_OPLE) == 1;
    }

    /**
     * @brief Compare this reference with a specified value using lua_compare().
     *
     * This invokes metamethods.
     *
     * @param rhs A value to compare with.
     *
     * @returns True if the referred value is greater than the specified one.
     */
    template <class T>
    bool operator>(const T& rhs) const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        if (! Stack<T>::push(m_L, rhs))
            return false;

        const int lhsType = lua_type(m_L, -2);
        const int rhsType = lua_type(m_L, -1);
        if (lhsType != rhsType)
            return lhsType > rhsType;

        return lua_compare(m_L, -1, -2, LUA_OPLT) == 1;
    }

    /**
     * @brief Compare this reference with a specified value using lua_compare().
     *
     * This invokes metamethods.
     *
     * @param rhs A value to compare with.
     *
     * @returns True if the referred value is greater than or equal to the specified one.
     */
    template <class T>
    bool operator>=(const T& rhs) const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        if (! Stack<T>::push(m_L, rhs))
            return false;

        const int lhsType = lua_type(m_L, -2);
        const int rhsType = lua_type(m_L, -1);
        if (lhsType != rhsType)
            return lhsType >= rhsType;

        return lua_compare(m_L, -1, -2, LUA_OPLE) == 1;
    }

    /**
     * @brief Compare this reference with a specified value using lua_compare().
     *
     * This does not invoke metamethods.
     *
     * @param rhs A value to compare with.
     *
     * @returns True if the referred value is equal to the specified one.
     */
    template <class T>
    bool rawequal(const T& v) const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        if (! Stack<T>::push(m_L, v))
            return false;

        return lua_rawequal(m_L, -1, -2) == 1;
    }

    //=============================================================================================
    /**
     * @brief Return the length of a referred array.
     *
     * This is identical to applying the Lua # operator.
     *
     * @returns The length of the referred array.
     */
    int length() const
    {
        const StackRestore stackRestore(m_L);

        impl().push(m_L);

        return get_length(m_L, -1);
    }

    //=============================================================================================
    /**
     * @brief Call Lua code.
     *
     * The return value is provided as a LuaRef (which may be LUA_REFNIL).
     *
     * If an error occurs, a LuaException is thrown (only if exceptions are enabled).
     *
     * @returns A result of the call.
     */
    template <class... Args>
    LuaResult operator()(Args&&... args) const;

    template <class... Args>
    LuaResult call(Args&&... args) const;

    template <class F, class... Args>
    LuaResult callWithHandler(F&& errorHandler, Args&&... args) const;

protected:
    lua_State* m_L = nullptr;

private:
    const Impl& impl() const { return static_cast<const Impl&>(*this); }

    Impl& impl() { return static_cast<Impl&>(*this); }
};

//=================================================================================================
/**
 * @brief Lightweight reference to a Lua object.
 *
 * The reference is maintained for the lifetime of the C++ object.
 */
class LuaRef : public LuaRefBase<LuaRef, LuaRef>
{
    //=============================================================================================
    /**
     * @brief A proxy for representing table values.
     */
    class TableItem : public LuaRefBase<TableItem, LuaRef>
    {
        friend class LuaRef;

    public:
        //=========================================================================================
        /**
         * @brief Construct a TableItem from a table value.
         *
         * The table is in the registry, and the key is at the top of the stack.
         * The key is popped off the stack.
         *
         * @param L A lua state.
         * @param tableRef The index of a table in the Lua registry.
         */
        TableItem(lua_State* L, int tableRef)
            : LuaRefBase(L)
            , m_keyRef(luaL_ref(L, LUA_REGISTRYINDEX))
        {
#if LUABRIDGE_SAFE_STACK_CHECKS
            luaL_checkstack(m_L, 1, detail::error_lua_stack_overflow);
#endif

            lua_rawgeti(m_L, LUA_REGISTRYINDEX, tableRef);
            m_tableRef = luaL_ref(L, LUA_REGISTRYINDEX);
        }

        //=========================================================================================
        /**
         * @brief Create a TableItem via copy constructor.
         *
         * It is best to avoid code paths that invoke this, because it creates an extra temporary Lua reference. Typically this is done by
         * passing the TableItem parameter as a `const` reference.
         *
         * @param other Another Lua table item reference.
         */
        TableItem(const TableItem& other)
            : LuaRefBase(other.m_L)
        {
#if LUABRIDGE_SAFE_STACK_CHECKS
            if (! lua_checkstack(m_L, 1))
                return;
#endif

            lua_rawgeti(m_L, LUA_REGISTRYINDEX, other.m_tableRef);
            m_tableRef = luaL_ref(m_L, LUA_REGISTRYINDEX);

            lua_rawgeti(m_L, LUA_REGISTRYINDEX, other.m_keyRef);
            m_keyRef = luaL_ref(m_L, LUA_REGISTRYINDEX);
        }

        //=========================================================================================
        /**
         * @brief Destroy the proxy.
         *
         * This does not destroy the table value.
         */
        ~TableItem()
        {
            if (m_keyRef != LUA_NOREF)
                luaL_unref(m_L, LUA_REGISTRYINDEX, m_keyRef);

            if (m_tableRef != LUA_NOREF)
                luaL_unref(m_L, LUA_REGISTRYINDEX, m_tableRef);
        }

        //=========================================================================================
        /**
         * @brief Assign a new value to this table key.
         *
         * This may invoke metamethods.
         *
         * @tparam T The type of a value to assign.
         *
         * @param v A value to assign.
         *
         * @returns This reference.
         */
        template <class T>
        TableItem& operator=(const T& v)
        {
#if LUABRIDGE_SAFE_STACK_CHECKS
            if (! lua_checkstack(m_L, 2))
                return *this;
#endif

            const StackRestore stackRestore(m_L);

            lua_rawgeti(m_L, LUA_REGISTRYINDEX, m_tableRef);
            lua_rawgeti(m_L, LUA_REGISTRYINDEX, m_keyRef);

            if (! Stack<T>::push(m_L, v))
                return *this;

            lua_settable(m_L, -3);
            return *this;
        }

        //=========================================================================================
        /**
         * @brief Assign a new value to this table key.
         *
         * The assignment is raw, no metamethods are invoked.
         *
         * @tparam T The type of a value to assign.
         *
         * @param v A value to assign.
         *
         * @returns This reference.
         */
        template <class T>
        TableItem& rawset(const T& v)
        {
#if LUABRIDGE_SAFE_STACK_CHECKS
            if (! lua_checkstack(m_L, 2))
                return *this;
#endif

            const StackRestore stackRestore(m_L);

            lua_rawgeti(m_L, LUA_REGISTRYINDEX, m_tableRef);
            lua_rawgeti(m_L, LUA_REGISTRYINDEX, m_keyRef);

            if (! Stack<T>::push(m_L, v))
                return *this;

            lua_rawset(m_L, -3);
            return *this;
        }

        //=========================================================================================
        /**
         * @brief Push the value onto the Lua stack.
         */
        void push() const
        {
            push(m_L);
        }

        void push(lua_State* L) const
        {
            LUABRIDGE_ASSERT(equalstates(L, m_L));

#if LUABRIDGE_SAFE_STACK_CHECKS
            if (! lua_checkstack(L, 3))
                return;
#endif

            lua_rawgeti(L, LUA_REGISTRYINDEX, m_tableRef);
            lua_rawgeti(L, LUA_REGISTRYINDEX, m_keyRef);
            lua_gettable(L, -2);
            lua_remove(L, -2); // remove the table
        }

        //=========================================================================================
        /**
         * @brief Access a table value using a key.
         *
         * This invokes metamethods.
         *
         * @tparam T The type of a key.
         *
         * @param key A key value.
         *
         * @returns A Lua table item reference.
         */
        template <class T>
        TableItem operator[](const T& key) const
        {
            return LuaRef(*this)[key];
        }

        //=========================================================================================
        /**
         * @brief Access a table value using a key.
         *
         * The operation is raw, metamethods are not invoked. The result is passed by value and may not be modified.
         *
         * @tparam T The type of a key.
         *
         * @param key A key value.
         *
         * @returns A Lua value reference.
         */
        template <class T>
        LuaRef rawget(const T& key) const
        {
            return LuaRef(*this).rawget(key);
        }

    private:
        int m_tableRef = LUA_NOREF;
        int m_keyRef = LUA_NOREF;
    };

    friend struct Stack<TableItem>;
    friend struct Stack<TableItem&>;

    //=========================================================================================
    /**
     * @brief Create a reference to an object at the top of the Lua stack and pop it.
     *
     * This constructor is private and not invoked directly. Instead, use the `fromStack` function.
     *
     * @param L A Lua state.
     *
     * @note The object is popped.
     */
    LuaRef(lua_State* L, FromStack) noexcept
        : LuaRefBase(L)
        , m_ref(luaL_ref(m_L, LUA_REGISTRYINDEX))
    {
    }

    //=========================================================================================
    /**
     * @brief Create a reference to an object on the Lua stack.
     *
     * This constructor is private and not invoked directly. Instead, use the `fromStack` function.
     *
     * @param L A Lua state.
     *
     * @param index The index of the value on the Lua stack.
     *
     * @note The object is not popped.
     */
    LuaRef(lua_State* L, int index, FromStack)
        : LuaRefBase(L)
        , m_ref(LUA_NOREF)
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(m_L, 1))
            return;
#endif

        lua_pushvalue(m_L, index);
        m_ref = luaL_ref(m_L, LUA_REGISTRYINDEX);
    }

    LuaRef(std::nullptr_t) noexcept = delete;

public:
    //=============================================================================================
    /**
     * @brief Create an invalid reference that will be treated as nil.
     *
     * The Lua reference may be assigned later.
     *
     * @param L A Lua state.
     */
    LuaRef(lua_State* L) noexcept
        : LuaRefBase(L)
        , m_ref(LUA_NOREF)
    {
    }

    //=============================================================================================
    /**
     * @brief Push a value onto a Lua stack and return a reference to it.
     *
     * @param L A Lua state.
     * @param v A value to push.
     */
    template <class T>
    LuaRef(lua_State* L, const T& v)
        : LuaRefBase(L)
        , m_ref(LUA_NOREF)
    {
        if (! Stack<T>::push(m_L, v))
            return;

        m_ref = luaL_ref(m_L, LUA_REGISTRYINDEX);
    }

    //=============================================================================================
    /**
     * @brief Create a reference to a table item.
     *
     * @param v A table item reference.
     */
    LuaRef(const TableItem& v)
        : LuaRefBase(v.state())
        , m_ref(v.createRef())
    {
    }

    //=============================================================================================
    /**
     * @brief Create a new reference to an existing Lua value.
     *
     * @param other An existing reference.
     */
    LuaRef(const LuaRef& other)
        : LuaRefBase(other.m_L)
        , m_ref(other.createRef())
    {
    }

    //=============================================================================================
    /**
     * @brief Move a reference to an existing Lua value.
     *
     * @param other An existing reference.
     */
    LuaRef(LuaRef&& other) noexcept
        : LuaRefBase(other.m_L)
        , m_ref(std::exchange(other.m_ref, LUA_NOREF))
    {
    }

    //=============================================================================================
    /**
     * @brief Destroy a reference.
     *
     * The corresponding Lua registry reference will be released.
     *
     * @note If the state refers to a thread, it is the responsibility of the caller to ensure that the thread still exists when the LuaRef is destroyed.
     */
    ~LuaRef()
    {
        if (m_ref != LUA_NOREF)
            luaL_unref(m_L, LUA_REGISTRYINDEX, m_ref);
    }

    //=============================================================================================
    /**
     * @brief Return a reference to a top Lua stack item.
     *
     * The stack item is not popped.
     *
     * @param L A Lua state.
     *
     * @returns A reference to a value on the top of a Lua stack.
     */
    static LuaRef fromStack(lua_State* L)
    {
        return LuaRef(L, FromStack());
    }

    //=============================================================================================
    /**
     * @brief Return a reference to a Lua stack item with a specified index.
     *
     * The stack item is not removed.
     *
     * @param L     A Lua state.
     * @param index An index in the Lua stack.
     *
     * @returns A reference to a value in a Lua stack.
     */
    static LuaRef fromStack(lua_State* L, int index)
    {
        return LuaRef(L, index, FromStack());
    }

    //=============================================================================================
    /**
     * @brief Create a new empty table on the top of a Lua stack and return a reference to it.
     *
     * @param L A Lua state.
     *
     * @returns A reference to the newly created table.
     *
     * @see luabridge::newTable()
     */
    static LuaRef newTable(lua_State* L)
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(L, 1))
            return { L };
#endif

        lua_newtable(L);
        return LuaRef(L, FromStack());
    }
    
    //=============================================================================================
    /**
     * @brief Create a new function on the top of a Lua stack and return a reference to it.
     *
     * @param L A Lua state.
     * @param func The c++ function to map to lua.
     * @param debugname Optional debug name (used only by Luau).
     *
     * @returns A reference to the newly created function.
     *
     * @see luabridge::newFunction()
     */
    template <class F>
    static LuaRef newFunction(lua_State* L, F&& func, const char* debugname = "")
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(L, 1))
            return { L };
#endif

        detail::push_function(L, std::forward<F>(func), debugname);
        return LuaRef(L, FromStack());
    }

    //=============================================================================================
    /**
     * @brief Return a reference to a named global Lua variable.
     *
     * @param L    A Lua state.
     * @param name The name of a global variable.
     *
     * @returns A reference to the Lua variable.
     *
     * @see luabridge::getGlobal()
     */
    static LuaRef getGlobal(lua_State* L, const char* name)
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(L, 1))
            return { L };
#endif

        lua_getglobal(L, name);
        return LuaRef(L, FromStack());
    }

    //=============================================================================================
    /**
     * @brief Indicate whether it is an invalid reference.
     *
     * @returns True if this is an invalid reference, false otherwise.
     */
    bool isValid() const { return m_ref != LUA_NOREF; }

    //=============================================================================================
    /**
     * @brief Assign another LuaRef to this LuaRef.
     *
     * @param rhs A reference to assign from.
     *
     * @returns This reference.
     */
    LuaRef& operator=(const LuaRef& rhs)
    {
        LuaRef ref(rhs);
        swap(ref);
        return *this;
    }

    //=============================================================================================
    /**
     * @brief Move assign another LuaRef to this LuaRef.
     *
     * @param rhs A reference to assign from.
     *
     * @returns This reference.
     */
    LuaRef& operator=(LuaRef&& rhs) noexcept
    {
        if (m_ref != LUA_NOREF)
            luaL_unref(m_L, LUA_REGISTRYINDEX, m_ref);

        m_L = rhs.m_L;
        m_ref = std::exchange(rhs.m_ref, LUA_NOREF);

        return *this;
    }

    //=============================================================================================
    /**
     * @brief Assign a table item reference.
     *
     * @param rhs A table item reference.
     *
     * @returns This reference.
     */
    LuaRef& operator=(const LuaRef::TableItem& rhs)
    {
        LuaRef ref(rhs);
        swap(ref);
        return *this;
    }

    //=============================================================================================
    /**
     * @brief Assign nil to this reference.
     *
     * @returns This reference.
     */
    LuaRef& operator=(const LuaNil&)
    {
        LuaRef ref(m_L);
        swap(ref);
        return *this;
    }

    //=============================================================================================
    /**
     * @brief Assign a different value to this reference.
     *
     * @param rhs A value to assign.
     *
     * @returns This reference.
     */
    template <class T>
    LuaRef& operator=(const T& rhs)
    {
        LuaRef ref(m_L, rhs);
        swap(ref);
        return *this;
    }

    //=============================================================================================
    /**
     * @brief Place the object onto the Lua stack.
     */
    void push() const
    {
        push(m_L);
    }

    void push(lua_State* L) const
    {
        LUABRIDGE_ASSERT(equalstates(L, m_L));

#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(L, 1))
            return;
#endif

        lua_rawgeti(L, LUA_REGISTRYINDEX, m_ref);
    }

    //=============================================================================================
    /**
     * @brief Pop the top of Lua stack and assign the ref to m_ref
     */
    void pop()
    {
        pop(m_L);
    }

    void pop(lua_State* L)
    {
        LUABRIDGE_ASSERT(equalstates(L, m_L));

        if (m_ref != LUA_NOREF)
            luaL_unref(L, LUA_REGISTRYINDEX, m_ref);

        m_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    }

    //=============================================================================================
    /**
     * @brief Move the reference to a separate coroutine (lua_State).
     */
    void moveTo(lua_State* newL)
    {
        push();

        lua_xmove(m_L, newL, 1);

        m_L = newL;
    }

    //=============================================================================================
    /**
     * @brief Access a table value using a key.
     *
     * This invokes metamethods.
     *
     * @param key A key in the table.
     *
     * @returns A reference to the table item.
     */
    template <class T>
    TableItem operator[](const T& key) const
    {
        if (! Stack<T>::push(m_L, key))
            return TableItem(m_L, m_ref);

        return TableItem(m_L, m_ref);
    }

    //=============================================================================================
    /**
     * @brief Access a table value using a key.
     *
     * The operation is raw, metamethods are not invoked. The result is passed by value and may not be modified.
     *
     * @param key A key in the table.
     *
     * @returns A reference to the table item.
     */
    template <class T>
    LuaRef rawget(const T& key) const
    {
        const StackRestore stackRestore(m_L);

        push(m_L);

        if (! Stack<T>::push(m_L, key))
            return LuaRef(m_L);

        lua_rawget(m_L, -2);
        return LuaRef(m_L, FromStack());
    }

    //=============================================================================================
    /**
     * @brief Get the unique hash of a LuaRef.
     */
    std::size_t hash() const
    {
        std::size_t value;
        switch (type())
        {
        case LUA_TNONE:
            value = std::hash<std::nullptr_t>{}(nullptr);
            break;

        case LUA_TBOOLEAN:
            value = std::hash<bool>{}(unsafe_cast<bool>());
            break;

        case LUA_TNUMBER:
            value = std::hash<lua_Number>{}(unsafe_cast<lua_Number>());
            break;

        case LUA_TSTRING:
            value = std::hash<const char*>{}(unsafe_cast<const char*>());
            break;

        case LUA_TNIL:
        case LUA_TTABLE:
        case LUA_TFUNCTION:
        case LUA_TTHREAD:
        case LUA_TUSERDATA:
        case LUA_TLIGHTUSERDATA:
        default:
            value = static_cast<std::size_t>(m_ref);
            break;
        }

        const std::size_t seed = std::hash<int>{}(type());
        return value + 0x9e3779b9u + (seed << 6) + (seed >> 2);
    }

private:
    void swap(LuaRef& other) noexcept
    {
        using std::swap;

        swap(m_L, other.m_L);
        swap(m_ref, other.m_ref);
    }

    int m_ref = LUA_NOREF;
};

//=================================================================================================
/**
 * @brief Equality between type T and LuaRef.
 */
template <class T>
auto operator==(const T& lhs, const LuaRef& rhs)
    -> std::enable_if_t<!std::is_same_v<T, LuaRef> && !std::is_same_v<T, LuaRefBase<LuaRef, LuaRef>>, bool>
{
    return rhs == lhs;
}

/**
 * @brief Inequality between type T and LuaRef.
 */
template <class T>
auto operator!=(const T& lhs, const LuaRef& rhs)
    -> std::enable_if_t<!std::is_same_v<T, LuaRef> && !std::is_same_v<T, LuaRefBase<LuaRef, LuaRef>>, bool>
{
    return !(rhs == lhs);
}

/**
 * @brief Less than between type T and LuaRef.
 */
template <class T>
auto operator<(const T& lhs, const LuaRef& rhs)
    -> std::enable_if_t<!std::is_same_v<T, LuaRef> && !std::is_same_v<T, LuaRefBase<LuaRef, LuaRef>>, bool>
{
    return !(rhs >= lhs);
}

/**
 * @brief Less than equal between type T and LuaRef.
 */
template <class T>
auto operator<=(const T& lhs, const LuaRef& rhs)
    -> std::enable_if_t<!std::is_same_v<T, LuaRef> && !std::is_same_v<T, LuaRefBase<LuaRef, LuaRef>>, bool>
{
    return !(rhs > lhs);
}

/**
 * @brief Greater than between type T and LuaRef.
 */
template <class T>
auto operator>(const T& lhs, const LuaRef& rhs)
    -> std::enable_if_t<!std::is_same_v<T, LuaRef> && !std::is_same_v<T, LuaRefBase<LuaRef, LuaRef>>, bool>
{
    return rhs <= lhs;
}

/**
 * @brief Greater than equal between type T and LuaRef.
 */
template <class T>
auto operator>=(const T& lhs, const LuaRef& rhs)
    -> std::enable_if_t<!std::is_same_v<T, LuaRef> && !std::is_same_v<T, LuaRefBase<LuaRef, LuaRef>>, bool>
{
    return !(rhs > lhs);
}

//=================================================================================================
/**
 * @brief Stack specialization for `LuaRef`.
 */
template <>
struct Stack<LuaRef>
{
    [[nodiscard]] static Result push(lua_State* L, const LuaRef& v)
    {
        v.push(L);

        return {};
    }

    [[nodiscard]] static TypeResult<LuaRef> get(lua_State* L, int index)
    {
        return LuaRef::fromStack(L, index);
    }
};

//=================================================================================================
/**
 * @brief Stack specialization for `TableItem`.
 */
template <>
struct Stack<LuaRef::TableItem>
{
    [[nodiscard]] static Result push(lua_State* L, const LuaRef::TableItem& v)
    {
        v.push(L);

        return {};
    }
};

//=================================================================================================
/**
 * @brief Create a reference to a new, empty table.
 *
 * This is a syntactic abbreviation for LuaRef::newTable ().
 */
[[nodiscard]] inline LuaRef newTable(lua_State* L)
{
    return LuaRef::newTable(L);
}

//=================================================================================================
/**
 * @brief Create a reference to a new function.
 *
 * This is a syntactic abbreviation for LuaRef::newFunction ().
 */
template <class F>
[[nodiscard]] inline LuaRef newFunction(lua_State* L, F&& func)
{
    return LuaRef::newFunction(L, std::forward<F>(func));
}

//=================================================================================================
/**
 * @brief Create a reference to a value in the global table.
 *
 * This is a syntactic abbreviation for LuaRef::getGlobal ().
 */
[[nodiscard]] inline LuaRef getGlobal(lua_State* L, const char* name)
{
    return LuaRef::getGlobal(L, name);
}

//=================================================================================================
/**
 * @brief C++ like cast syntax, safe.
 */
template <class T>
[[nodiscard]] TypeResult<T> cast(const LuaRef& ref)
{
    return ref.cast<T>();
}

/**
 * @brief C++ like cast syntax, unsafe.
 */
template <class T>
[[nodiscard]] T unsafe_cast(const LuaRef& ref)
{
    return ref.unsafe_cast<T>();
}
} // namespace luabridge

namespace std {
template <>
struct hash<luabridge::LuaRef>
{
    std::size_t operator()(const luabridge::LuaRef& x) const
    {
        return x.hash();
    }
};
} // namespace std

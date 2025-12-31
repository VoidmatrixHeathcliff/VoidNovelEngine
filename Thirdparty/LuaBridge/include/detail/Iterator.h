// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2018, Dmitry Tarakanov
// Copyright 2012, Vinnie Falco <vinnie.falco@gmail.com>
// SPDX-License-Identifier: MIT

#pragma once

#include "LuaRef.h"

#include <utility>

namespace luabridge {

//=================================================================================================
/**
 * @brief Iterator class to allow table iteration.
 *
 * @see Range class.
 */
class Iterator
{
public:
    explicit Iterator(const LuaRef& table, bool isEnd = false)
        : m_L(table.state())
        , m_table(table)
        , m_key(table.state()) // m_key is nil
        , m_value(table.state()) // m_value is nil
    {
        if (! isEnd)
        {
            next(); // get the first (key, value) pair from table
        }
    }

    /**
     * @brief Return an associated Lua state.
     *
     * @return A Lua state.
     */
    lua_State* state() const noexcept
    {
        return m_L;
    }

    /**
     * @brief Dereference the iterator.
     *
     * @return A key-value pair for a current table entry.
     */
    std::pair<LuaRef, LuaRef> operator*() const
    {
        return std::make_pair(m_key, m_value);
    }

    /**
     * @brief Return the value referred by the iterator.
     *
     * @return A value for the current table entry.
     */
    LuaRef operator->() const
    {
        return m_value;
    }

    /**
     * @brief Compare two iterators.
     *
     * @param rhs Another iterator.
     *
     * @return True if iterators point to the same entry of the same table, false otherwise.
     */
    bool operator!=(const Iterator& rhs) const
    {
        LUABRIDGE_ASSERT(m_L == rhs.m_L);

        return ! m_table.rawequal(rhs.m_table) || ! m_key.rawequal(rhs.m_key);
    }

    /**
     * @brief Move the iterator to the next table entry.
     *
     * @return This iterator.
     */
    Iterator& operator++()
    {
        if (isNil())
        {
            // if the iterator reaches the end, do nothing
            return *this;
        }
        else
        {
            next();
            return *this;
        }
    }

    /**
     * @brief Check if the iterator points after the last table entry.
     *
     * @return True if there are no more table entries to iterate, false otherwise.
     */
    bool isNil() const noexcept
    {
        return m_key.isNil();
    }

    /**
     * @brief Return the key for the current table entry.
     *
     * @return A reference to the entry key.
     */
    LuaRef key() const
    {
        return m_key;
    }

    /**
     * @brief Return the key for the current table entry.
     *
     * @return A reference to the entry value.
     */
    LuaRef value() const
    {
        return m_value;
    }

private:
    // Don't use postfix increment, it is less efficient
    Iterator operator++(int);

    void next()
    {
#if LUABRIDGE_SAFE_STACK_CHECKS
        if (! lua_checkstack(m_L, 2))
        {
            m_key = LuaNil();
            m_value = LuaNil();
            return;
        }
#endif

        m_table.push();
        m_key.push();

        if (lua_next(m_L, -2))
        {
            m_value.pop();
            m_key.pop();
        }
        else
        {
            m_key = LuaNil();
            m_value = LuaNil();
        }

        lua_pop(m_L, 1);
    }

    lua_State* m_L = nullptr;
    LuaRef m_table;
    LuaRef m_key;
    LuaRef m_value;
};

//=================================================================================================
/**
 * @brief Range class taking two table iterators.
 */
class Range
{
public:
    Range(const Iterator& begin, const Iterator& end)
        : m_begin(begin)
        , m_end(end)
    {
    }

    const Iterator& begin() const noexcept
    {
        return m_begin;
    }

    const Iterator& end() const noexcept
    {
        return m_end;
    }

private:
    Iterator m_begin;
    Iterator m_end;
};

//=================================================================================================
/**
 * @brief Return a range for the Lua table reference.
 *
 * @return A range suitable for range-based for statement.
 */
inline Range pairs(const LuaRef& table)
{
    return Range{ Iterator(table, false), Iterator(table, true) };
}

} // namespace luabridge

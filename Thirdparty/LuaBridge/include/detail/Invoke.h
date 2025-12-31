// https://github.com/kunitoki/LuaBridge3
// Copyright 2021, Lucio Asnaghi
// SPDX-License-Identifier: MIT

#pragma once

#include "Config.h"
#include "Errors.h"
#include "Stack.h"
#include "LuaRef.h"
#include "LuaException.h"

#include <vector>
#include <functional>
#include <optional>
#include <variant>
#include <tuple>

namespace luabridge {

//=================================================================================================
/**
 * @brief Result of a lua invocation.
 */
class LuaResult
{
public:
    /**
     * @brief Get if the result was ok and didn't raise a lua error.
     */
    explicit operator bool() const noexcept
    {
        return !m_ec;
    }

    /**
     * @brief Return if the invocation was ok and didn't raise a lua error.
     */
    bool wasOk() const noexcept
    {
        return !m_ec;
    }

    /**
     * @brief Return if the invocation did raise a lua error.
     */
    bool hasFailed() const noexcept
    {
        return !!m_ec;
    }

    /**
     * @brief Return the error code, if any.
     *
     * In case the invcation didn't raise any lua error, the value returned equals to a
     * default constructed std::error_code.
     */
    std::error_code errorCode() const noexcept
    {
        return m_ec;
    }

    /**
     * @brief Return the error message, if any.
     */
    std::string errorMessage() const noexcept
    {
        if (std::holds_alternative<std::string>(m_data))
        {
            const auto& message = std::get<std::string>(m_data);
            return message.empty() ? m_ec.message() : message;
        }

        return {};
    }

    /**
     * @brief Return the number of return values.
     */
    std::size_t size() const noexcept
    {
        if (std::holds_alternative<std::vector<LuaRef>>(m_data))
            return std::get<std::vector<LuaRef>>(m_data).size();

        return 0;
    }

    /**
     * @brief Get a return value at a specific index.
     */
    LuaRef operator[](std::size_t index) const
    {
        LUABRIDGE_ASSERT(m_ec == std::error_code());

        if (std::holds_alternative<std::vector<LuaRef>>(m_data))
        {
            const auto& values = std::get<std::vector<LuaRef>>(m_data);

            LUABRIDGE_ASSERT(index < values.size());
            return values[index];
        }

        return LuaRef(m_L);
    }

private:
    template <class... Args>
    friend LuaResult call(const LuaRef&, Args&&...);

    template <class F, class... Args>
    friend LuaResult callWithHandler(const LuaRef&, F&&, Args&&...);

    static LuaResult errorFromStack(lua_State* L, std::error_code ec)
    {
        auto errorString = lua_tostring(L, -1);
        lua_pop(L, 1);

        return LuaResult(L, ec, errorString ? errorString : ec.message());
    }

    static LuaResult valuesFromStack(lua_State* L, int stackTop)
    {
        std::vector<LuaRef> values;

        const int numReturnedValues = lua_gettop(L) - stackTop;
        if (numReturnedValues > 0)
        {
            values.reserve(numReturnedValues);

            for (int index = numReturnedValues; index > 0; --index)
                values.emplace_back(LuaRef::fromStack(L, -index));

            lua_pop(L, numReturnedValues);
        }

        return LuaResult(L, std::move(values));
    }

    LuaResult(lua_State* L, std::error_code ec, std::string_view errorString)
        : m_L(L)
        , m_ec(ec)
        , m_data(std::string(errorString))
    {
    }

    explicit LuaResult(lua_State* L, std::vector<LuaRef> values) noexcept
        : m_L(L)
        , m_data(std::move(values))
    {
    }

    lua_State* m_L = nullptr;
    std::error_code m_ec;
    std::variant<std::vector<LuaRef>, std::string> m_data;
};

//=================================================================================================
/**
 * @brief Safely call Lua code.
 *
 * These overloads allow Lua code to be called throught `lua_pcall`.  The return value is provided as
 * a `LuaResult` which will hold the return values or an error if the call failed.
 *
 * If an error occurs, a `LuaException` is thrown or if exceptions are disabled the function result will
 * contain a error code and evaluate false.
 *
 * @note The function might throw a `LuaException` if the application is compiled with exceptions on
 * and they are enabled globally by calling `enableExceptions` in two cases:
 * - one of the arguments passed cannot be pushed in the stack, for example a unregistered C++ class
 * - the lua invaction calls the panic handler, which is converted to a C++ exception
 *
 * @return A result object.
*/
template <class F, class... Args>
LuaResult callWithHandler(const LuaRef& object, F&& errorHandler, Args&&... args)
{
    static constexpr bool isValidHandler = !std::is_same_v<detail::remove_cvref_t<F>, detail::remove_cvref_t<decltype(std::ignore)>>;

    lua_State* L = object.state();
    const int stackTop = lua_gettop(L);

    if constexpr (isValidHandler)
        detail::push_function(L, std::forward<F>(errorHandler), ""); // Stack: error handler (eh)

    object.push(); // Stack: eh, ref

    {
        const auto [result, index] = detail::push_arguments(L, std::forward_as_tuple(args...)); // Stack: eh, ref, args...
        if (! result)
        {
            lua_pop(L, static_cast<int>(index) + 1);
            return LuaResult(L, result, result.message());
        }
    }

    const int code = lua_pcall(L, sizeof...(Args), LUA_MULTRET, isValidHandler ? (-static_cast<int>(sizeof...(Args)) - 2) : 0);
    if (code != LUABRIDGE_LUA_OK)
    {
        auto ec = makeErrorCode(ErrorCode::LuaFunctionCallFailed);

#if LUABRIDGE_HAS_EXCEPTIONS
        if constexpr (! isValidHandler)
        {
            if (LuaException::areExceptionsEnabled(L))
                LuaException::raise(L, ec);
        }
#endif

        return LuaResult::errorFromStack(L, ec);
    }

    return LuaResult::valuesFromStack(L, stackTop);
}

template <class... Args>
LuaResult call(const LuaRef& object, Args&&... args)
{
    return callWithHandler(object, std::ignore, std::forward<Args>(args)...);
}

//=============================================================================================
/**
 * @brief Wrapper for `lua_pcall` that throws if exceptions are enabled.
 */
inline int pcall(lua_State* L, int nargs = 0, int nresults = 0, int msgh = 0)
{
    const int code = lua_pcall(L, nargs, nresults, msgh);

#if LUABRIDGE_HAS_EXCEPTIONS
    if (code != LUABRIDGE_LUA_OK && LuaException::areExceptionsEnabled(L))
        LuaException::raise(L, makeErrorCode(ErrorCode::LuaFunctionCallFailed));
#endif

    return code;
}

//=============================================================================================
template <class Impl, class LuaRef>
template <class... Args>
LuaResult LuaRefBase<Impl, LuaRef>::operator()(Args&&... args) const
{
    return luabridge::call(*this, std::forward<Args>(args)...);
}

template <class Impl, class LuaRef>
template <class... Args>
LuaResult LuaRefBase<Impl, LuaRef>::call(Args&&... args) const
{
    return luabridge::call(*this, std::forward<Args>(args)...);
}

template <class Impl, class LuaRef>
template <class F, class... Args>
LuaResult LuaRefBase<Impl, LuaRef>::callWithHandler(F&& errorHandler, Args&&... args) const
{
    return luabridge::callWithHandler(*this, std::forward<F>(errorHandler), std::forward<Args>(args)...);
}

} // namespace luabridge

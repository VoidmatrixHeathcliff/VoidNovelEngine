// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2020, Dmitry Tarakanov
// Copyright 2019, George Tokmaji
// SPDX-License-Identifier: MIT

#pragma once

#include <cassert>

#if !(__cplusplus >= 201703L || (defined(_MSC_VER) && _HAS_CXX17))
#error LuaBridge 3 requires a compliant C++17 compiler, or C++17 has not been enabled !
#endif

#if !defined(LUABRIDGE_HAS_EXCEPTIONS)
#if defined(_MSC_VER)
#if _CPPUNWIND || _HAS_EXCEPTIONS
#define LUABRIDGE_HAS_EXCEPTIONS 1
#else
#define LUABRIDGE_HAS_EXCEPTIONS 0
#endif
#elif defined(__clang__)
#if __EXCEPTIONS && __has_feature(cxx_exceptions)
#define LUABRIDGE_HAS_EXCEPTIONS 1
#else
#define LUABRIDGE_HAS_EXCEPTIONS 0
#endif
#elif defined(__GNUC__)
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
#define LUABRIDGE_HAS_EXCEPTIONS 1
#else
#define LUABRIDGE_HAS_EXCEPTIONS 0
#endif
#endif
#endif

#if LUABRIDGE_HAS_EXCEPTIONS
#define LUABRIDGE_IF_EXCEPTIONS(...) __VA_ARGS__
#define LUABRIDGE_IF_NO_EXCEPTIONS(...)
#else
#define LUABRIDGE_IF_EXCEPTIONS(...)
#define LUABRIDGE_IF_NO_EXCEPTIONS(...) __VA_ARGS__
#endif

#if defined(LUAU_FASTMATH_BEGIN)
#define LUABRIDGE_ON_LUAU 1
#elif defined(LUAJIT_VERSION)
#define LUABRIDGE_ON_LUAJIT 1
#elif defined(RAVI_OPTION_STRING2)
#define LUABRIDGE_ON_RAVI 1
#elif defined(LUA_VERSION_NUM)
#define LUABRIDGE_ON_LUA 1
#else
#error "Lua headers must be included prior to LuaBridge ones"
#endif

#if defined(__OBJC__)
#define LUABRIDGE_ON_OBJECTIVE_C 1
#endif

/**
 * @brief Enable safe stack checks to avoid lua stack overflow when pushing values on the stack.
 * 
 * @note Default is enabled. 
 */
#if !defined(LUABRIDGE_SAFE_STACK_CHECKS)
#define LUABRIDGE_SAFE_STACK_CHECKS 1
#endif

/**
 * @brief Enable safe exception handling when lua is compiled as `C` and exceptions raise during execution of registered `lua_CFunction`.
 * 
 * This is a problem that manifests when exceptions are leaking a CFunction when lua is compiled as `C` because the library will then longjmp
 * instead of correctly unwinding the exception into C++ land. If you have exceptions enabled and are compiling lua as `C` and you are getting random
 * crashes when invoking CFunctions that throw, you have two options: or you catch exceptions in your CFunction and raise a `lua_error` instead
 * or you enable this macro, which will add a safe indirection doing exceptions catching and raising when invoking your registered CFunction.
 * 
 * @warning When enabled, some performance degradation is to be expected when invoking registered  `lua_CFunction` through the library.
 *  
 * @note Default is disabled, can only be enabled when  `LUABRIDGE_HAS_EXCEPTIONS` is 1.
 */
#if !defined(LUABRIDGE_SAFE_LUA_C_EXCEPTION_HANDLING)
#define LUABRIDGE_SAFE_LUA_C_EXCEPTION_HANDLING 0
#endif

/**
 * @brief Control raising when an unregistered class is used.
 * 
 * @note Default is enabled when exceptions are enabled, disabled otherwise.
 */
#if !defined(LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE)
#if LUABRIDGE_HAS_EXCEPTIONS
#define LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE 1
#else
#define LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE 0
#endif
#endif

#if !defined(LUABRIDGE_ASSERT)
#if defined(NDEBUG) && !defined(LUABRIDGE_FORCE_ASSERT_RELEASE)
#define LUABRIDGE_ASSERT(expr) ((void)(expr))
#else
#define LUABRIDGE_ASSERT(expr) assert(expr)
#endif
#endif

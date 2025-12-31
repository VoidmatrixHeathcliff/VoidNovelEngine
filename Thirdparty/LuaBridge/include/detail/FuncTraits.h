// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2020, Dmitry Tarakanov
// Copyright 2019, George Tokmaji
// Copyright 2012, Vinnie Falco <vinnie.falco@gmail.com>
// SPDX-License-Identifier: MIT

#pragma once

#include "Config.h"

#include <functional>
#include <tuple>

namespace luabridge {
namespace detail {

//=================================================================================================
/**
 * @brief Invokes undefined behavior when an unreachable part of the code is reached.
 *
 * An implementation may use this to optimize impossible code branches away (typically, in optimized builds) or to trap them to prevent
 * further execution (typically, in debug builds).
 */
[[noreturn]] inline void unreachable()
{
#if defined(__GNUC__) // GCC, Clang, ICC
    __builtin_unreachable();
#elif defined(_MSC_VER) // MSVC
    __assume(false);
#endif
}

//=================================================================================================
/**
 * @brief Provides the member typedef type which is the type referred to by T with its topmost cv-qualifiers removed.
 */
template< class T >
struct remove_cvref
{
    typedef std::remove_cv_t<std::remove_reference_t<T>> type;
};

template <class T>
using remove_cvref_t = typename remove_cvref<T>::type;

//=================================================================================================
/**
 * @brief Generic function traits.
 *
 * @tparam IsMember True if the function is a member function pointer.
 * @tparam IsConst True if the function is const.
 * @tparam R Return type of the function.
 * @tparam Args Arguments types as variadic parameter pack.
 */
template <bool IsMember, bool IsConst, class R, class... Args>
struct function_traits_base
{
    using result_type = R;

    using argument_types = std::tuple<Args...>;

    static constexpr auto arity = sizeof...(Args);

    static constexpr auto is_member = IsMember;

    static constexpr auto is_const = IsConst;
};

template <class, bool Enable>
struct function_traits_impl;

template <class R, class... Args>
struct function_traits_impl<R(Args...), true> : function_traits_base<false, false, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R (*)(Args...), true> : function_traits_base<false, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (C::*)(Args...), true> : function_traits_base<true, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (C::*)(Args...) const, true> : function_traits_base<true, true, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R(Args...) noexcept, true> : function_traits_base<false, false, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R (*)(Args...) noexcept, true> : function_traits_base<false, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (C::*)(Args...) noexcept, true> : function_traits_base<true, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (C::*)(Args...) const noexcept, true> : function_traits_base<true, true, R, Args...>
{
};

#if defined(_MSC_VER) && defined(_M_IX86) // Windows: WINAPI (a.k.a. __stdcall) function pointers (32bit only).
inline static constexpr bool is_stdcall_default_calling_convention = std::is_same_v<void __stdcall(), void()>;
inline static constexpr bool is_fastcall_default_calling_convention = std::is_same_v<void __fastcall(), void()>;

template <class R, class... Args>
struct function_traits_impl<R __stdcall(Args...), !is_stdcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R (__stdcall *)(Args...), !is_stdcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__stdcall C::*)(Args...), true> : function_traits_base<true, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__stdcall C::*)(Args...) const, true> : function_traits_base<true, true, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R __stdcall(Args...) noexcept, !is_stdcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R (__stdcall *)(Args...) noexcept, !is_stdcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__stdcall C::*)(Args...) noexcept, true> : function_traits_base<true, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__stdcall C::*)(Args...) const noexcept, true> : function_traits_base<true, true, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R __fastcall(Args...), !is_fastcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R (__fastcall *)(Args...), !is_fastcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__fastcall C::*)(Args...), true> : function_traits_base<true, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__fastcall C::*)(Args...) const, true> : function_traits_base<true, true, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R __fastcall(Args...) noexcept, !is_fastcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class R, class... Args>
struct function_traits_impl<R (__fastcall *)(Args...) noexcept, !is_fastcall_default_calling_convention> : function_traits_base<false, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__fastcall C::*)(Args...) noexcept, true> : function_traits_base<true, false, R, Args...>
{
};

template <class C, class R, class... Args>
struct function_traits_impl<R (__fastcall C::*)(Args...) const noexcept, true> : function_traits_base<true, true, R, Args...>
{
};
#endif

template <class F>
struct functor_traits_impl : function_traits_impl<decltype(&F::operator()), true>
{
};

//=================================================================================================
/**
 * @brief Traits class for callable objects (e.g. function pointers, lambdas)
 *
 * @tparam F Callable object.
 */
template <class F>
struct function_traits : std::conditional_t<std::is_class_v<F>,
                                            detail::functor_traits_impl<F>,
                                            detail::function_traits_impl<F, true>>
{
};

//=================================================================================================
/**
 * @brief Deduces the argument type of a callble object or void in case it has no argument.
 *
 * @tparam I Argument index.
 * @tparam F Callable object.
 */
template <std::size_t I, class F, class = void>
struct function_argument_or_void
{
    using type = void;
};

template <std::size_t I, class F>
struct function_argument_or_void<I, F, std::enable_if_t<I < std::tuple_size_v<typename function_traits<F>::argument_types>>>
{
    using type = std::tuple_element_t<I, typename function_traits<F>::argument_types>;
};

template <std::size_t I, class F>
using function_argument_or_void_t = typename function_argument_or_void<I, F>::type;

//=================================================================================================
/**
 * @brief Deduces the return type of a callble object.
 *
 * @tparam F Callable object.
 */
template <class F>
using function_result_t = typename function_traits<F>::result_type;

/**
 * @brief Deduces the argument type of a callble object.
 *
 * @tparam I Argument index.
 * @tparam F Callable object.
 */
template <std::size_t I, class F>
using function_argument_t = std::tuple_element_t<I, typename function_traits<F>::argument_types>;

/**
 * @brief Deduces the arguments type of a callble object.
 *
 * @tparam F Callable object.
 */
template <class F>
using function_arguments_t = typename function_traits<F>::argument_types;

/**
 * @brief An integral constant expression that gives the number of arguments accepted by the callable object.
 *
 * @tparam F Callable object.
 */
template <class F>
static constexpr std::size_t function_arity_v = function_traits<F>::arity;

/**
 * @brief An boolean constant expression that checks if the callable object is a member function.
 *
 * @tparam F Callable object.
 */
template <class F>
static constexpr bool function_is_member_v = function_traits<F>::is_member;

/**
 * @brief An boolean constant expression that checks if the callable object is const.
 *
 * @tparam F Callable object.
 */
template <class F>
static constexpr bool function_is_const_v = function_traits<F>::is_const;

//=================================================================================================
/**
 * @brief Detect if we T is a callable object.
 *
 * @tparam T Potentially callable object.
 */
template <class T, class = void>
struct is_callable
{
    static constexpr bool value = false;
};

template <class T>
struct is_callable<T, std::void_t<decltype(&T::operator())>>
{
    static constexpr bool value = true;
};

template <class T>
struct is_callable<T, std::enable_if_t<std::is_pointer_v<T> && std::is_function_v<std::remove_pointer_t<T>>>>
{
    static constexpr bool value = true;
};

template <class T>
struct is_callable<T, std::enable_if_t<std::is_member_function_pointer_v<T>>>
{
    static constexpr bool value = true;
};

template <class T>
inline static constexpr bool is_callable_v = is_callable<T>::value;

//=================================================================================================
/**
 * @brief Detect if we T is a const member function pointer.
 *
 * @tparam T Potentially const member function pointer.
 */
template <class T>
struct is_const_member_function_pointer
{
    static constexpr bool value = false;
};

template <class T, class R, class... Args>
struct is_const_member_function_pointer<R (T::*)(Args...)>
{
    static constexpr bool value = false;
};

template <class T, class R, class... Args>
struct is_const_member_function_pointer<R (T::*)(Args...) const>
{
    static constexpr bool value = true;
};

template <class T, class R, class... Args>
struct is_const_member_function_pointer<R (T::*)(Args...) noexcept>
{
    static constexpr bool value = false;
};

template <class T, class R, class... Args>
struct is_const_member_function_pointer<R (T::*)(Args...) const noexcept>
{
    static constexpr bool value = true;
};

template <class T>
inline static constexpr bool is_const_member_function_pointer_v = is_const_member_function_pointer<T>::value;

//=================================================================================================
/**
 * @brief Detect if T is a lua cfunction pointer.
 *
 * @tparam T Potentially lua cfunction pointer.
 */
template <class T>
struct is_cfunction_pointer
{
    static constexpr bool value = false;
};

template <>
struct is_cfunction_pointer<int (*)(lua_State*)>
{
    static constexpr bool value = true;
};

template <class T>
inline static constexpr bool is_cfunction_pointer_v = is_cfunction_pointer<T>::value;

//=================================================================================================
/**
 * @brief Detect if T is a member lua cfunction pointer.
 *
 * @tparam T Potentially member lua cfunction pointer.
 */
template <class T>
struct is_member_cfunction_pointer
{
    static constexpr bool value = false;
};

template <class T>
struct is_member_cfunction_pointer<int (T::*)(lua_State*)>
{
    static constexpr bool value = true;
};

template <class T>
struct is_member_cfunction_pointer<int (T::*)(lua_State*) const>
{
    static constexpr bool value = true;
};

template <class T>
inline static constexpr bool is_member_cfunction_pointer_v = is_member_cfunction_pointer<T>::value;

/**
 * @brief Detect if T is a const member lua cfunction pointer.
 *
 * @tparam T Potentially const member lua cfunction pointer.
 */
template <class T>
struct is_const_member_cfunction_pointer
{
    static constexpr bool value = false;
};

template <class T>
struct is_const_member_cfunction_pointer<int (T::*)(lua_State*)>
{
    static constexpr bool value = false;
};

template <class T>
struct is_const_member_cfunction_pointer<int (T::*)(lua_State*) const>
{
    static constexpr bool value = true;
};

template <class T>
inline static constexpr bool is_const_member_cfunction_pointer_v = is_const_member_cfunction_pointer<T>::value;

//=================================================================================================
/**
 * @brief Detect if T is a member or non member lua cfunction pointer.
 *
 * @tparam T Potentially member or non member lua cfunction pointer.
 */
template <class T>
inline static constexpr bool is_any_cfunction_pointer_v = is_cfunction_pointer_v<T> || is_member_cfunction_pointer_v<T>;

//=================================================================================================
/**
 * @brief A constexpr check for proxy_member functions.
 *
 * @tparam T Type where the callable should be able to operate.
 * @tparam F Callable object.
 */
template <class T, class F>
inline static constexpr bool is_proxy_member_function_v =
    !std::is_member_function_pointer_v<F> &&
    std::is_same_v<T, remove_cvref_t<std::remove_pointer_t<function_argument_or_void_t<0, F>>>>;

template <class T, class F>
inline static constexpr bool is_const_proxy_function_v =
    is_proxy_member_function_v<T, F> &&
    std::is_const_v<std::remove_reference_t<std::remove_pointer_t<function_argument_or_void_t<0, F>>>>;

//=================================================================================================
/**
 * @brief An integral constant expression that gives the number of arguments excluding one type (usually used with lua_State*) accepted by the callable object.
 *
 * @tparam F Callable object.
 */
template <class, class>
struct function_arity_excluding
{
};

template < class... Ts, class ExclusionType>
struct function_arity_excluding<std::tuple<Ts...>, ExclusionType>
    : std::integral_constant<std::size_t, (0 + ... + (std::is_same_v<std::decay_t<Ts>, ExclusionType> ? 0 : 1))>
{
};

template <class F, class ExclusionType>
inline static constexpr std::size_t function_arity_excluding_v = function_arity_excluding<function_arguments_t<F>, ExclusionType>::value;

/**
 * @brief An integral constant expression that gives the number of arguments excluding one type (usually used with lua_State*) accepted by the callable object.
 *
 * @tparam F Callable object.
 */
template <class, class, class, class, class = void>
struct member_function_arity_excluding
{
};

template <class T, class F, class... Ts, class ExclusionType>
struct member_function_arity_excluding<T, F, std::tuple<Ts...>, ExclusionType, std::enable_if_t<!is_proxy_member_function_v<T, F>>>
    : std::integral_constant<std::size_t, (0 + ... + (std::is_same_v<std::decay_t<Ts>, ExclusionType> ? 0 : 1))>
{
};

template <class T, class F, class... Ts, class ExclusionType>
struct member_function_arity_excluding<T, F, std::tuple<Ts...>, ExclusionType, std::enable_if_t<is_proxy_member_function_v<T, F>>>
    : std::integral_constant<std::size_t, (0 + ... + (std::is_same_v<std::decay_t<Ts>, ExclusionType> ? 0 : 1)) - 1>
{
};

template <class T, class F, class ExclusionType>
inline static constexpr std::size_t member_function_arity_excluding_v = member_function_arity_excluding<T, F, function_arguments_t<F>, ExclusionType>::value;

//=================================================================================================
/**
 * @brief Detectors for const and non const functions in packs and counting them.
 */
template <class T, class F>
static constexpr bool is_const_function =
    detail::is_const_member_function_pointer_v<F> ||
        (detail::function_arity_v<F> > 0 && detail::is_const_proxy_function_v<T, F>);

template <class T, class... Fs>
inline static constexpr std::size_t const_functions_count = (0 + ... + (is_const_function<T, Fs> ? 1 : 0));

template <class T, class... Fs>
inline static constexpr std::size_t non_const_functions_count = (0 + ... + (is_const_function<T, Fs> ? 0 : 1));

//=================================================================================================
/**
 * @brief Simple make_tuple alternative that doesn't decay the types.
 *
 * @tparam Types Argument types that will compose the tuple.
 */
template <class... Types>
constexpr auto tupleize(Types&&... types)
{
    return std::tuple<Types...>(std::forward<Types>(types)...);
}

//=================================================================================================
/**
 * @brief Remove first type from tuple.
 */
template <class T>
struct remove_first_type
{
};

template <class T, class... Ts>
struct remove_first_type<std::tuple<T, Ts...>>
{
    using type = std::tuple<Ts...>;
};

template <class T>
using remove_first_type_t = typename remove_first_type<T>::type;

} // namespace detail
} // namespace luabridge

// https://github.com/kunitoki/LuaBridge3
// Copyright 2020, Lucio Asnaghi
// Copyright 2019, Dmitry Tarakanov
// Copyright 2012, Vinnie Falco <vinnie.falco@gmail.com>
// SPDX-License-Identifier: MIT

#pragma once

#include "Config.h"
#include "Errors.h"
#include "LuaException.h"
#include "ClassInfo.h"
#include "TypeTraits.h"
#include "Result.h"
#include "Stack.h"

#include <stdexcept>
#include <type_traits>

namespace luabridge {
namespace detail {

//=================================================================================================
/**
 * @brief Return the identity pointer for our lightuserdata tokens.
 *
 * Because of Lua's dynamic typing and our improvised system of imposing C++ class structure, there is the possibility that executing
 * scripts may knowingly or unknowingly cause invalid data to get passed to the C functions created by LuaBridge.
 *
 * In particular, our security model addresses the following:
 *
 *   1. Scripts cannot create a userdata (ignoring the debug lib).
 *
 *   2. Scripts cannot create a lightuserdata (ignoring the debug lib).
 *
 *   3. Scripts cannot set the metatable on a userdata.
 */

/**
 * @brief Interface to a class pointer retrievable from a userdata.
 */
class Userdata
{
private:
    //=============================================================================================
    /**
     * @brief Validate and retrieve a Userdata on the stack.
     *
     * The Userdata must exactly match the corresponding class table or const table, or else a Lua error is raised. This is used for the
     * __gc metamethod.
     */
    static Userdata* getExactClass(lua_State* L, int index, const void* classKey)
    {
        return (void)classKey, static_cast<Userdata*>(lua_touserdata(L, lua_absindex(L, index)));
    }

    //=============================================================================================
    /**
     * @brief Validate and retrieve a Userdata on the stack.
     *
     * The Userdata must be derived from or the same as the given base class, identified by the key. If canBeConst is false, generates
     * an error if the resulting Userdata represents to a const object. We do the type check first so that the error message is informative.
     */
    static Userdata* getClass(lua_State* L,
                              int index,
                              const void* registryConstKey,
                              const void* registryClassKey,
                              bool canBeConst)
    {
        const int result = lua_getmetatable(L, index); // Stack: object metatable (ot) | nil
        if (result == 0 || !lua_istable(L, -1))
        {
            lua_rawgetp(L, LUA_REGISTRYINDEX, registryClassKey); // Stack: ot | nil, registry metatable (rt) | nil
            return throwBadArg(L, index);
        }

        lua_rawgetp(L, -1, getConstKey()); // Stack: ot | nil, const table (co) | nil
        LUABRIDGE_ASSERT(lua_istable(L, -1) || lua_isnil(L, -1));

        // If const table is NOT present, object is const. Use non-const registry table
        // if object cannot be const, so constness validation is done automatically.
        // E.g. nonConstFn (constObj)
        // -> canBeConst = false, isConst = true
        // -> 'Class' registry table, 'const Class' object table
        // -> 'expected Class, got const Class'
        const bool isConst = lua_isnil(L, -1); // Stack: ot | nil, nil, rt
        lua_rawgetp(L, LUA_REGISTRYINDEX, (isConst && canBeConst)
            ? registryConstKey
            : registryClassKey); // Stack: ot, co | nil, rt

        lua_insert(L, -3); // Stack: rt, ot, co | nil
        lua_pop(L, 1); // Stack: rt, ot

        for (;;)
        {
            if (lua_rawequal(L, -1, -2)) // Stack: rt, ot
            {
                lua_pop(L, 2); // Stack: -
                return static_cast<Userdata*>(lua_touserdata(L, index));
            }

            // Replace current metatable with it's base class.
            lua_rawgetp(L, -1, getParentKey()); // Stack: rt, ot, parent ot (pot) | nil

            if (lua_isnil(L, -1)) // Stack: rt, ot, nil
            {
                // Drop the object metatable because it may be some parent metatable
                lua_pop(L, 2); // Stack: rt
                return throwBadArg(L, index);
            }

            lua_remove(L, -2); // Stack: rt, pot
        }

        // no return
    }

    static bool isInstance(lua_State* L, int index, const void* registryKey)
    {
        const auto result = lua_getmetatable(L, index); // Stack: object metatable (ot) | nil
        if (result == 0)
            return false;

        if (!lua_istable(L, -1))
        {
            lua_pop(L, 1); // Stack: -
            return false;
        }

        lua_rawgetp(L, LUA_REGISTRYINDEX, registryKey); // Stack: ot, rt
        lua_insert(L, -2); // Stack: rt, ot

        for (;;)
        {
            if (lua_rawequal(L, -1, -2)) // Stack: rt, ot
            {
                lua_pop(L, 2); // Stack: -
                return true;
            }

            // Replace current metatable with it's base class.
            lua_rawgetp(L, -1, getParentKey()); // Stack: rt, ot, parent ot (pot) | nil

            if (lua_isnil(L, -1)) // Stack: rt, ot, nil
            {
                // Drop the object metatable because it may be some parent metatable
                lua_pop(L, 3); // Stack: -
                return false;
            }

            lua_remove(L, -2); // Stack: rt, pot
        }

        // no return
    }

    static Userdata* throwBadArg(lua_State* L, int index)
    {
        LUABRIDGE_ASSERT(lua_istable(L, -1) || lua_isnil(L, -1)); // Stack: rt | nil

        const char* expected = 0;
        if (lua_isnil(L, -1)) // Stack: nil
        {
            expected = "unregistered class";
        }
        else
        {
            lua_rawgetp(L, -1, getTypeKey()); // Stack: rt, registry type
            expected = lua_tostring(L, -1);
            lua_pop(L, 1); // Stack: rt
        }

        const char* got = nullptr;
        if (lua_isuserdata(L, index))
        {
            lua_getmetatable(L, index); // Stack: rt, ot | nil
            if (lua_istable(L, -1)) // Stack: rt, ot
            {
                lua_rawgetp(L, -1, getTypeKey()); // Stack: rt, ot, object type | nil
                if (lua_isstring(L, -1))
                    got = lua_tostring(L, -1);

                lua_pop(L, 1); // Stack: rt, ot
            }

            lua_pop(L, 1); // Stack: rt
        }

        if (!got)
        {
            lua_pop(L, 1); // Stack
            got = lua_typename(L, lua_type(L, index));
        }

        luaL_argerror(L, index, lua_pushfstring(L, "%s expected, got %s", expected, got));
        return nullptr;
    }

public:
    virtual ~Userdata() {}

    //=============================================================================================
    /**
     * @brief Returns the Userdata* if the class on the Lua stack matches.
     *
     * If the class does not match, a Lua error is raised.
     *
     * @tparam T  A registered user class.
     *
     * @param L A Lua state.
     * @param index The index of an item on the Lua stack.
     *
     * @return A userdata pointer if the class matches.
     */
    template <class T>
    static Userdata* getExact(lua_State* L, int index)
    {
        return getExactClass(L, index, detail::getClassRegistryKey<T>());
    }

    //=============================================================================================
    /**
     * @brief Get a pointer to the class from the Lua stack.
     *
     * If the object is not the class or a subclass, or it violates the const-ness, a Lua error is raised.
     *
     * @tparam T A registered user class.
     *
     * @param L A Lua state.
     * @param index The index of an item on the Lua stack.
     * @param canBeConst TBD
     *
     * @return A pointer if the class and constness match.
     */
    template <class T>
    static T* get(lua_State* L, int index, bool canBeConst)
    {
        if (lua_isnil(L, index))
            return nullptr;

        auto* clazz = getClass(L, index, detail::getConstRegistryKey<T>(), detail::getClassRegistryKey<T>(), canBeConst);
        if (! clazz)
            return nullptr;

        return static_cast<T*>(clazz->getPointer());
    }

    template <class T>
    static bool isInstance(lua_State* L, int index)
    {
        return isInstance(L, index, detail::getClassRegistryKey<T>())
            || isInstance(L, index, detail::getConstRegistryKey<T>());
    }

protected:
    Userdata() = default;

    /**
     * @brief Get an untyped pointer to the contained class.
     */
    void* getPointer() const noexcept
    {
        return m_p;
    }

    void* m_p = nullptr; // subclasses must set this
};

//=================================================================================================
/**
 * @brief Wraps a class object stored in a Lua userdata.
 *
 * The lifetime of the object is managed by Lua. The object is constructed inside the userdata using placement new.
 */
template <class T>
class UserdataValue : public Userdata
{
    using AlignType = typename std::conditional_t<alignof(T) <= alignof(double), T, void*>;

    static constexpr int MaxPadding = alignof(T) <= alignof(AlignType) ? 0 : alignof(T) - alignof(AlignType) + 1;

public:
    UserdataValue(const UserdataValue&) = delete;
    UserdataValue operator=(const UserdataValue&) = delete;

    ~UserdataValue()
    {
        if (getPointer() != nullptr)
        {
            getObject()->~T();
        }
    }

    /**
     * @brief Push a T via placement new.
     *
     * The caller is responsible for calling placement new using the returned uninitialized storage.
     *
     * @param L A Lua state.
     *
     * @return An object referring to the newly created userdata value.
     */
    static UserdataValue<T>* place(lua_State* L, std::error_code& ec)
    {
        auto* ud = new (lua_newuserdata_x<UserdataValue<T>>(L, sizeof(UserdataValue<T>))) UserdataValue<T>();

        lua_rawgetp(L, LUA_REGISTRYINDEX, detail::getClassRegistryKey<T>());

        if (!lua_istable(L, -1))
        {
            lua_pop(L, 1); // possibly: a nil

            ud->~UserdataValue<T>();

#if LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE
            ec = throw_or_error_code<LuaException>(L, ErrorCode::ClassNotRegistered);
#else
            ec = makeErrorCode(ErrorCode::ClassNotRegistered);
#endif

            return nullptr;
        }

        lua_setmetatable(L, -2);

        return ud;
    }

    /**
     * @brief Push T via copy construction from U.
     *
     * @tparam U A container type.
     *
     * @param L A Lua state.
     * @param u A container object l-value reference.
     * @param ec Error code that will be set in case of failure to push on the lua stack.
     */
    template <class U>
    static auto push(lua_State* L, const U& u) -> std::enable_if_t<std::is_copy_constructible_v<U>, Result>
    {
        std::error_code ec;
        auto* ud = place(L, ec);

        if (!ud)
            return ec;

        new (ud->getObject()) U(u);

        ud->commit();

        return {};
    }

    /**
     * @brief Push T via move construction from U.
     *
     * @tparam U A container type.
     *
     * @param L A Lua state.
     * @param u A container object r-value reference.
     * @param ec Error code that will be set in case of failure to push on the lua stack.
     */
    template <class U>
    static auto push(lua_State* L, U&& u) -> std::enable_if_t<std::is_move_constructible_v<U>, Result>
    {
        std::error_code ec;
        auto* ud = place(L, ec);

        if (!ud)
            return ec;

        new (ud->getObject()) U(std::move(u));

        ud->commit();

        return {};
    }

    /**
     * @brief Confirm object construction.
     */
    void commit() noexcept
    {
        m_p = getObject();
    }

    T* getObject() noexcept
    {
        // If this fails to compile it means you forgot to provide
        // a Container specialization for your container!

        if constexpr (MaxPadding == 0)
            return reinterpret_cast<T*>(&m_storage[0]);
        else
            return reinterpret_cast<T*>(&m_storage[0] + m_storage[sizeof(m_storage) - 1]);
    }

private:
    /**
     * @brief Used for placement construction.
     */
    UserdataValue() noexcept
        : Userdata()
    {
        if constexpr (MaxPadding > 0)
        {
            uintptr_t offset = reinterpret_cast<uintptr_t>(&m_storage[0]) % alignof(T);
            if (offset > 0)
                offset = alignof(T) - offset;

            assert(offset < MaxPadding);
            m_storage[sizeof(m_storage) - 1] = static_cast<unsigned char>(offset);
        }
    }

    alignas(AlignType) unsigned char m_storage[sizeof(T) + MaxPadding];
};

//=================================================================================================
/**
 * @brief Wraps a pointer to a class object inside a Lua userdata.
 *
 * The lifetime of the object is managed by C++.
 */
class UserdataPtr : public Userdata
{
public:
    UserdataPtr(const UserdataPtr&) = delete;
    UserdataPtr operator=(const UserdataPtr&) = delete;

    /**
     * @brief Push non-const pointer to object.
     *
     * @tparam T A user registered class.
     *
     * @param L A Lua state.
     * @param p A pointer to the user class instance.
     * @param ec Error code that will be set in case of failure to push on the lua stack.
     */
    template <class T>
    static Result push(lua_State* L, T* ptr)
    {
        if (ptr)
            return push(L, ptr, getClassRegistryKey<T>());

        lua_pushnil(L);
        return {};
    }

    /**
     * @brief Push const pointer to object.
     *
     * @tparam T A user registered class.
     *
     * @param L A Lua state.
     * @param p A pointer to the user class instance.
     * @param ec Error code that will be set in case of failure to push on the lua stack.
     */
    template <class T>
    static Result push(lua_State* L, const T* ptr)
    {
        if (ptr)
            return push(L, ptr, getConstRegistryKey<T>());

        lua_pushnil(L);
        return {};
    }

private:
    /**
     * @brief Push a pointer to object using metatable key.
     */
    static Result push(lua_State* L, const void* ptr, const void* key)
    {
        auto* udptr = new (lua_newuserdata_x<UserdataPtr>(L, sizeof(UserdataPtr))) UserdataPtr(const_cast<void*>(ptr));

        lua_rawgetp(L, LUA_REGISTRYINDEX, key);

        if (!lua_istable(L, -1))
        {
            lua_pop(L, 1); // possibly: a nil

            udptr->~UserdataPtr();

#if LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE
            return throw_or_error_code<LuaException>(L, ErrorCode::ClassNotRegistered);
#else
            return makeErrorCode(ErrorCode::ClassNotRegistered);
#endif
        }

        lua_setmetatable(L, -2);

        return {};
    }

    explicit UserdataPtr(void* ptr)
    {
        // Can't construct with a null object!
        LUABRIDGE_ASSERT(ptr != nullptr);
        m_p = ptr;
    }
};

//============================================================================
/**
 * @brief Wraps an external value type to a class object inside a Lua userdata.
 *
 * The lifetime of the object is managed by Lua. The object is constructed inside the userdata using an
 * already constructed object provided externally, and it is destructed by a deallocator function provided.
 */
template <class T>
class UserdataValueExternal : public Userdata
{
public:
    UserdataValueExternal(const UserdataValueExternal&) = delete;
    UserdataValueExternal operator=(const UserdataValueExternal&) = delete;

    ~UserdataValueExternal()
    {
        if (getObject() != nullptr)
            m_dealloc(getObject());
    }

    /**
     * @brief Push a T via externally allocated object.
     *
     * @param L A Lua state.
     * @param obj The object allocated externally that need to be stored.
     * @param dealloc A deallocator function that will free the passed object.
     *
     * @return An object referring to the newly created userdata value.
     */
    template <class Dealloc>
    static UserdataValueExternal<T>* place(lua_State* L, T* obj, Dealloc dealloc, std::error_code& ec)
    {
        auto* ud = new (lua_newuserdata_x<UserdataValueExternal<T>>(L, sizeof(UserdataValueExternal<T>))) UserdataValueExternal<T>(obj, dealloc);

        lua_rawgetp(L, LUA_REGISTRYINDEX, detail::getClassRegistryKey<T>());

        if (!lua_istable(L, -1))
        {
            lua_pop(L, 1); // possibly: a nil

            ud->~UserdataValueExternal<T>();

#if LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE
            ec = throw_or_error_code<LuaException>(L, ErrorCode::ClassNotRegistered);
#else
            ec = makeErrorCode(ErrorCode::ClassNotRegistered);
#endif

            return nullptr;
        }

        lua_setmetatable(L, -2);

        return ud;
    }

    T* getObject() noexcept
    {
        return static_cast<T*>(m_p);
    }

private:
    UserdataValueExternal(void* ptr, void (*dealloc)(T*)) noexcept
    {
        // Can't construct with a null object!
        LUABRIDGE_ASSERT(ptr != nullptr);
        m_p = ptr;

        // Can't construct with a null deallocator!
        LUABRIDGE_ASSERT(dealloc != nullptr);
        m_dealloc = dealloc;
    }

    void (*m_dealloc)(T*) = nullptr;
};

//============================================================================
/**
 * @brief Wraps a container that references a class object.
 *
 * The template argument C is the container type, ContainerTraits must be specialized on C or else a compile error will result.
 */
template <class C>
class UserdataShared : public Userdata
{
public:
    UserdataShared(const UserdataShared&) = delete;
    UserdataShared& operator=(const UserdataShared&) = delete;

    ~UserdataShared() = default;

    /**
     * @brief Construct from a container to the class or a derived class.
     *
     * @tparam U A container type.
     *
     * @param  u A container object reference.
     */
    template <class U>
    explicit UserdataShared(const U& u) : m_c(u)
    {
        m_p = const_cast<void*>(reinterpret_cast<const void*>((ContainerTraits<C>::get(m_c))));
    }

    /**
     * @brief Construct from a pointer to the class or a derived class.
     *
     * @tparam U A container type.
     *
     * @param u A container object pointer.
     */
    template <class U>
    explicit UserdataShared(U* u) : m_c(u)
    {
        m_p = const_cast<void*>(reinterpret_cast<const void*>((ContainerTraits<C>::get(m_c))));
    }

private:
    C m_c;
};

//=================================================================================================
/**
 * @brief SFINAE helper for non-const objects.
 */
template <class C, bool MakeObjectConst>
struct UserdataSharedHelper
{
    using T = std::remove_const_t<typename ContainerTraits<C>::Type>;

    static Result push(lua_State* L, const C& c)
    {
        if (ContainerTraits<C>::get(c) != nullptr)
        {
            auto* us = new (lua_newuserdata_x<UserdataShared<C>>(L, sizeof(UserdataShared<C>))) UserdataShared<C>(c);

            lua_rawgetp(L, LUA_REGISTRYINDEX, getClassRegistryKey<T>());

            if (!lua_istable(L, -1))
            {
                lua_pop(L, 1); // possibly: a nil

                us->~UserdataShared<C>();

#if LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE
                return throw_or_error_code<LuaException>(L, ErrorCode::ClassNotRegistered);
#else
                return makeErrorCode(ErrorCode::ClassNotRegistered);
#endif
            }

            lua_setmetatable(L, -2);
        }
        else
        {
            lua_pushnil(L);
        }

        return {};
    }

    static Result push(lua_State* L, T* t)
    {
        if (t)
        {
            auto* us = new (lua_newuserdata_x<UserdataShared<C>>(L, sizeof(UserdataShared<C>))) UserdataShared<C>(t);

            lua_rawgetp(L, LUA_REGISTRYINDEX, getClassRegistryKey<T>());

            if (!lua_istable(L, -1))
            {
                lua_pop(L, 1); // possibly: a nil

                us->~UserdataShared<C>();

#if LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE
                return throw_or_error_code<LuaException>(L, ErrorCode::ClassNotRegistered);
#else
                return makeErrorCode(ErrorCode::ClassNotRegistered);
#endif
            }

            lua_setmetatable(L, -2);
        }
        else
        {
            lua_pushnil(L);
        }

        return {};
    }
};

/**
 * @brief SFINAE helper for const objects.
 */
template <class C>
struct UserdataSharedHelper<C, true>
{
    using T = std::remove_const_t<typename ContainerTraits<C>::Type>;

    static Result push(lua_State* L, const C& c)
    {
        if (ContainerTraits<C>::get(c) != nullptr)
        {
            auto* us = new (lua_newuserdata_x<UserdataShared<C>>(L, sizeof(UserdataShared<C>))) UserdataShared<C>(c);

            lua_rawgetp(L, LUA_REGISTRYINDEX, getConstRegistryKey<T>());

            if (!lua_istable(L, -1))
            {
                lua_pop(L, 1); // possibly: a nil

                us->~UserdataShared<C>();

#if LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE
                return throw_or_error_code<LuaException>(L, ErrorCode::ClassNotRegistered);
#else
                return makeErrorCode(ErrorCode::ClassNotRegistered);
#endif
            }

            lua_setmetatable(L, -2);
        }
        else
        {
            lua_pushnil(L);
        }

        return {};
    }

    static Result push(lua_State* L, T* t)
    {
        if (t)
        {
            auto* us = new (lua_newuserdata_x<UserdataShared<C>>(L, sizeof(UserdataShared<C>))) UserdataShared<C>(t);

            lua_rawgetp(L, LUA_REGISTRYINDEX, getConstRegistryKey<T>());

            if (!lua_istable(L, -1))
            {
                lua_pop(L, 1); // possibly: a nil

                us->~UserdataShared<C>();

#if LUABRIDGE_RAISE_UNREGISTERED_CLASS_USAGE
                return throw_or_error_code<LuaException>(L, ErrorCode::ClassNotRegistered);
#else
                return makeErrorCode(ErrorCode::ClassNotRegistered);
#endif
            }

            lua_setmetatable(L, -2);
        }
        else
        {
            lua_pushnil(L);
        }

        return {};
    }
};

//=================================================================================================
/**
 * @brief Pass by container.
 *
 * The container controls the object lifetime. Typically this will be a lifetime shared by C++ and Lua using a reference count. Because of type
 * erasure, containers like std::shared_ptr will not work, unless the type hold by them is derived from std::enable_shared_from_this.
 */
template <class T, bool ByContainer>
struct StackHelper
{
    using ReturnType = TypeResult<T>;

    static Result push(lua_State* L, const T& t)
    {
        return UserdataSharedHelper<T, std::is_const_v<typename ContainerTraits<T>::Type>>::push(L, t);
    }

    static ReturnType get(lua_State* L, int index)
    {
        using CastType = std::remove_const_t<typename ContainerTraits<T>::Type>;

        auto* result = Userdata::get<CastType>(L, index, true);
        if (! result)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        return ContainerTraits<T>::construct(result);
    }
};

/**
 * @brief Pass by value.
 *
 * Lifetime is managed by Lua. A C++ function which accesses a pointer or reference to an object outside the activation record in which it was
 * retrieved may result in undefined behavior if Lua garbage collected it.
 */
template <class T>
struct StackHelper<T, false>
{
    static Result push(lua_State* L, const T& t)
    {
        return UserdataValue<T>::push(L, t);
    }

    static Result push(lua_State* L, T&& t)
    {
        return UserdataValue<T>::push(L, std::move(t));
    }

    static TypeResult<std::reference_wrapper<const T>> get(lua_State* L, int index)
    {
        auto* result = Userdata::get<T>(L, index, true);
        if (! result)
            return makeErrorCode(ErrorCode::InvalidTypeCast); // nil passed to reference

        return std::cref(*result);
    }
};

//=================================================================================================
/**
 * @brief Lua stack conversions for pointers and references to class objects.
 *
 * Lifetime is managed by C++. Lua code which remembers a reference to the value may result in undefined behavior if C++ destroys the object.
 * The handling of the const and volatile qualifiers happens in UserdataPtr.
 */
template <class C, bool ByContainer>
struct RefStackHelper
{
    using ReturnType = TypeResult<C>;
    using T = std::remove_const_t<typename ContainerTraits<C>::Type>;

    static Result push(lua_State* L, const C& t)
    {
        return UserdataSharedHelper<C, std::is_const_v<typename ContainerTraits<C>::Type>>::push(L, t);
    }

    static ReturnType get(lua_State* L, int index)
    {
        auto* result = Userdata::get<T>(L, index, true);
        if (! result)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        return ContainerTraits<C>::construct(result);
    }
};

template <class T>
struct RefStackHelper<T, false>
{
    using ReturnType = TypeResult<std::reference_wrapper<T>>;

    static Result push(lua_State* L, T& t)
    {
        return UserdataPtr::push(L, std::addressof(t));
    }

    static Result push(lua_State* L, const T& t)
    {
        return UserdataPtr::push(L, std::addressof(t));
    }

    static ReturnType get(lua_State* L, int index)
    {
        auto* result = Userdata::get<T>(L, index, true);
        if (! result)
            return makeErrorCode(ErrorCode::InvalidTypeCast); // nil passed to reference

        return std::ref(*result);
    }
};

//=================================================================================================
/**
 * @brief Trait class that selects whether to return a user registered class object by value or by reference.
 */
template <class T, class Enable = void>
struct UserdataGetter
{
    using ReturnType = TypeResult<T*>;

    static ReturnType get(lua_State* L, int index)
    {
        auto* result = Userdata::get<T>(L, index, true);
        if (! result)
            return makeErrorCode(ErrorCode::InvalidTypeCast);

        return result;
    }
};

template <class T>
struct UserdataGetter<T, std::void_t<T (*)()>>
{
    using ReturnType = TypeResult<T>;

    static ReturnType get(lua_State* L, int index)
    {
        auto result = StackHelper<T, IsContainer<T>::value>::get(L, index);
        if (! result)
            return result.error();

        return *result;
    }
};

} // namespace detail

//=================================================================================================
/**
 * @brief Lua stack conversions for class objects passed by value.
 */
template <class T, class = void>
struct Stack
{
    using IsUserdata = void;

    using Getter = detail::UserdataGetter<T>;
    using ReturnType = typename Getter::ReturnType;

    [[nodiscard]] static Result push(lua_State* L, const T& value)
    {
        return detail::StackHelper<T, detail::IsContainer<T>::value>::push(L, value);
    }

    [[nodiscard]] static Result push(lua_State* L, T&& value)
    {
        return detail::StackHelper<T, detail::IsContainer<T>::value>::push(L, std::move(value));
    }

    [[nodiscard]] static ReturnType get(lua_State* L, int index)
    {
        return Getter::get(L, index);
    }

    [[nodiscard]] static bool isInstance(lua_State* L, int index)
    {
        return detail::Userdata::isInstance<T>(L, index);
    }
};

namespace detail {

//=================================================================================================
/**
 * @brief Trait class indicating whether the parameter type must be a user registered class.
 *
 * The trait checks the existence of member type Stack::IsUserdata specialization for detection.
 */
template <class T, class Enable = void>
struct IsUserdata : std::false_type
{
};

template <class T>
struct IsUserdata<T, std::void_t<typename Stack<T>::IsUserdata>> : std::true_type
{
};

//=================================================================================================
/**
 * @brief Trait class that selects a specific push/get implementation for userdata.
 */
template <class T, bool IsUserdata>
struct StackOpSelector;

// pointer
template <class T>
struct StackOpSelector<T*, true>
{
    using ReturnType = TypeResult<T*>;

    static Result push(lua_State* L, T* value) { return UserdataPtr::push(L, value); }

    static ReturnType get(lua_State* L, int index) { return Userdata::get<T>(L, index, false); }

    template <class U = T>
    static bool isInstance(lua_State* L, int index) { return Userdata::isInstance<U>(L, index); }
};

// pointer to const
template <class T>
struct StackOpSelector<const T*, true>
{
    using ReturnType = TypeResult<const T*>;

    static Result push(lua_State* L, const T* value) { return UserdataPtr::push(L, value); }

    static ReturnType get(lua_State* L, int index) { return Userdata::get<T>(L, index, true); }

    template <class U = T>
    static bool isInstance(lua_State* L, int index) { return Userdata::isInstance<U>(L, index); }
};

// l-value reference
template <class T>
struct StackOpSelector<T&, true>
{
    using Helper = RefStackHelper<T, IsContainer<T>::value>;
    using ReturnType = typename Helper::ReturnType;

    static Result push(lua_State* L, T& value) { return Helper::push(L, value); }

    static ReturnType get(lua_State* L, int index) { return Helper::get(L, index); }

    template <class U = T>
    static bool isInstance(lua_State* L, int index) { return Userdata::isInstance<U>(L, index); }
};

// l-value reference to const
template <class T>
struct StackOpSelector<const T&, true>
{
    using Helper = RefStackHelper<T, IsContainer<T>::value>;
    using ReturnType = typename Helper::ReturnType;

    static Result push(lua_State* L, const T& value) { return Helper::push(L, value); }

    static ReturnType get(lua_State* L, int index) { return Helper::get(L, index); }

    template <class U = T>
    static bool isInstance(lua_State* L, int index) { return Userdata::isInstance<U>(L, index); }
};

} // namespace detail
} // namespace luabridge

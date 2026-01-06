# 引入外部函数
include(${ROOT_DIR}/cmake/module.cmake)

# 文件收集
set(HEADER_FILES "")
set(SOURCE_FILES "")
set(LUA_FILES "")
set(RESOURCE_FILES "")

set(CURRENT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
file(GLOB_RECURSE HEADER_FILES "${CURRENT_PATH}/*.h" "${CURRENT_PATH}/*.hpp")
file(GLOB_RECURSE SOURCE_FILES "${CURRENT_PATH}/*.c" "${CURRENT_PATH}/*.cpp")
file(GLOB_RECURSE LUA_FILES "${CURRENT_PATH}/*.lua")

# 三方库
file(GLOB_RECURSE IMGUI_HEADER_FILES "${ROOT_DIR}/${THIRDPARTY_FOLDER}/ImGUI/*.h" "${ROOT_DIR}/${THIRDPARTY_FOLDER}/ImGUI/*.hpp")
file(GLOB_RECURSE IMGUI_SOURCE_FILES "${ROOT_DIR}/${THIRDPARTY_FOLDER}/ImGUI/*.c" "${ROOT_DIR}/${THIRDPARTY_FOLDER}/ImGUI/*.cpp")
list(APPEND HEADER_FILES
    "${ROOT_DIR}/${THIRDPARTY_FOLDER}/cJSON/include/cJSON.h"
    "${ROOT_DIR}/${THIRDPARTY_FOLDER}/cpp-base64/include/base64.h"
    "${ROOT_DIR}/${THIRDPARTY_FOLDER}/MicroPather/include/micropather.h"
    "${IMGUI_HEADER_FILES}"
)
list(APPEND SOURCE_FILES
    "${ROOT_DIR}/${THIRDPARTY_FOLDER}/cJSON/src/cJSON.c"
    "${ROOT_DIR}/${THIRDPARTY_FOLDER}/cpp-base64/base64.cpp"
    "${ROOT_DIR}/${THIRDPARTY_FOLDER}/MicroPather/src/micropather.cpp"
    "${IMGUI_SOURCE_FILES}"
)
list(APPEND RESOURCE_FILES
    "${CURRENT_PATH}/imgui.ini"
    "${CURRENT_PATH}/RaycastEngine.rc"
)

# 文件分类
if(CMAKE_CXX_PLATFORM_ID MATCHES "Windows")
    source_group(TREE ${ROOT_DIR} PREFIX "Header Files" FILES ${HEADER_FILES})
    source_group(TREE ${ROOT_DIR} PREFIX "Source Files" FILES ${SOURCE_FILES})
    source_group(TREE ${ROOT_DIR} PREFIX "Lua Files" FILES ${LUA_FILES})
    source_group(TREE ${ROOT_DIR} PREFIX "Resource Files" FILES ${RESOURCE_FILES})
else()
endif()

# 添加依赖，LuaBridge 仅头文件
set(LibraryList "cJSON" "cpp-base64" "ImGUI" "Lua" "LuaBridge" "MicroPather" "Raylib" "SDL2")
AddLibrary("${LibraryList}")

# 创建项目
set(ProjectName "RaycastEngine")
add_executable(${ProjectName}
    ${HEADER_FILES} ${SOURCE_FILES}
    ${LUA_FILES} ${RESOURCE_FILES}
)

# 链接库
if(CMAKE_CXX_COMPILER_ID MATCHES "MSVC")
    target_compile_definitions(${ProjectName} PRIVATE
        UNICODE
        _UNICODE
    )
    set_target_properties(${ProjectName} PROPERTIES
        DEBUG_POSTFIX "d"
        VS_DEBUGGER_WORKING_DIRECTORY "$(OutDir)"
        MSVC_RUNTIME_LIBRARY "MultiThreaded"
    )
    # TODO: 如果安装 vcpkg 请在配置属性 vcpkg 通用关闭 Use Vcpkg，否则会优先链接 vcpkg 中的库
    target_link_libraries(${ProjectName} "lua")
    target_link_libraries(${ProjectName} "glfw3" "raylib")
    target_link_libraries(${ProjectName}
        "brotlicommon.lib"
        "brotlidec.lib"
        "bz2.lib"
        "FLAC.lib"
        "FLAC++.lib"
        "freetype.lib"
        "gio-2.0.lib"
        "girepository-2.0.lib"
        "glib-2.0.lib"
        "gmodule-2.0.lib"
        "gobject-2.0.lib"
        "gthread-2.0.lib"
        "iconv.lib"
        "intl.lib"
        "libfluidsynth-3.lib"
        "libpng16.lib"
        "libwavpack.lib"
        "libxmp-static.lib"
        "modplug.lib"
        "mpg123.lib"
        "ogg.lib"
        "opus.lib"
        "opusfile.lib"
        "out123.lib"
        "SDL2_gfx.lib"
        "SDL2_image-static.lib"
        "SDL2_mixer-static.lib"
        "SDL2_net-static.lib"
        "SDL2_ttf.lib"
        "SDL2-static.lib"
        "syn123.lib"
        "vorbis.lib"
        "vorbisenc.lib"
        "vorbisfile.lib"
        "zlib.lib"
    )
    target_link_libraries(${ProjectName}
        "setupapi.lib"
        "version.lib"
        "shlwapi.lib"
        "iphlpapi.lib"
        "ksuser.lib"
        "dwmapi.lib"
        # 多媒体库（raylib需要）
        winmm.lib
        dsound.lib
        imm32.lib
        msimg32.lib
        ws2_32.lib
    )
else()
endif()

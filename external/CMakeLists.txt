set(EXTERNAL_FOLDER "external")

####################################################################################################
# raylib
####################################################################################################
set(USE_MSVC_RUNTIME_LIBRARY_DLL OFF)
add_subdirectory(raylib)
if(CMAKE_CXX_COMPILER_ID MATCHES "MSVC")
    set_target_properties("raylib" PROPERTIES
        MSVC_RUNTIME_LIBRARY "MultiThreaded"
    )
endif()
set_property(TARGET "raylib" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")
set_property(TARGET "glfw" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")
set_property(TARGET "uninstall" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")
set_property(TARGET "update_mappings" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")

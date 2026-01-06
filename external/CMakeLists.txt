set(EXTERNAL_FOLDER "external")

####################################################################################################
# raylib
####################################################################################################
add_subdirectory(raylib)
if(CMAKE_CXX_COMPILER_ID MATCHES "MSVC")
    set_target_properties("raylib" PROPERTIES
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    )
endif()
set_property(TARGET "raylib" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")
set_property(TARGET "glfw" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")
set_property(TARGET "uninstall" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")
set_property(TARGET "update_mappings" PROPERTY FOLDER "${EXTERNAL_FOLDER}/raylib")

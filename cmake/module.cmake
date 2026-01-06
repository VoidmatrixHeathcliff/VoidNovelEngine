set(THIRDPARTY_FOLDER "Thirdparty")

# 添加头文件和链接库路径
macro(AddLibrary LibraryList)
    foreach(library ${LibraryList})
        # 添加 include
        include_directories(${ROOT_DIR}/${THIRDPARTY_FOLDER}/${library}/include)
        # 添加链接库路径
        if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
            link_directories(${ROOT_DIR}/${THIRDPARTY_FOLDER}/${library}/x64)
        endif()
    endforeach()
endmacro()

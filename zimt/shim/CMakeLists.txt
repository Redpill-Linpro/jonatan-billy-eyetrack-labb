# Builds the shim as one shared library with OpenCV linked in statically.
# Run by the Makefile, which builds OpenCV first and passes its build
# directory (relative to the zimt directory) as OPENCV_BUILD.
cmake_minimum_required(VERSION 3.16)
project(zimt_cv CXX)

get_filename_component(OpenCV_DIR "${OPENCV_BUILD}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")
find_package(OpenCV REQUIRED COMPONENTS core imgproc videoio NO_DEFAULT_PATH)

add_library(zimt_cv SHARED zimt_cv.cpp)
set_target_properties(zimt_cv PROPERTIES
    PREFIX lib
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
target_include_directories(zimt_cv PRIVATE ${OpenCV_INCLUDE_DIRS})
target_link_libraries(zimt_cv PRIVATE opencv_core opencv_imgproc opencv_videoio)

if(MINGW)
    # Link the GCC and MinGW runtimes in too, so the DLL needs only Windows.
    target_link_options(zimt_cv PRIVATE -static)
elseif(NOT APPLE)
    # Export the shim's own functions only, not OpenCV's, and drop what they do not reach.
    target_link_options(zimt_cv PRIVATE "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/zimt_cv.map" -Wl,--gc-sections -s)
    set_property(TARGET zimt_cv APPEND PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/zimt_cv.map")
endif()

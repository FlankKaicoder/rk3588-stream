cmake_minimum_required(VERSION 3.10)

project(rk3588_ai_stream)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(TARGET_SOC "rk3588" CACHE STRING "Target SoC")

set(LUBANCAT_YOLO11_CPP
    "$ENV{HOME}/lubancat_ai_manual_code/example/yolo11/cpp"
    CACHE PATH "Path to LubanCat YOLO11 cpp demo")

set(LUBANCAT_EXAMPLE_DIR "${LUBANCAT_YOLO11_CPP}/../..")

message(STATUS "LUBANCAT_YOLO11_CPP = ${LUBANCAT_YOLO11_CPP}")
message(STATUS "LUBANCAT_EXAMPLE_DIR = ${LUBANCAT_EXAMPLE_DIR}")

find_package(OpenCV REQUIRED)

include_directories(${LUBANCAT_EXAMPLE_DIR}/3rdparty/allocator/dma)

add_subdirectory(${LUBANCAT_EXAMPLE_DIR}/3rdparty 3rdparty.out)
add_subdirectory(${LUBANCAT_EXAMPLE_DIR}/utils utils.out)

set(RKNPU_YOLO11_SRC "${LUBANCAT_YOLO11_CPP}/rknpu2/yolo11.cc")

add_executable(image_detect
    src/main_image.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(image_detect PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(image_detect
    imageutils
    fileutils
    imagedrawing
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(image_detect PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)

add_executable(video_detect
    src/main_video.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(video_detect PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(video_detect
    imageutils
    fileutils
    ${OpenCV_LIBS}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(video_detect PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)

add_executable(camera_detect
    src/main_camera.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(camera_detect PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(camera_detect
    imageutils
    fileutils
    ${OpenCV_LIBS}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(camera_detect PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)

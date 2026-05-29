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

# 04 camera_profile: 摄像头检测性能剖析版本
add_executable(camera_profile
    src/main_camera_profile.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(camera_profile PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(camera_profile
    imageutils
    fileutils
    ${OpenCV_LIBS}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(camera_profile PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib;$ORIGIN/./lib"
)

# 04-1 camera_profile_nowrite: 不写视频，只统计检测主链路耗时
add_executable(camera_profile_nowrite
    src/main_camera_profile_nowrite.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(camera_profile_nowrite PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(camera_profile_nowrite
    imageutils
    fileutils
    ${OpenCV_LIBS}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(camera_profile_nowrite PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib;$ORIGIN/./lib"
)

# 04-2 camera_capture_profile: 只测试摄像头 cap.read 速度
add_executable(camera_capture_profile
    src/main_camera_capture_profile.cpp
)

target_link_libraries(camera_capture_profile
    ${OpenCV_LIBS}
    pthread
)

# 04-3 camera_profile_setcap: 设置摄像头直接输出 1280x720，跳过 OpenCV resize
add_executable(camera_profile_setcap
    src/main_camera_profile_setcap.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(camera_profile_setcap PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(camera_profile_setcap
    imageutils
    fileutils
    ${OpenCV_LIBS}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(camera_profile_setcap PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib;$ORIGIN/./lib"
)

# 04-3-nowrite: 设置摄像头 1280x720，不写视频，只统计检测主链路
add_executable(camera_profile_setcap_nowrite
    src/main_camera_profile_setcap_nowrite.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(camera_profile_setcap_nowrite PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(camera_profile_setcap_nowrite
    imageutils
    fileutils
    ${OpenCV_LIBS}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(camera_profile_setcap_nowrite PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib;$ORIGIN/./lib"
)

# 04-4 v4l2_capture_profile: V4L2 mmap 原生采集性能测试
add_executable(v4l2_capture_profile
    src/main_v4l2_capture_profile.cpp
)

target_link_libraries(v4l2_capture_profile
    pthread
)

# 06-1 rga_nv12_to_rgb: 使用 image_utils/RGA 将 NV12 文件转换为 RGB/JPG
add_executable(rga_nv12_to_rgb
    src/main_rga_nv12_to_rgb.cpp
)

target_include_directories(rga_nv12_to_rgb PRIVATE
    ${LUBANCAT_EXAMPLE_DIR}/utils
    ${LUBANCAT_EXAMPLE_DIR}/utils/image_utils
    ${LUBANCAT_EXAMPLE_DIR}/3rdparty/rga/include
)

target_compile_options(rga_nv12_to_rgb PRIVATE
    -pthread
)

target_link_options(rga_nv12_to_rgb PRIVATE
    -pthread
)

target_link_libraries(rga_nv12_to_rgb
    imageutils
    fileutils
    ${OpenCV_LIBS}
    dl
    pthread
)
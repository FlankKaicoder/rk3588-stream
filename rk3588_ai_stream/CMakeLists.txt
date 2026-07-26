cmake_minimum_required(VERSION 3.10)

project(rk3588_ai_stream)

set(CMAKE_CXX_STANDARD 17)
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
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_common_utils utils.out)

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
# ===== 05 / 06 V4L2 + RGA + RKNN experiments =====

find_path(RGA_INCLUDE_DIR
    NAMES im2d.hpp
    PATHS
        /usr/include/rga
        /usr/local/include/rga
        /usr/include
        /usr/local/include
)

find_library(RGA_LIBRARY
    NAMES rga
    PATHS
        /usr/lib
        /usr/lib/aarch64-linux-gnu
        /usr/local/lib
)

if(NOT RGA_LIBRARY)
    set(RGA_LIBRARY rga)
endif()

message(STATUS "RGA_INCLUDE_DIR = ${RGA_INCLUDE_DIR}")
message(STATUS "RGA_LIBRARY     = ${RGA_LIBRARY}")

add_executable(v4l2_rga_realtime_preprocess
    src/main_v4l2_rga_realtime_preprocess.cpp
)

target_include_directories(v4l2_rga_realtime_preprocess PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${RGA_INCLUDE_DIR}
)

target_link_libraries(v4l2_rga_realtime_preprocess
    ${RGA_LIBRARY}
    pthread
)

add_executable(v4l2_rga_rknn_detect
    src/main_v4l2_rga_rknn_detect.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(v4l2_rga_rknn_detect PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${RGA_INCLUDE_DIR}
)

target_link_libraries(v4l2_rga_rknn_detect
    imageutils
    fileutils
    imagedrawing
    ${RGA_LIBRARY}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(v4l2_rga_realtime_preprocess PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)

target_compile_options(v4l2_rga_rknn_detect PRIVATE
    -O3
    -DNDEBUG
)

set_target_properties(v4l2_rga_rknn_detect PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)

# ===== 07 profile inference_yolo11_model internal stages =====

add_executable(v4l2_rga_rknn_detect_profile
    src/main_v4l2_rga_rknn_detect.cpp
    src/postprocess_profile.cc
    src/yolo11_profile.cc
)

target_include_directories(v4l2_rga_rknn_detect_profile PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${RGA_INCLUDE_DIR}
)

target_link_libraries(v4l2_rga_rknn_detect_profile
    imageutils
    fileutils
    imagedrawing
    ${RGA_LIBRARY}
    ${LIBRKNNRT}
    dl
    pthread
)

target_compile_options(v4l2_rga_rknn_detect_profile PRIVATE
    -O3
    -DNDEBUG
)

set_target_properties(v4l2_rga_rknn_detect_profile PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)

# 08-1: dump V4L2 NV12 frames for MPP encoder test
add_executable(v4l2_dump_nv12
    src/main_v4l2_dump_nv12.cpp
)

target_compile_options(v4l2_dump_nv12 PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(v4l2_dump_nv12
    pthread
)

# 08-3: V4L2 + RGA + RKNN detect + RGB back to NV12 for MPP encoder
find_package(PkgConfig REQUIRED)

if(NOT TARGET PkgConfig::LIBRGA)
    pkg_check_modules(LIBRGA REQUIRED IMPORTED_TARGET librga)
endif()

add_executable(v4l2_rga_rknn_detect_to_nv12
    src/main_v4l2_rga_rknn_detect_to_nv12.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(v4l2_rga_rknn_detect_to_nv12 PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${OpenCV_INCLUDE_DIRS}
)

target_compile_options(v4l2_rga_rknn_detect_to_nv12 PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(v4l2_rga_rknn_detect_to_nv12
    imageutils
    fileutils
    ${OpenCV_LIBS}
    PkgConfig::LIBRGA
    ${LIBRKNNRT}
    dl
    pthread
)

# 08-4: clean profile version, no debug jpg and no per-frame fflush
add_executable(v4l2_rga_rknn_detect_to_nv12_clean
    src/main_v4l2_rga_rknn_detect_to_nv12_clean.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(v4l2_rga_rknn_detect_to_nv12_clean PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${OpenCV_INCLUDE_DIRS}
)

target_compile_options(v4l2_rga_rknn_detect_to_nv12_clean PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(v4l2_rga_rknn_detect_to_nv12_clean
    imageutils
    fileutils
    ${OpenCV_LIBS}
    PkgConfig::LIBRGA
    ${LIBRKNNRT}
    dl
    pthread
)


# ================= EXP21_MPP_FILE_ENCODE_BEGIN =================

# EXP21：使用 /home/cat/mpp 源码树中的头文件，避免系统 MPP 头文件与源码内部头文件混用。
set(EXP21_MPP_ROOT /home/cat/mpp)

set(EXP21_MPP_INCLUDE_DIRS
    ${EXP21_MPP_ROOT}/inc
    ${EXP21_MPP_ROOT}/mpp/inc
    ${EXP21_MPP_ROOT}/kmpp/base/inc
    ${EXP21_MPP_ROOT}/osal/inc
)

set(EXP21_MPP_LIBRARY
    ${EXP21_MPP_ROOT}/build/mpp/librockchip_mpp.so
)

if(NOT EXISTS ${EXP21_MPP_LIBRARY})
    message(WARNING "EXP21_MPP_LIBRARY not found at ${EXP21_MPP_LIBRARY}, fallback to system rockchip_mpp")
    find_library(EXP21_MPP_LIBRARY
        NAMES rockchip_mpp
        PATHS
            /usr/local/lib
            /usr/lib/aarch64-linux-gnu
    )
endif()

message(STATUS "EXP21_MPP_ROOT         = ${EXP21_MPP_ROOT}")
message(STATUS "EXP21_MPP_INCLUDE_DIRS = ${EXP21_MPP_INCLUDE_DIRS}")
message(STATUS "EXP21_MPP_LIBRARY      = ${EXP21_MPP_LIBRARY}")

add_executable(exp21_mpp_file_encode
    src/main_exp21_mpp_file_encode.cpp
    src/mpp_h264_encoder.cpp
)

target_include_directories(exp21_mpp_file_encode PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${EXP21_MPP_INCLUDE_DIRS}
)

target_compile_options(exp21_mpp_file_encode PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(exp21_mpp_file_encode
    ${EXP21_MPP_LIBRARY}
    pthread
)

# ================= EXP21_MPP_FILE_ENCODE_END =================


# ================= EXP21_2_V4L2_MPP_ENCODE_BEGIN =================
add_executable(exp21_v4l2_mpp_encode
    src/main_exp21_v4l2_mpp_encode.cpp
    src/mpp_h264_encoder.cpp
)

target_include_directories(exp21_v4l2_mpp_encode PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${EXP21_MPP_INCLUDE_DIRS}
)

target_compile_options(exp21_v4l2_mpp_encode PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(exp21_v4l2_mpp_encode
    ${EXP21_MPP_LIBRARY}
    pthread
)
# ================= EXP21_2_V4L2_MPP_ENCODE_END =================


# ================= EXP21_3_DETECT_MPP_ENCODE_BEGIN =================
add_executable(exp21_detect_mpp_encode
    src/main_exp21_detect_mpp_encode.cpp
    src/mpp_h264_encoder.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    src/yolo11_clean_silent.cc
)

target_include_directories(exp21_detect_mpp_encode PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${RGA_INCLUDE_DIR}
    ${EXP21_MPP_INCLUDE_DIRS}
)

target_compile_options(exp21_detect_mpp_encode PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(exp21_detect_mpp_encode
    imageutils
    fileutils
    imagedrawing
    ${RGA_LIBRARY}
    ${LIBRKNNRT}
    ${OpenCV_LIBS}
    ${EXP21_MPP_LIBRARY}
    dl
    pthread
)

set_target_properties(exp21_detect_mpp_encode PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)

# ================= EXP21_3_DETECT_MPP_ENCODE_END =================

# ================= EXP21_4_ASYNC_DETECT_MPP_ENCODE_BEGIN =================
add_executable(exp21_detect_mpp_encode_async
    src/main_exp21_detect_mpp_encode_async.cpp
    src/mpp_h264_encoder.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    src/yolo11_clean_silent.cc
)

target_include_directories(exp21_detect_mpp_encode_async PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${RGA_INCLUDE_DIR}
    ${EXP21_MPP_INCLUDE_DIRS}
)

target_compile_options(exp21_detect_mpp_encode_async PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(exp21_detect_mpp_encode_async
    imageutils
    fileutils
    imagedrawing
    ${RGA_LIBRARY}
    ${LIBRKNNRT}
    ${OpenCV_LIBS}
    ${EXP21_MPP_LIBRARY}
    dl
    pthread
)

set_target_properties(exp21_detect_mpp_encode_async PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)
# ================= EXP21_4_ASYNC_DETECT_MPP_ENCODE_END =================

# ===== exp24: MP4 mux from H264 + PTS CSV =====
find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG24 REQUIRED libavformat libavcodec libavutil)

add_executable(exp24_mp4_mux_from_pts
    src/main_exp24_mp4_mux_from_pts.cpp
)

target_include_directories(exp24_mp4_mux_from_pts PRIVATE
    ${FFMPEG24_INCLUDE_DIRS}
)

target_compile_options(exp24_mp4_mux_from_pts PRIVATE
    -O3
    -DNDEBUG
    ${FFMPEG24_CFLAGS_OTHER}
)

target_link_libraries(exp24_mp4_mux_from_pts PRIVATE
    ${FFMPEG24_LIBRARIES}
)

target_compile_features(exp24_mp4_mux_from_pts PRIVATE cxx_std_17)


# ===== Experiment 26: AV sync timestamp probes =====
add_executable(exp26_v4l2_ts_probe
    src/main_exp26_v4l2_ts_probe.cpp
)
target_compile_options(exp26_v4l2_ts_probe PRIVATE -O3 -DNDEBUG)
target_link_libraries(exp26_v4l2_ts_probe pthread)

add_executable(exp26_alsa_ts_probe
    src/main_exp26_alsa_ts_probe.cpp
)
target_compile_options(exp26_alsa_ts_probe PRIVATE -O3 -DNDEBUG)
target_link_libraries(exp26_alsa_ts_probe asound pthread)
# ===== End Experiment 26 =====


# ===== Experiment 26-3: ALSA timestamped PCM capture =====
add_executable(exp26_alsa_pcm_capture_ts
    src/main_exp26_alsa_pcm_capture_ts.cpp
)
target_compile_options(exp26_alsa_pcm_capture_ts PRIVATE -O3 -DNDEBUG)
target_link_libraries(exp26_alsa_pcm_capture_ts asound pthread)
# ===== End Experiment 26-3 =====


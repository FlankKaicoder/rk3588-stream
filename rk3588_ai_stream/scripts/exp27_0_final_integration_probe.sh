#!/usr/bin/env bash

set -u

PROJECT_ROOT="$(pwd)"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="output/exp27_0_final_integration_probe_${STAMP}"

mkdir -p "$OUT_DIR"

echo "============================================================"
echo " Experiment 27-0: Final Integration Probe"
echo "============================================================"
echo "project : $PROJECT_ROOT"
echo "out_dir : $OUT_DIR"
echo

###############################################################################
# 1. 系统和工程状态
###############################################################################

{
    echo "========== time =========="
    date

    echo
    echo "========== system =========="
    uname -a
    cat /etc/os-release 2>/dev/null || true

    echo
    echo "========== project root =========="
    pwd

    echo
    echo "========== git status =========="
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git status --short
        echo
        git log -1 --oneline 2>/dev/null || true
    else
        echo "not a git repository"
    fi

    echo
    echo "========== cpu governors =========="
    cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor \
        2>/dev/null || true

    echo
    echo "========== cpu frequencies =========="
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [ -f "$f" ] || continue
        echo "$f: $(cat "$f")"
    done
} > "$OUT_DIR/environment.txt" 2>&1

###############################################################################
# 2. 搜索实验21~26相关代码
###############################################################################

find src include scripts \
    -maxdepth 3 \
    -type f \
    2>/dev/null \
    | sort \
    | grep -Ei \
      'exp2[1-6]|mpp|h264|v4l2|alsa|audio|aac|mp4|rtsp|timestamp|sync|mux' \
    > "$OUT_DIR/candidate_files.txt" || true

###############################################################################
# 3. 检查关键文件是否存在
###############################################################################

{
    check_file()
    {
        local path="$1"

        if [ -f "$path" ]; then
            printf "FOUND   %-70s %10s bytes\n" \
                "$path" \
                "$(stat -c '%s' "$path")"
        else
            printf "MISSING %s\n" "$path"
        fi
    }

    echo "========== expected core sources =========="

    check_file include/mpp_h264_encoder.hpp
    check_file src/mpp_h264_encoder.cpp
    check_file src/main_exp21_detect_mpp_encode_async.cpp
    check_file src/main_exp24_mp4_mux_from_pts.cpp
    check_file src/yolo11_clean_silent.cc

    echo
    echo "========== expected executables =========="

    check_file build/exp21_detect_mpp_encode_async
    check_file build/exp24_mp4_mux_from_pts

    echo
    echo "========== expected integration scripts =========="

    check_file scripts/exp22_av_async_mpp_rtsp.sh
    check_file scripts/exp25_2_sync_av_mp4_record.sh
    check_file scripts/exp26_3_av_mp4_v4l2_alsa_ts.sh
} > "$OUT_DIR/expected_files.txt" 2>&1

###############################################################################
# 4. 提取关键源码符号
###############################################################################

SOURCE_FILES=()

while IFS= read -r file; do
    [ -f "$file" ] || continue
    SOURCE_FILES+=("$file")
done < "$OUT_DIR/candidate_files.txt"

{
    echo "========== encoder and queue structures =========="

    grep -nEH \
      'class MppH264Encoder|struct Exp21EncFrame|EncodedVideoPacket|std::queue|condition_variable|encoder_thread|async_' \
      "${SOURCE_FILES[@]}" 2>/dev/null || true

    echo
    echo "========== video timestamp logic =========="

    grep -nEH \
      'buffer\.timestamp|v4l2.*timestamp|sync_pts|pts_us|set_next_pts_us|mpp_frame_set_pts|mpp_packet_get_pts|packet_dts|sync_meta' \
      "${SOURCE_FILES[@]}" 2>/dev/null || true

    echo
    echo "========== audio timestamp logic =========="

    grep -nEH \
      'snd_pcm|htimestamp|audio_stream_start|sample_counter|total_frames|audio_ts|audio_trim|atrim|asetpts' \
      "${SOURCE_FILES[@]}" 2>/dev/null || true

    echo
    echo "========== mux and stream logic =========="

    grep -nEH \
      'avformat|av_interleaved_write_frame|AVPacket|ffmpeg|mediamtx|rtsp://|movflags|c:v copy|c:a copy|FIFO|fifo' \
      "${SOURCE_FILES[@]}" 2>/dev/null || true
} > "$OUT_DIR/key_symbols.txt" 2>&1

###############################################################################
# 5. CMake target 审计
###############################################################################

{
    echo "========== CMakeLists target definitions =========="

    grep -nE \
      'add_executable|add_library|target_link_libraries|target_include_directories|CMAKE_BUILD_TYPE|CMAKE_CXX_STANDARD' \
      CMakeLists.txt 2>/dev/null || true

    echo
    echo "========== generated build targets =========="

    if [ -d build ]; then
        cmake --build build --target help 2>/dev/null \
            | grep -Ei \
              'exp2[1-7]|mpp|mp4|rtsp|v4l2|alsa|audio|detect' \
            || true
    else
        echo "build directory does not exist"
    fi
} > "$OUT_DIR/cmake_targets.txt" 2>&1

###############################################################################
# 6. 二进制参数和动态依赖
###############################################################################

{
    for bin in \
        build/exp21_detect_mpp_encode_async \
        build/exp24_mp4_mux_from_pts
    do
        echo
        echo "============================================================"
        echo "$bin"
        echo "============================================================"

        if [ ! -x "$bin" ]; then
            echo "missing or not executable"
            continue
        fi

        ls -lh "$bin"

        echo
        echo "---------- usage ----------"
        timeout 3 "$bin" 2>&1 || true

        echo
        echo "---------- ldd ----------"
        ldd "$bin" 2>&1 || true
    done
} > "$OUT_DIR/binaries.txt" 2>&1

###############################################################################
# 7. 关键脚本实际流程
###############################################################################

{
    for script in \
        scripts/exp22_av_async_mpp_rtsp.sh \
        scripts/exp25_2_sync_av_mp4_record.sh \
        scripts/exp26_3_av_mp4_v4l2_alsa_ts.sh
    do
        echo
        echo "============================================================"
        echo "$script"
        echo "============================================================"

        if [ ! -f "$script" ]; then
            echo "missing"
            continue
        fi

        grep -nE \
          '^[A-Z_]+=|ffmpeg|mediamtx|exp21_detect|exp24_mp4|audio|alsa|pcm|pts|timestamp|sync|trim|atrim|fifo|wait|cleanup' \
          "$script" 2>/dev/null || true
    done
} > "$OUT_DIR/script_flows.txt" 2>&1

###############################################################################
# 8. 文件哈希，后续判断是否误改旧版本
###############################################################################

if [ "${#SOURCE_FILES[@]}" -gt 0 ]; then
    sha256sum "${SOURCE_FILES[@]}" \
        > "$OUT_DIR/source_hashes.sha256" 2>/dev/null || true
else
    : > "$OUT_DIR/source_hashes.sha256"
fi

###############################################################################
# 9. 设备只读探测，不启动正式采集
###############################################################################

{
    echo "========== video device =========="

    timeout 5 v4l2-ctl \
        -d /dev/video11 \
        --get-fmt-video \
        2>&1 || true

    echo
    echo "========== video all key =========="

    timeout 5 v4l2-ctl \
        -d /dev/video11 \
        --all \
        2>&1 \
        | grep -E \
          'Driver name|Card type|Width/Height|Pixel Format|Bytes per Line|Size Image|Capabilities' \
        || true

    echo
    echo "========== audio cards =========="

    timeout 5 arecord -l 2>&1 || true

    echo
    echo "========== alsa pcm =========="

    cat /proc/asound/pcm 2>/dev/null || true
} > "$OUT_DIR/device_probe.txt" 2>&1

###############################################################################
# 10. 简洁汇总
###############################################################################

CANDIDATE_COUNT="$(wc -l < "$OUT_DIR/candidate_files.txt" 2>/dev/null || echo 0)"
MISSING_COUNT="$(grep -c '^MISSING' "$OUT_DIR/expected_files.txt" 2>/dev/null || true)"
TARGET_COUNT="$(grep -cE 'exp2[1-7]|mpp|mp4|rtsp|v4l2|alsa|audio|detect' \
    "$OUT_DIR/cmake_targets.txt" 2>/dev/null || true)"

{
    echo "========== Experiment 27-0 Summary =========="
    echo "project_root      : $PROJECT_ROOT"
    echo "out_dir           : $OUT_DIR"
    echo "candidate_files   : $CANDIDATE_COUNT"
    echo "missing_expected  : $MISSING_COUNT"
    echo "target_lines      : $TARGET_COUNT"

    echo
    echo "========== expected files =========="
    cat "$OUT_DIR/expected_files.txt"

    echo
    echo "========== next decision =========="

    if [ "$MISSING_COUNT" -eq 0 ]; then
        echo "RESULT=PASS_READY_FOR_EXP27_REFACTOR"
        echo "All expected experiment 21~26 core files are present."
    else
        echo "RESULT=NEED_SOURCE_PATH_REVIEW"
        echo "Some expected files are missing or renamed."
    fi
} > "$OUT_DIR/summary.txt"

echo "============================================================"
echo " Experiment 27-0 completed"
echo "============================================================"
echo "summary : $OUT_DIR/summary.txt"
echo "sources : $OUT_DIR/candidate_files.txt"
echo "symbols : $OUT_DIR/key_symbols.txt"
echo "cmake   : $OUT_DIR/cmake_targets.txt"
echo "scripts : $OUT_DIR/script_flows.txt"
echo

cat "$OUT_DIR/summary.txt"

#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT=output/exp23_0_pts_source_probe
mkdir -p "$OUT"
LOG="$OUT/exp23_0_source_probe.log"
: > "$LOG"

run_cmd() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

dump_file_head() {
    local f="$1"
    local n="${2:-260}"

    echo
    echo "========== FILE: $f first $n lines =========="
    echo "========== FILE: $f first $n lines ==========" >> "$LOG"

    if [ -f "$f" ]; then
        nl -ba "$f" | sed -n "1,${n}p" | tee -a "$LOG"
    else
        echo "MISSING: $f" | tee -a "$LOG"
    fi
}

grep_file() {
    local pattern="$1"
    local f="$2"

    echo
    echo "========== grep: $pattern in $f =========="
    echo "========== grep: $pattern in $f ==========" >> "$LOG"

    if [ -f "$f" ]; then
        grep -nE "$pattern" "$f" | tee -a "$LOG" || true
    else
        echo "MISSING: $f" | tee -a "$LOG"
    fi
}

echo "exp23-0 source probe start" | tee -a "$LOG"
date | tee -a "$LOG"

echo
echo "========== project pwd ==========" | tee -a "$LOG"
pwd | tee -a "$LOG"

echo
echo "========== key files existence ==========" | tee -a "$LOG"
for f in \
    include/mpp_h264_encoder.hpp \
    src/mpp_h264_encoder.cpp \
    src/main_exp21_detect_mpp_encode_async.cpp \
    src/main_exp21_detect_mpp_encode.cpp \
    src/main_exp21_v4l2_mpp_encode.cpp \
    src/yolo11_clean_silent.cc \
    scripts/exp22_av_async_mpp_rtsp.sh \
    CMakeLists.txt
do
    if [ -f "$f" ]; then
        ls -lh "$f" | tee -a "$LOG"
    else
        echo "MISSING $f" | tee -a "$LOG"
    fi
done

echo
echo "========== backup current source ==========" | tee -a "$LOG"
mkdir -p "$OUT/source_backup"

for f in \
    include/mpp_h264_encoder.hpp \
    src/mpp_h264_encoder.cpp \
    src/main_exp21_detect_mpp_encode_async.cpp \
    src/main_exp21_detect_mpp_encode.cpp \
    src/main_exp21_v4l2_mpp_encode.cpp \
    scripts/exp22_av_async_mpp_rtsp.sh \
    CMakeLists.txt
do
    if [ -f "$f" ]; then
        mkdir -p "$OUT/source_backup/$(dirname "$f")"
        cp -a "$f" "$OUT/source_backup/$f"
    fi
done

find "$OUT/source_backup" -type f | sort | tee -a "$LOG"

dump_file_head include/mpp_h264_encoder.hpp 220
dump_file_head src/mpp_h264_encoder.cpp 360
dump_file_head src/main_exp21_detect_mpp_encode_async.cpp 420

grep_file "struct|class|queue|mutex|condition_variable|thread|Frame|Packet|encode|push|pop|fifo|fwrite|ofstream|frame_id|encoded|drop|fail" \
    src/main_exp21_detect_mpp_encode_async.cpp

grep_file "mpp_create|mpp_init|MppFrame|MppPacket|mpp_frame|mpp_packet|encode|put_frame|get_packet|MPP_ENC|pts|dts|eos|key" \
    src/mpp_h264_encoder.cpp

grep_file "mpp_h264_encoder|exp21_detect_mpp_encode_async|add_executable|target_link_libraries|target_include_directories|rockchip_mpp" \
    CMakeLists.txt

echo
echo "========== MPP PTS API grep ==========" | tee -a "$LOG"
grep -RsnE \
    "mpp_frame_set_pts|mpp_frame_get_pts|mpp_packet_set_pts|mpp_packet_get_pts|mpp_packet_set_dts|mpp_packet_get_dts|mpp_packet_get_flag|KEY_FRAME|INTRA|IDR" \
    /usr/include/rockchip /usr/local/include/rockchip /home/cat/mpp/inc /home/cat/mpp/mpp/inc /home/cat/mpp/osal/inc /home/cat/mpp 2>/dev/null \
    | tee "$OUT/mpp_pts_api_grep.txt" \
    | tee -a "$LOG" || true

echo
echo "========== current build check ==========" | tee -a "$LOG"
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tee -a "../$LOG"
make exp21_detect_mpp_encode_async -j4 2>&1 | tee -a "../$LOG"
cd ..

echo
echo "========== executable usage probe ==========" | tee -a "$LOG"
if [ -x build/exp21_detect_mpp_encode_async ]; then
    timeout 3 ./build/exp21_detect_mpp_encode_async 2>&1 | head -80 | tee -a "$LOG" || true
else
    echo "MISSING executable: build/exp21_detect_mpp_encode_async" | tee -a "$LOG"
fi

echo
echo "========== done ==========" | tee -a "$LOG"
echo "log saved: $LOG" | tee -a "$LOG"
echo "api grep : $OUT/mpp_pts_api_grep.txt" | tee -a "$LOG"
echo "backup   : $OUT/source_backup" | tee -a "$LOG"

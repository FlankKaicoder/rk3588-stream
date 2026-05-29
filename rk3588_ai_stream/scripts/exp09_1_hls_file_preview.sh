#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp09_1_hls_file_preview
HLS_DIR="$OUT_DIR/hls"
LOG="$OUT_DIR/09_1_hls.log"

mkdir -p "$OUT_DIR" "$HLS_DIR"
rm -f "$HLS_DIR"/*

: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

INPUT_MP4="output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4"

if [ ! -f "$INPUT_MP4" ]; then
    echo "ERROR: input mp4 not found: $INPUT_MP4" | tee -a "$LOG"
    echo "Try checking:" | tee -a "$LOG"
    find output -maxdepth 3 -type f -name "*.mp4" | sort | tee -a "$LOG"
    exit 1
fi

echo "========== 09-1 HLS file preview ==========" | tee -a "$LOG"
echo "board ip : $BOARD_IP" | tee -a "$LOG"
echo "input mp4: $INPUT_MP4" | tee -a "$LOG"
echo "hls dir  : $HLS_DIR" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffprobe input ==========" | tee -a "$LOG"
ffprobe -hide_banner "$INPUT_MP4" 2>&1 | tee "$OUT_DIR/input_ffprobe.log" || true

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    if [ -n "${FFMPEG_PID:-}" ]; then
        kill "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "${HTTP_PID:-}" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo | tee -a "$LOG"
echo "========== start ffmpeg HLS ==========" | tee -a "$LOG"

ffmpeg -re -stream_loop -1 \
    -i "$INPUT_MP4" \
    -an \
    -c:v copy \
    -f hls \
    -hls_time 1 \
    -hls_list_size 5 \
    -hls_flags delete_segments+append_list \
    "$HLS_DIR/index.m3u8" \
    > "$OUT_DIR/ffmpeg_hls.log" 2>&1 &

FFMPEG_PID=$!

sleep 3

echo | tee -a "$LOG"
echo "========== generated hls files ==========" | tee -a "$LOG"
ls -lh "$HLS_DIR" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== start http server ==========" | tee -a "$LOG"

cd "$HLS_DIR"
python3 -m http.server 8080 > "../python_http.log" 2>&1 &
HTTP_PID=$!
cd - >/dev/null

echo | tee -a "$LOG"
echo "HLS URL:" | tee -a "$LOG"
echo "  http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "在电脑 VLC 中打开：" | tee -a "$LOG"
echo "  媒体 -> 打开网络串流 -> http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "按 Ctrl+C 结束本实验。" | tee -a "$LOG"

wait "$FFMPEG_PID"

#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp10_1_rtsp_file_preview
LOG="$OUT_DIR/10_1.log"
CONF="$OUT_DIR/mediamtx_min.yml"

mkdir -p "$OUT_DIR"
: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')
INPUT_MP4="output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4"

if [ ! -f "$INPUT_MP4" ]; then
    echo "ERROR: input mp4 not found: $INPUT_MP4" | tee -a "$LOG"
    find output -maxdepth 3 -type f -name "*.mp4" | sort | tee -a "$LOG"
    exit 1
fi

cat > "$CONF" <<'EOF_CONF'
rtspAddress: :8554

paths:
  all_others:
EOF_CONF

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    if [ -n "${FFMPEG_PID:-}" ]; then
        kill "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "${MEDIAMTX_PID:-}" ]; then
        kill "$MEDIAMTX_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pkill -f mediamtx || true
pkill -f "ffmpeg.*exp10_file" || true

echo "========== 10-1 RTSP file preview ==========" | tee -a "$LOG"
echo "board ip : $BOARD_IP" | tee -a "$LOG"
echo "input mp4: $INPUT_MP4" | tee -a "$LOG"
echo "conf     : $CONF" | tee -a "$LOG"

./tools/mediamtx/mediamtx "$CONF" > "$OUT_DIR/mediamtx.log" 2>&1 &
MEDIAMTX_PID=$!

sleep 2

echo | tee -a "$LOG"
echo "========== port check ==========" | tee -a "$LOG"
ss -ltnp | grep 8554 | tee -a "$LOG" || {
    echo "ERROR: no 8554 listen" | tee -a "$LOG"
    tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG"
    exit 1
}

ffmpeg -nostdin -re -stream_loop -1 \
    -i "$INPUT_MP4" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    rtsp://127.0.0.1:8554/exp10_file \
    > "$OUT_DIR/ffmpeg_push_rtsp.log" 2>&1 &

FFMPEG_PID=$!

sleep 3

echo | tee -a "$LOG"
echo "========== mediamtx log ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffmpeg log ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/ffmpeg_push_rtsp.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "RTSP URL:" | tee -a "$LOG"
echo "  rtsp://$BOARD_IP:8554/exp10_file" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "HLS URL:" | tee -a "$LOG"
echo "  http://$BOARD_IP:8888/exp10_file/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "按 Ctrl+C 结束本实验。" | tee -a "$LOG"

wait "$FFMPEG_PID" || true

#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp11_0_browser_file_preview
LOG="$OUT_DIR/11_0.log"
STREAM_PATH=exp11_file_browser

mkdir -p "$OUT_DIR"
: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

INPUT_MP4="output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4"

if [ ! -f "$INPUT_MP4" ]; then
    echo "ERROR: input mp4 not found: $INPUT_MP4" | tee -a "$LOG"
    echo "当前已有 mp4 文件如下：" | tee -a "$LOG"
    find output -maxdepth 4 -type f -name "*.mp4" | sort | tee -a "$LOG"
    exit 1
fi

if command -v mediamtx >/dev/null 2>&1; then
    MEDIAMTX_BIN=$(command -v mediamtx)
else
    MEDIAMTX_BIN=./tools/mediamtx/mediamtx
fi

if [ ! -x "$MEDIAMTX_BIN" ]; then
    echo "ERROR: mediamtx not found or not executable: $MEDIAMTX_BIN" | tee -a "$LOG"
    exit 1
fi

MTX_CONF="$OUT_DIR/mediamtx_browser.yml"

cat > "$MTX_CONF" <<EOF_CONF
rtspAddress: :8554

hls: true
hlsAddress: :8888
hlsAllowOrigins: ["*"]
hlsVariant: lowLatency
hlsAlwaysRemux: true

webrtc: true
webrtcAddress: :8889
webrtcAllowOrigins: ["*"]
webrtcLocalUDPAddress: :8189
webrtcIPsFromInterfaces: true

paths:
  all_others:
EOF_CONF

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    if [ -n "${FFMPEG_PID:-}" ]; then
        kill "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "${MTX_PID:-}" ]; then
        kill "$MTX_PID" 2>/dev/null || true
    fi

    pkill -f "rtsp://127.0.0.1:8554/$STREAM_PATH" 2>/dev/null || true
}
trap cleanup EXIT

echo "========== 11-0 browser file preview ==========" | tee -a "$LOG"
echo "board ip    : $BOARD_IP" | tee -a "$LOG"
echo "input mp4   : $INPUT_MP4" | tee -a "$LOG"
echo "stream path : $STREAM_PATH" | tee -a "$LOG"
echo "mediamtx    : $MEDIAMTX_BIN" | tee -a "$LOG"
echo "config      : $MTX_CONF" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== stop old processes ==========" | tee -a "$LOG"
pkill -f mediamtx 2>/dev/null || true
pkill -f ffmpeg 2>/dev/null || true
sleep 1

echo | tee -a "$LOG"
echo "========== start MediaMTX ==========" | tee -a "$LOG"

"$MEDIAMTX_BIN" "$MTX_CONF" > "$OUT_DIR/mediamtx.log" 2>&1 &
MTX_PID=$!

sleep 2

echo | tee -a "$LOG"
echo "========== ports ==========" | tee -a "$LOG"
ss -lntup 2>/dev/null | grep -E ":8554|:8888|:8889|:1935" | tee -a "$LOG" || true
ss -lunp 2>/dev/null | grep -E ":8189" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== start ffmpeg: MP4 -> RTSP publish ==========" | tee -a "$LOG"

ffmpeg -nostdin -re -stream_loop -1 \
    -i "$INPUT_MP4" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    "rtsp://127.0.0.1:8554/$STREAM_PATH" \
    > "$OUT_DIR/ffmpeg_push.log" 2>&1 &

FFMPEG_PID=$!

sleep 4

echo | tee -a "$LOG"
echo "========== MediaMTX log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== FFmpeg log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/ffmpeg_push.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== 打开方式 ==========" | tee -a "$LOG"
echo "浏览器 WebRTC 低延迟地址：" | tee -a "$LOG"
echo "  http://$BOARD_IP:8889/$STREAM_PATH" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "浏览器 HLS 备用地址：" | tee -a "$LOG"
echo "  http://$BOARD_IP:8888/$STREAM_PATH" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "VLC HLS 地址：" | tee -a "$LOG"
echo "  http://$BOARD_IP:8888/$STREAM_PATH/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "VLC RTSP 地址：" | tee -a "$LOG"
echo "  rtsp://$BOARD_IP:8554/$STREAM_PATH" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "如果 WebRTC 打不开，先用 HLS / RTSP 验证流是否已经发布成功。" | tee -a "$LOG"
echo "按 Ctrl+C 结束本实验。" | tee -a "$LOG"

wait "$FFMPEG_PID"

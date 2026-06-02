#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp11_1_realtime_detect_browser
LOG="$OUT_DIR/11_1.log"
STREAM_PATH=exp11_detect_browser

mkdir -p "$OUT_DIR"
: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

WIDTH=1280
HEIGHT=720
FPS=30

# 10分钟左右，方便打开浏览器观察
FRAMES=18000

NV12_FIFO="$OUT_DIR/realtime_detect_nv12.fifo"
H264_FIFO="$OUT_DIR/realtime_detect_h264.fifo"
PROFILE="$OUT_DIR/profile_realtime_detect_browser.csv"

rm -f "$NV12_FIFO" "$H264_FIFO" "$PROFILE"
mkfifo "$NV12_FIFO"
mkfifo "$H264_FIFO"

if command -v mediamtx >/dev/null 2>&1; then
    MEDIAMTX_BIN=$(command -v mediamtx)
else
    MEDIAMTX_BIN=./tools/mediamtx/mediamtx
fi

if [ ! -x "$MEDIAMTX_BIN" ]; then
    echo "ERROR: mediamtx not found or not executable: $MEDIAMTX_BIN" | tee -a "$LOG"
    exit 1
fi

if [ ! -x ./build/v4l2_rga_rknn_detect_to_nv12_clean ]; then
    echo "ERROR: ./build/v4l2_rga_rknn_detect_to_nv12_clean not found" | tee -a "$LOG"
    echo "请先确认 08/09/10 实验的 build 目标还在。" | tee -a "$LOG"
    exit 1
fi

if [ ! -x /home/cat/mpp/build/test/mpi_enc_test ]; then
    echo "ERROR: /home/cat/mpp/build/test/mpi_enc_test not found" | tee -a "$LOG"
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

    if [ -n "${DETECT_PID:-}" ]; then
        kill "$DETECT_PID" 2>/dev/null || true
    fi

    if [ -n "${ENC_PID:-}" ]; then
        kill "$ENC_PID" 2>/dev/null || true
    fi

    if [ -n "${FFMPEG_PID:-}" ]; then
        kill "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "${MTX_PID:-}" ]; then
        kill "$MTX_PID" 2>/dev/null || true
    fi

    pkill -f "v4l2_rga_rknn_detect_to_nv12_clean" 2>/dev/null || true
    pkill -f "mpi_enc_test.*realtime_detect_nv12" 2>/dev/null || true
    pkill -f "rtsp://127.0.0.1:8554/$STREAM_PATH" 2>/dev/null || true

    rm -f "$NV12_FIFO" "$H264_FIFO"
}
trap cleanup EXIT

echo "========== 11-1 realtime detect browser preview ==========" | tee -a "$LOG"
echo "board ip    : $BOARD_IP" | tee -a "$LOG"
echo "stream path : $STREAM_PATH" | tee -a "$LOG"
echo "width       : $WIDTH" | tee -a "$LOG"
echo "height      : $HEIGHT" | tee -a "$LOG"
echo "fps         : $FPS" | tee -a "$LOG"
echo "frames      : $FRAMES" | tee -a "$LOG"
echo "nv12 fifo   : $NV12_FIFO" | tee -a "$LOG"
echo "h264 fifo   : $H264_FIFO" | tee -a "$LOG"
echo "profile     : $PROFILE" | tee -a "$LOG"
echo "mediamtx    : $MEDIAMTX_BIN" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== stop old processes ==========" | tee -a "$LOG"
pkill -f mediamtx 2>/dev/null || true
pkill -f ffmpeg 2>/dev/null || true
pkill -f mpi_enc_test 2>/dev/null || true
pkill -f v4l2_rga_rknn_detect_to_nv12_clean 2>/dev/null || true
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
echo "========== start ffmpeg: H264 FIFO -> RTSP publish ==========" | tee -a "$LOG"

ffmpeg -nostdin \
    -fflags nobuffer \
    -flags low_delay \
    -f h264 \
    -framerate "$FPS" \
    -i "$H264_FIFO" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    "rtsp://127.0.0.1:8554/$STREAM_PATH" \
    > "$OUT_DIR/ffmpeg_push.log" 2>&1 &

FFMPEG_PID=$!

sleep 1

echo | tee -a "$LOG"
echo "========== start MPP encoder: NV12 FIFO -> H264 FIFO ==========" | tee -a "$LOG"

/home/cat/mpp/build/test/mpi_enc_test \
    -i "$NV12_FIFO" \
    -o "$H264_FIFO" \
    -w "$WIDTH" \
    -h "$HEIGHT" \
    -f 0 \
    -t 7 \
    -n "$FRAMES" \
    > "$OUT_DIR/mpi_enc.log" 2>&1 &

ENC_PID=$!

sleep 1

echo | tee -a "$LOG"
echo "========== start realtime detect writer: camera -> NV12 FIFO ==========" | tee -a "$LOG"

sudo ./build/v4l2_rga_rknn_detect_to_nv12_clean \
    models/yolo11.rknn \
    /dev/video11 \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$NV12_FIFO" \
    "$PROFILE" \
    > "$OUT_DIR/realtime_detect_to_nv12.log" 2>&1 &

DETECT_PID=$!

sleep 5

echo | tee -a "$LOG"
echo "========== MediaMTX log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true

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
echo "建议优先打开 WebRTC 地址。如果 WebRTC 黑屏，立刻打开 HLS 或 RTSP 判断是不是 WebRTC ICE/浏览器问题。" | tee -a "$LOG"
echo "按 Ctrl+C 结束本实验。" | tee -a "$LOG"

wait "$DETECT_PID" || true

echo | tee -a "$LOG"
echo "========== detect finished, wait encoder ==========" | tee -a "$LOG"
wait "$ENC_PID" || true

sleep 3
kill "$FFMPEG_PID" 2>/dev/null || true

echo | tee -a "$LOG"
echo "========== detect log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/realtime_detect_to_nv12.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== encoder log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mpi_enc.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg log tail ==========" | tee -a "$LOG"
tail -120 "$OUT_DIR/ffmpeg_push.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== mediamtx log tail ==========" | tee -a "$LOG"
tail -120 "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== profile csv ==========" | tee -a "$LOG"
ls -lh "$PROFILE" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "11-1 done."

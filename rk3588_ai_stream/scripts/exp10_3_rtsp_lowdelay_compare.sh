#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

TRANSPORT="${1:-tcp}"

if [ "$TRANSPORT" != "tcp" ] && [ "$TRANSPORT" != "udp" ]; then
    echo "Usage: $0 [tcp|udp]"
    exit 1
fi

OUT_DIR="output/exp10_3_rtsp_lowdelay_${TRANSPORT}"
LOG="$OUT_DIR/10_3_${TRANSPORT}.log"
CONF="$OUT_DIR/mediamtx_min.yml"

mkdir -p "$OUT_DIR"
: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

WIDTH=1280
HEIGHT=720
FPS=30
FRAMES=18000

NV12_FIFO="$OUT_DIR/realtime_detect_nv12.fifo"
H264_FIFO="$OUT_DIR/realtime_detect_h264.fifo"
PROFILE="$OUT_DIR/profile_realtime_detect_rtsp_${TRANSPORT}.csv"

rm -f "$NV12_FIFO" "$H264_FIFO" "$PROFILE"
mkfifo "$NV12_FIFO"
mkfifo "$H264_FIFO"

cat > "$CONF" <<'EOF_CONF'
rtspAddress: :8554

paths:
  all_others:
EOF_CONF

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    kill ${DETECT_PID:-0} 2>/dev/null || true
    kill ${ENC_PID:-0} 2>/dev/null || true
    kill ${FFMPEG_PID:-0} 2>/dev/null || true
    kill ${MEDIAMTX_PID:-0} 2>/dev/null || true

    pkill -f "v4l2_rga_rknn_detect_to_nv12_clean" 2>/dev/null || true
    pkill -f "mpi_enc_test" 2>/dev/null || true
    pkill -f "ffmpeg.*exp10_detect" 2>/dev/null || true
    pkill -f mediamtx 2>/dev/null || true

    rm -f "$NV12_FIFO" "$H264_FIFO"
}
trap cleanup EXIT

echo "========== 10-3 RTSP low delay compare ==========" | tee -a "$LOG"
echo "transport : $TRANSPORT" | tee -a "$LOG"
echo "board ip  : $BOARD_IP" | tee -a "$LOG"
echo "width     : $WIDTH" | tee -a "$LOG"
echo "height    : $HEIGHT" | tee -a "$LOG"
echo "fps       : $FPS" | tee -a "$LOG"
echo "frames    : $FRAMES" | tee -a "$LOG"
echo "out dir   : $OUT_DIR" | tee -a "$LOG"
echo "profile   : $PROFILE" | tee -a "$LOG"

if [ ! -x ./tools/mediamtx/mediamtx ]; then
    echo "ERROR: ./tools/mediamtx/mediamtx not found or not executable" | tee -a "$LOG"
    exit 1
fi

if [ ! -x ./build/v4l2_rga_rknn_detect_to_nv12_clean ]; then
    echo "ERROR: ./build/v4l2_rga_rknn_detect_to_nv12_clean not found" | tee -a "$LOG"
    echo "Try:" | tee -a "$LOG"
    echo "  cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make v4l2_rga_rknn_detect_to_nv12_clean -j4" | tee -a "$LOG"
    exit 1
fi

echo | tee -a "$LOG"
echo "========== clean old processes ==========" | tee -a "$LOG"
pkill -f mediamtx 2>/dev/null || true
pkill -f "ffmpeg.*exp10_detect" 2>/dev/null || true
pkill -f mpi_enc_test 2>/dev/null || true
pkill -f v4l2_rga_rknn_detect_to_nv12_clean 2>/dev/null || true
sleep 1

echo | tee -a "$LOG"
echo "========== start mediamtx ==========" | tee -a "$LOG"
./tools/mediamtx/mediamtx "$CONF" > "$OUT_DIR/mediamtx.log" 2>&1 &
MEDIAMTX_PID=$!

sleep 2

ss -ltnp | grep 8554 | tee -a "$LOG" || {
    echo "ERROR: no 8554 listen" | tee -a "$LOG"
    tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG"
    exit 1
}

echo | tee -a "$LOG"
echo "========== start ffmpeg: H264 FIFO -> RTSP ==========" | tee -a "$LOG"

ffmpeg -nostdin -y \
    -fflags nobuffer \
    -flags low_delay \
    -probesize 32 \
    -analyzeduration 0 \
    -use_wallclock_as_timestamps 1 \
    -f h264 \
    -framerate "$FPS" \
    -i "$H264_FIFO" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport "$TRANSPORT" \
    "rtsp://127.0.0.1:8554/exp10_detect" \
    > "$OUT_DIR/ffmpeg_push_rtsp.log" 2>&1 &

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
    > "$OUT_DIR/mpi_enc_rtsp.log" 2>&1 &

ENC_PID=$!

sleep 1

echo | tee -a "$LOG"
echo "========== start realtime detect writer: camera -> NV12 FIFO ==========" | tee -a "$LOG"

./build/v4l2_rga_rknn_detect_to_nv12_clean \
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
echo "========== mediamtx log ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffmpeg log ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/ffmpeg_push_rtsp.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "RTSP URL:" | tee -a "$LOG"
echo "  rtsp://$BOARD_IP:8554/exp10_detect" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "HLS backup URL:" | tee -a "$LOG"
echo "  http://$BOARD_IP:8888/exp10_detect/index.m3u8" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "VLC recommended command:" | tee -a "$LOG"
echo "  vlc --network-caching=100 --avcodec-hw=none rtsp://$BOARD_IP:8554/exp10_detect" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "按 Ctrl+C 结束当前 ${TRANSPORT} 对照实验。" | tee -a "$LOG"

wait "$DETECT_PID" || true

echo | tee -a "$LOG"
echo "========== detect finished, wait encoder ==========" | tee -a "$LOG"
wait "$ENC_PID" || true

sleep 2
kill "$FFMPEG_PID" 2>/dev/null || true

echo | tee -a "$LOG"
echo "========== final log tail: detect ==========" | tee -a "$LOG"
tail -100 "$OUT_DIR/realtime_detect_to_nv12.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final log tail: encoder ==========" | tee -a "$LOG"
tail -100 "$OUT_DIR/mpi_enc_rtsp.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final log tail: ffmpeg ==========" | tee -a "$LOG"
tail -120 "$OUT_DIR/ffmpeg_push_rtsp.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final log tail: mediamtx ==========" | tee -a "$LOG"
tail -120 "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== output files ==========" | tee -a "$LOG"
ls -lh "$OUT_DIR" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "10-3 ${TRANSPORT} done." | tee -a "$LOG"

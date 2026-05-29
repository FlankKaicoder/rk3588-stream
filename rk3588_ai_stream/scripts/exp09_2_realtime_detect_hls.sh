#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp09_2_realtime_detect_hls
HLS_DIR="$OUT_DIR/hls"
LOG="$OUT_DIR/09_2.log"

mkdir -p "$OUT_DIR" "$HLS_DIR"
rm -f "$HLS_DIR"/*

: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

WIDTH=1280
HEIGHT=720
FPS=30

# 10分钟左右，避免还没打开 VLC 就结束
FRAMES=18000

NV12_FIFO="$OUT_DIR/realtime_detect_nv12.fifo"
H264_FIFO="$OUT_DIR/realtime_detect_h264.fifo"
PROFILE="$OUT_DIR/profile_realtime_detect_hls.csv"

rm -f "$NV12_FIFO" "$H264_FIFO" "$PROFILE"
mkfifo "$NV12_FIFO"
mkfifo "$H264_FIFO"

echo "========== 09-2 realtime detect HLS ==========" | tee -a "$LOG"
echo "board ip  : $BOARD_IP" | tee -a "$LOG"
echo "width     : $WIDTH" | tee -a "$LOG"
echo "height    : $HEIGHT" | tee -a "$LOG"
echo "fps       : $FPS" | tee -a "$LOG"
echo "frames    : $FRAMES" | tee -a "$LOG"
echo "nv12 fifo : $NV12_FIFO" | tee -a "$LOG"
echo "h264 fifo : $H264_FIFO" | tee -a "$LOG"
echo "hls dir   : $HLS_DIR" | tee -a "$LOG"

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    kill ${DETECT_PID:-0} 2>/dev/null || true
    kill ${ENC_PID:-0} 2>/dev/null || true
    kill ${FFMPEG_PID:-0} 2>/dev/null || true
    kill ${HTTP_PID:-0} 2>/dev/null || true

    sudo pkill -f "v4l2_rga_rknn_detect_to_nv12_clean" 2>/dev/null || true
    pkill -f "mpi_enc_test" 2>/dev/null || true
    pkill -f "ffmpeg.*realtime_detect_h264" 2>/dev/null || true
    pkill -f "python3 -m http.server 8080" 2>/dev/null || true

    rm -f "$NV12_FIFO" "$H264_FIFO"
}
trap cleanup EXIT

echo | tee -a "$LOG"
echo "========== start HTTP server ==========" | tee -a "$LOG"

cd "$HLS_DIR"
python3 -m http.server 8080 > "../python_http.log" 2>&1 &
HTTP_PID=$!
cd - >/dev/null

sleep 1

echo | tee -a "$LOG"
echo "========== start ffmpeg: H264 FIFO -> HLS ==========" | tee -a "$LOG"

ffmpeg -y \
    -fflags nobuffer \
    -flags low_delay \
    -f h264 \
    -framerate "$FPS" \
    -i "$H264_FIFO" \
    -an \
    -c:v copy \
    -f hls \
    -hls_time 1 \
    -hls_list_size 5 \
    -hls_flags delete_segments+append_list \
    "$HLS_DIR/index.m3u8" \
    > "$OUT_DIR/ffmpeg_hls.log" 2>&1 &

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
    > "$OUT_DIR/mpi_enc_hls.log" 2>&1 &

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

echo | tee -a "$LOG"
echo "HLS URL:" | tee -a "$LOG"
echo "  http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "现在去电脑 VLC 打开：" | tee -a "$LOG"
echo "  http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "提示：HLS 需要等 3~8 秒生成 index.m3u8 和 ts 分片。" | tee -a "$LOG"
echo "本脚本会持续运行约 10 分钟，按 Ctrl+C 可提前结束。" | tee -a "$LOG"

wait "$DETECT_PID" || true

echo | tee -a "$LOG"
echo "========== detect finished, wait encoder ==========" | tee -a "$LOG"
wait "$ENC_PID" || true

sleep 3
kill "$FFMPEG_PID" 2>/dev/null || true

echo | tee -a "$LOG"
echo "========== generated HLS files ==========" | tee -a "$LOG"
ls -lh "$HLS_DIR" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== detect log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/realtime_detect_to_nv12.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== encoder log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mpi_enc_hls.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg log tail ==========" | tee -a "$LOG"
tail -120 "$OUT_DIR/ffmpeg_hls.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== profile csv ==========" | tee -a "$LOG"
ls -lh "$PROFILE" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "09-2 done." | tee -a "$LOG"

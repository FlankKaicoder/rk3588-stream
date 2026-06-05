#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp19_1_realtime_av_rtsp_fix
LOG="$OUT_DIR/19_1_realtime_av_rtsp_fix.log"

WIDTH="${1:-1280}"
HEIGHT="${2:-720}"
FPS="${3:-20}"
FRAMES="${4:-1200}"
AUDIO_DEV="${5:-hw:2,0}"
AUDIO_RATE="${6:-48000}"
AUDIO_CHANNELS="${7:-2}"

STREAM_PATH="exp19_1_av_detect_fix"
RTSP_URL_LOCAL="rtsp://127.0.0.1:8554/${STREAM_PATH}"

NV12_FIFO="$OUT_DIR/realtime_detect_nv12.fifo"
H264_FIFO="$OUT_DIR/realtime_detect_h264.fifo"
PROFILE="$OUT_DIR/profile_realtime_av_detect_fix.csv"

mkdir -p "$OUT_DIR"
: > "$LOG"

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    if [ -n "${DETECT_PID:-}" ]; then
        kill "$DETECT_PID" 2>/dev/null || true
        wait "$DETECT_PID" 2>/dev/null || true
    fi

    if [ -n "${MPP_PID:-}" ]; then
        kill "$MPP_PID" 2>/dev/null || true
        wait "$MPP_PID" 2>/dev/null || true
    fi

    if [ -n "${FFMPEG_PID:-}" ]; then
        kill "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "${MEDIAMTX_PID:-}" ]; then
        kill "$MEDIAMTX_PID" 2>/dev/null || true
        wait "$MEDIAMTX_PID" 2>/dev/null || true
    fi

    rm -f "$NV12_FIFO" "$H264_FIFO"
}
trap cleanup EXIT

echo "========== 19-1 realtime AV RTSP fix ==========" | tee -a "$LOG"
date | tee -a "$LOG"
echo "width          : $WIDTH" | tee -a "$LOG"
echo "height         : $HEIGHT" | tee -a "$LOG"
echo "fps            : $FPS" | tee -a "$LOG"
echo "frames         : $FRAMES" | tee -a "$LOG"
echo "audio dev      : $AUDIO_DEV" | tee -a "$LOG"
echo "audio rate     : $AUDIO_RATE" | tee -a "$LOG"
echo "audio channels : $AUDIO_CHANNELS" | tee -a "$LOG"
echo "stream path    : $STREAM_PATH" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== check executable files ==========" | tee -a "$LOG"

if [ ! -x "./build/v4l2_rga_rknn_detect_to_nv12_clean" ]; then
    echo "ERROR: missing ./build/v4l2_rga_rknn_detect_to_nv12_clean" | tee -a "$LOG"
    echo "Build it first:" | tee -a "$LOG"
    echo "  cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make v4l2_rga_rknn_detect_to_nv12_clean -j4" | tee -a "$LOG"
    exit 1
fi

if [ ! -x "/home/cat/mpp/build/test/mpi_enc_test" ]; then
    echo "ERROR: missing /home/cat/mpp/build/test/mpi_enc_test" | tee -a "$LOG"
    exit 1
fi

if [ ! -x "./tools/mediamtx/mediamtx" ]; then
    echo "ERROR: missing ./tools/mediamtx/mediamtx" | tee -a "$LOG"
    exit 1
fi

which ffmpeg 2>&1 | tee -a "$LOG"
which ffprobe 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== audio capture hw params ==========" | tee -a "$LOG"

timeout 5 arecord -D "$AUDIO_DEV" --dump-hw-params \
    -f S16_LE \
    -r "$AUDIO_RATE" \
    -c "$AUDIO_CHANNELS" \
    -d 1 \
    /dev/null 2>&1 \
    | tee "$OUT_DIR/audio_capture_hw_params.log" \
    | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== prepare FIFO ==========" | tee -a "$LOG"

rm -f "$NV12_FIFO" "$H264_FIFO"
mkfifo "$NV12_FIFO"
mkfifo "$H264_FIFO"
ls -lh "$NV12_FIFO" "$H264_FIFO" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== start MediaMTX ==========" | tee -a "$LOG"

pkill -f mediamtx 2>/dev/null || true
sleep 1

cat > "$OUT_DIR/mediamtx_av_fix.yml" <<EOF
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
EOF

./tools/mediamtx/mediamtx "$OUT_DIR/mediamtx_av_fix.yml" > "$OUT_DIR/mediamtx_av_fix.log" 2>&1 &
MEDIAMTX_PID=$!

sleep 2

echo "MediaMTX pid: $MEDIAMTX_PID" | tee -a "$LOG"
ps -p "$MEDIAMTX_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true
ss -ltnp 2>/dev/null | grep 8554 | tee -a "$LOG" || true
tail -80 "$OUT_DIR/mediamtx_av_fix.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== start FFmpeg AV mux / RTSP push ==========" | tee -a "$LOG"

ffmpeg -nostdin -hide_banner \
    -fflags +genpts+nobuffer \
    -flags low_delay \
    -thread_queue_size 4096 \
    -use_wallclock_as_timestamps 1 \
    -f h264 \
    -r "$FPS" \
    -i "$H264_FIFO" \
    -thread_queue_size 4096 \
    -f alsa \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CHANNELS" \
    -i "$AUDIO_DEV" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a aac \
    -b:a 128k \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CHANNELS" \
    -f rtsp \
    -rtsp_transport tcp \
    "$RTSP_URL_LOCAL" \
    > "$OUT_DIR/ffmpeg_av_push_fix.log" 2>&1 &
FFMPEG_PID=$!

sleep 1

echo "FFmpeg pid: $FFMPEG_PID" | tee -a "$LOG"
ps -p "$FFMPEG_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== start MPP encoder ==========" | tee -a "$LOG"

/home/cat/mpp/build/test/mpi_enc_test \
    -i "$NV12_FIFO" \
    -o "$H264_FIFO" \
    -w "$WIDTH" \
    -h "$HEIGHT" \
    -f 0 \
    -t 7 \
    -n "$FRAMES" \
    > "$OUT_DIR/mpi_enc_av_fix.log" 2>&1 &
MPP_PID=$!

sleep 1

echo "MPP pid: $MPP_PID" | tee -a "$LOG"
ps -p "$MPP_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== start realtime detect NV12 writer ==========" | tee -a "$LOG"

sudo ./build/v4l2_rga_rknn_detect_to_nv12_clean \
    models/yolo11.rknn \
    /dev/video11 \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$NV12_FIFO" \
    "$PROFILE" \
    > "$OUT_DIR/realtime_detect_to_nv12_fix.log" 2>&1 &
DETECT_PID=$!

sleep 3

echo "Detect pid: $DETECT_PID" | tee -a "$LOG"
ps -p "$DETECT_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true

BOARD_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo | tee -a "$LOG"
echo "========== playback URLs ==========" | tee -a "$LOG"
echo "VLC RTSP TCP:" | tee -a "$LOG"
echo "rtsp://${BOARD_IP}:8554/${STREAM_PATH}" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "Recommended VLC command:" | tee -a "$LOG"
echo "vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none rtsp://${BOARD_IP}:8554/${STREAM_PATH}" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== wait for MediaMTX stream online ==========" | tee -a "$LOG"

ONLINE=0
for i in $(seq 1 40); do
    if grep -q "path ${STREAM_PATH}.*2 tracks" "$OUT_DIR/mediamtx_av_fix.log" 2>/dev/null; then
        ONLINE=1
        echo "stream online detected at ${i}s" | tee -a "$LOG"
        break
    fi

    if grep -q "stream is available and online, 2 tracks" "$OUT_DIR/mediamtx_av_fix.log" 2>/dev/null; then
        ONLINE=1
        echo "stream online detected at ${i}s" | tee -a "$LOG"
        break
    fi

    sleep 1
done

if [ "$ONLINE" -eq 0 ]; then
    echo "WARNING: stream online not detected before ffprobe." | tee -a "$LOG"
    tail -120 "$OUT_DIR/mediamtx_av_fix.log" | tee -a "$LOG" || true
fi

echo | tee -a "$LOG"
echo "========== ffprobe RTSP AV stream after online ==========" | tee -a "$LOG"

timeout 20 ffprobe -hide_banner -rtsp_transport tcp "rtsp://127.0.0.1:8554/${STREAM_PATH}" 2>&1 \
    | tee "$OUT_DIR/ffprobe_av_rtsp_fix.log" \
    | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== process snapshot while running ==========" | tee -a "$LOG"

ps -p "$DETECT_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true
ps -p "$MPP_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true
ps -p "$FFMPEG_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true
ps -p "$MEDIAMTX_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== wait realtime chain ==========" | tee -a "$LOG"
echo "Open VLC now:" | tee -a "$LOG"
echo "rtsp://${BOARD_IP}:8554/${STREAM_PATH}" | tee -a "$LOG"

wait "$DETECT_PID" || true
DETECT_PID=""

wait "$MPP_PID" || true
MPP_PID=""

sleep 3

echo | tee -a "$LOG"
echo "========== stop FFmpeg / MediaMTX ==========" | tee -a "$LOG"

kill "$FFMPEG_PID" 2>/dev/null || true
wait "$FFMPEG_PID" 2>/dev/null || true
FFMPEG_PID=""

kill "$MEDIAMTX_PID" 2>/dev/null || true
wait "$MEDIAMTX_PID" 2>/dev/null || true
MEDIAMTX_PID=""

echo | tee -a "$LOG"
echo "========== logs tail ==========" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "----- realtime_detect_to_nv12_fix.log tail -----" | tee -a "$LOG"
tail -120 "$OUT_DIR/realtime_detect_to_nv12_fix.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "----- mpi_enc_av_fix.log tail -----" | tee -a "$LOG"
tail -120 "$OUT_DIR/mpi_enc_av_fix.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "----- ffmpeg_av_push_fix.log tail -----" | tee -a "$LOG"
tail -160 "$OUT_DIR/ffmpeg_av_push_fix.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "----- mediamtx_av_fix.log tail -----" | tee -a "$LOG"
tail -160 "$OUT_DIR/mediamtx_av_fix.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== output files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f -printf "%f %s bytes\n" | sort | tee "$OUT_DIR/file_sizes.txt" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 19-1 summary ==========" | tee -a "$LOG"
echo "profile=$PROFILE" | tee -a "$LOG"
echo "rtsp_url=rtsp://${BOARD_IP}:8554/${STREAM_PATH}" | tee -a "$LOG"
echo "log=$LOG" | tee -a "$LOG"
echo "19-1 realtime AV RTSP fix finished." | tee -a "$LOG"

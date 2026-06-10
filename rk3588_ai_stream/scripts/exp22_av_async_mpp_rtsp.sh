#!/usr/bin/env bash
set -u

cd ~/projects/rk3588_ai_stream

WIDTH=${1:-1280}
HEIGHT=${2:-720}
FPS=${3:-30}
FRAMES=${4:-300}
AUDIO_DEV=${5:-hw:2,0}
AUDIO_RATE=${6:-48000}
AUDIO_CH=${7:-2}
STREAM_PATH=${8:-exp22_av_async_mpp_rtsp}

MODEL=models/yolo11.rknn
VIDEO_DEV=/dev/video11

TS=$(date +%Y%m%d_%H%M%S)
OUT_DIR=output/exp22_av_async_mpp_rtsp_${FRAMES}f_${TS}

mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/22_1.log"
MEDIAMTX_YML="$OUT_DIR/mediamtx_exp22.yml"
MEDIAMTX_LOG="$OUT_DIR/mediamtx.log"
FFMPEG_LOG="$OUT_DIR/ffmpeg_av_rtsp.log"
DETECT_LOG="$OUT_DIR/detect_async_mpp_h264_fifo.log"
FFPROBE_LOG="$OUT_DIR/ffprobe_av_rtsp.log"
PROFILE="$OUT_DIR/profile_exp22_async_mpp_av.csv"

H264_FIFO="$OUT_DIR/detect_h264.fifo"

BOARD_IP=$(hostname -I | awk '{print $1}')
STREAM_URL_LOCAL="rtsp://127.0.0.1:8554/${STREAM_PATH}"
STREAM_URL_LAN="rtsp://${BOARD_IP}:8554/${STREAM_PATH}"

: > "$LOG"

log() {
    echo "$@" | tee -a "$LOG"
}

CLEANED=0

cleanup() {
    if [ "${CLEANED:-0}" = "1" ]; then
        return
    fi
    CLEANED=1

    log
    log "========== cleanup =========="
    for p in ${DETECT_PID:-} ${FFMPEG_PID:-} ${MEDIAMTX_PID:-}; do
        if [ -n "${p:-}" ]; then
            kill "$p" 2>/dev/null || true
        fi
    done
    rm -f "$H264_FIFO"
}
trap cleanup EXIT INT TERM

log "========== exp22-1 start =========="
date | tee -a "$LOG"

log
log "WIDTH       = $WIDTH"
log "HEIGHT      = $HEIGHT"
log "FPS         = $FPS"
log "FRAMES      = $FRAMES"
log "AUDIO_DEV   = $AUDIO_DEV"
log "AUDIO_RATE  = $AUDIO_RATE"
log "AUDIO_CH    = $AUDIO_CH"
log "STREAM_PATH = $STREAM_PATH"
log "OUT_DIR     = $OUT_DIR"

log
log "========== precheck =========="

if [ ! -x build/exp21_detect_mpp_encode_async ]; then
    log "ERROR: build/exp21_detect_mpp_encode_async not found or not executable."
    log "Run:"
    log "  rm -rf build && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make exp21_detect_mpp_encode_async -j4"
    exit 1
fi

if [ ! -f "$MODEL" ]; then
    log "ERROR: model not found: $MODEL"
    exit 1
fi

if [ ! -e "$VIDEO_DEV" ]; then
    log "ERROR: video device not found: $VIDEO_DEV"
    exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    log "ERROR: ffmpeg not found"
    exit 1
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    log "ERROR: ffprobe not found"
    exit 1
fi

log "ffmpeg : $(command -v ffmpeg)"
log "ffprobe: $(command -v ffprobe)"

log
log "========== find mediamtx =========="

MEDIAMTX_BIN=""

for p in \
    ./tools/mediamtx/mediamtx \
    ./tools/mediamtx \
    "$(command -v mediamtx 2>/dev/null || true)"
do
    if [ -n "$p" ] && [ -f "$p" ] && [ -x "$p" ]; then
        MEDIAMTX_BIN="$p"
        break
    fi
done

if [ -z "$MEDIAMTX_BIN" ]; then
    log "ERROR: mediamtx executable not found."
    log "Expected: ./tools/mediamtx/mediamtx"
    exit 1
fi

log "MEDIAMTX_BIN = $MEDIAMTX_BIN"

log
log "========== kill old processes =========="

pkill -f "mediamtx" 2>/dev/null || true
pkill -f "ffmpeg.*${STREAM_PATH}" 2>/dev/null || true
pkill -f "exp21_detect_mpp_encode_async" 2>/dev/null || true

sleep 1

log
log "========== create mediamtx config =========="

cat > "$MEDIAMTX_YML" <<EOF
rtspAddress: :8554

hls: false
webrtc: false

paths:
  all_others:
EOF

cat "$MEDIAMTX_YML" | tee -a "$LOG"

log
log "========== create fifo =========="

rm -f "$H264_FIFO"
mkfifo "$H264_FIFO"

ls -lh "$H264_FIFO" | tee -a "$LOG"

log
log "========== start mediamtx =========="

"$MEDIAMTX_BIN" "$MEDIAMTX_YML" > "$MEDIAMTX_LOG" 2>&1 &
MEDIAMTX_PID=$!

sleep 2

if ! ps -p "$MEDIAMTX_PID" >/dev/null 2>&1; then
    log "ERROR: mediamtx failed to start."
    tail -120 "$MEDIAMTX_LOG" | tee -a "$LOG"
    exit 1
fi

ss -ltnp 2>/dev/null | grep 8554 | tee -a "$LOG" || log "WARN: 8554 not shown by ss"

log
log "========== start ffmpeg: H264 FIFO + ALSA AAC -> RTSP =========="

ffmpeg -nostdin -hide_banner -loglevel info \
    -thread_queue_size 2048 \
    -fflags +genpts \
    -use_wallclock_as_timestamps 1 \
    -f h264 \
    -r "$FPS" \
    -i "$H264_FIFO" \
    -thread_queue_size 4096 \
    -f alsa \
    -sample_rate "$AUDIO_RATE" \
    -channels "$AUDIO_CH" \
    -i "$AUDIO_DEV" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a aac \
    -b:a 128k \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -shortest \
    -f rtsp \
    -rtsp_transport tcp \
    "$STREAM_URL_LOCAL" \
    > "$FFMPEG_LOG" 2>&1 &

FFMPEG_PID=$!

sleep 1

log "FFMPEG_PID = $FFMPEG_PID"

log
log "========== start detector: V4L2 + RGA + RKNN + async MPP -> H264 FIFO =========="

./build/exp21_detect_mpp_encode_async \
    "$MODEL" \
    "$VIDEO_DEV" \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$H264_FIFO" \
    "$PROFILE" \
    > "$DETECT_LOG" 2>&1 &

DETECT_PID=$!

log "DETECT_PID = $DETECT_PID"

log
log "========== playback url =========="
log "VLC open:"
log "  $STREAM_URL_LAN"
log
log "Recommended VLC command:"
log "  vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none $STREAM_URL_LAN"

log
log "========== wait stream online and ffprobe =========="

FFPROBE_OK=0

for i in $(seq 1 25); do
    sleep 1

    if timeout 8 ffprobe \
        -hide_banner \
        -rtsp_transport tcp \
        "$STREAM_URL_LOCAL" \
        > "$FFPROBE_LOG" 2>&1; then

        if grep -q "Video: h264" "$FFPROBE_LOG" && grep -q "Audio: aac" "$FFPROBE_LOG"; then
            FFPROBE_OK=1
            log "ffprobe success: H264 + AAC found at try $i"
            break
        else
            log "ffprobe connected but tracks incomplete at try $i"
        fi
    else
        log "ffprobe not ready at try $i"
    fi
done

log
log "========== ffprobe current result =========="
cat "$FFPROBE_LOG" 2>/dev/null | tee -a "$LOG" || true

log
log "========== wait detector finish =========="

wait "$DETECT_PID" || true

log "detector finished."

sleep 3

if ps -p "$FFMPEG_PID" >/dev/null 2>&1; then
    log "ffmpeg still running, stop it."
    kill "$FFMPEG_PID" 2>/dev/null || true
    sleep 1
fi

log
log "========== process status =========="
ps -ef | grep -E "mediamtx|ffmpeg|exp21_detect_mpp_encode_async" | grep -v grep | tee -a "$LOG" || true

log
log "========== detect log tail =========="
tail -120 "$DETECT_LOG" | tee -a "$LOG" || true

log
log "========== ffmpeg log tail =========="
tail -160 "$FFMPEG_LOG" | tee -a "$LOG" || true

log
log "========== mediamtx log tail =========="
tail -160 "$MEDIAMTX_LOG" | tee -a "$LOG" || true

log
log "========== key abnormal counters =========="

# Only scan raw runtime logs.
# Do not scan 22_1.log / summary.txt / summary_fixed.txt / fifo,
# otherwise the counter labels themselves will be counted as abnormalities.
LOG_FILES=(
  "$DETECT_LOG"
  "$FFMPEG_LOG"
  "$MEDIAMTX_LOG"
  "$FFPROBE_LOG"
)

count_pattern() {
    local pattern="$1"
    grep -h -F "$pattern" "${LOG_FILES[@]}" 2>/dev/null | wc -l | tr -d ' '
}

count_pattern_i() {
    local pattern="$1"
    grep -h -i -F "$pattern" "${LOG_FILES[@]}" 2>/dev/null | wc -l | tr -d ' '
}

RGA_COLORFILL_CNT=$(count_pattern "RGA_COLORFILL")
RGA_FAIL_CNT=$(count_pattern "Failed to call RockChipRga")
XRUN_CNT=$(count_pattern_i "xrun")
QUEUE_BLOCK_CNT=$(count_pattern "Thread message queue blocking")
TIMESTAMP_UNSET_CNT=$(count_pattern "Timestamps are unset")
BROKEN_PIPE_CNT=$(count_pattern "Broken pipe")

{
    echo "FFPROBE_H264_AAC_OK          : $FFPROBE_OK"
    echo "RGA_COLORFILL                : $RGA_COLORFILL_CNT"
    echo "Failed to call RockChipRga   : $RGA_FAIL_CNT"
    echo "xrun                         : $XRUN_CNT"
    echo "Thread message queue blocking: $QUEUE_BLOCK_CNT"
    echo "Timestamps are unset         : $TIMESTAMP_UNSET_CNT"
    echo "Broken pipe                  : $BROKEN_PIPE_CNT"
} | tee "$OUT_DIR/summary.txt" | tee -a "$LOG"

log
log "========== output files =========="
find "$OUT_DIR" -maxdepth 1 -type f -printf "%p %k KB\n" | sort | tee -a "$LOG"

log
log "========== exp22-1 done =========="
log "OUT_DIR: $OUT_DIR"

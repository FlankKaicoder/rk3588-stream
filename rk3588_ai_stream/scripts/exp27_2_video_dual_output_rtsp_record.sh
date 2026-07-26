#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.."

WIDTH="${1:-1280}"
HEIGHT="${2:-720}"
FPS="${3:-30}"
FRAMES="${4:-300}"
AUDIO_DEV="${5:-hw:2,0}"
AUDIO_RATE="${6:-48000}"
AUDIO_CH="${7:-2}"
STREAM_PATH="${8:-exp27_2_video_dual_output}"

MODEL="models/yolo11.rknn"
VIDEO_DEV="/dev/video11"
BITRATE=4000000

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="output/exp27_2_video_dual_output_${FRAMES}f_${TS}"

SRC_FIFO="$OUT_DIR/mpp_h264_source.fifo"
RTSP_FIFO="$OUT_DIR/rtsp_h264.fifo"

H264_FILE="$OUT_DIR/realtime_detect_record.h264"
PTS_CSV="$SRC_FIFO.pts.csv"
SYNC_META="$SRC_FIFO.sync_meta.csv"
PROFILE="$OUT_DIR/profile.csv"

MEDIAMTX_CFG="$OUT_DIR/mediamtx.yml"
MEDIAMTX_LOG="$OUT_DIR/mediamtx.log"
FFMPEG_LOG="$OUT_DIR/ffmpeg_av_rtsp.log"
DETECT_LOG="$OUT_DIR/detect.log"
TEE_LOG="$OUT_DIR/tee.log"
FFPROBE_LOG="$OUT_DIR/ffprobe_rtsp.log"
ABNORMAL="$OUT_DIR/abnormal.txt"
SUMMARY="$OUT_DIR/summary.txt"

BOARD_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
RTSP_LOCAL="rtsp://127.0.0.1:8554/${STREAM_PATH}"
RTSP_LAN="rtsp://${BOARD_IP}:8554/${STREAM_PATH}"

MEDIAMTX_PID=""
FFMPEG_PID=""
TEE_PID=""
DETECT_PID=""

mkdir -p "$OUT_DIR"

log()
{
    echo "[$(date '+%F %T')] $*"
}

cleanup()
{
    set +e

    if [ -n "$DETECT_PID" ] && kill -0 "$DETECT_PID" 2>/dev/null; then
        kill -TERM "$DETECT_PID" 2>/dev/null || true
        wait "$DETECT_PID" 2>/dev/null || true
    fi

    if [ -n "$TEE_PID" ] && kill -0 "$TEE_PID" 2>/dev/null; then
        kill -TERM "$TEE_PID" 2>/dev/null || true
        wait "$TEE_PID" 2>/dev/null || true
    fi

    if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill -TERM "$FFMPEG_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "$MEDIAMTX_PID" ] && kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
        kill -TERM "$MEDIAMTX_PID" 2>/dev/null || true
        wait "$MEDIAMTX_PID" 2>/dev/null || true
    fi

    rm -f "$SRC_FIFO" "$RTSP_FIFO"
}

trap cleanup EXIT INT TERM

###############################################################################
# Precheck
###############################################################################

[ -f "$MODEL" ] || {
    echo "ERROR: missing $MODEL"
    exit 1
}

[ -e "$VIDEO_DEV" ] || {
    echo "ERROR: missing $VIDEO_DEV"
    exit 1
}

[ -x build/exp21_detect_mpp_encode_async ] || {
    echo "ERROR: missing build/exp21_detect_mpp_encode_async"
    exit 1
}

[ -x tools/mediamtx/mediamtx ] || {
    echo "ERROR: missing tools/mediamtx/mediamtx"
    exit 1
}

command -v ffmpeg >/dev/null 2>&1 || {
    echo "ERROR: ffmpeg not found"
    exit 1
}

command -v ffprobe >/dev/null 2>&1 || {
    echo "ERROR: ffprobe not found"
    exit 1
}

###############################################################################
# Runtime environment
###############################################################################

export RGA_LOG_LEVEL=0
export RGA_DEBUG=0

for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -e "$governor" ] || continue

    if [ -w "$governor" ]; then
        echo performance > "$governor" || true
    elif command -v sudo >/dev/null 2>&1; then
        echo performance |
            sudo tee "$governor" >/dev/null 2>&1 || true
    fi
done

echo "============================================================"
echo " Experiment 27-2: Video Dual Output"
echo "============================================================"
echo "out dir     : $OUT_DIR"
echo "frames      : $FRAMES"
echo "video       : ${WIDTH}x${HEIGHT}@${FPS}"
echo "audio       : ${AUDIO_DEV} ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
echo "H264 record : $H264_FILE"
echo "RTSP        : $RTSP_LAN"
echo

###############################################################################
# Avoid stale processes
###############################################################################

pkill -f "ffmpeg.*${STREAM_PATH}" 2>/dev/null || true
pkill -f "mediamtx.*${MEDIAMTX_CFG}" 2>/dev/null || true

###############################################################################
# FIFOs
###############################################################################

rm -f "$SRC_FIFO" "$RTSP_FIFO"
mkfifo "$SRC_FIFO"
mkfifo "$RTSP_FIFO"

###############################################################################
# MediaMTX
###############################################################################

cat > "$MEDIAMTX_CFG" <<EOF
logLevel: info

rtsp: true
rtspAddress: :8554

rtmp: false
hls: false
webrtc: false
srt: false

paths:
  all_others:
EOF

tools/mediamtx/mediamtx "$MEDIAMTX_CFG" \
    > "$MEDIAMTX_LOG" 2>&1 &

MEDIAMTX_PID=$!

for _ in $(seq 1 30); do
    if ss -ltn 2>/dev/null | grep -q ':8554'; then
        break
    fi
    sleep 0.2
done

if ! kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    echo "ERROR: MediaMTX failed"
    cat "$MEDIAMTX_LOG"
    exit 1
fi

###############################################################################
# FFmpeg: RTSP branch
###############################################################################

ffmpeg \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -thread_queue_size 512 \
    -use_wallclock_as_timestamps 1 \
    -fflags +genpts \
    -f h264 \
    -framerate "$FPS" \
    -i "$RTSP_FIFO" \
    -thread_queue_size 1024 \
    -use_wallclock_as_timestamps 1 \
    -f alsa \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -i "$AUDIO_DEV" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a aac \
    -b:a 128k \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -f rtsp \
    -rtsp_transport tcp \
    "$RTSP_LOCAL" \
    > "$FFMPEG_LOG" 2>&1 &

FFMPEG_PID=$!

###############################################################################
# H.264 fan-out
#
# Input:
#   MPP source FIFO
#
# Outputs:
#   1. local H.264 file
#   2. RTSP branch FIFO
###############################################################################

tee "$H264_FILE" \
    < "$SRC_FIFO" \
    > "$RTSP_FIFO" \
    2> "$TEE_LOG" &

TEE_PID=$!

###############################################################################
# Detector: one camera + one RKNN + one MPP encoder
###############################################################################

build/exp21_detect_mpp_encode_async \
    "$MODEL" \
    "$VIDEO_DEV" \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$SRC_FIFO" \
    "$PROFILE" \
    > "$DETECT_LOG" 2>&1 &

DETECT_PID=$!

###############################################################################
# Wait for stream and run ffprobe while producer is alive
###############################################################################

for _ in $(seq 1 40); do
    if grep -q \
        "stream is available and online, 2 tracks" \
        "$MEDIAMTX_LOG" 2>/dev/null; then
        break
    fi

    if ! kill -0 "$DETECT_PID" 2>/dev/null; then
        break
    fi

    sleep 0.25
done

timeout 6 ffprobe \
    -v error \
    -rtsp_transport tcp \
    -show_entries \
      stream=index,codec_name,codec_type,width,height,sample_rate,channels \
    -of default=noprint_wrappers=1 \
    "$RTSP_LOCAL" \
    > "$FFPROBE_LOG" 2>&1 || true

###############################################################################
# Wait for detector and tee
###############################################################################

set +e
wait "$DETECT_PID"
DETECT_RC=$?
DETECT_PID=""

wait "$TEE_PID"
TEE_RC=$?
TEE_PID=""
set -e

sleep 2

if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    kill -TERM "$FFMPEG_PID" 2>/dev/null || true
fi

set +e
wait "$FFMPEG_PID"
FFMPEG_RC=$?
FFMPEG_PID=""
set -e

if kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    kill -TERM "$MEDIAMTX_PID" 2>/dev/null || true
fi

set +e
wait "$MEDIAMTX_PID"
MEDIAMTX_RC=$?
MEDIAMTX_PID=""
set -e

rm -f "$SRC_FIFO" "$RTSP_FIFO"
trap - EXIT INT TERM

###############################################################################
# H.264 integrity analysis
###############################################################################

python3 - "$PTS_CSV" "$H264_FILE" \
    > "$OUT_DIR/h264_size_check.txt" <<'PY'
import csv
import os
import sys

pts_csv = sys.argv[1]
h264_file = sys.argv[2]

print(f"pts_csv={pts_csv}")
print(f"h264_file={h264_file}")

if not os.path.isfile(pts_csv):
    print("RESULT=MISSING_PTS_CSV")
    raise SystemExit(0)

if not os.path.isfile(h264_file):
    print("RESULT=MISSING_H264_FILE")
    raise SystemExit(0)

with open(pts_csv, newline="") as f:
    rows = list(csv.DictReader(f))

packet_sum = 0

for row in rows:
    try:
        packet_sum += int(float(row.get("packet_size", "0")))
    except ValueError:
        pass

file_size = os.path.getsize(h264_file)
header_plus_other = file_size - packet_sum

print(f"rows={len(rows)}")
print(f"packet_size_sum={packet_sum}")
print(f"h264_file_size={file_size}")
print(f"header_plus_other_bytes={header_plus_other}")

if len(rows) > 0 and file_size >= packet_sum:
    print("RESULT=PASS_H264_FILE_COVERS_ALL_PACKETS")
else:
    print("RESULT=FAIL_H264_SIZE_CHECK")
PY

###############################################################################
# Abnormal scan
###############################################################################

{
    echo "detect.log:"
    grep -nEi \
      "select timeout|RGA_COLORFILL|Failed to call RockChipRga|Segmentation|failed|error|invalid|async_encode_failures|async_drop_frames" \
      "$DETECT_LOG" || true

    echo
    echo "tee.log:"
    grep -nEi \
      "broken pipe|failed|error|invalid" \
      "$TEE_LOG" || true

    echo
    echo "ffmpeg_av_rtsp.log:"
    grep -nEi \
      "xrun|overrun|underrun|Thread message queue blocking|Timestamps are unset|Non-monotonous|Broken pipe|failed|error|invalid" \
      "$FFMPEG_LOG" || true

    echo
    echo "mediamtx.log:"
    grep -nEi \
      "WAR|ERR|RTP packets lost|invalid FU-A|processing errors" \
      "$MEDIAMTX_LOG" || true
} > "$ABNORMAL"

###############################################################################
# Summary
###############################################################################

{
    echo "EXP27_2_OUT=$OUT_DIR"
    echo "DETECT_RC=$DETECT_RC"
    echo "TEE_RC=$TEE_RC"
    echo "FFMPEG_RC=$FFMPEG_RC"
    echo "MEDIAMTX_RC=$MEDIAMTX_RC"
    echo "FRAMES=$FRAMES"
    echo "H264_FILE=$H264_FILE"
    echo "PTS_CSV=$PTS_CSV"
    echo "SYNC_META=$SYNC_META"
    echo "PROFILE=$PROFILE"
    echo "RTSP_URL=$RTSP_LAN"

    echo
    echo "========== detector =========="
    grep -E \
      "frames[[:space:]]*:|wall_fps|async_encoded_frames|async_encode_failures|async_drop_frames|async_avg" \
      "$DETECT_LOG" || true

    echo
    echo "========== ffprobe =========="
    cat "$FFPROBE_LOG" || true

    echo
    echo "========== size check =========="
    cat "$OUT_DIR/h264_size_check.txt"

    echo
    echo "========== abnormal =========="
    cat "$ABNORMAL"
} | tee "$SUMMARY"

echo
echo "============================================================"
echo " Experiment 27-2 completed"
echo "============================================================"
echo "OUT_DIR : $OUT_DIR"
echo "RTSP    : $RTSP_LAN"
echo "H264    : $H264_FILE"
echo

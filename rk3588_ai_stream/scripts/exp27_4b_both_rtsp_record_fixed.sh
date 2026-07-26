#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.."

###############################################################################
# Arguments
###############################################################################

WIDTH="${1:-1280}"
HEIGHT="${2:-720}"
FPS="${3:-30}"
FRAMES="${4:-300}"

AUDIO_DEV="${5:-hw:2,0}"
AUDIO_RATE="${6:-48000}"
AUDIO_CH="${7:-2}"
PERIOD_FRAMES="${8:-1024}"

STREAM_PATH="${9:-exp27_4_both}"

MODEL="models/yolo11.rknn"
VIDEO_DEV="/dev/video11"

AUDIO_LEAD_MS="${AUDIO_LEAD_MS:-100}"
AUDIO_PAD_SEC="${AUDIO_PAD_SEC:-2}"

NOMINAL_VIDEO_SEC=$(
    python3 - "$FRAMES" "$FPS" <<'PY'
import math
import sys

frames = int(sys.argv[1])
fps = int(sys.argv[2])

print(int(math.ceil(frames / fps)))
PY
)

AUDIO_DURATION=$((NOMINAL_VIDEO_SEC + AUDIO_PAD_SEC))

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="output/exp27_4_both_${FRAMES}f_${TS}"

###############################################################################
# Paths
###############################################################################

VIDEO_SOURCE_FIFO="$OUT_DIR/video_source.fifo"
VIDEO_RTSP_FIFO="$OUT_DIR/video_rtsp.fifo"

AUDIO_SOURCE_FIFO="$OUT_DIR/audio_source.fifo"
AUDIO_RTSP_FIFO="$OUT_DIR/audio_rtsp.fifo"

H264_FILE="$OUT_DIR/detect_both.h264"
PTS_CSV="$VIDEO_SOURCE_FIFO.pts.csv"
SYNC_META="$VIDEO_SOURCE_FIFO.sync_meta.csv"
PROFILE="$OUT_DIR/profile.csv"

PCM_FILE="$OUT_DIR/audio_full_s16le.pcm"
AUDIO_TS="$OUT_DIR/audio_ts.csv"

VIDEO_MP4="$OUT_DIR/video_v4l2_pts.mp4"
AUDIO_M4A="$OUT_DIR/audio_trimmed_aac.m4a"
AV_MP4="$OUT_DIR/av_both_v4l2_alsa.mp4"

MEDIAMTX_CFG="$OUT_DIR/mediamtx.yml"

MASTER_LOG="$OUT_DIR/run.log"
DETECT_LOG="$OUT_DIR/video_detect.log"
VIDEO_TEE_LOG="$OUT_DIR/video_tee.log"
AUDIO_CAPTURE_LOG="$OUT_DIR/audio_capture.log"
AUDIO_TEE_LOG="$OUT_DIR/audio_tee.log"

FFMPEG_RTSP_LOG="$OUT_DIR/ffmpeg_rtsp.log"
MEDIAMTX_LOG="$OUT_DIR/mediamtx.log"
RTSP_PROBE="$OUT_DIR/ffprobe_rtsp.txt"

VIDEO_MUX_LOG="$OUT_DIR/video_mux.log"
AUDIO_ENCODE_LOG="$OUT_DIR/audio_encode.log"
AV_MUX_LOG="$OUT_DIR/av_mux.log"
DECODE_LOG="$OUT_DIR/decode_check.log"
AV_PROBE="$OUT_DIR/ffprobe_av.txt"

PROCESS_SNAPSHOT="$OUT_DIR/process_snapshot.txt"
H264_CHECK="$OUT_DIR/h264_size_check.txt"
SYNC_PLAN="$OUT_DIR/sync_plan.txt"
LOCAL_VALIDATION="$OUT_DIR/local_av_validation.txt"
ABNORMAL="$OUT_DIR/abnormal.txt"
SUMMARY="$OUT_DIR/summary.txt"

BOARD_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
RTSP_LOCAL="rtsp://127.0.0.1:8554/${STREAM_PATH}"
RTSP_LAN="rtsp://${BOARD_IP}:8554/${STREAM_PATH}"

###############################################################################
# PIDs and cleanup
###############################################################################

MEDIAMTX_PID=""
FFMPEG_PID=""

VIDEO_TEE_PID=""
AUDIO_TEE_PID=""

DETECT_PID=""
AUDIO_CAPTURE_PID=""

mkdir -p "$OUT_DIR"

log()
{
    echo "[$(date '+%F %T')] $*" | tee -a "$MASTER_LOG"
}

cleanup()
{
    set +e

    for pid in \
        "$DETECT_PID" \
        "$AUDIO_CAPTURE_PID" \
        "$VIDEO_TEE_PID" \
        "$AUDIO_TEE_PID" \
        "$FFMPEG_PID" \
        "$MEDIAMTX_PID"
    do
        [ -n "$pid" ] || continue

        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    sleep 1

    for pid in \
        "$DETECT_PID" \
        "$AUDIO_CAPTURE_PID" \
        "$VIDEO_TEE_PID" \
        "$AUDIO_TEE_PID" \
        "$FFMPEG_PID" \
        "$MEDIAMTX_PID"
    do
        [ -n "$pid" ] || continue

        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi

        wait "$pid" 2>/dev/null || true
    done

    rm -f \
        "$VIDEO_SOURCE_FIFO" \
        "$VIDEO_RTSP_FIFO" \
        "$AUDIO_SOURCE_FIFO" \
        "$AUDIO_RTSP_FIFO"
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

for exe in \
    build/exp21_detect_mpp_encode_async \
    build/exp24_mp4_mux_from_pts \
    build/exp26_alsa_pcm_capture_ts \
    tools/mediamtx/mediamtx
do
    [ -x "$exe" ] || {
        echo "ERROR: missing executable: $exe"
        exit 1
    }
done

for cmd in \
    ffmpeg \
    ffprobe \
    python3 \
    tee \
    timeout
do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: command not found: $cmd"
        exit 1
    }
done

for value in \
    "$WIDTH" \
    "$HEIGHT" \
    "$FPS" \
    "$FRAMES" \
    "$AUDIO_RATE" \
    "$AUDIO_CH" \
    "$PERIOD_FRAMES"
do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: invalid positive integer: $value"
        exit 1
    }
done

###############################################################################
# Runtime environment
###############################################################################

export RGA_LOG_LEVEL=0
export RGA_DEBUG=0

for governor in \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
do
    [ -e "$governor" ] || continue

    if [ -w "$governor" ]; then
        echo performance > "$governor" || true
    elif command -v sudo >/dev/null 2>&1; then
        echo performance |
            sudo tee "$governor" >/dev/null 2>&1 || true
    fi
done

###############################################################################
# Header
###############################################################################

{
    echo "============================================================"
    echo " Experiment 27-4b: Fixed RTSP + Local MP4"
    echo "============================================================"
    echo "out dir            : $OUT_DIR"
    echo "video              : ${WIDTH}x${HEIGHT}@${FPS}"
    echo "frames             : $FRAMES"
    echo "nominal video sec  : $NOMINAL_VIDEO_SEC"
    echo "audio device       : $AUDIO_DEV"
    echo "audio              : ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
    echo "period frames      : $PERIOD_FRAMES"
    echo "audio lead         : ${AUDIO_LEAD_MS}ms"
    echo "audio duration     : ${AUDIO_DURATION}s"
    echo "RTSP               : $RTSP_LAN"
    echo "local AV MP4       : $AV_MP4"
    echo
} | tee "$MASTER_LOG"

###############################################################################
# Stop stale final processes
###############################################################################

pkill -f "ffmpeg.*${STREAM_PATH}" 2>/dev/null || true
pkill -f "mediamtx.*${MEDIAMTX_CFG}" 2>/dev/null || true

###############################################################################
# FIFOs
###############################################################################

rm -f \
    "$VIDEO_SOURCE_FIFO" \
    "$VIDEO_RTSP_FIFO" \
    "$AUDIO_SOURCE_FIFO" \
    "$AUDIO_RTSP_FIFO"

mkfifo \
    "$VIDEO_SOURCE_FIFO" \
    "$VIDEO_RTSP_FIFO" \
    "$AUDIO_SOURCE_FIFO" \
    "$AUDIO_RTSP_FIFO"

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

log "Start MediaMTX."

tools/mediamtx/mediamtx "$MEDIAMTX_CFG" \
    > "$MEDIAMTX_LOG" 2>&1 &

MEDIAMTX_PID=$!

for _ in $(seq 1 40); do
    if ss -ltn 2>/dev/null |
       grep -q ':8554'; then
        break
    fi

    sleep 0.2
done

if ! kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    log "ERROR: MediaMTX failed to start."
    cat "$MEDIAMTX_LOG"
    exit 1
fi

###############################################################################
# FFmpeg live RTSP muxer
#
# It does not open /dev/video11 or hw:2,0.
# It only reads the two fan-out FIFOs.
###############################################################################

log "Start FFmpeg live H264 + PCM -> AAC + RTSP."

ffmpeg \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -thread_queue_size 1024 \
    -f s16le \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -i "$AUDIO_RTSP_FIFO" \
    -thread_queue_size 512 \
    -fflags +genpts \
    -f h264 \
    -framerate "$FPS" \
    -i "$VIDEO_RTSP_FIFO" \
    -map 1:v:0 \
    -map 0:a:0 \
    -c:v copy \
    -af "asetpts=N/SR/TB" \
    -c:a aac \
    -b:a 128k \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -f rtsp \
    -rtsp_transport tcp \
    "$RTSP_LOCAL" \
    > "$FFMPEG_RTSP_LOG" 2>&1 &

FFMPEG_PID=$!

###############################################################################
# Fan-out processes
###############################################################################

log "Start video fan-out."

tee "$H264_FILE" \
    < "$VIDEO_SOURCE_FIFO" \
    > "$VIDEO_RTSP_FIFO" \
    2> "$VIDEO_TEE_LOG" &

VIDEO_TEE_PID=$!

log "Start audio fan-out."

tee "$PCM_FILE" \
    < "$AUDIO_SOURCE_FIFO" \
    > "$AUDIO_RTSP_FIFO" \
    2> "$AUDIO_TEE_LOG" &

AUDIO_TEE_PID=$!

###############################################################################
# Start the single ALSA capture first
###############################################################################

log "Start the only ALSA capture process."

build/exp26_alsa_pcm_capture_ts \
    "$AUDIO_DEV" \
    "$AUDIO_RATE" \
    "$AUDIO_CH" \
    "$AUDIO_DURATION" \
    "$PERIOD_FRAMES" \
    "$AUDIO_SOURCE_FIFO" \
    "$AUDIO_TS" \
    > "$AUDIO_CAPTURE_LOG" 2>&1 &

AUDIO_CAPTURE_PID=$!

python3 - "$AUDIO_LEAD_MS" <<'PY'
import sys
import time

time.sleep(int(sys.argv[1]) / 1000.0)
PY

###############################################################################
# Start the single V4L2 / RKNN / MPP video pipeline
###############################################################################

log "Start the only V4L2 + RKNN + MPP process."

build/exp21_detect_mpp_encode_async \
    "$MODEL" \
    "$VIDEO_DEV" \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$VIDEO_SOURCE_FIFO" \
    "$PROFILE" \
    > "$DETECT_LOG" 2>&1 &

DETECT_PID=$!

###############################################################################
# Process/device proof
###############################################################################

sleep 1

{
    echo "========== date =========="
    date -Is

    echo
    echo "========== relevant processes =========="
    ps -ef |
        grep -E \
          "exp21_detect_mpp_encode_async|exp26_alsa_pcm_capture_ts|ffmpeg.*${STREAM_PATH}|tee.*detect_both|tee.*audio_full" |
        grep -v grep || true

    echo
    echo "========== video device users =========="
    if command -v fuser >/dev/null 2>&1; then
        fuser -v "$VIDEO_DEV" 2>&1 || true
    fi

    echo
    echo "========== sound device users =========="
    if command -v fuser >/dev/null 2>&1; then
        fuser -v /dev/snd/* 2>&1 || true
    fi

    echo
    echo "Expected:"
    echo "1. Only exp21_detect_mpp_encode_async opens $VIDEO_DEV."
    echo "2. Only exp26_alsa_pcm_capture_ts opens the PCM capture node."
    echo "3. FFmpeg reads video_rtsp.fifo and audio_rtsp.fifo."
} > "$PROCESS_SNAPSHOT"

###############################################################################
# Wait for RTSP and probe it while live
###############################################################################

for _ in $(seq 1 80); do
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
    > "$RTSP_PROBE" 2>&1 || true

###############################################################################
# Wait for video and audio sources
###############################################################################

set +e

wait "$DETECT_PID"
DETECT_RC=$?
DETECT_PID=""

wait "$VIDEO_TEE_PID"
VIDEO_TEE_RC=$?
VIDEO_TEE_PID=""

wait "$AUDIO_CAPTURE_PID"
AUDIO_CAPTURE_RC=$?
AUDIO_CAPTURE_PID=""

wait "$AUDIO_TEE_PID"
AUDIO_TEE_RC=$?
AUDIO_TEE_PID=""

set -e

###############################################################################
# Let FFmpeg finish after both FIFOs reach EOF
###############################################################################

FFMPEG_FORCED_STOP=0

for _ in $(seq 1 40); do
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        break
    fi

    sleep 0.25
done

if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    FFMPEG_FORCED_STOP=1
    kill -TERM "$FFMPEG_PID" 2>/dev/null || true
fi

set +e
wait "$FFMPEG_PID"
FFMPEG_RC=$?
FFMPEG_PID=""
set -e

###############################################################################
# Stop MediaMTX
###############################################################################

if kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    kill -TERM "$MEDIAMTX_PID" 2>/dev/null || true
fi

set +e
wait "$MEDIAMTX_PID"
MEDIAMTX_RC=$?
MEDIAMTX_PID=""
set -e

rm -f \
    "$VIDEO_SOURCE_FIFO" \
    "$VIDEO_RTSP_FIFO" \
    "$AUDIO_SOURCE_FIFO" \
    "$AUDIO_RTSP_FIFO"

trap - EXIT INT TERM

###############################################################################
# H264 file completeness
###############################################################################

python3 - \
    "$PTS_CSV" \
    "$H264_FILE" \
    > "$H264_CHECK" <<'PY'
import csv
import os
import sys

csv_path = sys.argv[1]
h264_path = sys.argv[2]

result = []

result.append(f"pts_csv={csv_path}")
result.append(f"h264_file={h264_path}")

if not os.path.isfile(csv_path):
    result.append("RESULT=FAIL_MISSING_PTS_CSV")
    print("\n".join(result))
    raise SystemExit(0)

if not os.path.isfile(h264_path):
    result.append("RESULT=FAIL_MISSING_H264")
    print("\n".join(result))
    raise SystemExit(0)

with open(csv_path, newline="") as f:
    rows = list(csv.DictReader(f))

packet_sum = 0

for row in rows:
    try:
        packet_sum += int(float(row["packet_size"]))
    except (KeyError, TypeError, ValueError):
        pass

file_size = os.path.getsize(h264_path)
extra_size = file_size - packet_sum

result.append(f"rows={len(rows)}")
result.append(f"packet_size_sum={packet_sum}")
result.append(f"h264_file_size={file_size}")
result.append(f"header_plus_other_bytes={extra_size}")

passed = (
    len(rows) > 0
    and packet_sum > 0
    and file_size >= packet_sum
)

if passed:
    result.append("RESULT=PASS_H264_FILE_COVERS_ALL_PACKETS")
else:
    result.append("RESULT=FAIL_H264_FILE_CHECK")

print("\n".join(result))
PY

###############################################################################
# Mux timestamped video-only MP4
###############################################################################

log "Mux timestamped video-only MP4."

build/exp24_mp4_mux_from_pts \
    "$H264_FILE" \
    "$PTS_CSV" \
    "$VIDEO_MP4" \
    "$WIDTH" \
    "$HEIGHT" \
    "$FPS" \
    > "$VIDEO_MUX_LOG" 2>&1

VIDEO_DURATION=$(
    ffprobe \
        -v error \
        -select_streams v:0 \
        -show_entries stream=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "$VIDEO_MP4" |
        head -1
)

[ -n "$VIDEO_DURATION" ] || {
    echo "ERROR: cannot obtain video duration"
    exit 1
}

###############################################################################
# Compute V4L2 / ALSA alignment
###############################################################################

python3 - \
    "$SYNC_META" \
    "$AUDIO_TS" \
    "$VIDEO_DURATION" \
    "$AUDIO_RATE" \
    "$SYNC_PLAN" \
    "$OUT_DIR/audio_trim_s.txt" <<'PY'
import csv
import statistics
import sys

sync_meta_path = sys.argv[1]
audio_ts_path = sys.argv[2]
video_duration_s = float(sys.argv[3])
audio_rate = int(sys.argv[4])
report_path = sys.argv[5]
trim_path = sys.argv[6]

with open(sync_meta_path, newline="") as f:
    sync_rows = list(csv.DictReader(f))

with open(audio_ts_path, newline="") as f:
    audio_rows = list(csv.DictReader(f))

if not sync_rows:
    raise SystemExit("empty video sync metadata")

if not audio_rows:
    raise SystemExit("empty audio timestamp metadata")

first_video_v4l2_ts_ns = int(
    float(sync_rows[0]["v4l2_ts_ns"])
)

encoder_delta_bad = 0

for row in sync_rows:
    try:
        delta = int(
            float(row["encoder_pts_minus_sync_pts_us"])
        )
    except (KeyError, TypeError, ValueError):
        encoder_delta_bad += 1
        continue

    if delta != 0:
        encoder_delta_bad += 1

audio_start_values = []

for row in audio_rows[:200]:
    try:
        value = int(
            float(row["audio_stream_start_est_ns"])
        )
    except (KeyError, TypeError, ValueError):
        continue

    if value > 0:
        audio_start_values.append(value)

if not audio_start_values:
    raise SystemExit(
        "no valid audio_stream_start_est_ns"
    )

audio_stream_start_est_ns = int(
    statistics.median(audio_start_values)
)

audio_total_frames = int(
    float(audio_rows[-1]["total_frames"])
)

audio_sample_duration_s = (
    audio_total_frames / audio_rate
)

audio_lead_s = (
    first_video_v4l2_ts_ns
    - audio_stream_start_est_ns
) / 1e9

audio_trim_s = max(0.0, audio_lead_s)

audio_after_trim_s = (
    audio_sample_duration_s - audio_trim_s
)

audio_tail_margin_s = (
    audio_after_trim_s - video_duration_s
)

passed = (
    audio_lead_s >= 0.0
    and audio_tail_margin_s >= 0.0
    and encoder_delta_bad == 0
)

lines = [
    f"first_video_v4l2_ts_ns={first_video_v4l2_ts_ns}",
    f"audio_stream_start_est_ns={audio_stream_start_est_ns}",
    f"audio_start_est_samples_used={len(audio_start_values)}",
    f"audio_lead_s={audio_lead_s:.6f}",
    f"audio_trim_s={audio_trim_s:.6f}",
    f"video_duration_s={video_duration_s:.6f}",
    f"audio_total_frames={audio_total_frames}",
    f"audio_sample_duration_s={audio_sample_duration_s:.6f}",
    f"audio_after_trim_s={audio_after_trim_s:.6f}",
    f"audio_tail_margin_s={audio_tail_margin_s:.6f}",
    f"video_sync_rows={len(sync_rows)}",
    f"encoder_pts_delta_bad_rows={encoder_delta_bad}",
]

if passed:
    lines.append(
        "RESULT=PASS_V4L2_ALSA_ALIGNMENT_PLAN"
    )
else:
    lines.append(
        "RESULT=FAIL_V4L2_ALSA_ALIGNMENT_PLAN"
    )

with open(report_path, "w") as f:
    f.write("\n".join(lines) + "\n")

with open(trim_path, "w") as f:
    f.write(f"{audio_trim_s:.6f}\n")
PY

AUDIO_TRIM=$(
    cat "$OUT_DIR/audio_trim_s.txt"
)

###############################################################################
# Encode aligned local AAC
###############################################################################

log "Encode timestamp-aligned AAC."

ffmpeg \
    -y \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -f s16le \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -i "$PCM_FILE" \
    -af \
      "atrim=start=${AUDIO_TRIM}:duration=${VIDEO_DURATION},asetpts=PTS-STARTPTS" \
    -c:a aac \
    -b:a 128k \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    "$AUDIO_M4A" \
    > "$AUDIO_ENCODE_LOG" 2>&1

###############################################################################
# Copy mux final local AV MP4
###############################################################################

log "Mux local H264 + AAC MP4."

ffmpeg \
    -y \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -i "$VIDEO_MP4" \
    -i "$AUDIO_M4A" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a copy \
    -movflags +faststart \
    "$AV_MP4" \
    > "$AV_MUX_LOG" 2>&1

###############################################################################
# Validate final local MP4
###############################################################################

ffprobe \
    -v error \
    -show_entries \
      stream=index,codec_name,codec_type,width,height,sample_rate,channels,time_base,start_time,duration,nb_frames \
    -show_entries \
      format=filename,duration,size,bit_rate \
    -of default=noprint_wrappers=1 \
    "$AV_MP4" \
    > "$AV_PROBE" 2>&1

ffmpeg \
    -nostdin \
    -hide_banner \
    -v error \
    -i "$AV_MP4" \
    -f null - \
    > "$DECODE_LOG" 2>&1 || true

python3 - \
    "$AV_MP4" \
    "$FRAMES" \
    "$AUDIO_RATE" \
    "$AUDIO_CH" \
    > "$LOCAL_VALIDATION" <<'PY'
import json
import subprocess
import sys

path = sys.argv[1]
expected_frames = int(sys.argv[2])
expected_rate = int(sys.argv[3])
expected_channels = int(sys.argv[4])

data = json.loads(
    subprocess.check_output(
        [
            "ffprobe",
            "-v", "error",
            "-show_streams",
            "-show_format",
            "-of", "json",
            path,
        ],
        text=True,
    )
)

video = None
audio = None

for stream in data.get("streams", []):
    if stream.get("codec_type") == "video":
        video = stream
    elif stream.get("codec_type") == "audio":
        audio = stream

lines = []

if video is None or audio is None:
    lines.append("RESULT=FAIL_MISSING_AV_STREAM")
    print("\n".join(lines))
    raise SystemExit(0)

video_duration = float(video.get("duration", 0.0))
audio_duration = float(audio.get("duration", 0.0))

video_start = float(video.get("start_time", 0.0))
audio_start = float(audio.get("start_time", 0.0))

duration_delta = abs(
    video_duration - audio_duration
)

nb_frames = int(video.get("nb_frames", 0) or 0)

lines.extend(
    [
        f"video_codec={video.get('codec_name', '')}",
        f"audio_codec={audio.get('codec_name', '')}",
        f"video_start_time={video_start:.6f}",
        f"audio_start_time={audio_start:.6f}",
        f"video_duration_s={video_duration:.6f}",
        f"audio_duration_s={audio_duration:.6f}",
        f"duration_delta_s={duration_delta:.6f}",
        f"video_nb_frames={nb_frames}",
        f"audio_sample_rate={audio.get('sample_rate', '')}",
        f"audio_channels={audio.get('channels', '')}",
    ]
)

passed = (
    video.get("codec_name") == "h264"
    and audio.get("codec_name") == "aac"
    and nb_frames == expected_frames
    and str(audio.get("sample_rate")) == str(expected_rate)
    and int(audio.get("channels", 0)) == expected_channels
    and abs(video_start) < 0.001
    and abs(audio_start) < 0.001
    and duration_delta < 0.050
)

if passed:
    lines.append(
        "RESULT=PASS_LOCAL_TIMESTAMP_ALIGNED_AV_MP4"
    )
else:
    lines.append(
        "RESULT=FAIL_LOCAL_AV_MP4_VALIDATION"
    )

print("\n".join(lines))
PY

###############################################################################
# Abnormal scan
###############################################################################

{
    echo "video_detect.log:"
    grep -nEi \
      "select timeout|RGA_COLORFILL|Failed to call RockChipRga|Segmentation|failed|error|invalid|negative|non-positive" \
      "$DETECT_LOG" || true

    echo
    echo "video_tee.log:"
    grep -nEi \
      "broken pipe|failed|error|invalid" \
      "$VIDEO_TEE_LOG" || true

    echo
    echo "audio_capture.log:"
    grep -nEi \
      "xrun|overrun|underrun|unrecovered|failed|error|invalid|cannot|timeout" \
      "$AUDIO_CAPTURE_LOG" || true

    echo
    echo "audio_tee.log:"
    grep -nEi \
      "broken pipe|failed|error|invalid" \
      "$AUDIO_TEE_LOG" || true

    echo
    echo "ffmpeg_rtsp.log:"
    grep -nEi \
      "xrun|overrun|underrun|Thread message queue blocking|Timestamps are unset|Non-monotonous|Broken pipe|failed|error|invalid" \
      "$FFMPEG_RTSP_LOG" || true

    echo
    echo "mediamtx.log:"
    grep -nEi \
      "WAR|ERR|RTP packets lost|invalid FU-A|processing errors" \
      "$MEDIAMTX_LOG" || true

    echo
    echo "video_mux.log:"
    grep -nEi \
      "failed|error|invalid|negative|non-positive" \
      "$VIDEO_MUX_LOG" || true

    echo
    echo "audio_encode.log:"
    grep -nEi \
      "failed|error|invalid|Non-monotonous|Timestamps are unset" \
      "$AUDIO_ENCODE_LOG" || true

    echo
    echo "av_mux.log:"
    grep -nEi \
      "failed|error|invalid|Non-monotonous|Timestamps are unset" \
      "$AV_MUX_LOG" || true

    echo
    echo "decode_check.log:"
    cat "$DECODE_LOG"
} > "$ABNORMAL"

###############################################################################
# Final summary
###############################################################################

ENCODED=$(
    grep -E "async_encoded_frames" \
        "$DETECT_LOG" |
        tail -1 |
        awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

ENCODE_FAILURES=$(
    grep -E "async_encode_failures" \
        "$DETECT_LOG" |
        tail -1 |
        awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

DROPS=$(
    grep -E "async_drop_frames" \
        "$DETECT_LOG" |
        tail -1 |
        awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

WALL_FPS=$(
    grep -E "wall_fps" \
        "$DETECT_LOG" |
        tail -1 |
        awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

RTSP_H264_OK=0
RTSP_AAC_OK=0

grep -q "codec_name=h264" "$RTSP_PROBE" &&
    RTSP_H264_OK=1

grep -q "codec_name=aac" "$RTSP_PROBE" &&
    RTSP_AAC_OK=1

H264_RESULT=$(
    grep '^RESULT=' "$H264_CHECK" |
        tail -1 |
        cut -d= -f2-
)

SYNC_RESULT=$(
    grep '^RESULT=' "$SYNC_PLAN" |
        tail -1 |
        cut -d= -f2-
)

LOCAL_RESULT=$(
    grep '^RESULT=' "$LOCAL_VALIDATION" |
        tail -1 |
        cut -d= -f2-
)

ABNORMAL_HITS=$(
    grep -Ev \
      '^(video_detect|video_tee|audio_capture|audio_tee|ffmpeg_rtsp|mediamtx|video_mux|audio_encode|av_mux|decode_check)\.log:$|^$' \
      "$ABNORMAL" |
      wc -l
)

FINAL_RESULT="FAIL"

if [ "$DETECT_RC" -eq 0 ] &&
   [ "$VIDEO_TEE_RC" -eq 0 ] &&
   [ "$AUDIO_CAPTURE_RC" -eq 0 ] &&
   [ "$AUDIO_TEE_RC" -eq 0 ] &&
   [ "${ENCODED:-0}" -eq "$FRAMES" ] &&
   [ "${ENCODE_FAILURES:-1}" -eq 0 ] &&
   [ "${DROPS:-1}" -eq 0 ] &&
   [ "$RTSP_H264_OK" -eq 1 ] &&
   [ "$RTSP_AAC_OK" -eq 1 ] &&
   [ "$H264_RESULT" = "PASS_H264_FILE_COVERS_ALL_PACKETS" ] &&
   [ "$SYNC_RESULT" = "PASS_V4L2_ALSA_ALIGNMENT_PLAN" ] &&
   [ "$LOCAL_RESULT" = "PASS_LOCAL_TIMESTAMP_ALIGNED_AV_MP4" ] &&
   [ "$ABNORMAL_HITS" -eq 0 ]; then
    FINAL_RESULT="PASS_EXP27_4B_BOTH"
fi

{
    echo "EXP27_4_OUT=$OUT_DIR"
    echo "FINAL_RESULT=$FINAL_RESULT"
    echo
    echo "DETECT_RC=$DETECT_RC"
    echo "VIDEO_TEE_RC=$VIDEO_TEE_RC"
    echo "AUDIO_CAPTURE_RC=$AUDIO_CAPTURE_RC"
    echo "AUDIO_TEE_RC=$AUDIO_TEE_RC"
    echo "FFMPEG_RC=$FFMPEG_RC"
    echo "FFMPEG_FORCED_STOP=$FFMPEG_FORCED_STOP"
    echo "MEDIAMTX_RC=$MEDIAMTX_RC"
    echo
    echo "FRAMES=$FRAMES"
    echo "ASYNC_ENCODED=$ENCODED"
    echo "ASYNC_FAILURES=$ENCODE_FAILURES"
    echo "ASYNC_DROPS=$DROPS"
    echo "WALL_FPS=$WALL_FPS"
    echo
    echo "RTSP_H264_OK=$RTSP_H264_OK"
    echo "RTSP_AAC_OK=$RTSP_AAC_OK"
    echo "RTSP_URL=$RTSP_LAN"
    echo
    echo "H264_RESULT=$H264_RESULT"
    echo "SYNC_RESULT=$SYNC_RESULT"
    echo "LOCAL_RESULT=$LOCAL_RESULT"
    echo "ABNORMAL_HITS=$ABNORMAL_HITS"
    echo
    echo "H264_FILE=$H264_FILE"
    echo "PCM_FILE=$PCM_FILE"
    echo "VIDEO_MP4=$VIDEO_MP4"
    echo "AUDIO_M4A=$AUDIO_M4A"
    echo "AV_MP4=$AV_MP4"

    echo
    echo "========== H264 check =========="
    cat "$H264_CHECK"

    echo
    echo "========== sync plan =========="
    cat "$SYNC_PLAN"

    echo
    echo "========== RTSP streams =========="
    cat "$RTSP_PROBE"

    echo
    echo "========== local AV validation =========="
    cat "$LOCAL_VALIDATION"

    echo
    echo "========== process snapshot =========="
    cat "$PROCESS_SNAPSHOT"

    echo
    echo "========== abnormal =========="
    cat "$ABNORMAL"
} | tee "$SUMMARY"

echo
echo "============================================================"
echo " Experiment 27-4b completed"
echo "============================================================"
echo "RESULT   : $FINAL_RESULT"
echo "OUT_DIR  : $OUT_DIR"
echo "RTSP     : $RTSP_LAN"
echo "LOCAL MP4: $AV_MP4"
echo

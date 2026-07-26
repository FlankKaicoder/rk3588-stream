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
PERIOD_FRAMES="${8:-256}"

STREAM_PATH="${9:-exp27_4c_both_spool}"

MODEL="models/yolo11.rknn"
VIDEO_DEV="/dev/video11"

AUDIO_LEAD_MS="${AUDIO_LEAD_MS:-500}"
AUDIO_PAD_SEC="${AUDIO_PAD_SEC:-2}"

VIDEO_SEC_CEIL=$(
python3 - "$FRAMES" "$FPS" <<'PY'
import math
import sys
print(math.ceil(int(sys.argv[1]) / int(sys.argv[2])))
PY
)

AUDIO_DURATION=$((VIDEO_SEC_CEIL + AUDIO_PAD_SEC))

TS="$(date +%Y%m%d_%H%M%S)"
OUT="output/exp27_4c_both_spool_${FRAMES}f_${TS}"

H264="$OUT/detect_both.h264"
PTS_CSV="$H264.pts.csv"
SYNC_META="$H264.sync_meta.csv"
PROFILE="$OUT/profile.csv"

PCM="$OUT/audio_full_s16le.pcm"
AUDIO_TS="$OUT/audio_ts.csv"

VIDEO_MP4="$OUT/video_v4l2_pts.mp4"
AUDIO_M4A="$OUT/audio_trimmed_aac.m4a"
AV_MP4="$OUT/av_both_v4l2_alsa.mp4"

MEDIAMTX_CFG="$OUT/mediamtx.yml"
MEDIAMTX_LOG="$OUT/mediamtx.log"
FFMPEG_LOG="$OUT/ffmpeg_rtsp.log"
RTSP_PROBE="$OUT/ffprobe_rtsp.txt"

VIDEO_LOG="$OUT/video_detect.log"
AUDIO_LOG="$OUT/audio_capture.log"
VIDEO_MUX_LOG="$OUT/video_mux.log"
AUDIO_ENCODE_LOG="$OUT/audio_encode.log"
AV_MUX_LOG="$OUT/av_mux.log"
DECODE_LOG="$OUT/decode_check.log"

SYNC_PLAN="$OUT/sync_plan.txt"
LOCAL_CHECK="$OUT/local_av_validation.txt"
ABNORMAL="$OUT/abnormal.txt"
SUMMARY="$OUT/summary.txt"

BOARD_IP="$(hostname -I | awk '{print $1}')"
RTSP_LOCAL="rtsp://127.0.0.1:8554/$STREAM_PATH"
RTSP_LAN="rtsp://$BOARD_IP:8554/$STREAM_PATH"

MEDIAMTX_PID=""
FFMPEG_PID=""
VIDEO_PID=""
AUDIO_PID=""

mkdir -p "$OUT"

cleanup()
{
    set +e

    for pid in \
        "$VIDEO_PID" \
        "$AUDIO_PID" \
        "$FFMPEG_PID" \
        "$MEDIAMTX_PID"
    do
        [ -n "$pid" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 1

    for pid in \
        "$VIDEO_PID" \
        "$AUDIO_PID" \
        "$FFMPEG_PID" \
        "$MEDIAMTX_PID"
    do
        [ -n "$pid" ] || continue
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}

trap cleanup EXIT INT TERM

for exe in \
    build/exp21_detect_mpp_encode_async \
    build/exp24_mp4_mux_from_pts \
    build/exp26_alsa_pcm_capture_ts \
    tools/mediamtx/mediamtx
do
    [ -x "$exe" ] || {
        echo "ERROR: missing $exe"
        exit 1
    }
done

for cmd in ffmpeg ffprobe python3 tail timeout; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: missing command $cmd"
        exit 1
    }
done

export RGA_LOG_LEVEL=0
export RGA_DEBUG=0

for governor in \
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
do
    [ -e "$governor" ] || continue

    if [ -w "$governor" ]; then
        echo performance > "$governor" || true
    else
        echo performance |
            sudo tee "$governor" >/dev/null 2>&1 || true
    fi
done

echo "============================================================"
echo " Experiment 27-4c: Spool Fan-out Both Mode"
echo "============================================================"
echo "out dir        : $OUT"
echo "video          : ${WIDTH}x${HEIGHT}@${FPS}"
echo "frames         : $FRAMES"
echo "audio          : $AUDIO_DEV ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
echo "audio lead     : ${AUDIO_LEAD_MS}ms"
echo "audio duration : ${AUDIO_DURATION}s"
echo "RTSP           : $RTSP_LAN"
echo

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

for _ in $(seq 1 40); do
    ss -ltn 2>/dev/null |
        grep -q ':8554' &&
        break

    sleep 0.2
done

kill -0 "$MEDIAMTX_PID" 2>/dev/null || {
    echo "ERROR: MediaMTX failed"
    cat "$MEDIAMTX_LOG"
    exit 1
}

###############################################################################
# Start single ALSA capture directly to a normal file
###############################################################################

: > "$PCM"
: > "$H264"

build/exp26_alsa_pcm_capture_ts \
    "$AUDIO_DEV" \
    "$AUDIO_RATE" \
    "$AUDIO_CH" \
    "$AUDIO_DURATION" \
    "$PERIOD_FRAMES" \
    "$PCM" \
    "$AUDIO_TS" \
    > "$AUDIO_LOG" 2>&1 &

AUDIO_PID=$!

python3 - "$AUDIO_LEAD_MS" <<'PY'
import sys
import time
time.sleep(int(sys.argv[1]) / 1000.0)
PY

###############################################################################
# Start single V4L2/RKNN/MPP pipeline directly to normal H264 file
###############################################################################

build/exp21_detect_mpp_encode_async \
    "$MODEL" \
    "$VIDEO_DEV" \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$H264" \
    "$PROFILE" \
    > "$VIDEO_LOG" 2>&1 &

VIDEO_PID=$!

###############################################################################
# Wait until both growing files contain data
###############################################################################

for _ in $(seq 1 100); do
    if [ -s "$H264" ] && [ -s "$PCM" ]; then
        break
    fi

    kill -0 "$VIDEO_PID" 2>/dev/null || break
    kill -0 "$AUDIO_PID" 2>/dev/null || break

    sleep 0.05
done

[ -s "$H264" ] || {
    echo "ERROR: H264 file has no data"
    exit 1
}

[ -s "$PCM" ] || {
    echo "ERROR: PCM file has no data"
    exit 1
}

###############################################################################
# Live RTSP branch reads growing files.
#
# Blocking in FFmpeg/tail can no longer block the producer programs.
###############################################################################

ffmpeg \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -thread_queue_size 1024 \
    -use_wallclock_as_timestamps 1 \
    -fflags +genpts \
    -f h264 \
    -framerate "$FPS" \
    -i <(
        tail \
            --pid="$VIDEO_PID" \
            --sleep-interval=0.05 \
            -c +1 \
            -f "$H264"
    ) \
    -thread_queue_size 2048 \
    -use_wallclock_as_timestamps 1 \
    -f s16le \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -i <(
        tail \
            --pid="$AUDIO_PID" \
            --sleep-interval=0.05 \
            -c +1 \
            -f "$PCM"
    ) \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -af "asetpts=N/SR/TB" \
    -c:a aac \
    -b:a 128k \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -shortest \
    -f rtsp \
    -rtsp_transport tcp \
    "$RTSP_LOCAL" \
    > "$FFMPEG_LOG" 2>&1 &

FFMPEG_PID=$!

###############################################################################
# Probe live stream
###############################################################################

for _ in $(seq 1 80); do
    if grep -q \
        "stream is available and online, 2 tracks" \
        "$MEDIAMTX_LOG" 2>/dev/null; then
        break
    fi

    kill -0 "$VIDEO_PID" 2>/dev/null || break
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
# Wait producers
###############################################################################

set +e

wait "$VIDEO_PID"
VIDEO_RC=$?
VIDEO_PID=""

wait "$AUDIO_PID"
AUDIO_RC=$?
AUDIO_PID=""

set -e

###############################################################################
# Wait live muxer
###############################################################################

for _ in $(seq 1 50); do
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

FFMPEG_FORCED_STOP=0

if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    FFMPEG_FORCED_STOP=1
    kill -TERM "$FFMPEG_PID" 2>/dev/null || true
fi

set +e
wait "$FFMPEG_PID"
FFMPEG_RC=$?
FFMPEG_PID=""
set -e

kill -TERM "$MEDIAMTX_PID" 2>/dev/null || true

set +e
wait "$MEDIAMTX_PID"
MEDIAMTX_RC=$?
MEDIAMTX_PID=""
set -e

trap - EXIT INT TERM

###############################################################################
# Video-only MP4 using real V4L2-derived PTS
###############################################################################

build/exp24_mp4_mux_from_pts \
    "$H264" \
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

###############################################################################
# Compute local V4L2/ALSA timestamp alignment
###############################################################################

XRUN_COUNT=$(
grep -ciE \
    "xrun|overrun|underrun" \
    "$AUDIO_LOG" || true
)

python3 - \
    "$SYNC_META" \
    "$AUDIO_TS" \
    "$VIDEO_DURATION" \
    "$AUDIO_RATE" \
    "$XRUN_COUNT" \
    "$SYNC_PLAN" \
    "$OUT/audio_trim_s.txt" <<'PY'
import csv
import statistics
import sys

sync_path = sys.argv[1]
audio_path = sys.argv[2]
video_duration = float(sys.argv[3])
rate = int(sys.argv[4])
xrun_count = int(sys.argv[5])
report_path = sys.argv[6]
trim_path = sys.argv[7]

with open(sync_path, newline="") as f:
    vrows = list(csv.DictReader(f))

with open(audio_path, newline="") as f:
    arows = list(csv.DictReader(f))

if not vrows:
    raise SystemExit("empty video sync metadata")

if not arows:
    raise SystemExit("empty audio timestamp metadata")

first_video_ns = int(float(vrows[0]["v4l2_ts_ns"]))

start_values = []

for row in arows[:200]:
    try:
        value = int(
            float(row["audio_stream_start_est_ns"])
        )
    except (KeyError, TypeError, ValueError):
        continue

    if value > 0:
        start_values.append(value)

if not start_values:
    raise SystemExit("no valid audio start estimate")

audio_start_ns = int(statistics.median(start_values))

audio_total_frames = int(
    float(arows[-1]["total_frames"])
)

audio_duration = audio_total_frames / rate
audio_lead = (first_video_ns - audio_start_ns) / 1e9
audio_trim = max(0.0, audio_lead)
tail_margin = audio_duration - audio_trim - video_duration

bad_video_pts = 0

for row in vrows:
    try:
        delta = int(
            float(row["encoder_pts_minus_sync_pts_us"])
        )
    except (KeyError, TypeError, ValueError):
        bad_video_pts += 1
        continue

    if delta != 0:
        bad_video_pts += 1

passed = (
    xrun_count == 0
    and audio_lead >= 0.0
    and tail_margin >= 0.0
    and bad_video_pts == 0
)

lines = [
    f"first_video_v4l2_ts_ns={first_video_ns}",
    f"audio_stream_start_est_ns={audio_start_ns}",
    f"audio_start_est_samples_used={len(start_values)}",
    f"audio_lead_s={audio_lead:.6f}",
    f"audio_trim_s={audio_trim:.6f}",
    f"video_duration_s={video_duration:.6f}",
    f"audio_total_frames={audio_total_frames}",
    f"audio_sample_duration_s={audio_duration:.6f}",
    f"audio_tail_margin_s={tail_margin:.6f}",
    f"video_sync_rows={len(vrows)}",
    f"encoder_pts_delta_bad_rows={bad_video_pts}",
    f"xrun_count={xrun_count}",
]

lines.append(
    "RESULT=PASS_V4L2_ALSA_ALIGNMENT_PLAN"
    if passed
    else "RESULT=FAIL_V4L2_ALSA_ALIGNMENT_PLAN"
)

open(report_path, "w").write(
    "\n".join(lines) + "\n"
)

open(trim_path, "w").write(
    f"{audio_trim:.6f}\n"
)
PY

AUDIO_TRIM=$(cat "$OUT/audio_trim_s.txt")

###############################################################################
# Encode timestamp-aligned AAC and mux final MP4
###############################################################################

ffmpeg \
    -y \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -f s16le \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -i "$PCM" \
    -af \
      "atrim=start=${AUDIO_TRIM}:duration=${VIDEO_DURATION},asetpts=PTS-STARTPTS" \
    -c:a aac \
    -b:a 128k \
    "$AUDIO_M4A" \
    > "$AUDIO_ENCODE_LOG" 2>&1

ffmpeg \
    -y \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -i "$VIDEO_MP4" \
    -i "$AUDIO_M4A" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c copy \
    -movflags +faststart \
    "$AV_MP4" \
    > "$AV_MUX_LOG" 2>&1

ffmpeg \
    -nostdin \
    -hide_banner \
    -v error \
    -i "$AV_MP4" \
    -f null - \
    > "$DECODE_LOG" 2>&1 || true

###############################################################################
# Final local MP4 validation
###############################################################################

python3 - \
    "$AV_MP4" \
    "$FRAMES" \
    "$LOCAL_CHECK" <<'PY'
import json
import subprocess
import sys

path = sys.argv[1]
expected_frames = int(sys.argv[2])
report = sys.argv[3]

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

video = next(
    (
        s for s in data["streams"]
        if s.get("codec_type") == "video"
    ),
    None,
)

audio = next(
    (
        s for s in data["streams"]
        if s.get("codec_type") == "audio"
    ),
    None,
)

lines = []

if video is None or audio is None:
    lines.append("RESULT=FAIL_MISSING_AV_STREAM")
else:
    vf = int(video.get("nb_frames", 0) or 0)
    vd = float(video.get("duration", 0))
    ad = float(audio.get("duration", 0))
    vs = float(video.get("start_time", 0))
    aus = float(audio.get("start_time", 0))
    delta = abs(vd - ad)

    lines.extend(
        [
            f"video_codec={video.get('codec_name')}",
            f"audio_codec={audio.get('codec_name')}",
            f"video_nb_frames={vf}",
            f"video_start_time={vs:.6f}",
            f"audio_start_time={aus:.6f}",
            f"video_duration_s={vd:.6f}",
            f"audio_duration_s={ad:.6f}",
            f"duration_delta_s={delta:.6f}",
        ]
    )

    passed = (
        video.get("codec_name") == "h264"
        and audio.get("codec_name") == "aac"
        and vf == expected_frames
        and abs(vs) < 0.001
        and abs(aus) < 0.001
        and delta < 0.050
    )

    lines.append(
        "RESULT=PASS_LOCAL_TIMESTAMP_ALIGNED_AV_MP4"
        if passed
        else "RESULT=FAIL_LOCAL_AV_MP4_VALIDATION"
    )

open(report, "w").write(
    "\n".join(lines) + "\n"
)
PY

###############################################################################
# Final counters
###############################################################################

ENCODED=$(
grep "async_encoded_frames" "$VIDEO_LOG" |
tail -1 |
awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

FAILURES=$(
grep "async_encode_failures" "$VIDEO_LOG" |
tail -1 |
awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

DROPS=$(
grep "async_drop_frames" "$VIDEO_LOG" |
tail -1 |
awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

WALL_FPS=$(
grep "wall_fps" "$VIDEO_LOG" |
tail -1 |
awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}'
)

RTSP_H264_OK=0
RTSP_AAC_OK=0

grep -q "codec_name=h264" "$RTSP_PROBE" &&
    RTSP_H264_OK=1

grep -q "codec_name=aac" "$RTSP_PROBE" &&
    RTSP_AAC_OK=1

SYNC_RESULT=$(
grep '^RESULT=' "$SYNC_PLAN" |
cut -d= -f2-
)

LOCAL_RESULT=$(
grep '^RESULT=' "$LOCAL_CHECK" |
cut -d= -f2-
)

{
    grep -nEi \
      "select timeout|RGA_COLORFILL|Failed to call RockChipRga|Segmentation|Broken pipe" \
      "$VIDEO_LOG" || true

    grep -nEi \
      "xrun|overrun|underrun" \
      "$AUDIO_LOG" || true

    grep -nEi \
      "Non-monotonous DTS|Timestamps are unset|Broken pipe|failed|error|invalid" \
      "$FFMPEG_LOG" || true

    cat "$DECODE_LOG"
} > "$ABNORMAL"

ABNORMAL_HITS=$(
grep -cve '^$' "$ABNORMAL" || true
)

FINAL_RESULT="FAIL"

if [ "$VIDEO_RC" -eq 0 ] &&
   [ "$AUDIO_RC" -eq 0 ] &&
   [ "${ENCODED:-0}" -eq "$FRAMES" ] &&
   [ "${FAILURES:-1}" -eq 0 ] &&
   [ "${DROPS:-1}" -eq 0 ] &&
   [ "$RTSP_H264_OK" -eq 1 ] &&
   [ "$RTSP_AAC_OK" -eq 1 ] &&
   [ "$SYNC_RESULT" = "PASS_V4L2_ALSA_ALIGNMENT_PLAN" ] &&
   [ "$LOCAL_RESULT" = "PASS_LOCAL_TIMESTAMP_ALIGNED_AV_MP4" ] &&
   [ "$ABNORMAL_HITS" -eq 0 ]; then
    FINAL_RESULT="PASS_EXP27_4C_BOTH"
fi

{
    echo "EXP27_4C_OUT=$OUT"
    echo "FINAL_RESULT=$FINAL_RESULT"
    echo
    echo "VIDEO_RC=$VIDEO_RC"
    echo "AUDIO_RC=$AUDIO_RC"
    echo "FFMPEG_RC=$FFMPEG_RC"
    echo "FFMPEG_FORCED_STOP=$FFMPEG_FORCED_STOP"
    echo "MEDIAMTX_RC=$MEDIAMTX_RC"
    echo
    echo "FRAMES=$FRAMES"
    echo "ASYNC_ENCODED=$ENCODED"
    echo "ASYNC_FAILURES=$FAILURES"
    echo "ASYNC_DROPS=$DROPS"
    echo "WALL_FPS=$WALL_FPS"
    echo
    echo "XRUN_COUNT=$XRUN_COUNT"
    echo "RTSP_H264_OK=$RTSP_H264_OK"
    echo "RTSP_AAC_OK=$RTSP_AAC_OK"
    echo "SYNC_RESULT=$SYNC_RESULT"
    echo "LOCAL_RESULT=$LOCAL_RESULT"
    echo "ABNORMAL_HITS=$ABNORMAL_HITS"
    echo
    echo "RTSP_URL=$RTSP_LAN"
    echo "H264=$H264"
    echo "PCM=$PCM"
    echo "AV_MP4=$AV_MP4"

    echo
    echo "========== sync plan =========="
    cat "$SYNC_PLAN"

    echo
    echo "========== local validation =========="
    cat "$LOCAL_CHECK"

    echo
    echo "========== RTSP streams =========="
    cat "$RTSP_PROBE"

    echo
    echo "========== abnormal =========="
    cat "$ABNORMAL"
} | tee "$SUMMARY"

echo
echo "============================================================"
echo " Experiment 27-4c completed"
echo "============================================================"
echo "RESULT   : $FINAL_RESULT"
echo "OUT_DIR  : $OUT"
echo "RTSP     : $RTSP_LAN"
echo "LOCAL MP4: $AV_MP4"

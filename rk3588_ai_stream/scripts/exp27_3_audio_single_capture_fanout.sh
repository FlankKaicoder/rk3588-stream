#!/usr/bin/env bash

set -Eeuo pipefail

cd "$(dirname "$0")/.."

DURATION="${1:-5}"
AUDIO_DEV="${2:-hw:2,0}"
AUDIO_RATE="${3:-48000}"
AUDIO_CH="${4:-2}"
PERIOD_FRAMES="${5:-256}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="output/exp27_3_audio_single_capture_${DURATION}s_${TS}"

SOURCE_FIFO="$OUT_DIR/audio_source.fifo"
LIVE_FIFO="$OUT_DIR/audio_live.fifo"

PCM_FILE="$OUT_DIR/audio_full_s16le.pcm"
AUDIO_TS="$OUT_DIR/audio_ts.csv"
AAC_FILE="$OUT_DIR/audio_live_branch_aac.m4a"

CAPTURE_LOG="$OUT_DIR/audio_capture.log"
TEE_LOG="$OUT_DIR/audio_tee.log"
FFMPEG_LOG="$OUT_DIR/ffmpeg_audio_live_branch.log"

PROCESS_LOG="$OUT_DIR/process_snapshot.txt"
ANALYSIS="$OUT_DIR/audio_analysis.txt"
FFPROBE_LOG="$OUT_DIR/ffprobe_aac.txt"
ABNORMAL="$OUT_DIR/abnormal.txt"
SUMMARY="$OUT_DIR/summary.txt"

CAPTURE_PID=""
TEE_PID=""
FFMPEG_PID=""

mkdir -p "$OUT_DIR"

cleanup()
{
    set +e

    if [ -n "$CAPTURE_PID" ] &&
       kill -0 "$CAPTURE_PID" 2>/dev/null; then
        kill -TERM "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi

    if [ -n "$TEE_PID" ] &&
       kill -0 "$TEE_PID" 2>/dev/null; then
        kill -TERM "$TEE_PID" 2>/dev/null || true
        wait "$TEE_PID" 2>/dev/null || true
    fi

    if [ -n "$FFMPEG_PID" ] &&
       kill -0 "$FFMPEG_PID" 2>/dev/null; then
        kill -TERM "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi

    rm -f "$SOURCE_FIFO" "$LIVE_FIFO"
}

trap cleanup EXIT INT TERM

###############################################################################
# Precheck
###############################################################################

[ -x build/exp26_alsa_pcm_capture_ts ] || {
    echo "ERROR: missing build/exp26_alsa_pcm_capture_ts"
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

command -v tee >/dev/null 2>&1 || {
    echo "ERROR: tee not found"
    exit 1
}

[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: duration must be positive integer"
    exit 1
}

###############################################################################
# Information
###############################################################################

echo "============================================================"
echo " Experiment 27-3: ALSA Single Capture Fan-out"
echo "============================================================"
echo "out dir       : $OUT_DIR"
echo "audio device  : $AUDIO_DEV"
echo "duration      : $DURATION s"
echo "sample rate   : $AUDIO_RATE"
echo "channels      : $AUDIO_CH"
echo "period frames : $PERIOD_FRAMES"
echo
echo "Architecture:"
echo "ALSA -> timestamp capture -> source FIFO -> tee"
echo "                                      |-> local PCM"
echo "                                      |-> live FIFO -> FFmpeg AAC"
echo

###############################################################################
# FIFO
###############################################################################

rm -f "$SOURCE_FIFO" "$LIVE_FIFO"
mkfifo "$SOURCE_FIFO"
mkfifo "$LIVE_FIFO"

###############################################################################
# Live consumer
#
# Important:
# FFmpeg does not open hw:2,0.
# FFmpeg reads raw PCM from LIVE_FIFO.
###############################################################################

ffmpeg \
    -y \
    -nostdin \
    -hide_banner \
    -loglevel info \
    -thread_queue_size 1024 \
    -f s16le \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -i "$LIVE_FIFO" \
    -map 0:a:0 \
    -c:a aac \
    -b:a 128k \
    -ar "$AUDIO_RATE" \
    -ac "$AUDIO_CH" \
    -movflags +faststart \
    "$AAC_FILE" \
    > "$FFMPEG_LOG" 2>&1 &

FFMPEG_PID=$!

###############################################################################
# PCM fan-out
#
# Input:
#   SOURCE_FIFO written by the only ALSA capture process
#
# Output:
#   1. local raw PCM file
#   2. LIVE_FIFO consumed by FFmpeg
###############################################################################

tee "$PCM_FILE" \
    < "$SOURCE_FIFO" \
    > "$LIVE_FIFO" \
    2> "$TEE_LOG" &

TEE_PID=$!

###############################################################################
# The only ALSA capture process
#
# Arguments:
#   device rate channels duration period output_pcm output_timestamp_csv
#
# output_pcm is deliberately a FIFO here.
###############################################################################

build/exp26_alsa_pcm_capture_ts \
    "$AUDIO_DEV" \
    "$AUDIO_RATE" \
    "$AUDIO_CH" \
    "$DURATION" \
    "$PERIOD_FRAMES" \
    "$SOURCE_FIFO" \
    "$AUDIO_TS" \
    > "$CAPTURE_LOG" 2>&1 &

CAPTURE_PID=$!

###############################################################################
# Runtime process snapshot
###############################################################################

sleep 1

{
    echo "========== date =========="
    date -Is

    echo
    echo "========== relevant processes =========="
    ps -ef |
        grep -E \
          "exp26_alsa_pcm_capture_ts|ffmpeg.*audio_live_branch|tee.*audio_full" |
        grep -v grep || true

    echo
    echo "========== sound device users =========="
    if command -v fuser >/dev/null 2>&1; then
        fuser -v /dev/snd/* 2>&1 || true
    else
        echo "fuser not installed"
    fi

    echo
    echo "Expected:"
    echo "Only exp26_alsa_pcm_capture_ts opens the ALSA capture device."
    echo "FFmpeg input must be s16le FIFO, not alsa hw:2,0."
} > "$PROCESS_LOG"

###############################################################################
# Wait for natural EOF
###############################################################################

set +e

wait "$CAPTURE_PID"
CAPTURE_RC=$?
CAPTURE_PID=""

wait "$TEE_PID"
TEE_RC=$?
TEE_PID=""

wait "$FFMPEG_PID"
FFMPEG_RC=$?
FFMPEG_PID=""

set -e

rm -f "$SOURCE_FIFO" "$LIVE_FIFO"
trap - EXIT INT TERM

###############################################################################
# Validate PCM and timestamp CSV
###############################################################################

python3 - \
    "$AUDIO_TS" \
    "$PCM_FILE" \
    "$AAC_FILE" \
    "$AUDIO_RATE" \
    "$AUDIO_CH" \
    > "$ANALYSIS" <<'PY'
import csv
import json
import os
import statistics
import subprocess
import sys

csv_path = sys.argv[1]
pcm_path = sys.argv[2]
aac_path = sys.argv[3]
rate = int(sys.argv[4])
channels = int(sys.argv[5])

bytes_per_sample = 2
bytes_per_frame = channels * bytes_per_sample

result = []

result.append(f"audio_ts_csv={csv_path}")
result.append(f"pcm_file={pcm_path}")
result.append(f"aac_file={aac_path}")

if not os.path.isfile(csv_path):
    result.append("RESULT=FAIL_MISSING_AUDIO_TS_CSV")
    print("\n".join(result))
    raise SystemExit(0)

if not os.path.isfile(pcm_path):
    result.append("RESULT=FAIL_MISSING_PCM")
    print("\n".join(result))
    raise SystemExit(0)

if not os.path.isfile(aac_path):
    result.append("RESULT=FAIL_MISSING_AAC")
    print("\n".join(result))
    raise SystemExit(0)

with open(csv_path, newline="") as f:
    rows = list(csv.DictReader(f))

result.append(f"timestamp_rows={len(rows)}")

if not rows:
    result.append("RESULT=FAIL_EMPTY_TIMESTAMP_CSV")
    print("\n".join(result))
    raise SystemExit(0)

total_frames = int(float(rows[-1]["total_frames"]))
pcm_size = os.path.getsize(pcm_path)
expected_pcm_size = total_frames * bytes_per_frame

pcm_duration = total_frames / rate

start_values = []

for row in rows[:200]:
    try:
        value = int(float(row["audio_stream_start_est_ns"]))
    except (KeyError, TypeError, ValueError):
        continue

    if value > 0:
        start_values.append(value)

start_median = (
    int(statistics.median(start_values))
    if start_values else -1
)

probe_cmd = [
    "ffprobe",
    "-v", "error",
    "-show_entries",
    "stream=codec_name,codec_type,sample_rate,channels,duration:"
    "format=duration,size",
    "-of", "json",
    aac_path,
]

probe = json.loads(
    subprocess.check_output(probe_cmd, text=True)
)

stream = probe.get("streams", [{}])[0]
fmt = probe.get("format", {})

aac_duration = float(
    stream.get("duration")
    or fmt.get("duration")
    or 0.0
)

duration_delta = abs(aac_duration - pcm_duration)

result.append(f"total_frames={total_frames}")
result.append(f"bytes_per_frame={bytes_per_frame}")
result.append(f"expected_pcm_size={expected_pcm_size}")
result.append(f"actual_pcm_size={pcm_size}")
result.append(f"pcm_size_match={int(pcm_size == expected_pcm_size)}")
result.append(f"pcm_duration_s={pcm_duration:.6f}")
result.append(f"aac_duration_s={aac_duration:.6f}")
result.append(f"duration_delta_s={duration_delta:.6f}")
result.append(
    f"audio_stream_start_est_ns_median={start_median}"
)
result.append(
    f"audio_start_est_samples_used={len(start_values)}"
)
result.append(
    f"aac_codec={stream.get('codec_name', '')}"
)
result.append(
    f"aac_sample_rate={stream.get('sample_rate', '')}"
)
result.append(
    f"aac_channels={stream.get('channels', '')}"
)

passed = (
    len(rows) > 0
    and total_frames > 0
    and pcm_size == expected_pcm_size
    and start_median > 0
    and stream.get("codec_name") == "aac"
    and str(stream.get("sample_rate")) == str(rate)
    and int(stream.get("channels", 0)) == channels
    and duration_delta < 0.150
)

if passed:
    result.append("RESULT=PASS_SINGLE_ALSA_CAPTURE_DUAL_FANOUT")
else:
    result.append("RESULT=FAIL_AUDIO_FANOUT_VALIDATION")

print("\n".join(result))
PY

###############################################################################
# ffprobe
###############################################################################

ffprobe \
    -v error \
    -show_entries \
      stream=index,codec_name,codec_type,sample_rate,channels,time_base,start_time,duration,nb_frames \
    -show_entries \
      format=filename,duration,size,bit_rate \
    -of default=noprint_wrappers=1 \
    "$AAC_FILE" \
    > "$FFPROBE_LOG" 2>&1

###############################################################################
# Abnormal scan
###############################################################################

{
    echo "audio_capture.log:"
    grep -nEi \
      "xrun|overrun|underrun|failed|error|invalid|cannot|timeout|unrecovered" \
      "$CAPTURE_LOG" || true

    echo
    echo "audio_tee.log:"
    grep -nEi \
      "broken pipe|failed|error|invalid" \
      "$TEE_LOG" || true

    echo
    echo "ffmpeg_audio_live_branch.log:"
    grep -nEi \
      "xrun|overrun|underrun|Thread message queue blocking|Non-monotonous|Timestamps are unset|Broken pipe|failed|error|invalid" \
      "$FFMPEG_LOG" || true
} > "$ABNORMAL"

###############################################################################
# Summary
###############################################################################

{
    echo "EXP27_3_OUT=$OUT_DIR"
    echo "CAPTURE_RC=$CAPTURE_RC"
    echo "TEE_RC=$TEE_RC"
    echo "FFMPEG_RC=$FFMPEG_RC"
    echo "DURATION=$DURATION"
    echo "AUDIO_DEV=$AUDIO_DEV"
    echo "AUDIO_RATE=$AUDIO_RATE"
    echo "AUDIO_CH=$AUDIO_CH"
    echo "PERIOD_FRAMES=$PERIOD_FRAMES"
    echo "PCM_FILE=$PCM_FILE"
    echo "AUDIO_TS=$AUDIO_TS"
    echo "AAC_FILE=$AAC_FILE"

    echo
    echo "========== analysis =========="
    cat "$ANALYSIS"

    echo
    echo "========== ffprobe =========="
    cat "$FFPROBE_LOG"

    echo
    echo "========== process snapshot =========="
    cat "$PROCESS_LOG"

    echo
    echo "========== abnormal =========="
    cat "$ABNORMAL"
} | tee "$SUMMARY"

echo
echo "============================================================"
echo " Experiment 27-3 completed"
echo "============================================================"
echo "OUT_DIR : $OUT_DIR"
echo

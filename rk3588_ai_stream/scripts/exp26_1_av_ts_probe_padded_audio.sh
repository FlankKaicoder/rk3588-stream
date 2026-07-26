#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

DURATION=${1:-60}
AUDIO_PAD=${2:-2}
WIDTH=${3:-1280}
HEIGHT=${4:-720}
FPS=${5:-30}
AUDIO_DEV=${6:-hw:2,0}
AUDIO_RATE=${7:-48000}
AUDIO_CH=${8:-2}
PERIOD_FRAMES=${9:-256}

AUDIO_DURATION=$((DURATION + AUDIO_PAD))
FRAMES=$((DURATION * FPS))

TS=$(date +%Y%m%d_%H%M%S)
OUT="output/exp26_1_av_ts_probe_padded_audio_${DURATION}s_pad${AUDIO_PAD}s_${TS}"
mkdir -p "$OUT"

echo "========== exp26-1 av timestamp probe with padded audio =========="
echo "out            : $OUT"
echo "video duration : $DURATION s"
echo "audio duration : $AUDIO_DURATION s"
echo "audio pad      : $AUDIO_PAD s"
echo "video          : /dev/video11 ${WIDTH}x${HEIGHT} ${FPS}fps frames=$FRAMES"
echo "audio          : $AUDIO_DEV ${AUDIO_RATE}Hz ${AUDIO_CH}ch period=$PERIOD_FRAMES"
echo

echo "========== build check =========="
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp26_v4l2_ts_probe exp26_alsa_ts_probe -j4
cd ..

echo
echo "========== clear dmesg =========="
sudo dmesg -C || true

echo
echo "========== start padded audio timestamp probe =========="
./build/exp26_alsa_ts_probe \
  "$AUDIO_DEV" \
  "$AUDIO_RATE" \
  "$AUDIO_CH" \
  "$AUDIO_DURATION" \
  "$PERIOD_FRAMES" \
  "$OUT/audio_ts.csv" \
  > "$OUT/audio_ts.log" 2>&1 &
AUDIO_PID=$!

sleep 0.20

echo "========== start video timestamp probe =========="
./build/exp26_v4l2_ts_probe \
  /dev/video11 \
  "$WIDTH" \
  "$HEIGHT" \
  "$FRAMES" \
  "$OUT/video_ts.csv" \
  > "$OUT/video_ts.log" 2>&1 &
VIDEO_PID=$!

set +e
wait "$VIDEO_PID"
VIDEO_RC=$?
wait "$AUDIO_PID"
AUDIO_RC=$?
set -e

echo "video_rc=$VIDEO_RC" | tee "$OUT/return_codes.txt"
echo "audio_rc=$AUDIO_RC" | tee -a "$OUT/return_codes.txt"

dmesg | tail -200 > "$OUT/dmesg_after.log" || true

python3 - "$OUT" "$FPS" "$AUDIO_RATE" "$DURATION" <<'PY'
import csv
import sys
from pathlib import Path

out = Path(sys.argv[1])
fps = float(sys.argv[2])
audio_rate = float(sys.argv[3])
target_video_duration = float(sys.argv[4])

def read_csv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))

def to_i(x, default=-1):
    try:
        return int(float(x))
    except Exception:
        return default

vrows = read_csv(out / "video_ts.csv")
arows = read_csv(out / "audio_ts.csv")

def choose_video_ref(row):
    v4l2 = to_i(row.get("v4l2_ts_ns", -1))
    dq = to_i(row.get("dqbuf_monotonic_ns", -1))
    if v4l2 > 0 and dq > 0 and abs(v4l2 - dq) < 10_000_000_000:
        return v4l2, "v4l2_ts_ns"
    return dq, "dqbuf_monotonic_ns"

def choose_audio_ref(row):
    h = to_i(row.get("alsa_htstamp_ns", -1))
    after = to_i(row.get("read_after_ns", -1))
    if h > 0 and after > 0 and abs(h - after) < 10_000_000_000:
        return h, "alsa_htstamp_ns"
    return after, "read_after_ns"

v_first, v_ref = choose_video_ref(vrows[0])
v_last, _ = choose_video_ref(vrows[-1])
a_first, a_ref = choose_audio_ref(arows[0])
a_last, _ = choose_audio_ref(arows[-1])

video_rows = len(vrows)
audio_chunks = len(arows)

video_nominal_duration_s = video_rows / fps
video_ts_first_to_last_s = (v_last - v_first) / 1e9
video_ts_effective_duration_s = video_ts_first_to_last_s + 1.0 / fps

audio_total_frames = to_i(arows[-1].get("total_frames", -1))
audio_sample_duration_s = audio_total_frames / audio_rate

audio_trim_s = max(0.0, (v_first - a_first) / 1e9)
audio_after_trim_s = audio_sample_duration_s - audio_trim_s
audio_tail_margin_s = audio_after_trim_s - video_nominal_duration_s

audio_extra_over_video_s = audio_sample_duration_s - target_video_duration
duration_after_trim_minus_video_s = audio_after_trim_s - video_nominal_duration_s

report = []
report.append(f"out={out}")
report.append(f"video_rows={video_rows}")
report.append(f"audio_chunks={audio_chunks}")
report.append(f"video_ref={v_ref}")
report.append(f"audio_ref={a_ref}")
report.append(f"first_video_ref_ns={v_first}")
report.append(f"first_audio_ref_ns={a_first}")
report.append(f"first_audio_minus_video_ms={(a_first - v_first)/1e6:.3f}")
report.append(f"audio_trim_s={audio_trim_s:.6f}")
report.append(f"video_nominal_duration_s={video_nominal_duration_s:.6f}")
report.append(f"video_ts_first_to_last_s={video_ts_first_to_last_s:.6f}")
report.append(f"video_ts_effective_duration_s={video_ts_effective_duration_s:.6f}")
report.append(f"audio_sample_duration_s={audio_sample_duration_s:.6f}")
report.append(f"audio_after_trim_s={audio_after_trim_s:.6f}")
report.append(f"audio_tail_margin_s={audio_tail_margin_s:.6f}")
report.append(f"audio_extra_over_target_video_s={audio_extra_over_video_s:.6f}")
report.append(f"duration_after_trim_minus_video_s={duration_after_trim_minus_video_s:.6f}")

if audio_tail_margin_s > 0:
    report.append("RESULT=PASS_AUDIO_CAN_COVER_FULL_VIDEO_AFTER_TRIM")
else:
    report.append("RESULT=FAIL_AUDIO_TOO_SHORT_AFTER_TRIM")

(out / "av_sync_report_corrected.txt").write_text("\n".join(report) + "\n")

with open(out / "av_sync_report_corrected.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow([
        "video_ref",
        "audio_ref",
        "first_audio_minus_video_ms",
        "audio_trim_s",
        "video_nominal_duration_s",
        "video_ts_effective_duration_s",
        "audio_sample_duration_s",
        "audio_after_trim_s",
        "audio_tail_margin_s",
        "result",
    ])
    w.writerow([
        v_ref,
        a_ref,
        f"{(a_first - v_first)/1e6:.3f}",
        f"{audio_trim_s:.6f}",
        f"{video_nominal_duration_s:.6f}",
        f"{video_ts_effective_duration_s:.6f}",
        f"{audio_sample_duration_s:.6f}",
        f"{audio_after_trim_s:.6f}",
        f"{audio_tail_margin_s:.6f}",
        "PASS" if audio_tail_margin_s > 0 else "FAIL",
    ])

print("\n".join(report))
PY

{
  echo "audio_ts.log:"
  grep -nEi "xrun|overrun|underrun|error|failed|invalid|cannot|timeout" "$OUT/audio_ts.log" || true
  echo
  echo "video_ts.log:"
  grep -nEi "select timeout|VIDIOC|error|failed|invalid|cannot" "$OUT/video_ts.log" || true
  echo
  echo "dmesg_after.log:"
  grep -nEi "xrun|underrun|overrun|select timeout|imx415|rkisp|rkcif|mipi|rga|error|failed" "$OUT/dmesg_after.log" || true
} > "$OUT/abnormal.txt"

echo
echo "========== corrected report =========="
cat "$OUT/av_sync_report_corrected.txt"

echo
echo "========== abnormal =========="
cat "$OUT/abnormal.txt"

echo
echo "EXP26_OUT=$OUT"

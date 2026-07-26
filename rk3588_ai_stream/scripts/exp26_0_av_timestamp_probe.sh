#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

DURATION=${1:-60}
WIDTH=${2:-1280}
HEIGHT=${3:-720}
FPS=${4:-30}
AUDIO_DEV=${5:-hw:2,0}
AUDIO_RATE=${6:-48000}
AUDIO_CH=${7:-2}
PERIOD_FRAMES=${8:-1024}

FRAMES=$((DURATION * FPS))
TS=$(date +%Y%m%d_%H%M%S)
OUT="output/exp26_0_av_ts_probe_${DURATION}s_${TS}"
mkdir -p "$OUT"

echo "========== exp26-0 av timestamp probe =========="
echo "out        : $OUT"
echo "duration   : $DURATION s"
echo "video      : /dev/video11 ${WIDTH}x${HEIGHT} ${FPS}fps frames=$FRAMES"
echo "audio      : $AUDIO_DEV ${AUDIO_RATE}Hz ${AUDIO_CH}ch period=$PERIOD_FRAMES"
echo

if [ ! -f /usr/include/alsa/asoundlib.h ]; then
  echo "ERROR: /usr/include/alsa/asoundlib.h not found."
  echo "Install it first:"
  echo "  sudo apt-get update"
  echo "  sudo apt-get install -y libasound2-dev"
  exit 2
fi

echo "========== build exp26 probes =========="
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp26_v4l2_ts_probe exp26_alsa_ts_probe -j4
cd ..

echo
echo "========== clear old dmesg =========="
sudo dmesg -C || true

echo
echo "========== start audio timestamp probe =========="
./build/exp26_alsa_ts_probe \
  "$AUDIO_DEV" \
  "$AUDIO_RATE" \
  "$AUDIO_CH" \
  "$DURATION" \
  "$PERIOD_FRAMES" \
  "$OUT/audio_ts.csv" \
  > "$OUT/audio_ts.log" 2>&1 &
AUDIO_PID=$!

# 给 ALSA 很短的启动时间，模拟实验25中音频先启动的情况。
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

echo
echo "========== dmesg tail =========="
dmesg | tail -200 > "$OUT/dmesg_after.log" || true

echo
echo "========== analyze timestamp csv =========="
python3 - "$OUT" "$FPS" "$AUDIO_RATE" <<'PY'
import csv
import math
import sys
from pathlib import Path

out = Path(sys.argv[1])
fps = float(sys.argv[2])
audio_rate = float(sys.argv[3])

video_csv = out / "video_ts.csv"
audio_csv = out / "audio_ts.csv"

def read_csv(path):
    if not path.exists():
        return []
    with path.open(newline="") as f:
        return list(csv.DictReader(f))

vrows = read_csv(video_csv)
arows = read_csv(audio_csv)

report = []
report.append(f"out={out}")
report.append(f"video_rows={len(vrows)}")
report.append(f"audio_chunks={len(arows)}")

def to_i(x, default=-1):
    try:
        return int(float(x))
    except Exception:
        return default

def choose_video_ref(row):
    v4l2 = to_i(row.get("v4l2_ts_ns", -1))
    dq = to_i(row.get("dqbuf_monotonic_ns", -1))
    # 若 V4L2 timestamp 与 DQBUF monotonic 差距非常大，说明不在同一时钟域，退回 DQBUF 时间。
    if v4l2 > 0 and dq > 0 and abs(v4l2 - dq) < 10_000_000_000:
        return v4l2, "v4l2_ts_ns"
    return dq, "dqbuf_monotonic_ns"

def choose_audio_ref(row):
    h = to_i(row.get("alsa_htstamp_ns", -1))
    after = to_i(row.get("read_after_ns", -1))
    # 若 ALSA htimestamp 与 read_after monotonic 差距非常大，说明不在同一时钟域，退回 read_after。
    if h > 0 and after > 0 and abs(h - after) < 10_000_000_000:
        return h, "alsa_htstamp_ns"
    return after, "read_after_ns"

if len(vrows) >= 2 and len(arows) >= 2:
    v_first, v_ref_name = choose_video_ref(vrows[0])
    v_last, _ = choose_video_ref(vrows[-1])

    a_first, a_ref_name = choose_audio_ref(arows[0])
    a_last, _ = choose_audio_ref(arows[-1])

    first_offset_ms = (a_first - v_first) / 1e6
    video_duration_s = (v_last - v_first) / 1e9

    audio_total_frames = to_i(arows[-1].get("total_frames", -1))
    audio_sample_duration_s = audio_total_frames / audio_rate if audio_total_frames > 0 else float("nan")
    audio_wall_duration_s = (a_last - a_first) / 1e9

    duration_diff_ms = (audio_sample_duration_s - video_duration_s) * 1000.0
    drift_ppm = ((audio_sample_duration_s - video_duration_s) / video_duration_s * 1e6) if video_duration_s > 0 else float("nan")

    video_intervals = []
    for r0, r1 in zip(vrows[:-1], vrows[1:]):
        t0, _ = choose_video_ref(r0)
        t1, _ = choose_video_ref(r1)
        if t1 > t0:
            video_intervals.append((t1 - t0) / 1e6)

    if video_intervals:
        avg_vi = sum(video_intervals) / len(video_intervals)
        min_vi = min(video_intervals)
        max_vi = max(video_intervals)
    else:
        avg_vi = min_vi = max_vi = float("nan")

    report.extend([
        f"video_ref={v_ref_name}",
        f"audio_ref={a_ref_name}",
        f"first_video_ref_ns={v_first}",
        f"first_audio_ref_ns={a_first}",
        f"first_audio_minus_video_ms={first_offset_ms:.3f}",
        f"video_duration_s={video_duration_s:.6f}",
        f"audio_sample_duration_s={audio_sample_duration_s:.6f}",
        f"audio_wall_duration_s={audio_wall_duration_s:.6f}",
        f"audio_sample_minus_video_ms={duration_diff_ms:.3f}",
        f"drift_ppm={drift_ppm:.3f}",
        f"video_interval_avg_ms={avg_vi:.3f}",
        f"video_interval_min_ms={min_vi:.3f}",
        f"video_interval_max_ms={max_vi:.3f}",
        f"expected_video_interval_ms={1000.0/fps:.3f}",
    ])

    with (out / "av_sync_report.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "video_ref",
            "audio_ref",
            "first_audio_minus_video_ms",
            "video_duration_s",
            "audio_sample_duration_s",
            "audio_wall_duration_s",
            "audio_sample_minus_video_ms",
            "drift_ppm",
            "video_interval_avg_ms",
            "video_interval_min_ms",
            "video_interval_max_ms",
        ])
        w.writerow([
            v_ref_name,
            a_ref_name,
            f"{first_offset_ms:.3f}",
            f"{video_duration_s:.6f}",
            f"{audio_sample_duration_s:.6f}",
            f"{audio_wall_duration_s:.6f}",
            f"{duration_diff_ms:.3f}",
            f"{drift_ppm:.3f}",
            f"{avg_vi:.3f}",
            f"{min_vi:.3f}",
            f"{max_vi:.3f}",
        ])
else:
    report.append("ERROR: not enough rows to analyze.")

(out / "av_sync_report.txt").write_text("\n".join(report) + "\n")
print("\n".join(report))
PY

echo
echo "========== abnormal check =========="
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
echo "========== report =========="
cat "$OUT/av_sync_report.txt"

echo
echo "========== abnormal =========="
cat "$OUT/abnormal.txt"

echo
echo "EXP26_OUT=$OUT"

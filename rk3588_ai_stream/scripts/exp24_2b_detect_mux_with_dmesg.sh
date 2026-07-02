#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

FRAMES=${1:-300}
WIDTH=${2:-1280}
HEIGHT=${3:-720}
FPS=${4:-30}

STAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="output/exp24_2b_detect_mux_${FRAMES}f_${STAMP}"
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/24_2b.log"
: > "$LOG"

H264="$OUT_DIR/detect_${FRAMES}f.h264"
PTS_CSV="$H264.pts.csv"
PROFILE_CSV="$OUT_DIR/profile_${FRAMES}f.csv"
MP4="$OUT_DIR/detect_${FRAMES}f_pts_mux.mp4"

DETECT_LOG="$OUT_DIR/detect_async_mpp.log"
MUX_LOG="$OUT_DIR/mux_run.log"
FFPROBE_STREAM_LOG="$OUT_DIR/ffprobe_mp4_stream.log"
FFPROBE_PACKETS_CSV="$OUT_DIR/ffprobe_packets.csv"
COMPARE_TXT="$OUT_DIR/pts_compare.txt"
DECODE_LOG="$OUT_DIR/ffmpeg_decode_check.log"
DMESG_BEFORE="$OUT_DIR/dmesg_before.log"
DMESG_AFTER="$OUT_DIR/dmesg_after.log"

echo "========== exp24-2b detect mux with dmesg ==========" | tee -a "$LOG"
date | tee -a "$LOG"
echo "OUT_DIR=$OUT_DIR" | tee -a "$LOG"
echo "FRAMES=$FRAMES WIDTH=$WIDTH HEIGHT=$HEIGHT FPS=$FPS" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== cleanup old processes ==========" | tee -a "$LOG"
pkill -f exp21_detect_mpp_encode_async 2>/dev/null || true
pkill -f exp24_mp4_mux_from_pts 2>/dev/null || true
sleep 1

echo | tee -a "$LOG"
echo "========== video11 users before ==========" | tee -a "$LOG"
fuser -v /dev/video11 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== build ==========" | tee -a "$LOG"
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tee -a "../$LOG"
make exp21_detect_mpp_encode_async exp24_mp4_mux_from_pts -j4 2>&1 | tee -a "../$LOG"
cd ..

echo | tee -a "$LOG"
echo "========== clear dmesg ==========" | tee -a "$LOG"
sudo dmesg -C || true
dmesg | tail -50 > "$DMESG_BEFORE" || true

echo | tee -a "$LOG"
echo "========== run detect async mpp ==========" | tee -a "$LOG"

set +e
./build/exp21_detect_mpp_encode_async \
  models/yolo11.rknn \
  /dev/video11 \
  "$WIDTH" \
  "$HEIGHT" \
  "$FRAMES" \
  "$H264" \
  "$PROFILE_CSV" \
  > "$DETECT_LOG" 2>&1
DETECT_RC=$?
set -e

dmesg | tail -260 > "$DMESG_AFTER" || true

echo "DETECT_RC=$DETECT_RC" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== detect tail ==========" | tee -a "$LOG"
tail -140 "$DETECT_LOG" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== dmesg key after detect ==========" | tee -a "$LOG"
grep -nEi "select timeout|VIDIOC|STREAMON|STREAMOFF|imx415|rkisp|rkcif|mipi|timeout|failed|error|invalid|Operation not permitted|No such|stream" \
  "$DMESG_AFTER" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== detect key summary ==========" | tee -a "$LOG"
grep -nE "select timeout|async_encoded_frames|async_encode_failures|async_drop_frames|frames[[:space:]]*:|wall_fps|avg_select_ms|avg_total_ms|enc pts csv saved|output h264|failed|error|Segmentation|段错误|non-positive|negative|invalid" \
  "$DETECT_LOG" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== output check ==========" | tee -a "$LOG"
ls -lh "$H264" "$PTS_CSV" "$PROFILE_CSV" "$DETECT_LOG" "$DMESG_AFTER" 2>&1 | tee -a "$LOG" || true

if [ ! -f "$PTS_CSV" ]; then
  echo "ERROR_PTS_CSV_MISSING" | tee -a "$LOG"
  exit 0
fi

echo | tee -a "$LOG"
echo "========== mux to mp4 ==========" | tee -a "$LOG"

set +e
./build/exp24_mp4_mux_from_pts \
  "$H264" \
  "$PTS_CSV" \
  "$MP4" \
  "$WIDTH" \
  "$HEIGHT" \
  "$FPS" \
  > "$MUX_LOG" 2>&1
MUX_RC=$?
set -e

echo "MUX_RC=$MUX_RC" | tee -a "$LOG"
cat "$MUX_LOG" | tee -a "$LOG"

if [ "$MUX_RC" -ne 0 ]; then
  echo "MUX_FAILED_SKIP_FFPROBE" | tee -a "$LOG"
  exit 0
fi

echo | tee -a "$LOG"
echo "========== ffprobe stream ==========" | tee -a "$LOG"

ffprobe -hide_banner \
  -show_format \
  -show_streams \
  -select_streams v:0 \
  "$MP4" \
  > "$FFPROBE_STREAM_LOG" 2>&1 || true

grep -nE "codec_name=|codec_type=|width=|height=|r_frame_rate=|avg_frame_rate=|time_base=|duration=|nb_frames=|bit_rate=" \
  "$FFPROBE_STREAM_LOG" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffprobe packets ==========" | tee -a "$LOG"

ffprobe -hide_banner \
  -select_streams v:0 \
  -show_packets \
  -show_entries packet=pts,pts_time,dts,dts_time,duration,duration_time,size,flags \
  -of csv=p=0 \
  "$MP4" \
  > "$FFPROBE_PACKETS_CSV" 2>/dev/null || true

echo "first 5 packets:" | tee -a "$LOG"
head -5 "$FFPROBE_PACKETS_CSV" | tee -a "$LOG" || true

echo "last 5 packets:" | tee -a "$LOG"
tail -5 "$FFPROBE_PACKETS_CSV" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== compare pts ==========" | tee -a "$LOG"

python3 - "$PTS_CSV" "$FFPROBE_PACKETS_CSV" "$COMPARE_TXT" <<'PY'
import csv
import sys
from pathlib import Path

pts_csv = Path(sys.argv[1])
pkt_csv = Path(sys.argv[2])
out_txt = Path(sys.argv[3])

rows = []
with pts_csv.open("r", newline="") as f:
    for r in csv.DictReader(f):
        rows.append(r)

packets = []
with pkt_csv.open("r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        p = line.split(",")
        if len(p) >= 8:
            packets.append(p)

bad = []
n = min(len(rows), len(packets))

for i in range(n):
    input_pts_us = int(float(rows[i]["input_pts_us"]))
    input_pts_time = input_pts_us / 1000000.0

    pkt_pts_time = float(packets[i][1])
    pkt_dts_time = float(packets[i][3])
    pkt_dur_time = float(packets[i][5])

    if abs(pkt_pts_time - input_pts_time) > 0.000002:
        bad.append((i, "pts_time_mismatch", input_pts_time, pkt_pts_time))

    if abs(pkt_dts_time - input_pts_time) > 0.000002:
        bad.append((i, "dts_time_mismatch", input_pts_time, pkt_dts_time))

    if pkt_dur_time <= 0:
        bad.append((i, "non_positive_duration", pkt_dur_time))

key_count = sum(1 for p in packets if len(p) >= 8 and "K" in p[7])

lines = []
lines.append(f"pts_rows        : {len(rows)}")
lines.append(f"mp4_packets     : {len(packets)}")
lines.append(f"compare_count   : {n}")
lines.append(f"bad_count       : {len(bad)}")
lines.append(f"key_packet_count: {key_count}")
if rows:
    lines.append(f"first_input_pts : {rows[0]['input_pts_us']}")
    lines.append(f"last_input_pts  : {rows[-1]['input_pts_us']}")
if packets:
    lines.append(f"first_pkt       : {packets[0]}")
    lines.append(f"last_pkt        : {packets[-1]}")
lines.append("")
lines.append("bad first 20:")
for b in bad[:20]:
    lines.append(str(b))

text = "\n".join(lines)
out_txt.write_text(text)
print(text)
PY

cat "$COMPARE_TXT" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== decode check ==========" | tee -a "$LOG"

ffmpeg -hide_banner -v error \
  -i "$MP4" \
  -f null - \
  > "$DECODE_LOG" 2>&1 || true

if [ -s "$DECODE_LOG" ]; then
  cat "$DECODE_LOG" | tee -a "$LOG"
else
  echo "decode_check: OK" | tee -a "$LOG"
fi

echo | tee -a "$LOG"
echo "========== abnormal keyword check ==========" | tee -a "$LOG"

grep -nEi "select timeout|failed|invalid|non-positive|negative|Timestamps are unset|missing picture|Could not|No such|malformed|deprecated|Segmentation|段错误|Broken pipe|VIDIOC|STREAMON|STREAMOFF|imx415|rkisp|rkcif|mipi|timeout|error" \
  "$DETECT_LOG" "$MUX_LOG" "$FFPROBE_STREAM_LOG" "$DECODE_LOG" "$COMPARE_TXT" "$DMESG_AFTER" 2>/dev/null | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f | sort | xargs -r ls -lh | tee -a "$LOG"

echo | tee -a "$LOG"
echo "exp24-2b done."
echo "OUT_DIR=$OUT_DIR"
echo "LOG=$LOG"

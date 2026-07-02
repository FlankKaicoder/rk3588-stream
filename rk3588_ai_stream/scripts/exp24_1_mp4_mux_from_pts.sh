#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp24_1_mp4_mux_from_pts
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/24_1.log"
: > "$LOG"

echo "========== exp24-1 mp4 mux from pts ==========" | tee -a "$LOG"
date | tee -a "$LOG"

EXP23_DIR=$(ls -td output/exp23_3_header_sync_buffer_300f output/exp23_* 2>/dev/null | head -1 || true)
if [ -z "$EXP23_DIR" ]; then
    echo "ERROR: cannot find exp23 output dir" | tee -a "$LOG"
    exit 1
fi

H264=$(find "$EXP23_DIR" -maxdepth 1 -type f -name "*.h264" | head -1 || true)
PTS_CSV=$(find "$EXP23_DIR" -maxdepth 1 -type f -name "*.pts.csv" | head -1 || true)

if [ ! -f "$H264" ]; then
    echo "ERROR: h264 not found in $EXP23_DIR" | tee -a "$LOG"
    exit 1
fi

if [ ! -f "$PTS_CSV" ]; then
    echo "ERROR: pts csv not found in $EXP23_DIR" | tee -a "$LOG"
    exit 1
fi

MP4="$OUT_DIR/exp24_1_pts_mux_300f.mp4"

echo "EXP23_DIR=$EXP23_DIR" | tee -a "$LOG"
echo "H264     =$H264" | tee -a "$LOG"
echo "PTS_CSV  =$PTS_CSV" | tee -a "$LOG"
echo "MP4      =$MP4" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== build exp24 muxer ==========" | tee -a "$LOG"

mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tee -a "../$LOG"
make exp24_mp4_mux_from_pts -j4 2>&1 | tee -a "../$LOG"
cd ..

echo | tee -a "$LOG"
echo "========== run exp24 muxer ==========" | tee -a "$LOG"

rm -f "$MP4" "$MP4.packets.csv"

./build/exp24_mp4_mux_from_pts \
  "$H264" \
  "$PTS_CSV" \
  "$MP4" \
  1280 \
  720 \
  30 \
  2>&1 | tee "$OUT_DIR/mux_run.log"

cat "$OUT_DIR/mux_run.log" >> "$LOG"

echo | tee -a "$LOG"
echo "========== output files ==========" | tee -a "$LOG"
ls -lh "$MP4" "$MP4.packets.csv" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffprobe mp4 stream ==========" | tee -a "$LOG"

ffprobe -hide_banner \
  -show_format \
  -show_streams \
  -select_streams v:0 \
  "$MP4" \
  > "$OUT_DIR/ffprobe_mp4_stream.log" 2>&1 || true

cat "$OUT_DIR/ffprobe_mp4_stream.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffprobe packet timestamps ==========" | tee -a "$LOG"

ffprobe -hide_banner \
  -select_streams v:0 \
  -show_packets \
  -show_entries packet=pts,pts_time,dts,dts_time,duration,duration_time,size,flags \
  -of csv=p=0 \
  "$MP4" \
  > "$OUT_DIR/ffprobe_packets.csv" 2>/dev/null || true

echo "first 20 packets:" | tee -a "$LOG"
head -20 "$OUT_DIR/ffprobe_packets.csv" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "last 20 packets:" | tee -a "$LOG"
tail -20 "$OUT_DIR/ffprobe_packets.csv" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== compare pts csv and mp4 packets ==========" | tee -a "$LOG"

python3 - "$PTS_CSV" "$OUT_DIR/ffprobe_packets.csv" "$OUT_DIR/pts_compare.txt" <<'PY'
import csv
import sys
from pathlib import Path

pts_csv = Path(sys.argv[1])
pkt_csv = Path(sys.argv[2])
out_txt = Path(sys.argv[3])

rows = []
with pts_csv.open("r", newline="") as f:
    r = csv.DictReader(f)
    for x in r:
        rows.append(x)

packets = []
with pkt_csv.open("r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split(",")
        # ffprobe csv:
        # pts,pts_time,dts,dts_time,duration,duration_time,size,flags
        if len(parts) >= 8:
            packets.append(parts)

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

key_count = 0
for p in packets:
    if len(p) >= 8 and "K" in p[7]:
        key_count += 1

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

cat "$OUT_DIR/pts_compare.txt" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== abnormal keyword check ==========" | tee -a "$LOG"

grep -nEi "error|failed|invalid|non-positive|negative|Timestamps are unset|missing picture|Could not|No such|malformed|deprecated" \
  "$OUT_DIR"/*.log "$OUT_DIR"/*.txt 2>/dev/null | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f | sort | xargs -r ls -lh | tee -a "$LOG"

echo | tee -a "$LOG"
echo "exp24-1 done."
echo "log: $LOG"

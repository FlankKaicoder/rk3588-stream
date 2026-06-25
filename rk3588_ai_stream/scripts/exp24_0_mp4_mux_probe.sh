#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp24_0_mp4_mux_probe
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/24_0.log"
: > "$LOG"

run_cmd() {
    echo
    echo "========== $* ==========" | tee -a "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

echo "========== exp24-0 mp4 mux probe ==========" | tee -a "$LOG"
date | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== find latest exp23 output ==========" | tee -a "$LOG"

EXP23_DIR=$(ls -td output/exp23_3_header_sync_buffer_300f output/exp23_* 2>/dev/null | head -1 || true)

if [ -z "$EXP23_DIR" ]; then
    echo "ERROR: cannot find exp23 output dir" | tee -a "$LOG"
    find output -maxdepth 2 -type d | grep exp23 | sort | tee -a "$LOG" || true
    exit 1
fi

H264=$(find "$EXP23_DIR" -maxdepth 1 -type f -name "*.h264" | head -1 || true)
PTS_CSV=$(find "$EXP23_DIR" -maxdepth 1 -type f -name "*.pts.csv" | head -1 || true)
PROFILE_CSV=$(find "$EXP23_DIR" -maxdepth 1 -type f -name "*.csv" ! -name "*.pts.csv" | head -1 || true)
RUN_LOG=$(find "$EXP23_DIR" -maxdepth 1 -type f -name "run.log" | head -1 || true)

echo "EXP23_DIR  = $EXP23_DIR" | tee -a "$LOG"
echo "H264       = $H264" | tee -a "$LOG"
echo "PTS_CSV    = $PTS_CSV" | tee -a "$LOG"
echo "PROFILE_CSV= $PROFILE_CSV" | tee -a "$LOG"
echo "RUN_LOG    = $RUN_LOG" | tee -a "$LOG"

if [ ! -f "$H264" ]; then
    echo "ERROR: h264 file not found" | tee -a "$LOG"
    exit 1
fi

if [ ! -f "$PTS_CSV" ]; then
    echo "ERROR: pts csv not found" | tee -a "$LOG"
    exit 1
fi

echo | tee -a "$LOG"
echo "========== file size ==========" | tee -a "$LOG"
ls -lh "$H264" "$PTS_CSV" "$PROFILE_CSV" "$RUN_LOG" 2>/dev/null | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== toolchain / ffmpeg ==========" | tee -a "$LOG"
run_cmd which ffmpeg
run_cmd which ffprobe
run_cmd ffmpeg -hide_banner -version
run_cmd ffprobe -hide_banner -version

echo | tee -a "$LOG"
echo "========== ffmpeg dev pkg-config ==========" | tee -a "$LOG"
run_cmd pkg-config --modversion libavformat
run_cmd pkg-config --modversion libavcodec
run_cmd pkg-config --modversion libavutil
run_cmd pkg-config --cflags --libs libavformat libavcodec libavutil

echo | tee -a "$LOG"
echo "========== ffmpeg dev headers ==========" | tee -a "$LOG"
find /usr /usr/local -path "*libavformat/avformat.h" 2>/dev/null | sort | tee -a "$LOG" || true
find /usr /usr/local -path "*libavcodec/avcodec.h" 2>/dev/null | sort | tee -a "$LOG" || true
find /usr /usr/local -path "*libavutil/avutil.h" 2>/dev/null | sort | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== raw h264 ffprobe ==========" | tee -a "$LOG"
ffprobe -hide_banner \
  -show_streams \
  -select_streams v:0 \
  "$H264" \
  > "$OUT_DIR/ffprobe_raw_h264.log" 2>&1 || true

cat "$OUT_DIR/ffprobe_raw_h264.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== pts csv analysis ==========" | tee -a "$LOG"

python3 - "$PTS_CSV" "$OUT_DIR/pts_analysis.txt" <<'PY'
import csv
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

rows = []
with csv_path.open("r", newline="") as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

def to_int(x, default=None):
    try:
        return int(float(x))
    except Exception:
        return default

frame_ids = [to_int(r.get("frame_id")) for r in rows]
input_pts = [to_int(r.get("input_pts_us")) for r in rows]
pkt_pts = [to_int(r.get("mpp_packet_pts_us")) for r in rows]
pkt_dts = [to_int(r.get("mpp_packet_dts_us")) for r in rows]
pts_match = [str(r.get("pts_match", "")).strip() for r in rows]
packet_sizes = [to_int(r.get("packet_size"), 0) for r in rows]

bad = []
for i, r in enumerate(rows):
    fid = frame_ids[i]
    ipts = input_pts[i]
    ppts = pkt_pts[i]
    if fid is None or ipts is None or ppts is None:
        bad.append((i, "parse_error", r))
        continue
    if i > 0:
        if frame_ids[i] != frame_ids[i-1] + 1:
            bad.append((i, "frame_id_not_continuous", r))
        if input_pts[i] <= input_pts[i-1]:
            bad.append((i, "input_pts_not_increasing", r))
        if pkt_pts[i] < pkt_pts[i-1]:
            bad.append((i, "packet_pts_decrease", r))
    if ipts != ppts:
        bad.append((i, "input_pts_not_equal_packet_pts", r))

duration_us = 0
if input_pts:
    # 估算最后一帧结束时间：最后 PTS + 一帧间隔
    if len(input_pts) >= 2:
        step = input_pts[-1] - input_pts[-2]
    else:
        step = 33333
    duration_us = input_pts[-1] + step

unique_dts = sorted(set(x for x in pkt_dts if x is not None))[:20]

lines = []
lines.append(f"csv_path             : {csv_path}")
lines.append(f"rows                 : {len(rows)}")
lines.append(f"first_frame_id       : {frame_ids[0] if frame_ids else None}")
lines.append(f"last_frame_id        : {frame_ids[-1] if frame_ids else None}")
lines.append(f"first_input_pts_us   : {input_pts[0] if input_pts else None}")
lines.append(f"last_input_pts_us    : {input_pts[-1] if input_pts else None}")
lines.append(f"estimated_duration_s : {duration_us / 1000000.0:.6f}")
lines.append(f"pts_match_count      : {sum(1 for x in pts_match if x in ('1','true','True'))} / {len(rows)}")
lines.append(f"bad_count            : {len(bad)}")
lines.append(f"packet_size_min      : {min(packet_sizes) if packet_sizes else None}")
lines.append(f"packet_size_max      : {max(packet_sizes) if packet_sizes else None}")
lines.append(f"packet_size_avg      : {sum(packet_sizes)/len(packet_sizes):.2f}" if packet_sizes else "packet_size_avg      : None")
lines.append(f"dts_unique_first20   : {unique_dts}")
lines.append("")
lines.append("first 5 rows:")
for r in rows[:5]:
    lines.append(str(r))
lines.append("")
lines.append("last 5 rows:")
for r in rows[-5:]:
    lines.append(str(r))
lines.append("")
lines.append("bad first 20:")
for item in bad[:20]:
    lines.append(str(item))

text = "\n".join(lines)
out_path.write_text(text)
print(text)
PY

echo | tee -a "$LOG"
echo "========== ffmpeg baseline mp4 mux ==========" | tee -a "$LOG"

BASELINE_MP4="$OUT_DIR/exp24_0_ffmpeg_baseline_30fps.mp4"

ffmpeg -y -hide_banner \
  -f h264 \
  -framerate 30 \
  -i "$H264" \
  -c:v copy \
  -movflags +faststart \
  "$BASELINE_MP4" \
  > "$OUT_DIR/ffmpeg_baseline_mux.log" 2>&1 || true

cat "$OUT_DIR/ffmpeg_baseline_mux.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== baseline mp4 ffprobe ==========" | tee -a "$LOG"

ffprobe -hide_banner \
  -show_format \
  -show_streams \
  -select_streams v:0 \
  "$BASELINE_MP4" \
  > "$OUT_DIR/ffprobe_baseline_mp4.log" 2>&1 || true

cat "$OUT_DIR/ffprobe_baseline_mp4.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== packet pts check ==========" | tee -a "$LOG"

ffprobe -hide_banner \
  -select_streams v:0 \
  -show_packets \
  -show_entries packet=pts_time,dts_time,duration_time,size,flags \
  -of csv=p=0 \
  "$BASELINE_MP4" \
  > "$OUT_DIR/baseline_packets.csv" 2>/dev/null || true

echo "first packets:" | tee -a "$LOG"
head -20 "$OUT_DIR/baseline_packets.csv" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "last packets:" | tee -a "$LOG"
tail -20 "$OUT_DIR/baseline_packets.csv" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== abnormal keyword check ==========" | tee -a "$LOG"

grep -nEi "error|failed|invalid|non-positive|negative|Timestamps are unset|missing picture|moov|Could not|No such" \
  "$OUT_DIR"/*.log "$OUT_DIR"/*.txt 2>/dev/null | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== exp24-0 result files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f | sort | xargs -r ls -lh | tee -a "$LOG"

echo | tee -a "$LOG"
echo "exp24-0 done."
echo "log: $LOG"

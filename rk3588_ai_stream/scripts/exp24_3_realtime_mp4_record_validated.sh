#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

FRAMES=${1:-1800}
WIDTH=${2:-1280}
HEIGHT=${3:-720}
FPS=${4:-30}

STAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="output/exp24_3_realtime_mp4_record_${FRAMES}f_${STAMP}"
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/24_3.log"
SUMMARY="$OUT_DIR/summary.txt"
: > "$LOG"
: > "$SUMMARY"

H264="$OUT_DIR/realtime_detect_${FRAMES}f.h264"
PTS_CSV="$H264.pts.csv"
PROFILE_CSV="$OUT_DIR/profile_${FRAMES}f.csv"
MP4="$OUT_DIR/realtime_detect_${FRAMES}f.mp4"

DETECT_LOG="$OUT_DIR/detect_async_mpp.log"
MUX_LOG="$OUT_DIR/mux_run.log"
FFPROBE_STREAM_LOG="$OUT_DIR/ffprobe_mp4_stream.log"
FFPROBE_PACKETS_CSV="$OUT_DIR/ffprobe_packets.csv"
COMPARE_TXT="$OUT_DIR/pts_compare.txt"
DECODE_LOG="$OUT_DIR/ffmpeg_decode_check.log"
DMESG_AFTER="$OUT_DIR/dmesg_after.log"

log() {
  echo "$*" | tee -a "$LOG"
}

log "========== exp24-3 realtime mp4 record validated =========="
date | tee -a "$LOG"
log "OUT_DIR=$OUT_DIR"
log "FRAMES=$FRAMES WIDTH=$WIDTH HEIGHT=$HEIGHT FPS=$FPS"
log "H264=$H264"
log "PTS_CSV=$PTS_CSV"
log "MP4=$MP4"

log ""
log "========== cleanup old processes =========="
pkill -f exp21_detect_mpp_encode_async 2>/dev/null || true
pkill -f exp24_mp4_mux_from_pts 2>/dev/null || true
sleep 1

log ""
log "========== video11 users before =========="
fuser -v /dev/video11 2>&1 | tee -a "$LOG" || true

log ""
log "========== build =========="
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tee -a "../$LOG"
make exp21_detect_mpp_encode_async exp24_mp4_mux_from_pts -j4 2>&1 | tee -a "../$LOG"
cd ..

log ""
log "========== clear dmesg =========="
sudo dmesg -C || true

log ""
log "========== run realtime detect + async mpp encode =========="

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

dmesg | tail -300 > "$DMESG_AFTER" || true

log "DETECT_RC=$DETECT_RC"

log ""
log "========== detect tail =========="
tail -140 "$DETECT_LOG" | tee -a "$LOG"

ENCODED=$(grep -E "async_encoded_frames" "$DETECT_LOG" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
FAILURES=$(grep -E "async_encode_failures" "$DETECT_LOG" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
DROPS=$(grep -E "async_drop_frames" "$DETECT_LOG" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
WALL_FPS=$(grep -E "wall_fps" "$DETECT_LOG" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
AVG_TOTAL=$(grep -E "avg_total_ms" "$DETECT_LOG" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')

log ""
log "========== detect parsed summary =========="
log "encoded=$ENCODED"
log "failures=$FAILURES"
log "drops=$DROPS"
log "wall_fps=$WALL_FPS"
log "avg_total_ms=$AVG_TOTAL"

if [ "$DETECT_RC" -ne 0 ]; then
  log "ERROR: detect program returned non-zero"
  exit 1
fi

if [ "$ENCODED" != "$FRAMES" ]; then
  log "ERROR: encoded frames mismatch, expected=$FRAMES actual=$ENCODED"
  exit 1
fi

if [ "$FAILURES" != "0" ]; then
  log "ERROR: async encode failures != 0"
  exit 1
fi

if [ "$DROPS" != "0" ]; then
  log "ERROR: async drop frames != 0"
  exit 1
fi

if [ ! -f "$H264" ] || [ ! -f "$PTS_CSV" ]; then
  log "ERROR: h264 or pts csv missing"
  exit 1
fi

log ""
log "========== mux to mp4 =========="

./build/exp24_mp4_mux_from_pts \
  "$H264" \
  "$PTS_CSV" \
  "$MP4" \
  "$WIDTH" \
  "$HEIGHT" \
  "$FPS" \
  > "$MUX_LOG" 2>&1

cat "$MUX_LOG" | tee -a "$LOG"

log ""
log "========== ffprobe stream =========="

ffprobe -hide_banner \
  -show_format \
  -show_streams \
  -select_streams v:0 \
  "$MP4" \
  > "$FFPROBE_STREAM_LOG" 2>&1

grep -nE "codec_name=|codec_type=|width=|height=|r_frame_rate=|avg_frame_rate=|time_base=|duration=|nb_frames=|bit_rate=" \
  "$FFPROBE_STREAM_LOG" | tee -a "$LOG" || true

log ""
log "========== ffprobe packets =========="

ffprobe -hide_banner \
  -select_streams v:0 \
  -show_packets \
  -show_entries packet=pts,pts_time,dts,dts_time,duration,duration_time,size,flags \
  -of csv=p=0 \
  "$MP4" \
  > "$FFPROBE_PACKETS_CSV" 2>/dev/null

log "first 5 packets:"
head -5 "$FFPROBE_PACKETS_CSV" | tee -a "$LOG" || true

log "last 5 packets:"
tail -5 "$FFPROBE_PACKETS_CSV" | tee -a "$LOG" || true

log ""
log "========== compare pts =========="

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

BAD_COUNT=$(grep -E "^bad_count" "$COMPARE_TXT" | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
MP4_PACKETS=$(grep -E "^mp4_packets" "$COMPARE_TXT" | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
PTS_ROWS=$(grep -E "^pts_rows" "$COMPARE_TXT" | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')

if [ "$BAD_COUNT" != "0" ]; then
  log "ERROR: pts compare bad_count != 0"
  exit 1
fi

if [ "$MP4_PACKETS" != "$FRAMES" ]; then
  log "ERROR: mp4 packet count mismatch, expected=$FRAMES actual=$MP4_PACKETS"
  exit 1
fi

if [ "$PTS_ROWS" != "$FRAMES" ]; then
  log "ERROR: pts row count mismatch, expected=$FRAMES actual=$PTS_ROWS"
  exit 1
fi

log ""
log "========== decode check =========="

ffmpeg -hide_banner -v error \
  -i "$MP4" \
  -f null - \
  > "$DECODE_LOG" 2>&1 || true

if [ -s "$DECODE_LOG" ]; then
  cat "$DECODE_LOG" | tee -a "$LOG"
  log "ERROR: decode check produced error output"
  exit 1
else
  log "decode_check: OK"
fi

log ""
log "========== dmesg key =========="
grep -nEi "select timeout|VIDIOC|STREAMON|STREAMOFF|imx415|rkisp|rkcif|mipi|timeout|failed|error|invalid|stream" \
  "$DMESG_AFTER" | tee -a "$LOG" || true

log ""
log "========== abnormal keyword check =========="

ABN="$OUT_DIR/abnormal.txt"
grep -nEi "select timeout|failed|invalid|non-positive|negative|Timestamps are unset|missing picture|Could not|No such|malformed|deprecated|Segmentation|段错误|Broken pipe|timeout|error" \
  "$DETECT_LOG" "$MUX_LOG" "$FFPROBE_STREAM_LOG" "$DECODE_LOG" "$COMPARE_TXT" 2>/dev/null > "$ABN" || true

if [ -s "$ABN" ]; then
  cat "$ABN" | tee -a "$LOG"
  log "ERROR: abnormal keywords found"
  exit 1
else
  log "abnormal_check: OK"
fi

log ""
log "========== write summary =========="

{
  echo "# exp24-3 realtime MP4 record validated"
  echo
  echo "OUT_DIR=$OUT_DIR"
  echo "frames=$FRAMES"
  echo "width=$WIDTH"
  echo "height=$HEIGHT"
  echo "fps=$FPS"
  echo
  echo "detect_rc=$DETECT_RC"
  echo "async_encoded_frames=$ENCODED"
  echo "async_encode_failures=$FAILURES"
  echo "async_drop_frames=$DROPS"
  echo "wall_fps=$WALL_FPS"
  echo "avg_total_ms=$AVG_TOTAL"
  echo
  echo "pts_rows=$PTS_ROWS"
  echo "mp4_packets=$MP4_PACKETS"
  echo "bad_count=$BAD_COUNT"
  echo
  echo "h264=$H264"
  echo "pts_csv=$PTS_CSV"
  echo "mp4=$MP4"
  echo "profile_csv=$PROFILE_CSV"
  echo
  echo "result=PASS"
} > "$SUMMARY"

cat "$SUMMARY" | tee -a "$LOG"

log ""
log "========== final files =========="
find "$OUT_DIR" -maxdepth 1 -type f | sort | xargs -r ls -lh | tee -a "$LOG"

log ""
log "exp24-3 PASS"
log "OUT_DIR=$OUT_DIR"
log "MP4=$MP4"

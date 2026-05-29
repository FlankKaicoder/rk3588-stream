#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp08_4_detect_fifo_mpp_clean
mkdir -p "$OUT_DIR"

FIFO="$OUT_DIR/live_detect_clean_1280x720_nv12.fifo"
H264="$OUT_DIR/live_detect_clean_300f_1280x720.h264"
MP4="$OUT_DIR/live_detect_clean_300f_1280x720.mp4"
FIRST_JPG="$OUT_DIR/first_frame_from_mp4.jpg"
PROFILE="$OUT_DIR/profile_detect_to_nv12_clean.csv"

rm -f "$FIFO" "$H264" "$MP4" "$FIRST_JPG" "$PROFILE"
mkfifo "$FIFO"

echo "========== 08-4 start MPP encoder ==========" | tee "$OUT_DIR/08_4.log"

/home/cat/mpp/build/test/mpi_enc_test \
  -i "$FIFO" \
  -o "$H264" \
  -w 1280 \
  -h 720 \
  -f 0 \
  -t 7 \
  -n 300 \
  > "$OUT_DIR/mpi_enc_detect_fifo_run.log" 2>&1 &

ENC_PID=$!

sleep 1

echo "encoder pid: $ENC_PID" | tee -a "$OUT_DIR/08_4.log"

echo "========== 08-4 start clean detect writer ==========" | tee -a "$OUT_DIR/08_4.log"

./build/v4l2_rga_rknn_detect_to_nv12_clean \
  models/yolo11.rknn \
  /dev/video11 \
  1280 \
  720 \
  300 \
  "$FIFO" \
  "$PROFILE" \
  2>&1 | tee "$OUT_DIR/v4l2_rga_rknn_detect_to_nv12_clean.log"

echo "========== wait encoder ==========" | tee -a "$OUT_DIR/08_4.log"
wait "$ENC_PID" || true

rm -f "$FIFO"

echo "========== encoder log tail ==========" | tee -a "$OUT_DIR/08_4.log"
tail -60 "$OUT_DIR/mpi_enc_detect_fifo_run.log" | tee -a "$OUT_DIR/08_4.log"

echo "========== check h264 ==========" | tee -a "$OUT_DIR/08_4.log"
ls -lh "$H264" | tee -a "$OUT_DIR/08_4.log"

echo "========== package mp4 ==========" | tee -a "$OUT_DIR/08_4.log"
ffmpeg -y \
  -framerate 30 \
  -i "$H264" \
  -c copy \
  "$MP4" \
  2>&1 | tee "$OUT_DIR/ffmpeg_pack_mp4.log"

echo "========== ffprobe ==========" | tee -a "$OUT_DIR/08_4.log"
ffprobe -hide_banner "$MP4" \
  2>&1 | tee "$OUT_DIR/ffprobe_mp4.log"

echo "========== extract first frame ==========" | tee -a "$OUT_DIR/08_4.log"
ffmpeg -y \
  -i "$MP4" \
  -frames:v 1 \
  "$FIRST_JPG" \
  2>&1 | tee "$OUT_DIR/extract_first_jpg.log"

echo "========== csv avg ==========" | tee -a "$OUT_DIR/08_4.log"
python3 - <<'PY' | tee -a "$OUT_DIR/08_4.log"
import csv
from pathlib import Path

p = Path("output/exp08_4_detect_fifo_mpp_clean/profile_detect_to_nv12_clean.csv")

rows = []
with p.open() as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

print("frames:", len(rows))

keys = [
    "select_ms",
    "dqbuf_ms",
    "rga_nv12_to_rgb_ms",
    "input_prepare_ms",
    "model_total_ms",
    "draw_ms",
    "rga_rgb_to_nv12_ms",
    "write_ms",
    "qbuf_ms",
    "total_ms",
    "fps",
    "detect_count",
]

for k in keys:
    vals = [float(r[k]) for r in rows]
    print(f"{k:22s}: avg={sum(vals)/len(vals):8.3f}  min={min(vals):8.3f}  max={max(vals):8.3f}")

total = [float(r["total_ms"]) for r in rows]
print(f"\n1000 / avg_total_ms fps : {1000.0 / (sum(total) / len(total)):.3f}")
PY

echo "========== final files ==========" | tee -a "$OUT_DIR/08_4.log"
ls -lh "$OUT_DIR" | tee -a "$OUT_DIR/08_4.log"

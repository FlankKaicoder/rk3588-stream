#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp08_2_v4l2_fifo_mpp
mkdir -p "$OUT_DIR"

FIFO="$OUT_DIR/live_1280x720_nv12.fifo"
H264="$OUT_DIR/live_120f_1280x720.h264"
MP4="$OUT_DIR/live_120f_1280x720.mp4"
FIRST_JPG="$OUT_DIR/first_frame.jpg"

rm -f "$FIFO" "$H264" "$MP4" "$FIRST_JPG"
mkfifo "$FIFO"

echo "========== 08-2 start encoder ==========" | tee "$OUT_DIR/08_2.log"

/home/cat/mpp/build/test/mpi_enc_test \
  -i "$FIFO" \
  -o "$H264" \
  -w 1280 \
  -h 720 \
  -f 0 \
  -t 7 \
  -n 120 \
  > "$OUT_DIR/mpi_enc_fifo_run.log" 2>&1 &

ENC_PID=$!

sleep 1

echo "encoder pid: $ENC_PID" | tee -a "$OUT_DIR/08_2.log"

echo "========== 08-2 start v4l2 capture writer ==========" | tee -a "$OUT_DIR/08_2.log"

./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  120 \
  "$FIFO" \
  2>&1 | tee "$OUT_DIR/v4l2_fifo_dump.log"

echo "========== wait encoder ==========" | tee -a "$OUT_DIR/08_2.log"
wait "$ENC_PID" || true

rm -f "$FIFO"

echo "========== encoder log tail ==========" | tee -a "$OUT_DIR/08_2.log"
tail -40 "$OUT_DIR/mpi_enc_fifo_run.log" | tee -a "$OUT_DIR/08_2.log"

echo "========== check h264 ==========" | tee -a "$OUT_DIR/08_2.log"
ls -lh "$H264" | tee -a "$OUT_DIR/08_2.log"

echo "========== package mp4 ==========" | tee -a "$OUT_DIR/08_2.log"
ffmpeg -y \
  -framerate 30 \
  -i "$H264" \
  -c copy \
  "$MP4" \
  2>&1 | tee "$OUT_DIR/ffmpeg_pack_mp4.log"

echo "========== ffprobe ==========" | tee -a "$OUT_DIR/08_2.log"
ffprobe -hide_banner "$MP4" \
  2>&1 | tee "$OUT_DIR/ffprobe_mp4.log"

echo "========== extract first frame ==========" | tee -a "$OUT_DIR/08_2.log"
ffmpeg -y \
  -i "$MP4" \
  -frames:v 1 \
  "$FIRST_JPG" \
  2>&1 | tee "$OUT_DIR/extract_first_jpg.log"

echo "========== final files ==========" | tee -a "$OUT_DIR/08_2.log"
ls -lh "$OUT_DIR" | tee -a "$OUT_DIR/08_2.log"

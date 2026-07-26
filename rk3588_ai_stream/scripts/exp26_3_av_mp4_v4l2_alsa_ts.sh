#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

FRAMES=${1:-300}
WIDTH=${2:-1280}
HEIGHT=${3:-720}
FPS=${4:-30}
AUDIO_DEV=${5:-hw:2,0}
AUDIO_RATE=${6:-48000}
AUDIO_CH=${7:-2}
PERIOD_FRAMES=${8:-256}
MIN_EXPECT_FPS=${9:-15}
AUDIO_PAD_SEC=${10:-5}

AUDIO_DURATION=$(python3 - <<PY
import math
frames=float("$FRAMES")
min_fps=float("$MIN_EXPECT_FPS")
pad=float("$AUDIO_PAD_SEC")
print(int(math.ceil(frames / min_fps + pad)))
PY
)

TS=$(date +%Y%m%d_%H%M%S)
OUT="output/exp26_3_av_mp4_v4l2_alsa_ts_${FRAMES}f_${TS}"
mkdir -p "$OUT"

H264="$OUT/detect_v4l2_pts_${FRAMES}f.h264"
PROFILE="$OUT/profile_${FRAMES}f.csv"
VIDEO_MP4="$OUT/video_v4l2_pts_${FRAMES}f.mp4"
AUDIO_PCM="$OUT/audio_full_s16le_${AUDIO_DURATION}s.pcm"
AUDIO_TS="$OUT/audio_ts.csv"
AUDIO_TRIM_M4A="$OUT/audio_trimmed_aac.m4a"
AV_MP4="$OUT/av_v4l2_alsa_ts_${FRAMES}f.mp4"


echo "========== set performance mode =========="
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "$g" >/dev/null || true
done

export RGA_LOG_LEVEL=0
export RGA_DEBUG=0

echo "========== exp26-3 AV MP4 V4L2/ALSA timestamp sync =========="
echo "out            : $OUT"
echo "video frames   : $FRAMES"
echo "video size     : ${WIDTH}x${HEIGHT}"
echo "fps nominal    : $FPS"
echo "audio dev      : $AUDIO_DEV"
echo "audio duration : $AUDIO_DURATION s"
echo "audio rate/ch  : ${AUDIO_RATE}/${AUDIO_CH}"
echo "period frames  : $PERIOD_FRAMES"
echo

echo "========== build =========="
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async exp24_mp4_mux_from_pts exp26_alsa_pcm_capture_ts -j4
cd ..

echo
echo "========== clear dmesg =========="
sudo dmesg -C || true

echo
echo "========== start ALSA timestamped PCM capture =========="
./build/exp26_alsa_pcm_capture_ts \
  "$AUDIO_DEV" \
  "$AUDIO_RATE" \
  "$AUDIO_CH" \
  "$AUDIO_DURATION" \
  "$PERIOD_FRAMES" \
  "$AUDIO_PCM" \
  "$AUDIO_TS" \
  > "$OUT/audio_capture.log" 2>&1 &
AUDIO_PID=$!

sleep 0.20

echo
echo "========== start video detection record =========="
./build/exp21_detect_mpp_encode_async \
  models/yolo11.rknn \
  /dev/video11 \
  "$WIDTH" \
  "$HEIGHT" \
  "$FRAMES" \
  "$H264" \
  "$PROFILE" \
  > "$OUT/video_record.log" 2>&1
VIDEO_RC=$?

echo
echo "========== wait audio capture =========="
set +e
wait "$AUDIO_PID"
AUDIO_RC=$?
set -e

echo "video_rc=$VIDEO_RC" | tee "$OUT/return_codes.txt"
echo "audio_rc=$AUDIO_RC" | tee -a "$OUT/return_codes.txt"

echo
echo "========== mux video-only MP4 =========="
./build/exp24_mp4_mux_from_pts \
  "$H264" \
  "$H264.pts.csv" \
  "$VIDEO_MP4" \
  "$WIDTH" \
  "$HEIGHT" \
  "$FPS" \
  > "$OUT/video_mux.log" 2>&1

VIDEO_DURATION=$(ffprobe -v error \
  -show_entries format=duration \
  -of default=nw=1:nk=1 \
  "$VIDEO_MP4")

echo "video_duration_s=$VIDEO_DURATION" | tee "$OUT/video_duration.txt"

echo
echo "========== compute audio trim from timestamps =========="
python3 - "$OUT" "$H264.sync_meta.csv" "$AUDIO_TS" "$VIDEO_DURATION" "$AUDIO_RATE" <<'PY'
import csv
import statistics
import sys
from pathlib import Path

out = Path(sys.argv[1])
sync_csv = Path(sys.argv[2])
audio_csv = Path(sys.argv[3])
video_duration_s = float(sys.argv[4])
audio_rate = float(sys.argv[5])

def read_csv(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))

def iv(x, default=-1):
    try:
        return int(float(x))
    except Exception:
        return default

sync_rows = read_csv(sync_csv)
audio_rows = read_csv(audio_csv)

first_video_v4l2_ts_ns = iv(sync_rows[0]["first_video_v4l2_ts_ns"])
last_video_sync_pts_us = iv(sync_rows[-1]["video_sync_pts_us"])

start_est = [
    iv(r.get("audio_stream_start_est_ns", -1))
    for r in audio_rows
]
start_est = [x for x in start_est if x > 0]

if not start_est:
    raise SystemExit("no valid audio_stream_start_est_ns")

use_n = min(200, len(start_est))
audio_stream_start_est_ns = int(statistics.median(start_est[:use_n]))

audio_total_frames = iv(audio_rows[-1]["total_frames"])
audio_sample_duration_s = audio_total_frames / audio_rate

audio_trim_s = max(0.0, (first_video_v4l2_ts_ns - audio_stream_start_est_ns) / 1e9)
audio_after_trim_s = audio_sample_duration_s - audio_trim_s
audio_tail_margin_s = audio_after_trim_s - video_duration_s

report = []
report.append(f"first_video_v4l2_ts_ns={first_video_v4l2_ts_ns}")
report.append(f"audio_stream_start_est_ns={audio_stream_start_est_ns}")
report.append(f"audio_start_est_samples_used={use_n}")
report.append(f"audio_trim_s={audio_trim_s:.6f}")
report.append(f"video_duration_s={video_duration_s:.6f}")
report.append(f"last_video_sync_pts_us={last_video_sync_pts_us}")
report.append(f"audio_sample_duration_s={audio_sample_duration_s:.6f}")
report.append(f"audio_after_trim_s={audio_after_trim_s:.6f}")
report.append(f"audio_tail_margin_s={audio_tail_margin_s:.6f}")
report.append("RESULT=PASS_AUDIO_COVERS_VIDEO" if audio_tail_margin_s > 0 else "RESULT=FAIL_AUDIO_TOO_SHORT")

(out / "sync_plan.txt").write_text("\n".join(report) + "\n")
(out / "audio_trim_s.txt").write_text(f"{audio_trim_s:.6f}\n")
(out / "trim_video_duration_s.txt").write_text(f"{video_duration_s:.6f}\n")

print("\n".join(report))
PY

AUDIO_TRIM=$(cat "$OUT/audio_trim_s.txt")
TRIM_DURATION=$(cat "$OUT/trim_video_duration_s.txt")

echo
echo "========== encode trimmed AAC =========="
ffmpeg -hide_banner -y \
  -f s16le \
  -ar "$AUDIO_RATE" \
  -ac "$AUDIO_CH" \
  -i "$AUDIO_PCM" \
  -af "atrim=start=${AUDIO_TRIM}:duration=${TRIM_DURATION},asetpts=PTS-STARTPTS" \
  -c:a aac \
  -b:a 128k \
  "$AUDIO_TRIM_M4A" \
  > "$OUT/ffmpeg_audio_trim_encode.log" 2>&1

echo
echo "========== mux AV MP4 =========="
ffmpeg -hide_banner -y \
  -i "$VIDEO_MP4" \
  -i "$AUDIO_TRIM_M4A" \
  -map 0:v:0 \
  -map 1:a:0 \
  -c:v copy \
  -c:a copy \
  -movflags +faststart \
  -shortest \
  "$AV_MP4" \
  > "$OUT/ffmpeg_av_mux.log" 2>&1

echo
echo "========== ffprobe AV =========="
ffprobe -hide_banner \
  -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,time_base,duration,nb_frames,sample_rate,channels,bit_rate \
  -of default=nw=1 \
  "$AV_MP4" \
  > "$OUT/ffprobe_av_streams.txt" 2>&1 || true

ffprobe -hide_banner \
  -show_entries format=duration,size,bit_rate \
  -of default=nw=1 \
  "$AV_MP4" \
  > "$OUT/ffprobe_av_format.txt" 2>&1 || true

echo
echo "========== decode check =========="
ffmpeg -hide_banner -v warning \
  -i "$AV_MP4" \
  -f null - \
  > "$OUT/ffmpeg_decode_check.log" 2>&1 || true

dmesg | tail -200 > "$OUT/dmesg_after.log" || true

echo
echo "========== abnormal check =========="
{
  echo "video_record.log:"
  grep -nEi "error|failed|timeout|RGA_COLORFILL|Failed to call|unsafe|warning|invalid|non-positive|negative|Segmentation" "$OUT/video_record.log" || true
  echo
  echo "audio_capture.log:"
  grep -nEi "xrun|overrun|underrun|error|failed|invalid|cannot|timeout" "$OUT/audio_capture.log" || true
  echo
  echo "video_mux.log:"
  grep -nEi "error|failed|warning|invalid|non-monotonous|unset|negative|non-positive" "$OUT/video_mux.log" || true
  echo
  echo "ffmpeg_audio_trim_encode.log:"
  grep -nEi "error|failed|warning|invalid|non-monotonous|unset|negative|non-positive" "$OUT/ffmpeg_audio_trim_encode.log" || true
  echo
  echo "ffmpeg_av_mux.log:"
  grep -nEi "error|failed|warning|invalid|non-monotonous|unset|negative|non-positive" "$OUT/ffmpeg_av_mux.log" || true
  echo
  echo "ffmpeg_decode_check.log:"
  cat "$OUT/ffmpeg_decode_check.log" || true
} > "$OUT/abnormal.txt"

cat > "$OUT/summary.txt" <<SUM
EXP26_3_OUT=$OUT
FRAMES=$FRAMES
WIDTH=$WIDTH
HEIGHT=$HEIGHT
FPS_NOMINAL=$FPS
AUDIO_DEV=$AUDIO_DEV
AUDIO_RATE=$AUDIO_RATE
AUDIO_CH=$AUDIO_CH
AUDIO_DURATION=$AUDIO_DURATION
AUDIO_TRIM=$AUDIO_TRIM
VIDEO_DURATION=$VIDEO_DURATION
H264=$H264
VIDEO_MP4=$VIDEO_MP4
AUDIO_PCM=$AUDIO_PCM
AUDIO_TRIM_M4A=$AUDIO_TRIM_M4A
AV_MP4=$AV_MP4
SUM

echo
echo "========== summary =========="
cat "$OUT/summary.txt"

echo
echo "========== sync plan =========="
cat "$OUT/sync_plan.txt"

echo
echo "========== av streams =========="
cat "$OUT/ffprobe_av_streams.txt"

echo
echo "========== av format =========="
cat "$OUT/ffprobe_av_format.txt"

echo
echo "========== abnormal =========="
cat "$OUT/abnormal.txt"

echo
echo "EXP26_3_OUT=$OUT"

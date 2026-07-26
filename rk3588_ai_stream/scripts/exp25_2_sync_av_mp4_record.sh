#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

FRAMES=${1:-1800}
WIDTH=${2:-1280}
HEIGHT=${3:-720}
FPS=${4:-30}
AUDIO_DEV=${5:-hw:2,0}
AUDIO_RATE=${6:-48000}
AUDIO_CH=${7:-2}

TS=$(date +%Y%m%d_%H%M%S)
OUT_DIR=output/exp25_2_sync_av_mp4_${FRAMES}f_${TS}
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/25_2.log"
: > "$LOG"

log() {
    echo "$@" | tee -a "$LOG"
}

run() {
    log
    log "========== $* =========="
    "$@" 2>&1 | tee -a "$LOG"
}

log "========== exp25-2 sync AV MP4 record =========="
date | tee -a "$LOG"

log
log "OUT_DIR=$OUT_DIR"
log "FRAMES=$FRAMES"
log "WIDTH=$WIDTH"
log "HEIGHT=$HEIGHT"
log "FPS=$FPS"
log "AUDIO_DEV=$AUDIO_DEV"
log "AUDIO_RATE=$AUDIO_RATE"
log "AUDIO_CH=$AUDIO_CH"

VIDEO_DUR=$(python3 - <<PY
frames = int("$FRAMES")
fps = float("$FPS")
print(f"{frames / fps:.3f}")
PY
)

# 音频多录 2 秒，后续用 -shortest 截断；同时根据启动时间差裁掉开头多录音频。
AUDIO_DUR=$(python3 - <<PY
dur = float("$VIDEO_DUR")
print(f"{dur + 2.0:.3f}")
PY
)

log "VIDEO_DUR=${VIDEO_DUR}s"
log "AUDIO_DUR=${AUDIO_DUR}s"

H264="$OUT_DIR/realtime_detect_${FRAMES}f.h264"
PTS_CSV="$H264.pts.csv"
PROFILE_CSV="$OUT_DIR/profile_${FRAMES}f.csv"
VIDEO_MP4="$OUT_DIR/realtime_detect_${FRAMES}f_video_only.mp4"
AUDIO_M4A="$OUT_DIR/realtime_audio_${FRAMES}f_aac.m4a"
AV_MP4="$OUT_DIR/realtime_detect_${FRAMES}f_av_sync.mp4"

log
log "========== set performance governor =========="
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$g" >/dev/null || true
done
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq | tee -a "$LOG" || true

log
log "========== build check =========="
if [ ! -x build/exp21_detect_mpp_encode_async ] || [ ! -x build/exp24_mp4_mux_from_pts ]; then
    log "build target missing, rebuild..."
    rm -rf build
    mkdir -p build
    cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release 2>&1 | tee -a "../$LOG"
    make exp21_detect_mpp_encode_async exp24_mp4_mux_from_pts -j4 2>&1 | tee -a "../$LOG"
    cd ..
fi

ls -lh build/exp21_detect_mpp_encode_async build/exp24_mp4_mux_from_pts | tee -a "$LOG"

log
log "========== audio device check =========="
arecord -l 2>&1 | tee "$OUT_DIR/arecord_l.txt" | tee -a "$LOG" || true
cat /proc/asound/pcm 2>/dev/null | tee "$OUT_DIR/proc_asound_pcm.txt" | tee -a "$LOG" || true

log
log "========== start audio capture =========="
AUDIO_START_NS=$(date +%s%N)

ffmpeg -hide_banner -y -nostdin \
    -thread_queue_size 1024 \
    -f alsa \
    -ac "$AUDIO_CH" \
    -ar "$AUDIO_RATE" \
    -i "$AUDIO_DEV" \
    -t "$AUDIO_DUR" \
    -c:a aac \
    -b:a 128k \
    "$AUDIO_M4A" \
    > "$OUT_DIR/ffmpeg_audio_capture.log" 2>&1 &

AUDIO_PID=$!
log "AUDIO_PID=$AUDIO_PID"
log "AUDIO_START_NS=$AUDIO_START_NS"

# 给 FFmpeg/ALSA 一点点启动时间，保证音频大概率早于视频开始。
sleep 0.35

log
log "========== start realtime video detect record =========="
VIDEO_START_NS=$(date +%s%N)
log "VIDEO_START_NS=$VIDEO_START_NS"

set +e
./build/exp21_detect_mpp_encode_async \
    models/yolo11.rknn \
    /dev/video11 \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$H264" \
    "$PROFILE_CSV" \
    > "$OUT_DIR/detect_async_mpp.log" 2>&1
DETECT_RC=$?
set -e

VIDEO_END_NS=$(date +%s%N)
log "VIDEO_END_NS=$VIDEO_END_NS"
log "DETECT_RC=$DETECT_RC"

log
log "========== wait audio capture finish =========="
set +e
wait "$AUDIO_PID"
AUDIO_RC=$?
set -e
AUDIO_END_NS=$(date +%s%N)

log "AUDIO_END_NS=$AUDIO_END_NS"
log "AUDIO_RC=$AUDIO_RC"

log
log "========== detect log tail =========="
tail -120 "$OUT_DIR/detect_async_mpp.log" | tee -a "$LOG"

log
log "========== audio log tail =========="
tail -120 "$OUT_DIR/ffmpeg_audio_capture.log" | tee -a "$LOG"

log
log "========== generated files check =========="
ls -lh "$H264" "$PTS_CSV" "$PROFILE_CSV" "$AUDIO_M4A" 2>&1 | tee -a "$LOG"

log
log "========== mux h264 + pts csv to video mp4 =========="
set +e
./build/exp24_mp4_mux_from_pts \
    "$H264" \
    "$PTS_CSV" \
    "$VIDEO_MP4" \
    "$WIDTH" \
    "$HEIGHT" \
    "$FPS" \
    > "$OUT_DIR/mux_video_only.log" 2>&1
MUX_VIDEO_RC=$?
set -e

log "MUX_VIDEO_RC=$MUX_VIDEO_RC"
tail -120 "$OUT_DIR/mux_video_only.log" | tee -a "$LOG"

log
log "========== compute audio lead =========="
AUDIO_LEAD_SEC=$(python3 - <<PY
audio_start = int("$AUDIO_START_NS")
video_start = int("$VIDEO_START_NS")
lead = (video_start - audio_start) / 1e9
if lead < 0:
    lead = 0.0
print(f"{lead:.3f}")
PY
)

log "AUDIO_LEAD_SEC=$AUDIO_LEAD_SEC"
echo "$AUDIO_LEAD_SEC" > "$OUT_DIR/audio_lead_sec.txt"

log
log "========== mux video mp4 + trimmed audio m4a to final av mp4 =========="
set +e
ffmpeg -hide_banner -y -nostdin \
    -i "$VIDEO_MP4" \
    -ss "$AUDIO_LEAD_SEC" \
    -i "$AUDIO_M4A" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a copy \
    -shortest \
    -movflags +faststart \
    "$AV_MP4" \
    > "$OUT_DIR/ffmpeg_av_mux.log" 2>&1
MUX_AV_RC=$?
set -e

log "MUX_AV_RC=$MUX_AV_RC"
tail -120 "$OUT_DIR/ffmpeg_av_mux.log" | tee -a "$LOG"

log
log "========== ffprobe final AV streams =========="
ffprobe -hide_banner -v error \
    -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,time_base,duration,nb_frames,sample_rate,channels,channel_layout,bit_rate \
    -of default=noprint_wrappers=1 \
    "$AV_MP4" \
    2>&1 | tee "$OUT_DIR/ffprobe_av_streams.txt" | tee -a "$LOG"

log
log "========== ffprobe final AV format =========="
ffprobe -hide_banner -v error \
    -show_entries format=duration,size,bit_rate \
    -of default=noprint_wrappers=1 \
    "$AV_MP4" \
    2>&1 | tee "$OUT_DIR/ffprobe_av_format.txt" | tee -a "$LOG"

log
log "========== packet count check =========="
ffprobe -hide_banner -v error \
    -select_streams v:0 \
    -show_packets \
    -of csv=p=0 \
    "$VIDEO_MP4" \
    > "$OUT_DIR/ffprobe_video_packets.csv" 2>/dev/null || true

PTS_ROWS=$(python3 - <<PY
from pathlib import Path
p = Path("$PTS_CSV")
if not p.exists():
    print(0)
else:
    lines = p.read_text().strip().splitlines()
    print(max(0, len(lines)-1))
PY
)

MP4_VIDEO_PACKETS=$(wc -l < "$OUT_DIR/ffprobe_video_packets.csv" 2>/dev/null || echo 0)

log "PTS_ROWS=$PTS_ROWS"
log "MP4_VIDEO_PACKETS=$MP4_VIDEO_PACKETS"

log
log "========== decode check =========="
set +e
ffmpeg -hide_banner -v warning -nostdin \
    -i "$AV_MP4" \
    -f null - \
    > "$OUT_DIR/ffmpeg_decode_check.log" 2>&1
DECODE_RC=$?
set -e

log "DECODE_RC=$DECODE_RC"
cat "$OUT_DIR/ffmpeg_decode_check.log" | tee -a "$LOG"

log
log "========== abnormal check =========="
{
    echo "detect_async_mpp:"
    grep -nEi "select timeout|GET_EXTRA_INFO|unsafe|Segmentation|段错误|failed|error|invalid|negative|non-positive|RGA_COLORFILL|Thread message queue|async_encode_failures|async_drop_frames" "$OUT_DIR/detect_async_mpp.log" || true

    echo
    echo "ffmpeg_audio_capture:"
    grep -nEi "xrun|overrun|underrun|error|failed|Invalid|Input/output|Thread message queue" "$OUT_DIR/ffmpeg_audio_capture.log" || true

    echo
    echo "mux_video_only:"
    grep -nEi "Timestamps are unset|Non-monotonous|invalid|error|failed|deprecated|Application provided invalid" "$OUT_DIR/mux_video_only.log" || true

    echo
    echo "ffmpeg_av_mux:"
    grep -nEi "Timestamps are unset|Non-monotonous|invalid|error|failed|deprecated|Application provided invalid" "$OUT_DIR/ffmpeg_av_mux.log" || true

    echo
    echo "decode_check:"
    grep -nEi "error|failed|Invalid|Non-monotonous|corrupt|missing" "$OUT_DIR/ffmpeg_decode_check.log" || true
} | tee "$OUT_DIR/abnormal.txt" | tee -a "$LOG"

log
log "========== final summary =========="

ASYNC_ENCODED=$(grep -E "async_encoded_frames" "$OUT_DIR/detect_async_mpp.log" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}' || true)
ASYNC_FAIL=$(grep -E "async_encode_failures" "$OUT_DIR/detect_async_mpp.log" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}' || true)
ASYNC_DROP=$(grep -E "async_drop_frames" "$OUT_DIR/detect_async_mpp.log" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}' || true)
WALL_FPS=$(grep -E "wall_fps" "$OUT_DIR/detect_async_mpp.log" | tail -1 | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}' || true)

VIDEO_STREAM_OK=$(grep -c "codec_type=video" "$OUT_DIR/ffprobe_av_streams.txt" || true)
AUDIO_STREAM_OK=$(grep -c "codec_type=audio" "$OUT_DIR/ffprobe_av_streams.txt" || true)

ABNORMAL_LINES=$(grep -nEi "select timeout|GET_EXTRA_INFO|unsafe|Segmentation|段错误|xrun|overrun|underrun|Timestamps are unset|Non-monotonous|Application provided invalid|corrupt|missing|RGA_COLORFILL|Thread message queue" "$OUT_DIR/abnormal.txt" | wc -l || true)

RESULT=FAIL
if [ "$DETECT_RC" = "0" ] && \
   [ "$AUDIO_RC" = "0" ] && \
   [ "$MUX_VIDEO_RC" = "0" ] && \
   [ "$MUX_AV_RC" = "0" ] && \
   [ "$DECODE_RC" = "0" ] && \
   [ "${ASYNC_ENCODED:-0}" = "$FRAMES" ] && \
   [ "${ASYNC_FAIL:-1}" = "0" ] && \
   [ "${ASYNC_DROP:-1}" = "0" ] && \
   [ "$PTS_ROWS" = "$FRAMES" ] && \
   [ "$VIDEO_STREAM_OK" -ge 1 ] && \
   [ "$AUDIO_STREAM_OK" -ge 1 ] && \
   [ "$ABNORMAL_LINES" = "0" ]; then
    RESULT=PASS
fi

{
    echo "# exp25-2 sync AV MP4 record"
    echo
    echo "OUT_DIR=$OUT_DIR"
    echo "frames=$FRAMES"
    echo "width=$WIDTH"
    echo "height=$HEIGHT"
    echo "fps=$FPS"
    echo "video_duration_s=$VIDEO_DUR"
    echo
    echo "audio_dev=$AUDIO_DEV"
    echo "audio_rate=$AUDIO_RATE"
    echo "audio_ch=$AUDIO_CH"
    echo "audio_duration_s=$AUDIO_DUR"
    echo "audio_lead_sec=$AUDIO_LEAD_SEC"
    echo
    echo "detect_rc=$DETECT_RC"
    echo "audio_rc=$AUDIO_RC"
    echo "mux_video_rc=$MUX_VIDEO_RC"
    echo "mux_av_rc=$MUX_AV_RC"
    echo "decode_rc=$DECODE_RC"
    echo
    echo "async_encoded_frames=${ASYNC_ENCODED:-}"
    echo "async_encode_failures=${ASYNC_FAIL:-}"
    echo "async_drop_frames=${ASYNC_DROP:-}"
    echo "wall_fps=${WALL_FPS:-}"
    echo
    echo "pts_rows=$PTS_ROWS"
    echo "mp4_video_packets=$MP4_VIDEO_PACKETS"
    echo "abnormal_lines=$ABNORMAL_LINES"
    echo
    echo "h264=$H264"
    echo "pts_csv=$PTS_CSV"
    echo "video_mp4=$VIDEO_MP4"
    echo "audio_m4a=$AUDIO_M4A"
    echo "av_mp4=$AV_MP4"
    echo "profile_csv=$PROFILE_CSV"
    echo
    echo "result=$RESULT"
} | tee "$OUT_DIR/summary.txt" | tee -a "$LOG"

log
log "exp25-2 done."
log "summary: $OUT_DIR/summary.txt"
log "output : $AV_MP4"

exit 0

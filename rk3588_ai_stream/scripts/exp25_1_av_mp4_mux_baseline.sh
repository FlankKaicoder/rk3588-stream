#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp25_1_av_mp4_mux_baseline
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/25_1.log"
: > "$LOG"

log() {
    echo "$@" | tee -a "$LOG"
}

run() {
    log
    log "========== $* =========="
    "$@" 2>&1 | tee -a "$LOG"
}

log "========== exp25-1 av mp4 mux baseline =========="
date | tee -a "$LOG"

log
log "========== set performance governor =========="
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$g" >/dev/null || true
done
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq | tee -a "$LOG" || true

log
log "========== find latest exp24 mp4 =========="
VIDEO_MP4=$(find output -type f -path "*/exp24_3_realtime_mp4_record_*/*" -name "realtime_detect_*.mp4" | sort | tail -1 || true)

if [ -z "${VIDEO_MP4:-}" ] || [ ! -f "$VIDEO_MP4" ]; then
    log "ERROR: cannot find experiment24 realtime_detect mp4."
    log "Please check:"
    log "  find output -type f -name '*.mp4' | sort | tail -30"
    exit 1
fi

log "VIDEO_MP4=$VIDEO_MP4"
ls -lh "$VIDEO_MP4" | tee -a "$LOG"

log
log "========== video stream info =========="
ffprobe -hide_banner -v error \
    -select_streams v:0 \
    -show_entries stream=codec_name,width,height,r_frame_rate,avg_frame_rate,time_base,duration,nb_frames,bit_rate \
    -of default=noprint_wrappers=1 \
    "$VIDEO_MP4" \
    2>&1 | tee "$OUT_DIR/video_stream_info.txt" | tee -a "$LOG"

DUR=$(ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$VIDEO_MP4")

log
log "video duration raw: $DUR"

# 给音频多录 0.5 秒，最后 mux 时用 -shortest 截断到较短轨道，避免音频短一点导致尾部无声。
AUDIO_DUR=$(python3 - <<PY
dur = float("$DUR")
print(f"{dur + 0.5:.3f}")
PY
)

log "audio capture duration: $AUDIO_DUR s"

AUDIO_M4A="$OUT_DIR/exp25_1_audio_48k_stereo_aac.m4a"
OUT_MP4="$OUT_DIR/exp25_1_av_mux_baseline.mp4"

log
log "========== audio device check =========="
arecord -l 2>&1 | tee "$OUT_DIR/arecord_l.txt" | tee -a "$LOG" || true
cat /proc/asound/pcm 2>/dev/null | tee "$OUT_DIR/proc_asound_pcm.txt" | tee -a "$LOG" || true

log
log "========== capture AAC audio =========="
ffmpeg -hide_banner -y -nostdin \
    -f alsa \
    -ac 2 \
    -ar 48000 \
    -i hw:2,0 \
    -t "$AUDIO_DUR" \
    -c:a aac \
    -b:a 128k \
    "$AUDIO_M4A" \
    > "$OUT_DIR/ffmpeg_audio_capture.log" 2>&1

cat "$OUT_DIR/ffmpeg_audio_capture.log" | tail -80 | tee -a "$LOG"

log
log "========== audio file check =========="
ls -lh "$AUDIO_M4A" | tee -a "$LOG"

ffprobe -hide_banner -v error \
    -show_entries stream=index,codec_type,codec_name,sample_rate,channels,channel_layout,duration,bit_rate \
    -of default=noprint_wrappers=1 \
    "$AUDIO_M4A" \
    2>&1 | tee "$OUT_DIR/audio_stream_info.txt" | tee -a "$LOG"

log
log "========== mux video mp4 + audio m4a to av mp4 =========="
ffmpeg -hide_banner -y -nostdin \
    -i "$VIDEO_MP4" \
    -i "$AUDIO_M4A" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a copy \
    -shortest \
    -movflags +faststart \
    "$OUT_MP4" \
    > "$OUT_DIR/ffmpeg_av_mux.log" 2>&1

cat "$OUT_DIR/ffmpeg_av_mux.log" | tail -120 | tee -a "$LOG"

log
log "========== output av mp4 =========="
ls -lh "$OUT_MP4" | tee -a "$LOG"

log
log "========== ffprobe av streams =========="
ffprobe -hide_banner -v error \
    -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,time_base,duration,nb_frames,sample_rate,channels,channel_layout,bit_rate \
    -of default=noprint_wrappers=1 \
    "$OUT_MP4" \
    2>&1 | tee "$OUT_DIR/ffprobe_av_streams.txt" | tee -a "$LOG"

log
log "========== ffprobe format =========="
ffprobe -hide_banner -v error \
    -show_entries format=duration,size,bit_rate \
    -of default=noprint_wrappers=1 \
    "$OUT_MP4" \
    2>&1 | tee "$OUT_DIR/ffprobe_av_format.txt" | tee -a "$LOG"

log
log "========== decode check =========="
ffmpeg -hide_banner -v warning -nostdin \
    -i "$OUT_MP4" \
    -f null - \
    > "$OUT_DIR/ffmpeg_decode_check.log" 2>&1 || true

cat "$OUT_DIR/ffmpeg_decode_check.log" | tee -a "$LOG"

log
log "========== abnormal check =========="
{
    echo "ffmpeg_audio_capture:"
    grep -nEi "xrun|overrun|underrun|error|failed|Invalid|Input/output|Thread message queue" "$OUT_DIR/ffmpeg_audio_capture.log" || true

    echo
    echo "ffmpeg_av_mux:"
    grep -nEi "Timestamps are unset|Non-monotonous|invalid|error|failed|deprecated|Application provided invalid" "$OUT_DIR/ffmpeg_av_mux.log" || true

    echo
    echo "decode_check:"
    grep -nEi "error|failed|Invalid|Non-monotonous|corrupt|missing" "$OUT_DIR/ffmpeg_decode_check.log" || true
} | tee "$OUT_DIR/abnormal.txt" | tee -a "$LOG"

log
log "========== summary =========="
{
    echo "VIDEO_MP4=$VIDEO_MP4"
    echo "AUDIO_M4A=$AUDIO_M4A"
    echo "OUT_MP4=$OUT_MP4"
    echo
    echo "files:"
    ls -lh "$VIDEO_MP4" "$AUDIO_M4A" "$OUT_MP4"
    echo
    echo "streams:"
    ffprobe -v error \
        -show_entries stream=index,codec_type,codec_name,width,height,sample_rate,channels,duration,nb_frames \
        -of compact=p=0:nk=1 \
        "$OUT_MP4"
} | tee "$OUT_DIR/summary.txt" | tee -a "$LOG"

log
log "exp25-1 done."
log "summary: $OUT_DIR/summary.txt"
log "output : $OUT_MP4"

#!/usr/bin/env bash
set -u

cd ~/projects/rk3588_ai_stream

WIDTH=${1:-1280}
HEIGHT=${2:-720}
FPS=${3:-30}
FRAMES=${4:-9000}
AUDIO_DEV=${5:-hw:2,0}
AUDIO_RATE=${6:-48000}
AUDIO_CH=${7:-2}
STREAM_PATH=${8:-final_ai_av_rtsp}

LOG_DIR=output/final
mkdir -p "$LOG_DIR"

LOG="$LOG_DIR/run_final_av_rtsp.log"
: > "$LOG"

log() {
    echo "$@" | tee -a "$LOG"
}

log "========== final AI AV RTSP start =========="
date | tee -a "$LOG"

log
log "WIDTH       = $WIDTH"
log "HEIGHT      = $HEIGHT"
log "FPS         = $FPS"
log "FRAMES      = $FRAMES"
log "AUDIO_DEV   = $AUDIO_DEV"
log "AUDIO_RATE  = $AUDIO_RATE"
log "AUDIO_CH    = $AUDIO_CH"
log "STREAM_PATH = $STREAM_PATH"

log
log "========== set CPU governor performance =========="

for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$g" >/dev/null
done

cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tee -a "$LOG"

log
log "========== cleanup old stream processes =========="

pkill -f "exp21_detect_mpp_encode_async" 2>/dev/null || true
pkill -f "ffmpeg.*final_ai_av_rtsp" 2>/dev/null || true
pkill -f "ffmpeg.*${STREAM_PATH}" 2>/dev/null || true
pkill -f "mediamtx.*exp" 2>/dev/null || true
pkill -f "mediamtx.*final" 2>/dev/null || true

sleep 1

ps -ef | grep -E "exp21_detect_mpp_encode_async|ffmpeg|mediamtx" | grep -v grep | tee -a "$LOG" || echo "no old stream process" | tee -a "$LOG"

log
log "========== build target check =========="

if [ ! -x build/exp21_detect_mpp_encode_async ]; then
    log "ERROR: build/exp21_detect_mpp_encode_async not found."
    log "Please run:"
    log "  rm -rf build && mkdir build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make exp21_detect_mpp_encode_async -j4"
    exit 1
fi

if [ ! -x scripts/exp22_av_async_mpp_rtsp.sh ]; then
    log "ERROR: scripts/exp22_av_async_mpp_rtsp.sh not found or not executable."
    exit 1
fi

log "build/exp21_detect_mpp_encode_async OK"
log "scripts/exp22_av_async_mpp_rtsp.sh OK"

BOARD_IP=$(hostname -I | awk '{print $1}')
RTSP_URL="rtsp://${BOARD_IP}:8554/${STREAM_PATH}"

log
log "========== playback =========="
log "RTSP URL:"
log "  $RTSP_URL"
log
log "Recommended VLC:"
log "  vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none $RTSP_URL"

log
log "========== run final chain =========="

./scripts/exp22_av_async_mpp_rtsp.sh \
  "$WIDTH" \
  "$HEIGHT" \
  "$FPS" \
  "$FRAMES" \
  "$AUDIO_DEV" \
  "$AUDIO_RATE" \
  "$AUDIO_CH" \
  "$STREAM_PATH" \
  2>&1 | tee -a "$LOG"

RC=${PIPESTATUS[0]}

log
log "========== final chain exited =========="
log "RC=$RC"

log
log "========== latest output =========="
OUT=$(ls -td output/exp22_av_async_mpp_rtsp_${FRAMES}f_* 2>/dev/null | head -1 || true)
if [ -n "$OUT" ]; then
    log "OUT=$OUT"
    if [ -f "$OUT/summary.txt" ]; then
        log
        log "========== summary =========="
        cat "$OUT/summary.txt" | tee -a "$LOG"
    fi
else
    log "WARN: no output dir found"
fi

exit "$RC"

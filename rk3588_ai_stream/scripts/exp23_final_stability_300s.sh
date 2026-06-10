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
STREAM_PATH=${8:-exp23_final_av_rtsp_300s}
MON_INTERVAL=${9:-5}

TS=$(date +%Y%m%d_%H%M%S)
MASTER_DIR=output/exp23_final_stability_${FRAMES}f_${TS}
mkdir -p "$MASTER_DIR"

MASTER_LOG="$MASTER_DIR/exp23_master.log"
EXP22_RUN_LOG="$MASTER_DIR/exp22_script_stdout.log"

: > "$MASTER_LOG"

log() {
    echo "$@" | tee -a "$MASTER_LOG"
}

log "========== exp23 final stability start =========="
date | tee -a "$MASTER_LOG"

log
log "WIDTH        = $WIDTH"
log "HEIGHT       = $HEIGHT"
log "FPS          = $FPS"
log "FRAMES       = $FRAMES"
log "AUDIO_DEV    = $AUDIO_DEV"
log "AUDIO_RATE   = $AUDIO_RATE"
log "AUDIO_CH     = $AUDIO_CH"
log "STREAM_PATH  = $STREAM_PATH"
log "MON_INTERVAL = $MON_INTERVAL"
log "MASTER_DIR   = $MASTER_DIR"

log
log "========== set CPU governor performance =========="

for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$g" >/dev/null
done

cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tee -a "$MASTER_LOG"

log
log "========== cleanup old processes =========="

pkill -f "exp21_detect_mpp_encode_async" 2>/dev/null || true
pkill -f "ffmpeg.*exp2" 2>/dev/null || true
pkill -f "mediamtx.*exp2" 2>/dev/null || true

sleep 1

ps -ef | grep -E "exp21_detect_mpp_encode_async|ffmpeg|mediamtx" | grep -v grep | tee -a "$MASTER_LOG" || echo "no old stream process" | tee -a "$MASTER_LOG"

log
log "========== start exp22 final AV RTSP script =========="

./scripts/exp22_av_async_mpp_rtsp.sh \
  "$WIDTH" \
  "$HEIGHT" \
  "$FPS" \
  "$FRAMES" \
  "$AUDIO_DEV" \
  "$AUDIO_RATE" \
  "$AUDIO_CH" \
  "$STREAM_PATH" \
  > "$EXP22_RUN_LOG" 2>&1 &

EXP22_PID=$!

log "EXP22_PID = $EXP22_PID"

log
log "========== wait exp22 out dir =========="

EXP22_OUT=""

for i in $(seq 1 30); do
    sleep 1
    EXP22_OUT=$(grep -m1 "^OUT_DIR" "$EXP22_RUN_LOG" 2>/dev/null | awk -F'= ' '{print $2}' | tr -d '\r')
    if [ -n "$EXP22_OUT" ] && [ -d "$EXP22_OUT" ]; then
        break
    fi
done

if [ -z "$EXP22_OUT" ] || [ ! -d "$EXP22_OUT" ]; then
    log "ERROR: cannot find exp22 OUT_DIR from $EXP22_RUN_LOG"
    log "===== exp22 log tail ====="
    tail -120 "$EXP22_RUN_LOG" | tee -a "$MASTER_LOG"
    exit 1
fi

log "EXP22_OUT = $EXP22_OUT"

log
log "========== start resource monitor =========="

./scripts/exp23_resource_monitor.sh "$EXP22_OUT" "$MON_INTERVAL" "$EXP22_PID" \
  > "$MASTER_DIR/resource_monitor_stdout.log" 2>&1 &

MON_PID=$!

log "MON_PID = $MON_PID"

log
log "========== wait exp22 finish =========="

wait "$EXP22_PID"
EXP22_RC=$?

log "EXP22_RC = $EXP22_RC"

sleep 2

if kill -0 "$MON_PID" 2>/dev/null; then
    kill "$MON_PID" 2>/dev/null || true
fi

log
log "========== collect final result =========="

{
    echo "MASTER_DIR=$MASTER_DIR"
    echo "EXP22_OUT=$EXP22_OUT"
    echo "EXP22_RC=$EXP22_RC"
    echo
    echo "========== summary =========="
    cat "$EXP22_OUT/summary.txt" 2>/dev/null || true
    echo
    echo "========== ffprobe =========="
    cat "$EXP22_OUT/ffprobe_av_rtsp.log" 2>/dev/null || true
    echo
    echo "========== detect result =========="
    grep -E "frames|wall_fps|avg_model_total_ms|avg_total_ms|async_encoded_frames|async_encode_failures|async_drop_frames|async_avg" "$EXP22_OUT/detect_async_mpp_h264_fifo.log" 2>/dev/null || true
    echo
    echo "========== mediamtx key lines =========="
    grep -E "stream is available|2 tracks|is publishing|is reading|shutting down gracefully" "$EXP22_OUT/mediamtx.log" 2>/dev/null || true
    echo
    echo "========== real abnormal lines =========="
    grep -nH -E \
      "RGA_COLORFILL|Failed to call RockChipRga|xrun|Thread message queue blocking|Timestamps are unset|Broken pipe" \
      "$EXP22_OUT/detect_async_mpp_h264_fifo.log" \
      "$EXP22_OUT/ffmpeg_av_rtsp.log" \
      "$EXP22_OUT/mediamtx.log" \
      "$EXP22_OUT/ffprobe_av_rtsp.log" \
      2>/dev/null || echo "no real abnormal lines"
    echo
    echo "========== resource csv tail =========="
    tail -20 "$EXP22_OUT/resource_samples.csv" 2>/dev/null || true
} | tee "$MASTER_DIR/final_report.txt" | tee -a "$MASTER_LOG"

log
log "========== exp23 final stability done =========="
log "MASTER_DIR: $MASTER_DIR"
log "EXP22_OUT : $EXP22_OUT"

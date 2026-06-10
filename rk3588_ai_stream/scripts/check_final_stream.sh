#!/usr/bin/env bash
set -u

cd ~/projects/rk3588_ai_stream

STREAM_PATH=${1:-final_ai_av_rtsp}
BOARD_IP=$(hostname -I | awk '{print $1}')
LOCAL_URL="rtsp://127.0.0.1:8554/${STREAM_PATH}"
LAN_URL="rtsp://${BOARD_IP}:8554/${STREAM_PATH}"

echo "========== final stream check =========="
date

echo
echo "STREAM_PATH = $STREAM_PATH"
echo "LOCAL_URL   = $LOCAL_URL"
echo "LAN_URL     = $LAN_URL"

echo
echo "========== governor =========="
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c || true

echo
echo "========== freq =========="
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [ -r "$f" ] && echo "$f $(cat "$f")"
done 2>/dev/null

echo
echo "========== thermal =========="
for z in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$z" ] && echo "$z $(cat "$z")"
done 2>/dev/null

echo
echo "========== processes =========="
ps -eo pid,ppid,stat,pcpu,pmem,rss,comm,args | grep -E "exp21_detect_mpp_encode_async|ffmpeg|mediamtx" | grep -v grep || echo "no stream process"

echo
echo "========== ports =========="
ss -ltnp 2>/dev/null | grep -E ":8554|:1935|:8888|:8889|:8890" || echo "no stream port"

echo
echo "========== ffprobe =========="
timeout 8 ffprobe -hide_banner -rtsp_transport tcp "$LOCAL_URL" 2>&1 || echo "ffprobe failed"

echo
echo "========== latest exp22 output =========="
OUT=$(ls -td output/exp22_av_async_mpp_rtsp_* 2>/dev/null | head -1 || true)
echo "$OUT"

if [ -n "$OUT" ] && [ -d "$OUT" ]; then
    echo
    echo "========== summary =========="
    cat "$OUT/summary.txt" 2>/dev/null || echo "no summary.txt"

    echo
    echo "========== detect result =========="
    grep -E "frames|wall_fps|avg_model_total_ms|avg_total_ms|async_encoded_frames|async_encode_failures|async_drop_frames|async_avg" "$OUT/detect_async_mpp_h264_fifo.log" 2>/dev/null || true

    echo
    echo "========== real abnormal lines =========="
    grep -nH -E \
      "RGA_COLORFILL|Failed to call RockChipRga|xrun|Thread message queue blocking|Timestamps are unset|Broken pipe" \
      "$OUT/detect_async_mpp_h264_fifo.log" \
      "$OUT/ffmpeg_av_rtsp.log" \
      "$OUT/mediamtx.log" \
      "$OUT/ffprobe_av_rtsp.log" \
      2>/dev/null || echo "no real abnormal lines"
fi

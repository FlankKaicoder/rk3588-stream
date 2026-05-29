#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp09_stream_probe
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/probe.log"
: > "$LOG"

run_cmd() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

echo "09 stream probe start" | tee -a "$LOG"
date | tee -a "$LOG"

echo
echo "========== system ==========" | tee -a "$LOG"
uname -a | tee -a "$LOG"
cat /etc/os-release 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== board ip ==========" | tee -a "$LOG"
hostname -I 2>/dev/null | tee -a "$LOG" || true
ip addr 2>/dev/null | grep -E "inet " | tee -a "$LOG" || true

echo
echo "========== ffmpeg ==========" | tee -a "$LOG"
which ffmpeg 2>/dev/null | tee -a "$LOG" || true
ffmpeg -version 2>/dev/null | head -20 | tee -a "$LOG" || true

echo
echo "========== ffprobe ==========" | tee -a "$LOG"
which ffprobe 2>/dev/null | tee -a "$LOG" || true
ffprobe -version 2>/dev/null | head -10 | tee -a "$LOG" || true

echo
echo "========== ffplay ==========" | tee -a "$LOG"
which ffplay 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== streaming servers ==========" | tee -a "$LOG"
which mediamtx 2>/dev/null | tee -a "$LOG" || true
which rtsp-simple-server 2>/dev/null | tee -a "$LOG" || true
which ZLMediaKit 2>/dev/null | tee -a "$LOG" || true
which MediaServer 2>/dev/null | tee -a "$LOG" || true
which nginx 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== ffmpeg protocols ==========" | tee -a "$LOG"
ffmpeg -hide_banner -protocols 2>/dev/null | grep -E "rtsp|rtmp|http|tcp|udp|file" | tee -a "$LOG" || true

echo
echo "========== ffmpeg muxers ==========" | tee -a "$LOG"
ffmpeg -hide_banner -muxers 2>/dev/null | grep -E "rtsp|rtp|flv|hls|mpegts|mp4|h264" | tee -a "$LOG" || true

echo
echo "========== port check ==========" | tee -a "$LOG"
ss -lntup 2>/dev/null | grep -E ":8554|:8080|:8888|:1935" | tee -a "$LOG" || true

echo
echo "========== existing exp08 outputs ==========" | tee -a "$LOG"
find output -maxdepth 3 -type f \
    \( -name "*.mp4" -o -name "*.h264" -o -name "*.csv" \) \
    | sort \
    | grep -E "exp08|camera|mpp|detect|fifo|nv12" \
    | tee -a "$LOG" || true

echo
echo "probe log saved to: $LOG"

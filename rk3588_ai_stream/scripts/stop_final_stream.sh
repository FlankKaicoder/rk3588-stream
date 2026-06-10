#!/usr/bin/env bash
set -u

cd ~/projects/rk3588_ai_stream

echo "========== stop final stream =========="

pkill -f "exp21_detect_mpp_encode_async" 2>/dev/null || true
pkill -f "exp22_av_async_mpp_rtsp" 2>/dev/null || true
pkill -f "run_final_av_rtsp" 2>/dev/null || true
pkill -f "ffmpeg.*rtsp" 2>/dev/null || true
pkill -f "mediamtx" 2>/dev/null || true

sleep 1

echo
echo "========== remaining processes =========="
ps -ef | grep -E "exp21_detect_mpp_encode_async|exp22_av_async_mpp_rtsp|run_final_av_rtsp|ffmpeg|mediamtx" | grep -v grep || echo "no stream process"

echo
echo "========== ports =========="
ss -ltnp 2>/dev/null | grep -E ":8554|:1935|:8888|:8889|:8890" || echo "no stream port"

echo
echo "done."

#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp10_rtsp_probe
TOOLS_DIR=tools/mediamtx
LOG="$OUT_DIR/probe.log"

mkdir -p "$OUT_DIR" "$TOOLS_DIR"
: > "$LOG"

run_cmd() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

echo "10 RTSP probe start" | tee -a "$LOG"
date | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== system ==========" | tee -a "$LOG"
uname -a | tee -a "$LOG"
cat /etc/os-release 2>/dev/null | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== board ip ==========" | tee -a "$LOG"
BOARD_IP=$(hostname -I | awk '{print $1}')
echo "board ip: $BOARD_IP" | tee -a "$LOG"
ip addr 2>/dev/null | grep -E "inet " | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg / ffprobe / ffplay ==========" | tee -a "$LOG"
which ffmpeg 2>/dev/null | tee -a "$LOG" || true
ffmpeg -version 2>/dev/null | head -12 | tee -a "$LOG" || true
which ffprobe 2>/dev/null | tee -a "$LOG" || true
which ffplay 2>/dev/null | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg RTSP support ==========" | tee -a "$LOG"
ffmpeg -hide_banner -protocols 2>/dev/null | grep -E "rtsp|rtp|tcp|udp|http|file" | tee -a "$LOG" || true
ffmpeg -hide_banner -muxers 2>/dev/null | grep -E "rtsp|rtp|h264|mpegts|flv|hls|mp4" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== existing RTSP servers ==========" | tee -a "$LOG"
which mediamtx 2>/dev/null | tee -a "$LOG" || true
which rtsp-simple-server 2>/dev/null | tee -a "$LOG" || true
which ZLMediaKit 2>/dev/null | tee -a "$LOG" || true
which MediaServer 2>/dev/null | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== port check before ==========" | tee -a "$LOG"
ss -lntup 2>/dev/null | grep -E ":8554|:8888|:1935|:8080" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== existing exp08 / exp09 outputs ==========" | tee -a "$LOG"
find output -maxdepth 3 -type f \
    \( -name "*.mp4" -o -name "*.h264" -o -name "*.csv" -o -name "*.m3u8" \) \
    | sort \
    | grep -E "exp08|exp09|detect|hls|mpp|fifo|nv12" \
    | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== check mediamtx local binary ==========" | tee -a "$LOG"

if command -v mediamtx >/dev/null 2>&1; then
    echo "system mediamtx found: $(command -v mediamtx)" | tee -a "$LOG"
    mediamtx --version 2>&1 | tee -a "$LOG" || true
elif [ -x "$TOOLS_DIR/mediamtx" ]; then
    echo "local mediamtx found: $TOOLS_DIR/mediamtx" | tee -a "$LOG"
    "$TOOLS_DIR/mediamtx" --version 2>&1 | tee -a "$LOG" || true
else
    echo "mediamtx not found, try downloading latest linux arm64 release..." | tee -a "$LOG"

    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl not found. Please install curl or manually copy mediamtx to $TOOLS_DIR/mediamtx" | tee -a "$LOG"
        exit 0
    fi

    API_JSON="$OUT_DIR/mediamtx_latest.json"
    curl -fsSL https://api.github.com/repos/bluenviron/mediamtx/releases/latest -o "$API_JSON" || {
        echo "ERROR: cannot access GitHub. You can manually download linux_arm64v8 tar.gz and extract mediamtx into $TOOLS_DIR/" | tee -a "$LOG"
        exit 0
    }

    URL=$(grep "browser_download_url" "$API_JSON" \
        | grep -E "linux_arm64v8.*tar.gz|linux_arm64.*tar.gz" \
        | head -n 1 \
        | sed 's/.*"browser_download_url": "\(.*\)".*/\1/')

    if [ -z "$URL" ]; then
        echo "ERROR: cannot find linux arm64 mediamtx release asset." | tee -a "$LOG"
        echo "Please open $API_JSON and manually check release asset name." | tee -a "$LOG"
        exit 0
    fi

    echo "download url: $URL" | tee -a "$LOG"

    TARBALL="$OUT_DIR/mediamtx_linux_arm64.tar.gz"
    curl -L "$URL" -o "$TARBALL"

    tar -xzf "$TARBALL" -C "$TOOLS_DIR"
    chmod +x "$TOOLS_DIR/mediamtx"

    echo "downloaded mediamtx:" | tee -a "$LOG"
    ls -lh "$TOOLS_DIR" | tee -a "$LOG"
    "$TOOLS_DIR/mediamtx" --version 2>&1 | tee -a "$LOG" || true
fi

echo | tee -a "$LOG"
echo "========== final mediamtx path ==========" | tee -a "$LOG"
if command -v mediamtx >/dev/null 2>&1; then
    echo "$(command -v mediamtx)" | tee -a "$LOG"
elif [ -x "$TOOLS_DIR/mediamtx" ]; then
    echo "$TOOLS_DIR/mediamtx" | tee -a "$LOG"
else
    echo "mediamtx still not available." | tee -a "$LOG"
fi

echo | tee -a "$LOG"
echo "10-0 done. log saved to: $LOG" | tee -a "$LOG"

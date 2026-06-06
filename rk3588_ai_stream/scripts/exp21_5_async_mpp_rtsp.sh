#!/usr/bin/env bash
set -euo pipefail

WIDTH="${1:-1280}"
HEIGHT="${2:-720}"
FPS="${3:-30}"
FRAMES="${4:-900}"
MODEL="${5:-models/yolo11.rknn}"
VIDEO_DEV="${6:-/dev/video11}"
STREAM_PATH="${7:-exp21_5_async_mpp_rtsp}"

TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="output/exp21_5_async_mpp_rtsp_${FRAMES}f_${TS}"

mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/21_5.log"
FIFO="$OUT_DIR/detect_h264.fifo"
PROFILE_CSV="$OUT_DIR/profile_detect_mpp_async_rtsp.csv"
MEDIAMTX_CFG="$OUT_DIR/mediamtx_exp21_5.yml"
MEDIAMTX_LOG="$OUT_DIR/mediamtx.log"
FFMPEG_LOG="$OUT_DIR/ffmpeg_h264_fifo_rtsp.log"
DETECT_LOG="$OUT_DIR/detect_async_mpp_to_h264_fifo.log"
FFPROBE_10S="$OUT_DIR/ffprobe_10s.log"
FFPROBE_END="$OUT_DIR/ffprobe_end.log"

STREAM_URL_LOCAL="rtsp://127.0.0.1:8554/${STREAM_PATH}"

echo "========== exp21-5 async mpp rtsp ==========" | tee -a "$LOG"
echo "width       : $WIDTH" | tee -a "$LOG"
echo "height      : $HEIGHT" | tee -a "$LOG"
echo "fps         : $FPS" | tee -a "$LOG"
echo "frames      : $FRAMES" | tee -a "$LOG"
echo "model       : $MODEL" | tee -a "$LOG"
echo "video dev   : $VIDEO_DEV" | tee -a "$LOG"
echo "stream path : $STREAM_PATH" | tee -a "$LOG"
echo "out dir     : $OUT_DIR" | tee -a "$LOG"
echo "local url   : $STREAM_URL_LOCAL" | tee -a "$LOG"
echo "============================================" | tee -a "$LOG"

if [ ! -x ./build/exp21_detect_mpp_encode_async ]; then
    echo "[ERR] ./build/exp21_detect_mpp_encode_async not found or not executable" | tee -a "$LOG"
    echo "Please build it first:" | tee -a "$LOG"
    echo "  mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make exp21_detect_mpp_encode_async -j4" | tee -a "$LOG"
    exit 1
fi

if [ ! -f "$MODEL" ]; then
    echo "[ERR] model not found: $MODEL" | tee -a "$LOG"
    exit 1
fi

find_mediamtx() {
    if command -v mediamtx >/dev/null 2>&1; then
        command -v mediamtx
        return 0
    fi

    for p in \
        ./mediamtx \
        ./tools/mediamtx/mediamtx \
        ./tools/mediamtx \
        ./third_party/mediamtx/mediamtx \
        ./third_party/mediamtx \
        /usr/local/bin/mediamtx \
        /usr/bin/mediamtx \
        "$HOME/mediamtx/mediamtx" \
        "$HOME/mediamtx"
    do
        # 注意：目录也可能满足 -x，所以必须同时要求 -f。
        if [ -f "$p" ] && [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done

    return 1
}

MEDIAMTX_BIN="$(find_mediamtx || true)"
if [ -z "${MEDIAMTX_BIN}" ]; then
    echo "[ERR] mediamtx binary not found" | tee -a "$LOG"
    echo "Please make sure mediamtx is in PATH or under ./tools/mediamtx" | tee -a "$LOG"
    exit 1
fi

echo "mediamtx bin: $MEDIAMTX_BIN" | tee -a "$LOG"

cleanup() {
    echo "========== exp21-5 cleanup ==========" | tee -a "$LOG" || true

    if [ -n "${DETECT_PID:-}" ] && kill -0 "$DETECT_PID" 2>/dev/null; then
        echo "kill detect pid=$DETECT_PID" | tee -a "$LOG" || true
        kill "$DETECT_PID" 2>/dev/null || true
        wait "$DETECT_PID" 2>/dev/null || true
    fi

    if [ -n "${FFMPEG_PID:-}" ] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        echo "kill ffmpeg pid=$FFMPEG_PID" | tee -a "$LOG" || true
        kill "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "${MEDIAMTX_PID:-}" ] && kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
        echo "kill mediamtx pid=$MEDIAMTX_PID" | tee -a "$LOG" || true
        kill "$MEDIAMTX_PID" 2>/dev/null || true
        wait "$MEDIAMTX_PID" 2>/dev/null || true
    fi

    rm -f "$FIFO" 2>/dev/null || true
}
trap cleanup EXIT

echo "========== prepare fifo ==========" | tee -a "$LOG"
rm -f "$FIFO"
mkfifo "$FIFO"
ls -lh "$FIFO" | tee -a "$LOG"

cat > "$MEDIAMTX_CFG" <<YAML
rtspAddress: :8554

# 21-5 主验证 RTSP。先关闭 HLS/WebRTC，避免额外转封装日志干扰。
hls: false
webrtc: false

paths:
  all_others:
YAML

echo "========== start mediamtx ==========" | tee -a "$LOG"
"$MEDIAMTX_BIN" "$MEDIAMTX_CFG" > "$MEDIAMTX_LOG" 2>&1 &
MEDIAMTX_PID=$!
echo "mediamtx pid: $MEDIAMTX_PID" | tee -a "$LOG"

sleep 2

echo "========== start ffmpeg h264 fifo -> rtsp ==========" | tee -a "$LOG"

ffmpeg -hide_banner -loglevel info \
  -fflags +genpts \
  -f h264 \
  -r "$FPS" \
  -i "$FIFO" \
  -an \
  -c:v copy \
  -f rtsp \
  -rtsp_transport tcp \
  "$STREAM_URL_LOCAL" \
  > "$FFMPEG_LOG" 2>&1 &
FFMPEG_PID=$!

echo "ffmpeg pid: $FFMPEG_PID" | tee -a "$LOG"

# 让 ffmpeg 先阻塞等待 FIFO writer
sleep 1

echo "========== start detect async mpp encoder ==========" | tee -a "$LOG"

./build/exp21_detect_mpp_encode_async \
  "$MODEL" \
  "$VIDEO_DEV" \
  "$WIDTH" \
  "$HEIGHT" \
  "$FRAMES" \
  "$FIFO" \
  "$PROFILE_CSV" \
  > "$DETECT_LOG" 2>&1 &
DETECT_PID=$!

echo "detect pid: $DETECT_PID" | tee -a "$LOG"

echo "========== wait stream online ==========" | tee -a "$LOG"
sleep 10

echo "========== ffprobe 10s ==========" | tee -a "$LOG"
timeout 15 ffprobe -hide_banner -rtsp_transport tcp "$STREAM_URL_LOCAL" \
  > "$FFPROBE_10S" 2>&1 || true
cat "$FFPROBE_10S" | tee -a "$LOG" || true

echo "========== wait detect finish ==========" | tee -a "$LOG"
wait "$DETECT_PID" || true
DETECT_PID=""

# 给 ffmpeg 一点时间把 FIFO 中剩余 h264 packet 推完
sleep 3

echo "========== ffprobe end ==========" | tee -a "$LOG"
timeout 15 ffprobe -hide_banner -rtsp_transport tcp "$STREAM_URL_LOCAL" \
  > "$FFPROBE_END" 2>&1 || true
cat "$FFPROBE_END" | tee -a "$LOG" || true

echo "========== stop ffmpeg / mediamtx ==========" | tee -a "$LOG"
if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    kill "$FFMPEG_PID" 2>/dev/null || true
    wait "$FFMPEG_PID" 2>/dev/null || true
fi
FFMPEG_PID=""

if kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    kill "$MEDIAMTX_PID" 2>/dev/null || true
    wait "$MEDIAMTX_PID" 2>/dev/null || true
fi
MEDIAMTX_PID=""

echo "========== key detect result ==========" | tee -a "$LOG"
grep -E "exp21-4 async|frames[[:space:]]*:|wall_fps|avg_|async_|output h264|profile csv|encoder thread exit" \
  "$DETECT_LOG" | tee -a "$LOG" || true

echo "========== key ffmpeg result ==========" | tee -a "$LOG"
grep -E "Input #|Output #|Stream #|frame=|fps=|bitrate=|speed=|error|Error|Broken pipe|Connection refused|404|failed|Invalid" \
  "$FFMPEG_LOG" | tail -120 | tee -a "$LOG" || true

echo "========== key mediamtx result ==========" | tee -a "$LOG"
grep -E "stream is available|publishing|reading|RTSP|ERR|WAR|error|failed" \
  "$MEDIAMTX_LOG" | tail -120 | tee -a "$LOG" || true

echo "========== generated files ==========" | tee -a "$LOG"
ls -lh "$OUT_DIR" | tee -a "$LOG"

echo "========== exp21-5 done ==========" | tee -a "$LOG"
echo "out dir: $OUT_DIR" | tee -a "$LOG"
echo "LAN URL example: rtsp://<board-ip>:8554/${STREAM_PATH}" | tee -a "$LOG"

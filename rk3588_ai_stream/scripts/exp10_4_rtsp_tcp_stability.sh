#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

DURATION_SEC="${1:-600}"

WIDTH=1280
HEIGHT=720
FPS=30
FRAMES=$((DURATION_SEC * FPS))

STAMP=$(date +"%Y%m%d_%H%M%S")

OUT_DIR="output/exp10_4_rtsp_tcp_stability_${DURATION_SEC}s_${STAMP}"
LOG="$OUT_DIR/10_4_tcp_stability.log"
CONF="$OUT_DIR/mediamtx_min.yml"

mkdir -p "$OUT_DIR"
: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

NV12_FIFO="$OUT_DIR/realtime_detect_nv12.fifo"
H264_FIFO="$OUT_DIR/realtime_detect_h264.fifo"
PROFILE="$OUT_DIR/profile_realtime_detect_rtsp_tcp_stability.csv"

rm -f "$NV12_FIFO" "$H264_FIFO" "$PROFILE"
mkfifo "$NV12_FIFO"
mkfifo "$H264_FIFO"

cat > "$CONF" <<'EOF_CONF'
rtspAddress: :8554

paths:
  all_others:
EOF_CONF

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    kill ${DETECT_PID:-0} 2>/dev/null || true
    kill ${ENC_PID:-0} 2>/dev/null || true
    kill ${FFMPEG_PID:-0} 2>/dev/null || true
    kill ${MEDIAMTX_PID:-0} 2>/dev/null || true

    pkill -f "v4l2_rga_rknn_detect_to_nv12_clean" 2>/dev/null || true
    pkill -f "mpi_enc_test" 2>/dev/null || true
    pkill -f "ffmpeg.*exp10_detect_stable" 2>/dev/null || true
    pkill -f mediamtx 2>/dev/null || true

    rm -f "$NV12_FIFO" "$H264_FIFO"
}
trap cleanup EXIT

echo "========== 10-4 RTSP TCP stability test ==========" | tee -a "$LOG"
echo "board ip     : $BOARD_IP" | tee -a "$LOG"
echo "duration sec : $DURATION_SEC" | tee -a "$LOG"
echo "frames       : $FRAMES" | tee -a "$LOG"
echo "width        : $WIDTH" | tee -a "$LOG"
echo "height       : $HEIGHT" | tee -a "$LOG"
echo "fps setting  : $FPS" | tee -a "$LOG"
echo "out dir      : $OUT_DIR" | tee -a "$LOG"
echo "profile      : $PROFILE" | tee -a "$LOG"
echo "rtsp path    : exp10_detect_stable" | tee -a "$LOG"

if [ ! -x ./tools/mediamtx/mediamtx ]; then
    echo "ERROR: ./tools/mediamtx/mediamtx not found or not executable" | tee -a "$LOG"
    exit 1
fi

if [ ! -x ./build/v4l2_rga_rknn_detect_to_nv12_clean ]; then
    echo "ERROR: ./build/v4l2_rga_rknn_detect_to_nv12_clean not found" | tee -a "$LOG"
    echo "Try:" | tee -a "$LOG"
    echo "  cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make v4l2_rga_rknn_detect_to_nv12_clean -j4" | tee -a "$LOG"
    exit 1
fi

echo | tee -a "$LOG"
echo "========== clean old processes ==========" | tee -a "$LOG"
pkill -f mediamtx 2>/dev/null || true
pkill -f "ffmpeg.*exp10_detect" 2>/dev/null || true
pkill -f mpi_enc_test 2>/dev/null || true
pkill -f v4l2_rga_rknn_detect_to_nv12_clean 2>/dev/null || true
sleep 1

echo | tee -a "$LOG"
echo "========== start mediamtx ==========" | tee -a "$LOG"

./tools/mediamtx/mediamtx "$CONF" > "$OUT_DIR/mediamtx.log" 2>&1 &
MEDIAMTX_PID=$!

sleep 2

ss -ltnp | grep 8554 | tee -a "$LOG" || {
    echo "ERROR: no 8554 listen" | tee -a "$LOG"
    tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG"
    exit 1
}

echo | tee -a "$LOG"
echo "========== start ffmpeg: H264 FIFO -> RTSP TCP ==========" | tee -a "$LOG"

ffmpeg -nostdin -y \
    -fflags nobuffer \
    -flags low_delay \
    -probesize 32 \
    -analyzeduration 0 \
    -use_wallclock_as_timestamps 1 \
    -f h264 \
    -framerate "$FPS" \
    -i "$H264_FIFO" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    "rtsp://127.0.0.1:8554/exp10_detect_stable" \
    > "$OUT_DIR/ffmpeg_push_rtsp.log" 2>&1 &

FFMPEG_PID=$!

sleep 1

echo | tee -a "$LOG"
echo "========== start MPP encoder: NV12 FIFO -> H264 FIFO ==========" | tee -a "$LOG"

/home/cat/mpp/build/test/mpi_enc_test \
    -i "$NV12_FIFO" \
    -o "$H264_FIFO" \
    -w "$WIDTH" \
    -h "$HEIGHT" \
    -f 0 \
    -t 7 \
    -n "$FRAMES" \
    > "$OUT_DIR/mpi_enc_rtsp.log" 2>&1 &

ENC_PID=$!

sleep 1

echo | tee -a "$LOG"
echo "========== start realtime detect writer: camera -> NV12 FIFO ==========" | tee -a "$LOG"

./build/v4l2_rga_rknn_detect_to_nv12_clean \
    models/yolo11.rknn \
    /dev/video11 \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$NV12_FIFO" \
    "$PROFILE" \
    > "$OUT_DIR/realtime_detect_to_nv12.log" 2>&1 &

DETECT_PID=$!

sleep 5

echo | tee -a "$LOG"
echo "========== initial mediamtx log ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mediamtx.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== initial ffmpeg log ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/ffmpeg_push_rtsp.log" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "RTSP URL:" | tee -a "$LOG"
echo "  rtsp://$BOARD_IP:8554/exp10_detect_stable" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "VLC recommended command:" | tee -a "$LOG"
echo "  vlc --rtsp-tcp --network-caching=300 --avcodec-hw=none rtsp://$BOARD_IP:8554/exp10_detect_stable" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "HLS backup URL:" | tee -a "$LOG"
echo "  http://$BOARD_IP:8888/exp10_detect_stable/index.m3u8" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== running monitor ==========" | tee -a "$LOG"
echo "每 30 秒打印一次状态，直到 ${DURATION_SEC}s 测试结束。" | tee -a "$LOG"

START_TS=$(date +%s)

while kill -0 "$DETECT_PID" 2>/dev/null; do
    NOW_TS=$(date +%s)
    ELAPSED=$((NOW_TS - START_TS))

    echo | tee -a "$LOG"
    echo "----- elapsed ${ELAPSED}s / target ${DURATION_SEC}s -----" | tee -a "$LOG"

    echo "[process]" | tee -a "$LOG"
    ps -p "$MEDIAMTX_PID" -o pid,stat,cmd 2>/dev/null | tee -a "$LOG" || true
    ps -p "$FFMPEG_PID" -o pid,stat,cmd 2>/dev/null | tee -a "$LOG" || true
    ps -p "$ENC_PID" -o pid,stat,cmd 2>/dev/null | tee -a "$LOG" || true
    ps -p "$DETECT_PID" -o pid,stat,cmd 2>/dev/null | tee -a "$LOG" || true

    echo "[mediamtx recent]" | tee -a "$LOG"
    tail -20 "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true

    echo "[ffmpeg recent]" | tee -a "$LOG"
    tail -20 "$OUT_DIR/ffmpeg_push_rtsp.log" | tee -a "$LOG" || true

    echo "[encoder recent]" | tee -a "$LOG"
    tail -10 "$OUT_DIR/mpi_enc_rtsp.log" | tee -a "$LOG" || true

    echo "[detect recent]" | tee -a "$LOG"
    grep -E "frame=.*total=.*fps=|==========|wall_fps|avg_" "$OUT_DIR/realtime_detect_to_nv12.log" | tail -10 | tee -a "$LOG" || true

    sleep 30
done

echo | tee -a "$LOG"
echo "========== detect finished, wait encoder ==========" | tee -a "$LOG"

wait "$DETECT_PID" || true
wait "$ENC_PID" || true

sleep 2
kill "$FFMPEG_PID" 2>/dev/null || true

echo | tee -a "$LOG"
echo "========== final log tail: detect ==========" | tee -a "$LOG"
tail -150 "$OUT_DIR/realtime_detect_to_nv12.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final log tail: encoder ==========" | tee -a "$LOG"
tail -150 "$OUT_DIR/mpi_enc_rtsp.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final log tail: ffmpeg ==========" | tee -a "$LOG"
tail -150 "$OUT_DIR/ffmpeg_push_rtsp.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final log tail: mediamtx ==========" | tee -a "$LOG"
tail -150 "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== automatic summary ==========" | tee -a "$LOG"

echo "[mediamtx events]" | tee -a "$LOG"
echo -n "publish count: " | tee -a "$LOG"
grep -c "is publishing to path 'exp10_detect_stable'" "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true
echo -n "reader count : " | tee -a "$LOG"
grep -c "is reading from path 'exp10_detect_stable'" "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true
echo -n "warn count   : " | tee -a "$LOG"
grep -Ec "WAR|RTP packets lost|invalid FU-A|processing errors" "$OUT_DIR/mediamtx.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "[ffmpeg errors]" | tee -a "$LOG"
grep -Ei "error|broken|failed|invalid|Connection|pipe" "$OUT_DIR/ffmpeg_push_rtsp.log" | tail -30 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "[profile csv summary]" | tee -a "$LOG"
python3 - "$PROFILE" <<'PY' | tee -a "$LOG" || true
import csv, sys, statistics as st
p = sys.argv[1]
try:
    with open(p, newline="") as f:
        rows = list(csv.DictReader(f))
except Exception as e:
    print("cannot read profile:", e)
    sys.exit(0)

print("profile:", p)
print("rows:", len(rows))
if not rows:
    sys.exit(0)

print("columns:", ",".join(rows[0].keys()))

def vals(name):
    out = []
    for r in rows:
        try:
            if r.get(name, "") != "":
                out.append(float(r[name]))
        except Exception:
            pass
    return out

candidates = [
    "total_ms", "fps",
    "rga_in_ms", "model_total_ms", "model_ms",
    "draw_ms", "rga_out_ms", "write_ms",
    "select_ms", "dqbuf_ms", "qbuf_ms"
]

for c in candidates:
    v = vals(c)
    if v:
        print(f"{c}: avg={sum(v)/len(v):.3f} min={min(v):.3f} max={max(v):.3f} samples={len(v)}")

print("last 3 rows:")
for r in rows[-3:]:
    print(r)
PY

echo | tee -a "$LOG"
echo "========== output files ==========" | tee -a "$LOG"
ls -lh "$OUT_DIR" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "10-4 TCP stability test done." | tee -a "$LOG"
echo "log saved to: $LOG" | tee -a "$LOG"
echo "out dir: $OUT_DIR" | tee -a "$LOG"

#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp17_realtime_audio
LOG="$OUT_DIR/17_realtime_audio.log"

CAP_DEV="${1:-hw:2,0}"
RATE="${2:-48000}"
CHANNELS="${3:-2}"
FILE_SECONDS="${4:-20}"
STREAM_SECONDS="${5:-30}"

mkdir -p "$OUT_DIR"
: > "$LOG"

AAC_M4A="$OUT_DIR/live_capture_aac_128k_${FILE_SECONDS}s.m4a"
AAC_ADTS="$OUT_DIR/live_capture_aac_128k_${FILE_SECONDS}s.adts.aac"
OPUS_OGG="$OUT_DIR/live_capture_opus_64k_${FILE_SECONDS}s.ogg"
G711A_WAV="$OUT_DIR/live_capture_g711a_8k_mono_${FILE_SECONDS}s.wav"
G711U_WAV="$OUT_DIR/live_capture_g711u_8k_mono_${FILE_SECONDS}s.wav"

RTSP_PATH="exp17_audio_aac"
RTSP_URL_LOCAL="rtsp://127.0.0.1:8554/${RTSP_PATH}"

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    if [ -n "${FFMPEG_PUSH_PID:-}" ]; then
        kill "$FFMPEG_PUSH_PID" 2>/dev/null || true
        wait "$FFMPEG_PUSH_PID" 2>/dev/null || true
    fi

    if [ -n "${MEDIAMTX_PID:-}" ]; then
        kill "$MEDIAMTX_PID" 2>/dev/null || true
        wait "$MEDIAMTX_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "========== 17 realtime audio capture/encode ==========" | tee -a "$LOG"
date | tee -a "$LOG"
echo "capture device : $CAP_DEV" | tee -a "$LOG"
echo "rate           : $RATE" | tee -a "$LOG"
echo "channels       : $CHANNELS" | tee -a "$LOG"
echo "file seconds   : $FILE_SECONDS" | tee -a "$LOG"
echo "stream seconds : $STREAM_SECONDS" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ALSA cards ==========" | tee -a "$LOG"
cat /proc/asound/cards 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ALSA pcm ==========" | tee -a "$LOG"
cat /proc/asound/pcm 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== capture hw params ==========" | tee -a "$LOG"
timeout 5 arecord -D "$CAP_DEV" --dump-hw-params -f S16_LE -r "$RATE" -c "$CHANNELS" -d 1 /dev/null 2>&1 \
    | tee "$OUT_DIR/capture_hw_params.log" \
    | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg ALSA support ==========" | tee -a "$LOG"
ffmpeg -hide_banner -devices 2>&1 | grep -Ei "alsa|pulse|oss" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg audio encoders ==========" | tee -a "$LOG"
ffmpeg -hide_banner -encoders 2>&1 | grep -Ei "aac|opus|pcm_alaw|pcm_mulaw|pcm_s16le" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== 17-1 live ALSA -> AAC M4A ==========" | tee -a "$LOG"

ffmpeg -y -nostdin -hide_banner \
    -f alsa \
    -ar "$RATE" \
    -ac "$CHANNELS" \
    -i "$CAP_DEV" \
    -t "$FILE_SECONDS" \
    -vn \
    -c:a aac \
    -b:a 128k \
    "$AAC_M4A" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 17-1 live ALSA -> AAC ADTS ==========" | tee -a "$LOG"

ffmpeg -y -nostdin -hide_banner \
    -f alsa \
    -ar "$RATE" \
    -ac "$CHANNELS" \
    -i "$CAP_DEV" \
    -t "$FILE_SECONDS" \
    -vn \
    -c:a aac \
    -b:a 128k \
    -f adts \
    "$AAC_ADTS" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 17-1 live ALSA -> Opus OGG ==========" | tee -a "$LOG"

if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qi "libopus"; then
    ffmpeg -y -nostdin -hide_banner \
        -f alsa \
        -ar "$RATE" \
        -ac "$CHANNELS" \
        -i "$CAP_DEV" \
        -t "$FILE_SECONDS" \
        -vn \
        -c:a libopus \
        -b:a 64k \
        "$OPUS_OGG" 2>&1 | tee -a "$LOG"
else
    ffmpeg -y -nostdin -hide_banner \
        -f alsa \
        -ar "$RATE" \
        -ac "$CHANNELS" \
        -i "$CAP_DEV" \
        -t "$FILE_SECONDS" \
        -vn \
        -c:a opus \
        -b:a 64k \
        -strict -2 \
        "$OPUS_OGG" 2>&1 | tee -a "$LOG"
fi

echo | tee -a "$LOG"
echo "========== 17-1 live ALSA -> G.711 A-law WAV ==========" | tee -a "$LOG"

ffmpeg -y -nostdin -hide_banner \
    -f alsa \
    -ar "$RATE" \
    -ac "$CHANNELS" \
    -i "$CAP_DEV" \
    -t "$FILE_SECONDS" \
    -vn \
    -af "pan=mono|c0=0.5*c0+0.5*c1" \
    -ar 8000 \
    -ac 1 \
    -c:a pcm_alaw \
    "$G711A_WAV" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 17-1 live ALSA -> G.711 mu-law WAV ==========" | tee -a "$LOG"

ffmpeg -y -nostdin -hide_banner \
    -f alsa \
    -ar "$RATE" \
    -ac "$CHANNELS" \
    -i "$CAP_DEV" \
    -t "$FILE_SECONDS" \
    -vn \
    -af "pan=mono|c0=0.5*c0+0.5*c1" \
    -ar 8000 \
    -ac 1 \
    -c:a pcm_mulaw \
    "$G711U_WAV" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffprobe encoded realtime audio files ==========" | tee -a "$LOG"

for f in "$AAC_M4A" "$AAC_ADTS" "$OPUS_OGG" "$G711A_WAV" "$G711U_WAV"; do
    echo | tee -a "$LOG"
    echo "----- ffprobe: $f -----" | tee -a "$LOG"
    ffprobe -hide_banner "$f" 2>&1 | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== volume detect encoded files after decode ==========" | tee -a "$LOG"

for f in "$AAC_M4A" "$AAC_ADTS" "$OPUS_OGG" "$G711A_WAV" "$G711U_WAV"; do
    echo | tee -a "$LOG"
    echo "----- volume: $f -----" | tee -a "$LOG"
    ffmpeg -hide_banner -i "$f" -af volumedetect -f null - 2>&1 \
        | tee "$OUT_DIR/$(basename "$f").volumedetect.log" \
        | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== 17-2 prepare MediaMTX audio-only RTSP ==========" | tee -a "$LOG"

if [ -x "./tools/mediamtx/mediamtx" ]; then
    MEDIAMTX_BIN="./tools/mediamtx/mediamtx"
elif command -v mediamtx >/dev/null 2>&1; then
    MEDIAMTX_BIN="$(command -v mediamtx)"
else
    MEDIAMTX_BIN=""
fi

if [ -z "$MEDIAMTX_BIN" ]; then
    echo "WARNING: mediamtx not found, skip RTSP audio streaming test." | tee -a "$LOG"
else
    pkill -f mediamtx 2>/dev/null || true
    sleep 1

    cat > "$OUT_DIR/mediamtx_audio.yml" <<EOF
rtspAddress: :8554

paths:
  all_others:
EOF

    echo "MediaMTX bin: $MEDIAMTX_BIN" | tee -a "$LOG"
    "$MEDIAMTX_BIN" "$OUT_DIR/mediamtx_audio.yml" > "$OUT_DIR/mediamtx_audio.log" 2>&1 &
    MEDIAMTX_PID=$!

    sleep 2

    echo | tee -a "$LOG"
    echo "========== MediaMTX process / port ==========" | tee -a "$LOG"
    ps -ef | grep mediamtx | grep -v grep | tee -a "$LOG" || true
    ss -ltnp 2>/dev/null | grep 8554 | tee -a "$LOG" || true
    tail -80 "$OUT_DIR/mediamtx_audio.log" | tee -a "$LOG" || true

    echo | tee -a "$LOG"
    echo "========== 17-2 live ALSA -> AAC -> RTSP ==========" | tee -a "$LOG"
    echo "RTSP local url: $RTSP_URL_LOCAL" | tee -a "$LOG"

    ffmpeg -nostdin -hide_banner \
        -f alsa \
        -ar "$RATE" \
        -ac "$CHANNELS" \
        -i "$CAP_DEV" \
        -vn \
        -c:a aac \
        -b:a 128k \
        -f rtsp \
        -rtsp_transport tcp \
        "$RTSP_URL_LOCAL" \
        > "$OUT_DIR/ffmpeg_audio_rtsp_push.log" 2>&1 &
    FFMPEG_PUSH_PID=$!

    sleep 5

    echo | tee -a "$LOG"
    echo "========== FFmpeg push process ==========" | tee -a "$LOG"
    ps -p "$FFMPEG_PUSH_PID" -o pid,ppid,stat,pcpu,pmem,cmd 2>&1 | tee -a "$LOG" || true

    BOARD_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo | tee -a "$LOG"
    echo "========== RTSP playback URL ==========" | tee -a "$LOG"
    echo "VLC / ffplay url:" | tee -a "$LOG"
    echo "rtsp://${BOARD_IP}:8554/${RTSP_PATH}" | tee -a "$LOG"

    echo | tee -a "$LOG"
    echo "========== 17-3 ffprobe RTSP audio stream ==========" | tee -a "$LOG"
    timeout 15 ffprobe -hide_banner -rtsp_transport tcp "rtsp://127.0.0.1:8554/${RTSP_PATH}" 2>&1 \
        | tee "$OUT_DIR/ffprobe_audio_rtsp.log" \
        | tee -a "$LOG" || true

    echo | tee -a "$LOG"
    echo "========== keep RTSP audio stream for ${STREAM_SECONDS}s ==========" | tee -a "$LOG"
    echo "During this time, you can open VLC:" | tee -a "$LOG"
    echo "rtsp://${BOARD_IP}:8554/${RTSP_PATH}" | tee -a "$LOG"

    sleep "$STREAM_SECONDS"

    echo | tee -a "$LOG"
    echo "========== stop RTSP audio stream ==========" | tee -a "$LOG"

    kill "$FFMPEG_PUSH_PID" 2>/dev/null || true
    wait "$FFMPEG_PUSH_PID" 2>/dev/null || true
    FFMPEG_PUSH_PID=""

    echo | tee -a "$LOG"
    echo "========== ffmpeg audio rtsp push log tail ==========" | tee -a "$LOG"
    tail -120 "$OUT_DIR/ffmpeg_audio_rtsp_push.log" | tee -a "$LOG" || true

    echo | tee -a "$LOG"
    echo "========== mediamtx audio log tail ==========" | tee -a "$LOG"
    tail -120 "$OUT_DIR/mediamtx_audio.log" | tee -a "$LOG" || true
fi

echo | tee -a "$LOG"
echo "========== final files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f -printf "%f %s bytes\n" | sort | tee "$OUT_DIR/file_sizes.txt" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 17 summary ==========" | tee -a "$LOG"
echo "capture_device=$CAP_DEV" | tee -a "$LOG"
echo "rate=$RATE" | tee -a "$LOG"
echo "channels=$CHANNELS" | tee -a "$LOG"
echo "aac_m4a=$AAC_M4A" | tee -a "$LOG"
echo "aac_adts=$AAC_ADTS" | tee -a "$LOG"
echo "opus_ogg=$OPUS_OGG" | tee -a "$LOG"
echo "g711a_wav=$G711A_WAV" | tee -a "$LOG"
echo "g711u_wav=$G711U_WAV" | tee -a "$LOG"
echo "rtsp_url=rtsp://$(hostname -I 2>/dev/null | awk '{print $1}'):8554/${RTSP_PATH}" | tee -a "$LOG"
echo "log=$LOG" | tee -a "$LOG"
echo "17 realtime audio capture/encode finished." | tee -a "$LOG"

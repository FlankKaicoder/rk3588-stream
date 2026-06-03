#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp14_alsa_pcm
LOG="$OUT_DIR/14_alsa_pcm.log"

CAP_DEV="${1:-hw:2,0}"
PLAY_DEV="${2:-hw:2,0}"
RATE="${3:-48000}"
CHANNELS="${4:-1}"
SECONDS="${5:-10}"

mkdir -p "$OUT_DIR"
: > "$LOG"

run_cmd() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

run_shell() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    bash -lc "$*" 2>&1 | tee -a "$LOG" || true
}

echo "========== 14 ALSA PCM capture/playback ==========" | tee -a "$LOG"
date | tee -a "$LOG"
echo "capture device : $CAP_DEV" | tee -a "$LOG"
echo "playback device: $PLAY_DEV" | tee -a "$LOG"
echo "rate           : $RATE" | tee -a "$LOG"
echo "channels       : $CHANNELS" | tee -a "$LOG"
echo "seconds        : $SECONDS" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ALSA cards ==========" | tee -a "$LOG"
cat /proc/asound/cards 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ALSA pcm ==========" | tee -a "$LOG"
cat /proc/asound/pcm 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== arecord -l ==========" | tee -a "$LOG"
arecord -l 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== aplay -l ==========" | tee -a "$LOG"
aplay -l 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== mixer snapshot card2 ==========" | tee -a "$LOG"
amixer -c 2 2>&1 | tee "$OUT_DIR/amixer_card2.log" | tee -a "$LOG" || true
amixer -c 2 controls 2>&1 | tee "$OUT_DIR/amixer_card2_controls.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== capture hw params ==========" | tee -a "$LOG"
timeout 5 arecord -D "$CAP_DEV" --dump-hw-params -f S16_LE -r "$RATE" -c "$CHANNELS" -d 1 /dev/null 2>&1 \
    | tee "$OUT_DIR/capture_hw_params.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== playback hw params ==========" | tee -a "$LOG"
timeout 5 aplay -D "$PLAY_DEV" --dump-hw-params /dev/zero 2>&1 \
    | head -120 \
    | tee "$OUT_DIR/playback_hw_params.log" | tee -a "$LOG" || true

CAP_WAV="$OUT_DIR/capture_${RATE}_${CHANNELS}ch_${SECONDS}s.wav"
CAP_PCM="$OUT_DIR/capture_${RATE}_${CHANNELS}ch_${SECONDS}s.pcm"
TONE_WAV="$OUT_DIR/test_tone_1000hz_${RATE}_${CHANNELS}ch.wav"

echo | tee -a "$LOG"
echo "========== record wav ==========" | tee -a "$LOG"
echo "Now recording ${SECONDS}s audio from $CAP_DEV ..." | tee -a "$LOG"

arecord -D "$CAP_DEV" \
    -f S16_LE \
    -r "$RATE" \
    -c "$CHANNELS" \
    -d "$SECONDS" \
    "$CAP_WAV" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== record raw pcm ==========" | tee -a "$LOG"

arecord -D "$CAP_DEV" \
    -f S16_LE \
    -r "$RATE" \
    -c "$CHANNELS" \
    -d "$SECONDS" \
    -t raw \
    "$CAP_PCM" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== output files ==========" | tee -a "$LOG"
ls -lh "$CAP_WAV" "$CAP_PCM" 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffprobe wav ==========" | tee -a "$LOG"
ffprobe -hide_banner "$CAP_WAV" 2>&1 | tee "$OUT_DIR/capture_ffprobe.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== volume detect ==========" | tee -a "$LOG"
ffmpeg -hide_banner -i "$CAP_WAV" -af volumedetect -f null - 2>&1 \
    | tee "$OUT_DIR/capture_volumedetect.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== astats ==========" | tee -a "$LOG"
ffmpeg -hide_banner -i "$CAP_WAV" -af astats=metadata=1:reset=1 -f null - 2>&1 \
    | tail -120 \
    | tee "$OUT_DIR/capture_astats_tail.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== generate playback test tone ==========" | tee -a "$LOG"
ffmpeg -y -hide_banner \
    -f lavfi \
    -i "sine=frequency=1000:duration=3:sample_rate=${RATE}" \
    -af "volume=0.2" \
    -ac "$CHANNELS" \
    "$TONE_WAV" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== play generated test tone ==========" | tee -a "$LOG"
echo "Playing 1kHz low-volume test tone through $PLAY_DEV ..." | tee -a "$LOG"
aplay -D "$PLAY_DEV" "$TONE_WAV" 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== play recorded wav ==========" | tee -a "$LOG"
echo "Playing recorded wav through $PLAY_DEV ..." | tee -a "$LOG"
aplay -D "$PLAY_DEV" "$CAP_WAV" 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f -printf "%f %s bytes\n" | sort | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 14 summary ==========" | tee -a "$LOG"
echo "capture_wav=$CAP_WAV" | tee -a "$LOG"
echo "capture_pcm=$CAP_PCM" | tee -a "$LOG"
echo "test_tone_wav=$TONE_WAV" | tee -a "$LOG"
echo "log=$LOG" | tee -a "$LOG"
echo "14 ALSA PCM capture/playback finished." | tee -a "$LOG"

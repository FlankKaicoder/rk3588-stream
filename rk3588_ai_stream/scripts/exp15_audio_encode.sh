#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp15_audio_encode
LOG="$OUT_DIR/15_audio_encode.log"

mkdir -p "$OUT_DIR"
: > "$LOG"

INPUT_WAV="${1:-}"

if [ -z "$INPUT_WAV" ]; then
    INPUT_WAV=$(ls -t output/exp14_alsa_pcm/capture_48000_2ch_*s.wav 2>/dev/null | head -1 || true)
fi

if [ -z "$INPUT_WAV" ] || [ ! -f "$INPUT_WAV" ]; then
    echo "ERROR: input wav not found." | tee -a "$LOG"
    echo "Try:" | tee -a "$LOG"
    echo "  ./scripts/exp15_audio_encode.sh output/exp14_alsa_pcm/capture_48000_2ch_11s.wav" | tee -a "$LOG"
    exit 1
fi

run_cmd() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG"
}

run_cmd_allow_fail() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

echo "========== 15 audio encode ==========" | tee -a "$LOG"
date | tee -a "$LOG"
echo "input wav: $INPUT_WAV" | tee -a "$LOG"

AAC_M4A="$OUT_DIR/capture_aac_128k.m4a"
AAC_ADTS="$OUT_DIR/capture_aac_128k.adts.aac"
OPUS_OGG="$OUT_DIR/capture_opus_64k.ogg"
G711A_WAV="$OUT_DIR/capture_g711a_8k_mono.wav"
G711U_WAV="$OUT_DIR/capture_g711u_8k_mono.wav"

AAC_M4A_DEC="$OUT_DIR/decoded_aac_m4a.wav"
AAC_ADTS_DEC="$OUT_DIR/decoded_aac_adts.wav"
OPUS_DEC="$OUT_DIR/decoded_opus.wav"
G711A_DEC="$OUT_DIR/decoded_g711a.wav"
G711U_DEC="$OUT_DIR/decoded_g711u.wav"

MONO_48K="$OUT_DIR/capture_mono_48k.wav"
MONO_GAIN="$OUT_DIR/capture_mono_48k_gain12db.wav"

echo | tee -a "$LOG"
echo "========== input ffprobe ==========" | tee -a "$LOG"
ffprobe -hide_banner "$INPUT_WAV" 2>&1 | tee "$OUT_DIR/input_ffprobe.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== input volume ==========" | tee -a "$LOG"
ffmpeg -hide_banner -i "$INPUT_WAV" -af volumedetect -f null - 2>&1 \
    | tee "$OUT_DIR/input_volumedetect.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== make mono review wav ==========" | tee -a "$LOG"

ffmpeg -y -hide_banner \
    -i "$INPUT_WAV" \
    -af "pan=mono|c0=0.5*c0+0.5*c1" \
    -ar 48000 \
    -ac 1 \
    "$MONO_48K" 2>&1 | tee -a "$LOG"

ffmpeg -y -hide_banner \
    -i "$INPUT_WAV" \
    -af "pan=mono|c0=0.5*c0+0.5*c1,volume=12dB" \
    -ar 48000 \
    -ac 1 \
    "$MONO_GAIN" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== encode AAC M4A ==========" | tee -a "$LOG"

ffmpeg -y -hide_banner \
    -i "$INPUT_WAV" \
    -c:a aac \
    -b:a 128k \
    "$AAC_M4A" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== encode AAC ADTS ==========" | tee -a "$LOG"

ffmpeg -y -hide_banner \
    -i "$INPUT_WAV" \
    -c:a aac \
    -b:a 128k \
    -f adts \
    "$AAC_ADTS" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== encode Opus OGG ==========" | tee -a "$LOG"

if ffmpeg -hide_banner -encoders 2>/dev/null | grep -qi "libopus"; then
    ffmpeg -y -hide_banner \
        -i "$INPUT_WAV" \
        -c:a libopus \
        -b:a 64k \
        "$OPUS_OGG" 2>&1 | tee -a "$LOG"
else
    echo "libopus not found, try native opus encoder." | tee -a "$LOG"
    ffmpeg -y -hide_banner \
        -i "$INPUT_WAV" \
        -c:a opus \
        -b:a 64k \
        -strict -2 \
        "$OPUS_OGG" 2>&1 | tee -a "$LOG"
fi

echo | tee -a "$LOG"
echo "========== encode G.711 A-law 8k mono ==========" | tee -a "$LOG"

ffmpeg -y -hide_banner \
    -i "$INPUT_WAV" \
    -af "pan=mono|c0=0.5*c0+0.5*c1" \
    -ar 8000 \
    -ac 1 \
    -c:a pcm_alaw \
    "$G711A_WAV" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== encode G.711 mu-law 8k mono ==========" | tee -a "$LOG"

ffmpeg -y -hide_banner \
    -i "$INPUT_WAV" \
    -af "pan=mono|c0=0.5*c0+0.5*c1" \
    -ar 8000 \
    -ac 1 \
    -c:a pcm_mulaw \
    "$G711U_WAV" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffprobe encoded files ==========" | tee -a "$LOG"

for f in "$AAC_M4A" "$AAC_ADTS" "$OPUS_OGG" "$G711A_WAV" "$G711U_WAV" "$MONO_48K" "$MONO_GAIN"; do
    echo | tee -a "$LOG"
    echo "----- ffprobe: $f -----" | tee -a "$LOG"
    ffprobe -hide_banner "$f" 2>&1 | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== decode encoded files back to wav ==========" | tee -a "$LOG"

ffmpeg -y -hide_banner -i "$AAC_M4A"  -c:a pcm_s16le "$AAC_M4A_DEC" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$AAC_ADTS" -c:a pcm_s16le "$AAC_ADTS_DEC" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$OPUS_OGG" -c:a pcm_s16le "$OPUS_DEC" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$G711A_WAV" -c:a pcm_s16le "$G711A_DEC" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$G711U_WAV" -c:a pcm_s16le "$G711U_DEC" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== decoded volume detect ==========" | tee -a "$LOG"

for f in "$AAC_M4A_DEC" "$AAC_ADTS_DEC" "$OPUS_DEC" "$G711A_DEC" "$G711U_DEC" "$MONO_GAIN"; do
    echo | tee -a "$LOG"
    echo "----- volume: $f -----" | tee -a "$LOG"
    ffmpeg -hide_banner -i "$f" -af volumedetect -f null - 2>&1 \
        | tee "$OUT_DIR/$(basename "$f").volumedetect.log" \
        | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== file sizes ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f -printf "%f %s bytes\n" | sort | tee "$OUT_DIR/file_sizes.txt" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 15 summary ==========" | tee -a "$LOG"
echo "input_wav=$INPUT_WAV" | tee -a "$LOG"
echo "aac_m4a=$AAC_M4A" | tee -a "$LOG"
echo "aac_adts=$AAC_ADTS" | tee -a "$LOG"
echo "opus_ogg=$OPUS_OGG" | tee -a "$LOG"
echo "g711a_wav=$G711A_WAV" | tee -a "$LOG"
echo "g711u_wav=$G711U_WAV" | tee -a "$LOG"
echo "mono_gain_for_listen=$MONO_GAIN" | tee -a "$LOG"
echo "log=$LOG" | tee -a "$LOG"
echo "15 audio encode finished." | tee -a "$LOG"

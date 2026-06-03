#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp16_audio_decode_playback
LOG="$OUT_DIR/16_audio_decode_playback.log"

PLAY_DEV="${1:-hw:2,0}"

mkdir -p "$OUT_DIR"
: > "$LOG"

AAC_M4A="output/exp15_audio_encode/capture_aac_128k.m4a"
AAC_ADTS="output/exp15_audio_encode/capture_aac_128k.adts.aac"
OPUS_OGG="output/exp15_audio_encode/capture_opus_64k.ogg"
G711A_WAV="output/exp15_audio_encode/capture_g711a_8k_mono.wav"
G711U_WAV="output/exp15_audio_encode/capture_g711u_8k_mono.wav"

for f in "$AAC_M4A" "$AAC_ADTS" "$OPUS_OGG" "$G711A_WAV" "$G711U_WAV"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: missing input file: $f" | tee -a "$LOG"
        echo "Please run exp15 first." | tee -a "$LOG"
        exit 1
    fi
done

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

echo "========== 16 audio decode/playback ==========" | tee -a "$LOG"
date | tee -a "$LOG"
echo "playback device: $PLAY_DEV" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== input encoded files ==========" | tee -a "$LOG"
ls -lh "$AAC_M4A" "$AAC_ADTS" "$OPUS_OGG" "$G711A_WAV" "$G711U_WAV" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== playback hw params ==========" | tee -a "$LOG"
timeout 5 aplay -D "$PLAY_DEV" --dump-hw-params /dev/zero 2>&1 \
    | head -120 \
    | tee "$OUT_DIR/playback_hw_params.log" \
    | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffprobe encoded inputs ==========" | tee -a "$LOG"

for f in "$AAC_M4A" "$AAC_ADTS" "$OPUS_OGG" "$G711A_WAV" "$G711U_WAV"; do
    echo | tee -a "$LOG"
    echo "----- ffprobe: $f -----" | tee -a "$LOG"
    ffprobe -hide_banner "$f" 2>&1 | tee -a "$LOG" || true
done

DEC_AAC_M4A="$OUT_DIR/decoded_aac_m4a.wav"
DEC_AAC_ADTS="$OUT_DIR/decoded_aac_adts.wav"
DEC_OPUS="$OUT_DIR/decoded_opus.wav"
DEC_G711A="$OUT_DIR/decoded_g711a.wav"
DEC_G711U="$OUT_DIR/decoded_g711u.wav"

PLAY_AAC_M4A="$OUT_DIR/play_aac_m4a_48k_2ch_s16.wav"
PLAY_AAC_ADTS="$OUT_DIR/play_aac_adts_48k_2ch_s16.wav"
PLAY_OPUS="$OUT_DIR/play_opus_48k_2ch_s16.wav"
PLAY_G711A="$OUT_DIR/play_g711a_48k_2ch_s16.wav"
PLAY_G711U="$OUT_DIR/play_g711u_48k_2ch_s16.wav"

PLAY_AAC_M4A_GAIN="$OUT_DIR/play_aac_m4a_48k_2ch_s16_gain12db.wav"
PLAY_AAC_ADTS_GAIN="$OUT_DIR/play_aac_adts_48k_2ch_s16_gain12db.wav"
PLAY_OPUS_GAIN="$OUT_DIR/play_opus_48k_2ch_s16_gain12db.wav"
PLAY_G711A_GAIN="$OUT_DIR/play_g711a_48k_2ch_s16_gain12db.wav"
PLAY_G711U_GAIN="$OUT_DIR/play_g711u_48k_2ch_s16_gain12db.wav"

echo | tee -a "$LOG"
echo "========== decode encoded files to PCM wav ==========" | tee -a "$LOG"

ffmpeg -y -hide_banner -i "$AAC_M4A"  -c:a pcm_s16le "$DEC_AAC_M4A" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$AAC_ADTS" -c:a pcm_s16le "$DEC_AAC_ADTS" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$OPUS_OGG" -c:a pcm_s16le "$DEC_OPUS" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$G711A_WAV" -c:a pcm_s16le "$DEC_G711A" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$G711U_WAV" -c:a pcm_s16le "$DEC_G711U" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== convert decoded wav to hw:2,0 friendly format ==========" | tee -a "$LOG"
echo "Target format: 48000 Hz / stereo / pcm_s16le" | tee -a "$LOG"

ffmpeg -y -hide_banner -i "$DEC_AAC_M4A"  -ar 48000 -ac 2 -c:a pcm_s16le "$PLAY_AAC_M4A" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$DEC_AAC_ADTS" -ar 48000 -ac 2 -c:a pcm_s16le "$PLAY_AAC_ADTS" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$DEC_OPUS"     -ar 48000 -ac 2 -c:a pcm_s16le "$PLAY_OPUS" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$DEC_G711A"    -ar 48000 -ac 2 -c:a pcm_s16le "$PLAY_G711A" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$DEC_G711U"    -ar 48000 -ac 2 -c:a pcm_s16le "$PLAY_G711U" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== make +12dB playback review files ==========" | tee -a "$LOG"
echo "Because current recording level is low, these files are only for listening review." | tee -a "$LOG"

ffmpeg -y -hide_banner -i "$PLAY_AAC_M4A"  -af "volume=12dB" -c:a pcm_s16le "$PLAY_AAC_M4A_GAIN" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$PLAY_AAC_ADTS" -af "volume=12dB" -c:a pcm_s16le "$PLAY_AAC_ADTS_GAIN" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$PLAY_OPUS"     -af "volume=12dB" -c:a pcm_s16le "$PLAY_OPUS_GAIN" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$PLAY_G711A"    -af "volume=12dB" -c:a pcm_s16le "$PLAY_G711A_GAIN" 2>&1 | tee -a "$LOG"
ffmpeg -y -hide_banner -i "$PLAY_G711U"    -af "volume=12dB" -c:a pcm_s16le "$PLAY_G711U_GAIN" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffprobe decoded/playback wav ==========" | tee -a "$LOG"

for f in \
    "$DEC_AAC_M4A" "$DEC_AAC_ADTS" "$DEC_OPUS" "$DEC_G711A" "$DEC_G711U" \
    "$PLAY_AAC_M4A" "$PLAY_AAC_ADTS" "$PLAY_OPUS" "$PLAY_G711A" "$PLAY_G711U"
do
    echo | tee -a "$LOG"
    echo "----- ffprobe: $f -----" | tee -a "$LOG"
    ffprobe -hide_banner "$f" 2>&1 | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== volume detect playback review files ==========" | tee -a "$LOG"

for f in "$PLAY_AAC_M4A_GAIN" "$PLAY_AAC_ADTS_GAIN" "$PLAY_OPUS_GAIN" "$PLAY_G711A_GAIN" "$PLAY_G711U_GAIN"; do
    echo | tee -a "$LOG"
    echo "----- volume: $f -----" | tee -a "$LOG"
    ffmpeg -hide_banner -i "$f" -af volumedetect -f null - 2>&1 \
        | tee "$OUT_DIR/$(basename "$f").volumedetect.log" \
        | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== playback decoded audio ==========" | tee -a "$LOG"
echo "The following files will be played through $PLAY_DEV." | tee -a "$LOG"
echo "They are +12dB review copies, generated only because the original recording level is low." | tee -a "$LOG"

for f in "$PLAY_AAC_M4A_GAIN" "$PLAY_AAC_ADTS_GAIN" "$PLAY_OPUS_GAIN" "$PLAY_G711A_GAIN" "$PLAY_G711U_GAIN"; do
    echo | tee -a "$LOG"
    echo "----- aplay: $f -----" | tee -a "$LOG"
    aplay -D "$PLAY_DEV" "$f" 2>&1 | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== final files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f -printf "%f %s bytes\n" | sort | tee "$OUT_DIR/file_sizes.txt" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 16 summary ==========" | tee -a "$LOG"
echo "playback_device=$PLAY_DEV" | tee -a "$LOG"
echo "decoded_aac_m4a=$DEC_AAC_M4A" | tee -a "$LOG"
echo "decoded_aac_adts=$DEC_AAC_ADTS" | tee -a "$LOG"
echo "decoded_opus=$DEC_OPUS" | tee -a "$LOG"
echo "decoded_g711a=$DEC_G711A" | tee -a "$LOG"
echo "decoded_g711u=$DEC_G711U" | tee -a "$LOG"
echo "log=$LOG" | tee -a "$LOG"
echo "16 audio decode/playback finished." | tee -a "$LOG"

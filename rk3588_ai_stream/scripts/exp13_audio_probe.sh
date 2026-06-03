#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp13_audio_probe
LOG="$OUT_DIR/probe.log"

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

echo "13 audio probe start" | tee -a "$LOG"
date | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== system ==========" | tee -a "$LOG"
uname -a 2>&1 | tee -a "$LOG" || true
cat /etc/os-release 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== /dev/snd ==========" | tee -a "$LOG"
ls -lh /dev/snd 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== /proc/asound ==========" | tee -a "$LOG"
cat /proc/asound/cards 2>&1 | tee -a "$LOG" || true
echo | tee -a "$LOG"
cat /proc/asound/devices 2>&1 | tee -a "$LOG" || true
echo | tee -a "$LOG"
cat /proc/asound/pcm 2>&1 | tee -a "$LOG" || true
echo | tee -a "$LOG"
cat /proc/asound/version 2>&1 | tee -a "$LOG" || true

run_shell 'which arecord || true'
run_shell 'which aplay || true'
run_shell 'arecord --version || true'
run_shell 'aplay --version || true'

echo | tee -a "$LOG"
echo "========== ALSA capture devices: arecord -l ==========" | tee -a "$LOG"
arecord -l 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ALSA playback devices: aplay -l ==========" | tee -a "$LOG"
aplay -l 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ALSA capture device names: arecord -L ==========" | tee -a "$LOG"
arecord -L 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ALSA playback device names: aplay -L ==========" | tee -a "$LOG"
aplay -L 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ALSA mixer ==========" | tee -a "$LOG"
which amixer 2>&1 | tee -a "$LOG" || true
amixer 2>&1 | tee -a "$LOG" || true
echo | tee -a "$LOG"
amixer controls 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ALSA config ==========" | tee -a "$LOG"
echo "--- /etc/asound.conf ---" | tee -a "$LOG"
cat /etc/asound.conf 2>&1 | tee -a "$LOG" || true
echo | tee -a "$LOG"
echo "--- ~/.asoundrc ---" | tee -a "$LOG"
cat ~/.asoundrc 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg / ffprobe ==========" | tee -a "$LOG"
which ffmpeg 2>&1 | tee -a "$LOG" || true
ffmpeg -hide_banner -version 2>&1 | head -30 | tee -a "$LOG" || true
echo | tee -a "$LOG"
which ffprobe 2>&1 | tee -a "$LOG" || true
ffprobe -hide_banner -version 2>&1 | head -20 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg devices ==========" | tee -a "$LOG"
ffmpeg -hide_banner -devices 2>&1 | tee "$OUT_DIR/ffmpeg_devices.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg alsa support ==========" | tee -a "$LOG"
ffmpeg -hide_banner -devices 2>&1 | grep -Ei "alsa|pulse|oss" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg audio encoders ==========" | tee -a "$LOG"
ffmpeg -hide_banner -encoders 2>&1 | tee "$OUT_DIR/ffmpeg_encoders.log" | grep -Ei "aac|opus|pcm_s16le|pcm_alaw|pcm_mulaw|g722|g726|mp3|flac" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg audio decoders ==========" | tee -a "$LOG"
ffmpeg -hide_banner -decoders 2>&1 | tee "$OUT_DIR/ffmpeg_decoders.log" | grep -Ei "aac|opus|pcm_s16le|pcm_alaw|pcm_mulaw|g722|g726|mp3|flac" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg muxers ==========" | tee -a "$LOG"
ffmpeg -hide_banner -muxers 2>&1 | tee "$OUT_DIR/ffmpeg_muxers.log" | grep -Ei "adts|wav|mp4|mov|matroska|webm|ogg|rtsp|rtp|flv|hls|mpegts" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg demuxers ==========" | tee -a "$LOG"
ffmpeg -hide_banner -demuxers 2>&1 | tee "$OUT_DIR/ffmpeg_demuxers.log" | grep -Ei "aac|wav|mp4|mov|matroska|webm|ogg|rtsp|rtp|flv|hls|mpegts|alsa" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== kernel sound modules ==========" | tee -a "$LOG"
lsmod 2>/dev/null | grep -Ei "snd|sound|audio|codec|hdmi" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== dmesg sound related tail ==========" | tee -a "$LOG"
dmesg 2>/dev/null | grep -Ei "snd|sound|audio|alsa|codec|hdmi|i2s|pdm|mic|speaker|usb.*audio|es8388|rt5651|ac108" | tail -200 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== quick default capture capability test ==========" | tee -a "$LOG"
echo "This is only a 1 second /dev/null capture test. It may fail if no default capture device exists." | tee -a "$LOG"
timeout 8 arecord -D default -f S16_LE -r 48000 -c 1 -d 1 /dev/null 2>&1 | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== quick default playback capability test ==========" | tee -a "$LOG"
echo "This only checks whether default playback can accept a short generated wav later; no audio is played here." | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== summary hints ==========" | tee -a "$LOG"

CAPTURE_NUM=$(arecord -l 2>/dev/null | grep -c "^card " || true)
PLAYBACK_NUM=$(aplay -l 2>/dev/null | grep -c "^card " || true)

echo "capture_device_count=$CAPTURE_NUM" | tee -a "$LOG"
echo "playback_device_count=$PLAYBACK_NUM" | tee -a "$LOG"

if [ "$CAPTURE_NUM" -gt 0 ]; then
    echo "CAPTURE_OK: ALSA capture devices were found." | tee -a "$LOG"
else
    echo "CAPTURE_MISSING: no ALSA capture device found by arecord -l." | tee -a "$LOG"
fi

if [ "$PLAYBACK_NUM" -gt 0 ]; then
    echo "PLAYBACK_OK: ALSA playback devices were found." | tee -a "$LOG"
else
    echo "PLAYBACK_MISSING: no ALSA playback device found by aplay -l." | tee -a "$LOG"
fi

if ffmpeg -hide_banner -devices 2>&1 | grep -qi alsa; then
    echo "FFMPEG_ALSA_OK: ffmpeg supports ALSA input/output." | tee -a "$LOG"
else
    echo "FFMPEG_ALSA_MISSING: ffmpeg ALSA support not detected." | tee -a "$LOG"
fi

if ffmpeg -hide_banner -encoders 2>&1 | grep -q " A..... aac"; then
    echo "FFMPEG_AAC_ENCODER_OK: native AAC encoder exists." | tee -a "$LOG"
else
    echo "FFMPEG_AAC_ENCODER_CHECK: AAC encoder not clearly detected." | tee -a "$LOG"
fi

if ffmpeg -hide_banner -encoders 2>&1 | grep -qi "libopus"; then
    echo "FFMPEG_OPUS_ENCODER_OK: libopus encoder exists." | tee -a "$LOG"
else
    echo "FFMPEG_OPUS_ENCODER_MISSING_OR_NATIVE_ONLY: libopus encoder not detected." | tee -a "$LOG"
fi

echo | tee -a "$LOG"
echo "probe log saved to: $LOG" | tee -a "$LOG"

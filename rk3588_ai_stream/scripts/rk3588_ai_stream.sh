#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MODE="${1:-help}"
DURATION_SEC="${2:-10}"
CUSTOM_NAME="${3:-}"

WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"

VIDEO_DEV="${VIDEO_DEV:-/dev/video11}"
MODEL_PATH="${MODEL_PATH:-models/yolo11.rknn}"

AUDIO_DEV="${AUDIO_DEV:-hw:2,0}"
AUDIO_RATE="${AUDIO_RATE:-48000}"
AUDIO_CHANNELS="${AUDIO_CHANNELS:-2}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LAUNCH_DIR="output/exp27_1_unified_entry_${MODE}_${TIMESTAMP}"
LAUNCH_LOG="$LAUNCH_DIR/launcher.log"

mkdir -p "$LAUNCH_DIR"

log()
{
    echo "[$(date '+%F %T')] $*" | tee -a "$LAUNCH_LOG"
}

die()
{
    log "ERROR: $*"
    exit 1
}

usage()
{
    cat <<'EOF'
Usage:
  ./scripts/rk3588_ai_stream.sh rtsp   [duration_sec] [stream_path]
  ./scripts/rk3588_ai_stream.sh record [duration_sec]
  ./scripts/rk3588_ai_stream.sh status
  ./scripts/rk3588_ai_stream.sh stop
  ./scripts/rk3588_ai_stream.sh both   [duration_sec]

Examples:
  ./scripts/rk3588_ai_stream.sh rtsp 10 exp27_rtsp_smoke
  ./scripts/rk3588_ai_stream.sh record 10
  ./scripts/rk3588_ai_stream.sh status
  ./scripts/rk3588_ai_stream.sh stop

Environment overrides:
  WIDTH=1280
  HEIGHT=720
  FPS=30
  VIDEO_DEV=/dev/video11
  MODEL_PATH=models/yolo11.rknn
  AUDIO_DEV=hw:2,0
  AUDIO_RATE=48000
  AUDIO_CHANNELS=2
EOF
}

require_file()
{
    local path="$1"
    [ -e "$path" ] || die "missing: $path"
}

require_executable()
{
    local path="$1"
    [ -x "$path" ] || die "missing or not executable: $path"
}

require_integer()
{
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] ||
        die "duration_sec must be a positive integer: $value"
}

set_runtime_environment()
{
    export RGA_LOG_LEVEL=0
    export RGA_DEBUG=0

    log "Attempting to set CPU governor to performance."

    for governor in \
        /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
    do
        [ -e "$governor" ] || continue

        if [ -w "$governor" ]; then
            echo performance > "$governor" || true
        elif command -v sudo >/dev/null 2>&1; then
            echo performance |
                sudo tee "$governor" >/dev/null 2>&1 || true
        fi
    done
}

print_config()
{
    {
        echo "========== Exp27 Unified Entry =========="
        echo "mode           : $MODE"
        echo "duration_sec   : $DURATION_SEC"
        echo "width          : $WIDTH"
        echo "height         : $HEIGHT"
        echo "fps            : $FPS"
        echo "video_dev      : $VIDEO_DEV"
        echo "model_path     : $MODEL_PATH"
        echo "audio_dev      : $AUDIO_DEV"
        echo "audio_rate     : $AUDIO_RATE"
        echo "audio_channels : $AUDIO_CHANNELS"
        echo "launcher_dir   : $LAUNCH_DIR"
        echo "========================================="
    } | tee -a "$LAUNCH_LOG"
}

run_rtsp()
{
    require_integer "$DURATION_SEC"

    require_file "$MODEL_PATH"
    require_file "$VIDEO_DEV"
    require_executable build/exp21_detect_mpp_encode_async
    require_executable scripts/exp22_av_async_mpp_rtsp.sh

    local frames=$((DURATION_SEC * FPS))
    local stream_path

    if [ -n "$CUSTOM_NAME" ]; then
        stream_path="$CUSTOM_NAME"
    else
        stream_path="exp27_final_av_rtsp"
    fi

    print_config

    log "frames      : $frames"
    log "stream_path : $stream_path"
    log "Starting RTSP mode through experiment 22 stable chain."

    ./scripts/exp22_av_async_mpp_rtsp.sh \
        "$WIDTH" \
        "$HEIGHT" \
        "$FPS" \
        "$frames" \
        "$AUDIO_DEV" \
        "$AUDIO_RATE" \
        "$AUDIO_CHANNELS" \
        "$stream_path" \
        2>&1 | tee -a "$LAUNCH_LOG"

    local rc=${PIPESTATUS[0]}

    log "RTSP child return code: $rc"

    local latest_out
    latest_out="$(
        ls -td \
            output/exp22_av_async_mpp_rtsp_"${frames}"f_* \
            2>/dev/null |
            head -1 || true
    )"

    if [ -n "$latest_out" ]; then
        log "RTSP output directory: $latest_out"
        printf '%s\n' "$latest_out" \
            > "$LAUNCH_DIR/child_output_dir.txt"
    fi

    return "$rc"
}

run_record()
{
    require_integer "$DURATION_SEC"

    require_file "$MODEL_PATH"
    require_file "$VIDEO_DEV"
    require_executable build/exp21_detect_mpp_encode_async
    require_executable build/exp24_mp4_mux_from_pts
    require_executable build/exp26_alsa_pcm_capture_ts
    require_executable scripts/exp26_3_av_mp4_v4l2_alsa_ts.sh

    local frames=$((DURATION_SEC * FPS))

    print_config

    log "frames: $frames"
    log "Starting timestamp-aligned MP4 record mode."

    # 最后三个参数继续使用实验26-3已经验证过的稳定参数。
    ./scripts/exp26_3_av_mp4_v4l2_alsa_ts.sh \
        "$frames" \
        "$WIDTH" \
        "$HEIGHT" \
        "$FPS" \
        "$AUDIO_DEV" \
        "$AUDIO_RATE" \
        "$AUDIO_CHANNELS" \
        256 \
        20 \
        10 \
        2>&1 | tee -a "$LAUNCH_LOG"

    local rc=${PIPESTATUS[0]}

    log "Record child return code: $rc"

    local latest_out
    latest_out="$(
        ls -td output/exp26_3_* 2>/dev/null |
            head -1 || true
    )"

    if [ -n "$latest_out" ]; then
        log "Record output directory: $latest_out"
        printf '%s\n' "$latest_out" \
            > "$LAUNCH_DIR/child_output_dir.txt"
    fi

    return "$rc"
}

show_status()
{
    if [ -x scripts/check_final_stream.sh ]; then
        exec ./scripts/check_final_stream.sh
    fi

    echo "========== processes =========="
    ps -ef |
        grep -E \
          "exp21_detect_mpp_encode_async|exp26_alsa_pcm_capture_ts|ffmpeg|mediamtx" |
        grep -v grep || true

    echo
    echo "========== ports =========="
    ss -lntup 2>/dev/null |
        grep -E ":8554|:8888|:8889|:8189" || true

    echo
    echo "========== video device users =========="
    command -v fuser >/dev/null 2>&1 &&
        fuser "$VIDEO_DEV" 2>/dev/null || true

    echo
    echo "========== audio device users =========="
    command -v fuser >/dev/null 2>&1 &&
        fuser /dev/snd/* 2>/dev/null || true
}

stop_runtime()
{
    if [ -x scripts/stop_final_stream.sh ]; then
        ./scripts/stop_final_stream.sh || true
    fi

    pkill -f "exp21_detect_mpp_encode_async" 2>/dev/null || true
    pkill -f "exp26_alsa_pcm_capture_ts" 2>/dev/null || true
    pkill -f "ffmpeg.*exp27" 2>/dev/null || true
    pkill -f "ffmpeg.*final_ai_av_rtsp" 2>/dev/null || true
    pkill -f "mediamtx" 2>/dev/null || true

    echo "Final stream and record processes stopped."
}

case "$MODE" in
    rtsp)
        set_runtime_environment
        run_rtsp
        ;;

    record)
        set_runtime_environment
        run_record
        ;;

    status)
        show_status
        ;;

    stop)
        stop_runtime
        ;;

    both)
        duration="${2:-60}"
        stream_path="${3:-rk3588_ai_stream_both}"

        if ! [[ "$duration" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: duration must be a positive integer"
            exit 1
        fi

        frames=$((duration * 30))

        export AUDIO_LEAD_MS="${AUDIO_LEAD_MS:-500}"
        export AUDIO_PAD_SEC="${AUDIO_PAD_SEC:-2}"

        exec ./scripts/exp27_4c_both_spool_rtsp_record.sh \
            1280 \
            720 \
            30 \
            "$frames" \
            hw:2,0 \
            48000 \
            2 \
            256 \
            "$stream_path"
        ;;

    help|-h|--help)
        usage
        ;;

    *)
        usage >&2
        exit 1
        ;;
esac

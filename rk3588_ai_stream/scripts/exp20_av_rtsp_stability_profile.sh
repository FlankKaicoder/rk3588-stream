#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

WIDTH=${1:-1280}
HEIGHT=${2:-720}
FPS=${3:-20}
DURATION=${4:-120}
AUDIO_DEV=${5:-hw:2,0}
AUDIO_RATE=${6:-48000}
AUDIO_CH=${7:-2}

# exp19-1 当前默认 RTSP 路径
STREAM_PATH=${8:-exp19_1_av_detect_fix}

FRAMES=$((FPS * DURATION))
TS=$(date +%Y%m%d_%H%M%S)
OUT_DIR="output/exp20_av_rtsp_stability_${DURATION}s_${TS}"

mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/20.log"
RUN_LOG="$OUT_DIR/exp19_1_run.log"
MONITOR_CSV="$OUT_DIR/resource_samples.csv"
PROCESS_LOG="$OUT_DIR/process_samples.log"
PORT_LOG="$OUT_DIR/port_samples.log"
SUMMARY="$OUT_DIR/summary.txt"

: > "$LOG"
: > "$RUN_LOG"
: > "$PROCESS_LOG"
: > "$PORT_LOG"
: > "$SUMMARY"

echo "========== exp20 av rtsp stability profile ==========" | tee -a "$LOG"
echo "out dir    : $OUT_DIR" | tee -a "$LOG"
echo "width      : $WIDTH" | tee -a "$LOG"
echo "height     : $HEIGHT" | tee -a "$LOG"
echo "fps        : $FPS" | tee -a "$LOG"
echo "duration   : $DURATION s" | tee -a "$LOG"
echo "frames     : $FRAMES" | tee -a "$LOG"
echo "audio dev  : $AUDIO_DEV" | tee -a "$LOG"
echo "audio rate : $AUDIO_RATE" | tee -a "$LOG"
echo "audio ch   : $AUDIO_CH" | tee -a "$LOG"
echo "stream path: $STREAM_PATH" | tee -a "$LOG"
echo "start      : $(date)" | tee -a "$LOG"

if [ ! -x scripts/exp19_1_realtime_av_rtsp_fix.sh ]; then
    echo "ERROR: scripts/exp19_1_realtime_av_rtsp_fix.sh not found or not executable" | tee -a "$LOG"
    exit 1
fi

cleanup() {
    echo | tee -a "$LOG"
    echo "========== exp20 cleanup ==========" | tee -a "$LOG"
    pkill -f "ffprobe.*${STREAM_PATH}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

get_cpu_temp() {
    local t=""
    for f in /sys/class/thermal/thermal_zone*/temp; do
        if [ -f "$f" ]; then
            t=$(cat "$f" 2>/dev/null || true)
            if [ -n "$t" ]; then
                awk -v v="$t" 'BEGIN { printf "%.1f", v / 1000.0 }'
                return
            fi
        fi
    done
    echo "NA"
}

get_cpu_freq_avg() {
    local files
    files=$(ls /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null || true)
    if [ -z "$files" ]; then
        echo "NA"
        return
    fi

    awk '
    {
        sum += $1;
        n += 1;
    }
    END {
        if (n > 0) {
            printf "%.1f", sum / n / 1000.0;
        } else {
            printf "NA";
        }
    }' $files
}

monitor_loop() {
    echo "timestamp,elapsed_s,load1,load5,load15,mem_total_kb,mem_available_kb,cpu_temp_c,cpu_freq_avg_mhz,stream_proc_cpu_percent,stream_proc_mem_percent,stream_proc_rss_kb,stream_proc_count" > "$MONITOR_CSV"

    local start_ts
    start_ts=$(date +%s)

    while true; do
        local now_ts elapsed
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))

        if [ "$elapsed" -gt $((DURATION + 20)) ]; then
            break
        fi

        local timestamp load1 load5 load15 mem_total mem_avail temp freq
        timestamp=$(date "+%Y-%m-%d %H:%M:%S")
        read -r load1 load5 load15 _ < /proc/loadavg

        mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        temp=$(get_cpu_temp)
        freq=$(get_cpu_freq_avg)

        local proc_line
        proc_line=$(ps -eo pcpu,pmem,rss,args --no-headers \
            | grep -E "mediamtx|ffmpeg|mpi_enc_test|v4l2_rga_rknn_detect_to_nv12_clean" \
            | grep -v grep \
            | awk '
                {
                    cpu += $1;
                    mem += $2;
                    rss += $3;
                    count += 1;
                }
                END {
                    if (count == 0) {
                        printf "0,0,0,0";
                    } else {
                        printf "%.2f,%.2f,%d,%d", cpu, mem, rss, count;
                    }
                }')

        echo "$timestamp,$elapsed,$load1,$load5,$load15,$mem_total,$mem_avail,$temp,$freq,$proc_line" >> "$MONITOR_CSV"

        {
            echo
            echo "========== $timestamp elapsed=${elapsed}s =========="
            ps -eo pid,ppid,stat,pcpu,pmem,rss,args \
                | grep -E "mediamtx|ffmpeg|mpi_enc_test|v4l2_rga_rknn_detect_to_nv12_clean" \
                | grep -v grep || true
        } >> "$PROCESS_LOG"

        {
            echo
            echo "========== $timestamp elapsed=${elapsed}s =========="
            ss -lntup 2>/dev/null | grep -E ":8554|:8888|:8889|:1935" || true
        } >> "$PORT_LOG"

        sleep 5
    done
}

probe_stream_once() {
    local delay="$1"
    local name="$2"

    (
        sleep "$delay"
        echo "========== ffprobe at ${delay}s ==========" > "$OUT_DIR/ffprobe_${name}.log"
        ffprobe \
            -hide_banner \
            -rtsp_transport tcp \
            -i "rtsp://127.0.0.1:8554/${STREAM_PATH}" \
            -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,avg_frame_rate,sample_rate,channels \
            -of json \
            > "$OUT_DIR/ffprobe_${name}.json" \
            2>> "$OUT_DIR/ffprobe_${name}.log" || true
    ) &
}

echo | tee -a "$LOG"
echo "========== start resource monitor ==========" | tee -a "$LOG"
monitor_loop &
MON_PID=$!

# 在推流过程中做几次 ffprobe，避免结束后流已经不存在
probe_stream_once 20 "20s"

if [ "$DURATION" -ge 80 ]; then
    probe_stream_once $((DURATION / 2)) "middle"
fi

if [ "$DURATION" -ge 60 ]; then
    probe_stream_once $((DURATION - 15)) "end"
fi

echo | tee -a "$LOG"
echo "========== run exp19-1 fixed av rtsp chain ==========" | tee -a "$LOG"

set +e
timeout $((DURATION + 80)) \
    ./scripts/exp19_1_realtime_av_rtsp_fix.sh \
    "$WIDTH" \
    "$HEIGHT" \
    "$FPS" \
    "$FRAMES" \
    "$AUDIO_DEV" \
    "$AUDIO_RATE" \
    "$AUDIO_CH" \
    > >(tee -a "$RUN_LOG") \
    2>&1

RUN_RC=$?
set -e

echo | tee -a "$LOG"
echo "exp19-1 wrapper return code: $RUN_RC" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== stop monitor ==========" | tee -a "$LOG"
kill "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true

echo | tee -a "$LOG"
echo "========== collect exp19-1 outputs ==========" | tee -a "$LOG"

if [ -d output/exp19_1_realtime_av_rtsp_fix ]; then
    cp -a output/exp19_1_realtime_av_rtsp_fix "$OUT_DIR/exp19_1_outputs"
    echo "copied output/exp19_1_realtime_av_rtsp_fix" | tee -a "$LOG"
else
    echo "WARN: output/exp19_1_realtime_av_rtsp_fix not found" | tee -a "$LOG"
fi

echo | tee -a "$LOG"
echo "========== grep key logs ==========" | tee -a "$LOG"

{
    echo "========== key patterns =========="
    grep -RniE \
        "2 tracks|stream is available|is publishing|is reading|wall_fps|frames[[:space:]]*:|average frame rate|xrun|Timestamps are unset|Thread message queue blocking|Broken pipe|No route to host|Connection refused|404|error|failed|fail" \
        "$OUT_DIR" 2>/dev/null || true

    echo
    echo "========== resource csv tail =========="
    tail -20 "$MONITOR_CSV" 2>/dev/null || true

    echo
    echo "========== ffprobe json files =========="
    ls -lh "$OUT_DIR"/ffprobe_*.json 2>/dev/null || true

    echo
    echo "========== ffprobe logs =========="
    for f in "$OUT_DIR"/ffprobe_*.log; do
        [ -f "$f" ] || continue
        echo
        echo "----- $f -----"
        cat "$f"
    done
} | tee -a "$SUMMARY"

echo | tee -a "$LOG"
echo "========== exp20 done ==========" | tee -a "$LOG"
echo "end        : $(date)" | tee -a "$LOG"
echo "out dir    : $OUT_DIR" | tee -a "$LOG"
echo "summary    : $SUMMARY" | tee -a "$LOG"


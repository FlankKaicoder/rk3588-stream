#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=${1:-output/exp12_latency_stability}
DURATION=${2:-600}
INTERVAL=${3:-5}

mkdir -p "$OUT_DIR"

CSV="$OUT_DIR/resource_samples.csv"
PROC_LOG="$OUT_DIR/process_samples.log"
PORT_LOG="$OUT_DIR/port_samples.log"
SUMMARY="$OUT_DIR/summary.txt"
LATENCY_CSV="$OUT_DIR/latency_observations.csv"

: > "$PROC_LOG"
: > "$PORT_LOG"
: > "$SUMMARY"

echo "timestamp,elapsed_s,load1,load5,load15,mem_total_kb,mem_available_kb,cpu_temp_c,cpu_freq_avg_mhz,stream_proc_cpu_percent,stream_proc_mem_percent,stream_proc_rss_kb,stream_proc_count" > "$CSV"

cat > "$LATENCY_CSV" <<'EOF_LAT'
protocol,client,round,real_clock_ms,stream_clock_ms,latency_ms,play_url,notes
WebRTC,Chrome/Edge,1,,,,http://BOARD_IP:8889/exp11_detect_browser,
WebRTC,Chrome/Edge,2,,,,http://BOARD_IP:8889/exp11_detect_browser,
WebRTC,Chrome/Edge,3,,,,http://BOARD_IP:8889/exp11_detect_browser,
RTSP_TCP,VLC,1,,,,rtsp://BOARD_IP:8554/exp11_detect_browser,
RTSP_TCP,VLC,2,,,,rtsp://BOARD_IP:8554/exp11_detect_browser,
RTSP_TCP,VLC,3,,,,rtsp://BOARD_IP:8554/exp11_detect_browser,
HLS,Browser,1,,,,http://BOARD_IP:8888/exp11_detect_browser,
HLS,Browser,2,,,,http://BOARD_IP:8888/exp11_detect_browser,
HLS,Browser,3,,,,http://BOARD_IP:8888/exp11_detect_browser,
EOF_LAT

get_cpu_temp_c() {
    local max_temp=""
    for f in /sys/class/thermal/thermal_zone*/temp; do
        [ -f "$f" ] || continue
        v=$(cat "$f" 2>/dev/null || echo "")
        [ -n "$v" ] || continue
        if [ "$v" -gt 1000 ] 2>/dev/null; then
            v=$(awk "BEGIN {printf \"%.1f\", $v/1000}")
        fi
        if [ -z "$max_temp" ]; then
            max_temp="$v"
        else
            max_temp=$(awk "BEGIN {if ($v > $max_temp) print $v; else print $max_temp}")
        fi
    done
    echo "${max_temp:-0}"
}

get_cpu_freq_avg_mhz() {
    local sum=0
    local cnt=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [ -f "$f" ] || continue
        v=$(cat "$f" 2>/dev/null || echo 0)
        sum=$((sum + v))
        cnt=$((cnt + 1))
    done

    if [ "$cnt" -eq 0 ]; then
        echo "0"
    else
        awk "BEGIN {printf \"%.1f\", $sum/$cnt/1000}"
    fi
}

get_stream_pids() {
    pgrep -f "mediamtx|ffmpeg|mpi_enc_test|v4l2_rga_rknn_detect_to_nv12_clean" 2>/dev/null | sort -u || true
}

echo "========== exp12 resource monitor ==========" | tee -a "$SUMMARY"
echo "out dir : $OUT_DIR" | tee -a "$SUMMARY"
echo "duration: $DURATION s" | tee -a "$SUMMARY"
echo "interval: $INTERVAL s" | tee -a "$SUMMARY"
echo "start   : $(date)" | tee -a "$SUMMARY"
echo | tee -a "$SUMMARY"

START_TS=$(date +%s)
END_TS=$((START_TS + DURATION))

while true; do
    NOW_TS=$(date +%s)
    if [ "$NOW_TS" -gt "$END_TS" ]; then
        break
    fi

    ELAPSED=$((NOW_TS - START_TS))
    TS=$(date "+%Y-%m-%d %H:%M:%S")

    read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg

    MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    MEM_AVAIL=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)

    CPU_TEMP=$(get_cpu_temp_c)
    CPU_FREQ=$(get_cpu_freq_avg_mhz)

    PIDS=$(get_stream_pids)
    PROC_COUNT=0
    PROC_CPU=0
    PROC_MEM=0
    PROC_RSS=0

    if [ -n "$PIDS" ]; then
        PROC_COUNT=$(echo "$PIDS" | wc -w)

        PROC_STATS=$(ps -p "$(echo "$PIDS" | paste -sd, -)" -o %cpu=,%mem=,rss= 2>/dev/null || true)

        if [ -n "$PROC_STATS" ]; then
            PROC_CPU=$(echo "$PROC_STATS" | awk '{sum+=$1} END {printf "%.2f", sum+0}')
            PROC_MEM=$(echo "$PROC_STATS" | awk '{sum+=$2} END {printf "%.2f", sum+0}')
            PROC_RSS=$(echo "$PROC_STATS" | awk '{sum+=$3} END {printf "%.0f", sum+0}')
        fi
    fi

    echo "$TS,$ELAPSED,$LOAD1,$LOAD5,$LOAD15,$MEM_TOTAL,$MEM_AVAIL,$CPU_TEMP,$CPU_FREQ,$PROC_CPU,$PROC_MEM,$PROC_RSS,$PROC_COUNT" >> "$CSV"

    {
        echo
        echo "========== $TS elapsed=${ELAPSED}s =========="
        echo "PIDS: $PIDS"
        ps -eo pid,ppid,stat,%cpu,%mem,rss,comm,args \
            | grep -E "mediamtx|ffmpeg|mpi_enc_test|v4l2_rga_rknn_detect_to_nv12_clean" \
            | grep -v grep || true
    } >> "$PROC_LOG"

    {
        echo
        echo "========== $TS elapsed=${ELAPSED}s =========="
        ss -lntup 2>/dev/null | grep -E ":8554|:8888|:8889|:1935" || true
        ss -lunp 2>/dev/null | grep -E ":8189" || true
    } >> "$PORT_LOG"

    sleep "$INTERVAL"
done

echo | tee -a "$SUMMARY"
echo "end     : $(date)" | tee -a "$SUMMARY"
echo "csv     : $CSV" | tee -a "$SUMMARY"
echo "proc log: $PROC_LOG" | tee -a "$SUMMARY"
echo "port log: $PORT_LOG" | tee -a "$SUMMARY"
echo "latency : $LATENCY_CSV" | tee -a "$SUMMARY"

echo | tee -a "$SUMMARY"
echo "========== last resource samples ==========" | tee -a "$SUMMARY"
tail -10 "$CSV" | tee -a "$SUMMARY"

echo | tee -a "$SUMMARY"
echo "========== possible stream logs ==========" | tee -a "$SUMMARY"
find output -maxdepth 3 -type f \
    \( -name "mediamtx.log" -o -name "ffmpeg*.log" -o -name "mpi_enc*.log" -o -name "realtime_detect*.log" -o -name "*.csv" \) \
    | grep -E "exp10|exp11|exp12" \
    | sort \
    | tee -a "$SUMMARY" || true

echo
echo "exp12 monitor done."
echo "summary saved to: $SUMMARY"

#!/usr/bin/env bash
set -u

OUT_DIR=${1:?usage: $0 <out_dir> <interval_s> <watch_pid>}
INTERVAL=${2:-5}
WATCH_PID=${3:-}

mkdir -p "$OUT_DIR"

CSV="$OUT_DIR/resource_samples.csv"
PROC_LOG="$OUT_DIR/process_samples.log"
PORT_LOG="$OUT_DIR/port_samples.log"
TEMP_LOG="$OUT_DIR/temp_freq_samples.log"

echo "timestamp,elapsed_s,load1,load5,load15,mem_total_kb,mem_available_kb,cpu_temp_c,cpu_freq_avg_mhz,stream_proc_cpu_percent,stream_proc_mem_percent,stream_proc_rss_kb,stream_proc_count" > "$CSV"

START_TS=$(date +%s)

get_loads() {
    awk '{print $1","$2","$3}' /proc/loadavg
}

get_mem() {
    awk '
    /MemTotal:/ {total=$2}
    /MemAvailable:/ {avail=$2}
    END {print total","avail}
    ' /proc/meminfo
}

get_temp_c() {
    local max_temp=""
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        t=$(cat "$z" 2>/dev/null || echo "")
        [ -n "$t" ] || continue
        if [ -z "$max_temp" ] || [ "$t" -gt "$max_temp" ]; then
            max_temp="$t"
        fi
    done

    if [ -z "$max_temp" ]; then
        echo "NA"
    else
        awk -v t="$max_temp" 'BEGIN {printf "%.1f", t/1000.0}'
    fi
}

get_avg_freq_mhz() {
    local sum=0
    local cnt=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null || echo "")
        [ -n "$v" ] || continue
        sum=$((sum + v))
        cnt=$((cnt + 1))
    done

    if [ "$cnt" -eq 0 ]; then
        echo "NA"
    else
        awk -v s="$sum" -v c="$cnt" 'BEGIN {printf "%.1f", s/c/1000.0}'
    fi
}

sample_stream_proc() {
    ps -eo pid,ppid,stat,pcpu,pmem,rss,comm,args \
        | grep -E "exp21_detect_mpp_encode_async|ffmpeg|mediamtx" \
        | grep -v grep
}

sum_proc_stats() {
    sample_stream_proc | awk '
    {
        cpu += $4;
        mem += $5;
        rss += $6;
        count += 1;
    }
    END {
        if (count == 0) {
            printf "0,0,0,0";
        } else {
            printf "%.2f,%.2f,%d,%d", cpu, mem, rss, count;
        }
    }'
}

echo "========== exp23 resource monitor ==========" | tee -a "$PROC_LOG"
echo "out dir : $OUT_DIR" | tee -a "$PROC_LOG"
echo "interval: $INTERVAL s" | tee -a "$PROC_LOG"
echo "watch pid: ${WATCH_PID:-none}" | tee -a "$PROC_LOG"
echo "start   : $(date)" | tee -a "$PROC_LOG"

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TS))
    TS=$(date "+%Y-%m-%d %H:%M:%S")

    LOADS=$(get_loads)
    MEM=$(get_mem)
    TEMP=$(get_temp_c)
    FREQ=$(get_avg_freq_mhz)
    PROC_STATS=$(sum_proc_stats)

    echo "$TS,$ELAPSED,$LOADS,$MEM,$TEMP,$FREQ,$PROC_STATS" >> "$CSV"

    {
        echo
        echo "========== $TS elapsed=${ELAPSED}s =========="
        sample_stream_proc || true
    } >> "$PROC_LOG"

    {
        echo
        echo "========== $TS elapsed=${ELAPSED}s =========="
        ss -ltnp 2>/dev/null | grep -E ":8554|:1935|:8888|:8889|:8890" || true
    } >> "$PORT_LOG"

    {
        echo
        echo "========== $TS elapsed=${ELAPSED}s =========="
        echo "thermal:"
        for z in /sys/class/thermal/thermal_zone*/temp; do
            [ -r "$z" ] && echo "$z $(cat "$z")"
        done
        echo
        echo "freq:"
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            [ -r "$f" ] && echo "$f $(cat "$f")"
        done
        echo
        echo "governor:"
        cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c
    } >> "$TEMP_LOG"

    if [ -n "$WATCH_PID" ]; then
        if ! kill -0 "$WATCH_PID" 2>/dev/null; then
            break
        fi
    fi

    sleep "$INTERVAL"
done

echo "end: $(date)" | tee -a "$PROC_LOG"
echo "csv: $CSV" | tee -a "$PROC_LOG"

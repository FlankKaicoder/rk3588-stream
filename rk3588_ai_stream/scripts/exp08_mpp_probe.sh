#!/usr/bin/env bash
set -e

OUT_DIR=output/exp08_mpp_probe
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/probe.log"
: > "$LOG"

run_cmd() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

echo "08 MPP probe start" | tee -a "$LOG"
date | tee -a "$LOG"

echo
echo "========== system ==========" | tee -a "$LOG"
uname -a | tee -a "$LOG"
cat /etc/os-release 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== CPU governor ==========" | tee -a "$LOG"
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== MPP headers ==========" | tee -a "$LOG"
find /usr /usr/local /opt "$HOME" \
    \( -name "rk_mpi.h" \
    -o -name "mpp_api.h" \
    -o -name "mpp_frame.h" \
    -o -name "mpp_packet.h" \
    -o -name "mpp_buffer.h" \
    -o -name "rk_mpi_cmd.h" \
    -o -name "mpp_enc_cfg.h" \) \
    2>/dev/null | sort | tee -a "$LOG" || true

echo
echo "========== MPP libraries ==========" | tee -a "$LOG"
find /usr /usr/local /opt "$HOME" \
    \( -name "librockchip_mpp.so*" \
    -o -name "libmpp.so*" \
    -o -name "libvpu.so*" \
    -o -name "librockchip_vpu.so*" \) \
    2>/dev/null | sort | tee -a "$LOG" || true

echo
echo "========== ldconfig MPP ==========" | tee -a "$LOG"
ldconfig -p 2>/dev/null | grep -Ei "mpp|rockchip|vpu" | tee -a "$LOG" || true

echo
echo "========== pkg-config ==========" | tee -a "$LOG"
pkg-config --list-all 2>/dev/null | grep -Ei "mpp|rockchip|vpu|rga" | tee -a "$LOG" || true

echo
echo "========== MPP sample executables ==========" | tee -a "$LOG"
find /usr /usr/local /opt "$HOME" \
    \( -name "mpi_enc_test" \
    -o -name "mpi_dec_test" \
    -o -name "mpi_*_test" \
    -o -name "*mpp*test*" \
    -o -name "*enc*test*" \) \
    -type f 2>/dev/null | sort | tee -a "$LOG" || true

echo
echo "========== MPP sample source ==========" | tee -a "$LOG"
find /usr /usr/local /opt "$HOME" \
    \( -name "mpi_enc_test.c" \
    -o -name "mpi_enc_test.cpp" \
    -o -name "mpi_enc_utils.c" \
    -o -name "mpi_enc_utils.h" \
    -o -name "CMakeLists.txt" \) \
    2>/dev/null | grep -Ei "mpp|mpi|rockchip|rk" | sort | tee -a "$LOG" || true

echo
echo "========== video device ==========" | tee -a "$LOG"
v4l2-ctl -d /dev/video11 --all 2>&1 | tee -a "$LOG" || true

echo
echo "========== video formats ==========" | tee -a "$LOG"
v4l2-ctl -d /dev/video11 --list-formats-ext 2>&1 | tee -a "$LOG" || true

echo
echo "========== quick v4l2 fps check ==========" | tee -a "$LOG"
v4l2-ctl -d /dev/video11 \
  --set-fmt-video-mplane=width=1280,height=720,pixelformat=NV12 \
  --stream-mmap=4 \
  --stream-count=120 \
  --stream-to=/dev/null 2>&1 | tee -a "$LOG" || true

echo
echo "probe log saved to: $LOG"

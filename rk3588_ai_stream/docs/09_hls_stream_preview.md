# 09 HLS 实时检测预览实验记录

## 1. 实验背景

前面 08 实验已经完成了 RK3588 端侧 AI 检测录像链路。

08 的核心链路是：

```text
摄像头 /dev/video11
        ↓
V4L2 mmap 采集 1280x720 NV12
        ↓
RGA NV12 → RGB888
        ↓
RKNN YOLO11 推理
        ↓
检测框绘制
        ↓
RGA RGB888 → NV12
        ↓
FIFO
        ↓
MPP H.264 硬件编码
        ↓
保存 H.264 / MP4 检测视频
```

08 实验已经证明：

```text
1. V4L2 mmap 可以稳定采集 /dev/video11 的 1280x720 NV12；
2. RGA 可以完成 NV12 ↔ RGB888 双向转换；
3. RKNN YOLO11 推理链路可以接入实时摄像头输入；
4. MPP 编码器可以对 NV12 进行 H.264 硬件编码；
5. 检测后的画框视频可以保存为 H.264 / MP4 文件；
6. MPP 编码器本身不是主要瓶颈；
7. 完整检测 + 编码链路已经可以接近实时运行。
```

但是 08 仍然只是“本地录像保存”，还没有实现远程预览。真实的端侧 AI 视频系统不仅需要保存录像，还需要支持电脑端、上位机或浏览器端实时查看检测画面。

因此 09 实验继续在 08 基础上增加网络预览链路。

09 的目标是：

```text
实时摄像头检测
        ↓
MPP H.264 编码
        ↓
FFmpeg HLS 切片
        ↓
HTTP 服务
        ↓
电脑端 VLC 网络预览
```

---

## 2. 实验目标

本实验主要完成以下目标：

```text
1. 探测板端流媒体环境；
2. 检查 ffmpeg / ffprobe / ffplay 是否可用；
3. 检查是否存在 RTSP Server，例如 mediamtx / rtsp-simple-server；
4. 使用 08 已生成的检测 MP4 文件验证 HLS 文件预览；
5. 使用 VLC 播放板端 HLS 地址；
6. 将实时检测链路输出的 NV12 FIFO 接入 MPP 编码器；
7. 将 MPP 输出的 H.264 FIFO 接入 FFmpeg；
8. 使用 FFmpeg 生成 HLS 切片；
9. 使用 Python HTTP Server 提供 HLS 文件访问；
10. 使用 VLC 播放实时摄像头检测画面；
11. 排查 09-2 初次失败时的 V4L2 / RKISP / IMX415 问题；
12. 总结摄像头链路异常恢复方法。
```

---

## 3. 当前工程路径

当前工程路径：

```bash
~/projects/rk3588_ai_stream
```

相关文件结构：

```text
rk3588_ai_stream/
├── build/
│   ├── v4l2_dump_nv12
│   └── v4l2_rga_rknn_detect_to_nv12_clean
│
├── scripts/
│   ├── exp09_0_stream_probe.sh
│   ├── exp09_1_hls_file_preview.sh
│   └── exp09_2_realtime_detect_hls.sh
│
├── output/
│   ├── exp09_stream_probe/
│   │   └── probe.log
│   │
│   ├── exp09_1_hls_file_preview/
│   │   ├── 09_1_hls.log
│   │   ├── ffmpeg_hls.log
│   │   ├── python_http.log
│   │   └── hls/
│   │       ├── index.m3u8
│   │       └── index*.ts
│   │
│   ├── exp09_2_realtime_detect_hls/
│   │   ├── 09_2.log
│   │   ├── realtime_detect_to_nv12.log
│   │   ├── mpi_enc_hls.log
│   │   ├── ffmpeg_hls.log
│   │   ├── python_http.log
│   │   ├── profile_realtime_detect_hls.csv
│   │   └── hls/
│   │       ├── index.m3u8
│   │       └── index*.ts
│   │
│   └── exp09_2_camera_check/
│       ├── test_after_power_cycle.nv12
│       └── rkaiq_debug/
│
└── docs/
    └── 09_hls_stream_preview.md
```

---

## 4. 09-0：流媒体环境探测

### 4.1 实验目的

09-0 的目的不是推流，而是先确认当前板端是否具备网络预览所需的基础环境。

需要确认：

```text
1. 板端 IP 地址；
2. ffmpeg 是否存在；
3. ffprobe 是否存在；
4. ffplay 是否存在；
5. 是否存在 RTSP Server；
6. ffmpeg 是否支持 HLS / RTSP / FLV / H.264 / MP4；
7. 08 实验是否已经生成可用于测试的 MP4 / H.264 文件。
```

这样做的原因是：

```text
如果板端没有 RTSP Server，就不能直接做 RTSP；
如果 ffmpeg 不支持 HLS，就不能用 HLS；
如果网络访问不通，VLC 也无法播放；
如果 08 输出文件不存在，就无法先做文件级预览验证。
```

所以 09-0 是整个 09 实验的前置环境检查。

---

### 4.2 09-0 探测脚本

创建脚本：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp09_stream_probe
mkdir -p scripts

cat > scripts/exp09_0_stream_probe.sh <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp09_stream_probe
mkdir -p "$OUT_DIR"

LOG="$OUT_DIR/probe.log"
: > "$LOG"

run_cmd() {
    echo
    echo "========== $* =========="
    echo "========== $* ==========" >> "$LOG"
    "$@" 2>&1 | tee -a "$LOG" || true
}

echo "09 stream probe start" | tee -a "$LOG"
date | tee -a "$LOG"

echo
echo "========== system ==========" | tee -a "$LOG"
uname -a | tee -a "$LOG"
cat /etc/os-release 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== board ip ==========" | tee -a "$LOG"
hostname -I 2>/dev/null | tee -a "$LOG" || true
ip addr 2>/dev/null | grep -E "inet " | tee -a "$LOG" || true

echo
echo "========== ffmpeg ==========" | tee -a "$LOG"
which ffmpeg 2>/dev/null | tee -a "$LOG" || true
ffmpeg -version 2>/dev/null | head -20 | tee -a "$LOG" || true

echo
echo "========== ffprobe ==========" | tee -a "$LOG"
which ffprobe 2>/dev/null | tee -a "$LOG" || true
ffprobe -version 2>/dev/null | head -10 | tee -a "$LOG" || true

echo
echo "========== ffplay ==========" | tee -a "$LOG"
which ffplay 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== streaming servers ==========" | tee -a "$LOG"
which mediamtx 2>/dev/null | tee -a "$LOG" || true
which rtsp-simple-server 2>/dev/null | tee -a "$LOG" || true
which ZLMediaKit 2>/dev/null | tee -a "$LOG" || true
which MediaServer 2>/dev/null | tee -a "$LOG" || true
which nginx 2>/dev/null | tee -a "$LOG" || true

echo
echo "========== ffmpeg protocols ==========" | tee -a "$LOG"
ffmpeg -hide_banner -protocols 2>/dev/null | grep -E "rtsp|rtmp|http|tcp|udp|file" | tee -a "$LOG" || true

echo
echo "========== ffmpeg muxers ==========" | tee -a "$LOG"
ffmpeg -hide_banner -muxers 2>/dev/null | grep -E "rtsp|rtp|flv|hls|mpegts|mp4|h264" | tee -a "$LOG" || true

echo
echo "========== port check ==========" | tee -a "$LOG"
ss -lntup 2>/dev/null | grep -E ":8554|:8080|:8888|:1935" | tee -a "$LOG" || true

echo
echo "========== existing exp08 outputs ==========" | tee -a "$LOG"
find output -maxdepth 3 -type f \
    \( -name "*.mp4" -o -name "*.h264" -o -name "*.csv" \) \
    | sort \
    | grep -E "exp08|camera|mpp|detect|fifo|nv12" \
    | tee -a "$LOG" || true

echo
echo "probe log saved to: $LOG"
EOF_SCRIPT

chmod +x scripts/exp09_0_stream_probe.sh
./scripts/exp09_0_stream_probe.sh
```

---

### 4.3 09-0 探测结果

板端 IP：

```text
10.198.89.221
```

ffmpeg：

```text
/usr/bin/ffmpeg
ffmpeg version 4.3.9-0+deb11u2
```

ffprobe：

```text
/usr/bin/ffprobe
```

ffplay：

```text
/usr/bin/ffplay
```

当前没有找到 RTSP Server：

```text
streaming servers 为空
未找到 mediamtx
未找到 rtsp-simple-server
未找到 ZLMediaKit
```

ffmpeg 支持的相关协议：

```text
http
https
rtmp
tcp
udp
file
```

ffmpeg 支持的相关 muxer：

```text
flv
h264
hls
mp4
mpegts
rtp
rtsp
```

已有 08 输出文件：

```text
output/exp08_2_v4l2_fifo_mpp/live_120f_1280x720.h264
output/exp08_2_v4l2_fifo_mpp/live_120f_1280x720.mp4

output/exp08_3_detect_fifo_mpp/live_detect_120f_1280x720.h264
output/exp08_3_detect_fifo_mpp/live_detect_120f_1280x720.mp4

output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.h264
output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4
```

---

### 4.4 09-0 结论

09-0 结论：

```text
1. 板端 ffmpeg / ffprobe / ffplay 环境完整；
2. 当前板端没有现成 RTSP Server；
3. 暂时不适合直接做 RTSP；
4. ffmpeg 支持 HLS；
5. 可以先使用 HLS 进行网络预览验证；
6. 08 已经存在检测 MP4 文件，可以作为 09-1 的输入。
```

因此 09 路线确定为：

```text
先做 HLS 文件预览；
再做实时检测 HLS 预览；
RTSP 后续作为 10 实验继续做。
```

---

## 5. 09-1：检测 MP4 文件 HLS 预览

### 5.1 实验目的

09-1 先不接实时摄像头，而是使用 08 已经生成的检测 MP4 文件作为输入。

这样做的原因是：

```text
1. 先验证 HLS + HTTP + VLC 网络预览链路；
2. 不引入摄像头、RKNN、MPP、FIFO 等复杂因素；
3. 如果播放失败，可以确认问题只在 HLS / 网络 / VLC；
4. 如果播放成功，再将输入替换为实时检测编码输出。
```

09-1 链路：

```text
08 检测 MP4
        ↓
ffmpeg 循环读取
        ↓
-c:v copy 不重新编码
        ↓
HLS 切片
        ↓
python3 -m http.server
        ↓
VLC 网络预览
```

---

### 5.2 09-1 脚本

创建脚本：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p scripts
mkdir -p output/exp09_1_hls_file_preview

cat > scripts/exp09_1_hls_file_preview.sh <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp09_1_hls_file_preview
HLS_DIR="$OUT_DIR/hls"
LOG="$OUT_DIR/09_1_hls.log"

mkdir -p "$OUT_DIR" "$HLS_DIR"
rm -f "$HLS_DIR"/*

: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

INPUT_MP4="output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4"

if [ ! -f "$INPUT_MP4" ]; then
    echo "ERROR: input mp4 not found: $INPUT_MP4" | tee -a "$LOG"
    echo "Try checking:" | tee -a "$LOG"
    find output -maxdepth 3 -type f -name "*.mp4" | sort | tee -a "$LOG"
    exit 1
fi

echo "========== 09-1 HLS file preview ==========" | tee -a "$LOG"
echo "board ip : $BOARD_IP" | tee -a "$LOG"
echo "input mp4: $INPUT_MP4" | tee -a "$LOG"
echo "hls dir  : $HLS_DIR" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== ffprobe input ==========" | tee -a "$LOG"
ffprobe -hide_banner "$INPUT_MP4" 2>&1 | tee "$OUT_DIR/input_ffprobe.log" || true

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    if [ -n "${FFMPEG_PID:-}" ]; then
        kill "$FFMPEG_PID" 2>/dev/null || true
    fi

    if [ -n "${HTTP_PID:-}" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo | tee -a "$LOG"
echo "========== start ffmpeg HLS ==========" | tee -a "$LOG"

ffmpeg -re -stream_loop -1 \
    -i "$INPUT_MP4" \
    -an \
    -c:v copy \
    -f hls \
    -hls_time 1 \
    -hls_list_size 5 \
    -hls_flags delete_segments+append_list \
    "$HLS_DIR/index.m3u8" \
    > "$OUT_DIR/ffmpeg_hls.log" 2>&1 &

FFMPEG_PID=$!

sleep 3

echo | tee -a "$LOG"
echo "========== generated hls files ==========" | tee -a "$LOG"
ls -lh "$HLS_DIR" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== start http server ==========" | tee -a "$LOG"

cd "$HLS_DIR"
python3 -m http.server 8080 > "../python_http.log" 2>&1 &
HTTP_PID=$!
cd - >/dev/null

echo | tee -a "$LOG"
echo "HLS URL:" | tee -a "$LOG"
echo "  http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "在电脑 VLC 中打开：" | tee -a "$LOG"
echo "  媒体 -> 打开网络串流 -> http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "按 Ctrl+C 结束本实验。" | tee -a "$LOG"

wait "$FFMPEG_PID"
EOF_SCRIPT

chmod +x scripts/exp09_1_hls_file_preview.sh
./scripts/exp09_1_hls_file_preview.sh
```

---

### 5.3 VLC 打开方式

板端 IP：

```text
10.198.89.221
```

VLC 中打开：

```text
http://10.198.89.221:8080/index.m3u8
```

操作路径：

```text
VLC
    ↓
媒体
    ↓
打开网络串流
    ↓
输入 http://10.198.89.221:8080/index.m3u8
    ↓
播放
```

---

### 5.4 09-1 实验结果

电脑端 VLC 可以播放 08 检测视频循环画面。

说明：

```text
1. 板端 HLS 文件切片成功；
2. python3 HTTP server 可以正常提供文件；
3. 电脑端可以访问板端 8080 端口；
4. VLC 可以识别并播放 HLS；
5. HLS 文件预览链路已经跑通。
```

---

### 5.5 09-1 结论

09-1 证明：

```text
08 检测 MP4
        ↓
FFmpeg HLS
        ↓
HTTP Server
        ↓
VLC
```

这一条链路是可行的。

因此下一步可以将输入从：

```text
已有 MP4 文件
```

替换为：

```text
实时检测编码输出
```

---

## 6. 09-2：实时检测 FIFO H.264 → HLS 预览

### 6.1 实验目的

09-2 是本实验的核心。

09-1 只是播放已有 MP4 文件，不能代表真正实时系统。09-2 要把实时摄像头检测链路接入 HLS。

最终目标链路：

```text
摄像头 /dev/video11
        ↓
V4L2 mmap 采集 1280x720 NV12
        ↓
RGA NV12 → RGB888
        ↓
RKNN YOLO11 推理
        ↓
检测框绘制
        ↓
RGA RGB888 → NV12
        ↓
NV12 FIFO
        ↓
mpi_enc_test MPP H.264 编码
        ↓
H264 FIFO
        ↓
FFmpeg HLS 切片
        ↓
python3 -m http.server
        ↓
电脑端 VLC 网络实时预览
```

---

### 6.2 为什么使用两个 FIFO？

09-2 中有两个 FIFO：

```text
realtime_detect_nv12.fifo
realtime_detect_h264.fifo
```

作用分别是：

```text
NV12 FIFO：
    v4l2_rga_rknn_detect_to_nv12_clean 写入检测后的 NV12 帧；
    mpi_enc_test 从该 FIFO 读取 NV12 原始帧。

H264 FIFO：
    mpi_enc_test 写入编码后的 H.264 裸流；
    ffmpeg 从该 FIFO 读取 H.264 并切成 HLS。
```

整体数据流：

```text
检测程序
    ↓ NV12 FIFO
MPP 编码器
    ↓ H264 FIFO
FFmpeg HLS
```

这样做的好处：

```text
1. 不需要先保存完整 raw 文件；
2. 不需要先保存完整 H.264 文件；
3. 各模块通过 FIFO 串联；
4. 更接近实时工程结构；
5. 方便分阶段排查问题。
```

---

### 6.3 09-2 最终脚本

创建脚本：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p scripts
mkdir -p output/exp09_2_realtime_detect_hls

cat > scripts/exp09_2_realtime_detect_hls.sh <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp09_2_realtime_detect_hls
HLS_DIR="$OUT_DIR/hls"
LOG="$OUT_DIR/09_2.log"

mkdir -p "$OUT_DIR" "$HLS_DIR"
rm -f "$HLS_DIR"/*

: > "$LOG"

BOARD_IP=$(hostname -I | awk '{print $1}')

WIDTH=1280
HEIGHT=720
FPS=30

# 10分钟左右，避免还没打开 VLC 就结束
FRAMES=18000

NV12_FIFO="$OUT_DIR/realtime_detect_nv12.fifo"
H264_FIFO="$OUT_DIR/realtime_detect_h264.fifo"
PROFILE="$OUT_DIR/profile_realtime_detect_hls.csv"

rm -f "$NV12_FIFO" "$H264_FIFO" "$PROFILE"
mkfifo "$NV12_FIFO"
mkfifo "$H264_FIFO"

echo "========== 09-2 realtime detect HLS ==========" | tee -a "$LOG"
echo "board ip  : $BOARD_IP" | tee -a "$LOG"
echo "width     : $WIDTH" | tee -a "$LOG"
echo "height    : $HEIGHT" | tee -a "$LOG"
echo "fps       : $FPS" | tee -a "$LOG"
echo "frames    : $FRAMES" | tee -a "$LOG"
echo "nv12 fifo : $NV12_FIFO" | tee -a "$LOG"
echo "h264 fifo : $H264_FIFO" | tee -a "$LOG"
echo "hls dir   : $HLS_DIR" | tee -a "$LOG"

cleanup() {
    echo | tee -a "$LOG"
    echo "cleanup..." | tee -a "$LOG"

    kill ${DETECT_PID:-0} 2>/dev/null || true
    kill ${ENC_PID:-0} 2>/dev/null || true
    kill ${FFMPEG_PID:-0} 2>/dev/null || true
    kill ${HTTP_PID:-0} 2>/dev/null || true

    sudo pkill -f "v4l2_rga_rknn_detect_to_nv12_clean" 2>/dev/null || true
    pkill -f "mpi_enc_test" 2>/dev/null || true
    pkill -f "ffmpeg.*realtime_detect_h264" 2>/dev/null || true
    pkill -f "python3 -m http.server 8080" 2>/dev/null || true

    rm -f "$NV12_FIFO" "$H264_FIFO"
}
trap cleanup EXIT

echo | tee -a "$LOG"
echo "========== start HTTP server ==========" | tee -a "$LOG"

cd "$HLS_DIR"
python3 -m http.server 8080 > "../python_http.log" 2>&1 &
HTTP_PID=$!
cd - >/dev/null

sleep 1

echo | tee -a "$LOG"
echo "========== start ffmpeg: H264 FIFO -> HLS ==========" | tee -a "$LOG"

ffmpeg -y \
    -fflags nobuffer \
    -flags low_delay \
    -f h264 \
    -framerate "$FPS" \
    -i "$H264_FIFO" \
    -an \
    -c:v copy \
    -f hls \
    -hls_time 1 \
    -hls_list_size 5 \
    -hls_flags delete_segments+append_list \
    "$HLS_DIR/index.m3u8" \
    > "$OUT_DIR/ffmpeg_hls.log" 2>&1 &

FFMPEG_PID=$!

sleep 1

echo | tee -a "$LOG"
echo "========== start MPP encoder: NV12 FIFO -> H264 FIFO ==========" | tee -a "$LOG"

/home/cat/mpp/build/test/mpi_enc_test \
    -i "$NV12_FIFO" \
    -o "$H264_FIFO" \
    -w "$WIDTH" \
    -h "$HEIGHT" \
    -f 0 \
    -t 7 \
    -n "$FRAMES" \
    > "$OUT_DIR/mpi_enc_hls.log" 2>&1 &

ENC_PID=$!

sleep 1

echo | tee -a "$LOG"
echo "========== start realtime detect writer: camera -> NV12 FIFO ==========" | tee -a "$LOG"

sudo ./build/v4l2_rga_rknn_detect_to_nv12_clean \
    models/yolo11.rknn \
    /dev/video11 \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$NV12_FIFO" \
    "$PROFILE" \
    > "$OUT_DIR/realtime_detect_to_nv12.log" 2>&1 &

DETECT_PID=$!

echo | tee -a "$LOG"
echo "HLS URL:" | tee -a "$LOG"
echo "  http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "现在去电脑 VLC 打开：" | tee -a "$LOG"
echo "  http://$BOARD_IP:8080/index.m3u8" | tee -a "$LOG"
echo | tee -a "$LOG"
echo "提示：HLS 需要等 3~8 秒生成 index.m3u8 和 ts 分片。" | tee -a "$LOG"
echo "本脚本会持续运行约 10 分钟，按 Ctrl+C 可提前结束。" | tee -a "$LOG"

wait "$DETECT_PID" || true

echo | tee -a "$LOG"
echo "========== detect finished, wait encoder ==========" | tee -a "$LOG"
wait "$ENC_PID" || true

sleep 3
kill "$FFMPEG_PID" 2>/dev/null || true

echo | tee -a "$LOG"
echo "========== generated HLS files ==========" | tee -a "$LOG"
ls -lh "$HLS_DIR" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== detect log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/realtime_detect_to_nv12.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== encoder log tail ==========" | tee -a "$LOG"
tail -80 "$OUT_DIR/mpi_enc_hls.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== ffmpeg log tail ==========" | tee -a "$LOG"
tail -120 "$OUT_DIR/ffmpeg_hls.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== profile csv ==========" | tee -a "$LOG"
ls -lh "$PROFILE" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "09-2 done." | tee -a "$LOG"
EOF_SCRIPT

chmod +x scripts/exp09_2_realtime_detect_hls.sh
```

运行：

```bash
./scripts/exp09_2_realtime_detect_hls.sh
```

---

### 6.4 VLC 播放地址

脚本输出：

```text
HLS URL:
  http://10.198.89.221:8080/index.m3u8
```

VLC 中打开：

```text
http://10.198.89.221:8080/index.m3u8
```

注意：

```text
HLS 不是低延迟协议；
需要等 3~8 秒，等 FFmpeg 生成 index.m3u8 和 ts 分片；
VLC 端会有几秒延迟，这是正常现象。
```

---

### 6.5 09-2 最终实验结果

最终 09-2 成功。

电脑端 VLC 可以播放实时摄像头检测画面。

说明完整链路已经跑通：

```text
摄像头实时输入
        ↓
RKNN YOLO11 检测
        ↓
MPP H.264 编码
        ↓
FFmpeg HLS
        ↓
VLC 实时预览
```

---

## 7. 09-2 初次失败问题排查

09-2 第一次运行时并没有成功。现象是脚本很快结束，VLC 还没打开，HLS 文件就已经生成结束。

### 7.1 初次失败现象

HLS 目录中只有：

```text
index.m3u8
index0.ts
```

其中：

```text
index0.ts 为 0 字节
```

检测程序日志：

```text
select timeout at frame=0
```

MPP 编码器日志：

```text
found last frame. feof 1
encoded frame 0 size 0
```

FFmpeg 日志：

```text
missing picture in access unit
no frame
Could not find codec parameters for stream 0
```

说明：

```text
1. FFmpeg 没有收到有效 H.264 视频帧；
2. MPP 编码器没有收到有效 NV12 帧；
3. 实时检测程序没有采集到第一帧；
4. 问题不在 VLC，也不在 HLS 本身；
5. 问题源头在 V4L2 摄像头采集。
```

---

### 7.2 使用 v4l2_dump_nv12 做最小采集验证

为了排除 HLS、FFmpeg、MPP、RKNN 等因素，回到最小采集链路：

```bash
sudo ./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  30 \
  output/exp09_2_camera_check/test_30f_1280x720.nv12
```

结果出现：

```text
select timeout at frame=0
```

说明：

```text
最小 V4L2 采集都没有拿到第一帧；
完整 HLS 链路失败的根源在摄像头 / RKISP / V4L2 输入端。
```

---

### 7.3 第一次 dmesg：IMX415 sensor 启流失败

清空 dmesg 后再次运行最小采集：

```bash
sudo dmesg -C

sudo ./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  30 \
  output/exp09_2_camera_check/test_30f_1280x720_dmesg.nv12

dmesg | tail -150
```

dmesg 关键输出：

```text
rkisp_hw fdcb0000.rkisp: set isp clk = 594000000Hz
rkcif-mipi-lvds: stream[0] start streaming
rockchip-mipi-csi2 mipi0-csi2: stream ON
rockchip-csi2-dphy0: dphy0, data_rate_mbps 892
imx415 1-001a: s_stream: 1. 3864x2192, hdr: 0, bpp: 10
m00_b_imx415 1-001a: start stream failed while write regs
rkisp0-vir0: rkisp_stream_stop id:0 timeout
rkisp0-vir0: waiting on params stream off event timeout
```

这说明：

```text
1. RKISP / RKCIF / MIPI 都尝试启动；
2. 驱动调用 IMX415 sensor 的 s_stream(1)；
3. IMX415 需要通过 I2C 写寄存器启动出图；
4. 写寄存器失败；
5. sensor 没有真正输出图像；
6. /dev/video11 自然等不到帧；
7. V4L2 select 最终 timeout。
```

根因不是 HLS，而是：

```text
IMX415 / RKISP / MIPI 摄像头链路异常。
```

---

### 7.4 第二阶段错误：VIDIOC_STREAMON Operation not permitted

重启后再次测试，有一次出现：

```text
VIDIOC_STREAMON failed: Operation not permitted
```

并且 dmesg 只有：

```text
rkisp0-vir0: check rkisp_mainpath link or isp input
```

这说明：

```text
/dev/video11 能打开；
格式能设置；
buffer 能申请；
mmap 能成功；
但是 STREAMON 阶段，RKISP 发现 mainpath 没有有效输入；
因此内核直接拒绝启动视频流。
```

这同样不是应用层权限问题，因为使用 `sudo` 运行仍然失败。

---

### 7.5 media graph 与 rkaiq 排查

查看 media graph 时发现：

```text
rkisp_mainpath -> /dev/video11
rkisp_selfpath -> /dev/video12
rkisp_fbcpath  -> /dev/video13
rkisp-statistics -> /dev/video18
rkisp-input-params -> /dev/video19
```

并且：

```text
rkisp-isp-subdev -> rkisp_mainpath [ENABLED]
```

说明 `/dev/video11` 节点本身存在，并且 link 是 enabled。

但是 `rkisp-isp-subdev` 的输入仍显示类似默认状态：

```text
SBGGR10_1X10/800x600
```

这和 IMX415 实际模式：

```text
3864x2192 RAW10
```

不匹配，说明 ISP 输入链路没有正确准备好。

继续查看 rkaiq 服务：

```bash
systemctl list-units --type=service --all | grep -Ei "rkaiq|aiq|isp|rkipc|camera"
```

发现：

```text
rkaiq_3A.service loaded inactive dead Enable Rockchip camera engine rkaiq
```

尝试启动：

```bash
sudo systemctl start rkaiq_3A.service
sudo systemctl status rkaiq_3A.service --no-pager -l
```

状态仍为 inactive，并且出现：

```text
ERR: Bad media topology for: /dev/media7
ERR: Bad media topology for: /dev/media8
...
rkaiq_3A_server: 未找到进程
```

手动运行：

```bash
sudo /usr/bin/rkaiq_3A_server
```

出现段错误：

```text
段错误
```

日志显示：

```text
media get entity by name: rkisp-isp-subdev is null
media get entity by name: rkisp-input-params is null
media get entity by name: rkisp-statistics is null
media get entity by name: rkisp_mainpath is null
Cound not find rkisp dev names, skipped /dev/media0
ERR: Bad media topology for: /dev/media0
DBG: get rkisp-isp-subdev devname: /dev/v4l-subdev2
DBG: get rkisp-input-params devname: /dev/video19
DBG: get rkisp-statistics devname: /dev/video18
DBG: get rkisp_mainpath devname: /dev/video11
ERR: Bad media topology for: /dev/media2
...
```

说明：

```text
1. 系统存在 rkaiq_3A_server；
2. 系统也存在 IMX415 对应 IQ 文件；
3. 但是当前 rkaiq_3A_server 会段错误退出；
4. 不能依赖手动启动 rkaiq_3A_server 来恢复链路。
```

相关文件存在：

```text
/usr/bin/rkaiq_3A_server
/etc/iqfiles/imx415_CMK-OT2022-PX1_IR0147-50IRC-8M-F20.json
```

---

### 7.6 最终恢复方式：断电重启

经过排查后，普通重启没有完全恢复摄像头链路。最终通过断电重启恢复。

断电重启后，重新运行：

```bash
cd ~/projects/rk3588_ai_stream

sudo ./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  30 \
  output/exp09_2_camera_check/test_after_power_cycle.nv12
```

输出：

```text
video dev  : /dev/video11
width      : 1280
height     : 720
frames     : 30
out nv12   : output/exp09_2_camera_check/test_after_power_cycle.nv12
frame size : 1382400
driver     : rkisp_v6
card       : rkisp_mainpath
actual fmt : 1280x720 fourcc=NV12 planes=1 sizeimage=1382400 bytesperline=1280
request buffers count: 4
mmap buffer=0 length=1382400 offset=0
mmap buffer=1 length=1382400 offset=1384448
mmap buffer=2 length=1382400 offset=2768896
mmap buffer=3 length=1382400 offset=4153344
frame=0 index=0 bytesused=1382400 select=114.431 dqbuf=0.015 write=8.376 qbuf=0.087

========== 08-1 dump nv12 result ==========
frames          : 30
wall_time_ms    : 1088.968
wall_fps        : 27.549
avg_select_ms   : 29.276
avg_dqbuf_ms    : 0.019
avg_write_ms    : 6.870
avg_qbuf_ms     : 0.108
saved nv12      : output/exp09_2_camera_check/test_after_power_cycle.nv12
==========================================
```

说明：

```text
1. /dev/video11 恢复出帧；
2. V4L2 mmap 采集恢复；
3. 30 帧 NV12 可以正常保存；
4. 摄像头链路恢复后，09-2 可以继续执行；
5. 此类 IMX415 / RKISP 异常可能需要断电重启才能恢复。
```

---

## 8. 09-2 成功后的完整链路意义

09-2 成功后，当前系统已经具备：

```text
1. 摄像头实时输入；
2. V4L2 mmap 低开销采集；
3. RGA 硬件图像格式转换；
4. RKNN NPU 推理；
5. YOLO11 后处理与画框；
6. RGA 转回编码所需 NV12；
7. MPP H.264 硬件编码；
8. FFmpeg HLS 切片；
9. HTTP Server 网络访问；
10. VLC 客户端实时播放。
```

这说明当前项目已经不再只是“模型部署 Demo”，而是具备完整的视频系统链路：

```text
采集 → 推理 → 编码 → 网络预览
```

---

## 9. 关键经验总结

### 9.1 HLS 播放失败不一定是 HLS 的问题

本次一开始表现为 VLC 无法播放，但是根因并不是 HLS，而是第一帧摄像头数据没有出来。

排查顺序应该是：

```text
VLC 播放失败
        ↓
检查 HLS 文件是否为空
        ↓
检查 FFmpeg 是否收到 H.264
        ↓
检查 MPP 是否收到 NV12
        ↓
检查检测程序是否写 FIFO
        ↓
检查 V4L2 是否采集到第一帧
        ↓
检查 RKISP / sensor 是否正常出流
```

---

### 9.2 最小链路优先

完整链路失败时，不应该一开始就看所有模块，而应该回到最小链路：

```bash
sudo ./build/v4l2_dump_nv12 /dev/video11 1280 720 30 xxx.nv12
```

只要这个最小采集不成功，后面的 RKNN、MPP、HLS 都没有意义。

---

### 9.3 IMX415 / RKISP 异常可能需要断电重启

本次出现过：

```text
m00_b_imx415 1-001a: start stream failed while write regs
rkisp0-vir0: check rkisp_mainpath link or isp input
VIDIOC_STREAMON failed: Operation not permitted
select timeout at frame=0
```

这类问题说明 sensor / ISP / MIPI pipeline 处于异常状态。

最终通过断电重启恢复，说明：

```text
普通 Linux reboot 不一定能完全复位 MIPI 摄像头模组；
断电重启可以重新初始化 sensor 电源域和 MIPI 链路；
后续实验如果再次出现 frame=0 timeout，应优先做最小采集验证，再考虑断电恢复。
```

---

### 9.4 rkaiq_3A_server 当前不稳定

当前系统中虽然存在：

```text
/usr/bin/rkaiq_3A_server
/etc/iqfiles/imx415_CMK-OT2022-PX1_IR0147-50IRC-8M-F20.json
```

但是手动运行会段错误，`rkaiq_3A.service` 也不会常驻。

因此当前实验阶段：

```text
不主动依赖手动启动 rkaiq_3A_server；
以实际 V4L2 / RKISP 出帧状态为准；
如果 /dev/video11 能正常出 NV12，则继续实验；
如果不能出帧，则先排查 sensor / RKISP。
```

---

## 10. 当前项目能力阶段

完成 09 后，当前项目已经具备：

```text
1. RK3588 摄像头 V4L2 mmap 原生采集；
2. RGA NV12 / RGB888 双向转换；
3. RKNN YOLO11 NPU 推理；
4. 检测框绘制；
5. MPP H.264 硬件编码；
6. MP4 检测录像保存；
7. HLS 实时网络预览；
8. VLC 客户端播放检测画面；
9. 摄像头链路异常定位与恢复经验。
```

当前系统已经从：

```text
板端 YOLO11 推理 Demo
```

升级为：

```text
基于 RK3588 的端侧 AI 视频检测、硬件编码与网络预览系统
```

---

## 11. 和前面实验的关系

当前 09 与前面实验的关系如下：

```text
00：
    验证鲁班猫官方 YOLO11 RKNN Demo 可运行。

01：
    单图检测迁移到自己的工程。

02：
    视频文件检测迁移。

03：
    OpenCV 摄像头检测，证明摄像头检测链路可以跑通。

04：
    性能剖析，发现 OpenCV VideoCapture 是输入瓶颈。

05：
    改用 V4L2 mmap + RGA，输入预处理链路接近 30FPS。

06：
    接入 RKNN YOLO11，形成 V4L2 + RGA + RKNN 实时检测链路。

07：
    拆解 inference_yolo11_model 内部耗时，并通过 Release / O3 / performance 等优化接近 30FPS。

08：
    接入 MPP H.264 硬件编码，实现检测录像保存。

09：
    在 08 基础上接入 FFmpeg HLS，实现 VLC 网络实时预览。
```

最终形成：

```text
V4L2
    ↓
RGA
    ↓
RKNN
    ↓
RGA
    ↓
MPP
    ↓
FFmpeg HLS
    ↓
VLC
```

---

## 12. 后续方向

完成 09 后，后续可以继续做：

```text
10_rtsp_stream_preview：
    部署 mediamtx 或 rtsp-simple-server，实现 RTSP 实时预览。

11_low_latency_stream：
    优化 HLS 延迟，尝试 HTTP-FLV / RTSP / WebRTC。

12_pipeline_refactor：
    将采集、推理、编码、推流拆成多线程流水线。

13_model_replace：
    将 COCO YOLO11 替换为自训练孔探缺陷检测模型。

14_edge_file_manager：
    增加远程文件管理模块，用于下载录像、日志、检测结果。

15_qt_client_preview：
    将网络预览接入 Qt 上位机，实现界面化显示和控制。
```

---

## 13. 实验结论

09 实验最终结论：

```text
1. 当前板端没有现成 RTSP Server，因此本实验优先选择 HLS；
2. ffmpeg / ffprobe / ffplay 环境完整；
3. 08 生成的检测 MP4 可以通过 HLS 被 VLC 播放；
4. 实时检测输出可以通过 FIFO 接入 MPP 编码器；
5. MPP 编码后的 H.264 可以通过 FIFO 接入 FFmpeg；
6. FFmpeg 可以生成 HLS 切片；
7. Python HTTP Server 可以提供 HLS 文件访问；
8. 电脑端 VLC 可以播放实时摄像头检测画面；
9. 初次失败的根因不是 HLS，而是 IMX415 / RKISP 摄像头链路异常；
10. 断电重启后，/dev/video11 恢复出帧，09-2 最终成功。
```

因此，当前项目已经完成：

```text
RK3588 端侧 AI 摄像头实时检测
        +
MPP H.264 硬件编码
        +
HLS 网络实时预览
```

这已经是一个比较完整的嵌入式 AI 视频系统原型。
EOF_MD

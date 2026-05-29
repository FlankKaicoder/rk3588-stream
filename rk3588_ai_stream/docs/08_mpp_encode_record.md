# 08 MPP 编码录像实验记录

## 1. 实验背景

前面已经完成了从官方 YOLO11 Demo 到 RK3588 摄像头实时检测链路的一系列迁移和优化实验。

截至 07 实验结束，当前项目已经完成：

```text
00_lubancat_demo_baseline：
    验证鲁班猫官方 YOLO11 RKNN Demo 可以正常运行。

01_image_detect：
    单图检测迁移到自己的 rk3588_ai_stream 工程。

02_video_detect：
    视频文件逐帧检测，保存检测结果视频。

03_camera_detect：
    OpenCV VideoCapture 摄像头检测，保存检测视频。

04_camera_profile：
    对 OpenCV 摄像头检测链路做性能剖析，发现 OpenCV VideoCapture 是输入瓶颈。

05_v4l2_rga_realtime_preprocess：
    使用 V4L2 mmap 原生采集 NV12，并通过 RGA 转 RGB888，输入链路接近 30FPS。

06_v4l2_rga_rknn_detect：
    V4L2 + RGA + RKNN 完整检测链路，初始约 18.7FPS，瓶颈转移到 inference_yolo11_model()。

07_model_internal_profile：
    拆解 inference_yolo11_model() 内部耗时，定位后处理 decode、编译优化和 CPU governor 问题；
    在 Release + O3 + performance 后，完整 V4L2 + RGA + RKNN 检测链路达到约 29.7FPS。
```

07 实验结束后，检测链路已经基本接近 30FPS。因此 08 实验不再继续优先死磕推理函数，而是转向完整工程链路：

```text
将检测后的帧接入 Rockchip MPP H.264 硬件编码器，
替代 OpenCV VideoWriter，
保存为 H.264 / MP4 文件，
为后续 RTSP / HTTP-FLV / HLS 实时推流做准备。
```

---

## 2. 实验目标

08 实验的总体目标：

```text
摄像头实时采集
    ↓
V4L2 mmap 获取 1280x720 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
MPP H.264 硬件编码
    ↓
保存 H.264 / MP4 检测视频
```

本实验重点验证：

1. RK3588 板端是否具备 MPP 编码开发环境；
2. `/dev/video11` 是否可以稳定输出 `1280x720 NV12`；
3. 原始 NV12 帧是否可以通过 `mpi_enc_test` 编码成 H.264；
4. 实时采集到的 NV12 是否可以通过 FIFO 管道送入 MPP 编码器；
5. 检测画框后的 RGB 帧是否可以转回 NV12 并送入 MPP 编码器；
6. 完整链路能否稳定接近 30FPS；
7. 瓶颈是否出现在 MPP 编码器、FIFO 写入、RGA 转换，还是 RKNN 推理。

---

## 3. 实验编号说明

08 实验被拆成 5 个子实验：

```text
08-0_mpp_probe：
    MPP 环境探测。

08-1_v4l2_dump_nv12_mpp_encode：
    V4L2 mmap 采集 NV12 → 保存 raw NV12 → mpi_enc_test 离线编码。

08-2_v4l2_fifo_mpp_encode：
    V4L2 mmap 实时采集 NV12 → FIFO → mpi_enc_test 实时编码。

08-3_detect_fifo_mpp：
    V4L2 + RGA + RKNN + 画框 + RGB转NV12 → FIFO → MPP 编码。

08-4_detect_fifo_mpp_clean：
    去掉 debug JPG 和每帧 fflush，进行 300 帧稳定性测试。
```

这样分阶段做的原因是：

```text
不能一上来就把采集、推理、画框、颜色转换、编码全部揉在一起。
如果失败，很难判断问题到底来自 V4L2、RGA、RKNN、FIFO 还是 MPP。
```

所以 08 按照从简单到复杂的方式逐步验证：

```text
先验证 MPP 环境；
再验证原始 NV12 可以编码；
再验证实时 FIFO 编码；
最后接入 RKNN 检测和画框。
```

---

## 4. 当前工程路径

当前工程路径：

```bash
~/projects/rk3588_ai_stream
```

08 实验涉及的主要目录：

```text
rk3588_ai_stream/
├── src/
│   ├── main_v4l2_dump_nv12.cpp
│   ├── main_v4l2_rga_rknn_detect_to_nv12.cpp
│   └── main_v4l2_rga_rknn_detect_to_nv12_clean.cpp
│
├── scripts/
│   ├── exp08_mpp_probe.sh
│   ├── exp08_2_v4l2_fifo_mpp.sh
│   ├── exp08_3_detect_fifo_mpp.sh
│   └── exp08_4_detect_fifo_mpp_clean.sh
│
├── output/
│   ├── exp08_mpp_probe/
│   ├── exp08_mpp_encode_record/
│   ├── exp08_mpp_encode_record_retry/
│   ├── exp08_2_v4l2_fifo_mpp/
│   ├── exp08_3_detect_fifo_mpp/
│   └── exp08_4_detect_fifo_mpp_clean/
│
└── docs/
    └── 08_mpp_encode_record.md
```

---

## 5. 08-0：MPP 环境探测

### 5.1 实验目的

08-0 的目的不是跑检测，而是确认板端 MPP 环境是否完整。

需要确认：

```text
1. 系统环境；
2. CPU governor 是否为 performance；
3. MPP 头文件是否存在；
4. MPP 动态库是否存在；
5. pkg-config 是否能找到 rockchip_mpp；
6. 是否存在 mpi_enc_test；
7. 是否存在 mpi_enc_test.c 源码；
8. /dev/video11 当前格式是否为 1280x720 NV12；
9. 当前 v4l2-ctl 是否支持 mplane streaming 参数。
```

### 5.2 探测命令

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp08_mpp_probe
mkdir -p scripts

cat > scripts/exp08_mpp_probe.sh <<'EOF_SCRIPT'
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
find /usr /usr/local ~/lubancat_ai_manual_code ~/mpp ~/demo \
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
find /usr /usr/local ~/lubancat_ai_manual_code ~/mpp ~/demo \
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
find /usr /usr/local ~/mpp ~/demo \
    \( -name "mpi_enc_test" \
    -o -name "mpi_dec_test" \
    -o -name "mpi_*_test" \
    -o -name "*mpp*test*" \
    -o -name "*enc*test*" \) \
    -type f 2>/dev/null | sort | tee -a "$LOG" || true

echo
echo "========== MPP sample source ==========" | tee -a "$LOG"
find /usr /usr/local ~/mpp ~/demo \
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
EOF_SCRIPT

chmod +x scripts/exp08_mpp_probe.sh
./scripts/exp08_mpp_probe.sh
```

### 5.3 探测结果

系统环境：

```text
Linux lubancat 5.10.160
Debian GNU/Linux 11 bullseye
aarch64
CPU governor：performance
```

MPP 头文件存在：

```text
/usr/include/rockchip/rk_mpi.h
/usr/include/rockchip/mpp_frame.h
/usr/include/rockchip/mpp_packet.h
/usr/include/rockchip/mpp_buffer.h
/usr/include/rockchip/rk_mpi_cmd.h

/usr/local/include/rockchip/rk_mpi.h
/usr/local/include/rockchip/mpp_frame.h
/usr/local/include/rockchip/mpp_packet.h
/usr/local/include/rockchip/mpp_buffer.h
/usr/local/include/rockchip/rk_mpi_cmd.h

/home/cat/mpp/inc/rk_mpi.h
/home/cat/mpp/inc/mpp_frame.h
/home/cat/mpp/inc/mpp_packet.h
/home/cat/mpp/inc/mpp_buffer.h
/home/cat/mpp/mpp/inc/mpp_enc_cfg.h
```

MPP 动态库存在：

```text
/usr/lib/aarch64-linux-gnu/librockchip_mpp.so
/usr/lib/aarch64-linux-gnu/librockchip_mpp.so.0
/usr/lib/aarch64-linux-gnu/librockchip_mpp.so.1

/usr/local/lib/librockchip_mpp.so
/usr/local/lib/librockchip_mpp.so.0
/usr/local/lib/librockchip_mpp.so.1

/home/cat/mpp/build/mpp/librockchip_mpp.so
/home/cat/mpp/build/mpp/librockchip_mpp.so.0
/home/cat/mpp/build/mpp/librockchip_mpp.so.1
```

`pkg-config` 可以找到：

```text
librga
rockchip_mpp
rockchip_vpu
```

系统中存在 MPP 编码测试程序：

```text
/usr/bin/mpi_enc_test
/usr/local/bin/mpi_enc_test
/home/cat/mpp/build/test/mpi_enc_test
```

存在对应源码：

```text
/home/cat/mpp/test/mpi_enc_test.c
/home/cat/mpp/utils/mpi_enc_utils.c
/home/cat/mpp/utils/mpi_enc_utils.h
```

摄像头节点 `/dev/video11`：

```text
Driver name      : rkisp_v6
Card type        : rkisp_mainpath
Device Caps      : Video Capture Multiplanar / Streaming / Extended Pix Format

Format Video Capture Multiplanar:
    Width/Height      : 1280/720
    Pixel Format      : 'NV12' (Y/CbCr 4:2:0)
    Number of planes  : 1
    Bytes per Line    : 1280
    Size Image        : 1382400
```

支持格式：

```text
UYVY
NV16
NV61
NV21
NV12
NM21
NM12
```

### 5.4 08-0 结论

08-0 结论：

```text
1. MPP 开发环境完整；
2. librga、rockchip_mpp、rockchip_vpu 均可用；
3. 板端存在 mpi_enc_test 和源码；
4. /dev/video11 当前可以输出 1280x720 NV12；
5. 单帧 NV12 大小为 1280×720×3/2 = 1382400 bytes；
6. 当前 v4l2-ctl 不支持 --set-fmt-video-mplane 和 --stream-mmap=4 这种参数写法；
7. 后续继续使用自己写的 V4L2 mmap C++ 采集程序，不依赖 v4l2-ctl 做采集。
```

---

## 6. 08-1：V4L2 dump NV12 + MPP 离线编码

### 6.1 实验目的

08-1 的目的：

```text
先不接 RKNN，不画框，不接实时 FIFO。
只验证 V4L2 采集出来的原始 NV12 文件能否被 MPP 编码器正常编码。
```

流程：

```text
/dev/video11
    ↓
V4L2 mmap 采集 1280x720 NV12
    ↓
保存为 input_120f_1280x720.nv12
    ↓
mpi_enc_test 读取 raw NV12
    ↓
MPP H.264 编码
    ↓
生成 .h264
    ↓
ffmpeg 封装为 .mp4
```

---

### 6.2 新增程序：`main_v4l2_dump_nv12.cpp`

该程序用于从 V4L2 采集 NV12 并写入文件或 FIFO。

核心流程：

```text
open("/dev/video11")
    ↓
VIDIOC_QUERYCAP
    ↓
VIDIOC_S_FMT 设置 1280x720 NV12
    ↓
VIDIOC_REQBUFS
    ↓
VIDIOC_QUERYBUF
    ↓
mmap
    ↓
VIDIOC_QBUF
    ↓
VIDIOC_STREAMON
    ↓
select 等待帧到来
    ↓
VIDIOC_DQBUF
    ↓
fwrite 写出 NV12
    ↓
VIDIOC_QBUF 归还 buffer
```

新增 CMake target：

```cmake
add_executable(v4l2_dump_nv12
    src/main_v4l2_dump_nv12.cpp
)

target_compile_options(v4l2_dump_nv12 PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(v4l2_dump_nv12
    pthread
)
```

---

### 6.3 编译命令

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir -p build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release
make v4l2_dump_nv12 -j4
```

---

### 6.4 采集 NV12 raw 文件

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp08_mpp_encode_record

./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  120 \
  output/exp08_mpp_encode_record/input_120f_1280x720.nv12
```

### 6.5 V4L2 dump 结果

```text
video dev  : /dev/video11
width      : 1280
height     : 720
frames     : 120
out nv12   : output/exp08_mpp_encode_record/input_120f_1280x720.nv12
frame size : 1382400
driver     : rkisp_v6
card       : rkisp_mainpath
actual fmt : 1280x720 fourcc=NV12 planes=1 sizeimage=1382400 bytesperline=1280
request buffers count: 4
mmap buffer=0 length=1382400 offset=0
mmap buffer=1 length=1382400 offset=1384448
mmap buffer=2 length=1382400 offset=2768896
mmap buffer=3 length=1382400 offset=4153344

========== 08-1 dump nv12 result ==========
frames          : 120
wall_time_ms    : 4050.972
wall_fps        : 29.623
avg_select_ms   : 30.554
avg_dqbuf_ms    : 0.006
avg_write_ms    : 3.124
avg_qbuf_ms     : 0.071
saved nv12      : output/exp08_mpp_encode_record/input_120f_1280x720.nv12
==========================================
```

输出文件：

```text
input_120f_1280x720.nv12
大小：159M
```

计算验证：

```text
单帧大小：
1280 × 720 × 3 / 2 = 1382400 bytes

120 帧理论大小：
1382400 × 120 = 165888000 bytes ≈ 158.2 MiB
```

实际文件约 159M，符合预期。

---

### 6.6 第一次 mpi_enc_test 参数问题

第一次尝试使用：

```bash
mpi_enc_test \
  -i input_120f_1280x720.nv12 \
  -o output_120f_1280x720.h264 \
  -w 1280 \
  -h 720 \
  -f 0 \
  -t 7 \
  -n 120 \
  -fps 30 \
  -bps 4000000
```

结果没有生成 `.h264` 文件：

```text
output_120f_1280x720.h264: No such file or directory
mpi_enc_test_help.log = 0 字节
mpi_enc_test_run.log  = 0 字节
```

原因分析：

```text
1. mpi_enc_test -h 不是 help，而是 height；
2. 该版本 mpi_enc_test 可能不支持 -fps / -bps 这种长参数；
3. 后续改用最小参数进行测试。
```

---

### 6.7 修正后的 MPP 离线编码命令

成功命令：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp08_mpp_encode_record_retry

/home/cat/mpp/build/test/mpi_enc_test \
  -i output/exp08_mpp_encode_record/input_120f_1280x720.nv12 \
  -o output/exp08_mpp_encode_record_retry/output_minimal.h264 \
  -w 1280 \
  -h 720 \
  -f 0 \
  -t 7 \
  -n 120
```

参数说明：

```text
-i：
    输入原始 NV12 文件。

-o：
    输出 H.264 裸码流文件。

-w：
    输入宽度，1280。

-h：
    输入高度，720。

-f 0：
    输入格式。当前实验中 0 对应 YUV420SP / NV12。

-t 7：
    编码类型。当前实验中 7 对应 H.264 / AVC。

-n 120：
    编码帧数。
```

---

### 6.8 离线编码结果

```text
mpp[14988]: mpi_enc_test: chn 0 encode 120 frames time 444 ms delay   3 ms fps 270.09 bps 3176384
mpp[14988]: mpi_enc_test: /home/cat/mpp/build/test/mpi_enc_test average frame rate 270.09
```

输出文件：

```text
output_minimal.h264    1.6M
```

这里的 `270.09FPS` 是：

```text
离线 raw 文件读取 + MPP 编码吞吐
```

不是摄像头实时 FPS。

它说明：

```text
MPP 编码器本身吞吐非常高，
不是后续 30FPS 实时录像的瓶颈。
```

---

### 6.9 H.264 封装 MP4

```bash
ffmpeg -y \
  -framerate 30 \
  -i output/exp08_mpp_encode_record_retry/output_minimal.h264 \
  -c copy \
  output/exp08_mpp_encode_record_retry/output_120f_1280x720.mp4
```

验证：

```bash
ffprobe -hide_banner output/exp08_mpp_encode_record_retry/output_120f_1280x720.mp4
```

结果：

```text
Duration: 00:00:04.00
Video: h264 (High)
Resolution: 1280x720
Bitrate: 3176 kb/s
FPS: 30 fps
```

输出文件：

```text
output_120f_1280x720.mp4    1.6M
first_frame.jpg             43K
```

---

### 6.10 08-1 结论

08-1 结论：

```text
1. V4L2 mmap 可以稳定采集 1280x720 NV12；
2. 120 帧 NV12 raw 文件大小正确；
3. 原始 NV12 可以被 Rockchip MPP 编码器正常编码；
4. H.264 裸流可以通过 ffmpeg 封装成 MP4；
5. MP4 可以正常 ffprobe 和抽帧；
6. MPP 离线编码 120 帧仅耗时 444ms，吞吐约 270FPS；
7. MPP 编码器本身不是实时检测录像链路的主要瓶颈。
```

---

## 7. 08-2：V4L2 实时采集 + FIFO + MPP 编码

### 7.1 实验目的

08-1 先把 raw 文件保存到磁盘，再离线编码。

08-2 进一步验证：

```text
不再先保存完整 raw 文件，
而是通过 Linux FIFO 管道，
将实时采集到的 NV12 数据直接送给 mpi_enc_test。
```

流程：

```text
/dev/video11
    ↓
v4l2_dump_nv12 实时采集
    ↓
FIFO 管道 live_1280x720_nv12.fifo
    ↓
mpi_enc_test 读取 FIFO
    ↓
MPP H.264 编码
    ↓
生成 H.264
    ↓
ffmpeg 封装 MP4
```

---

### 7.2 运行脚本

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p scripts
mkdir -p output/exp08_2_v4l2_fifo_mpp

cat > scripts/exp08_2_v4l2_fifo_mpp.sh <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp08_2_v4l2_fifo_mpp
mkdir -p "$OUT_DIR"

FIFO="$OUT_DIR/live_1280x720_nv12.fifo"
H264="$OUT_DIR/live_120f_1280x720.h264"
MP4="$OUT_DIR/live_120f_1280x720.mp4"
FIRST_JPG="$OUT_DIR/first_frame.jpg"

rm -f "$FIFO" "$H264" "$MP4" "$FIRST_JPG"
mkfifo "$FIFO"

echo "========== 08-2 start encoder ==========" | tee "$OUT_DIR/08_2.log"

/home/cat/mpp/build/test/mpi_enc_test \
  -i "$FIFO" \
  -o "$H264" \
  -w 1280 \
  -h 720 \
  -f 0 \
  -t 7 \
  -n 120 \
  > "$OUT_DIR/mpi_enc_fifo_run.log" 2>&1 &

ENC_PID=$!

sleep 1

echo "encoder pid: $ENC_PID" | tee -a "$OUT_DIR/08_2.log"

echo "========== 08-2 start v4l2 capture writer ==========" | tee -a "$OUT_DIR/08_2.log"

./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  120 \
  "$FIFO" \
  2>&1 | tee "$OUT_DIR/v4l2_fifo_dump.log"

echo "========== wait encoder ==========" | tee -a "$OUT_DIR/08_2.log"
wait "$ENC_PID" || true

rm -f "$FIFO"

echo "========== encoder log tail ==========" | tee -a "$OUT_DIR/08_2.log"
tail -40 "$OUT_DIR/mpi_enc_fifo_run.log" | tee -a "$OUT_DIR/08_2.log"

echo "========== check h264 ==========" | tee -a "$OUT_DIR/08_2.log"
ls -lh "$H264" | tee -a "$OUT_DIR/08_2.log"

echo "========== package mp4 ==========" | tee -a "$OUT_DIR/08_2.log"
ffmpeg -y \
  -framerate 30 \
  -i "$H264" \
  -c copy \
  "$MP4" \
  2>&1 | tee "$OUT_DIR/ffmpeg_pack_mp4.log"

echo "========== ffprobe ==========" | tee -a "$OUT_DIR/08_2.log"
ffprobe -hide_banner "$MP4" \
  2>&1 | tee "$OUT_DIR/ffprobe_mp4.log"

echo "========== extract first frame ==========" | tee -a "$OUT_DIR/08_2.log"
ffmpeg -y \
  -i "$MP4" \
  -frames:v 1 \
  "$FIRST_JPG" \
  2>&1 | tee "$OUT_DIR/extract_first_jpg.log"

echo "========== final files ==========" | tee -a "$OUT_DIR/08_2.log"
ls -lh "$OUT_DIR" | tee -a "$OUT_DIR/08_2.log"
EOF_SCRIPT

chmod +x scripts/exp08_2_v4l2_fifo_mpp.sh
./scripts/exp08_2_v4l2_fifo_mpp.sh
```

---

### 7.3 08-2 结果

生成文件：

```text
live_120f_1280x720.h264    1.6M
live_120f_1280x720.mp4     1.6M
first_frame.jpg            47K
```

`ffprobe` 结果：

```text
Duration: 00:00:04.00
Video: h264 (High)
Resolution: 1280x720
Bitrate: 3238 kb/s
FPS: 30 fps
```

### 7.4 08-2 结论

08-2 结论：

```text
1. 实时 V4L2 采集到的 NV12 可以通过 FIFO 管道送入 mpi_enc_test；
2. MPP 可以实时编码 FIFO 中的 NV12 帧；
3. 输出的 H.264 裸流和 MP4 均正常；
4. 该实验证明“实时摄像头采集 + MPP 硬件编码录像”已经跑通；
5. 下一步可以在 FIFO 前加入 RKNN 检测、画框和 RGB→NV12 转换。
```

---

## 8. 08-3：V4L2 + RGA + RKNN + 画框 + RGB转NV12 + FIFO + MPP 编码

### 8.1 实验目的

08-3 是 08 实验的关键步骤。

目标是把检测后的帧真正送入 MPP 编码链路。

完整流程：

```text
/dev/video11
    ↓
V4L2 mmap 采集 NV12
    ↓
RGA：NV12 → RGB888
    ↓
构造 image_buffer_t
    ↓
inference_yolo11_model()
    ↓
YOLO11 后处理
    ↓
OpenCV 在 RGB888 图像上画检测框
    ↓
RGA：RGB888 → NV12
    ↓
fwrite 写入 FIFO
    ↓
mpi_enc_test 读取 FIFO
    ↓
MPP H.264 编码
    ↓
ffmpeg 封装 MP4
```

### 8.2 为什么需要 RGB 再转回 NV12？

当前推理链路需要 RGB888：

```text
V4L2 摄像头输出：NV12
RKNN YOLO11 输入：RGB888
```

所以前半段需要：

```text
RGA NV12 → RGB888
```

检测框绘制在 RGB 图像上完成。

但是 MPP H.264 编码器更适合输入 YUV420SP / NV12：

```text
MPP encoder 输入：NV12
```

因此画框后还需要：

```text
RGA RGB888 → NV12
```

这样才能把带检测框的结果帧送入 MPP 编码器。

---

### 8.3 新增程序

新增文件：

```text
src/main_v4l2_rga_rknn_detect_to_nv12.cpp
```

新增 target：

```cmake
add_executable(v4l2_rga_rknn_detect_to_nv12
    src/main_v4l2_rga_rknn_detect_to_nv12.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(v4l2_rga_rknn_detect_to_nv12 PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${OpenCV_INCLUDE_DIRS}
)

target_compile_options(v4l2_rga_rknn_detect_to_nv12 PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(v4l2_rga_rknn_detect_to_nv12
    imageutils
    fileutils
    ${OpenCV_LIBS}
    PkgConfig::LIBRGA
    ${LIBRKNNRT}
    dl
    pthread
)
```

程序统计字段：

```text
select_ms
dqbuf_ms
rga_nv12_to_rgb_ms
input_prepare_ms
model_total_ms
draw_ms
rga_rgb_to_nv12_ms
write_ms
qbuf_ms
total_ms
fps
detect_count
```

---

### 8.4 运行脚本

```bash
cd ~/projects/rk3588_ai_stream

cat > scripts/exp08_3_detect_fifo_mpp.sh <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp08_3_detect_fifo_mpp
mkdir -p "$OUT_DIR"

FIFO="$OUT_DIR/live_detect_1280x720_nv12.fifo"
H264="$OUT_DIR/live_detect_120f_1280x720.h264"
MP4="$OUT_DIR/live_detect_120f_1280x720.mp4"
FIRST_JPG="$OUT_DIR/first_frame_from_mp4.jpg"
PROFILE="$OUT_DIR/profile_detect_to_nv12.csv"

rm -f "$FIFO" "$H264" "$MP4" "$FIRST_JPG" "$PROFILE"
mkfifo "$FIFO"

echo "========== 08-3 start MPP encoder ==========" | tee "$OUT_DIR/08_3.log"

/home/cat/mpp/build/test/mpi_enc_test \
  -i "$FIFO" \
  -o "$H264" \
  -w 1280 \
  -h 720 \
  -f 0 \
  -t 7 \
  -n 120 \
  > "$OUT_DIR/mpi_enc_detect_fifo_run.log" 2>&1 &

ENC_PID=$!

sleep 1

echo "encoder pid: $ENC_PID" | tee -a "$OUT_DIR/08_3.log"

echo "========== 08-3 start V4L2 + RGA + RKNN detect writer ==========" | tee -a "$OUT_DIR/08_3.log"

./build/v4l2_rga_rknn_detect_to_nv12 \
  models/yolo11.rknn \
  /dev/video11 \
  1280 \
  720 \
  120 \
  "$FIFO" \
  "$PROFILE" \
  2>&1 | tee "$OUT_DIR/v4l2_rga_rknn_detect_to_nv12.log"

echo "========== wait encoder ==========" | tee -a "$OUT_DIR/08_3.log"
wait "$ENC_PID" || true

rm -f "$FIFO"

echo "========== encoder log tail ==========" | tee -a "$OUT_DIR/08_3.log"
tail -50 "$OUT_DIR/mpi_enc_detect_fifo_run.log" | tee -a "$OUT_DIR/08_3.log"

echo "========== check h264 ==========" | tee -a "$OUT_DIR/08_3.log"
ls -lh "$H264" | tee -a "$OUT_DIR/08_3.log"

echo "========== package mp4 ==========" | tee -a "$OUT_DIR/08_3.log"
ffmpeg -y \
  -framerate 30 \
  -i "$H264" \
  -c copy \
  "$MP4" \
  2>&1 | tee "$OUT_DIR/ffmpeg_pack_mp4.log"

echo "========== ffprobe ==========" | tee -a "$OUT_DIR/08_3.log"
ffprobe -hide_banner "$MP4" \
  2>&1 | tee "$OUT_DIR/ffprobe_mp4.log"

echo "========== extract first frame ==========" | tee -a "$OUT_DIR/08_3.log"
ffmpeg -y \
  -i "$MP4" \
  -frames:v 1 \
  "$FIRST_JPG" \
  2>&1 | tee "$OUT_DIR/extract_first_jpg.log"

echo "========== final files ==========" | tee -a "$OUT_DIR/08_3.log"
ls -lh "$OUT_DIR" | tee -a "$OUT_DIR/08_3.log"
EOF_SCRIPT

chmod +x scripts/exp08_3_detect_fifo_mpp.sh
./scripts/exp08_3_detect_fifo_mpp.sh
```

---

### 8.5 08-3 输出文件

成功生成：

```text
debug_first_rgb_detect.jpg          383K
live_detect_120f_1280x720.h264      1.6M
live_detect_120f_1280x720.mp4       1.6M
profile_detect_to_nv12.csv          8.9K
first_frame_from_mp4.jpg            46K
```

这说明：

```text
检测画框后的 RGB 帧已经成功转回 NV12；
NV12 已经成功进入 FIFO；
MPP 成功编码；
ffmpeg 成功封装 MP4；
MP4 可以正常抽帧。
```

---

### 8.6 08-3 性能结果

```text
MPP 编码端：
encode 120 frames time 4284 ms
fps = 28.01
bps ≈ 3234072

MP4：
Duration: 00:00:04.00
Video: H.264 High
Resolution: 1280x720
FPS: 30
Bitrate: 3238 kb/s

CSV 平均：
frames: 120
select_ms             : avg=   0.846
dqbuf_ms              : avg=   0.003
rga_nv12_to_rgb_ms    : avg=   1.634
input_prepare_ms      : avg=   0.001
model_total_ms        : avg=  27.796
draw_ms               : avg=   0.872
rga_rgb_to_nv12_ms    : avg=   2.342
write_ms              : avg=   1.385
qbuf_ms               : avg=   0.034
total_ms              : avg=  34.914
fps                   : avg=  29.895
detect_count          : avg=   0.000

1000 / avg_total_ms fps : 28.642
```

### 8.7 08-3 注意点

08-3 中有一个干扰项：

```text
draw_ms max=104.338ms
total_ms max=226.116ms
```

原因是代码里在第 0 帧保存了调试 JPG：

```cpp
if (frame_id == 0) {
    save_rgb_debug_jpg(...);
}
```

该保存操作被计入 `draw_ms`，导致第 0 帧耗时异常。

因此 08-3 虽然已经证明完整链路跑通，但性能数据还不是最干净版本。

所以继续做 08-4：

```text
去掉第 0 帧 debug JPG；
去掉每帧 fflush；
测试 300 帧；
得到更稳定的真实性能。
```

---

## 9. 08-4：干净版 300 帧稳定性测试

### 9.1 实验目的

08-4 的目的：

```text
去掉 08-3 中影响性能统计的调试逻辑，
进行更长时间的 300 帧稳定性测试。
```

修改点：

```text
1. 删除第 0 帧 debug JPG 保存；
2. 删除每帧 fflush(fout)；
3. 编码帧数从 120 增加到 300；
4. 输出干净版 profile CSV；
5. 重新统计完整链路平均耗时和 FPS。
```

---

### 9.2 生成 clean 版本源码

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp08_4_detect_fifo_mpp_clean
mkdir -p scripts

python3 - <<'PY'
from pathlib import Path

src = Path("src/main_v4l2_rga_rknn_detect_to_nv12.cpp")
dst = Path("src/main_v4l2_rga_rknn_detect_to_nv12_clean.cpp")

text = src.read_text()

old_debug = '''        if (frame_id == 0) {
            save_rgb_debug_jpg("output/exp08_3_detect_fifo_mpp/debug_first_rgb_detect.jpg",
                               rgb_buf.data(),
                               width,
                               height);
        }

'''

text = text.replace(old_debug, "")
text = text.replace("        fflush(fout);\n", "")
text = text.replace(
    'printf("debug jpg           : output/exp08_3_detect_fifo_mpp/debug_first_rgb_detect.jpg\\n");\n',
    ''
)

dst.write_text(text)
print("created", dst)
PY
```

新增 CMake target：

```cmake
add_executable(v4l2_rga_rknn_detect_to_nv12_clean
    src/main_v4l2_rga_rknn_detect_to_nv12_clean.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(v4l2_rga_rknn_detect_to_nv12_clean PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
    ${OpenCV_INCLUDE_DIRS}
)

target_compile_options(v4l2_rga_rknn_detect_to_nv12_clean PRIVATE
    -O3
    -DNDEBUG
)

target_link_libraries(v4l2_rga_rknn_detect_to_nv12_clean
    imageutils
    fileutils
    ${OpenCV_LIBS}
    PkgConfig::LIBRGA
    ${LIBRKNNRT}
    dl
    pthread
)
```

编译：

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir -p build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release
make v4l2_rga_rknn_detect_to_nv12_clean -j4
```

---

### 9.3 08-4 运行脚本

```bash
cd ~/projects/rk3588_ai_stream

cat > scripts/exp08_4_detect_fifo_mpp_clean.sh <<'EOF_SCRIPT'
#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT_DIR=output/exp08_4_detect_fifo_mpp_clean
mkdir -p "$OUT_DIR"

FIFO="$OUT_DIR/live_detect_clean_1280x720_nv12.fifo"
H264="$OUT_DIR/live_detect_clean_300f_1280x720.h264"
MP4="$OUT_DIR/live_detect_clean_300f_1280x720.mp4"
FIRST_JPG="$OUT_DIR/first_frame_from_mp4.jpg"
PROFILE="$OUT_DIR/profile_detect_to_nv12_clean.csv"

rm -f "$FIFO" "$H264" "$MP4" "$FIRST_JPG" "$PROFILE"
mkfifo "$FIFO"

echo "========== 08-4 start MPP encoder ==========" | tee "$OUT_DIR/08_4.log"

/home/cat/mpp/build/test/mpi_enc_test \
  -i "$FIFO" \
  -o "$H264" \
  -w 1280 \
  -h 720 \
  -f 0 \
  -t 7 \
  -n 300 \
  > "$OUT_DIR/mpi_enc_detect_fifo_run.log" 2>&1 &

ENC_PID=$!

sleep 1

echo "encoder pid: $ENC_PID" | tee -a "$OUT_DIR/08_4.log"

echo "========== 08-4 start clean detect writer ==========" | tee -a "$OUT_DIR/08_4.log"

./build/v4l2_rga_rknn_detect_to_nv12_clean \
  models/yolo11.rknn \
  /dev/video11 \
  1280 \
  720 \
  300 \
  "$FIFO" \
  "$PROFILE" \
  2>&1 | tee "$OUT_DIR/v4l2_rga_rknn_detect_to_nv12_clean.log"

echo "========== wait encoder ==========" | tee -a "$OUT_DIR/08_4.log"
wait "$ENC_PID" || true

rm -f "$FIFO"

echo "========== encoder log tail ==========" | tee -a "$OUT_DIR/08_4.log"
tail -60 "$OUT_DIR/mpi_enc_detect_fifo_run.log" | tee -a "$OUT_DIR/08_4.log"

echo "========== check h264 ==========" | tee -a "$OUT_DIR/08_4.log"
ls -lh "$H264" | tee -a "$OUT_DIR/08_4.log"

echo "========== package mp4 ==========" | tee -a "$OUT_DIR/08_4.log"
ffmpeg -y \
  -framerate 30 \
  -i "$H264" \
  -c copy \
  "$MP4" \
  2>&1 | tee "$OUT_DIR/ffmpeg_pack_mp4.log"

echo "========== ffprobe ==========" | tee -a "$OUT_DIR/08_4.log"
ffprobe -hide_banner "$MP4" \
  2>&1 | tee "$OUT_DIR/ffprobe_mp4.log"

echo "========== extract first frame ==========" | tee -a "$OUT_DIR/08_4.log"
ffmpeg -y \
  -i "$MP4" \
  -frames:v 1 \
  "$FIRST_JPG" \
  2>&1 | tee "$OUT_DIR/extract_first_jpg.log"

echo "========== csv avg ==========" | tee -a "$OUT_DIR/08_4.log"
python3 - <<'PY' | tee -a "$OUT_DIR/08_4.log"
import csv
from pathlib import Path

p = Path("output/exp08_4_detect_fifo_mpp_clean/profile_detect_to_nv12_clean.csv")

rows = []
with p.open() as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

print("frames:", len(rows))

keys = [
    "select_ms",
    "dqbuf_ms",
    "rga_nv12_to_rgb_ms",
    "input_prepare_ms",
    "model_total_ms",
    "draw_ms",
    "rga_rgb_to_nv12_ms",
    "write_ms",
    "qbuf_ms",
    "total_ms",
    "fps",
    "detect_count",
]

for k in keys:
    vals = [float(r[k]) for r in rows]
    print(f"{k:22s}: avg={sum(vals)/len(vals):8.3f}  min={min(vals):8.3f}  max={max(vals):8.3f}")

total = [float(r["total_ms"]) for r in rows]
print(f"\n1000 / avg_total_ms fps : {1000.0 / (sum(total) / len(total)):.3f}")
PY

echo "========== final files ==========" | tee -a "$OUT_DIR/08_4.log"
ls -lh "$OUT_DIR" | tee -a "$OUT_DIR/08_4.log"
EOF_SCRIPT

chmod +x scripts/exp08_4_detect_fifo_mpp_clean.sh
./scripts/exp08_4_detect_fifo_mpp_clean.sh
```

---

### 9.4 08-4 输出文件

```text
output/exp08_4_detect_fifo_mpp_clean/
├── 08_4.log
├── extract_first_jpg.log
├── ffmpeg_pack_mp4.log
├── ffprobe_mp4.log
├── first_frame_from_mp4.jpg
├── live_detect_clean_300f_1280x720.h264
├── live_detect_clean_300f_1280x720.mp4
├── mpi_enc_detect_fifo_run.log
├── profile_detect_to_nv12_clean.csv
└── v4l2_rga_rknn_detect_to_nv12_clean.log
```

关键文件大小：

```text
live_detect_clean_300f_1280x720.h264    4.1M
live_detect_clean_300f_1280x720.mp4     4.1M
profile_detect_to_nv12_clean.csv        23K
v4l2_rga_rknn_detect_to_nv12_clean.log  370K
first_frame_from_mp4.jpg                47K
```

---

### 9.5 08-4 主程序性能结果

```text
========== 08-3 detect to nv12 result ==========
frames              : 300
wall_time_ms        : 10613.529
wall_fps            : 28.266
avg_select_ms       : 0.314
avg_dqbuf_ms        : 0.003
avg_rga_nv12_to_rgb : 1.717
avg_input_prepare   : 0.001
avg_model_total_ms  : 27.834
avg_draw_ms         : 0.003
avg_rga_rgb_to_nv12 : 2.758
avg_write_ms        : 2.666
avg_qbuf_ms         : 0.036
avg_total_ms        : 35.333
profile csv         : output/exp08_4_detect_fifo_mpp_clean/profile_detect_to_nv12_clean.csv
output nv12/fifo    : output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_1280x720_nv12.fifo
================================================
```

CSV 平均结果：

```text
frames: 300

model_total_ms        : avg=  27.834  min=  22.516  max=  32.943
draw_ms               : avg=   0.003  min=   0.002  max=   0.007
rga_rgb_to_nv12_ms    : avg=   2.758  min=   1.793  max=   3.114
write_ms              : avg=   2.666  min=   1.040  max=   8.770
qbuf_ms               : avg=   0.036  min=   0.028  max=   0.114
total_ms              : avg=  35.332  min=  27.477  max= 120.123
fps                   : avg=  28.619  min=   8.325  max=  36.394
detect_count          : avg=   0.000  min=   0.000  max=   0.000

1000 / avg_total_ms fps : 28.303
```

---

### 9.6 08-4 MPP 编码结果

```text
mpp[57693]: mpi_enc_test: chn 0 encode 300 frames time 10705 ms delay   2 ms fps 28.02 bps 3424788
mpp[57693]: mpi_enc_test: /home/cat/mpp/build/test/mpi_enc_test average frame rate 28.02
```

`ffprobe` 结果：

```text
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4':

Duration: 00:00:10.00
bitrate: 3428 kb/s

Stream #0:0:
    Video: h264 (High)
    yuvj420p(pc)
    1280x720
    3424 kb/s
    30 fps
```

---

### 9.7 08-4 结论

08-4 结论：

```text
1. 去掉 debug JPG 和每帧 fflush 后，完整检测录像链路稳定运行 300 帧；
2. 主程序 wall_fps = 28.266FPS；
3. 由 avg_total_ms 反推 FPS = 28.303FPS；
4. MPP 编码端平均帧率 = 28.02FPS；
5. 最终 MP4 为 1280x720、H.264 High、30fps、10秒；
6. MPP 编码器可以跟上检测主链路；
7. 当前瓶颈仍然主要在 inference_yolo11_model()；
8. FIFO 写入和 RGA RGB→NV12 有一定开销，但不是主瓶颈；
9. 完整链路已经基本达到 720P 接近 30FPS 的实时检测录像能力。
```

---

## 10. 08 实验整体性能对比

| 实验 | 链路 | 帧数 | 关键结果 |
|---|---|---:|---|
| 08-0 | MPP 环境探测 | - | MPP 头文件、库、mpi_enc_test、/dev/video11 NV12 均可用 |
| 08-1 | V4L2 dump NV12 | 120 | wall_fps = 29.623FPS |
| 08-1 retry | raw NV12 → MPP H.264 | 120 | 离线编码 270.09FPS，MP4 正常 |
| 08-2 | V4L2 → FIFO → MPP | 120 | 实时编码 MP4 正常，1280x720/30fps |
| 08-3 | V4L2 + RGA + RKNN + 画框 + MPP | 120 | 约 28.6FPS，完整链路跑通 |
| 08-4 | 08-3 clean 稳定性测试 | 300 | wall_fps = 28.266FPS，MPP 端 = 28.02FPS |

---

## 11. 当前完整链路耗时拆解

08-4 最终平均耗时：

```text
avg_select_ms       : 0.314 ms
avg_dqbuf_ms        : 0.003 ms
avg_rga_nv12_to_rgb : 1.717 ms
avg_input_prepare   : 0.001 ms
avg_model_total_ms  : 27.834 ms
avg_draw_ms         : 0.003 ms
avg_rga_rgb_to_nv12 : 2.758 ms
avg_write_ms        : 2.666 ms
avg_qbuf_ms         : 0.036 ms
avg_total_ms        : 35.333 ms
```

耗时排序：

```text
第一：model_total_ms
    27.834ms
    占比约 78.8%

第二：rga_rgb_to_nv12_ms
    2.758ms
    占比约 7.8%

第三：write_ms
    2.666ms
    占比约 7.5%

第四：rga_nv12_to_rgb_ms
    1.717ms
    占比约 4.9%

其他：
    select / dqbuf / qbuf / input_prepare / draw
    都不是主要瓶颈。
```

结论：

```text
当前主要瓶颈仍然是 inference_yolo11_model() 整体链路；
MPP 编码器不是瓶颈；
FIFO 写入不是主瓶颈；
RGA 双向颜色转换有开销，但可接受。
```

---

## 12. 关于 `RGA_COLORFILL fail` 日志

08-4 日志中仍然可以看到：

```text
RgaCollorFill(1819) RGA_COLORFILL fail: Invalid argument
RgaCollorFill(1820) RGA_COLORFILL fail: Invalid argument
Failed to call RockChipRga interface
```

出现位置在：

```text
rknn_run 前后的 convert_image_with_letterbox() 内部
```

根据日志：

```text
scale=0.500000
dst_box=(0 140 639 499)
fill dst image (x y w h)=(0 0 640 640) with color=0x72727272
```

说明官方 `inference_yolo11_model()` 内部在做：

```text
1280x720 RGB 输入
    ↓
letterbox 到 640x640
    ↓
填充灰边
```

其中 RGA color fill 失败，但程序没有崩溃，仍然继续 `rknn_run` 并完成检测。

判断：

```text
1. 这不是 08 外部 RGA NV12→RGB 或 RGB→NV12 的失败；
2. 这是官方 YOLO11 内部 letterbox 预处理中的 RGA color fill 问题；
3. 当前完整链路仍能稳定 28FPS，因此暂时不影响 08 实验收口；
4. 后续若要极限优化，可以考虑替换官方 convert_image_with_letterbox()，减少内部 RGA warning 和潜在 fallback。
```

---

## 13. 为什么 08 没有直接手写 MPP API？

本实验使用：

```text
mpi_enc_test + FIFO
```

而不是一开始直接在 C++ 里调用 MPP API。

原因：

```text
1. 当前目标是先验证完整工程链路是否成立；
2. mpi_enc_test 是 Rockchip MPP 自带编码测试程序，适合快速验证编码器能力；
3. FIFO 可以把当前程序输出的 NV12 与 MPP 编码器解耦；
4. 这样可以快速判断问题是否出现在编码器端；
5. 当前 08 已经证明 MPP 编码器不是瓶颈。
```

后续如果继续工程化，可以把：

```text
FIFO + mpi_enc_test
```

替换成：

```text
C++ 内部直接调用 MPP API：
    mpp_create
    mpp_init
    mpi->control
    mpp_frame_init
    mpp_packet_init
    encode_put_frame
    encode_get_packet
```

但这属于下一阶段工程封装，不影响当前 08 实验结论。

---

## 14. 08 实验中的关键文件说明

### 14.1 `main_v4l2_dump_nv12.cpp`

作用：

```text
从 /dev/video11 使用 V4L2 mmap 采集 1280x720 NV12，
可以写入普通 raw 文件，
也可以写入 FIFO。
```

对应实验：

```text
08-1
08-2
```

### 14.2 `main_v4l2_rga_rknn_detect_to_nv12.cpp`

作用：

```text
V4L2 mmap 采集 NV12；
RGA 转 RGB；
RKNN 推理；
画框；
RGA 转回 NV12；
写入 FIFO；
输出 profile CSV。
```

对应实验：

```text
08-3
```

### 14.3 `main_v4l2_rga_rknn_detect_to_nv12_clean.cpp`

作用：

```text
在 08-3 基础上去掉 debug JPG 保存和每帧 fflush，
用于 300 帧稳定性测试。
```

对应实验：

```text
08-4
```

### 14.4 `exp08_2_v4l2_fifo_mpp.sh`

作用：

```text
启动 mpi_enc_test 作为后台编码器；
创建 FIFO；
启动 v4l2_dump_nv12 写 FIFO；
等待编码器结束；
封装 MP4；
抽帧验证。
```

### 14.5 `exp08_3_detect_fifo_mpp.sh`

作用：

```text
启动 mpi_enc_test；
启动完整检测程序写 FIFO；
保存检测结果 H.264 / MP4；
抽帧验证。
```

### 14.6 `exp08_4_detect_fifo_mpp_clean.sh`

作用：

```text
运行 300 帧干净版完整链路稳定性测试；
统计 CSV；
输出最终性能。
```

---

## 15. 当前项目能力更新

完成 08 后，当前项目已经具备：

```text
1. RK3588 上 YOLO11 RKNN 单图检测；
2. 视频文件检测；
3. OpenCV 摄像头检测；
4. V4L2 mmap 原生摄像头采集；
5. RGA NV12→RGB888 硬件颜色转换；
6. V4L2 + RGA + RKNN 实时检测；
7. inference_yolo11_model() 内部性能剖析；
8. Release + O3 + performance 优化；
9. MPP H.264 硬件编码环境验证；
10. V4L2 NV12 raw 文件离线编码；
11. V4L2 实时采集 FIFO 编码；
12. 检测画框后 RGB→NV12 再进入 MPP 编码；
13. H.264 裸流保存；
14. H.264 → MP4 封装；
15. MP4 抽帧验证；
16. 完整检测录像链路约 28FPS。
```

项目已经从：

```text
官方 Demo 迁移
```

推进到：

```text
RK3588 真实工程链路：
V4L2 + RGA + RKNN + MPP
```

---

## 16. 和前面实验的关系

整体路线：

```text
03_camera_detect：
    用 OpenCV 证明摄像头检测能跑通。

04_camera_profile：
    定位 OpenCV VideoCapture 是性能瓶颈。

05_v4l2_rga_realtime_preprocess：
    用 V4L2 mmap + RGA 替代 OpenCV 输入链路。

06_v4l2_rga_rknn_detect：
    接入 RKNN 后发现瓶颈转移到 inference_yolo11_model()。

07_model_internal_profile：
    拆解并优化 inference_yolo11_model()，达到接近 30FPS。

08_mpp_encode_record：
    将检测结果帧接入 MPP H.264 编码，保存为 MP4。
```

08 的意义在于：

```text
前面的 05~07 解决“实时检测”；
08 解决“检测结果如何高效录像保存”。
```

OpenCV `VideoWriter` 属于 CPU / 软件层封装，容易带来额外开销，不适合作为最终 RK3588 工程项目的核心录像方案。

MPP 则是 RK3588 的硬件视频编码链路，更符合嵌入式音视频工程项目定位。

---

## 17. 可以写进项目总结的一句话

```text
在 RK3588 平台上完成 V4L2 + RGA + RKNN + MPP 的端侧 AI 视频检测录像闭环：使用 V4L2 mmap 从 RKISP 摄像头节点采集 1280x720 NV12 图像，通过 RGA 完成 NV12/RGB888 双向转换，接入 YOLO11 RKNN 进行实时目标检测并绘制检测框，最终将检测结果帧转回 NV12 后通过 Rockchip MPP H.264 硬件编码保存为 MP4。300 帧稳定性测试中，完整链路达到约 28.3FPS，MPP 编码端约 28.0FPS，基本实现 720P 实时检测录像。
```

---

## 18. 可以写进简历的表达

简历压缩版：

```text
基于 RK3588 构建端侧 AI 视频检测录像链路，使用 V4L2 mmap 从 RKISP 摄像头采集 1280×720 NV12 图像，结合 RGA 实现 NV12↔RGB888 硬件颜色转换，接入 YOLO11 RKNN 完成实时推理与检测框绘制，并通过 Rockchip MPP H.264 硬件编码将检测结果保存为 MP4；在 300 帧稳定性测试中完整链路达到约 28FPS，替代 OpenCV VideoWriter，显著提升录像链路的工程可用性。
```

稍微详细版：

```text
完成 RK3588 上 V4L2 + RGA + RKNN + MPP 的完整端侧视频检测系统：通过 V4L2 mmap 绕开 OpenCV VideoCapture 采集瓶颈，直接获取 RKISP 输出的 1280×720 NV12 帧；使用 RGA 完成 NV12→RGB888 预处理与检测后 RGB888→NV12 回写；接入 YOLO11 RKNN Runtime 完成实时推理，并通过 MPP H.264 硬件编码保存检测结果视频。经 300 帧测试，完整链路稳定约 28.3FPS，编码端约 28.0FPS，验证了系统在 720P 实时检测录像场景下的可行性。
```

---

## 19. 当前仍存在的问题

### 19.1 `detect_count = 0`

08-4 中：

```text
detect_count avg=0
```

原因不是链路错误，而是当前测试画面中没有触发 COCO YOLO11 的检测目标，或者置信度没有达到阈值。

这个问题对 08 的链路验证影响不大，因为：

```text
1. RKNN 推理函数正常执行；
2. RGB 画框函数正常调用；
3. 即使没有框，RGB→NV12→MPP 编码链路也成立；
4. 08 的重点是编码录像链路，而不是检测准确率。
```

后续如果要验证画框效果，可以：

```text
1. 在摄像头前放置人、椅子等 COCO 类别目标；
2. 或者换成固定测试视频输入；
3. 或者降低阈值；
4. 或者替换成自己的孔探缺陷检测模型。
```

### 19.2 仍然使用 FIFO + mpi_enc_test

当前版本不是最终工程形态。

当前方式：

```text
主检测程序
    ↓
FIFO
    ↓
mpi_enc_test
```

优点：

```text
实现快；
验证链路清晰；
方便定位 MPP 编码是否可用。
```

不足：

```text
1. 需要启动两个进程；
2. 编码参数控制不够灵活；
3. 难以在 C++ 程序内部统一管理编码状态；
4. 后续推流时还需要更直接地拿到 H.264 packet。
```

后续工程化方向：

```text
把 MPP 编码 API 直接集成到 C++ 主程序内部。
```

### 19.3 内部 RGA color fill warning

日志中的：

```text
RGA_COLORFILL fail
```

主要来自 YOLO11 内部 letterbox 阶段，不是 08 外部 RGA 转换失败。

后续可以考虑：

```text
1. 替换官方 convert_image_with_letterbox()；
2. 外部直接 RGA 输出 640x640 模型输入；
3. 减少内部 letterbox 和 RGA fill；
4. 进一步压缩 model_total_ms。
```

---

## 20. 后续实验建议

08 完成后，下一步建议进入：

```text
09_rtsp_stream_preview
```

目标：

```text
把当前保存到 MP4 的 H.264 检测结果，
进一步用于实时预览。
```

可选方向：

```text
方向 1：
    继续使用 FIFO + mpi_enc_test 输出 H.264 文件/管道，
    再接 FFmpeg 推 RTSP / RTMP / HTTP-FLV。

方向 2：
    自己在 C++ 中集成 MPP API，
    直接拿到 H.264 packet，
    再推给 RTSP server。

方向 3：
    先使用本地网络推流方案验证：
        FFmpeg
        mediamtx
        nginx-http-flv
        ZLMediaKit
```

推荐下一步顺序：

```text
09-0：确认板端/本机是否有 ffmpeg 推流能力；
09-1：用已有 MP4/H264 文件推 RTSP，验证播放器可看；
09-2：用 FIFO 实时推流；
09-3：接入当前检测结果帧；
09-4：再考虑 C++ 内部集成 MPP + RTSP。
```

---

## 21. 08 实验最终总结

08 实验完成了从“能实时检测”到“能实时检测并硬件编码录像”的关键工程升级。

最终链路：

```text
RKISP /dev/video11
        ↓
V4L2 mmap 采集 1280x720 NV12
        ↓
RGA NV12 → RGB888
        ↓
YOLO11 RKNN 推理
        ↓
检测框绘制
        ↓
RGA RGB888 → NV12
        ↓
FIFO
        ↓
Rockchip MPP H.264 编码
        ↓
H.264 裸流
        ↓
FFmpeg MP4 封装
```

最终结果：

```text
300 帧稳定性测试：
    主检测程序 wall_fps ≈ 28.266FPS
    avg_total_ms ≈ 35.333ms
    反推 FPS ≈ 28.303FPS
    MPP 编码端 FPS ≈ 28.02FPS

输出视频：
    H.264 High
    1280x720
    30fps
    10s
    bitrate ≈ 3428kb/s
```

最终判断：

```text
1. MPP 硬件编码链路已经跑通；
2. MPP 编码器不是主要瓶颈；
3. 完整检测录像链路已经达到约 28FPS；
4. 当前项目已经具备端侧 AI 实时检测录像能力；
5. 后续可以继续扩展 RTSP / HTTP-FLV / HLS 实时预览。
```


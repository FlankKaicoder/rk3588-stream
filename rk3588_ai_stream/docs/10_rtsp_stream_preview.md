# 10 RTSP 实时检测预览实验记录

## 1. 实验背景

前面已经完成了 09 HLS 实时检测预览实验。

09 实验完成的链路是：

~~~text
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
MPP H.264 硬件编码
        ↓
FFmpeg HLS 切片
        ↓
Python HTTP Server
        ↓
VLC / 浏览器网络预览
~~~

09 实验已经证明：

~~~text
1. 板端 ffmpeg / ffprobe / ffplay 可用；
2. 板端可以通过 HLS 进行网络预览；
3. 实时检测链路输出的 H.264 可以被 FFmpeg 切成 HLS；
4. VLC 可以通过 http://板端IP:8080/index.m3u8 预览实时检测画面；
5. HLS 链路稳定，但延迟相对较高；
6. 后续需要继续验证 RTSP 这种更常见、延迟更低的实时流媒体协议。
~~~

因此 10 实验的目标是：

~~~text
将 09 的 HLS 实时预览链路升级为 RTSP 实时预览链路。
~~~

10 实验不是重新做检测，也不是重新做编码，而是在 08 / 09 已经跑通的基础上，继续验证：

~~~text
V4L2 + RGA + RKNN + MPP H.264 + RTSP + VLC
~~~

是否可以组成完整的端侧 AI 实时检测预览系统。

---

## 2. 实验目标

10 实验主要完成以下目标：

~~~text
1. 准备 RTSP Server；
2. 使用 MediaMTX 作为 RTSP Server；
3. 解决 MediaMTX 配置文件未加载导致 path not configured 的问题；
4. 解决 FFmpeg 后台运行被 shell 挂起的问题；
5. 验证已有 MP4 文件能否通过 RTSP 推送并由 VLC 播放；
6. 验证实时检测输出能否通过 RTSP 推送并由 VLC 播放；
7. 对比 RTSP over TCP 与 RTSP over UDP；
8. 分析 UDP 丢包和 H.264 FU-A 分片错误；
9. 固定最终方案为 RTSP over TCP；
10. 进行 RTSP TCP 稳定性测试；
11. 总结当前实时性瓶颈与后续优化方向。
~~~

---

## 3. 实验编号说明

10 实验拆分为 5 个子实验：

~~~text
10-0：
    RTSP 环境探测与 MediaMTX 准备。

10-1：
    检测 MP4 文件 → FFmpeg → MediaMTX → RTSP → VLC。
    先验证 RTSP 基础链路。

10-2：
    实时检测 → MPP 编码 → FFmpeg → MediaMTX → RTSP → VLC。
    验证完整实时检测 RTSP 预览链路。

10-3：
    RTSP TCP / UDP 低延迟对照实验。
    比较稳定性、延迟、丢包和花屏情况。

10-4：
    RTSP over TCP 稳定性测试。
    固定最终方案，进行较长时间预览测试。
~~~

这样拆分的原因是：

~~~text
不能一上来就把实时检测、编码、RTSP Server、VLC 全部揉在一起。

如果失败，很难判断问题来自：
1. MediaMTX 没启动；
2. FFmpeg 没推流；
3. MPP 没编码；
4. 检测程序没写 FIFO；
5. VLC 网络访问不通；
6. RTSP 路径未配置；
7. TCP / UDP 传输问题。

所以先用 MP4 文件验证 RTSP 基础链路，再接入实时检测。
~~~

---

## 4. 当前工程路径

当前工程路径：

~~~bash
~/projects/rk3588_ai_stream
~~~

本实验涉及的主要文件结构：

~~~text
rk3588_ai_stream/
├── build/
│   └── v4l2_rga_rknn_detect_to_nv12_clean
│
├── tools/
│   └── mediamtx/
│       ├── mediamtx
│       ├── mediamtx.yml
│       └── LICENSE
│
├── scripts/
│   ├── exp10_0_rtsp_probe_and_mediamtx.sh
│   ├── exp10_1_rtsp_file_preview.sh
│   ├── exp10_2_realtime_detect_rtsp.sh
│   ├── exp10_3_rtsp_lowdelay_compare.sh
│   └── exp10_4_rtsp_tcp_stability.sh
│
├── output/
│   ├── exp10_rtsp_probe/
│   ├── exp10_debug_rtsp/
│   ├── exp10_1_rtsp_file_preview/
│   ├── exp10_2_realtime_detect_rtsp/
│   ├── exp10_3_rtsp_lowdelay_tcp/
│   ├── exp10_3_rtsp_lowdelay_udp/
│   └── exp10_4_rtsp_tcp_stability_300s_20260530_222632/
│
└── docs/
    └── 10_rtsp_stream_preview.md
~~~

---

## 5. 10 实验最终链路

10 实验最终跑通的完整链路为：

~~~text
摄像头 /dev/video11
        ↓
V4L2 mmap 采集 1280x720 NV12
        ↓
RGA NV12 → RGB888
        ↓
RKNN YOLO11 推理
        ↓
YOLO11 后处理
        ↓
检测框绘制
        ↓
RGA RGB888 → NV12
        ↓
NV12 FIFO
        ↓
Rockchip MPP H.264 硬件编码
        ↓
H.264 FIFO
        ↓
FFmpeg 读取 H.264 FIFO
        ↓
FFmpeg RTSP 推流
        ↓
MediaMTX RTSP Server
        ↓
电脑端 VLC 拉流预览
~~~

最终 RTSP 地址格式：

~~~text
rtsp://板端IP:8554/exp10_detect_stable
~~~

实际示例：

~~~text
rtsp://10.198.89.221:8554/exp10_detect_stable
~~~

VLC 推荐命令：

~~~bash
vlc --rtsp-tcp --network-caching=300 --avcodec-hw=none rtsp://10.198.89.221:8554/exp10_detect_stable
~~~

---

## 6. 10-0：RTSP 环境探测与 MediaMTX 准备

### 6.1 实验目的

10-0 的目的不是推流，而是确认 RTSP 所需基础环境：

~~~text
1. 板端 IP 地址；
2. ffmpeg 是否可用；
3. ffprobe 是否可用；
4. ffplay 是否可用；
5. ffmpeg 是否支持 RTSP / RTP / TCP / UDP；
6. 是否已有 RTSP Server；
7. 如果没有，则准备 MediaMTX；
8. 检查 MediaMTX 是否为 linux arm64 版本；
9. 检查 MediaMTX 是否能正常启动；
10. 检查 8554 端口是否监听。
~~~

### 6.2 MediaMTX 文件检查

执行：

~~~bash
cd ~/projects/rk3588_ai_stream

echo "===== system mediamtx ====="
which mediamtx || true

echo
echo "===== local mediamtx ====="
ls -lh tools/mediamtx 2>/dev/null || true

echo
echo "===== find mediamtx ====="
find . /usr /usr/local ~/mpp ~/demo -name "mediamtx" -type f 2>/dev/null
~~~

实际结果：

~~~text
===== system mediamtx =====

===== local mediamtx =====
总用量 59M
-rw-r--r-- 1 cat cat 1.1K  5月 16 01:20 LICENSE
-rwxr-xr-x 1 cat cat  59M  5月 16 01:25 mediamtx
-rw-r--r-- 1 cat cat  34K  5月 16 01:20 mediamtx.yml

===== find mediamtx =====
./tools/mediamtx/mediamtx
~~~

说明：

~~~text
系统全局没有 mediamtx；
本项目 tools/mediamtx/ 目录下存在 mediamtx；
mediamtx 文件可执行；
大小约 59M；
说明 MediaMTX 已经准备好。
~~~

### 6.3 手动启动 MediaMTX

执行：

~~~bash
cd ~/projects/rk3588_ai_stream

pkill -f mediamtx || true
pkill -f ffmpeg || true

mkdir -p output/exp10_debug_rtsp

if command -v mediamtx >/dev/null 2>&1; then
  MEDIAMTX_BIN=$(command -v mediamtx)
else
  MEDIAMTX_BIN=./tools/mediamtx/mediamtx
fi

echo "MEDIAMTX_BIN=$MEDIAMTX_BIN"

"$MEDIAMTX_BIN" > output/exp10_debug_rtsp/mediamtx.log 2>&1 &
sleep 2

echo "===== process ====="
ps -ef | grep mediamtx | grep -v grep || echo "NO mediamtx process"

echo
echo "===== port ====="
ss -ltnp | grep 8554 || echo "NO 8554 LISTEN"

echo
echo "===== log ====="
tail -80 output/exp10_debug_rtsp/mediamtx.log
~~~

实际结果：

~~~text
MEDIAMTX_BIN=./tools/mediamtx/mediamtx

===== process =====
cat      4139480 ... ./tools/mediamtx/mediamtx

===== port =====
LISTEN 0 0 *:8554 *:* users:(("mediamtx",pid=4139480,fd=7))

===== log =====
MediaMTX v1.18.2, linux, arm64
configuration file not found ..., using an empty configuration
[RTSP] listener opened on :8554
[RTMP] listener opened on :1935
[HLS] listener opened on :8888
[WebRTC] listener opened on :8889
[SRT] listener opened on :8890
~~~

### 6.4 10-0 结论

10-0 说明：

~~~text
1. MediaMTX 可以在 RK3588 板端运行；
2. MediaMTX 是 linux arm64 版本；
3. RTSP 8554 端口可以正常监听；
4. MediaMTX 默认还会同时开启：
   - RTMP 1935；
   - HLS 8888；
   - WebRTC 8889；
   - SRT 8890；
5. 初始启动时没有加载配置文件，会导致后续 path not configured 问题。
~~~

---

## 7. 10-1：MP4 文件 RTSP 预览

### 7.1 实验目的

10-1 先不接实时摄像头，而是用 08 已经生成的检测 MP4 文件验证 RTSP 基础链路。

输入文件：

~~~text
output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4
~~~

10-1 链路：

~~~text
已有检测 MP4
        ↓
FFmpeg 循环读取
        ↓
FFmpeg 复制 H.264 码流
        ↓
推送到 rtsp://127.0.0.1:8554/exp10_file
        ↓
MediaMTX
        ↓
电脑端 VLC 打开 rtsp://板端IP:8554/exp10_file
~~~

### 7.2 第一次失败：path not configured

第一次 VLC 打开：

~~~text
rtsp://10.198.89.221:8554/exp10_file
~~~

VLC 报错：

~~~text
VLC 无法连接到 10.198.89.221:8554
VLC 无法打开 MRL rtsp://10.198.89.221:8554/exp10_file
~~~

检查端口时第一次发现：

~~~text
NO 8554 LISTEN
~~~

说明当时 MediaMTX 没有启动。

后续手动启动 MediaMTX 后，8554 已经监听成功，但 MediaMTX 日志出现：

~~~text
path 'exp10_file' is not configured
~~~

原因是：

~~~text
MediaMTX 启动时没有加载配置文件；
默认 empty configuration 不允许任意 path；
VLC 访问 exp10_file 时被拒绝。
~~~

### 7.3 第二个问题：FFmpeg 后台被挂起

第一次后台运行 FFmpeg：

~~~bash
ffmpeg -re -stream_loop -1 \
  -i "$INPUT_MP4" \
  -an \
  -c:v copy \
  -f rtsp \
  -rtsp_transport tcp \
  rtsp://127.0.0.1:8554/exp10_file \
  > output/exp10_debug_rtsp/ffmpeg_push.log 2>&1 &
~~~

查看 jobs 时出现：

~~~text
[2]+ 已停止 ffmpeg ...
~~~

原因：

~~~text
FFmpeg 后台运行时可能尝试读取 stdin；
shell 会把后台任务挂起；
需要添加 -nostdin。
~~~

### 7.4 修复方式

创建最小 MediaMTX 配置：

~~~bash
cat > output/exp10_debug_rtsp/mediamtx_min.yml <<'EOF'
rtspAddress: :8554

paths:
  all_others:
EOF
~~~

然后显式指定配置文件启动 MediaMTX：

~~~bash
./tools/mediamtx/mediamtx output/exp10_debug_rtsp/mediamtx_min.yml \
  > output/exp10_debug_rtsp/mediamtx.log 2>&1 &
~~~

FFmpeg 推流时加入 `-nostdin`：

~~~bash
INPUT_MP4="output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4"

ffmpeg -nostdin -re -stream_loop -1 \
  -i "$INPUT_MP4" \
  -an \
  -c:v copy \
  -f rtsp \
  -rtsp_transport tcp \
  rtsp://127.0.0.1:8554/exp10_file \
  > output/exp10_debug_rtsp/ffmpeg_push.log 2>&1 &
~~~

### 7.5 10-1 成功日志

MediaMTX 日志：

~~~text
configuration loaded from .../mediamtx_min.yml
[RTSP] listener opened on :8554
[path exp10_file] stream is available and online, 1 track (H264)
[RTSP] [session ...] is publishing to path 'exp10_file'
~~~

FFmpeg 日志：

~~~text
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from '...live_detect_clean_300f_1280x720.mp4'
Duration: 00:00:10.00
Video: h264 (High), 1280x720, 30 fps

Output #0, rtsp, to 'rtsp://127.0.0.1:8554/exp10_file'
Stream #0:0 -> #0:0 (copy)
frame=261 fps=30 speed=1.01x
~~~

VLC 成功打开：

~~~text
rtsp://10.198.89.221:8554/exp10_file
~~~

### 7.6 10-1 结论

10-1 证明：

~~~text
1. MediaMTX 可以作为 RK3588 板端 RTSP Server；
2. FFmpeg 可以向 MediaMTX 推送 H.264；
3. VLC 可以从电脑端拉取 RTSP 流；
4. RTSP 基础链路已经跑通；
5. 后续可以将输入从 MP4 替换为实时检测 H.264 FIFO。
~~~

---

## 8. 10-2：实时检测 RTSP 预览

### 8.1 实验目的

10-2 是 10 实验的核心，目标是把实时检测链路接入 RTSP。

10-2 链路：

~~~text
/dev/video11
        ↓
v4l2_rga_rknn_detect_to_nv12_clean
        ↓
NV12 FIFO
        ↓
mpi_enc_test
        ↓
H.264 FIFO
        ↓
FFmpeg
        ↓
MediaMTX
        ↓
VLC
~~~

### 8.2 10-2 脚本核心结构

核心变量：

~~~bash
WIDTH=1280
HEIGHT=720
FPS=30
FRAMES=18000

NV12_FIFO="$OUT_DIR/realtime_detect_nv12.fifo"
H264_FIFO="$OUT_DIR/realtime_detect_h264.fifo"
PROFILE="$OUT_DIR/profile_realtime_detect_rtsp.csv"
~~~

启动顺序非常重要：

~~~text
1. 创建两个 FIFO；
2. 启动 MediaMTX；
3. 启动 FFmpeg，等待 H264 FIFO；
4. 启动 MPP 编码器，读取 NV12 FIFO，写 H264 FIFO；
5. 启动实时检测程序，写 NV12 FIFO。
~~~

不能反过来启动，因为 FIFO 会阻塞。

### 8.3 FFmpeg 推 RTSP 命令

最终 TCP 稳定版：

~~~bash
ffmpeg -nostdin -y \
    -fflags nobuffer \
    -flags low_delay \
    -probesize 32 \
    -analyzeduration 0 \
    -use_wallclock_as_timestamps 1 \
    -f h264 \
    -framerate "$FPS" \
    -i "$H264_FIFO" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    "rtsp://127.0.0.1:8554/exp10_detect" \
    > "$OUT_DIR/ffmpeg_push_rtsp.log" 2>&1 &
~~~

参数说明：

| 参数 | 作用 |
|---|---|
| `-nostdin` | 防止后台 FFmpeg 被 shell 挂起 |
| `-fflags nobuffer` | 减少输入缓冲 |
| `-flags low_delay` | 低延迟标志 |
| `-probesize 32` | 降低探测数据量 |
| `-analyzeduration 0` | 降低分析时长 |
| `-use_wallclock_as_timestamps 1` | 使用墙上时间戳 |
| `-f h264` | 指定输入为裸 H.264 |
| `-framerate 30` | 指定输入帧率 |
| `-c:v copy` | 不重新编码，直接复制码流 |
| `-rtsp_transport tcp` | RTSP 使用 TCP，保证稳定性 |

### 8.4 VLC 打开方式

推荐命令：

~~~bash
vlc --rtsp-tcp --network-caching=300 --avcodec-hw=none rtsp://10.198.89.221:8554/exp10_detect
~~~

低延迟版本：

~~~bash
vlc --rtsp-tcp --network-caching=100 --avcodec-hw=none rtsp://10.198.89.221:8554/exp10_detect
~~~

参数说明：

| 参数 | 作用 |
|---|---|
| `--rtsp-tcp` | 强制 VLC 使用 RTSP over TCP |
| `--network-caching=300` | 网络缓存 300ms，稳定性较好 |
| `--network-caching=100` | 网络缓存 100ms，延迟更低，但更容易卡 |
| `--avcodec-hw=none` | 关闭硬件解码，避免虚拟机 VAAPI / VDPAU 报错 |

### 8.5 VLC 终端报错说明

VLC 终端中出现过：

~~~text
vaInitialize: unknown libva error
VDPAU backend libvdpau_nvidia.so: 无法打开
main decoder error: buffer deadlock prevented
QObject::~QObject: Timers cannot be stopped from another thread
~~~

这些主要来自：

~~~text
Ubuntu 虚拟机中的 VLC 硬件解码 / 显示加速后端不可用。
~~~

解决：

~~~bash
vlc --avcodec-hw=none ...
~~~

这些报错不代表 RK3588 推流失败，因为画面已经可以正常显示。

### 8.6 10-2 结论

10-2 证明：

~~~text
实时检测 RTSP 预览链路已经跑通。

完整链路：
/dev/video11
  → V4L2 mmap
  → RGA
  → RKNN
  → MPP H.264
  → FFmpeg RTSP
  → MediaMTX
  → VLC

VLC 可以打开实时检测画面。
~~~

---

## 9. 10-3：RTSP TCP / UDP 低延迟对照实验

### 9.1 实验目的

10-3 的目标是比较：

~~~text
RTSP over TCP
RTSP over UDP
~~~

在当前板端、虚拟机、网络环境下的稳定性和延迟表现。

### 9.2 TCP 结果

TCP MediaMTX 日志：

~~~text
[path exp10_detect] stream is available and online, 1 track (H264)
[RTSP] [session ...] is publishing to path 'exp10_detect'
[RTSP] [session ...] is reading from path 'exp10_detect', with TCP, 1 track (H264)
~~~

TCP FFmpeg 日志：

~~~text
Input #0, h264, from '.../realtime_detect_h264.fifo'
Output #0, rtsp, to 'rtsp://127.0.0.1:8554/exp10_detect'
Stream #0:0 -> #0:0 (copy)
frame=1444 fps=18 speed=1x
~~~

说明 TCP 模式下：

~~~text
1. FFmpeg 可以推流；
2. MediaMTX 可以发布 exp10_detect；
3. VLC 可以拉流；
4. 稳定性较好；
5. 退出时出现 Broken pipe，是人为中断或脚本 cleanup 导致，不是运行时失败。
~~~

### 9.3 UDP 结果

UDP MediaMTX 日志：

~~~text
[path exp10_detect] stream is available and online, 1 track (H264)
[RTSP] [session ...] is publishing to path 'exp10_detect'
[RTSP] [session ...] is reading from path 'exp10_detect', with UDP, 1 track (H264)

WAR [RTSP] [session ...] 4 RTP packets lost
WAR [path exp10_detect] 4 processing errors, last was: invalid FU-A packet (non-starting)
~~~

说明 UDP 模式虽然可以播放，但是出现：

~~~text
1. RTP packets lost；
2. invalid FU-A packet；
3. H.264 分片不完整；
4. 有花屏、卡顿或断帧风险。
~~~

### 9.4 TCP / UDP 对比结论

| 模式 | 结果 | 稳定性 | 延迟 | 是否推荐 |
|---|---|---|---|---|
| RTSP over TCP | 成功 | 较好 | 略高但可接受 | 推荐 |
| RTSP over UDP | 成功但有丢包 | 较差 | 理论更低 | 不推荐 |

最终结论：

~~~text
当前项目最终采用 RTSP over TCP。
~~~

原因：

~~~text
1. TCP 稳定性更好；
2. 没有 UDP 中的 RTP 丢包和 FU-A 分片错误；
3. 对项目演示和简历展示而言，稳定性优先级高于极限低延迟；
4. 当前延迟已经可以接受，用户主观观察实时性较好。
~~~

---

## 10. 10-4：RTSP over TCP 稳定性测试

### 10.1 实验目的

10-4 固定最终方案：

~~~text
RTSP over TCP
VLC network-caching=300
VLC 关闭硬件解码
~~~

目标是验证：

~~~text
1. 是否可以持续预览；
2. 是否断流；
3. 是否花屏；
4. 是否卡顿；
5. 延迟是否明显累积；
6. MediaMTX / FFmpeg / MPP / 检测程序是否稳定运行。
~~~

### 10.2 运行命令

创建脚本：

~~~bash
scripts/exp10_4_rtsp_tcp_stability.sh
~~~

运行 300 秒版本：

~~~bash
cd ~/projects/rk3588_ai_stream

./scripts/exp10_4_rtsp_tcp_stability.sh 300
~~~

VLC 打开：

~~~bash
vlc --rtsp-tcp --network-caching=300 --avcodec-hw=none rtsp://10.198.89.221:8554/exp10_detect_stable
~~~

### 10.3 实际实验现象

用户实际观察：

~~~text
延时已经比较小；
实时性相比前面版本明显改善；
由于效果已经达到预期，所以临时 Ctrl+C 中断实验。
~~~

虽然用户提前中断，但是日志显示：

~~~text
elapsed 453s / target 300s
~~~

说明实际已经连续运行超过 7 分钟。

这里之所以超过 300 秒，是因为脚本按帧数控制：

~~~text
FRAMES = DURATION_SEC × FPS = 300 × 30 = 9000 帧
~~~

但实际检测链路不是 30FPS，而是约 18~23FPS，所以 9000 帧实际运行时间会超过 300 秒。

这不是异常，而是脚本设计导致的时间换算差异。

### 10.4 10-4 MediaMTX 成功日志

MediaMTX 正常启动：

~~~text
MediaMTX v1.18.2, linux, arm64
configuration loaded from .../mediamtx_min.yml
[RTSP] listener opened on :8554
~~~

FFmpeg 成功推流：

~~~text
[path exp10_detect_stable] stream is available and online, 1 track (H264)
[RTSP] [session ...] is publishing to path 'exp10_detect_stable'
~~~

VLC 成功拉流：

~~~text
[RTSP] [session ...] is reading from path 'exp10_detect_stable', with TCP, 1 track (H264)
~~~

VLC 连接持续时间：

~~~text
22:27:14 开始 reading
22:34:14 连接关闭
持续约 7 分钟
~~~

说明：

~~~text
RTSP over TCP 稳定预览通过。
~~~

### 10.5 10-4 FFmpeg 日志

FFmpeg 日志：

~~~text
Input #0, h264, from '.../realtime_detect_h264.fifo'
Video: h264 (High), yuvj420p, 1280x720

Output #0, rtsp, to 'rtsp://127.0.0.1:8554/exp10_detect_stable'
Stream #0:0 -> #0:0 (copy)

frame=8523 fps=18 time=00:07:41.48 speed=1x
video:120951kB
~~~

说明：

~~~text
FFmpeg 持续从 H.264 FIFO 读取码流；
持续以 RTSP 推给 MediaMTX；
推流时长超过 7 分钟；
平均推流帧率约 18FPS。
~~~

其中：

~~~text
av_interleaved_write_frame(): Broken pipe
Exiting normally, received signal 15
~~~

是因为用户 Ctrl+C 中断后脚本 cleanup 关闭 MediaMTX / FFmpeg / FIFO，属于正常退出，不是运行失败。

### 10.6 10-4 MPP 编码日志

MPP 编码器持续输出：

~~~text
mpi_enc_test: chn 0 encoded frame 8463 ...
...
mpi_enc_test: chn 0 encoded frame 8582 ...
~~~

说明：

~~~text
MPP H.264 编码器持续工作；
编码过程没有中途崩溃；
码率大约在 3.3~4.0Mbps 附近波动；
存在周期性 I 帧，例如 frame=8520 size=113546。
~~~

### 10.7 10-4 检测程序性能

检测程序关键日志示例：

~~~text
frame=8250 total=57.660 fps=17.343 rga_in=2.277 model=42.617 draw=1.551 rga_out=5.813 write=5.242 det=3
frame=8280 total=48.868 fps=20.463 rga_in=3.156 model=36.458 draw=0.435 rga_out=3.515 write=5.149 det=2
frame=8400 total=44.785 fps=22.329 rga_in=2.230 model=35.540 draw=0.003 rga_out=3.232 write=3.672 det=0
frame=8520 total=42.539 fps=23.508 rga_in=2.471 model=32.999 draw=0.003 rga_out=2.934 write=4.003 det=0
frame=8580 total=56.986 fps=17.548 rga_in=2.871 model=44.420 draw=0.004 rga_out=5.824 write=3.773 det=0
~~~

说明：

~~~text
当前完整检测 + 编码写 FIFO 链路大约在 17~23FPS 之间波动。
~~~

主要耗时来源仍然是：

~~~text
model 阶段，也就是 inference_yolo11_model()。
~~~

例如：

~~~text
model=32.999ms
model=35.540ms
model=42.617ms
model=44.420ms
~~~

### 10.8 10-4 结论

10-4 结论：

~~~text
RTSP over TCP 稳定性测试通过。

实验中 VLC 成功通过 RTSP over TCP 拉取实时检测画面，持续预览约 7 分钟。
用户主观观察延迟较小，实时性达到当前阶段预期。
测试过程中未出现 UDP 模式下的 RTP packets lost / invalid FU-A 错误。
人为 Ctrl+C 中断后出现 Broken pipe，属于正常退出日志。

最终方案确定为：
RTSP over TCP + MediaMTX + FFmpeg + MPP H.264 + VLC。
~~~

---

## 11. 本实验中遇到的问题与解决方案

### 11.1 问题 1：VLC 无法连接 8554

现象：

~~~text
VLC 无法连接到 10.198.89.221:8554
VLC 无法打开 MRL rtsp://10.198.89.221:8554/exp10_file
~~~

排查：

~~~bash
ss -lntup | grep 8554 || echo "NO 8554 LISTEN"
~~~

结果：

~~~text
NO 8554 LISTEN
~~~

原因：

~~~text
MediaMTX 没有启动；
没有程序监听 8554 端口。
~~~

解决：

~~~bash
./tools/mediamtx/mediamtx output/exp10_debug_rtsp/mediamtx_min.yml \
  > output/exp10_debug_rtsp/mediamtx.log 2>&1 &
~~~

---

### 11.2 问题 2：path not configured

现象：

~~~text
path 'exp10_file' is not configured
~~~

原因：

~~~text
MediaMTX 没有加载配置文件；
默认 empty configuration 不允许任意 RTSP path；
VLC 请求 exp10_file 时被拒绝。
~~~

解决：

~~~bash
cat > output/exp10_debug_rtsp/mediamtx_min.yml <<'EOF'
rtspAddress: :8554

paths:
  all_others:
EOF
~~~

然后启动时显式指定配置：

~~~bash
./tools/mediamtx/mediamtx output/exp10_debug_rtsp/mediamtx_min.yml
~~~

---

### 11.3 问题 3：FFmpeg 后台任务被停止

现象：

~~~text
[2]+ 已停止 ffmpeg ...
~~~

原因：

~~~text
FFmpeg 后台运行时可能尝试读取 stdin；
shell 将后台任务挂起。
~~~

解决：

~~~bash
ffmpeg -nostdin ...
~~~

---

### 11.4 问题 4：bash: /ffmpeg_push_rtsp.log 权限不够

现象：

~~~text
bash: /ffmpeg_push_rtsp.log: 权限不够
~~~

原因：

~~~bash
> "$OUT_DIR/ffmpeg_push_rtsp.log"
~~~

执行时 `OUT_DIR` 变量为空，shell 实际重定向到：

~~~bash
/ffmpeg_push_rtsp.log
~~~

普通用户无权写根目录。

解决：

~~~text
不要单独复制脚本内部的 FFmpeg 命令；
要么运行完整脚本；
要么先定义 OUT_DIR、FPS、H264_FIFO 等变量。
~~~

检查变量：

~~~bash
echo "$OUT_DIR"
echo "$FPS"
echo "$H264_FIFO"
~~~

---

### 11.5 问题 5：UDP 模式 RTP 丢包

现象：

~~~text
WAR [RTSP] [session ...] 4 RTP packets lost
WAR [path exp10_detect] 4 processing errors, last was: invalid FU-A packet (non-starting)
~~~

原因：

~~~text
UDP 不保证可靠传输；
H.264 RTP 分片丢失后会导致 FU-A 包不完整；
可能引发花屏、卡顿、断帧。
~~~

解决：

~~~text
最终采用 RTSP over TCP。
~~~

---

### 11.6 问题 6：VLC 终端 VAAPI / VDPAU 报错

现象：

~~~text
vaInitialize: unknown libva error
VDPAU backend libvdpau_nvidia.so: 无法打开
main decoder error: buffer deadlock prevented
~~~

原因：

~~~text
电脑端 Ubuntu 虚拟机硬件解码后端不可用；
与 RK3588 板端推流无关。
~~~

解决：

~~~bash
vlc --avcodec-hw=none ...
~~~

最终推荐：

~~~bash
vlc --rtsp-tcp --network-caching=300 --avcodec-hw=none rtsp://10.198.89.221:8554/exp10_detect_stable
~~~

---

### 11.7 问题 7：RGA_COLORFILL fail

现象：

~~~text
RgaCollorFill RGA_COLORFILL fail: Invalid argument
Failed to call RockChipRga interface
~~~

出现位置：

~~~text
inference_yolo11_model() 内部的 convert_image_with_letterbox()
~~~

推测原因：

~~~text
YOLO11 推理前 letterbox 需要对 640x640 输入图像进行灰色 padding；
官方代码使用 RGA color fill 填充灰边；
当前 RGA color fill 参数不被接受，导致每帧打印错误。
~~~

影响：

~~~text
1. 程序没有崩溃；
2. rknn_run 仍然正常执行；
3. RTSP 链路不受影响；
4. 但日志被严重污染；
5. 每帧失败一次 RGA 调用，可能增加少量耗时。
~~~

后续优化方向：

~~~text
1. 将 letterbox 灰边填充改为 CPU memset；
2. 或修改 RGA color fill 参数格式；
3. 或直接关闭相关 RGA debug 输出；
4. 或重写预处理，避免每帧触发 RGA_COLORFILL fail。
~~~

---

## 12. 当前性能分析

根据 10-4 结果，当前链路性能大致为：

~~~text
整体 FPS：约 17~23FPS
单帧总耗时：约 42~58ms
主要瓶颈：model / inference_yolo11_model()
~~~

典型耗时：

| 阶段 | 典型耗时 |
|---|---:|
| RGA 输入转换 `rga_in` | 2~4ms |
| RKNN 推理整体 `model` | 33~45ms |
| 画框 `draw` | 0~1.5ms |
| RGA 输出转换 `rga_out` | 3~6ms |
| FIFO 写入 `write` | 3~5ms |
| 单帧总耗时 `total` | 42~58ms |

结论：

~~~text
RTSP 不是当前主要瓶颈；
MPP 编码器也不是主要瓶颈；
主要瓶颈仍然集中在模型推理整体链路。
~~~

---

## 13. 最终实验结论

10 实验最终完成了：

~~~text
从实时摄像头 AI 检测结果到 RTSP 网络预览的完整链路。
~~~

完整能力包括：

~~~text
1. MediaMTX RTSP Server 部署；
2. FFmpeg RTSP 推流；
3. VLC RTSP 拉流；
4. MP4 文件 RTSP 预览；
5. 实时检测 RTSP 预览；
6. TCP / UDP 传输对比；
7. RTSP over TCP 稳定性测试；
8. 低延迟参数配置；
9. VLC 播放端硬解码问题排查；
10. RTSP 方案最终固化。
~~~

最终稳定方案：

~~~text
RTSP over TCP
MediaMTX
FFmpeg -c:v copy
MPP H.264
VLC --rtsp-tcp --network-caching=300 --avcodec-hw=none
~~~

最终链路：

~~~text
/dev/video11
  → V4L2 mmap
  → RGA NV12 → RGB888
  → RKNN YOLO11
  → YOLO11 后处理
  → 检测框绘制
  → RGA RGB888 → NV12
  → MPP H.264
  → FFmpeg RTSP
  → MediaMTX
  → VLC
~~~

最终结论：

~~~text
10 实验成功完成。

RK3588 板端已经可以将实时摄像头 AI 检测画面通过 RTSP 推送到电脑端 VLC 播放。
RTSP over TCP 模式稳定性优于 UDP，适合作为最终项目演示方案。
当前端到端实时性已经可以接受，但检测链路仍在 17~23FPS 波动。
后续优化重点应转向模型推理耗时、RGA letterbox 报错、编码参数调优、以及将 MPP 编码和 RTSP 推流集成进 C++ 主程序。
~~~

---

## 14. 后续优化方向

### 14.1 优化方向一：修复 RGA_COLORFILL fail

当前每帧都有：

~~~text
RGA_COLORFILL fail
~~~

后续可以：

~~~text
1. 修改官方 yolo11.cc 中 letterbox 填充逻辑；
2. 将灰边填充改为 CPU memset；
3. 避免 RGA color fill 参数错误；
4. 减少日志污染；
5. 减少无效 RGA 调用耗时。
~~~

---

### 14.2 优化方向二：减少外部 FIFO 和进程

当前链路使用多个独立进程：

~~~text
检测进程
mpi_enc_test 编码进程
FFmpeg 推流进程
MediaMTX 服务进程
~~~

优点：

~~~text
验证快，方便排错。
~~~

缺点：

~~~text
1. FIFO 会引入缓冲；
2. 进程间通信增加复杂度；
3. 不方便精确控制延迟；
4. 不适合最终工程化版本。
~~~

后续可以改成：

~~~text
C++ 主程序内部直接调用 MPP 编码 API；
编码后的 H.264 直接送 RTSP / RTP / MediaMTX；
减少 FIFO 和外部 FFmpeg 缓冲。
~~~

---

### 14.3 优化方向三：模型推理链路优化

当前 model 阶段仍为主要瓶颈。

后续可继续从 07 实验方向优化：

~~~text
1. 优化 YOLO11 decode；
2. 降低无效分支扫描；
3. 减少后处理类别扫描；
4. 优化 letterbox；
5. 尝试更小模型；
6. 尝试直接使用孔探缺陷模型而不是 COCO 80 类模型；
7. 优化 RKNN 输出后处理。
~~~

---

### 14.4 优化方向四：编码参数调优

当前使用 `mpi_enc_test` 默认参数。

后续可以尝试：

~~~text
1. 调整码率；
2. 调整 GOP；
3. 降低 B 帧 / 缓冲；
4. 使用低延迟编码配置；
5. 控制 IDR 周期；
6. 减少编码器内部缓存。
~~~

---

### 14.5 优化方向五：WebRTC / HTTP-FLV 对比

当前已经完成：

~~~text
HLS：
    稳定，但延迟较高。

RTSP：
    延迟较低，VLC 支持好。
~~~

后续还可以对比：

~~~text
HTTP-FLV：
    浏览器端播放方便，延迟中等。

WebRTC：
    延迟最低，但工程复杂度更高。

SRT：
    适合可靠传输，工程上可作为扩展。
~~~

---

## 15. 实验最终状态

截至 10 实验完成，当前项目已经完成：

~~~text
00 官方 Demo 基线验证
01 单图检测迁移
02 视频文件检测迁移
03 OpenCV 摄像头检测
04 摄像头链路性能剖析
05 V4L2 + RGA 实时预处理
06 V4L2 + RGA + RKNN 实时检测
07 inference_yolo11_model 内部剖析与优化
08 MPP H.264 编码录像
09 HLS 网络预览
10 RTSP 实时检测预览
~~~

项目主线已经从：

~~~text
单图检测
~~~

逐步扩展到：

~~~text
实时摄像头采集
硬件预处理
NPU 推理
硬件编码
HLS / RTSP 网络预览
~~~

这已经具备一个完整端侧 AI 视频分析系统的雏形。


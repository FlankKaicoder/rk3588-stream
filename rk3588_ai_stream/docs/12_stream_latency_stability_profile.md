# 12 端到端流媒体链路稳定性与资源占用评估实验记录

## 1. 实验背景

前面 00~11 实验已经完成了从 RK3588 官方 YOLO11 Demo 到浏览器端实时预览的完整迁移和串联。

截至 11 实验结束，当前项目已经具备：

```text
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
FFmpeg RTSP 推流到 MediaMTX
        ↓
MediaMTX 同时提供 RTSP / HLS / WebRTC
        ↓
VLC / 浏览器实时预览
```

11 实验主要证明“能跑通”，12 实验开始回答系统级问题：

```text
1. /dev/video11 裸 V4L2 采集是否稳定？
2. 完整检测 + 编码 + 推流链路是否能持续运行？
3. 运行过程 CPU / 内存 / 温度是否正常？
4. MediaMTX、FFmpeg、MPP、检测程序是否会异常退出？
5. 如果链路退出，如何区分主动结束和异常崩溃？
```

本实验原计划包含 WebRTC / RTSP / HLS 端到端延迟观测，但由于现场不好做手机秒表 / 浏览器画面对比，因此本次暂时不纳入定量延迟数据。本次文档只记录稳定性与资源占用测试，不记录虚假的延迟数值。

---

## 2. 实验目标

12 实验的核心目标是验证当前 RK3588 AI 流媒体链路在受控时间内是否稳定，并记录系统资源占用情况。

本实验完成：

```text
1. 对 /dev/video11 做纯 V4L2 mmap 裸采集稳定性测试；
2. 验证摄像头链路本身是否会在几分钟后 select timeout；
3. 对完整 V4L2 + RGA + RKNN + MPP + FFmpeg + MediaMTX 链路进行 240 秒受控稳定性测试；
4. 使用 timeout 自动结束实验，避免人为 Ctrl+C 干扰结论；
5. 记录 CPU load、内存、温度、CPU 频率、流媒体相关进程资源占用；
6. 分析 MediaMTX、FFmpeg、MPP、检测程序日志；
7. 判断 Broken pipe、cleanup、shutting down gracefully 等日志到底是异常还是受控退出；
8. 形成当前系统稳定性阶段性结论。
```

---

## 3. 实验编号说明

```text
12-0：
    V4L2 裸采集 7200 帧稳定性测试。
    目的：验证 /dev/video11 裸采集是否稳定。

12-1：
    初始完整链路资源监控。
    目的：建立资源监控脚本，记录 CPU / 内存 / 温度 / 进程状态。
    说明：最初一次运行中完整链路约 182 秒后退出，后来确认是人为 Ctrl+C 中断，不能作为自动崩溃证据。

12-2：
    完整链路 240 秒受控稳定性测试。
    目的：使用 timeout 自动结束完整链路，判断系统在 240 秒内是否稳定运行。
```

---

## 4. 当前工程路径与相关文件

当前工程路径：

```bash
~/projects/rk3588_ai_stream
```

相关脚本：

```text
scripts/exp12_resource_monitor.sh
scripts/exp11_1_realtime_detect_browser.sh
```

输出目录：

```text
output/exp12_0_v4l2_camera_stability_short/
output/exp12_2_full_chain_240s/
```

12-0 输出文件：

```text
output/exp12_0_v4l2_camera_stability_short/v4l2_dump_7200.log
output/exp12_0_v4l2_camera_stability_short/dmesg_after_test.log
```

12-2 输出文件：

```text
output/exp12_2_full_chain_240s/full_chain_240s.log
output/exp12_2_full_chain_240s/resource_samples.csv
output/exp12_2_full_chain_240s/process_samples.log
output/exp12_2_full_chain_240s/port_samples.log
output/exp12_2_full_chain_240s/summary.txt
output/exp12_2_full_chain_240s/latency_observations.csv
```

同时复用了 11 实验的实时推流输出目录：

```text
output/exp11_1_realtime_detect_browser/
├── 11_1.log
├── mediamtx_browser.yml
├── mediamtx.log
├── ffmpeg_push.log
├── mpi_enc.log
├── realtime_detect_to_nv12.log
└── profile_realtime_detect_browser.csv
```

---

# 5. 12-0：V4L2 裸采集稳定性测试

## 5.1 实验目的

在最初完整链路测试中，曾经看到：

```text
select timeout at frame=3706
```

一开始容易误判为：

```text
/dev/video11 / RKISP / IMX415 摄像头链路在约 3 分钟后不稳定。
```

但后来确认，那次完整链路退出存在人为 Ctrl+C 中断因素，因此不能直接判断是摄像头自动崩溃。

为了排除摄像头裸采集问题，12-0 单独做：

```text
不跑 RKNN
不跑 RGA
不跑 MPP
不跑 FFmpeg
不跑 MediaMTX
不推流
只测试 /dev/video11 V4L2 mmap 裸采集
```

测试链路：

```text
/dev/video11
        ↓
V4L2 mmap 采集 1280x720 NV12
        ↓
写入 /dev/null
```

---

## 5.2 12-0 执行命令

最初计划跑 10 分钟，但时间较长，因此改成 7200 帧：

```text
7200 帧 / 30FPS ≈ 240 秒 ≈ 4 分钟
```

实际命令：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp12_0_v4l2_camera_stability_short

./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  7200 \
  /dev/null \
  > output/exp12_0_v4l2_camera_stability_short/v4l2_dump_7200.log 2>&1

echo "========== v4l2 dump log tail =========="
tail -120 output/exp12_0_v4l2_camera_stability_short/v4l2_dump_7200.log

echo
echo "========== dmesg tail =========="
dmesg | tail -200 > output/exp12_0_v4l2_camera_stability_short/dmesg_after_test.log
tail -200 output/exp12_0_v4l2_camera_stability_short/dmesg_after_test.log
```

---

## 5.3 12-0 关键结果

尾部日志中持续出现正常采集帧：

```text
frame=6990 index=2 bytesused=1382400 select=33.518 dqbuf=0.022 write=0.019 qbuf=0.258
frame=7020 index=0 bytesused=1382400 select=33.546 dqbuf=0.021 write=0.020 qbuf=0.254
frame=7050 index=2 bytesused=1382400 select=32.974 dqbuf=0.018 write=0.015 qbuf=0.171
frame=7080 index=0 bytesused=1382400 select=32.973 dqbuf=0.017 write=0.013 qbuf=0.211
frame=7110 index=2 bytesused=1382400 select=32.699 dqbuf=0.017 write=0.011 qbuf=0.121
frame=7140 index=0 bytesused=1382400 select=33.356 dqbuf=0.026 write=0.020 qbuf=0.315
frame=7170 index=2 bytesused=1382400 select=33.376 dqbuf=0.024 write=0.020 qbuf=0.308
```

最终统计：

```text
========== 08-1 dump nv12 result ==========
frames          : 7200
wall_time_ms    : 240048.699
wall_fps        : 29.994
avg_select_ms   : 33.102
avg_dqbuf_ms    : 0.021
avg_write_ms    : 0.015
avg_qbuf_ms     : 0.199
saved nv12      : /dev/null
==========================================
```

---

## 5.4 12-0 结果分析

12-0 结论非常明确：

```text
/dev/video11 在纯 V4L2 mmap 裸采集情况下，
可以稳定采集 7200 帧，
持续约 240 秒，
平均帧率 29.994 FPS。
```

说明：

```text
1. /dev/video11 裸采集没有复现 select timeout；
2. RKISP mainpath 输出 1280x720 NV12 稳定；
3. V4L2 mmap DQBUF / QBUF 流程稳定；
4. 摄像头链路本身不是 3 分钟左右必然断流；
5. 如果完整链路出现退出，应优先排查上层处理链路或人为中断，而不是直接怀疑裸摄像头。
```

---

## 5.5 dmesg 说明

12-0 的 dmesg 中仍能看到大量历史 RGA 报错，例如：

```text
rga_policy: invalid function policy
rga_job: job assign failed
rga request commit failed
rga: request submit failed
```

但要注意：

```text
12-0 裸采集程序本身不使用 RGA。
```

因此这些 RGA 日志大概率来自前一次完整检测链路中的 `inference_yolo11_model()` 内部 letterbox / color fill 报错残留，并不代表 12-0 裸采集失败。

12-0 对应的新日志主要是：

```text
rkcif-mipi-lvds: stream[0] start streaming
rockchip-mipi-csi2: stream ON
imx415: s_stream: 1
...
rkcif-mipi-lvds: stream[0] start stopping
rockchip-mipi-csi2: stream OFF
imx415: s_stream: 0
```

这说明本次 V4L2 采集是正常开启、正常结束。

---

# 6. 资源监控脚本

## 6.1 脚本目的

12 实验新增：

```text
scripts/exp12_resource_monitor.sh
```

该脚本用于定时记录：

```text
1. 系统 load average；
2. 内存总量和可用内存；
3. CPU 温度；
4. CPU 当前频率；
5. 流媒体相关进程 CPU 占用；
6. 流媒体相关进程内存占用；
7. 流媒体相关进程 RSS；
8. 流媒体相关进程数量；
9. 端口监听状态；
10. 相关进程状态。
```

监控的进程包括：

```text
mediamtx
ffmpeg
mpi_enc_test
v4l2_rga_rknn_detect_to_nv12_clean
```

资源采样 CSV 字段：

```text
timestamp
elapsed_s
load1
load5
load15
mem_total_kb
mem_available_kb
cpu_temp_c
cpu_freq_avg_mhz
stream_proc_cpu_percent
stream_proc_mem_percent
stream_proc_rss_kb
stream_proc_count
```

---

## 6.2 脚本运行命令

```bash
cd ~/projects/rk3588_ai_stream

./scripts/exp12_resource_monitor.sh output/exp12_2_full_chain_240s 240 5
```

参数含义：

```text
output/exp12_2_full_chain_240s：
    输出目录

240：
    监控 240 秒

5：
    每 5 秒采样一次
```

---

# 7. 12-1：初始完整链路监控与误判修正

## 7.1 初始现象

最初运行完整链路时，日志显示约 3706 帧后退出：

```text
select timeout at frame=3706
```

检测程序统计：

```text
frames              : 3706
wall_time_ms        : 181986.242
wall_fps            : 20.364
avg_select_ms       : 0.032
avg_dqbuf_ms        : 0.007
avg_rga_nv12_to_rgb : 2.621
avg_input_prepare   : 0.001
avg_model_total_ms  : 36.357
avg_draw_ms         : 0.043
avg_rga_rgb_to_nv12 : 3.134
avg_write_ms        : 6.164
avg_qbuf_ms         : 0.104
avg_total_ms        : 48.464
```

MPP 日志显示：

```text
found last frame. feof 1
encoded frame 3706 size 0
found last packet
encode 3707 frames time 183195 ms fps 20.24
```

FFmpeg 日志显示：

```text
frame=3526 fps=20 q=-1.0 Lsize=N/A time=00:01:58.39
```

MediaMTX 日志显示发布端断开：

```text
RTSP session destroyed
HLS muxer destroyed
```

---

## 7.2 初始误判与修正

一开始根据上述日志，容易判断为：

```text
完整链路在约 182 秒后自动退出；
源头可能是 V4L2 select timeout。
```

但后续确认：

```text
上次是手动 Ctrl+C 中断的。
```

因此需要修正判断：

```text
不能把这次 182 秒退出作为自动崩溃证据；
因为 Ctrl+C 会触发脚本 cleanup；
cleanup 会杀掉检测程序、MPP、FFmpeg、MediaMTX；
后续出现 feof、Broken pipe、RTSP session destroyed 都是连锁结果。
```

这个修正非常重要。

实验中断原因必须区分：

```text
人为 Ctrl+C / timeout 主动结束
```

和：

```text
程序内部异常 / 摄像头 timeout / 编码器崩溃 / 推流失败
```

否则会误判系统稳定性。

---

# 8. 12-2：完整链路 240 秒受控稳定性测试

## 8.1 实验目的

为了避免人为 Ctrl+C 干扰，12-2 使用 `timeout` 进行受控测试。

目标：

```text
让完整 11-1 实时检测浏览器预览链路运行 240 秒；
到时间后由 timeout 自动发送 INT 信号结束；
观察是否在 240 秒内自动崩溃。
```

测试链路：

```text
V4L2 mmap 采集 /dev/video11
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
MPP H.264 编码
        ↓
H.264 FIFO
        ↓
FFmpeg RTSP 推流
        ↓
MediaMTX
        ↓
RTSP / HLS / WebRTC 服务
```

---

## 8.2 终端 1：启动完整链路 240 秒

命令：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp12_2_full_chain_240s

timeout -s INT 240s ./scripts/exp11_1_realtime_detect_browser.sh \
  > output/exp12_2_full_chain_240s/full_chain_240s.log 2>&1

echo "========== full chain log tail =========="
tail -160 output/exp12_2_full_chain_240s/full_chain_240s.log

echo
echo "========== exp11 latest logs =========="
tail -120 output/exp11_1_realtime_detect_browser/realtime_detect_to_nv12.log
tail -80  output/exp11_1_realtime_detect_browser/mpi_enc.log
tail -80  output/exp11_1_realtime_detect_browser/ffmpeg_push.log
tail -80  output/exp11_1_realtime_detect_browser/mediamtx.log
```

关键点：

```text
timeout -s INT 240s
```

表示：

```text
运行 240 秒后自动向脚本发送 SIGINT；
脚本执行 cleanup；
各子进程被正常清理。
```

---

## 8.3 终端 2：资源监控 240 秒

在完整链路启动后，另开一个 SSH 终端执行：

```bash
cd ~/projects/rk3588_ai_stream

./scripts/exp12_resource_monitor.sh output/exp12_2_full_chain_240s 240 5
```

---

## 8.4 12-2 启动日志

完整链路启动时打印：

```text
========== 11-1 realtime detect browser preview ==========
board ip    : 10.198.89.221
stream path : exp11_detect_browser
width       : 1280
height      : 720
fps         : 30
frames      : 18000
nv12 fifo   : output/exp11_1_realtime_detect_browser/realtime_detect_nv12.fifo
h264 fifo   : output/exp11_1_realtime_detect_browser/realtime_detect_h264.fifo
profile     : output/exp11_1_realtime_detect_browser/profile_realtime_detect_browser.csv
mediamtx    : ./tools/mediamtx/mediamtx
```

端口监听：

```text
tcp   LISTEN *:8554  mediamtx
tcp   LISTEN *:1935  mediamtx
tcp   LISTEN *:8888  mediamtx
tcp   LISTEN *:8889  mediamtx
udp   UNCONN *:8189  mediamtx
```

说明 MediaMTX 监听端口正常：

```text
8554：RTSP
1935：RTMP
8888：HLS
8889：WebRTC HTTP signaling
8189：WebRTC UDP ICE
```

---

## 8.5 MediaMTX 发布日志

MediaMTX 启动：

```text
2026/06/02 22:29:28 INF MediaMTX v1.18.2, linux, arm64
2026/06/02 22:29:28 INF configuration loaded from .../mediamtx_browser.yml
2026/06/02 22:29:28 INF [RTSP] listener opened on :8554
2026/06/02 22:29:28 INF [RTMP] listener opened on :1935
2026/06/02 22:29:28 INF [HLS] listener opened on :8888
2026/06/02 22:29:28 INF [WebRTC] listener opened on :8889, :8189
2026/06/02 22:29:28 INF [SRT] listener opened on :8890
```

发布端上线：

```text
2026/06/02 22:29:40 INF [path exp11_detect_browser] stream is available and online, 1 track (H264)
2026/06/02 22:29:40 INF [RTSP] [session f49c05f5] is publishing to path 'exp11_detect_browser'
```

HLS muxer 自动创建：

```text
2026/06/02 22:29:40 INF [HLS] [muxer exp11_detect_browser] created automatically
2026/06/02 22:29:40 INF [HLS] [muxer exp11_detect_browser] is converting into HLS, 1 track (H264)
```

说明：

```text
FFmpeg 已经成功将 H.264 推送到 MediaMTX；
MediaMTX 已经成功识别 H264 track；
MediaMTX 已经为 exp11_detect_browser 自动生成 HLS 转封装。
```

---

## 8.6 播放端连接日志

MediaMTX 中出现 RTSP reader：

```text
2026/06/02 22:31:26 INF [RTSP] [session 7d5c71a6] is reading from path 'exp11_detect_browser', with UDP, 1 track (H264)
```

随后又切换为 TCP：

```text
2026/06/02 22:31:37 INF [RTSP] [session ad59dd1a] is reading from path 'exp11_detect_browser', with TCP, 1 track (H264)
```

说明：

```text
VLC / RTSP 客户端确实成功连接到 exp11_detect_browser；
RTSP 拉流链路可用；
UDP 和 TCP 都被测试到；
最终 TCP 连接持续到实验结束。
```

结合 10 实验结论，RTSP over TCP 更适合作为稳定演示方案。

---

## 8.7 受控结束日志

到 240 秒后，MediaMTX 日志出现：

```text
2026/06/02 22:33:27 INF shutting down gracefully
2026/06/02 22:33:27 INF [SRT] listener is closing
2026/06/02 22:33:27 INF [WebRTC] listener is closing
2026/06/02 22:33:27 INF [HLS] listener is closing
2026/06/02 22:33:27 INF [HLS] [muxer exp11_detect_browser] destroyed: terminated
2026/06/02 22:33:27 INF [RTMP] listener is closing
2026/06/02 22:33:27 INF [RTSP] listener is closing
2026/06/02 22:33:27 INF [RTSP] [conn 127.0.0.1:43150] closed: terminated
2026/06/02 22:33:27 INF [RTSP] [session f49c05f5] destroyed: terminated
2026/06/02 22:33:27 INF [RTSP] [conn 10.198.210.113:64944] closed: terminated
2026/06/02 22:33:27 INF [RTSP] [session ad59dd1a] destroyed: terminated
```

关键点：

```text
shutting down gracefully
```

说明：

```text
MediaMTX 是被正常关闭；
不是崩溃；
不是异常退出；
不是 RTSP 服务内部错误。
```

---

## 8.8 FFmpeg Broken pipe 的解释

FFmpeg 日志中出现：

```text
av_interleaved_write_frame(): Broken pipe
frame=4488 fps=20 q=-1.0 Lsize=N/A time=00:02:30.46
Exiting normally, received signal 15.
```

这次 `Broken pipe` 不能视为系统失败。

原因：

```text
timeout 到 240 秒后触发 cleanup；
cleanup 会终止 MediaMTX / FFmpeg / MPP / 检测程序；
MediaMTX 关闭后，FFmpeg 再写 RTSP socket 时会收到 Broken pipe；
随后 FFmpeg 收到 signal 15 并正常退出。
```

所以它属于：

```text
受控关闭过程中的正常连锁日志
```

而不是：

```text
推流过程中 FFmpeg 主动异常崩溃。
```

---

## 8.9 MPP 编码日志

MPP 编码器持续输出：

```text
mpp[1317787]: mpi_enc_test: chn 0 encoded frame 4588 size ...
...
mpp[1317787]: mpi_enc_test: chn 0 encoded frame 4667 size ...
```

说明：

```text
MPP 编码器在测试结束前仍在持续编码；
没有出现编码器自身崩溃；
没有出现 MPP 主动异常退出。
```

编码帧率约 20FPS，这与检测程序完整链路的实际处理速度一致。

---

## 8.10 检测程序日志

检测程序在结束前仍持续输出：

```text
rknn_run
frame=4664 ...
rknn_run
frame=4665 ...
rknn_run
frame=4666 ...
rknn_run
frame=4667 ...
```

说明：

```text
到 timeout 结束前，RKNN 推理仍在持续运行；
检测程序没有在 240 秒内自动崩溃。
```

日志中仍有 RGA COLORFILL 报错：

```text
RGA_COLORFILL fail: Invalid argument
Failed to call RockChipRga interface
```

该问题在前面 07 / 08 / 11 实验中已经反复出现，主要来自 `inference_yolo11_model()` 内部 letterbox 灰边填充流程。

当前判断：

```text
1. 它会造成日志污染；
2. 可能引入少量额外耗时；
3. 但不是本次 240 秒完整链路失败原因；
4. 因为本次完整链路在受控时长内没有自动崩溃。
```

后续可以作为优化项处理，但不影响 12 稳定性结论。

---

# 9. 12-2 资源监控结果

## 9.1 资源监控启动与结束

资源监控脚本输出：

```text
========== exp12 resource monitor ==========
out dir : output/exp12_2_full_chain_240s
duration: 240 s
interval: 5 s
start   : 2026年 06月 02日 星期二 22:29:33 CST

end     : 2026年 06月 02日 星期二 22:33:38 CST
csv     : output/exp12_2_full_chain_240s/resource_samples.csv
proc log: output/exp12_2_full_chain_240s/process_samples.log
port log: output/exp12_2_full_chain_240s/port_samples.log
latency : output/exp12_2_full_chain_240s/latency_observations.csv
```

说明：

```text
资源监控完整运行 240 秒；
采样间隔为 5 秒；
输出 CSV 和日志正常生成。
```

---

## 9.2 最后 10 条资源采样

关键采样：

```text
2026-06-02 22:32:45,192,2.60,1.46,0.74,16327852,14681920,39.8,1128.0,62.10,0.90,175708,5
2026-06-02 22:32:50,197,2.72,1.50,0.75,16327852,14685668,40.7,831.0,61.90,0.90,172480,5
2026-06-02 22:32:56,203,2.58,1.49,0.76,16327852,14685624,39.8,1113.0,62.10,0.90,172480,5
2026-06-02 22:33:01,208,2.53,1.50,0.76,16327852,14683648,39.8,1032.0,62.20,0.90,173460,5
2026-06-02 22:33:06,213,2.65,1.54,0.78,16327852,14686540,40.7,906.0,62.10,0.90,169984,5
2026-06-02 22:33:12,219,2.52,1.54,0.78,16327852,14687640,40.7,1080.0,62.10,0.90,169984,5
2026-06-02 22:33:17,224,2.40,1.53,0.78,16327852,14686504,39.8,1059.0,62.20,0.90,171564,5
2026-06-02 22:33:22,229,2.52,1.57,0.80,16327852,14681676,39.8,1329.0,62.10,0.90,175504,5
2026-06-02 22:33:28,235,2.56,1.59,0.81,16327852,14778840,38.8,756.0,0,0,0,0
2026-06-02 22:33:33,240,2.36,1.56,0.81,16327852,14779784,37.9,909.0,0,0,0,0
```

---

## 9.3 资源字段解释

关键字段说明：

```text
stream_proc_count=5：
    完整链路运行时有 5 个相关进程：
    mediamtx / ffmpeg / mpi_enc_test / sudo / v4l2_rga_rknn_detect_to_nv12_clean。

stream_proc_cpu_percent≈62%：
    这些流媒体相关进程总 CPU 占用约 62%。

stream_proc_mem_percent≈0.90%：
    相关进程总内存占用比例很低。

stream_proc_rss_kb≈170MB：
    相关进程 RSS 约 170MB。

cpu_temp_c≈39~41°C：
    CPU 温度正常，没有明显过热。

mem_available_kb≈14.6GB：
    系统可用内存非常充足。
```

---

## 9.4 为什么 235 秒后进程数变成 0？

最后两条：

```text
2026-06-02 22:33:28,235,...,stream_proc_cpu_percent=0,stream_proc_count=0
2026-06-02 22:33:33,240,...,stream_proc_cpu_percent=0,stream_proc_count=0
```

这不是异常。

原因：

```text
完整链路在 22:33:27 已被 timeout 正常结束；
资源监控脚本还继续采样到 240 秒；
因此后两条采样中已经没有流媒体相关进程。
```

这反而证明：

```text
timeout 到时后 cleanup 生效；
相关进程被清理干净；
没有残留 mediamtx / ffmpeg / mpi_enc_test 进程。
```

---

# 10. 12 实验阶段性结论

## 10.1 V4L2 裸采集结论

```text
/dev/video11 纯 V4L2 mmap 采集 7200 帧稳定通过；
持续时间约 240 秒；
平均帧率 29.994 FPS；
未出现 select timeout；
说明摄像头裸采集链路稳定。
```

## 10.2 完整链路稳定性结论

```text
完整 V4L2 + RGA + RKNN + MPP + FFmpeg + MediaMTX 链路
在 240 秒受控测试中稳定运行；
测试期间检测程序、MPP 编码器、FFmpeg 推流和 MediaMTX 服务均正常工作；
RTSP 客户端可以读取 exp11_detect_browser；
测试结束由 timeout 主动触发 cleanup，非异常崩溃。
```

## 10.3 资源占用结论

```text
完整链路运行时：
    流媒体相关进程数量约 5 个；
    总 CPU 占用约 62%；
    总内存占用约 0.90%；
    RSS 约 170MB；
    CPU 温度约 39~41°C；
    可用内存约 14.6GB。

说明当前链路在 240 秒短时运行中没有明显内存泄漏、过热或资源异常。
```

## 10.4 日志解释结论

```text
FFmpeg Broken pipe：
    本次发生在 timeout cleanup 阶段；
    属于下游 MediaMTX / socket 被关闭后的正常连锁现象；
    不作为推流失败证据。

MediaMTX shutting down gracefully：
    说明 MediaMTX 是正常关闭，不是崩溃。

RGA COLORFILL fail：
    仍然存在，主要来自推理内部 letterbox 灰边填充；
    当前不影响 240 秒稳定性结论；
    但后续可以作为日志清理和预处理优化项。
```

---

# 11. 关于端到端延迟测试的说明

12 实验原本计划做：

```text
WebRTC / RTSP / HLS 端到端延迟对比
```

计划方法：

```text
让摄像头拍手机秒表或电脑毫秒计时器；
然后在浏览器 / VLC 播放画面中读取延迟差。
```

但是本次现场不方便做该实验，因此没有填入 `latency_observations.csv` 的实际延迟数据。

因此本次文档不记录虚假的延迟数值。

当前只能给出定性结论：

```text
WebRTC：
    理论上更适合浏览器低延迟预览；
    但本次未做精确延迟测量。

RTSP TCP：
    已验证 VLC / RTSP 客户端可以稳定读取；
    适合作为工程演示和 Qt / VLC 客户端方案。

HLS：
    由 MediaMTX 自动转封装；
    适合作为浏览器兼容性备用方案；
    但通常延迟会高于 RTSP 和 WebRTC。
```

后续如果条件允许，可以单独补一个：

```text
13_stream_latency_measurement
```

专门做三种协议的端到端延迟对比。

---

# 12. 当前项目能力更新

完成 12 稳定性测试后，当前系统能力可以总结为：

```text
1. V4L2 mmap 裸采集 1280x720 NV12 可稳定达到约 30FPS；
2. V4L2 + RGA + RKNN 检测链路可持续运行；
3. 检测后 RGB 可以通过 RGA 转回 NV12；
4. MPP 可以持续进行 H.264 硬件编码；
5. FFmpeg 可以读取 H.264 FIFO 并推送 RTSP；
6. MediaMTX 可以接收 RTSP 发布流；
7. MediaMTX 可以同时提供 RTSP / HLS / WebRTC 服务；
8. VLC / RTSP 客户端可以正常拉流；
9. 完整链路 240 秒受控稳定性测试通过；
10. 系统资源占用正常，无明显过热或内存异常。
```

项目主线已经从：

```text
功能跑通
```

推进到：

```text
短时稳定运行验证
```

---

# 13. 可写入简历或面试描述的表述

可以将当前项目描述为：

```text
基于 RK3588 构建端侧 AI 实时视频分析与流媒体预览系统，完成 V4L2 mmap 摄像头采集、RGA 硬件图像格式转换、RKNN YOLO11 推理、MPP H.264 硬件编码以及 MediaMTX 多协议分发，实现 RTSP / HLS / WebRTC 预览。通过稳定性测试验证 /dev/video11 裸采集 7200 帧稳定达到 29.994FPS，完整检测编码推流链路在 240 秒受控测试中稳定运行，运行时流媒体相关进程总 CPU 占用约 62%，RSS 约 170MB，CPU 温度约 40°C。
```

面试中可以这样讲：

```text
我不是只把 RTSP / WebRTC 跑起来，而是进一步做了稳定性验证。
首先我单独测试了 /dev/video11 的 V4L2 mmap 裸采集能力，7200 帧约 240 秒稳定达到 29.994FPS，排除了摄像头裸采集不稳定的问题。
然后我用 timeout 做了 240 秒完整链路受控测试，链路包括 V4L2、RGA、RKNN、MPP、FFmpeg 和 MediaMTX，测试过程中 MediaMTX 正常发布 H264 track，RTSP 客户端可以拉流，资源监控显示总 CPU 占用约 62%、RSS 约 170MB、CPU 温度约 40°C。
最后通过日志区分了主动 cleanup 导致的 Broken pipe 和真正异常崩溃，避免误判系统稳定性。
```

---

# 14. 后续优化方向

## 14.1 单独补做端到端延迟测试

可以单独作为 13 实验：

```text
13_stream_latency_measurement
```

测试内容：

```text
WebRTC 延迟；
RTSP TCP 延迟；
HLS 延迟；
不同 VLC network-caching 参数影响；
浏览器 WebRTC 与 HLS 对比。
```

## 14.2 清理 RGA COLORFILL 报错

当前日志中仍然存在：

```text
RGA_COLORFILL fail: Invalid argument
```

后续可以尝试：

```text
1. 修改 letterbox 填充逻辑；
2. 避免调用异常的 RgaColorFill；
3. 使用 CPU memset 进行灰边填充；
4. 或者直接修改输入预处理方式，让模型输入尺寸与采集尺寸处理更干净。
```

这可以减少日志污染，并可能略微降低推理前处理开销。

## 14.3 固定 RTSP TCP 演示链路

10 / 12 都说明 RTSP TCP 更适合稳定演示。

后续可以将默认播放命令固定为：

```bash
vlc --rtsp-tcp --network-caching=300 --avcodec-hw=none rtsp://板端IP:8554/exp11_detect_browser
```

## 14.4 增加一键启动脚本

当前完整链路依赖：

```text
MediaMTX
FFmpeg
MPP
检测程序
FIFO
```

后续可以封装为：

```text
scripts/start_ai_stream.sh
scripts/stop_ai_stream.sh
scripts/status_ai_stream.sh
```

便于项目演示。

## 14.5 接入 Web 控制台或 Qt 上位机

当前已经具备浏览器预览和 RTSP 预览能力。

后续可以继续接：

```text
Qt 客户端；
Web 控制台；
远程参数配置；
模型文件管理；
检测日志管理；
录像文件下载。
```

这也可以和后续的 FTP-like 远程文件管理项目结合起来。

---

# 15. 本实验总结

12 实验完成了以下工作：

```text
1. 创建资源监控脚本；
2. 完成 V4L2 裸采集 7200 帧稳定性测试；
3. 验证 /dev/video11 裸采集 240 秒稳定，帧率 29.994FPS；
4. 修正了“182 秒自动崩溃”的误判，确认当时有人为 Ctrl+C 干扰；
5. 使用 timeout 完成完整链路 240 秒受控稳定性测试；
6. 验证 MediaMTX 正常发布 exp11_detect_browser；
7. 验证 RTSP 客户端可以读取该 path；
8. 记录完整链路运行时 CPU / 内存 / 温度 / RSS；
9. 判断 Broken pipe 属于受控 cleanup 连锁现象；
10. 明确端到端延迟本次未测，不记录虚假数据。
```

最终结论：

```text
当前 RK3588 AI 流媒体系统已经通过短时稳定性验证。
/dev/video11 裸采集稳定达到约 30FPS；
完整 V4L2 + RGA + RKNN + MPP + FFmpeg + MediaMTX 链路在 240 秒受控测试中稳定运行；
资源占用和温度正常；
项目已经具备可演示的端侧 AI 实时视频分析与多协议流媒体预览能力。
```

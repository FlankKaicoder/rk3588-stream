# 23 最终系统级稳定性与资源占用验收实验记录

> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：`23_final_stability_profile`  
> 当前阶段目标：在实验22完成最终音视频双轨 RTSP 链路后，进行 9000 帧 / 约 300 秒系统级稳定性与资源占用验收。

---

## 1. 实验背景

实验22已经完成当前项目的最终音视频实时检测推流链路：

```text
摄像头 /dev/video11
    ↓
V4L2 mmap 采集 1280x720 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
YOLO11 后处理与检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
自研 C++ 异步 MPP H.264 编码线程
    ↓
H.264 FIFO
    ↓
FFmpeg 读取 H.264 FIFO

ALSA hw:2,0
    ↓
FFmpeg 实时采集 PCM
    ↓
AAC 编码

H.264 + AAC
    ↓
FFmpeg RTSP MUX
    ↓
MediaMTX
    ↓
RTSP 双轨流
    ↓
VLC / ffprobe 验证
```

实验23不再新增功能，而是做最终验收：

```text
1. 更长时间运行最终链路；
2. 验证 9000 帧是否完整处理；
3. 验证 H.264 + AAC 双轨是否持续上线；
4. 验证异步 MPP 编码是否无失败、无丢帧；
5. 验证音频采集是否无 xrun；
6. 验证 FFmpeg / MediaMTX 是否无 broken pipe、timestamp、队列阻塞问题；
7. 同步记录 CPU / 内存 / 温度 / 频率 / 进程资源占用。
```

---

## 2. 实验目标

本实验目标：

```text
9000 帧 / 30FPS ≈ 300 秒

验收指标：
    FFPROBE_H264_AAC_OK = 1
    RGA_COLORFILL = 0
    Failed to call RockChipRga = 0
    xrun = 0
    Thread message queue blocking = 0
    Timestamps are unset = 0
    Broken pipe = 0

性能指标：
    frames = 9000
    wall_fps 接近 30FPS
    async_encoded_frames = 9000
    async_encode_failures = 0
    async_drop_frames = 0

资源指标：
    温度稳定
    内存无明显泄漏
    CPU 频率稳定
    相关进程正常退出
```

---

## 3. 新增脚本

实验23新增两个脚本：

```text
scripts/exp23_resource_monitor.sh
scripts/exp23_final_stability_300s.sh
```

### 3.1 `exp23_resource_monitor.sh`

资源监控脚本定时记录：

```text
timestamp
elapsed_s
load1 / load5 / load15
MemTotal / MemAvailable
CPU 最高温度
CPU 平均频率
流媒体相关进程 CPU%
流媒体相关进程 MEM%
流媒体相关进程 RSS
流媒体相关进程数量
端口状态
CPU governor
```

输出文件：

```text
resource_samples.csv
process_samples.log
port_samples.log
temp_freq_samples.log
```

### 3.2 `exp23_final_stability_300s.sh`

实验总控脚本负责：

```text
1. 设置 CPU governor 为 performance；
2. 清理旧的 exp21 / ffmpeg / mediamtx 进程；
3. 调用实验22脚本运行最终音视频 RTSP 链路；
4. 使用 9000 帧作为最终测试帧数；
5. 启动资源监控脚本；
6. 等待实验22链路结束；
7. 汇总 summary、ffprobe、detect result、MediaMTX 关键日志；
8. 检查真实异常行；
9. 汇总 resource_samples.csv 尾部数据；
10. 生成 final_report.txt。
```

---

## 4. 实验运行命令

```bash
cd ~/projects/rk3588_ai_stream

./scripts/exp23_final_stability_300s.sh \
  1280 \
  720 \
  30 \
  9000 \
  hw:2,0 \
  48000 \
  2 \
  exp23_final_av_rtsp_300s \
  5
```

参数含义：

| 参数 | 含义 |
|---|---|
| `1280` | 视频宽度 |
| `720` | 视频高度 |
| `30` | 目标 FPS |
| `9000` | 测试帧数 |
| `hw:2,0` | ALSA 音频采集设备 |
| `48000` | 音频采样率 |
| `2` | 音频声道数 |
| `exp23_final_av_rtsp_300s` | RTSP path |
| `5` | 资源采样间隔，单位秒 |

---

## 5. 输出目录

实验23总控目录：

```text
output/exp23_final_stability_9000f_20260610_173337
```

实验22实际运行目录：

```text
output/exp22_av_async_mpp_rtsp_9000f_20260610_173338
```

总控结果：

```text
MASTER_DIR=output/exp23_final_stability_9000f_20260610_173337
EXP22_OUT=output/exp22_av_async_mpp_rtsp_9000f_20260610_173338
EXP22_RC=0
```

说明：

```text
实验23总控脚本正常结束；
实验22最终链路脚本返回值为 0；
不是异常崩溃，也不是人为中断。
```

---

## 6. summary 结果

```text
FFPROBE_H264_AAC_OK          : 1
RGA_COLORFILL                : 0
Failed to call RockChipRga   : 0
xrun                         : 0
Thread message queue blocking: 0
Timestamps are unset         : 0
Broken pipe                  : 0
```

说明：

```text
1. ffprobe 成功识别 H.264 + AAC 双轨；
2. 未出现 YOLO letterbox 阶段 RGA_COLORFILL 异常；
3. 未出现 Failed to call RockChipRga；
4. ALSA 音频采集没有 xrun；
5. FFmpeg 没有 Thread message queue blocking；
6. FFmpeg 没有 Timestamps are unset；
7. RTSP 推流没有 Broken pipe。
```

---

## 7. ffprobe 双轨验证

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp23_final_av_rtsp_300s':
  Metadata:
    title           : No Name
  Duration: N/A, start: 0.000000, bitrate: N/A
    Stream #0:0: Video: h264 (High), yuv420p(progressive), 1280x720, 30 fps, 30 tbr, 90k tbn, 60 tbc
    Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp
```

说明 RTSP 中包含：

```text
视频轨：
    H.264 High Profile
    yuv420p
    1280x720
    30fps

音频轨：
    AAC LC
    48000Hz
    stereo
    fltp
```

---

## 8. 检测与编码结果

原始结果：

```text
frames     : 9000

async_encoded_frames : 9000
async_encode_failures: 0
async_drop_frames    : 0
async_avg_encode_ms  : 2.982
async_avg_write_ms   : 0.137
async_avg_total_ms   : 3.119

frames              : 9000
wall_fps            : 29.992
avg_model_total_ms  : 27.360
avg_total_ms        : 33.283
```

分析：

```text
1. 检测主程序完整处理 9000 帧；
2. 异步 MPP 编码线程完整编码 9000 帧；
3. 编码失败为 0；
4. 编码丢帧为 0；
5. MPP 编码平均总耗时约 3.119ms，不是瓶颈；
6. 主链路 wall_fps = 29.992，接近 30FPS；
7. 主循环平均耗时 33.283ms，基本贴合 30FPS 周期；
8. RKNN 推理整体平均耗时 27.360ms，长时间运行没有劣化。
```

30FPS 单帧周期：

```text
1000ms / 30 = 33.333ms
```

当前主循环平均耗时：

```text
33.283ms
```

说明系统在 performance governor 下可以持续贴近 30FPS。

---

## 9. MediaMTX 关键日志

```text
2026/06/10 17:33:43 INF [path exp23_final_av_rtsp_300s] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
2026/06/10 17:33:43 INF [RTSP] [session f54a76fa] is publishing to path 'exp23_final_av_rtsp_300s'
2026/06/10 17:33:44 INF [RTSP] [session 5f027198] is reading from path 'exp23_final_av_rtsp_300s', with TCP, 2 tracks (H264, MPEG-4 Audio)
2026/06/10 17:35:03 INF [RTSP] [session c58c3740] is reading from path 'exp23_final_av_rtsp_300s', with TCP, 2 tracks (H264, MPEG-4 Audio)
2026/06/10 17:38:46 INF shutting down gracefully
```

说明：

```text
1. MediaMTX 成功发布 exp23_final_av_rtsp_300s；
2. path 上线后包含 2 tracks；
3. FFmpeg 正在向该 path 推流；
4. RTSP 客户端可以读取该 path；
5. 客户端使用 TCP 读取；
6. 实验结束时 MediaMTX 是 graceful shutdown；
7. 不是异常退出。
```

---

## 10. 真实异常检查

检查结果：

```text
no real abnormal lines
```

说明实验23真实运行日志中没有出现：

```text
RGA_COLORFILL
Failed to call RockChipRga
xrun
Thread message queue blocking
Timestamps are unset
Broken pipe
```

---

## 11. 资源占用结果

### 11.1 resource_samples.csv 尾部数据

```text
2026-06-10 17:37:07,208,1.51,0.82,0.40,16327852,14643388,41.6,2076.0,49.10,0.70,140180,3
2026-06-10 17:37:12,213,1.47,0.83,0.40,16327852,14643472,41.6,2076.0,49.10,0.70,140528,3
2026-06-10 17:37:17,218,1.51,0.85,0.41,16327852,14643528,41.6,2076.0,49.30,0.70,140152,3
2026-06-10 17:37:22,223,1.47,0.85,0.41,16327852,14642668,41.6,2076.0,49.40,0.70,140412,3
2026-06-10 17:37:27,228,1.43,0.85,0.42,16327852,14641196,41.6,2076.0,49.30,0.70,140412,3
2026-06-10 17:37:33,234,1.40,0.86,0.42,16327852,14642152,41.6,2076.0,49.50,0.70,140412,3
2026-06-10 17:37:38,239,1.36,0.86,0.42,16327852,14643052,41.6,2076.0,49.40,0.70,140296,3
2026-06-10 17:37:43,244,1.33,0.86,0.43,16327852,14641220,41.6,2076.0,49.30,140296,3
2026-06-10 17:37:48,249,1.31,0.86,0.43,16327852,14642416,41.6,2076.0,49.30,0.70,140252,3
2026-06-10 17:37:53,254,1.28,0.87,0.43,16327852,14643408,41.6,2076.0,49.00,0.70,139856,3
2026-06-10 17:37:59,260,1.34,0.88,0.44,16327852,14644300,41.6,2076.0,48.90,0.70,139792,3
2026-06-10 17:38:04,265,1.31,0.89,0.45,16327852,14644272,41.6,2076.0,48.80,0.70,140044,3
2026-06-10 17:38:09,270,1.29,0.89,0.45,16327852,14642768,41.6,2076.0,48.80,0.70,140304,3
2026-06-10 17:38:14,275,1.26,0.89,0.45,16327852,14642916,41.6,2076.0,48.70,0.70,140060,3
2026-06-10 17:38:19,280,1.30,0.91,0.46,16327852,14643228,41.6,2076.0,48.80,0.70,140060,3
2026-06-10 17:38:24,285,1.43,0.95,0.48,16327852,14642408,41.6,2076.0,48.60,0.70,140060,3
2026-06-10 17:38:30,291,1.40,0.95,0.48,16327852,14642372,41.6,2076.0,48.60,0.70,140060,3
2026-06-10 17:38:35,296,1.53,0.98,0.49,16327852,14643112,41.6,2076.0,48.70,0.70,140372,3
2026-06-10 17:38:40,301,1.48,0.98,0.50,16327852,14641972,41.6,2076.0,48.80,0.70,140252,3
2026-06-10 17:38:45,306,1.45,0.98,0.50,16327852,14685132,39.8,2076.0,2.60,0.20,41624,1
```

字段含义：

```text
timestamp,
elapsed_s,
load1,
load5,
load15,
mem_total_kb,
mem_available_kb,
cpu_temp_c,
cpu_freq_avg_mhz,
stream_proc_cpu_percent,
stream_proc_mem_percent,
stream_proc_rss_kb,
stream_proc_count
```

### 11.2 资源分析

从尾部采样可见：

```text
load1 大致在 1.26 ~ 1.60；
load5 大致上升到 0.98；
load15 大致上升到 0.50；
MemTotal ≈ 16,327,852 KB；
MemAvailable ≈ 14,641,000 ~ 14,685,000 KB；
CPU 温度约 40.7℃ ~ 41.6℃；
CPU 平均频率保持 2076.0 MHz；
运行中流媒体相关进程合计 CPU 占用约 48% ~ 50%；
运行中流媒体相关进程 RSS 约 140MB；
运行中流媒体进程数量为 3。
```

最后一行：

```text
2026-06-10 17:38:45,306,...,39.8,2076.0,2.60,0.20,41624,1
```

说明实验结束后：

```text
相关进程数量从 3 降到 1；
CPU 占用降到 2.60%；
RSS 降到 41624KB；
温度下降到 39.8℃；
链路已正常收尾清理。
```

---

## 12. 稳定性判断

### 12.1 视频链路

```text
frames = 9000
wall_fps = 29.992
avg_total_ms = 33.283
```

说明：

```text
V4L2 采集、RGA 转换、RKNN 推理、画框、RGA 转回 NV12、异步 MPP 编码、FFmpeg 推流整体稳定。
```

### 12.2 编码链路

```text
async_encoded_frames = 9000
async_encode_failures = 0
async_drop_frames = 0
async_avg_total_ms = 3.119ms
```

说明：

```text
自研 MppH264Encoder 工作稳定；
异步编码线程没有丢帧；
编码耗时远小于 33ms 帧周期；
MPP 编码不是瓶颈。
```

### 12.3 音频链路

```text
Audio: aac (LC), 48000 Hz, stereo, fltp
xrun = 0
```

说明：

```text
ALSA hw:2,0 实时采集正常；
FFmpeg AAC 编码正常；
音频轨成功进入 RTSP；
采集过程中没有出现 xrun。
```

### 12.4 RTSP / MediaMTX 链路

```text
stream is available and online, 2 tracks (H264, MPEG-4 Audio)
is publishing to path 'exp23_final_av_rtsp_300s'
is reading from path 'exp23_final_av_rtsp_300s', with TCP, 2 tracks
shutting down gracefully
```

说明：

```text
FFmpeg 推流成功；
MediaMTX 发布成功；
客户端可以拉流；
实验结束后 MediaMTX 正常退出。
```

### 12.5 系统资源

```text
CPU 温度约 40.7℃ ~ 41.6℃
CPU 平均频率 2076.0MHz
MemAvailable 约 14.6GB
流媒体相关 RSS 约 140MB
```

说明：

```text
实验期间没有明显温度异常；
没有出现内存持续下降到危险范围；
CPU governor / 当前频率保持稳定；
资源占用对 RK3588 来说可接受。
```

---

## 13. 实验23最终结论

```text
实验23：通过。

在 performance governor 下，当前 RK3588 端侧 AI 音视频实时检测推流系统完成 9000 帧 / 约 300 秒最终稳定性测试。

最终链路：
    V4L2 摄像头采集
        → RGA NV12/RGB 图像转换
        → RKNN YOLO11 推理
        → YOLO11 后处理与检测框绘制
        → RGA RGB/NV12 转换
        → 自研 C++ 异步 MPP H.264 编码
        → H.264 FIFO
        → FFmpeg 读取 H.264 FIFO
        → ALSA hw:2,0 音频采集
        → FFmpeg AAC 编码
        → FFmpeg RTSP 音视频双轨封装
        → MediaMTX 发布
        → VLC / ffprobe 预览与验证

最终验证结果：
    frames = 9000
    wall_fps = 29.992
    avg_model_total_ms = 27.360ms
    avg_total_ms = 33.283ms

    async_encoded_frames = 9000
    async_encode_failures = 0
    async_drop_frames = 0
    async_avg_total_ms = 3.119ms

    ffprobe:
        Video: H.264 High Profile, 1280x720, 30fps
        Audio: AAC LC, 48000Hz, stereo

    MediaMTX:
        stream is available and online, 2 tracks (H264, MPEG-4 Audio)

    异常检查:
        RGA_COLORFILL = 0
        Failed to call RockChipRga = 0
        xrun = 0
        Thread message queue blocking = 0
        Timestamps are unset = 0
        Broken pipe = 0

    资源状态:
        CPU 温度约 40.7℃ ~ 41.6℃
        CPU 平均频率约 2076.0MHz
        流媒体相关进程 CPU 合计约 49%
        流媒体相关进程 RSS 约 140MB
        MemAvailable 约 14.6GB

说明当前系统已经达到阶段性最终验收标准。
```

---

## 14. 后续收尾方向

实验23完成后，当前项目已经具备：

```text
1. 最终音视频实时检测推流链路；
2. 自研 C++ MPP H.264 编码封装；
3. 异步编码线程；
4. ALSA 实时音频采集；
5. AAC 编码；
6. FFmpeg 音视频双轨 RTSP 封装；
7. MediaMTX 发布；
8. 300 秒系统级稳定性数据；
9. 资源占用数据；
10. 可直接用于演示、项目总结、简历和面试说明的证据链。
```

后续进入：

```text
24_project_cleanup：
    工程目录清理；
    最终运行脚本整理；
    README 整理；
    docs 总目录整理；
    项目架构图整理；
    简历表述整理；
    面试问题整理。
```

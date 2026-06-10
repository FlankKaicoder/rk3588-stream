# RK3588 端侧 AI 音视频实时检测推流系统

## 1. 项目简介

本项目基于 LubanCat / RK3588 平台，实现端侧 AI 视频检测、硬件加速图像预处理、NPU 推理、硬件 H.264 编码、音频采集编码与 RTSP 双轨实时推流。

最终链路：

```text
V4L2 摄像头采集
    → RGA 图像格式转换
    → RKNN YOLO11 推理
    → 检测框绘制
    → 自研异步 MPP H.264 编码
    → FFmpeg 读取 H.264 FIFO

ALSA 音频采集
    → FFmpeg AAC 编码

H.264 + AAC
    → FFmpeg RTSP 封装
    → MediaMTX 发布
    → VLC / ffprobe 预览验证
```

---

## 2. 技术栈

```text
硬件平台：
    RK3588 / LubanCat

视频采集：
    V4L2 mmap
    /dev/video11
    1280x720 NV12

图像处理：
    RGA
    NV12 ↔ RGB888

AI 推理：
    RKNN Runtime
    YOLO11 RKNN 模型

视频编码：
    Rockchip MPP
    自研 C++ MppH264Encoder
    H.264 High Profile

音频：
    ALSA hw:2,0
    48000Hz stereo
    AAC 编码

推流：
    FFmpeg
    RTSP over TCP
    MediaMTX

工程：
    C++
    CMake
    Bash
    多线程
    FIFO
    资源监控
```

---

## 3. 最终运行方式

### 3.1 编译

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir -p build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async -j4
```

### 3.2 一键运行最终链路

```bash
cd ~/projects/rk3588_ai_stream

./scripts/run_final_av_rtsp.sh
```

默认参数：

```text
width       = 1280
height      = 720
fps         = 30
frames      = 9000
audio_dev   = hw:2,0
audio_rate  = 48000
audio_ch    = 2
stream_path = final_ai_av_rtsp
```

播放地址：

```text
rtsp://板端IP:8554/final_ai_av_rtsp
```

VLC 推荐：

```bash
vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none rtsp://板端IP:8554/final_ai_av_rtsp
```

### 3.3 检查状态

```bash
cd ~/projects/rk3588_ai_stream

./scripts/check_final_stream.sh final_ai_av_rtsp
```

### 3.4 停止推流

```bash
cd ~/projects/rk3588_ai_stream

./scripts/stop_final_stream.sh
```

---

## 4. 最终验收结果

最终 9000 帧 / 约 300 秒稳定性测试结果：

```text
frames = 9000
wall_fps = 29.992
avg_model_total_ms = 27.360ms
avg_total_ms = 33.283ms

async_encoded_frames = 9000
async_encode_failures = 0
async_drop_frames = 0
async_avg_total_ms = 3.119ms
```

ffprobe：

```text
Video: H.264 High Profile, 1280x720, 30fps
Audio: AAC LC, 48000Hz, stereo
```

MediaMTX：

```text
stream is available and online, 2 tracks (H264, MPEG-4 Audio)
```

异常检查：

```text
RGA_COLORFILL = 0
Failed to call RockChipRga = 0
xrun = 0
Thread message queue blocking = 0
Timestamps are unset = 0
Broken pipe = 0
```

资源状态：

```text
CPU 温度约 40.7℃ ~ 41.6℃
CPU 平均频率约 2076.0MHz
流媒体相关进程 CPU 合计约 49%
流媒体相关进程 RSS 约 140MB
MemAvailable 约 14.6GB
```

---

## 5. 关键优化点

### 5.1 绕开 OpenCV VideoCapture

早期 OpenCV 摄像头读取链路约 5~15FPS。  
后续改为：

```text
V4L2 mmap 原生采集 NV12
```

解决输入瓶颈。

### 5.2 使用 RGA 做格式转换

```text
NV12 → RGB888
RGB888 → NV12
```

降低 CPU 图像转换负担。

### 5.3 拆解 RKNN 推理耗时

对 `inference_yolo11_model()` 进行内部 profiling，定位：

```text
rknn_run
outputs_get
post_process
letterbox
```

并通过 Release / O3 / performance governor 优化到接近 30FPS。

### 5.4 修复 RGA_COLORFILL 日志污染

将 YOLO letterbox 灰边填充从每帧失败的 RGA imfill 改为 CPU memset，保留 RGA resize / copy。

### 5.5 自研 MPP H.264 编码封装

封装：

```cpp
MppH264Encoder
```

替代外部 `mpi_enc_test`，并接入异步编码线程。

### 5.6 异步编码线程

将 MPP 编码从检测主线程中拆出，降低主循环阻塞。

### 5.7 音视频双轨 RTSP

FFmpeg 同时读取：

```text
H.264 FIFO
ALSA hw:2,0
```

并输出：

```text
H.264 + AAC RTSP
```

---

## 6. 文档索引

完整实验文档见：

```text
docs/experiment_index.md
```

最终关键文档：

```text
docs/21_integrated_async_mpp_rtsp_summary.md
docs/22_av_async_mpp_rtsp.md
docs/23_final_stability_profile.md
```

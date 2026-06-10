# RK3588 端侧 AI 音视频实时检测推流系统项目总结

> 项目名称：RK3588 端侧 AI 音视频实时检测推流系统  
> 项目路径：`~/projects/rk3588_ai_stream`  
> 平台：LubanCat / RK3588  
> 核心链路：V4L2 + RGA + RKNN + Rockchip MPP + ALSA + AAC + FFmpeg + MediaMTX + RTSP  
> 最终验收：9000 帧 / 约 300 秒稳定性测试通过，H.264 + AAC 双轨 RTSP 正常，异常计数全 0。

---

## 1. 项目背景

本项目最初从鲁班猫官方 YOLO11 RKNN Demo 出发，目标不是单纯跑通一个模型，而是逐步构建一个完整的 RK3588 端侧 AI 音视频流媒体系统。

最初的官方 Demo 只具备：

```text
单张图片 / 视频帧
    → RKNN YOLO11 推理
    → 后处理
    → 画框
    → 输出图片或视频
```

但真实的嵌入式 AI 视频系统需要具备：

```text
真实摄像头输入
实时图像预处理
NPU 推理
检测结果绘制
硬件视频编码
网络推流
音频采集与编码
音视频双轨合流
长时间稳定运行
资源占用可观测
```

因此本项目最终扩展为：

```text
摄像头采集
    → 图像硬件预处理
    → YOLO11 RKNN 推理
    → 检测框绘制
    → 自研 MPP H.264 编码
    → 音频采集与 AAC 编码
    → RTSP 音视频双轨推流
    → VLC / ffprobe 预览与验证
```

---

## 2. 最终系统链路

最终系统链路如下：

```text
/dev/video11 摄像头
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
自研 C++ MppH264Encoder
    ↓
异步 MPP H.264 编码线程
    ↓
H.264 FIFO
    ↓
FFmpeg 读取视频流

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
VLC / ffprobe / 浏览器辅助验证
```

最终 RTSP 地址格式：

```text
rtsp://板端IP:8554/final_ai_av_rtsp
```

推荐 VLC 播放方式：

```bash
vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none rtsp://板端IP:8554/final_ai_av_rtsp
```

---

## 3. 技术栈

### 3.1 硬件平台

```text
开发板：LubanCat / RK3588
摄像头节点：/dev/video11
视频输入格式：1280x720 NV12
音频设备：hw:2,0
```

### 3.2 软件与系统模块

```text
视频采集：V4L2 mmap
图像加速：RGA
AI 推理：RKNN Runtime / YOLO11 RKNN
视频编码：Rockchip MPP H.264
音频采集：ALSA
音频编码：FFmpeg AAC
推流封装：FFmpeg RTSP
RTSP Server：MediaMTX
工程构建：CMake
开发语言：C++ / Bash
验证工具：ffprobe / VLC / resource monitor
```

---

## 4. 实验路线总览

整个项目按实验编号逐步推进：

```text
00：官方 YOLO11 RKNN Demo 基线验证
01：单图检测迁移到自有工程
02：视频文件逐帧检测迁移
03：OpenCV 摄像头检测迁移
04：摄像头链路性能剖析，定位 OpenCV VideoCapture 瓶颈
05：V4L2 mmap + RGA 实时预处理
06：V4L2 + RGA + RKNN 实时检测
07：YOLO11 推理内部性能剖析与优化
08：MPP H.264 编码录像
09：HLS 实时检测预览
10：RTSP 实时检测预览
11：WebRTC / 浏览器预览
12：端到端稳定性与资源占用评估
13~16：音频设备、PCM、AAC / Opus / G.711 编解码
17~19：实时音频、音视频封装、实时 AV RTSP
20：普通用户双轨 RTSP 稳定性与 RGA_COLORFILL 修复
21：自研 C++ MPP H.264 编码封装与异步 RTSP 推流
22：自研异步 MPP + ALSA + AAC + RTSP 双轨最终集成
23：9000 帧 / 300 秒最终系统级稳定性验收
```

---

## 5. 关键阶段总结

### 5.1 阶段一：官方 Demo 到自有工程迁移

最初验证鲁班猫官方 YOLO11 Demo 能正常运行，然后将其迁移到自己的工程中，形成：

```text
image_detect
video_detect
camera_detect
```

这个阶段解决的是：

```text
1. 官方代码能否独立迁移；
2. RKNN 模型能否加载；
3. 后处理和画框是否正常；
4. 自有 CMake 工程是否可维护；
5. 为后续 V4L2、RGA、MPP、RTSP 扩展打基础。
```

---

### 5.2 阶段二：定位 OpenCV 摄像头瓶颈

在 03 摄像头检测中，OpenCV `VideoCapture` 可以跑通，但性能很差。

通过 04 性能剖析发现：

```text
/dev/video11 是 RKISP mainpath；
原生输出格式是 NV12；
OpenCV 读取时存在隐式 NV12 → BGR 转换；
默认 4K 输入时链路只有约 5FPS；
即使设置 1280x720，也无法稳定突破输入层瓶颈。
```

因此项目路线调整为：

```text
放弃 OpenCV VideoCapture 作为最终采集链路；
改用 V4L2 mmap 原生采集 NV12；
再用 RGA 做 NV12 → RGB888。
```

这是项目的第一个关键工程转折点。

---

### 5.3 阶段三：V4L2 + RGA 输入链路

05 实验完成：

```text
/dev/video11
    → V4L2 mmap 采集 NV12
    → RGA NV12 → RGB888
```

结果证明输入预处理链路可以接近 30FPS。  
这说明摄像头硬件和 RKISP 输出本身没有问题，真正瓶颈在 OpenCV/GStreamer 封装层。

---

### 5.4 阶段四：RKNN 推理性能剖析

06 接入 RKNN 后，初始完整链路只有约 18FPS。  
07 对 `inference_yolo11_model()` 进行内部剖析，拆分出：

```text
convert_image_with_letterbox
rknn_inputs_set
rknn_run
rknn_outputs_get
post_process
rknn_outputs_release
```

进一步拆解后处理，发现：

```text
后处理 decode 占比较高；
Release / O3 编译优化非常关键；
CPU governor 需要设置 performance；
日志打印也会影响实时性判断。
```

优化后完整 V4L2 + RGA + RKNN 检测链路恢复到接近 30FPS。

---

### 5.5 阶段五：MPP H.264 编码与网络预览

08 接入 Rockchip MPP H.264 编码，先通过外部 `mpi_enc_test` 验证：

```text
NV12 文件编码
实时 V4L2 FIFO 编码
检测画框后编码
```

随后 09 / 10 / 11 逐步完成：

```text
HLS 预览
RTSP 预览
WebRTC / 浏览器预览
```

其中 RTSP over TCP 被确定为更稳定的最终方案。

---

### 5.6 阶段六：音频链路补齐

13~16 先完成音频基础能力：

```text
ALSA 声卡探测
PCM 采集与播放
AAC / Opus / G.711 编码
压缩音频解码播放
```

17~19 进一步完成：

```text
实时音频编码
文件级音视频封装
实时视频 + 实时音频 RTSP 双轨推流
```

最终确定音频设备：

```text
ALSA hw:2,0
48000Hz
stereo
```

---

### 5.7 阶段七：RGA_COLORFILL 修复

实验20中发现 YOLO letterbox 灰边填充阶段每帧出现：

```text
RGA_COLORFILL fail
Failed to call RockChipRga
```

定位到鲁班猫公共 `image_utils.c` 中的 RGA `imfill`。  
最终处理方式：

```text
YOLO 640x640 letterbox 灰边填充：
    改为 CPU memset

大图像 resize / copy：
    保留 RGA
```

修复后：

```text
RGA_COLORFILL = 0
Failed to call RockChipRga = 0
```

这个优化使后续长时间稳定性统计不再被无关错误日志污染。

---

### 5.8 阶段八：自研 MPP H.264 编码封装

实验21将外部 `mpi_enc_test` 替换为自研 C++ 封装：

```cpp
class MppH264Encoder
{
public:
    bool init(int width, int height, int fps, int bitrate);
    bool get_header(std::vector<uint8_t> &out_packet);
    bool encode(const uint8_t *nv12_data,
                size_t nv12_size,
                std::vector<uint8_t> &out_packet);
    void release();
};
```

这个阶段的意义：

```text
1. 编码逻辑进入自有 C++ 工程；
2. 不再依赖外部编码进程；
3. 后续可以统一管理编码线程、队列和帧生命周期；
4. 简历中可以合理描述 MPP 编码模块封装；
5. 为最终系统工程化收口提供基础。
```

---

### 5.9 阶段九：异步 MPP 编码线程

21-4 / 21-5 将 MPP 编码从检测主线程拆出：

```text
主线程：
    V4L2 / RGA / RKNN / 画框 / RGB→NV12 / push queue

编码线程：
    pop NV12 frame
    MPP H.264 encode
    write H.264 FIFO
```

异步化后：

```text
编码耗时不再直接阻塞检测主循环；
检测主链路更接近 30FPS；
编码线程可以独立统计 encoded / failures / drops。
```

---

### 5.10 阶段十：最终音视频双轨系统与 300 秒验收

实验22完成最终链路集成：

```text
自研异步 MPP H.264
    +
ALSA 实时音频采集
    +
AAC 编码
    +
RTSP H.264 + AAC 双轨
```

实验23完成最终验收：

```text
9000 帧 / 约 300 秒
wall_fps = 29.992
async_encoded_frames = 9000
async_encode_failures = 0
async_drop_frames = 0
```

最终证明当前系统已经具备完整演示和简历项目支撑能力。

---

## 6. 最终验收数据

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

## 7. 项目核心难点与解决方案

### 7.1 难点一：摄像头输入慢

问题：

```text
OpenCV VideoCapture 读取 /dev/video11 性能差。
```

原因：

```text
/dev/video11 原生输出 NV12；
OpenCV 读取时存在隐式格式转换和封装开销。
```

解决：

```text
改用 V4L2 mmap 原生采集 NV12；
使用 RGA 做 NV12 → RGB888。
```

---

### 7.2 难点二：推理链路无法接近 30FPS

问题：

```text
接入 RKNN 后初始完整链路约 18FPS。
```

解决：

```text
对 inference_yolo11_model() 做内部 profiling；
定位 rknn_run、post_process、letterbox 等耗时；
使用 Release / O3 / performance governor；
减少无意义日志打印。
```

结果：

```text
完整检测链路恢复到接近 30FPS。
```

---

### 7.3 难点三：MPP 编码工程化不足

问题：

```text
早期依赖外部 mpi_enc_test 编码，不利于工程封装。
```

解决：

```text
自研 MppH264Encoder；
封装 init / get_header / encode / release；
接入异步编码线程。
```

---

### 7.4 难点四：音视频双轨推流

问题：

```text
需要同时处理 H.264 视频和 ALSA 音频，并输出 RTSP 双轨。
```

解决：

```text
视频端输出 H.264 FIFO；
音频端由 FFmpeg 采集 ALSA hw:2,0；
FFmpeg 将 PCM 编码为 AAC；
FFmpeg 将 H.264 + AAC 封装为 RTSP；
MediaMTX 发布双轨。
```

---

### 7.5 难点五：长期稳定性统计容易被假异常污染

问题：

```text
RGA_COLORFILL 日志刷屏；
grep -R 扫描 FIFO 会阻塞；
summary 文件中的统计项名称会造成假阳性。
```

解决：

```text
修复 letterbox 灰边填充；
统计时只扫描原始运行日志；
避免扫描 FIFO、summary、总控日志。
```

---

## 8. 当前系统边界

当前版本已经实现：

```text
1. 720P 30FPS AI 检测；
2. H.264 + AAC 双轨 RTSP；
3. 300 秒稳定性验收；
4. 自研 MPP 编码封装；
5. 异步编码线程；
6. 资源监控和异常统计。
```

当前版本尚未重点实现：

```text
1. 多 RKNN context / 三 NPU worker 推理池；
2. 完整浏览器 Web 控制台；
3. 更长时间 24h 稳定性；
4. 自研 RTSP Server；
5. 精确端到端延迟测量；
6. 4K 输入下的完整实时检测；
7. 自训练缺陷模型替换后的最终业务效果。
```

这些可以作为后续扩展方向。

---

## 9. 可用于简历的项目价值

该项目不是简单模型部署，而是包含：

```text
底层采集：
    V4L2 mmap

硬件加速：
    RGA / RKNN / MPP

性能优化：
    profiling / Release / O3 / governor / 异步线程

音视频系统：
    ALSA / AAC / H.264 / RTSP / MediaMTX

工程能力：
    C++ 封装 / CMake / Bash 自动化 / 日志统计 / 资源监控

稳定性验证：
    9000帧 / 300秒 / 异常计数全0
```

因此简历中应该突出：

```text
端侧 AI 推理部署
多媒体采集与编码
硬件加速链路优化
多线程异步架构
流媒体双轨推流
稳定性验证数据
```

而不是只写“在 RK3588 上部署 YOLO”。

---

## 10. 一句话总结

本项目完成了一个基于 RK3588 的端侧 AI 音视频实时检测推流系统：通过 V4L2 mmap 和 RGA 替代 OpenCV 摄像头链路，使用 RKNN Runtime 完成 YOLO11 NPU 推理，封装 Rockchip MPP H.264 编码器并接入异步编码线程，同时通过 ALSA + AAC 接入实时音频，最终由 FFmpeg + MediaMTX 发布 H.264 + AAC 双轨 RTSP 流，并通过 9000 帧 / 300 秒稳定性测试验证系统可稳定接近 30FPS 运行。

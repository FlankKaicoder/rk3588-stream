# RK3588 端侧 AI 音视频实时检测、推流与同步录制系统：最终复盘与面试展示版

> 项目路径：`~/projects/rk3588_ai_stream`  
> 平台：LubanCat / RK3588  
> 实验范围：00~26  
> 核心技术栈：C++、Linux、CMake、V4L2、RGA、RKNN Runtime、YOLO11、Rockchip MPP、ALSA、AAC、FFmpeg、MediaMTX、RTSP、MP4、采集层时间戳同步  
> 文档目标：把 26 个实验整理成一个能写进简历、能在面试中完整讲清楚、且能体现工程深度的项目故事。

---

## 0. 这版总结的定位

这版不再只是“实验记录汇总”，而是面向简历和面试的最终复盘。

它要解决三个问题：

```text
1. 面试官能不能快速看懂这个项目到底做了什么？
2. 面试官能不能看到你不是只会跑 Demo，而是做了性能分析、工程拆解、系统集成和稳定性验证？
3. 你自己面试时能不能把 26 个实验讲成一个逻辑连贯的故事，而不是零散地说“我做了很多实验”？
```

因此本文档按下面的结构组织：

```text
项目一句话定位
    ↓
项目为什么要做
    ↓
一开始是什么状态
    ↓
中间遇到了哪些真实工程问题
    ↓
怎么一步步解决
    ↓
最终系统具备哪些能力
    ↓
这些能力分别体现了什么技术能力
    ↓
简历怎么写
    ↓
面试怎么讲
    ↓
哪些边界不能夸大
    ↓
后续可以怎么扩展
```

---

## 1. 项目最终一句话定位

推荐最终项目名称：

```text
基于 RK3588 的端侧 AI 音视频实时检测、推流与同步录制系统
```

一句话概括：

```text
基于 LubanCat / RK3588 平台，构建了一套端侧 AI 音视频系统：使用 V4L2 mmap 直接采集摄像头 NV12 数据，RGA 完成图像格式转换，RKNN Runtime 部署 YOLO11 模型进行实时检测，Rockchip MPP 完成 H.264 硬件编码，ALSA + AAC 接入音频，并通过 FFmpeg / MediaMTX 实现 H.264 + AAC RTSP 双轨推流；同时进一步实现基于编码端 PTS 与 V4L2 / ALSA 采集层时间戳的 H.264 + AAC MP4 本地同步录制。
```

这个名称比“实时检测推流系统”更准确，因为最终项目已经不止有推流，还包括：

```text
实时检测
实时推流
音频接入
MP4 本地录制
视频编码端 PTS
V4L2 / ALSA 采集层时间戳同步
```

---

## 2. 面试时最应该讲出来的项目主线

整个项目的主线可以概括成一句话：

```text
我不是直接跑通一个 YOLO Demo，而是从官方 Demo 出发，一步步把它改造成一个接近真实嵌入式产品链路的端侧 AI 音视频系统。
```

更完整的故事逻辑是：

```text
第一阶段：先验证官方 YOLO11 RKNN Demo 能在 RK3588 上运行。
第二阶段：把官方 Demo 迁移到自己的工程，完成单图、视频文件、摄像头检测。
第三阶段：发现 OpenCV VideoCapture 读取 RKISP 摄像头性能差，开始做性能剖析。
第四阶段：放弃 OpenCV 摄像头采集，改用 V4L2 mmap 直接采集 NV12，并用 RGA 做硬件格式转换。
第五阶段：接入 RKNN 后发现推理链路不够快，于是拆解 inference_yolo11_model 内部耗时，做 Release/O3/performance/log 优化。
第六阶段：检测链路接近 30FPS 后，接入 Rockchip MPP H.264 硬件编码，实现检测画面录像和流媒体预览。
第七阶段：从 HLS、RTSP、WebRTC 逐步验证远程预览链路，并做资源与稳定性测试。
第八阶段：补齐音频采集、音频编码、音视频双轨 RTSP 推流。
第九阶段：把外部 mpi_enc_test 替换为自研 C++ MppH264Encoder，并设计异步编码线程。
第十阶段：补齐编码端 PTS、自研 MP4 muxer、H.264 + AAC 双轨 MP4 本地录像。
第十一阶段：进一步用 V4L2 / ALSA 采集层 timestamp 替代进程启动时间估算，实现更可靠的音视频同步录制基础。
```

这就是项目的完整故事。

面试时不要说成：

```text
我做了 26 个实验。
```

而应该说成：

```text
我围绕一个端侧 AI 音视频系统，从 Demo 迁移、输入链路优化、推理 profiling、硬件编码、音视频推流、本地录像、时间戳同步和稳定性验证几个阶段逐步完成了系统闭环。
```

---

## 3. 最终系统能力总览

| 能力模块 | 是否完成 | 体现的能力 |
|---|---:|---|
| 官方 YOLO11 RKNN Demo 验证 | 完成 | 理解 RKNN Demo、模型加载、后处理流程 |
| 自有 C++ 工程迁移 | 完成 | 工程组织、CMake、第三方代码整合 |
| 单图 / 视频 / 摄像头检测 | 完成 | 基础 AI 推理链路迁移 |
| OpenCV 摄像头瓶颈定位 | 完成 | 性能剖析、瓶颈分析 |
| V4L2 mmap 采集 | 完成 | Linux 多媒体设备编程 |
| RGA NV12/RGB888 双向转换 | 完成 | 硬件图像加速、像素格式理解 |
| RKNN YOLO11 实时检测 | 完成 | 端侧 NPU 推理部署 |
| 推理内部 profiling | 完成 | 分阶段计时、性能优化方法论 |
| Rockchip MPP H.264 编码 | 完成 | 硬件编码、H.264 码流理解 |
| HLS / RTSP / WebRTC 预览 | 完成 | 流媒体链路搭建与排查 |
| 资源与稳定性评估 | 完成 | 长时间运行验证、日志分析 |
| ALSA 音频采集与播放 | 完成 | Linux 音频设备编程 |
| AAC / Opus / G.711 编解码 | 完成 | 音频编码格式理解 |
| H.264 + AAC RTSP 双轨推流 | 完成 | 音视频实时合流 |
| RGA_COLORFILL 问题修复 | 完成 | 第三方库问题定位、工程化修复 |
| 自研 C++ MppH264Encoder | 完成 | MPP API 封装、模块设计 |
| 异步编码线程 | 完成 | 生产者-消费者队列、多线程解耦 |
| MPP 编码端 PTS | 完成 | 时间戳、编码 packet 元数据 |
| 自研 video-only MP4 muxer | 完成 | libavformat、Annex-B/AVCC、SPS/PPS、PTS/DTS |
| H.264 + AAC 双轨 MP4 录像 | 完成 | 本地音视频录制能力 |
| V4L2 / ALSA 采集层时间戳同步 | 完成 | 音视频同步、monotonic 时间轴 |

---

## 4. 最终系统的三条产品级能力

最终系统不是单纯“能检测”，而是形成了三条能力主线。

---

### 4.1 能力一：实时 AI 检测 + RTSP 音视频双轨推流

这是项目最直观的演示能力。

```text
/dev/video11 摄像头
    ↓
V4L2 mmap 采集 1280×720 NV12
    ↓
RGA：NV12 → RGB888
    ↓
RKNN Runtime：YOLO11 推理
    ↓
YOLO11 后处理 + 检测框绘制
    ↓
RGA：RGB888 → NV12
    ↓
自研 C++ MppH264Encoder
    ↓
异步 MPP H.264 编码线程
    ↓
H.264 FIFO
    ↓
FFmpeg 读取 H.264 FIFO

ALSA hw:2,0
    ↓
FFmpeg 采集 PCM
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
VLC / ffprobe 预览验证
```

这条链路在简历中体现的是：

```text
嵌入式 Linux 摄像头采集 + 端侧 AI 推理 + 硬件编码 + 音视频实时推流的完整系统集成能力。
```

---

### 4.2 能力二：MP4 本地录制

这是上一版总结中必须重点强化的能力。

项目后期不仅实现了实时 RTSP 推流，还实现了本地 MP4 文件录像。这个能力非常重要，因为它说明系统不只是“实时看画面”，还可以做：

```text
历史录像保存
检测结果留存
离线回放
后续远程文件管理
事故追溯
数据采集
```

#### 4.2.1 video-only MP4 录像

实验24 完成了基于编码端 PTS 的 video-only MP4 录像。

```text
V4L2 摄像头采集
    ↓
RGA 预处理
    ↓
RKNN YOLO11 检测
    ↓
检测框绘制
    ↓
RGA 转回 NV12
    ↓
异步 MPP H.264 编码
    ↓
H.264 裸流 + PTS CSV
    ↓
自研 libavformat MP4 muxer
    ↓
video-only MP4
```

这里的重点不是“生成了 MP4 文件”，而是：

```text
不是让 FFmpeg 根据 framerate 猜时间戳，
而是工程侧显式记录每个编码 packet 的 PTS，
再由自研 muxer 写入 MP4 容器。
```

自研 muxer 主要做了：

```text
1. 读取 H.264 裸流；
2. 读取 PTS CSV；
3. 根据 packet_size 切分每个 H.264 packet；
4. 解析 SPS / PPS；
5. 构造 MP4 avcC extradata；
6. 将 Annex-B H.264 转换为 AVCC length-prefixed sample；
7. 显式设置 AVPacket.pts；
8. 显式设置 AVPacket.dts；
9. 显式设置 AVPacket.duration；
10. 标记关键帧；
11. 通过 ffprobe packet 级验证输出 MP4 的 PTS 是否正确。
```

这部分在面试中很有深度，因为它能引出：

```text
H.264 裸流和 MP4 容器的区别
Annex-B 和 AVCC 的区别
SPS / PPS 为什么放 extradata
PTS / DTS / duration 的作用
为什么裸流直接封装会出现 timestamp unset warning
为什么工程侧要维护 packet metadata
```

#### 4.2.2 H.264 + AAC 双轨 MP4 本地录像

实验25 进一步把 video-only MP4 升级成 H.264 + AAC 双轨 MP4。

```text
视频侧：
V4L2 + RGA + RKNN + MPP
    ↓
H.264 + PTS CSV
    ↓
自研 video-only MP4 muxer
    ↓
video-only MP4

音频侧：
ALSA hw:2,0
    ↓
FFmpeg 采集 PCM
    ↓
AAC 编码
    ↓
audio.m4a

最终：
video-only MP4 + audio.m4a
    ↓
FFmpeg copy mux
    ↓
H.264 + AAC 双轨 MP4
```

这里需要准确表达边界：

```text
自研的是视频 MP4 muxer；
最终 H.264 + AAC 双轨 MP4 合成使用 FFmpeg copy mux 完成；
不是完全自研音视频 muxer。
```

面试中这样说最稳妥：

```text
我实现了基于 libavformat 的 H.264 视频 MP4 muxer，完成了 Annex-B 到 AVCC 转换、SPS/PPS extradata 构造和显式 PTS/DTS/duration 写入；在此基础上使用 FFmpeg copy mux 接入 AAC 音频轨，形成 H.264 + AAC 双轨 MP4 本地录像。
```

---

### 4.3 能力三：基于 V4L2 / ALSA 采集层时间戳的音视频同步录制

这是项目最后阶段最有工程深度的能力之一。

实验25 的同步方式主要基于：

```text
音频进程启动时间
视频进程启动时间
audio_lead_sec
```

这个方式可以让音视频时长大致对齐，但有一个问题：

```text
它不能严格证明第一帧视频和第一段音频在真实采集时间轴上对齐。
```

因此实验26 将同步依据升级为采集层 timestamp。

#### 4.3.1 视频侧时间戳

旧方案：

```cpp
pts_us = frame_id * 1000000 / fps;
```

这个方案的问题是：

```text
如果程序实际处理速度低于 30FPS，或者 V4L2 sequence 出现跳帧，
按 frame_id / fps 生成的 PTS 会把真实时间轴压短。
```

新方案：

```cpp
video_sync_pts_us = (current_v4l2_ts_ns - first_video_v4l2_ts_ns) / 1000;
```

也就是：

```text
视频 PTS 直接由 V4L2 buffer timestamp 派生。
```

这样做的意义是：

```text
MP4 里的视频时间轴代表真实采集时间，而不是程序假设的固定帧率。
```

#### 4.3.2 音频侧时间戳

音频侧通过 ALSA htimestamp 估算音频流起点：

```text
audio_stream_start_est_ns = alsa_htstamp_ns - total_frames / sample_rate
```

然后和视频第一帧 V4L2 timestamp 对齐：

```text
audio_trim_s = first_video_v4l2_ts_ns - audio_stream_start_est_ns
```

最终裁剪音频：

```bash
atrim=start=${audio_trim_s}:duration=${video_duration}
asetpts=PTS-STARTPTS
```

再编码 AAC，与视频 MP4 合成双轨 MP4。

#### 4.3.3 正确理解“唇音同步”

这个项目中的“唇音同步”应该严谨表述为：

```text
基于 V4L2 / ALSA 采集层 monotonic timestamp，构建视频帧 PTS 与音频裁剪起点的统一时间轴，从工程时间戳层面保证音视频起点和持续时间对齐。
```

不要夸大成：

```text
我通过人工拍手/声画标定证明了绝对唇音同步。
```

更严谨的说法是：

```text
我实现的是采集层时间戳驱动的音视频同步录制基础，相比进程启动时间估算更可靠。后续如果要做绝对唇音同步验证，可以通过拍手、LED+蜂鸣器、音画脉冲等方式做外部 ground truth 标定。
```

这句话很重要，因为它能体现你对工程边界的清醒认识。

---

## 5. 按阶段复盘：26 个实验如何串成一个完整项目

---

### 5.1 阶段一：从官方 Demo 到自己的 C++ 工程

对应实验：00、01、02、03。

最初状态：

```text
鲁班猫官方 YOLO11 RKNN Demo 能跑，
但它只是官方示例，不适合作为简历项目，也不方便继续扩展摄像头、编码、推流、音频和录像。
```

所以先做三步迁移：

```text
00：确认官方 Demo 在当前 RK3588 板子上可运行。
01：迁移单图检测到自己的 rk3588_ai_stream 工程。
02：迁移视频文件逐帧检测。
03：迁移摄像头检测。
```

这一阶段体现的能力：

```text
1. 能读懂官方工程结构；
2. 能拆出可复用的 RKNN 推理和 YOLO11 后处理代码；
3. 能搭建自己的 CMake 工程；
4. 能把 Demo 迁移为可持续扩展的项目骨架。
```

面试表达：

```text
我没有直接在官方目录里改，而是把官方 YOLO11 Demo 迁移到自己的工程中，形成 image_detect、video_detect、camera_detect 三个目标，这样后续接 V4L2、RGA、MPP 和流媒体模块时工程结构比较清晰。
```

---

### 5.2 阶段二：发现 OpenCV 摄像头链路瓶颈，转向 V4L2 + RGA

对应实验：04、05。

最初摄像头链路是：

```text
OpenCV VideoCapture
    ↓
BGR 图像
    ↓
resize / cvtColor
    ↓
RKNN 推理
```

但是性能不理想。通过 04 profiling 发现：

```text
1. /dev/video11 是 RKISP mainpath；
2. 原生输出格式是 NV12；
3. OpenCV VideoCapture 存在隐式格式转换和封装开销；
4. 默认 4K 输入时只有约 5FPS；
5. 即使设置 1280×720，也不是最优路径。
```

所以项目路线调整为：

```text
放弃 OpenCV VideoCapture 作为最终采集路径，
改用 V4L2 mmap 直接采集 NV12，
再用 RGA 做 NV12 → RGB888。
```

05 的链路：

```text
/dev/video11
    ↓
V4L2 mmap 采集 1280×720 NV12
    ↓
RGA NV12 → RGB888
    ↓
统计 select / dqbuf / rga / qbuf / total
```

这一阶段体现的能力：

```text
1. 能用 profiling 定位瓶颈，而不是盲目优化；
2. 理解 RKISP 摄像头节点和普通 USB 摄像头的区别；
3. 理解 NV12、RGB888 等像素格式；
4. 能使用 V4L2 mmap 操作 Linux 摄像头设备；
5. 能使用 RGA 替代 CPU / OpenCV 图像转换。
```

面试表达：

```text
我一开始用 OpenCV VideoCapture 跑摄像头检测，但 profiling 后发现输入端是主要瓶颈。因为 /dev/video11 是 RKISP mainpath，原生输出 NV12，OpenCV 会引入隐式转换，所以我改用 V4L2 mmap 直接采集 NV12，再用 RGA 做 NV12 到 RGB 的硬件转换，输入链路接近 30FPS。
```

---

### 5.3 阶段三：接入 RKNN 后做推理链路 profiling 与优化

对应实验：06、07。

06 接入 RKNN 后，完整链路变成：

```text
V4L2 mmap
    ↓
RGA NV12 → RGB888
    ↓
inference_yolo11_model()
    ↓
画框
    ↓
保存快照 / 统计性能
```

初始完整检测链路不是 30FPS，而是大约十几 FPS。于是 07 把 `inference_yolo11_model()` 拆开：

```text
convert_image_with_letterbox
rknn_inputs_set
rknn_run
rknn_outputs_get
post_process
rknn_outputs_release
```

进一步发现：

```text
瓶颈不只有 rknn_run，
post_process、letterbox、编译优化、CPU governor、日志输出也会影响最终 FPS。
```

优化手段包括：

```text
1. Release 编译；
2. -O3 优化；
3. CPU governor 切到 performance；
4. 精简每帧日志；
5. 定位 YOLO11 后处理 decode / NMS 耗时；
6. 区分 rknn_run 真正耗时和 inference_yolo11_model 总耗时。
```

这一阶段体现的能力：

```text
1. 能做函数级 profiling；
2. 能区分 NPU 推理耗时和 CPU 后处理耗时；
3. 能分析编译选项和系统性能模式对实时性的影响；
4. 能用数据驱动优化，而不是凭感觉改代码。
```

面试表达：

```text
接入 RKNN 后，我没有简单认为慢就是 NPU 慢，而是把 inference_yolo11_model 拆成 letterbox、inputs_set、rknn_run、outputs_get、post_process 等阶段统计。结果发现 rknn_run 和后处理都是主要耗时。后续通过 Release/O3、performance governor 和日志精简，把完整检测链路优化到接近 30FPS。
```

---

### 5.4 阶段四：接入 MPP H.264 编码，实现检测画面编码和网络预览

对应实验：08、09、10、11、12。

检测链路接近实时后，下一步是把检测画面编码成视频流。

08 先用 MPP 验证：

```text
NV12 → MPP H.264 → H.264 / MP4
```

然后逐步接到实时检测：

```text
V4L2 采集
    ↓
RGA
    ↓
RKNN 检测
    ↓
画框
    ↓
RGA RGB → NV12
    ↓
MPP H.264 编码
```

09、10、11 分别验证：

```text
HLS 网络预览
RTSP 网络预览
WebRTC / 浏览器预览
```

12 做稳定性与资源评估。

这一阶段体现的能力：

```text
1. 理解 H.264 编码输入必须是编码器支持的像素格式；
2. 理解为什么画框后还要 RGB → NV12；
3. 能使用 MPP 硬件编码替代 OpenCV VideoWriter；
4. 能搭建 HLS / RTSP / WebRTC 流媒体预览链路；
5. 能使用 MediaMTX、FFmpeg、ffprobe、VLC 做验证和排查。
```

面试表达：

```text
检测画面不能直接用于推流，所以我把画框后的 RGB 图像再通过 RGA 转回 NV12，送到 Rockchip MPP H.264 编码器。之后分别验证了 HLS、RTSP 和 WebRTC 预览，最后选择 RTSP over TCP 作为相对稳定的实时预览方案。
```

---

### 5.5 阶段五：补齐音频链路，实现 H.264 + AAC 双轨推流

对应实验：13、14、15、16、17、18、19、20、22。

视频链路完成后，项目还缺音频。

13~16 先独立验证音频基础能力：

```text
ALSA 设备探测
PCM 采集
PCM 播放
AAC 编码 / 解码
Opus 编码 / 解码
G.711 编码 / 解码
```

17~19 再推进到实时音频和音视频合流：

```text
ALSA hw:2,0
    ↓
FFmpeg 采集 PCM
    ↓
AAC 编码
    ↓
RTSP 音频轨
```

最终和视频 H.264 合成：

```text
H.264 视频轨 + AAC 音频轨
    ↓
RTSP 双轨流
```

20 修复并验证普通用户双轨稳定性，同时解决 RGA_COLORFILL 日志刷屏问题。

这一阶段体现的能力：

```text
1. 能操作 ALSA 声卡；
2. 理解 PCM、采样率、声道、采样格式；
3. 理解 AAC / Opus / G.711 的用途；
4. 能用 FFmpeg 将 ALSA 实时音频编码为 AAC；
5. 能将 H.264 视频和 AAC 音频封装为 RTSP 双轨流；
6. 能排查 xrun、timestamp unset、queue block 等流媒体问题。
```

面试表达：

```text
视频推流完成后，我又补齐了音频链路。先通过 ALSA 验证 ES8388 codec 的采集和播放，再用 FFmpeg 做 AAC、Opus、G.711 编解码验证，最后把 ALSA 实时音频编码为 AAC，与 H.264 视频一起封装成 RTSP 双轨流。
```

---

### 5.6 阶段六：从外部 mpi_enc_test 升级为自研 MPP 编码模块和异步线程

对应实验：21、22。

前面 MPP 编码一开始依赖外部 `mpi_enc_test`，工程上不够完整。

问题是：

```text
1. 编码逻辑不在自己的主程序内；
2. 线程模型和队列不可控；
3. 后续无法方便维护 PTS；
4. 简历里不好写成自研模块；
5. 系统架构更像脚本拼接，而不是 C++ 工程闭环。
```

所以实验21 封装了：

```cpp
class MppH264Encoder
{
public:
    bool init(int width, int height, int fps, int bitrate);
    bool get_header(std::vector<uint8_t>& out_packet);
    bool encode(const uint8_t* nv12_data,
                size_t nv12_size,
                std::vector<uint8_t>& out_packet);
    void release();
};
```

并逐步验证：

```text
NV12 文件 → 自研 MPP → H.264
V4L2 实时采集 → 自研 MPP → H.264
V4L2 + RGA + RKNN + 画框 → 串行 MPP 编码
V4L2 + RGA + RKNN + 画框 → 异步 MPP 编码线程
异步 MPP → H.264 FIFO → FFmpeg → MediaMTX → RTSP
```

22 再把音频接回，形成：

```text
自研异步 MPP H.264 视频编码
    +
ALSA 音频采集 + AAC 编码
    +
RTSP 双轨推流
```

这一阶段体现的能力：

```text
1. 能读 MPP 示例并封装成自己的 C++ 类；
2. 理解 MPP init / cfg / frame / packet / header / release 流程；
3. 能设计异步编码线程；
4. 能用队列解耦检测主循环和编码耗时；
5. 能从脚本拼接升级到工程内部模块化实现。
```

面试表达：

```text
前面编码阶段我先用 mpi_enc_test 验证 MPP 能力，但后面为了工程完整性，我自己封装了 MppH264Encoder 类，并设计了异步编码线程。主线程负责采集、RGA、RKNN 和画框，编码线程从队列取 NV12 帧送入 MPP，这样检测主循环不会被编码阻塞。
```

---

### 5.7 阶段七：补齐 PTS、MP4 mux、本地双轨录像和采集层同步

对应实验：23、24、25、26。

这是项目最后收尾阶段，也是最容易体现深度的阶段。

#### 5.7.1 实验23：MPP 编码端 PTS

在实验21/22中，编码输出只有：

```text
H.264 packet bytes
```

但没有严格的：

```text
frame_id
pts
dts
packet_size
queue_delay
encode_ms
```

这对 MP4 录像和同步是不够的。

所以实验23给异步编码帧增加：

```text
frame_id
pts_us
enqueue_ts_us
nv12 data
```

编码前：

```cpp
mpp_frame_set_pts(frame, pts_us);
```

编码后：

```cpp
mpp_packet_get_pts(packet);
mpp_packet_get_dts(packet);
```

并输出 PTS CSV。

#### 5.7.2 实验24：自研 video-only MP4 muxer

实验24 使用实验23输出的：

```text
H.264 裸流 + PTS CSV
```

生成标准 MP4。

关键点：

```text
不是让 FFmpeg 猜时间戳，
而是由工程侧显式写入 AVPacket.pts / dts / duration。
```

#### 5.7.3 实验25：H.264 + AAC 双轨 MP4 本地录像

实验25 在 video-only MP4 的基础上增加音频：

```text
ALSA 采集 → AAC 编码 → audio.m4a
```

再和视频合成：

```text
video-only MP4 + audio.m4a → H.264 + AAC 双轨 MP4
```

这标志着系统具备了：

```text
本地音视频录像能力。
```

#### 5.7.4 实验26：V4L2 / ALSA 采集层时间戳同步

实验26 进一步解决：

```text
音视频同步依据不能只靠进程启动时间差。
```

视频侧改为：

```text
V4L2 buffer.timestamp → video_sync_pts_us → MPP packet PTS → MP4 video PTS
```

音频侧改为：

```text
ALSA htimestamp → 估算 audio_stream_start → 与 first_video_v4l2_ts_ns 对齐 → atrim 裁剪音频
```

最终实现：

```text
基于采集层 monotonic timestamp 的 H.264 + AAC MP4 同步录制。
```

这一阶段体现的能力：

```text
1. 理解裸 H.264 packet 和容器 packet 的区别；
2. 理解 PTS / DTS / duration；
3. 理解 SPS / PPS / avcC / Annex-B / AVCC；
4. 能使用 libavformat 做 MP4 mux；
5. 能把视频编码端 PTS 与采集层 timestamp 关联起来；
6. 能用 ALSA htimestamp 估算音频流起点；
7. 能构建音视频统一时间轴；
8. 对“唇音同步”的工程边界有清晰认识。
```

面试表达：

```text
后期我补齐了时间戳和本地录像能力。先在 MPP 编码端通过 mpp_frame_set_pts 写入输入 PTS，并用 mpp_packet_get_pts 回读验证，然后基于 H.264 裸流和 PTS CSV 实现了 video-only MP4 muxer。之后接入 AAC 音频形成 H.264 + AAC 双轨 MP4。最后我又把视频 PTS 从 frame_id/fps 改成 V4L2 buffer timestamp 派生，并用 ALSA htimestamp 估算音频起点，对音频做 timestamp 裁剪，从工程时间戳层面实现音视频同步录制。
```

---

## 6. 项目中最能体现能力的 8 个技术点

---

### 6.1 不是跑 Demo，而是完成工程迁移

体现点：

```text
官方 YOLO11 Demo → 自己的 C++ / CMake 工程 → 多个实验 target → 后续可扩展架构
```

面试官能看到：

```text
你不是只会执行官方命令，而是能把参考代码拆出来，迁移成自己的工程。
```

---

### 6.2 用 profiling 驱动路线调整

体现点：

```text
OpenCV VideoCapture 慢 → 不是盲目加线程 → 先分析瓶颈 → 转向 V4L2 mmap + RGA
```

面试官能看到：

```text
你有性能分析思维，不是遇到慢就猜。
```

---

### 6.3 理解 RK3588 多媒体硬件链路

体现点：

```text
RKISP 输出 NV12
RGA 做图像格式转换
RKNN 做 NPU 推理
MPP 做 H.264 编码
ALSA 做音频采集
```

面试官能看到：

```text
你理解嵌入式 SoC 中不同硬件模块的分工。
```

---

### 6.4 对 RKNN 推理链路做内部拆解

体现点：

```text
inference_yolo11_model 不是黑盒
拆成 preprocess / inputs_set / rknn_run / outputs_get / post_process / release
```

面试官能看到：

```text
你能区分 NPU 推理耗时和 CPU 前后处理耗时。
```

---

### 6.5 封装自研 MPP 编码模块

体现点：

```text
外部 mpi_enc_test → 自研 MppH264Encoder → 异步编码线程
```

面试官能看到：

```text
你能把系统工具验证过的能力沉淀成自己的 C++ 模块。
```

---

### 6.6 音视频双轨实时推流

体现点：

```text
H.264 视频轨 + AAC 音频轨 → RTSP MUX → MediaMTX → VLC / ffprobe
```

面试官能看到：

```text
你不只是做视觉推理，还做了音视频系统集成。
```

---

### 6.7 MP4 本地录制与容器时间戳

体现点：

```text
H.264 裸流 + PTS CSV → 自研 video MP4 muxer → H.264 + AAC 双轨 MP4
```

面试官能看到：

```text
你理解码流、容器、时间戳，不只是调用 ffmpeg 命令。
```

---

### 6.8 V4L2 / ALSA 采集层时间戳同步

体现点：

```text
frame_id/fps PTS → V4L2 timestamp 派生 PTS
进程启动时间估算 → ALSA htimestamp 音频起点估算
```

面试官能看到：

```text
你知道音视频同步不能只看文件时长，而要关心采集层时间轴。
```

---

## 7. 项目关键问题与解决方案：面试可重点讲

---

### 7.1 问题一：OpenCV 摄像头采集为什么慢？

现象：

```text
OpenCV VideoCapture 摄像头链路 FPS 很低。
```

分析：

```text
/dev/video11 是 RKISP mainpath，原生输出 NV12；
OpenCV 读取时会引入隐式格式转换和额外封装；
在 RK3588 这种硬件链路上，不应该把 OpenCV 当作最终采集层。
```

解决：

```text
V4L2 mmap 直接采集 NV12，RGA 完成 NV12 → RGB888。
```

能力体现：

```text
Linux 多媒体设备编程 + 性能剖析 + 硬件加速路径选择。
```

---

### 7.2 问题二：完整检测链路为什么不是 30FPS？

现象：

```text
V4L2 + RGA 输入链路接近 30FPS，接入 RKNN 后完整检测链路下降。
```

分析：

```text
inference_yolo11_model 内部包含多个阶段，不能简单认为都是 rknn_run 慢。
```

解决：

```text
拆解 preprocess、rknn_inputs_set、rknn_run、outputs_get、post_process、release；
通过 Release/O3、performance governor、日志精简和后处理分析优化。
```

能力体现：

```text
端侧 AI 性能剖析能力。
```

---

### 7.3 问题三：为什么要自研 MPP 编码封装？

现象：

```text
早期依赖外部 mpi_enc_test 编码。
```

问题：

```text
外部工具不能很好地控制线程、队列、PTS、异常统计和资源释放。
```

解决：

```text
封装 MppH264Encoder，实现 init、get_header、encode、release；
设计异步编码线程，主线程和编码线程解耦。
```

能力体现：

```text
硬件编码 API 封装 + 多线程工程设计。
```

---

### 7.4 问题四：为什么裸 H.264 不能直接当最终录像？

现象：

```text
H.264 裸流可以播放，但没有容器时间戳。
```

问题：

```text
直接用 FFmpeg 猜帧率封装，会出现 timestamp unset warning；
后续音视频同步、历史回放、packet 对齐都不可靠。
```

解决：

```text
编码端输出 PTS CSV；
自研 libavformat MP4 muxer；
显式写入 AVPacket.pts / dts / duration。
```

能力体现：

```text
码流与容器理解，时间戳体系理解。
```

---

### 7.5 问题五：为什么实验26还要做采集层时间戳同步？

现象：

```text
实验25 已经能生成 H.264 + AAC 双轨 MP4，但同步依据主要是进程启动时间差。
```

问题：

```text
进程启动时间不是第一帧视频真实采集时间，也不是第一段音频真实采集时间。
```

解决：

```text
视频侧使用 V4L2 buffer.timestamp 派生 video PTS；
音频侧使用 ALSA htimestamp 估算 audio stream start；
二者统一到 monotonic 时间轴后对音频做裁剪。
```

能力体现：

```text
音视频同步和采集层时间戳理解。
```

---

## 8. 简历推荐写法

---

### 8.1 简历项目名称

最推荐：

```text
基于 RK3588 的端侧 AI 音视频实时检测、推流与同步录制系统
```

如果简历空间不够：

```text
RK3588 端侧 AI 音视频检测与流媒体系统
```

偏嵌入式 AI 岗位：

```text
基于 RK3588 NPU 的端侧视觉检测与音视频流媒体系统
```

偏音视频岗位：

```text
基于 RK3588 的 H.264/AAC 实时推流与 MP4 同步录制系统
```

---

### 8.2 简历技术栈

```text
C++、Linux、CMake、V4L2、RGA、RKNN Runtime、YOLO11、Rockchip MPP、ALSA、AAC、FFmpeg、MediaMTX、RTSP、MP4、H.264、时间戳同步
```

---

### 8.3 简历完整版本

```text
基于 RK3588 的端侧 AI 音视频实时检测、推流与同步录制系统
技术栈：C++、Linux、CMake、V4L2、RGA、RKNN Runtime、YOLO11、Rockchip MPP、ALSA、AAC、FFmpeg、MediaMTX、RTSP、MP4

- 基于 LubanCat / RK3588 平台搭建端侧 AI 音视频系统，完成 YOLO11 RKNN 模型在板端的加载、推理、后处理与检测结果绘制，并将官方 Demo 迁移为自有 C++ / CMake 工程。
- 针对 OpenCV VideoCapture 读取 RKISP 摄像头性能不足的问题，改用 V4L2 mmap 直接采集 /dev/video11 的 1280×720 NV12 数据，并通过 RGA 完成 NV12/RGB888 双向转换，提升输入链路实时性。
- 对 RKNN 推理链路进行分阶段 profiling，拆解 letterbox、rknn_run、outputs_get、post_process 等耗时，并通过 Release/O3、performance governor 与日志精简将完整检测链路优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块，实现 MppH264Encoder 的初始化、SPS/PPS 获取、NV12 帧编码与资源释放，并设计异步编码线程解耦检测主循环和硬件编码流程。
- 接入 ALSA hw:2,0 音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流，并使用 ffprobe / VLC 完成音视频预览与稳定性验证。
- 实现基于编码端 PTS 的 H.264 video-only MP4 录像，完成 H.264 Annex-B 到 AVCC 转换、SPS/PPS avcC extradata 构造、AVPacket PTS/DTS/duration 写入和 packet 级 ffprobe 验证。
- 在 video-only MP4 基础上接入 AAC 音频轨，形成 H.264 + AAC 双轨 MP4 本地录像；进一步使用 V4L2 buffer timestamp 与 ALSA htimestamp 构建统一 monotonic 时间轴，实现基于采集层时间戳的音视频同步录制基础。
```

---

### 8.4 简历精简版本

```text
基于 RK3588 的端侧 AI 音视频实时检测、推流与同步录制系统
技术栈：C++、Linux、V4L2、RGA、RKNN、MPP、ALSA、FFmpeg、MediaMTX、RTSP、MP4

- 基于 RK3588 完成 YOLO11 RKNN 端侧部署，构建 V4L2 mmap + RGA + RKNN 实时检测链路，绕开 OpenCV 摄像头输入瓶颈。
- 对推理链路进行 profiling，拆解 rknn_run、post_process、letterbox 等耗时，通过 Release/O3、performance governor 与日志精简优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块，设计异步编码线程，将检测帧编码为 H.264 码流并输出至 FIFO。
- 接入 ALSA 音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流。
- 实现基于 PTS 的 video-only MP4 muxer，并进一步生成 H.264 + AAC 双轨 MP4；使用 V4L2 / ALSA 采集层 timestamp 完成音视频同步录制基础。
```

---

### 8.5 如果简历只能放 4 条 bullet

```text
- 基于 RK3588 构建 V4L2 + RGA + RKNN YOLO11 实时检测链路，完成摄像头 NV12 采集、硬件格式转换、NPU 推理和检测框绘制。
- 对检测链路进行 profiling，定位 OpenCV VideoCapture、RKNN 推理、YOLO 后处理和日志输出等瓶颈，通过 V4L2/RGA 替换与 Release/O3 优化实现接近 30FPS。
- 封装 Rockchip MPP H.264 编码器并接入异步编码线程，实现检测画面 H.264 编码、RTSP 推流和 H.264 + AAC 双轨预览。
- 实现基于编码端 PTS 的 MP4 本地录像，并使用 V4L2 buffer timestamp 与 ALSA htimestamp 构建采集层时间戳同步方案，完成 H.264 + AAC 双轨同步录制基础。
```

---

## 9. 面试讲述版本

---

### 9.1 1 分钟版本

```text
这个项目是我基于 RK3588 做的端侧 AI 音视频实时检测、推流和同步录制系统。

一开始我从鲁班猫官方 YOLO11 RKNN Demo 出发，把单图、视频文件和摄像头检测迁移到自己的 C++ / CMake 工程中。之后我发现 OpenCV VideoCapture 读取 RKISP 摄像头性能比较差，所以改用 V4L2 mmap 直接采集 /dev/video11 的 1280×720 NV12 数据，再用 RGA 做 NV12/RGB888 转换。

接入 RKNN 后，我对 inference_yolo11_model 做了 profiling，拆解 rknn_run、后处理、letterbox 等耗时，通过 Release/O3、performance governor 和日志精简，把完整检测链路优化到接近 30FPS。

后面我接入了 Rockchip MPP H.264 编码，先用外部工具验证，再封装成自己的 MppH264Encoder，并设计异步编码线程。音频侧用 ALSA 采集 PCM、FFmpeg 编码 AAC，最终通过 MediaMTX 发布 H.264 + AAC RTSP 双轨流。

最后我还做了本地 MP4 录制和时间戳同步：先给 MPP 编码端补 PTS，再实现 video-only MP4 muxer，之后合成 H.264 + AAC 双轨 MP4，并用 V4L2 和 ALSA 的采集层 timestamp 做音视频同步录制基础。
```

---

### 9.2 3 分钟版本

```text
这个项目可以分成四个阶段讲。

第一阶段是基础迁移。我先验证鲁班猫官方 YOLO11 RKNN Demo 可以在 RK3588 上运行，然后把单图检测、视频文件检测和摄像头检测迁移到自己的 C++ / CMake 工程里，形成可扩展的项目骨架。

第二阶段是实时性优化。最初摄像头检测用的是 OpenCV VideoCapture，但我通过 profiling 发现它读取 /dev/video11 这种 RKISP mainpath 节点时性能很差，因为摄像头原生输出是 NV12，而 OpenCV 会引入隐式格式转换和封装开销。所以我改成 V4L2 mmap 直接采集 1280×720 NV12，再用 RGA 做 NV12 到 RGB888 的硬件转换。接入 RKNN 后，我又把 inference_yolo11_model 内部拆开，分别统计 letterbox、rknn_run、outputs_get、post_process 等耗时，最终通过 Release/O3、performance governor 和日志精简把完整检测链路优化到接近 30FPS。

第三阶段是音视频实时推流。我先接入 Rockchip MPP H.264 编码，完成检测画面的硬件编码；再从 HLS、RTSP、WebRTC 逐步验证网络预览。后面补齐音频链路，用 ALSA hw:2,0 采集 PCM，FFmpeg 编码 AAC，最终把 H.264 视频和 AAC 音频封装成 RTSP 双轨流，通过 MediaMTX 发布，并用 VLC 和 ffprobe 验证。

第四阶段是工程深度收尾。早期编码依赖外部 mpi_enc_test，我后面封装了自己的 MppH264Encoder，并用异步编码线程解耦检测主循环和 MPP 编码。再往后，我给 MPP 编码端补充 PTS，输出 H.264 裸流和 PTS CSV，然后用 libavformat 实现 video-only MP4 muxer，处理了 Annex-B 到 AVCC、SPS/PPS extradata 和 AVPacket PTS/DTS/duration。最后接入 AAC 音频生成 H.264 + AAC 双轨 MP4，并用 V4L2 buffer timestamp 和 ALSA htimestamp 构建统一时间轴，实现基于采集层时间戳的音视频同步录制基础。
```

---

### 9.3 5 分钟深度版本结构

面试官如果愿意深入听，可以按下面顺序讲：

```text
1. 项目目标：从 YOLO Demo 做成端侧 AI 音视频系统。
2. 输入链路：OpenCV 慢 → V4L2 mmap + RGA。
3. 推理链路：inference_yolo11_model profiling → rknn_run + postprocess + letterbox。
4. 编码链路：RGB 画框后转 NV12 → MPP H.264。
5. 推流链路：HLS / RTSP / WebRTC，最终 RTSP over TCP 稳定。
6. 音频链路：ALSA → AAC → H.264 + AAC RTSP。
7. 工程化：自研 MppH264Encoder + 异步编码线程。
8. 文件录制：编码端 PTS → video-only MP4 muxer → H.264 + AAC MP4。
9. 同步录制：frame_id/fps 不够 → V4L2 timestamp + ALSA htimestamp。
10. 项目边界：未夸大为完全自研音视频 muxer，也未宣称外部声画标定绝对同步。
```

---

## 10. 面试官可能追问与推荐回答

---

### 10.1 你这个项目和官方 Demo 的区别是什么？

推荐回答：

```text
官方 Demo 主要是验证 YOLO11 RKNN 推理能跑，包括图片或摄像头输入、推理、后处理和画框。我这个项目是在官方 Demo 基础上继续做工程化扩展：首先迁移到自己的 C++ / CMake 工程，然后把 OpenCV 摄像头输入替换为 V4L2 mmap + RGA，接入 MPP H.264 编码、ALSA 音频、AAC 编码、RTSP 双轨推流、本地 MP4 录像和采集层时间戳同步。也就是说，官方 Demo 是模型推理示例，我这个项目更接近一个端侧 AI 音视频系统。
```

---

### 10.2 为什么不用 OpenCV VideoCapture？

推荐回答：

```text
因为 /dev/video11 是 RKISP mainpath，原生输出是 NV12。OpenCV VideoCapture 虽然使用方便，但在这个场景下会引入隐式格式转换和额外封装，实际 profiling 发现它成为摄像头输入瓶颈。所以我改用 V4L2 mmap 直接采集 NV12，再用 RGA 做硬件颜色转换，这样更符合 RK3588 的硬件链路。
```

---

### 10.3 RGA 在项目里具体做了什么？

推荐回答：

```text
RGA 主要做两类格式转换。第一是 V4L2 摄像头采集到的 NV12 转 RGB888，因为 YOLO11 RKNN 推理接口需要 RGB 图像。第二是检测画框之后的 RGB888 再转回 NV12，因为 MPP H.264 编码器输入使用 NV12。也就是说，RGA 在摄像头采集、AI 推理和视频编码之间承担硬件图像格式转换的桥梁作用。
```

---

### 10.4 你怎么判断瓶颈在哪里？

推荐回答：

```text
我给每个阶段都加了计时，包括 V4L2 select、DQBUF、RGA、input prepare、inference_yolo11_model、draw、QBUF 等。接入 RKNN 后，我又把 inference_yolo11_model 内部拆成 letterbox、rknn_inputs_set、rknn_run、outputs_get、post_process 和 outputs_release。这样可以区分到底是采集慢、RGA 慢、NPU 慢，还是后处理慢，而不是凭感觉优化。
```

---

### 10.5 为什么要自研 MppH264Encoder？

推荐回答：

```text
一开始我用 mpi_enc_test 验证 MPP 编码能力，这是合理的探测方式。但如果最终系统还依赖外部工具，就很难控制线程、队列、时间戳和异常统计。所以后面我把 MPP H.264 编码封装成自己的 C++ 类，负责初始化、配置、SPS/PPS header 获取、NV12 帧编码和资源释放，并通过异步编码线程接入主链路。
```

---

### 10.6 异步编码线程解决了什么问题？

推荐回答：

```text
如果主线程在完成采集、RGA、RKNN 和画框后直接同步编码，那么 MPP 编码耗时会阻塞主循环。异步编码线程使用生产者-消费者模型，主线程把待编码 NV12 帧放入队列，编码线程取帧送入 MPP。这样可以把检测主流程和编码流程解耦，同时统计 queue delay、encode time、drop frame 等信息。
```

---

### 10.7 MP4 录制为什么不能直接 ffmpeg -framerate 30 封装？

推荐回答：

```text
直接用 FFmpeg 从裸 H.264 按 30FPS 猜时间戳可以生成 MP4，但它没有使用工程侧真实的 packet PTS，容易出现 timestamp unset warning。为了让 MP4 容器里的时间戳可控，我在编码端为每帧维护 input_pts_us，并用 mpp_frame_set_pts 写入 MPP，再用 mpp_packet_get_pts 回读验证。之后 muxer 从 PTS CSV 读取时间戳，显式设置 AVPacket.pts、dts 和 duration。
```

---

### 10.8 Annex-B 和 AVCC 是什么关系？

推荐回答：

```text
H.264 裸流通常是 Annex-B 格式，用 start code，比如 00 00 00 01，来分隔 NALU。而 MP4 里的 H.264 sample 通常使用 AVCC 格式，也就是用长度前缀来表示每个 NALU 的大小。同时 SPS/PPS 不再每次都按 start code 放在 sample 里，而是放到 MP4 的 avcC extradata 中。所以我的 muxer 需要解析 SPS/PPS，构造 avcC，并把每个 Annex-B packet 转换成 length-prefixed sample。
```

---

### 10.9 实验26 的同步和普通音视频合成有什么区别？

推荐回答：

```text
普通音视频合成只要视频和音频时长差不多，就能生成双轨 MP4。但实验26关注的是采集层时间轴。视频侧不再用 frame_id/fps 伪造 PTS，而是用 V4L2 buffer timestamp 派生 PTS；音频侧用 ALSA htimestamp 估算音频流起点，再和第一帧视频的 V4L2 timestamp 对齐，裁掉音频开头。这样音视频起点和持续时间是基于同一个 monotonic 时间轴对齐的，比进程启动时间估算更可靠。
```

---

### 10.10 你能说这个已经严格证明唇音同步了吗？

推荐回答：

```text
我会谨慎表述。这个项目实现的是基于采集层 monotonic timestamp 的音视频同步录制基础，能从工程时间戳层面保证视频 PTS 和音频起点对齐，比进程启动时间估算可靠。但如果要严格证明绝对唇音同步，还需要外部 ground truth，比如拍手、LED 加蜂鸣器、音画脉冲等方式做实际声画标定。
```

---

## 11. 简历中不要夸大的地方

为了面试时不被追问打穿，下面这些点要谨慎表述。

### 11.1 不要说完全自研了整个音视频 muxer

准确说法：

```text
自研了基于 PTS 的 H.264 video-only MP4 muxer；
H.264 + AAC 双轨最终合成使用 FFmpeg copy mux。
```

不要说：

```text
完全自研 MP4 音视频封装器。
```

---

### 11.2 不要说实现了 Zero-Copy 全链路

准确说法：

```text
使用 V4L2 mmap、RGA、RKNN、MPP 构建硬件加速链路，减少 OpenCV/CPU 路径开销。
```

不要说：

```text
实现了全链路零拷贝。
```

除非后续真的验证了 DMABUF / RKNN / MPP buffer 共享。

---

### 11.3 不要说已经做了多 NPU 并行推理池

准确说法：

```text
当前主要完成单模型实时检测链路和系统级音视频闭环。
```

不要说：

```text
实现了三 NPU 并行推理调度。
```

---

### 11.4 不要说已经做了完整 Web 管理后台

准确说法：

```text
验证了 RTSP / HLS / WebRTC 预览能力，具备后续扩展 Web 控制台基础。
```

不要说：

```text
实现了完整浏览器管理系统。
```

---

### 11.5 不要把时间戳同步夸成绝对唇音同步标定

准确说法：

```text
基于 V4L2 / ALSA 采集层 timestamp 构建音视频同步录制基础。
```

不要说：

```text
已经通过外部物理标定证明绝对唇音同步。
```

---

## 12. 项目最终结论

这个项目最终可以总结为：

```text
从官方 YOLO11 RKNN Demo 出发，完成了一个 RK3588 端侧 AI 音视频系统的工程化闭环。
```

它不是单点功能，而是完整链路：

```text
摄像头采集
    → 图像硬件预处理
    → NPU 推理
    → 检测结果绘制
    → H.264 硬件编码
    → 音频采集与 AAC 编码
    → RTSP 音视频双轨推流
    → MP4 本地双轨录像
    → 采集层时间戳同步
    → 稳定性与异常日志验证
```

从能力展示角度，它能体现：

```text
1. 嵌入式 Linux 多媒体开发能力；
2. RK3588 硬件模块协同能力；
3. 端侧 AI 模型部署和性能优化能力；
4. H.264 / AAC / RTSP / MP4 音视频基础能力；
5. 多线程异步编码和工程模块化能力；
6. 时间戳、PTS、DTS、采集层同步等底层问题理解；
7. 通过实验逐步定位问题、验证假设、收敛方案的工程方法论。
```

最终简历中最推荐写成：

```text
基于 RK3588 的端侧 AI 音视频实时检测、推流与同步录制系统
```

而不是简单写成：

```text
YOLO11 RK3588 部署
```

因为后者只能体现模型部署，前者才能体现完整工程能力。

---

## 13. 后续如果继续扩展，最有价值的方向

如果后面还有时间，可以优先做下面几个方向，但它们不影响当前项目作为简历项目收尾。

### 13.1 端到端低延迟量化

```text
LED / 秒表 / 浏览器画面对比
摄像头采集时间 → VLC 显示时间
RTSP / HLS / WebRTC 延迟对比
```

价值：

```text
让“低延迟”从主观感受变成数据。
```

---

### 13.2 DMABUF / 零拷贝方向

```text
V4L2 DMABUF
RGA buffer sharing
MPP input buffer sharing
RKNN input buffer 研究
```

价值：

```text
进一步减少 memcpy，提高工程深度。
```

---

### 13.3 多线程流水线正式化

```text
采集线程
推理线程
编码线程
音频线程
mux / push 线程
```

价值：

```text
从实验链路升级成更清晰的生产者-消费者流水线。
```

---

### 13.4 Web 管理与文件管理

```text
录像文件列表
模型文件上传 / 切换
RTSP 地址展示
运行状态监控
日志下载
```

价值：

```text
把底层流媒体系统包装成产品形态。
```

---

### 13.5 替换为自训练缺陷检测模型

```text
YOLO11 COCO 模型 → 自训练孔探 / 医学内窥镜模型
RKNN 转换
部署验证
性能对比
```

价值：

```text
把当前通用 COCO 检测链路和毕业课题结合起来。
```

---

## 14. 最终推荐面试开场白

如果面试官让你介绍项目，可以直接从下面这段开始：

```text
我这个项目不是单纯做 YOLO11 部署，而是围绕 RK3588 做了一套端侧 AI 音视频系统。最开始我从鲁班猫官方 RKNN Demo 入手，把单图、视频和摄像头检测迁移到自己的 C++ 工程中。后面通过 profiling 发现 OpenCV 读取 RKISP 摄像头性能不好，于是改成 V4L2 mmap 采集 NV12，并用 RGA 做硬件格式转换。接入 RKNN 后，我继续拆解推理函数内部耗时，把完整检测链路优化到接近 30FPS。

在此基础上，我接入了 Rockchip MPP H.264 硬件编码，先实现检测画面编码和 RTSP 推流，再补齐 ALSA 音频采集与 AAC 编码，形成 H.264 + AAC 双轨 RTSP。后期我又把外部编码工具替换为自研 MppH264Encoder 和异步编码线程，并进一步实现了编码端 PTS、video-only MP4 muxer、H.264 + AAC 双轨 MP4 本地录像，以及基于 V4L2 / ALSA 采集层 timestamp 的音视频同步录制基础。
```

这段话的优点是：

```text
1. 有起点：从官方 Demo 出发；
2. 有问题：OpenCV 慢、推理链路慢、外部编码工具不够工程化、音视频同步不可靠；
3. 有解决：V4L2、RGA、profiling、MPP、ALSA、RTSP、MP4、timestamp；
4. 有结果：实时检测、双轨推流、本地录制、同步基础；
5. 有边界：没有夸大成完全产品化或全自研 muxer。
```

---

## 15. 最终一句话结论

```text
这个项目最有价值的地方，不是单独跑通了某个库，而是把 RK3588 上的摄像头采集、图像硬件预处理、NPU 推理、硬件编码、音频采集、流媒体推流、MP4 录制和采集层时间戳同步串成了一个完整的端侧 AI 音视频工程闭环。
```

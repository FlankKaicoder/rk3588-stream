# RK3588 端侧 AI 音视频实时检测推流系统最终复盘与简历表述建议

> 项目：`rk3588_ai_stream`  
> 平台：LubanCat / RK3588  
> 当前阶段：00~26 实验完成后的最终复盘  
> 核心链路：V4L2 + RGA + RKNN + Rockchip MPP + ALSA + AAC + FFmpeg + MediaMTX + RTSP / MP4  
> 文档目的：把前面 26 个实验从“实验记录”重新整理成“项目思路、方法过程、结论、简历写法和面试复盘”。

---

## 1. 项目一句话定位

本项目不是单纯的“YOLO11 RKNN 部署 Demo”，而是一个基于 RK3588 的端侧 AI 音视频实时检测与流媒体系统。

项目从鲁班猫官方 YOLO11 RKNN C++ Demo 出发，逐步完成：

```text
摄像头采集
    → 图像硬件预处理
    → RKNN NPU 推理
    → 检测结果绘制
    → H.264 硬件编码
    → AAC 音频接入
    → RTSP 双轨实时推流
    → H.264 + AAC 双轨 MP4 本地录像
    → 基于 V4L2 / ALSA 采集层时间戳的音视频同步验证
```

最终可以概括为：

```text
基于 RK3588 构建端侧 AI 音视频实时检测系统，完成从摄像头采集、RGA 预处理、RKNN 推理、MPP H.264 编码、ALSA 音频采集、RTSP 双轨推流、MP4 双轨录像到采集层时间戳同步的完整工程闭环。
```

---

## 2. 为什么这个项目适合写进简历

这个项目的价值不在于“跑通 YOLO11”，而在于它覆盖了嵌入式 AI 工程中非常典型的一条完整链路：

| 能力方向 | 项目中对应内容 |
|---|---|
| Linux 多媒体采集 | V4L2 mmap 采集 `/dev/video11` 的 1280×720 NV12 |
| 硬件图像处理 | RGA 完成 NV12 ↔ RGB888 双向转换 |
| 端侧 AI 推理 | RKNN Runtime 部署 YOLO11 RKNN 模型 |
| 性能分析 | 分阶段 profiling：采集、RGA、RKNN、后处理、编码、推流 |
| 硬件编码 | Rockchip MPP H.264 编码 |
| C++ 工程封装 | 自研 `MppH264Encoder`，从外部 `mpi_enc_test` 迁移到工程内编码模块 |
| 多线程系统设计 | 异步 MPP 编码线程，检测主循环和编码解耦 |
| 音频系统 | ALSA `hw:2,0` 采集，FFmpeg AAC 编码 |
| 流媒体系统 | FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流 |
| 本地录像 | H.264 + AAC 双轨 MP4 文件生成 |
| 时间戳同步 | V4L2 timestamp + ALSA htimestamp 构建统一采集层时间轴 |
| 稳定性验证 | 300 秒 RTSP 双轨稳定性、3600 帧 MP4 长测、异常日志统计 |

因此简历里应该把它写成“嵌入式 AI + Linux 多媒体 + 音视频流媒体 + 性能优化”的综合项目，而不是写成普通的模型部署项目。

---

## 3. 项目最终系统架构

### 3.1 实时 RTSP 推流链路

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
VLC / ffprobe / 浏览器辅助验证
```

RTSP 最终形态：

```text
rtsp://板端IP:8554/final_ai_av_rtsp
```

---

### 3.2 本地 MP4 录像链路

```text
视频侧：
/dev/video11
    ↓
V4L2 mmap 采集 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
异步 MPP H.264 编码
    ↓
H.264 裸流 + PTS CSV
    ↓
自研 libavformat 视频 MP4 MUX
    ↓
video-only MP4

音频侧：
ALSA hw:2,0
    ↓
PCM 采集
    ↓
AAC 编码
    ↓
audio.m4a

最终封装：
video-only MP4 + audio.m4a
    ↓
FFmpeg copy mux
    ↓
H.264 + AAC 双轨 MP4
```

---

### 3.3 实验26 后的采集层时间戳同步链路

实验25 的音视频文件对齐主要依赖脚本层面的进程启动时间差。实验26 将同步依据升级为采集层时间戳：

```text
视频侧：
V4L2 buffer.timestamp
    ↓
以第一帧 V4L2 timestamp 为 0 点
    ↓
生成 video_sync_pts_us
    ↓
写入 MPP encoder PTS
    ↓
H.264 packet PTS
    ↓
MP4 视频时间轴

音频侧：
ALSA htimestamp + 已采样帧数
    ↓
估算 audio_stream_start_est_ns
    ↓
与 first_video_v4l2_ts_ns 做差
    ↓
得到 audio_trim_s
    ↓
FFmpeg atrim + asetpts
    ↓
AAC 音频轨
```

这一步的意义是：

```text
视频 PTS 不再简单使用 frame_id / fps，而是来自真实 V4L2 采集时间；
音频不再只按脚本启动时间裁剪，而是根据 ALSA htimestamp 估算真实音频流起点；
音频和视频被统一到 monotonic 时间轴上进行文件级封装。
```

需要保守表述：这证明的是“基于采集层 timestamp 的时间轴对齐与同步封装方案”，不等价于已经完成了用拍手、LED、蜂鸣器等外部物理事件标定的严格唇音同步测试。

---

## 4. 整个项目的核心思路

### 4.1 不是一开始就写最终链路，而是逐层验证

整个项目最重要的方法论是：不把采集、推理、编码、音频、推流、封装一次性揉在一起，而是每一步先独立验证，再逐步合并。

原因是嵌入式音视频系统中任何一个模块出问题，都会表现为“画面不出来、播放失败、卡顿、没有声音、ffprobe 失败、VLC 断流”。如果一开始就搭大链路，很难判断问题来自哪里。

因此本项目采用了如下分层路线：

```text
官方 Demo 验证
    ↓
自有工程迁移
    ↓
图片 / 视频 / 摄像头检测
    ↓
性能剖析，定位 OpenCV 瓶颈
    ↓
V4L2 mmap 替代 OpenCV 采集
    ↓
RGA 替代 CPU / OpenCV 格式转换
    ↓
RKNN 推理接入和 profiling
    ↓
MPP 编码录像
    ↓
HLS / RTSP / WebRTC 网络预览
    ↓
ALSA 音频采集与 AAC 编码
    ↓
实时音视频 RTSP 双轨
    ↓
自研 MPP 编码封装和异步编码线程
    ↓
编码端 PTS 元数据
    ↓
自研 MP4 视频 MUX
    ↓
H.264 + AAC 双轨 MP4
    ↓
V4L2 / ALSA 采集层时间戳同步
```

### 4.2 每个实验都解决一个明确问题

| 阶段 | 解决的问题 |
|---|---|
| 00~03 | 官方 Demo 能不能迁移到自己的 C++ 工程，并完成图像、视频、摄像头检测 |
| 04 | 为什么摄像头检测 FPS 很低，瓶颈到底在哪里 |
| 05 | 能不能绕开 OpenCV，直接用 V4L2 mmap + RGA 获取可用 RGB 输入 |
| 06 | 接入 RKNN 后完整检测链路性能如何 |
| 07 | `inference_yolo11_model()` 内部到底慢在哪里，如何接近 30FPS |
| 08 | 检测后的画面能不能用 MPP H.264 硬件编码保存 |
| 09~11 | 编码后的 H.264 能不能用于 HLS / RTSP / WebRTC 网络预览 |
| 12 | 摄像头和完整流媒体链路能不能持续稳定运行 |
| 13~16 | 板端音频采集、播放、AAC / Opus / G.711 编解码是否可用 |
| 17~19 | 音频能不能接回实时视频系统，形成 AV RTSP 双轨流 |
| 20 | 普通用户运行、RGA_COLORFILL、xrun、timestamp 等问题如何清理 |
| 21 | MPP 编码能不能从外部工具升级为自研 C++ 模块，并接入异步线程 |
| 22 | 自研异步 MPP 视频编码能不能和 ALSA + AAC 形成最终 AV RTSP |
| 23 | 编码端能不能输出可追踪的 PTS / DTS / packet_size 元数据 |
| 24 | 能不能用工程侧 PTS 自研封装标准 MP4 |
| 25 | 能不能接入 AAC 音频，生成 H.264 + AAC 双轨 MP4 |
| 26 | 能不能从进程启动时间对齐升级为 V4L2 / ALSA 采集层时间戳同步 |

---

## 5. 关键阶段复盘

## 5.1 阶段一：从官方 Demo 到自有工程

最初的鲁班猫 YOLO11 Demo 可以跑通，但它属于官方示例目录，程序名、输出路径、工程组织都不适合作为长期项目。于是项目首先完成了：

```text
00：官方 YOLO11 RKNN Demo 基线验证
01：单图检测迁移，生成 image_detect
02：视频文件检测迁移，生成 video_detect
03：摄像头检测迁移，生成 camera_detect
```

这一阶段的意义：

```text
1. 验证 RKNN Runtime、YOLO11 模型、后处理、RGA 预处理基本可用；
2. 建立自己的 rk3588_ai_stream 工程结构；
3. 把官方代码作为 third_party 参考，而不是直接改官方工程；
4. 为后续 V4L2、RGA、MPP、RTSP、MP4 等模块扩展打基础。
```

---

## 5.2 阶段二：定位 OpenCV VideoCapture 瓶颈

03 实验能跑通摄像头检测，但性能很低。04 实验开始做逐阶段 profiling：

```text
capture_ms
resize_ms
cvtcolor_ms
model_total_ms
draw_ms
write_ms
total_ms
```

初始完整链路约 5FPS。去掉 VideoWriter 后 FPS 变化很小，说明写视频不是根本瓶颈。进一步分析发现：

```text
/dev/video11 是 RKISP mainpath；
原生输出是 NV12；
OpenCV VideoCapture 会隐式做 NV12 → BGR 转换；
OpenCV/GStreamer 封装层带来明显开销；
即使设置 1280×720，也无法作为最终实时链路的可靠输入层。
```

因此项目做出第一个关键路线调整：

```text
放弃 OpenCV VideoCapture 作为最终采集方案；
改用 V4L2 mmap 原生采集 NV12；
使用 RGA 做 NV12 → RGB888。
```

这个判断非常适合面试时讲，因为它体现了你不是盲目堆功能，而是先定位瓶颈，再替换底层链路。

---

## 5.3 阶段三：V4L2 mmap + RGA 输入链路

05 实验实现了：

```text
open /dev/video11
    ↓
VIDIOC_QUERYCAP
    ↓
VIDIOC_S_FMT 设置 1280×720 NV12
    ↓
VIDIOC_REQBUFS / QUERYBUF / mmap
    ↓
VIDIOC_QBUF / STREAMON
    ↓
select 等待帧
    ↓
VIDIOC_DQBUF 取出 NV12
    ↓
RGA NV12 → RGB888
    ↓
VIDIOC_QBUF 归还 buffer
```

`include/v4l2_mplane_capture.hpp` 被封装出来，后续 06、07、08、21、22、24、25、26 都复用这条 V4L2 采集链路。

这一阶段证明：

```text
1. /dev/video11 裸 V4L2 mmap 采集可接近 30FPS；
2. RGA 可以实时完成 NV12 → RGB888；
3. 输入链路不再是主要瓶颈；
4. 后续性能问题可以集中看 RKNN 推理、后处理和编码。
```

---

## 5.4 阶段四：RKNN 推理接入和内部性能剖析

06 实验在 V4L2 + RGA 后接入 RKNN YOLO11：

```text
V4L2 mmap 采集 NV12
    ↓
RGA NV12 → RGB888
    ↓
构造 image_buffer_t
    ↓
inference_yolo11_model()
    ↓
YOLO11 后处理
    ↓
画框
```

初始结果约 18.7FPS，主要瓶颈集中在 `inference_yolo11_model()`。

07 实验继续拆解内部耗时：

```text
convert_image_with_letterbox
rknn_inputs_set
rknn_run
rknn_outputs_get
post_process
rknn_outputs_release
```

进一步拆后处理：

```text
decode
sort
nms
pack
```

最终发现：

```text
1. `rknn_run` 是主要耗时之一；
2. YOLO11 后处理 decode 也非常重；
3. Release / O3 编译优化对后处理影响明显；
4. CPU governor 需要设置为 performance；
5. 每帧日志打印会污染长期运行和性能判断。
```

优化后，完整 V4L2 + RGA + RKNN 检测链路从约 18.7FPS 提升到约 29.7FPS，已经接近 30FPS 摄像头帧率上限。

---

## 5.5 阶段五：MPP H.264 编码与网络预览

08 实验把项目从“能检测”推进到“能编码录像”：

```text
V4L2 mmap 采集 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
MPP H.264 编码
    ↓
H.264 / MP4 文件
```

08 先用外部 `mpi_enc_test` 分阶段验证：

```text
NV12 文件 → MPP 编码
实时 V4L2 FIFO → MPP 编码
检测画框后 RGB 转 NV12 → MPP 编码
```

随后 09~11 继续扩展网络预览：

```text
09：HLS 预览
10：RTSP 预览
11：WebRTC / 浏览器预览
```

其中 RTSP over TCP 最终更适合作为稳定演示方案：

```text
FFmpeg 推送 H.264
    ↓
MediaMTX RTSP Server
    ↓
VLC / ffprobe 拉流
```

这一阶段说明项目已经从“端侧检测程序”升级为“视频系统链路”：

```text
采集 → 推理 → 编码 → 网络预览
```

---

## 5.6 阶段六：稳定性与资源评估

12 实验开始验证系统级稳定性，而不是只看能否跑通。

首先进行裸 V4L2 采集稳定性测试：

```text
/dev/video11
    ↓
V4L2 mmap 采集 7200 帧
    ↓
写入 /dev/null
```

结论：

```text
/dev/video11 在纯 V4L2 mmap 采集下可以稳定采集 7200 帧，约 240 秒，平均接近 30FPS。
```

然后对完整链路做受控时间测试，记录：

```text
CPU load
内存
温度
CPU 频率
MediaMTX / FFmpeg / 检测程序状态
异常日志
```

这个阶段的工程意义：

```text
1. 区分人为 Ctrl+C、timeout 结束和真正崩溃；
2. 不把 Broken pipe、graceful shutdown 等受控收尾误判为系统异常；
3. 为后续 300 秒最终验收和简历量化结果打基础。
```

---

## 5.7 阶段七：音频链路补齐

13~16 实验先独立验证音频能力：

```text
13：音频设备与 FFmpeg 编解码能力探测
14：ALSA PCM 采集与播放
15：AAC / Opus / G.711 编码
16：压缩音频解码与播放
```

最终确认：

```text
card 2：rockchip-es8388
设备：hw:2,0
能力：capture + playback
采样率：48000Hz
声道：stereo
```

17~19 将音频接入实时系统：

```text
17：实时 ALSA 采集 → AAC / Opus / G.711 文件与纯音频 RTSP
18：已有检测视频 + AAC 音频 → 双轨 MP4 文件
19：实时检测 H.264 + 实时 ALSA 音频 AAC → RTSP 双轨流
19-1：修正队列、ffprobe 时机、20FPS 对齐等问题
```

这一阶段使项目从“视频流媒体”变成“音视频流媒体”。

---

## 5.8 阶段八：RGA_COLORFILL 修复和普通用户稳定性

实验20处理了一个长期污染日志的问题：

```text
YOLO11 letterbox 阶段每帧触发 RGA_COLORFILL fail
Failed to call RockChipRga
```

定位结果：

```text
问题出现在鲁班猫公共 image_utils.c 中的 RGA imfill；
它用于给 YOLO 640×640 输入画布填充 letterbox 灰边；
RGA imfill 每帧失败后虽然有 CPU fallback，但错误日志刷屏。
```

最终处理策略：

```text
小画布 letterbox 灰边填充：直接 CPU memset；
大图像 resize / copy：继续使用 RGA。
```

这样做的理由：

```text
640×640×3 ≈ 1.2MB；
20~30FPS 下 memset 负载很低；
比每帧 RGA ColorFill 失败更稳定、更清晰。
```

修复后：

```text
RGA_COLORFILL = 0
Failed to call RockChipRga = 0
```

这个问题很适合作为面试中的“工程取舍”案例：不是所有硬件加速都必须强行使用，小数据量、兼容性不佳的操作交给 CPU 反而更稳。

---

## 5.9 阶段九：自研 MPP H.264 编码封装

21 实验是项目工程化程度提升的关键节点。

之前链路依赖外部 `mpi_enc_test`：

```text
检测程序
    ↓
NV12 FIFO
    ↓
外部 mpi_enc_test
    ↓
H.264
```

这种方式虽然能跑通，但存在问题：

```text
1. 编码逻辑不在自己的 C++ 主程序中；
2. 无法精细管理帧生命周期、时间戳和异常；
3. 多线程队列和同步难以控制；
4. 简历中不适合写成自研编码模块；
5. 最终工程像多个进程拼接，而不是完整系统。
```

因此 21 实验封装了：

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

封装内容包括：

```text
mpp_create
mpp_init
MppEncCfg 配置
prep 参数
rc 码率控制
H.264 profile / level / CABAC
SPS / PPS header 获取
NV12 MppFrame 输入
MppPacket 输出
资源释放
```

这一阶段的意义：

```text
1. MPP 编码真正进入自有 C++ 工程；
2. 可以统一管理编码线程和队列；
3. 后续可以给每个编码 packet 绑定 frame_id、PTS、DTS、packet_size；
4. 项目从“工具拼接”升级为“工程封装”。
```

---

## 5.10 阶段十：异步 MPP 编码线程

串行编码版本的主循环是：

```text
采集 → RGA → RKNN → draw → RGA → MPP encode → fwrite → QBUF
```

MPP 编码虽然只需要约 2.8ms，但放在主循环中会把总耗时从约 33ms 推高到约 36ms，导致帧率从接近 30FPS 降到约 27FPS。

因此 21-4 改成异步架构：

```text
主线程：
采集 → RGA → RKNN → draw → RGA → push NV12 到队列 → QBUF

编码线程：
pop NV12 → MPP encode → fwrite H.264
```

结果：

```text
主循环只承担 queue_push，平均约 0.1~0.2ms；
编码线程平均约 2.8~3.0ms；
检测和编码可以并行；
系统恢复接近 30FPS；
编码失败 0，丢帧 0。
```

这也是简历中非常值得写的一点：

```text
设计异步 MPP 编码线程，解耦检测主循环与 H.264 编码流程，降低主循环阻塞。
```

---

## 5.11 阶段十一：自研异步 MPP + AV RTSP 最终集成

22 实验把实验21的视频能力和实验20的音频能力合并：

```text
视频侧：
V4L2 + RGA + RKNN + 自研异步 MPP H.264

音频侧：
ALSA hw:2,0 + FFmpeg AAC

封装侧：
FFmpeg RTSP MUX + MediaMTX
```

最终形成：

```text
H.264 视频轨 + AAC 音频轨
    ↓
RTSP 双轨流
    ↓
VLC / ffprobe 验证
```

长时间测试表明：

```text
3600 帧约 120 秒测试接近 30FPS；
RKNN 推理整体稳定；
MPP 编码线程不是瓶颈；
无编码失败；
无编码丢帧；
无 RGA_COLORFILL、xrun、timestamp unset、broken pipe 等异常。
```

后续 9000 帧 / 约 300 秒最终 RTSP 稳定性验收中：

```text
frames = 9000
wall_fps ≈ 29.992
async_encoded_frames = 9000
async_encode_failures = 0
async_drop_frames = 0
Video: H.264 High Profile, 1280×720, 30fps
Audio: AAC LC, 48000Hz, stereo
异常计数全 0
```

这条链路是简历里最直接的系统结果。

---

## 5.12 阶段十二：编码端 PTS 元数据

23 实验解决了一个更底层的问题：

```text
H.264 packet 有数据，但工程侧没有显式维护每个 packet 的 PTS / DTS。
```

对于实时 RTSP，FFmpeg 可以从裸流和帧率推断时间戳；但如果要做 MP4 录像、历史回放、音视频同步，就必须有工程侧时间戳。

因此 23 实验做了：

```text
Exp21EncFrame 增加 frame_id、pts_us、enqueue_ts_us；
encode 前调用 mpp_frame_set_pts(frame, pts_us)；
encode 后通过 mpp_packet_get_pts(packet) 读回 packet PTS；
记录 mpp_packet_get_dts(packet)、packet_size、queue_delay、encode_wall_ms；
输出 <output_h264>.pts.csv。
```

验证结果：

```text
frame_id 连续；
input_pts_us 单调递增；
MPP packet pts 与 input_pts_us 一致；
可以作为后续 MP4 MUX 的可靠输入。
```

---

## 5.13 阶段十三：自研 libavformat MP4 视频 MUX

24 实验把 H.264 裸流 + PTS CSV 封装为标准 MP4。

如果直接使用 FFmpeg 从裸 H.264 自动封装 MP4，会出现：

```text
Timestamps are unset in a packet for stream 0.
```

这说明 FFmpeg 在猜时间戳，而不是使用工程侧生成的 PTS。

因此 24 实验编写了：

```text
src/main_exp24_mp4_mux_from_pts.cpp
```

实现内容：

```text
读取 H.264 裸流；
读取 PTS CSV；
按 packet_size 切分每个 H.264 packet；
解析 SPS / PPS；
构造 avcC extradata；
Annex-B H.264 → AVCC length-prefixed sample；
设置 AVPacket.pts；
设置 AVPacket.dts；
设置 AVPacket.duration；
判断 IDR 并设置 AV_PKT_FLAG_KEY；
写入 MP4 文件。
```

最终 1800 帧 / 约 60 秒实时检测录像验证通过：

```text
async_encoded_frames = 1800
async_encode_failures = 0
async_drop_frames = 0
wall_fps ≈ 29.960
pts_rows = 1800
mp4_packets = 1800
bad_count = 0
result = PASS
```

核心结论：

```text
MP4 内部 packet PTS 与 CSV 中 input_pts_us 完全一致；
DTS 当前按低延迟无 B 帧策略设置为 PTS；
每帧 duration 约 33333us；
标准 MP4 可以被 ffprobe / ffmpeg 正常识别与解码。
```

---

## 5.14 阶段十四：H.264 + AAC 双轨 MP4

25 实验将本地录像从 video-only MP4 扩展为 H.264 + AAC 双轨 MP4。

最终链路：

```text
视频：
V4L2 + RGA + RKNN + 异步 MPP H.264 + PTS CSV + 自研 MP4 视频 MUX

音频：
ALSA hw:2,0 + FFmpeg AAC

最终：
video-only MP4 + audio.m4a → FFmpeg copy mux → AV MP4
```

25 实验需要保守理解：

```text
自研的是 H.264 视频 MP4 muxer；
H.264 + AAC 双轨最终合成使用 FFmpeg copy mux；
25 的音频对齐依据主要是进程启动时间差 audio_lead_sec；
这属于文件级时间轴对齐，不是严格采集层唇音同步。
```

3600 帧 / 约 120 秒长测结果：

```text
async_encoded_frames = 3600
async_encode_failures = 0
async_drop_frames = 0
wall_fps ≈ 29.980
pts_rows = 3600
mp4_video_packets = 3600
abnormal_lines = 0
result = PASS
```

最终 MP4：

```text
视频轨：H.264 High Profile，1280×720，约 30FPS，3600 帧
音频轨：AAC LC，48000Hz，stereo
容器时长约 120 秒
ffmpeg 解码验证无错误
未出现 xrun、timestamp unset、Non-monotonous DTS、decode error 等异常
```

---

## 5.15 阶段十五：V4L2 / ALSA 采集层时间戳同步

26 实验是项目收尾阶段非常关键的一步。

它解决的问题是：

```text
实验25 的 audio_lead_sec 来自脚本层进程启动时间；
这不能严格代表第一帧视频真实采集时间，也不能代表第一批音频样本真实采集时间。
```

因此 26 实验验证：

```text
V4L2 是否能提供 monotonic timestamp；
ALSA 是否能提供 htimestamp；
音频先启动 + 多录 padding 后，能否按 timestamp 裁剪覆盖完整视频；
真实异步 MPP 录像程序能否输出 sync_meta.csv；
MPP encoder PTS 能否从 frame_id / fps 改为 V4L2 timestamp 派生 PTS；
最终能否生成 V4L2 timestamp 视频 + ALSA timestamp 裁剪音频的 H.264/AAC MP4。
```

关键改动：

```cpp
旧方案：
enc_frame.pts_us = frame_id * 1000000 / fps;

新方案：
enc_frame.pts_us = exp26_video_sync_pts_us;

其中：
exp26_video_sync_pts_us = (当前帧 V4L2 timestamp - 第一帧 V4L2 timestamp) / 1000;
```

音频侧：

```text
audio_stream_start_est_ns = alsa_htstamp_ns - total_frames / sample_rate

audio_trim_s = first_video_v4l2_ts_ns - audio_stream_start_est_ns

atrim=start=${audio_trim_s}:duration=${video_duration}
asetpts=PTS-STARTPTS
```

实验26 的重要发现：

```text
如果程序实际处理速度低于 30FPS 或 V4L2 sequence 出现跳帧，旧的 frame_id / fps 会压缩真实视频时间轴；
使用 V4L2 timestamp 后，MP4 视频时间轴能反映真实采集节奏；
音频侧可以根据 ALSA htimestamp 估算音频流起点，并裁剪到与视频一致的时间段。
```

最终结论：

```text
项目已经从“能录制 H.264 + AAC 双轨 MP4”，进一步升级为“基于 V4L2 / ALSA 采集层 timestamp 的音视频同步封装方案”。
```

简历中可以写：

```text
基于 V4L2 buffer timestamp 和 ALSA htimestamp 构建采集层时间轴，将视频 PTS 从 frame_id/fps 升级为 V4L2 timestamp 派生 PTS，并依据音频采集时间戳裁剪 AAC 音频，实现 H.264/AAC MP4 的时间戳驱动同步封装。
```

不建议写：

```text
实现严格唇音同步。
```

除非后续补充拍手、LED、蜂鸣器等物理事件标定实验。

---

## 6. 最终项目结论

### 6.1 功能结论

截至实验26，项目已经完成：

```text
1. RK3588 YOLO11 RKNN 模型部署；
2. 自有 C++ 工程迁移；
3. V4L2 mmap 摄像头采集；
4. RGA NV12/RGB888 双向转换；
5. RKNN 实时推理与 YOLO11 后处理；
6. 检测框绘制；
7. Rockchip MPP H.264 编码；
8. 自研 MppH264Encoder C++ 封装；
9. 异步 MPP 编码线程；
10. HLS / RTSP / WebRTC 预览验证；
11. ALSA 音频采集；
12. AAC 音频编码；
13. H.264 + AAC RTSP 双轨实时推流；
14. 编码端 PTS / DTS / packet_size 元数据记录；
15. 自研 H.264 视频 MP4 muxer；
16. H.264 + AAC 双轨 MP4 本地录像；
17. V4L2 / ALSA 采集层 timestamp 音视频同步验证。
```

### 6.2 性能结论

关键性能结果可以概括为：

```text
OpenCV 摄像头链路：约 5~15FPS，瓶颈在 OpenCV/GStreamer 隐式转换与封装；
V4L2 mmap 裸采集：接近 30FPS；
V4L2 + RGA 输入链路：接近 30FPS；
初始 V4L2 + RGA + RKNN：约 18.7FPS；
Release/O3/performance 优化后检测链路：约 29.7FPS；
异步 MPP 编码后：检测主循环恢复接近 30FPS；
3600 帧 AV MP4 长测：约 29.98FPS；
9000 帧 RTSP 稳定性测试：约 29.99FPS；
MPP 异步编码平均约 2.7~3.1ms，不是系统瓶颈；
RKNN 推理整体约 27ms，是最终主要耗时来源。
```

### 6.3 工程结论

本项目最重要的工程结论是：

```text
1. OpenCV 适合早期验证，不适合作为 RKISP 摄像头实时采集最终方案；
2. 对 RK3588 这类端侧平台，V4L2 + RGA + RKNN + MPP 是更合理的硬件链路；
3. 性能优化必须先分阶段 profiling，再决定是否引入线程或硬件加速；
4. MPP 编码放在主循环会影响实时性，异步编码线程是必要的工程优化；
5. 音视频双轨系统必须关注 xrun、timestamp unset、队列阻塞、Broken pipe 等异常；
6. MP4 本地录像不能长期依赖 FFmpeg 猜裸流时间戳，工程侧应提供 PTS；
7. 严谨音视频同步应尽量基于采集层 timestamp，而不是脚本进程启动时间。
```

---

## 7. 当前项目边界与不要夸大的地方

简历和面试中要保守，不能把没做完的内容说成已完成。

### 7.1 已经完成，可以写

```text
1. V4L2 mmap 采集；
2. RGA 图像转换；
3. RKNN YOLO11 实时推理；
4. MPP H.264 编码；
5. 自研 MPP 编码封装；
6. 异步编码线程；
7. ALSA 音频采集；
8. AAC 编码；
9. H.264 + AAC RTSP 双轨推流；
10. H.264 + AAC 双轨 MP4 录像；
11. 自研 H.264 视频 MP4 muxer；
12. V4L2 / ALSA timestamp 同步验证。
```

### 7.2 不建议写成已经完成

```text
1. 完整 Zero-Copy；
2. 多 RKNN context / 三 NPU 并行推理池；
3. 自研 RTSP Server；
4. 完整 Web 管理后台；
5. 24 小时稳定性测试；
6. 4K 输入实时 AI 检测；
7. 自训练孔探缺陷模型已经替换并达到业务精度；
8. 物理标定级严格唇音同步。
```

### 7.3 面试中对实验26的保守说法

建议说：

```text
我把原来基于进程启动时间的音频裁剪，升级为基于 V4L2 buffer timestamp 和 ALSA htimestamp 的采集层时间轴对齐。视频 PTS 使用 V4L2 timestamp 派生，音频根据 ALSA timestamp 估算起点后裁剪，再合成 H.264/AAC MP4。这个方案比脚本启动时间对齐严谨，但如果要证明物理意义上的严格唇音同步，还需要拍手或 LED/蜂鸣器这类外部事件标定。
```

---

## 8. 简历推荐写法

## 8.1 推荐项目名称

最推荐：

```text
基于 RK3588 的端侧 AI 音视频实时检测与流媒体系统
```

可选名称：

```text
RK3588 端侧 AI 实时检测与 RTSP/MP4 音视频系统
```

偏嵌入式 AI 岗位：

```text
基于 RK3588 NPU 的端侧视觉检测与音视频推流系统
```

偏音视频 / 流媒体岗位：

```text
基于 RK3588 的 H.264/AAC 双轨实时推流与本地录像系统
```

---

## 8.2 简历详细版

```text
基于 RK3588 的端侧 AI 音视频实时检测与流媒体系统
技术栈：C++、Linux、V4L2、RGA、RKNN、Rockchip MPP、ALSA、FFmpeg、MediaMTX、RTSP、MP4、CMake

- 基于 LubanCat / RK3588 平台构建端侧 AI 音视频实时检测系统，完成 YOLO11 RKNN 模型加载、NPU 推理、后处理、检测框绘制、H.264 编码、AAC 音频接入、RTSP 双轨推流和 MP4 双轨录像。
- 针对 OpenCV VideoCapture 读取 RKISP 摄像头节点性能不足的问题，改用 V4L2 mmap 直接采集 `/dev/video11` 的 1280×720 NV12 数据，并通过 RGA 完成 NV12/RGB888 双向转换，使输入链路接近 30FPS。
- 对 RKNN 推理链路进行阶段级 profiling，拆解 letterbox、rknn_run、outputs_get、post_process 等耗时，并通过 Release/O3 编译优化、performance governor 与日志精简，将完整检测链路从约 18.7FPS 优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块 `MppH264Encoder`，实现编码器初始化、SPS/PPS 获取、NV12 帧编码、PTS 回读与资源释放，并设计异步编码线程解耦检测主循环与 H.264 编码流程。
- 接入 ALSA `hw:2,0` 实时音频采集，使用 FFmpeg 编码 AAC，并与 H.264 视频流封装为 RTSP 双轨流，通过 MediaMTX 发布，支持 VLC / ffprobe 拉流验证。
- 实现基于 libavformat 的 H.264 视频 MP4 muxer，完成 Annex-B 到 AVCC 转换、SPS/PPS extradata 构造、AVPacket PTS/DTS/duration 写入和 packet 级对齐验证，并进一步合成 H.264 + AAC 双轨 MP4。
- 基于 V4L2 buffer timestamp 和 ALSA htimestamp 构建采集层时间轴，将视频 PTS 从 `frame_id/fps` 升级为 V4L2 timestamp 派生 PTS，并依据音频采集时间戳裁剪 AAC 音频，实现时间戳驱动的音视频同步封装方案。
```

---

## 8.3 简历精简版

```text
基于 RK3588 的端侧 AI 音视频实时检测与流媒体系统
技术栈：C++、Linux、V4L2、RGA、RKNN、MPP、ALSA、FFmpeg、MediaMTX、RTSP、MP4

- 搭建 RK3588 端侧 YOLO11 实时检测链路，使用 V4L2 mmap 采集 1280×720 NV12 摄像头数据，并通过 RGA 完成 NV12/RGB888 双向转换。
- 对 RKNN 推理链路进行 profiling，拆解 rknn_run、后处理、letterbox 等耗时，通过 Release/O3 和 performance governor 将检测链路优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码器并接入异步编码线程，实现检测画面的 H.264 实时编码、FIFO 输出和 RTSP 推流。
- 接入 ALSA 音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流，并完成 9000 帧 / 约 300 秒稳定性测试。
- 实现基于 libavformat 的 H.264 视频 MP4 muxer，并在此基础上合成 H.264 + AAC 双轨 MP4；进一步使用 V4L2 / ALSA 采集层 timestamp 优化音视频时间轴对齐。
```

---

## 8.4 如果简历只能放 4 条 bullet

```text
- 基于 RK3588 完成 YOLO11 RKNN 端侧部署，构建 V4L2 + RGA + RKNN 实时检测链路，绕开 OpenCV 摄像头输入瓶颈。
- 对推理链路进行 profiling，定位 rknn_run、post_process、letterbox 等耗时，通过 Release/O3、performance governor 与日志精简优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块，并设计异步编码线程，将检测帧编码为 H.264 码流输出至 FIFO。
- 接入 ALSA 音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流，并扩展 H.264/AAC MP4 录像和采集层 timestamp 同步方案。
```

---

## 8.5 一分钟面试介绍

```text
这个项目是我基于 RK3588 做的端侧 AI 音视频实时检测与流媒体系统。

一开始我从鲁班猫官方 YOLO11 RKNN Demo 入手，把单图检测、视频文件检测、摄像头检测迁移到自己的 C++ 工程中。早期用 OpenCV VideoCapture 能读摄像头，但性能很差。通过 profiling 和 v4l2-ctl 分析发现，/dev/video11 是 RKISP mainpath，原生输出 NV12，OpenCV 会做隐式转换和封装，所以我改成 V4L2 mmap 直接采集 NV12，再用 RGA 做 NV12 到 RGB 的转换。

接入 RKNN 后，初始完整链路只有十几 FPS，所以我继续拆 inference_yolo11_model 的内部耗时，包括 letterbox、rknn_run、outputs_get、post_process 等。后面通过 Release/O3、performance governor、后处理分析和日志精简，把完整检测链路优化到接近 30FPS。

在编码部分，我先用外部 mpi_enc_test 验证 MPP H.264 编码，后面自己封装了 MppH264Encoder，把 init、get_header、encode、release 放到自己的 C++ 类里，并把编码拆到异步线程，避免阻塞检测主循环。

最后我接入 ALSA 音频采集和 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流；同时又做了本地 H.264/AAC MP4 录像，并进一步用 V4L2 buffer timestamp 和 ALSA htimestamp 做采集层时间轴对齐。最终项目形成了实时推流和本地录像两条完整链路。
```

---

## 9. 面试重点问题准备

### 9.1 这个项目最大的难点是什么？

建议回答：

```text
我认为主要有四个难点。

第一是摄像头输入瓶颈。最初 OpenCV 能读图像但 FPS 很低，我通过 profiling 发现瓶颈在 OpenCV VideoCapture，而不是摄像头硬件本身，所以改成 V4L2 mmap + RGA。

第二是 RKNN 推理链路优化。接入 RKNN 后初始只有约 18FPS，我没有盲目加线程，而是拆 inference_yolo11_model 内部耗时，定位 rknn_run、post_process、letterbox 等阶段，再通过 Release/O3 和 performance governor 优化到接近 30FPS。

第三是 MPP 编码工程化。外部 mpi_enc_test 只能验证功能，不适合作为最终工程，所以我封装了 MppH264Encoder，并设计异步编码线程，让检测主循环不被编码阻塞。

第四是音视频系统稳定性。视频来自 H.264 FIFO，音频来自 ALSA，最后由 FFmpeg 封装 RTSP 或 MP4，需要关注 xrun、timestamp unset、队列阻塞、Broken pipe、DTS 单调性等问题，所以我做了日志统计、ffprobe 验证和长时间稳定性测试。
```

---

### 9.2 为什么不用 OpenCV？

```text
OpenCV 在早期验证阶段很方便，但最终链路没有继续用它做摄像头采集。原因是 /dev/video11 是 RKISP mainpath，原生输出 NV12，而 OpenCV VideoCapture 会隐式转换成 BGR，并带来 GStreamer / OpenCV 封装开销。实验中 OpenCV 链路只有几 FPS 到十几 FPS，而 V4L2 mmap 直接采集 NV12 可以接近 30FPS。为了实时性，最终选择 V4L2 mmap + RGA。
```

---

### 9.3 RGA 在项目里做什么？

```text
RGA 主要做图像格式转换。

摄像头输出是 NV12，而 YOLO11 RKNN 推理接口需要 RGB888，所以推理前做 NV12 → RGB888。检测框绘制后，要送给 MPP H.264 编码器，而 MPP 输入使用 NV12，所以编码前再做 RGB888 → NV12。也就是 RGA 在推理前和编码前各承担一次关键格式转换。
```

---

### 9.4 MPP 编码为什么要自己封装？

```text
最开始用 mpi_enc_test 是为了快速验证 MPP 编码环境和 NV12 输入是否正确。但如果最终工程还依赖外部测试程序，帧生命周期、队列、时间戳和异常处理都不好控制。后面我封装了 MppH264Encoder，把 MPP 初始化、SPS/PPS header 获取、NV12 帧编码、packet 输出和资源释放统一放在自己的 C++ 类中，这样主程序可以直接管理编码流程，也方便后续做异步编码和 PTS 元数据记录。
```

---

### 9.5 异步编码线程解决了什么？

```text
串行版本中，每帧检测后还要在主循环里执行 MPP encode 和 fwrite，虽然编码平均只有约 2.8ms，但放在 30FPS 链路里会让总耗时超过 33.33ms，帧率下降到约 27FPS。异步编码后，主线程只把 NV12 帧 push 到队列，平均只需要约 0.1~0.2ms；编码线程单独 pop 帧并执行 MPP encode。这样检测和编码可以并行，帧率恢复接近 30FPS。
```

---

### 9.6 实验26 的时间戳同步怎么解释？

```text
实验25 中音频裁剪主要依赖脚本记录的音频和视频进程启动时间差，这只能做到文件级大致对齐。实验26 进一步使用 V4L2 buffer timestamp 作为视频真实采集时间，用 ALSA htimestamp 和采样帧数估算音频流起点，然后把两者统一到 monotonic 时间轴上。

视频侧不再用 frame_id / fps 生成 PTS，而是使用当前帧 V4L2 timestamp 减去第一帧 V4L2 timestamp 得到 video_sync_pts_us，并写入 MPP encoder。音频侧根据 first_video_v4l2_ts_ns 和 audio_stream_start_est_ns 计算 audio_trim_s，再用 FFmpeg atrim 裁剪音频。这样 MP4 的视频时间轴和音频裁剪都来自采集层时间戳，比进程启动时间对齐更严谨。
```

---

## 10. 最终推荐写进简历的版本

如果只能选一个版本，我推荐下面这个：

```text
基于 RK3588 的端侧 AI 音视频实时检测与流媒体系统
技术栈：C++、Linux、V4L2、RGA、RKNN、Rockchip MPP、ALSA、FFmpeg、MediaMTX、RTSP、MP4、CMake

- 基于 LubanCat / RK3588 构建端侧 AI 音视频实时检测系统，完成 YOLO11 RKNN 模型加载、NPU 推理、检测框绘制、H.264 编码、AAC 音频接入、RTSP 双轨推流和 MP4 双轨录像。
- 针对 OpenCV VideoCapture 读取 RKISP 摄像头节点性能不足的问题，改用 V4L2 mmap 采集 1280×720 NV12 数据，并通过 RGA 完成 NV12/RGB888 双向转换，使输入链路接近 30FPS。
- 对 RKNN 推理链路进行阶段级 profiling，拆解 rknn_run、post_process、letterbox 等耗时，通过 Release/O3、performance governor 与日志精简，将完整检测链路从约 18.7FPS 优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块 `MppH264Encoder`，实现 SPS/PPS 获取、NV12 帧编码、PTS 回读和资源释放，并接入异步编码线程，降低检测主循环阻塞。
- 接入 ALSA `hw:2,0` 实时音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流，并完成 9000 帧 / 约 300 秒稳定性验证。
- 实现基于 libavformat 的 H.264 视频 MP4 muxer，并进一步合成 H.264 + AAC 双轨 MP4；基于 V4L2 buffer timestamp 与 ALSA htimestamp 构建采集层时间轴，优化音视频同步封装方案。
```

---

## 11. 后续如果继续优化，优先级建议

当前项目已经可以收尾。如果后续还要继续做，建议不要再随意加实验，而是按简历价值排序：

### 11.1 最高优先级：整理项目材料

```text
1. README.md：项目简介、架构图、运行方式、最终结果；
2. docs/experiment_index.md：实验索引更新到 26；
3. final_review.md：本文档；
4. 保存 VLC / ffprobe / MP4 / 资源监控截图；
5. 准备 1 分钟、3 分钟、10 分钟三个版本的面试讲解。
```

### 11.2 中等优先级：代码结构清理

```text
1. 把最终主链路代码和实验临时代码分开；
2. scripts 目录保留 final / check / stop / record 等关键脚本；
3. docs 中保留最终索引，避免 26 个实验文档显得杂乱；
4. 为 MppH264Encoder、V4L2 capture、RGA convert 写简单注释。
```

### 11.3 低优先级：继续功能扩展

```text
1. 多 RKNN context / 三 NPU worker；
2. DMA-BUF / zero-copy；
3. Web 控制台；
4. 24h 稳定性；
5. 自研 RTSP Server；
6. 物理事件级音视频同步标定。
```

这些方向可以作为后续展望，不建议现在继续拖慢项目收尾。

---

## 12. 最终复盘结论

这个项目已经可以正式作为简历核心项目。

它的主线应该总结为：

```text
从官方 YOLO11 RKNN Demo 出发，逐步迁移为自有 C++ 工程；
通过 profiling 发现 OpenCV 摄像头输入瓶颈，改用 V4L2 mmap + RGA；
通过 Release/O3、performance governor 和后处理分析将 RKNN 检测链路优化至接近 30FPS；
通过 Rockchip MPP 完成 H.264 硬件编码，并进一步封装为自研 C++ 编码模块；
通过异步编码线程解耦检测主循环和编码流程；
通过 ALSA + AAC 接入音频，形成 H.264 + AAC RTSP 双轨推流；
通过编码端 PTS、libavformat MUX 和 V4L2/ALSA 采集层 timestamp，扩展为双轨 MP4 录像和时间戳驱动同步封装。
```

一句话最终结论：

```text
本项目完成了一个基于 RK3588 的端侧 AI 音视频实时检测与流媒体系统，覆盖 V4L2 摄像头采集、RGA 图像处理、RKNN NPU 推理、MPP H.264 编码、ALSA 音频采集、AAC 编码、RTSP 双轨推流、MP4 双轨录像和采集层时间戳同步验证，具备较完整的嵌入式 AI 音视频系统工程价值。
```

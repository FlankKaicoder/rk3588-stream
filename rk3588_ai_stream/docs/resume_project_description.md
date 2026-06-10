# RK3588 项目简历表述与面试话术

> 目标：将当前 RK3588 端侧 AI 音视频实时检测推流项目整理为简历可用表述、面试口述版本和可扩展技术问答。  
> 注意：以下表述尽量保守，只写已经实际完成和验证过的内容，不夸大为未验证的 Zero-Copy、三 NPU 并行推理池或完整 Web 控制台。

---

## 1. 简历项目名称建议

推荐名称：

```text
基于 RK3588 的端侧 AI 音视频实时检测推流系统
```

可选名称：

```text
RK3588 端侧 AI 实时检测与 RTSP 音视频推流系统
```

更偏嵌入式 AI 岗位：

```text
基于 RK3588 NPU 的端侧视觉检测与音视频流媒体系统
```

更偏音视频 / 流媒体岗位：

```text
基于 RK3588 的 H.264/AAC 双轨实时推流与 AI 检测系统
```

---

## 2. 简历精简版项目描述

适合简历项目经历中直接使用：

```text
基于 RK3588 的端侧 AI 音视频实时检测推流系统

技术栈：C++、Linux、V4L2、RGA、RKNN、Rockchip MPP、ALSA、FFmpeg、MediaMTX、RTSP、CMake

- 基于 LubanCat / RK3588 平台搭建端侧 AI 实时检测系统，完成 YOLO11 RKNN 模型在板端的加载、推理、后处理与检测结果绘制。
- 针对 OpenCV VideoCapture 读取 RKISP 摄像头性能不足的问题，改用 V4L2 mmap 直接采集 /dev/video11 的 1280×720 NV12 数据，并通过 RGA 完成 NV12/RGB888 双向转换，提升输入链路实时性。
- 对 RKNN 推理函数进行分阶段性能剖析，拆解 letterbox、rknn_run、outputs_get、post_process 等耗时，并通过 Release/O3 编译优化、performance governor 与日志精简，将完整检测链路优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块，实现 MppH264Encoder 的初始化、SPS/PPS 获取、NV12 帧编码与资源释放，并将编码逻辑接入异步编码线程，降低检测主循环阻塞。
- 接入 ALSA hw:2,0 实时音频采集，使用 FFmpeg 编码 AAC，并与 H.264 视频流封装为 RTSP 双轨流，通过 MediaMTX 发布，支持 VLC / ffprobe 拉流验证。
- 完成 9000 帧 / 约 300 秒稳定性验收，系统达到 29.992FPS，H.264 + AAC 双轨正常，编码失败和丢帧均为 0，RGA、xrun、timestamp、broken pipe 等异常计数均为 0。
```

---

## 3. 简历更短版项目描述

适合简历空间不够时使用：

```text
基于 RK3588 的端侧 AI 音视频实时检测推流系统

技术栈：C++、Linux、V4L2、RGA、RKNN、MPP、ALSA、FFmpeg、MediaMTX、RTSP

- 搭建 RK3588 端侧 YOLO11 实时检测链路，使用 V4L2 mmap 采集 1280×720 NV12 摄像头数据，并通过 RGA 完成 NV12/RGB888 双向转换。
- 对 RKNN 推理链路进行 profiling，拆解 rknn_run、后处理、letterbox 等耗时，通过 Release/O3 和 performance governor 优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码器并接入异步编码线程，实现检测画面的 H.264 实时编码和 FIFO 输出。
- 接入 ALSA 音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流。
- 完成 9000 帧 / 约 300 秒稳定性测试，最终 wall_fps=29.992，编码失败与丢帧为 0，音视频双轨和异常检查均通过。
```

---

## 4. 如果只放 4 条 bullet

```text
- 基于 RK3588 完成 YOLO11 RKNN 端侧部署，构建 V4L2 + RGA + RKNN 实时检测链路，绕开 OpenCV 摄像头输入瓶颈。
- 对推理链路进行 profiling，定位 rknn_run、post_process、letterbox 等耗时，通过 Release/O3、performance governor 与日志精简优化到接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块，并设计异步编码线程，将检测帧编码为 H.264 码流输出至 FIFO。
- 接入 ALSA 音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流，完成 9000 帧 / 约 300 秒稳定性验收。
```

---

## 5. 面试自我介绍版

当面试官让你介绍这个项目时，可以这样说：

```text
这个项目是我基于 RK3588 做的一个端侧 AI 音视频实时检测推流系统。

一开始我不是直接写最终链路，而是从鲁班猫官方 YOLO11 RKNN Demo 开始，把单图检测、视频文件检测、摄像头检测逐步迁移到自己的 C++ 工程里。之后我发现 OpenCV VideoCapture 读取 RKISP 摄像头节点性能比较差，因为 /dev/video11 原生输出是 NV12，OpenCV 会有隐式格式转换和封装开销，所以我改成了 V4L2 mmap 直接采集 NV12，再用 RGA 做 NV12 到 RGB 的转换。

在接入 RKNN 后，初始完整链路大概只有十几 FPS，所以我对 inference_yolo11_model 做了内部 profiling，把 letterbox、rknn_inputs_set、rknn_run、outputs_get、post_process 等阶段拆开统计，最后通过 Release/O3 编译、performance governor、后处理优化和日志精简，把完整检测链路优化到接近 30FPS。

后面我又接入了 Rockchip MPP 硬件编码。开始是用外部 mpi_enc_test 验证，后面自己封装了一个 MppH264Encoder 类，提供 init、get_header、encode、release 接口，并把编码逻辑拆到异步编码线程里，避免阻塞检测主循环。

最后我把音频也接进来了，用 ALSA hw:2,0 采集 PCM，FFmpeg 编码 AAC，再把自研 MPP 输出的 H.264 和 AAC 音频封装成 RTSP 双轨流，通过 MediaMTX 发布，VLC 和 ffprobe 都能拉到 H.264 + AAC。最终做了 9000 帧、约 300 秒稳定性测试，wall_fps 是 29.992，编码失败和丢帧都是 0，RGA、xrun、timestamp、broken pipe 等异常也都是 0。
```

---

## 6. 面试官可能追问：你这个项目的难点是什么？

可以回答：

```text
我觉得主要有四个难点。

第一个是摄像头输入瓶颈。最初用 OpenCV VideoCapture 虽然能读到图像，但是 FPS 很低。后来通过 v4l2-ctl 和 profiling 发现 /dev/video11 是 RKISP mainpath，原生输出 NV12，OpenCV 读取时存在隐式格式转换，所以我改成 V4L2 mmap 直接采集 NV12，再用 RGA 做格式转换。

第二个是推理链路优化。接入 RKNN 后初始只有十几 FPS，我没有盲目加线程，而是先拆 inference_yolo11_model 的内部耗时，发现 rknn_run、post_process、letterbox 都有影响，最后通过 Release/O3、performance governor 和减少日志输出把链路稳定到接近 30FPS。

第三个是 MPP 编码工程化。开始用外部 mpi_enc_test 做编码验证，但这不适合写成完整工程，所以我自己封装了 MppH264Encoder，并把编码拆成异步线程，主线程只负责采集、推理、画框和投递帧，编码线程负责 H.264 输出。

第四个是音视频双轨稳定性。视频 H.264 和音频 AAC 的输入源不同，一个来自 FIFO，一个来自 ALSA，最后要由 FFmpeg 封装 RTSP。这里需要处理 ffprobe 时机、队列大小、timestamp、xrun、broken pipe 这些问题，最终通过日志统计和 300 秒稳定性测试确认链路稳定。
```

---

## 7. 面试官可能追问：为什么不用 OpenCV？

```text
OpenCV 在早期验证阶段很方便，但在这个项目里最终没有继续用它做摄像头采集，主要是因为 /dev/video11 是 RKISP mainpath，原生输出是 1280×720 NV12，而 OpenCV VideoCapture 读取时会做隐式转换和封装，导致采集链路本身就达不到稳定 30FPS。

我后面用 V4L2 mmap 直接采集 NV12，减少中间封装和拷贝，再用 RGA 做 NV12 到 RGB 的硬件转换。这样输入链路可以接近 30FPS，后续再分析 RKNN 推理才有意义。
```

---

## 8. 面试官可能追问：RGA 在项目里做了什么？

```text
RGA 主要负责图像格式转换。

摄像头 /dev/video11 输出的是 NV12，而 YOLO11 RKNN 推理接口需要 RGB888，所以推理前需要 NV12 到 RGB888。检测框画完之后，要送给 MPP H.264 编码器，而 MPP 编码输入使用 NV12，所以还需要 RGB888 转回 NV12。

所以 RGA 在项目里承担了两次关键转换：
1. 推理前：NV12 → RGB888；
2. 编码前：RGB888 → NV12。

这比用 CPU 或 OpenCV 做颜色转换更适合 RK3588 这种端侧平台。
```

---

## 9. 面试官可能追问：你怎么定位性能瓶颈？

```text
我分阶段做 profiling，而不是只看整体 FPS。

最开始摄像头检测很慢，我先把 capture、resize、cvtColor、model_total、draw、write 分开计时，发现 OpenCV capture 是大头。然后改成 V4L2 + RGA 后，输入链路接近 30FPS。

接入 RKNN 后整体又下降，于是继续拆 inference_yolo11_model，把 convert_image_with_letterbox、rknn_inputs_set、rknn_run、rknn_outputs_get、post_process、outputs_release 分开计时。后面又把 post_process 拆成 decode、sort、nms、pack，确认 decode 和整体后处理也占比较高。

最后通过 Release/O3 编译、performance governor、减少日志输出和保持 RGA/V4L2 输入链路，最终让完整检测链路接近 30FPS。
```

---

## 10. 面试官可能追问：MPP 编码为什么要自己封装？

```text
最初我用 mpi_enc_test 是为了验证 Rockchip MPP 编码环境和 NV12 输入是否正确。但 mpi_enc_test 是外部测试程序，如果最终工程还依赖它，整个链路就会变成“检测程序 + 外部编码进程 + FFmpeg”的拼接，不利于控制帧生命周期、队列、时间戳和异常处理。

所以我后面封装了 MppH264Encoder，把 MPP 初始化、H.264 header 获取、NV12 帧编码、packet 输出和资源释放放到自己的 C++ 类里。这样主程序可以直接控制编码流程，也方便进一步拆成异步编码线程。
```

---

## 11. 面试官可能追问：异步编码线程解决了什么问题？

```text
如果串行编码，主线程每帧要完成采集、RGA、RKNN、画框、RGB 转 NV12、MPP 编码和写 FIFO。MPP 编码虽然平均只有几毫秒，但它会直接叠加在主循环上，影响 30FPS 的稳定性。

所以我把编码拆成异步线程。主线程完成检测和 RGB 转 NV12 后，把帧投递给编码队列；编码线程独立调用 MPP 编码并写入 H.264 FIFO。这样可以把检测主循环和编码 I/O 解耦。最终 9000 帧测试中 async_encoded_frames=9000，encode_failures=0，drop_frames=0，说明异步编码线程稳定。
```

---

## 12. 面试官可能追问：音视频是怎么合流的？

```text
视频端是自研 MPP 编码线程输出 H.264 到 FIFO。音频端是 FFmpeg 从 ALSA hw:2,0 采集 PCM，然后编码成 AAC。最后 FFmpeg 同时读取 H.264 FIFO 和 ALSA 音频输入，把视频轨 copy，把音频编码为 AAC，再封装成 RTSP 推给 MediaMTX。

最终 ffprobe 能看到两条流：
1. Video: H.264 High Profile, 1280x720, 30fps；
2. Audio: AAC LC, 48000Hz, stereo。
```

---

## 13. 面试官可能追问：最终稳定性怎么证明？

```text
我做了 9000 帧、约 300 秒的最终稳定性测试。

结果是：
frames=9000；
wall_fps=29.992；
async_encoded_frames=9000；
async_encode_failures=0；
async_drop_frames=0；
ffprobe 能识别 H.264 + AAC；
MediaMTX 显示 2 tracks；
RGA_COLORFILL、Failed to call RockChipRga、xrun、Thread message queue blocking、Timestamps are unset、Broken pipe 这些异常计数都是 0。

同时资源监控显示 CPU 温度约 40~42℃，流媒体相关进程 RSS 约 140MB，没有明显内存泄漏和温度异常。
```

---

## 14. 简历中不建议写的内容

除非你后面真的完成了对应实验，否则当前简历中不建议写：

```text
1. 已实现三 NPU core 并行推理池；
2. 已实现完整 Zero-Copy 全链路；
3. 已直接操作 NC1HWC2 内存格式并完成端到端优化；
4. 已实现自研 RTSP Server；
5. 已实现浏览器 Web 控制台；
6. 已实现 4K 30FPS 完整检测推流；
7. 已完成 24 小时稳定性验证。
```

可以作为“后续优化方向”表达：

```text
后续可扩展多 RKNN context 推理池，利用 RK3588 三核 NPU 提升吞吐；
后续可进一步引入 DMA-BUF 零拷贝，减少用户态内存复制；
后续可构建 Web 控制台，实现参数配置、日志查看和录像管理。
```

---

## 15. 简历关键词

```text
RK3588
LubanCat
C++
Linux
V4L2
mmap
RGA
RKNN
YOLO11
NPU
Rockchip MPP
H.264
ALSA
AAC
FFmpeg
MediaMTX
RTSP
多线程
异步编码
性能剖析
端侧 AI
流媒体
稳定性测试
```

---

## 16. 简历最终推荐版本

如果只放一个项目，建议使用这一版：

```text
基于 RK3588 的端侧 AI 音视频实时检测推流系统
技术栈：C++、Linux、V4L2、RGA、RKNN、Rockchip MPP、ALSA、FFmpeg、MediaMTX、RTSP

- 基于 LubanCat / RK3588 平台构建端侧 AI 实时检测系统，完成 YOLO11 RKNN 模型板端加载、推理、后处理与检测结果绘制。
- 针对 OpenCV 摄像头采集性能不足问题，改用 V4L2 mmap 直接采集 /dev/video11 的 1280×720 NV12 数据，并通过 RGA 完成 NV12/RGB888 双向转换，提升输入链路实时性。
- 对 RKNN 推理链路进行分阶段 profiling，拆解 letterbox、rknn_run、outputs_get、post_process 等耗时，通过 Release/O3、performance governor 与日志精简将完整检测链路优化至接近 30FPS。
- 封装 Rockchip MPP H.264 编码模块，实现 SPS/PPS 获取、NV12 帧编码与资源释放，并设计异步编码线程降低检测主循环阻塞。
- 接入 ALSA hw:2,0 实时音频采集与 AAC 编码，通过 FFmpeg + MediaMTX 发布 H.264 + AAC RTSP 双轨流。
- 完成 9000 帧 / 约 300 秒稳定性验收，系统 wall_fps=29.992，编码失败与丢帧均为 0，音视频双轨和异常检查均通过。
```

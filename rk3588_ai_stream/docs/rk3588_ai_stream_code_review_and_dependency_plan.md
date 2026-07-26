# RK3588 端侧 AI 音视频项目：代码重温、依赖梳理与面试复习方案

> 项目：`rk3588_ai_stream`  
> 平台：LubanCat / RK3588  
> 建议名称：**基于 RK3588 的端侧 AI 音视频实时检测、推流与同步录制系统**  
> 最终主链路：V4L2 + RGA + RKNN + OpenCV + Rockchip MPP + ALSA + FFmpeg/libavformat + MediaMTX

---

# 1. 复习目标

不要把目标设成“背完所有代码”，而要达到四个层次：

1. 不看代码也能讲清完整数据流；
2. 能指出每个模块对应的源码、可执行文件和脚本；
3. 能区分源码、头文件、链接库、动态库、设备、模型和外部工具依赖；
4. 能解释每个关键设计为什么这样做。

最终应能完整口述：

```text
摄像头采集
→ 图像格式转换
→ NPU 推理
→ YOLO 后处理
→ 画框
→ 转回编码格式
→ 异步 H.264 编码
→ RTSP 推流或 MP4 录像
→ 音频采集与 AAC 编码
→ 时间戳对齐
→ 音视频双轨输出
```

---

# 2. 四层依赖模型

```text
第 4 层：业务编排层
    Bash 脚本、FFmpeg、MediaMTX、ffprobe、VLC

第 3 层：项目 C++ 应用层
    V4L2 主程序、RKNN 推理、MPP 编码、MP4 muxer、ALSA timestamp 工具

第 2 层：用户态库和 Runtime
    librknnrt、librga、librockchip_mpp、OpenCV、libavformat、
    libavcodec、libavutil、libasound、pthread、dl

第 1 层：Linux 内核与硬件
    /dev/video11、RKISP、RGA、RKNPU、MPP/VPU、ALSA hw:2,0
```

阅读任何代码时都问三件事：

```text
这一段属于哪一层？
它调用下一层什么接口？
它向上一层输出什么数据？
```

---

# 3. 三条最终运行链路

## 3.1 实时 AI 音视频 RTSP 推流

```text
/dev/video11
  ↓ V4L2 mmap
1280×720 NV12
  ↓ RGA
RGB888
  ↓ RKNN Runtime
YOLO11 输出 Tensor
  ↓ postprocess
检测框
  ↓ OpenCV
RGB 检测画面
  ↓ RGA
NV12
  ↓ 异步队列
编码线程
  ↓ MppH264Encoder
H.264 Annex-B packet
  ↓ FIFO
FFmpeg
  ├─ 视频：H.264 copy
  └─ 音频：ALSA PCM → AAC
  ↓ RTSP mux
MediaMTX
  ↓
VLC / ffprobe
```

主要分工：

| 对象 | 职责 |
|---|---|
| `build/exp21_detect_mpp_encode_async` | 摄像头、RGA、RKNN、画框、异步 MPP 编码 |
| H.264 FIFO | 连接 C++ 编码程序与 FFmpeg |
| `ffmpeg` | 读取 H.264、采集 ALSA、编码 AAC、RTSP MUX |
| `tools/mediamtx/mediamtx` | RTSP Server 与流分发 |
| `ffprobe` / VLC | 轨道验证和播放 |
| `scripts/exp22_av_async_mpp_rtsp.sh` | 启停与进程编排 |

## 3.2 视频 MP4 本地录制

```text
实时检测编码主程序
  ↓
H.264 Annex-B 文件 + PTS CSV
  ↓
build/exp24_mp4_mux_from_pts
  ↓
标准 video-only MP4
```

`src/main_exp24_mp4_mux_from_pts.cpp` 负责：

```text
读取 PTS CSV
→ 按 packet_size 切分 H.264 packet
→ 解析 SPS/PPS
→ 构造 avcC extradata
→ Annex-B NALU 转 AVCC sample
→ 设置 AVPacket.pts/dts/duration
→ 识别 IDR/keyframe
→ 使用 libavformat 写 MP4
```

## 3.3 采集层时间戳同步的 H.264 + AAC MP4

```text
视频：
V4L2 buffer.timestamp
→ video_sync_pts_us
→ MppFrame PTS
→ H.264 + PTS CSV + sync_meta.csv
→ 自研 video-only MP4 muxer

音频：
ALSA PCM + htimestamp
→ 估算音频流起点
→ 与第一帧 V4L2 timestamp 做差
→ atrim + asetpts
→ AAC

video-only MP4 + AAC
→ FFmpeg copy mux
→ 最终 H.264 + AAC 双轨 MP4
```

关键文件：

```text
src/main_exp21_detect_mpp_encode_async.cpp
src/main_exp26_alsa_pcm_capture_ts.cpp
src/main_exp26_v4l2_ts_probe.cpp
src/main_exp26_alsa_ts_probe.cpp
scripts/exp26_3_av_mp4_v4l2_alsa_ts.sh
```

准确表述应是：

```text
基于 V4L2 与 ALSA monotonic 采集层时间戳，
统一音视频起点和时间轴，完成同步 MP4 录制。
```

不要夸大为已经使用专业声画仪完成绝对 lip-sync 标定。

---

# 4. 源码—可执行文件—依赖关系

## 4.1 `image_detect`

文档中的基础 CMake 组成：

```text
src/main_image.cpp
third_party/lubancat_yolo11_ref/postprocess.cc
鲁班猫参考工程 rknpu2/yolo11.cc
```

项目库：

```text
imageutils
fileutils
imagedrawing
```

外部库：

```text
librknnrt
libdl
libpthread
```

运行文件：

```text
models/yolo11.rknn
model/coco_80_labels_list.txt
输入图片
```

该 target 只用于理解最小 RKNN 闭环：

```text
加载模型 → 准备输入 → rknn_run → 获取输出 → 后处理 → 画框
```

## 4.2 `exp21_detect_mpp_encode_async`

文档明确的源码组成：

```cmake
add_executable(exp21_detect_mpp_encode_async
    src/main_exp21_detect_mpp_encode_async.cpp
    src/mpp_h264_encoder.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    src/yolo11_clean_silent.cc
)
```

### `main_exp21_detect_mpp_encode_async.cpp`

负责：

```text
V4L2 打开、配置、mmap、DQBUF/QBUF
读取 V4L2 timestamp/sequence
RGA NV12→RGB
RKNN 推理调用
OpenCV 画框
RGA RGB→NV12
构造 Exp21EncFrame
生产者—消费者队列
性能统计
PTS CSV / sync_meta.csv
资源释放
```

关键头文件：

```cpp
linux/videodev2.h
sys/ioctl.h
sys/mman.h
yolo11.h
image_utils.h
file_utils.h
opencv2/opencv.hpp
im2d.hpp
RgaUtils.h
mpp_h264_encoder.hpp
```

### `mpp_h264_encoder.cpp/.hpp`

负责：

```text
MPP context 创建
H.264 配置
stride 对齐
SPS/PPS header 获取
NV12 拷贝到 MPP buffer
MppFrame 构造
输入 PTS 写入
编码与 packet 获取
输出 packet PTS/DTS/flags
MPP 资源释放
```

### `yolo11_clean_silent.cc`

负责：

```text
读取 .rknn
rknn_init
查询 tensor
letterbox/输入准备
rknn_inputs_set
rknn_run
rknn_outputs_get
调用 post_process
释放输出与模型
```

### `postprocess.cc`

负责：

```text
多尺度输出解码
INT8 反量化
阈值筛选
排序
NMS
坐标映射
类别名称
```

### 链接依赖

文档能够确认：

```text
${LIBRKNNRT}
librockchip_mpp.so
librga.so
OpenCV
imageutils
fileutils
pthread
dl
```

最终完整链接行应以板端当前 `CMakeLists.txt` 和 verbose build 为准。

## 4.3 `exp24_mp4_mux_from_pts`

源码：

```text
src/main_exp24_mp4_mux_from_pts.cpp
```

编译链接：

```text
libavformat
libavcodec
libavutil
```

运行输入：

```text
input.h264
input.pts.csv
width
height
fps
```

## 4.4 实验26音频工具

常见源码：

```text
src/main_exp26_alsa_ts_probe.cpp
src/main_exp26_alsa_pcm_capture_ts.cpp
```

依赖通常包括：

```text
alsa/asoundlib.h
libasound.so
pthread/C++ 标准库
```

实际 target 名称和链接行需要在板端 CMake 中确认。

---

# 5. 外部库、模型、设备和工具依赖

## 5.1 V4L2 / RKISP

```text
设备：/dev/video11
驱动：rkisp_v6
节点：rkisp_mainpath
格式：1280×720 NV12
类型：VIDEO_CAPTURE_MPLANE + STREAMING
```

关键 API：

```text
open
VIDIOC_QUERYCAP
VIDIOC_S_FMT
VIDIOC_REQBUFS
VIDIOC_QUERYBUF
mmap
VIDIOC_QBUF
VIDIOC_STREAMON
select
VIDIOC_DQBUF
VIDIOC_QBUF
VIDIOC_STREAMOFF
munmap
```

## 5.2 RGA

头文件：

```text
/usr/include/rga/im2d.hpp
/usr/include/rga/RgaUtils.h
```

动态库：

```text
/usr/lib/aarch64-linux-gnu/librga.so
```

用途：

```text
NV12↔RGB888
resize/letterbox 的部分图像处理
```

当前工程不是全链路 Zero-Copy，因为编码队列和 MPP buffer 之间存在复制。

## 5.3 RKNN

模型：

```text
models/yolo11.rknn
```

Runtime：

```text
librknnrt.so
```

标签：

```text
model/coco_80_labels_list.txt
```

板端运行通常不需要：

```text
yolo11n.pt
ONNX
RKNN-Toolkit2 Python 环境
训练数据集
```

这些属于训练/转换阶段。

关键 API：

```text
rknn_init
rknn_query
rknn_inputs_set
rknn_run
rknn_outputs_get
rknn_outputs_release
rknn_destroy
```

## 5.4 MPP

文档记录的 include：

```text
/home/cat/mpp/inc
/home/cat/mpp/mpp/inc
/home/cat/mpp/kmpp/base/inc
/home/cat/mpp/osal/inc
```

动态库候选：

```text
/home/cat/mpp/build/mpp/librockchip_mpp.so
/usr/lib/aarch64-linux-gnu/librockchip_mpp.so
/usr/local/lib/librockchip_mpp.so
```

必须用 `ldd` 确认最终加载哪个。

关键对象：

```text
MppCtx
MppApi
MppEncCfg
MppFrame
MppPacket
MppBuffer
```

## 5.5 OpenCV

最终仅主要用于：

```text
cv::Mat
rectangle
putText
getTextSize
imwrite(debug)
```

最终采集不依赖 `VideoCapture`，最终录像不依赖 `VideoWriter`。

## 5.6 ALSA

设备：

```text
hw:2,0
48 kHz
stereo
S16_LE
```

两种使用方式：

```text
FFmpeg 直接打开 ALSA：RTSP/AAC
C++ ALSA API：实验26 PCM + htimestamp
```

## 5.7 FFmpeg / libav

必须区分：

```text
ffmpeg：命令行程序
ffprobe：检查容器和 packet
libavformat/libavcodec/libavutil：C/C++ 链接库
```

项目使用 FFmpeg 命令行完成：

```text
AAC 编码
RTSP MUX
atrim
asetpts
音视频 copy mux
解码检查
```

## 5.8 MediaMTX

程序：

```text
tools/mediamtx/mediamtx
```

职责：

```text
接收 RTSP 发布
维护 path
向 VLC/ffprobe 分发
辅助提供 HLS/WebRTC
```

它不负责 AI 推理、H.264 编码或 ALSA 采集。

---

# 6. 最终主程序的阅读方法

不要从第一行机械读到最后一行。

## 第一遍：标记阶段边界

```text
参数解析
设备打开
V4L2 格式设置
buffer 申请/mmap/QBUF
MPP 初始化
RKNN 初始化
RGA buffer 准备
编码线程创建
STREAMON
主循环
编码线程收尾
STREAMOFF
资源释放
统计
```

目标：先画程序骨架。

## 第二遍：只追踪数据所有权

追踪四块内存：

```text
1. V4L2 mmap buffer
2. RGB buffer
3. 画框后转出的 NV12 buffer
4. Exp21EncFrame::nv12 独立副本
```

必须理解：

```text
DQBUF 后用户态暂时拥有 V4L2 buffer；
QBUF 后驱动可能马上复用它。
异步编码线程不能继续持有原 buffer 指针，必须复制。
```

## 第三遍：只看线程同步

关注：

```text
queue
mutex
condition_variable
atomic
enc_stop
max_enc_queue_size
```

需要回答：

```text
何时加锁？何时 push？何时 notify？
编码线程何时 wait？停止条件是什么？
队列满时为什么要丢帧？
退出前如何 drain 队列？
```

## 第四遍：只追踪时间戳

```text
V4L2 buf.timestamp
→ v4l2_ts_ns
→ video_sync_pts_us
→ Exp21EncFrame::pts_us
→ set_next_pts_us
→ mpp_frame_set_pts
→ mpp_packet_get_pts
→ pts.csv
→ MP4 AVPacket.pts
```

---

# 7. `MppH264Encoder` 阅读顺序

## 7.1 构造、析构、release

理解 RAII、重复释放安全和异常路径清理。

## 7.2 init

按四组参数看：

```text
prep：width/height/stride/format
rc：CBR、fps、GOP、bps
codec：AVC、profile、level、CABAC
control：GET_CFG / SET_CFG
```

## 7.3 get_header

理解：

```text
SPS/PPS 的作用
MPP_ENC_GET_HDR_SYNC
为什么 packet 要有有效存储
为什么先 set_length(0)
```

## 7.4 copy_nv12_to_mpp_buffer

```text
紧凑 NV12 = width×height×3/2
MPP buffer = hor_stride×ver_stride×3/2
```

1280×720 已 16 对齐时可整体 memcpy；非对齐尺寸要分别按行复制 Y/UV。

## 7.5 encode

```text
获取/创建 MPP buffer
→ 拷贝 NV12
→ 构造 MppFrame
→ 设置尺寸/stride/format/buffer/PTS
→ 提交 frame
→ 获取 packet
→ 读取 data/length/PTS/DTS/flag
→ 释放资源
```

---

# 8. RKNN 与后处理阅读顺序

## 8.1 `init_yolo11_model`

```text
读取 .rknn
rknn_init
查询 I/O 数量
查询 tensor attr
确认 layout/dtype/shape
记录模型宽高通道
```

## 8.2 `inference_yolo11_model`

按实验07阶段理解：

```text
convert_image_with_letterbox
rknn_inputs_set
rknn_run
rknn_outputs_get
post_process
rknn_outputs_release
```

核心认识：

```text
inference_yolo11_model != 纯 rknn_run
```

它还包括预处理、输出获取和 CPU 后处理。

## 8.3 `postprocess`

理解输入和输出，不要求背全部循环：

```text
三个尺度输出
量化 zp/scale
反量化
候选框
阈值
排序
NMS
坐标映射
```

---

# 9. MP4 muxer 阅读顺序

先理解：

```text
NALU：编码语法单元
Annex-B：start code + NALU
AVCC：length + NALU
MP4：轨道、sample、时间戳、索引的容器
```

重点函数：

```text
read_pts_csv
find_annexb_nalus
find_sps_pps
build_avcc_extradata
annexb_to_avcc_sample
写 AVPacket
```

当前未启用 B 帧，显示顺序和解码顺序一致，因此工程中采用：

```text
DTS = PTS
```

这不是所有 H.264 都成立；启用 B 帧后需要独立 DTS。

---

# 10. 音视频同步阅读顺序

旧方案：

```cpp
frame_id * 1000000 / 30
```

隐含前提：无跳帧、始终 30 FPS、处理节奏等于采集节奏。

新视频时间轴：

```text
video_sync_pts_us
= (current_v4l2_timestamp - first_v4l2_timestamp) / 1000
```

音频时间轴：

```text
根据 ALSA htimestamp 和已采集 sample 数
回推音频流起点
→ 与第一帧视频 timestamp 做差
→ audio_trim_s
→ atrim + asetpts
```

必须能解释旧方案为什么会压缩真实时间轴。

---

# 11. 编译系统复习

分清：

```text
编译：.cpp → .o，需要头文件/include path/宏/编译选项
链接：.o + library → executable，需要库和符号
运行：加载 executable + .so，需要动态库路径、设备、模型、配置和外部进程
```

每个核心 target 必查：

```bash
grep -n -A25 -B2 'add_executable(exp21_detect_mpp_encode_async' CMakeLists.txt
grep -n -A35 'target_include_directories(exp21_detect_mpp_encode_async' CMakeLists.txt
grep -n -A35 'target_link_libraries(exp21_detect_mpp_encode_async' CMakeLists.txt
cmake --build build --target exp21_detect_mpp_encode_async --verbose
ldd build/exp21_detect_mpp_encode_async
readelf -d build/exp21_detect_mpp_encode_async | grep -E 'NEEDED|RPATH|RUNPATH'
```

MP4 target 同样检查：

```bash
cmake --build build --target exp24_mp4_mux_from_pts --verbose
ldd build/exp24_mp4_mux_from_pts
```

---

# 12. 12 天复习计划

## 第 1 天：项目地图

```text
画三条最终链路
列出核心源码/target/脚本
理解四层依赖
```

## 第 2 天：CMake 与依赖

```text
运行依赖盘点脚本
掌握 add_executable/include/link/RPATH/ldd
输出核心 target 真实库列表
```

## 第 3 天：V4L2

不看代码写出完整 mmap 采集伪代码。

## 第 4 天：NV12、RGB 与 RGA

掌握内存布局、字节数、双向转换和 letterbox。

## 第 5 天：RKNN 与 postprocess

掌握模型加载、tensor、量化、三尺度解码和 NMS。

## 第 6 天：异步队列

画主线程与编码线程时序图，解释所有权和丢帧策略。

## 第 7 天：MPP H.264

不看代码讲完一帧 NV12 变成 H.264 packet 的全过程。

## 第 8 天：H.264 与 MP4

掌握 NALU、Annex-B、AVCC、SPS/PPS、IDR、avcC、PTS/DTS。

## 第 9 天：ALSA、AAC、RTSP

逐条解释脚本中各进程启动顺序与 FIFO 作用。

## 第 10 天：采集层时间戳同步

讲清 V4L2 时间轴、ALSA 起点估算、atrim 和双轨合成。

## 第 11 天：重新编译和最小运行

依次跑：

```text
30 帧 V4L2/RGA
30 帧 RKNN
30 帧异步 MPP
H.264→MP4
短时 RTSP 双轨
短时同步 AV MP4
```

## 第 12 天：面试演练

准备：

```text
1 分钟结果版
3 分钟演进版
8 分钟技术深度版
```

---

# 13. 面试前自测题

## 架构

1. 系统有哪些线程和进程？
2. C++、FFmpeg、MediaMTX 分别负责什么？
3. RTSP 和 MP4 复用了哪些模块？

## V4L2

4. 为什么不用 OpenCV VideoCapture？
5. DQBUF/QBUF 的所有权含义是什么？
6. 为什么编码线程不能持有 mmap buffer 指针？

## RGA/RKNN

7. 为什么 NV12 要转 RGB？
8. `inference_yolo11_model()` 为什么不等于纯 NPU 时间？
9. 后处理为什么可能成为瓶颈？

## 线程

10. 队列为什么有上限？
11. 实时系统为什么允许丢帧？
12. 退出时如何处理剩余队列？

## MPP/H.264

13. MPP 初始化配置了什么？
14. stride 为什么对齐？
15. SPS/PPS、GOP、IDR 分别是什么？
16. 一个 MPP packet 是否一定只有一个 NALU？

## MP4

17. Annex-B 和 AVCC 有什么区别？
18. 为什么 MP4 需要 avcC？
19. PTS、DTS、duration 分别是什么？
20. 为什么当前 DTS=PTS？启用 B 帧后呢？

## 音频同步

21. PCM、AAC、M4A 有什么区别？
22. V4L2 timestamp 与 ALSA htimestamp 为什么能比较？
23. 旧 `frame_id/fps` 方案有什么前提？
24. 当前能否宣称专业仪器验证的绝对唇音同步？

## 编译依赖

25. 头文件找到但链接失败是什么原因？
26. 编译成功但运行找不到 `.so` 是什么原因？
27. `.rknn`、librknnrt 和 NPU 驱动是什么关系？
28. ffmpeg 命令与 libavformat 有什么区别？

---

# 14. 复习优先级

```text
第一优先级：
main_exp21_detect_mpp_encode_async.cpp
mpp_h264_encoder.cpp/.hpp
main_exp24_mp4_mux_from_pts.cpp
exp22_av_async_mpp_rtsp.sh
exp26_3_av_mp4_v4l2_alsa_ts.sh

第二优先级：
yolo11_clean_silent.cc
postprocess.cc
main_exp26_alsa_pcm_capture_ts.cpp
third_party/lubancat_common_utils/image_utils.c
CMakeLists.txt

第三优先级：
05、07、20、21、23、24、25、26 文档

第四优先级：
00～04、08～19 历史代码
```

最终代码是复习主线；历史实验只用于解释架构为什么演进到现在。

---

# 15. 完成标准

你能在不看代码时做到以下事情，就达到面试要求：

```text
画完整架构图
写核心 target 的源码和库依赖
口述一帧从摄像头到 RTSP/MP4 的全过程
解释四块关键内存的所有权
解释生产者—消费者线程
解释 MPP NV12→H.264
解释 Annex-B→AVCC→MP4
解释 V4L2 PTS 与 ALSA 对齐
明确自研与外部工具边界
用 verbose build、ldd、readelf 排查依赖
诚实说明非全链路 Zero-Copy、未做外部物理唇音标定
```

---

# 16. 仍需板端确认的内容

当前文档和源码已明确核心结构，但来源中没有完整展示板端最新 `CMakeLists.txt` 全文。因此需要用配套脚本确认：

```text
每个 target 的完整 target_link_libraries
最终加载系统 MPP 还是 /home/cat/mpp/build 下的库
实验26音频 target 是否直接链接 asound
二进制 RPATH/RUNPATH
当前 build 目录保留的全部 target
```

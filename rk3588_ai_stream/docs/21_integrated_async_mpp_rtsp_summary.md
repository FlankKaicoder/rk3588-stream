# 实验21：Rockchip MPP H.264 编码封装与异步 RTSP 推流实验总结

## 1. 实验背景

在前面的实验中，RK3588 AI 流媒体系统已经完成了：

```text
V4L2 摄像头采集
    ↓
RGA NV12 → RGB
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB → NV12
    ↓
NV12 FIFO
    ↓
外部 mpi_enc_test
    ↓
H.264 编码
    ↓
FFmpeg / MediaMTX
    ↓
RTSP 预览
```

这条链路已经可以稳定完成 720P 接近 30FPS 的 AI 检测推流，但是仍然有一个工程问题：

```text
MPP 编码还依赖外部 mpi_enc_test 工具。
```

这会导致：

```text
1. 编码逻辑不在自己的 C++ 主程序中；
2. 简历中不适合直接写“封装 MPP 编码模块”；
3. 后续做线程模型、缓冲队列、时间戳和推流优化时不够灵活；
4. 工程架构上仍然是“检测程序 + 外部编码程序”拼接，而不是完整主程序。
```

因此实验21的核心目标是：

```text
把 Rockchip MPP H.264 编码封装成自己的 C++ 模块，
并逐步集成到 V4L2 + RGA + RKNN 实时检测主程序中，
最后替代外部 mpi_enc_test，实现内部异步 MPP 编码 + RTSP 推流。
```

---

## 2. 实验目标

实验21分为 5 个阶段：

```text
21-1：NV12 文件 → 自定义 MPP Encoder → H.264 文件
21-2：V4L2 实时采集 NV12 → 自定义 MPP Encoder → H.264 文件
21-3：V4L2 + RGA + RKNN + 画框 + 串行 MPP 编码 → H.264 文件
21-4：V4L2 + RGA + RKNN + 画框 + 异步 MPP 编码线程 → H.264 文件
21-5：异步 MPP 编码 → H.264 FIFO → FFmpeg → MediaMTX → RTSP 实时预览
```

最终希望实现：

```text
V4L2 摄像头采集
    ↓
RGA 格式转换
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB → NV12
    ↓
C++ 内部异步 MPP H.264 编码
    ↓
H.264 FIFO
    ↓
FFmpeg RTSP 封装
    ↓
MediaMTX 分发
    ↓
VLC / ffprobe 实时预览
```

---

## 3. 实验环境

### 3.1 硬件与系统

```text
开发板        ：RK3588 / LubanCat
摄像头设备    ：/dev/video11
V4L2 driver   ：rkisp_v6
V4L2 card     ：rkisp_mainpath
输入格式      ：NV12
输入分辨率    ：1280x720
目标帧率      ：30FPS
```

### 3.2 软件模块

```text
采集            ：V4L2 mmap
图像转换        ：RGA
AI 推理         ：RKNN YOLO11
编码            ：Rockchip MPP H.264
封装 / 推流     ：FFmpeg
RTSP 服务器     ：MediaMTX
验证工具        ：ffprobe / VLC
```

### 3.3 关键库路径

实验中 MPP 头文件和库分布比较分散，最终使用的是：

```text
MPP root        ：/home/cat/mpp
MPP include     ：/home/cat/mpp/inc
MPP include     ：/home/cat/mpp/mpp/inc
MPP include     ：/home/cat/mpp/kmpp/base/inc
MPP include     ：/home/cat/mpp/osal/inc
MPP library     ：/home/cat/mpp/build/mpp/librockchip_mpp.so
```

RKNN Runtime 使用工程原有变量：

```cmake
${LIBRKNNRT_INCLUDES}
${LIBRKNNRT}
```

---

## 4. 新增文件与目标

### 4.1 新增核心文件

```text
include/mpp_h264_encoder.hpp
src/mpp_h264_encoder.cpp
```

作用：

```text
封装 Rockchip MPP H.264 编码器。
```

主要接口：

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

### 4.2 新增实验主程序

```text
src/main_exp21_mpp_file_encode.cpp
    21-1：NV12 文件输入，MPP 编码输出 H.264。

src/main_exp21_v4l2_mpp_encode.cpp
    21-2：V4L2 实时采集 NV12，MPP 编码输出 H.264。

src/main_exp21_detect_mpp_encode.cpp
    21-3 / 21-3b / 21-3c：
    V4L2 + RGA + RKNN + 画框 + 串行 MPP 编码。

src/main_exp21_detect_mpp_encode_async.cpp
    21-4：
    V4L2 + RGA + RKNN + 画框 + 异步 MPP 编码线程。

src/yolo11_clean_silent.cc
    从官方 yolo11.cc 复制而来，关闭每帧 rknn_run 打印。

scripts/exp21_5_async_mpp_rtsp.sh
    21-5：
    异步 MPP 编码输出 H.264 FIFO，并由 FFmpeg 推送到 MediaMTX。
```

### 4.3 新增 CMake target

```text
exp21_mpp_file_encode
exp21_v4l2_mpp_encode
exp21_detect_mpp_encode
exp21_detect_mpp_encode_async
```

---

## 5. MPP 编码封装设计

### 5.1 初始化流程

`MppH264Encoder::init()` 中完成：

```text
1. 设置 width / height / fps / bitrate；
2. 按 16 字节对齐计算 hor_stride / ver_stride；
3. 调用 mpp_create；
4. 调用 mpp_init，类型为 MPP_CTX_ENC + MPP_VIDEO_CodingAVC；
5. 初始化 MppEncCfg；
6. 配置 prep 参数；
7. 配置 rc 码率控制参数；
8. 配置 H.264 profile / level / CABAC；
9. 调用 MPP_ENC_SET_CFG 生效。
```

### 5.2 输入格式

当前输入格式固定为：

```text
NV12 / MPP_FMT_YUV420SP
```

对于 1280x720：

```text
width       = 1280
height      = 720
hor_stride  = 1280
ver_stride  = 720
frame_size  = 1280 * 720 * 3 / 2 = 1382400 bytes
```

### 5.3 H.264 头信息

编码前调用：

```cpp
mpp_encoder.get_header(h264_header);
```

用于获取 SPS / PPS，并写入 H.264 文件或 FIFO：

```cpp
fwrite(h264_header.data(), 1, h264_header.size(), fout);
```

实验中 header 大小为：

```text
39 bytes
```

### 5.4 编码接口

每帧调用：

```cpp
mpp_encoder.encode(nv12_data, nv12_size, h264_packet);
```

输出：

```text
h264_packet
```

然后写入文件或 FIFO。

---

## 6. 实验21-1：NV12 文件 → 自定义 MPP → H.264

### 6.1 实验目的

先不接摄像头、不接 RKNN、不接 RTSP，只验证：

```text
自定义 MppH264Encoder 能否把已有 NV12 文件编码成可识别 H.264。
```

### 6.2 运行链路

```text
output/exp08_mpp_encode_record/input_120f_1280x720.nv12
    ↓
exp21_mpp_file_encode
    ↓
output/exp21_1_mpp_file_encode/exp21_1_test.h264
    ↓
ffmpeg 封装 MP4
    ↓
ffprobe 验证
```

### 6.3 关键结果

```text
input nv12      ：output/exp08_mpp_encode_record/input_120f_1280x720.nv12
output h264     ：output/exp21_1_mpp_file_encode/exp21_1_test.h264
width           ：1280
height          ：720
fps             ：30
frames          ：120
bitrate         ：4000000
frame size      ：1382400

got h264 header ：39 bytes
encoded_frames ：120
wall_time_ms   ：896.293
wall_fps       ：133.885
packet bytes   ：1915666
```

ffprobe 结果：

```text
Video: h264 (High), yuv420p, 1280x720, 3831 kb/s, 30 fps
Duration: 00:00:04.00
```

### 6.4 结论

```text
自定义 MPP H.264 编码器基础功能正确；
H.264 header 可以正常输出；
H.264 packet 可以被 ffmpeg 封装；
ffprobe 能识别为 H.264 High Profile 1280x720 30FPS；
离线编码速度达到 133.885FPS，说明 MPP 编码能力充足。
```

---

## 7. 实验21-2：V4L2 实时采集 → 自定义 MPP → H.264

### 7.1 实验目的

验证：

```text
真实摄像头 V4L2 NV12 采集帧能否直接送入自定义 MPP 编码器。
```

### 7.2 运行链路

```text
/dev/video11
    ↓
V4L2 mmap 采集 NV12
    ↓
MppH264Encoder
    ↓
camera_120f_1280x720.h264
    ↓
ffmpeg 封装 MP4
```

### 7.3 V4L2 信息

```text
driver     ：rkisp_v6
card       ：rkisp_mainpath
actual fmt ：1280x720 NV12
planes     ：1
sizeimage  ：1382400
bytesperline：1280
buffer 数量：4
```

### 7.4 关键结果

```text
encoded_frames    ：120
wall_time_ms      ：4050.399
wall_fps          ：29.627
avg_select_ms     ：30.294
avg_dqbuf_ms      ：0.006
avg_encode_ms     ：3.283
avg_write_ms      ：0.099
avg_qbuf_ms       ：0.067
avg_total_ms      ：33.751
h264_packet_bytes ：1910671
```

ffprobe 结果：

```text
Video: h264 (High), yuv420p, 1280x720, 3821 kb/s, 30 fps
Duration: 00:00:04.00
```

### 7.5 结论

```text
V4L2 实时采集 + 自定义 MPP 编码链路成功；
摄像头输入本身稳定接近 30FPS；
MPP 编码平均耗时约 3.283ms；
MPP 编码不是瓶颈。
```

---

## 8. 实验21-3：AI 检测 + 串行 MPP 编码

### 8.1 实验目的

将 MPP 编码集成到原来的 AI 检测主程序中。

旧流程：

```text
V4L2 → RGA → RKNN → draw → RGA → 写 NV12 FIFO → mpi_enc_test
```

新流程：

```text
V4L2 → RGA → RKNN → draw → RGA → MppH264Encoder → H.264 文件
```

### 8.2 串行版本结构

```text
主线程中依次执行：
1. V4L2 DQBUF
2. RGA NV12 → RGB
3. RKNN YOLO11 推理
4. 画框
5. RGA RGB → NV12
6. MPP encode
7. fwrite H.264 packet
8. V4L2 QBUF
```

### 8.3 21-3 profile 版结果

```text
frames              ：120
wall_time_ms        ：4364.666
wall_fps            ：27.494
avg_select_ms       ：0.677
avg_dqbuf_ms        ：0.004
avg_rga_nv12_to_rgb ：1.786
avg_input_prepare   ：0.001
avg_model_total_ms  ：28.075
avg_draw_ms         ：0.193
avg_rga_rgb_to_nv12 ：2.653
avg_mpp_encode_write：2.882
avg_qbuf_ms         ：0.049
avg_total_ms        ：36.321
```

ffprobe：

```text
Video: h264 (High), yuv420p, 1280x720, 3840 kb/s, 30 fps
```

### 8.4 问题分析

21-3 串行版本帧率下降到约 27.5FPS，主要原因不是 MPP 性能不足，而是：

```text
MPP encode 被串行放进主循环；
每帧额外占用约 2.8ms；
总耗时从约 33ms 增加到约 36ms。
```

粗略相加：

```text
model_total_ms      ≈ 28.075
rga_in              ≈ 1.786
rga_out             ≈ 2.653
mpp_encode_write    ≈ 2.882
draw                ≈ 0.193

合计 ≈ 35.589ms
```

所以实际：

```text
1000 / 36.321 ≈ 27.5FPS
```

这与实测结果一致。

---

## 9. 实验21-3b：clean 版 YOLO 源码对比

### 9.1 实验目的

确认 27FPS 是否由 profile 版 YOLO 源码额外计时 / 打印造成。

将 CMake 中：

```text
src/yolo11_profile.cc
src/postprocess_profile.cc
```

改为：

```text
src/yolo11_clean_silent.cc
third_party/lubancat_yolo11_ref/postprocess.cc
```

### 9.2 结果

```text
frames              ：120
wall_time_ms        ：4342.752
wall_fps            ：27.632
avg_select_ms       ：0.678
avg_dqbuf_ms        ：0.004
avg_rga_nv12_to_rgb ：1.826
avg_input_prepare   ：0.001
avg_model_total_ms  ：27.904
avg_draw_ms         ：0.171
avg_rga_rgb_to_nv12 ：2.730
avg_mpp_encode_write：2.779
avg_qbuf_ms         ：0.048
avg_total_ms        ：36.141
```

对比：

```text
21-3  profile 版 wall_fps：27.494
21-3b clean   版 wall_fps：27.632
```

### 9.3 结论

```text
从 profile 版切换到 clean 版只有小幅提升；
主要瓶颈不是 profile 代码；
核心瓶颈仍然是串行架构。
```

---

## 10. 实验21-3c：关闭每帧 debug 打印

### 10.1 问题

日志中存在大量每帧打印：

```text
scale=0.500000 dst_box=...
rknn_run
frame=xxx person @ ...
```

其中：

```text
scale=... 来自 third_party/lubancat_common_utils/image_utils.c
rknn_run 来自 yolo11.cc
```

### 10.2 处理方式

不修改官方源码，复制官方 yolo11.cc 到工程中：

```text
src/yolo11_clean_silent.cc
```

并注释掉每帧：

```cpp
printf("rknn_run\n");
```

保留错误打印：

```cpp
printf("rknn_run fail! ret=%d\n", ret);
```

对 `third_party/lubancat_common_utils/image_utils.c` 中的 `scale=...` 打印也进行注释。

### 10.3 结论

该步骤主要用于清理日志和降低长期运行干扰，不是主要性能优化点。

---

## 11. 实验21-4：异步 MPP 编码线程

### 11.1 实验目的

解决 21-3 串行编码导致帧率下降的问题。

将架构从：

```text
主线程：
采集 → RGA → RKNN → draw → RGA → MPP encode → fwrite → QBUF
```

改为：

```text
主线程：
采集 → RGA → RKNN → draw → RGA → push NV12 到队列 → QBUF

编码线程：
pop NV12 → MPP encode → fwrite H.264
```

### 11.2 队列结构

```cpp
struct Exp21EncFrame
{
    int frame_id = 0;
    std::vector<unsigned char> nv12;
};
```

异步队列：

```cpp
std::queue<Exp21EncFrame> enc_queue;
std::mutex enc_mutex;
std::condition_variable enc_cv;
std::atomic<bool> enc_stop(false);
std::atomic<int> async_encoded_frames(0);
std::atomic<int> async_encode_failures(0);
std::atomic<int> async_drop_frames(0);
```

队列最大长度：

```cpp
const size_t max_enc_queue_size = 8;
```

如果队列异常堆积：

```cpp
if (enc_queue.size() >= max_enc_queue_size) {
    enc_queue.pop();
    async_drop_frames++;
}
```

### 11.3 主线程变化

串行版本中主线程直接执行：

```cpp
mpp_encoder.encode(out_nv12_buf.data(), nv12_size, h264_packet);
fwrite(h264_packet.data(), 1, h264_packet.size(), fout);
```

异步版本中主线程只执行：

```cpp
Exp21EncFrame enc_frame;
enc_frame.frame_id = frame_id;
enc_frame.nv12.assign(out_nv12_buf.begin(), out_nv12_buf.end());

{
    std::lock_guard<std::mutex> lk(enc_mutex);
    enc_queue.push(std::move(enc_frame));
}

enc_cv.notify_one();
```

### 11.4 21-4 结果

```text
frames              ：120
wall_time_ms        ：4080.632
wall_fps            ：29.407
avg_select_ms       ：1.725
avg_dqbuf_ms        ：0.003
avg_rga_nv12_to_rgb ：1.757
avg_input_prepare   ：0.001
avg_model_total_ms  ：27.395
avg_draw_ms         ：0.148
avg_rga_rgb_to_nv12 ：2.742
avg_mpp_queue_push  ：0.167
avg_qbuf_ms         ：0.030
avg_total_ms        ：33.968
```

编码线程统计：

```text
async_encoded_frames ：120
async_encode_failures：0
async_drop_frames    ：0
async_avg_encode_ms  ：2.820
async_avg_write_ms   ：0.058
async_avg_total_ms   ：2.878
```

ffprobe：

```text
Video: h264 (High), yuv420p, 1280x720, 3824 kb/s, 30 fps
```

### 11.5 对比结论

```text
21-3b 串行 MPP：
wall_fps             ：27.632
avg_mpp_encode_write ：2.779ms
avg_total_ms         ：36.141ms

21-4 异步 MPP：
wall_fps             ：29.407
avg_mpp_queue_push   ：0.167ms
avg_total_ms         ：33.968ms
```

结论：

```text
串行编码会额外占用主循环约 2.8ms；
异步编码后，主循环只承担 queue_push，平均 0.167ms；
检测和编码可以并行；
系统帧率从 27.6FPS 回升到 29.4FPS。
```

---

## 12. 实验21-5：异步 MPP → H.264 FIFO → RTSP

### 12.1 实验目标

将 21-4 的 H.264 文件输出改为 H.264 FIFO，并由 FFmpeg 推送到 MediaMTX。

最终链路：

```text
V4L2 摄像头采集
    ↓
RGA NV12 → RGB
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB → NV12
    ↓
C++ 内部异步 MPP H.264 编码
    ↓
H.264 FIFO
    ↓
FFmpeg RTSP 封装
    ↓
MediaMTX
    ↓
RTSP 预览
```

### 12.2 脚本

新增：

```text
scripts/exp21_5_async_mpp_rtsp.sh
```

运行示例：

```bash
./scripts/exp21_5_async_mpp_rtsp.sh \
  1280 \
  720 \
  30 \
  300 \
  models/yolo11.rknn \
  /dev/video11 \
  exp21_5_async_mpp_rtsp
```

### 12.3 FFmpeg 命令核心

```bash
ffmpeg -hide_banner -loglevel info \
  -fflags +genpts \
  -f h264 \
  -r "$FPS" \
  -i "$FIFO" \
  -an \
  -c:v copy \
  -f rtsp \
  -rtsp_transport tcp \
  "$STREAM_URL_LOCAL"
```

后续为减少 timestamp warning，可加入：

```bash
-use_wallclock_as_timestamps 1
```

### 12.4 MediaMTX 配置

为了避免 HLS / WebRTC 额外日志干扰，21-5 中只验证 RTSP：

```yaml
rtspAddress: :8554

hls: false
webrtc: false

paths:
  all_others:
```

---

## 13. 21-5 首次问题：MediaMTX 路径误判

### 13.1 问题现象

第一次运行时，FFmpeg 可以从 FIFO 读取 H.264：

```text
Input #0, h264, from detect_h264.fifo
Stream #0:0: Video: h264 (High), yuv420p, 1280x720, 30 fps
```

但推 RTSP 失败：

```text
Connection refused
Could not write header for output file #0
```

MediaMTX log 显示：

```text
./scripts/exp21_5_async_mpp_rtsp.sh:行128: ./tools/mediamtx：是一个目录
```

### 13.2 原因

脚本中判断可执行文件时使用了：

```bash
if [ -x "$p" ]; then
```

但是目录也可能满足 `-x`，所以把：

```text
./tools/mediamtx
```

这个目录误判成可执行文件。

### 13.3 修复

改为：

```bash
if [ -f "$p" ] && [ -x "$p" ]; then
```

并优先查找：

```text
./tools/mediamtx/mediamtx
```

### 13.4 结论

该问题不是 C++ 编码链路问题，而是脚本中 MediaMTX 可执行文件定位问题。

---

## 14. 21-5 最终运行结果

### 14.1 MediaMTX 结果

```text
MediaMTX v1.18.2, linux, arm64
RTSP listener opened on :8554
[path exp21_5_async_mpp_rtsp] stream is available and online, 1 track (H264)
[RTSP] is publishing to path 'exp21_5_async_mpp_rtsp'
[RTSP] is reading from path 'exp21_5_async_mpp_rtsp', with TCP, 1 track (H264)
```

### 14.2 FFmpeg 结果

```text
Input #0, h264, from 'detect_h264.fifo':
    Stream #0:0: Video: h264 (High), yuv420p(progressive), 1280x720, 30 fps

Output #0, rtsp, to 'rtsp://127.0.0.1:8554/exp21_5_async_mpp_rtsp':
    Stream #0:0: Video: h264 (High), yuv420p(progressive), 1280x720, 30 fps

frame=300 fps=61 q=-1.0 Lsize=N/A time=00:00:09.96 speed=2.03x
```

这里 FFmpeg 的 `fps=61 / speed=2.03x` 不是摄像头真实处理 FPS，而是 FFmpeg 读取 FIFO 并推送的速度统计；真实检测链路 FPS 以检测程序的 `wall_fps` 为准。

### 14.3 ffprobe 结果

运行中 ffprobe 成功识别：

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp21_5_async_mpp_rtsp':
    Stream #0:0: Video: h264 (High), yuv420p(progressive), 1280x720, 30 fps
```

结束后 ffprobe 返回：

```text
404 Not Found
no stream is available on path
```

这是因为 300 帧有限测试结束后，检测程序和 FFmpeg 已经退出，MediaMTX path 不再有在线流。该现象不是失败。

### 14.4 检测与编码结果

```text
frames               ：300
wall_fps             ：29.742
avg_select_ms        ：1.673
avg_dqbuf_ms         ：0.004
avg_rga_nv12_to_rgb  ：1.678
avg_input_prepare    ：0.001
avg_model_total_ms   ：27.451
avg_draw_ms          ：0.132
avg_rga_rgb_to_nv12  ：2.430
avg_mpp_queue_push   ：0.168
avg_qbuf_ms          ：0.033
avg_total_ms         ：33.569
```

异步编码线程：

```text
async_encoded_frames ：300
async_encode_failures：0
async_drop_frames    ：0
async_avg_encode_ms  ：2.582
async_avg_write_ms   ：0.193
async_avg_total_ms   ：2.776
```

### 14.5 21-5 结论

```text
自定义异步 MPP 编码模块已经成功替代外部 mpi_enc_test；
C++ 主程序内部完成 H.264 编码；
FFmpeg 只负责读取 H.264 FIFO 并封装 RTSP；
MediaMTX 可以正常发布 RTSP；
300 帧测试中检测端 wall_fps 达到 29.742FPS；
编码线程 0 失败、0 丢帧。
```

---

## 15. 关于 timestamp warning

FFmpeg 中出现：

```text
Timestamps are unset in a packet for stream 0.
```

原因：

```text
C++ 主程序输出的是 H.264 裸码流 FIFO；
裸 H.264 packet 本身没有容器时间戳；
FFmpeg 从 FIFO 读取 H.264 后推 RTSP 时提示 packet timestamp 未显式设置。
```

当前该 warning 不影响推流成功：

```text
ffprobe 能识别 RTSP；
MediaMTX 显示 stream online；
FFmpeg 成功推送 300 帧。
```

后续优化方向：

```text
1. FFmpeg 输入侧增加 -use_wallclock_as_timestamps 1；
2. 后续使用 libavformat 直接在 C++ 中封装 RTSP；
3. 在 C++ 推流层为每个 packet 显式设置 PTS/DTS。
```

---

## 16. 实验21性能汇总表

| 阶段 | 链路 | 帧数 | wall_fps | 编码耗时 | 结果 |
|---|---|---:|---:|---:|---|
| 21-1 | NV12 文件 → MPP → H.264 | 120 | 133.885 | 约 3ms/帧 | 成功 |
| 21-2 | V4L2 → MPP → H.264 | 120 | 29.627 | 3.283ms | 成功 |
| 21-3 | AI 检测 + 串行 MPP | 120 | 27.494 | 2.882ms | 成功，但串行拖慢 |
| 21-3b | clean YOLO + 串行 MPP | 120 | 27.632 | 2.779ms | 小幅提升 |
| 21-4 | AI 检测 + 异步 MPP | 120 | 29.407 | 2.820ms，主线程 push 0.167ms | 成功 |
| 21-5 | 异步 MPP + H.264 FIFO + RTSP | 300 | 29.742 | 2.582ms，主线程 push 0.168ms | 成功 |

---

## 17. 实验21关键结论

### 17.1 MPP 编码能力充足

21-1 离线编码达到：

```text
133.885FPS
```

21-2 实时摄像头编码达到：

```text
29.627FPS
```

说明：

```text
MPP H.264 编码本身不是瓶颈。
```

### 17.2 串行编码会拉低主循环 FPS

21-3 / 21-3b 说明：

```text
当 MPP encode 被串行放入 AI 检测主循环时，
每帧额外增加约 2.8ms，
系统帧率从接近 30FPS 降到约 27.6FPS。
```

### 17.3 异步编码线程可以恢复接近 30FPS

21-4 说明：

```text
将 MPP 编码移入独立线程后，
主线程只需把 NV12 帧 push 到队列，
queue_push 平均只需约 0.167ms，
wall_fps 回升到 29.407FPS。
```

### 17.4 自定义 MPP 编码已替代 mpi_enc_test

21-5 说明：

```text
C++ 主程序内部已经完成 H.264 编码；
H.264 FIFO 可以被 FFmpeg 正确识别；
MediaMTX 可以发布 RTSP；
RTSP 端可识别为 H.264 High / 1280x720 / 30FPS。
```

因此实验21最终完成了：

```text
外部 mpi_enc_test
    ↓
自定义 MPP Encoder
    ↓
检测线程 + 异步编码线程
    ↓
H.264 FIFO + RTSP 推流
```

---

## 18. 实验21中遇到的问题与解决方案

### 18.1 mpp_enc_cfg.h 找不到

报错：

```text
fatal error: mpp_enc_cfg.h: 没有那个文件或目录
```

原因：

```text
系统路径 /usr/include/rockchip 下有 rk_mpi.h 等头文件，
但是 mpp_enc_cfg.h 位于 MPP 源码树：
/home/cat/mpp/mpp/inc/mpp_enc_cfg.h
```

解决：

```cmake
set(EXP21_MPP_INCLUDE_DIRS
    ${EXP21_MPP_ROOT}/inc
    ${EXP21_MPP_ROOT}/mpp/inc
    ${EXP21_MPP_ROOT}/kmpp/base/inc
    ${EXP21_MPP_ROOT}/osal/inc
)
```

---

### 18.2 kmpp_obj.h 找不到

报错：

```text
fatal error: kmpp_obj.h: 没有那个文件或目录
```

原因：

```text
mpp_enc_cfg.h 依赖 kmpp_obj.h；
kmpp_obj.h 位于：
/home/cat/mpp/kmpp/base/inc/kmpp_obj.h
```

解决：

```cmake
${EXP21_MPP_ROOT}/kmpp/base/inc
```

---

### 18.3 CMake block 没有替换成功

现象：

```text
grep EXP21_MPP_INCLUDE_DIRS 没有输出；
CMake 仍然打印 ROCKCHIP_MPP_INCLUDE_DIR。
```

原因：

```text
自动 patch 没有替换到原来的 EXP21 block。
```

解决：

```text
强制重写 EXP21_MPP_FILE_ENCODE block。
```

---

### 18.4 自动 patch main 时变量未插入

报错：

```text
mpp_encoder was not declared
h264_packet was not declared
mpp_encode_write_ms was not declared
```

原因：

```text
自动字符串替换匹配的是：
fopen failed 后直接 return -1；

但真实代码中多了：
close(fd);

导致 MppH264Encoder 初始化代码没有插入成功。
```

同时：

```text
脚本误把日志字段名替换成了变量名 mpp_encode_write_ms。
```

解决：

```text
手动在 fopen 成功后插入 MppH264Encoder 初始化；
恢复 write_ms 变量名；
只在 CSV 表头中使用 mpp_encode_write_ms / queue_push 等字段名。
```

---

### 18.5 RKNN 链接错误

报错：

```text
undefined reference to rknn_init
undefined reference to rknn_run
undefined reference to rknn_outputs_get
```

原因：

```text
新 target exp21_detect_mpp_encode 误用了 ${RKNN_RT_LIB}；
原工程实际使用的是 ${LIBRKNNRT}。
```

解决：

```cmake
target_include_directories(... PRIVATE
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(... 
    ${LIBRKNNRT}
    dl
    pthread
)
```

---

### 18.6 async target 没有添加到 CMake

报错：

```text
make: *** 没有规则可制作目标“exp21_detect_mpp_encode_async”。 停止。
```

原因：

```text
src/main_exp21_detect_mpp_encode_async.cpp 已经生成，
但 CMakeLists.txt 没有 add_executable(exp21_detect_mpp_encode_async)。
```

解决：

```cmake
add_executable(exp21_detect_mpp_encode_async
    src/main_exp21_detect_mpp_encode_async.cpp
    src/mpp_h264_encoder.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    src/yolo11_clean_silent.cc
)
```

---

### 18.7 异步 patch 只成功了一半

检查发现：

```text
grep mpp_encoder.encode(out_nv12_buf...) 仍然存在
```

原因：

```text
异步队列和线程已经加入，
但主循环里的串行 encode 没有替换掉。
```

解决：

```text
将主循环中的 mpp_encoder.encode + fwrite 替换为 queue push。
```

成功判断：

```bash
grep -n "mpp_encoder.encode(out_nv12_buf" src/main_exp21_detect_mpp_encode_async.cpp
```

应输出：

```text
no serial encode in main loop
```

---

### 18.8 MediaMTX 被误判为目录

报错：

```text
./scripts/exp21_5_async_mpp_rtsp.sh:行128: ./tools/mediamtx：是一个目录
Connection refused
```

原因：

```text
脚本用 [ -x "$p" ] 判断 mediamtx；
目录也可能满足 -x；
因此将 ./tools/mediamtx 目录误判为可执行文件。
```

解决：

```bash
if [ -f "$p" ] && [ -x "$p" ]; then
```

并优先查找：

```text
./tools/mediamtx/mediamtx
```

---

## 19. 实验21最终工程链路

最终链路已经变成：

```text
/dev/video11
    ↓
V4L2 mmap 获取 NV12
    ↓
RGA：NV12 → RGB888
    ↓
RKNN：YOLO11 推理
    ↓
YOLO 后处理 + 检测框绘制
    ↓
RGA：RGB888 → NV12
    ↓
主线程将 NV12 push 到编码队列
    ↓
异步编码线程调用 MppH264Encoder
    ↓
输出 H.264 packet
    ↓
H.264 FIFO
    ↓
FFmpeg 读取裸 H.264
    ↓
RTSP 推送到 MediaMTX
    ↓
VLC / ffprobe 客户端实时预览
```

---

## 20. 对简历的意义

实验21使项目从：

```text
调用外部 mpi_enc_test 完成编码
```

升级为：

```text
自主封装 MPP H.264 编码模块，并集成到实时 AI 检测主程序。
```

可以在简历中写：

```text
封装 Rockchip MPP H.264 编码模块，将检测帧在 C++ 主程序内完成硬件编码；针对串行编码导致帧率下降的问题，引入检测线程与异步编码线程解耦，将 720P AI 检测编码链路由约 27.6FPS 优化至 29.7FPS，并通过 H.264 FIFO + FFmpeg + MediaMTX 完成 RTSP 实时预览。
```

更详细版本：

```text
基于 RK3588 实现边缘 AI 实时检测与 RTSP 推流系统，完成 V4L2 mmap 采集、RGA 图像格式转换、RKNN YOLO11 推理、检测框绘制、Rockchip MPP H.264 硬件编码封装及 MediaMTX 分发。通过将 MPP 编码从外部 mpi_enc_test 迁移为 C++ 内部异步编码线程，将串行检测编码链路由 27.6FPS 优化至 29.7FPS，300 帧 RTSP 推流测试中编码线程 0 失败、0 丢帧。
```

---

## 21. 后续优化方向

实验21已经完成核心目标，后续可以继续优化：

```text
1. 跑 3600 帧 / 120 秒长稳测试；
2. 关闭检测框每帧 printf，只保留每 30 帧性能日志；
3. FFmpeg 增加 -use_wallclock_as_timestamps 1 减少 timestamp warning；
4. 用 libavformat 替代 FFmpeg 进程，实现 C++ 内部 RTSP 封装；
5. 为编码线程设计 buffer pool，减少每帧 NV12 vector 拷贝；
6. 引入更完整的线程模型：采集线程 / 推理线程 / 编码线程；
7. 增加资源监控：CPU、内存、温度、队列长度；
8. 在最终报告中加入 FPS、耗时拆解、异常统计图。
```

---

## 22. 实验21最终结论

实验21成功完成了：

```text
1. 自定义 MPP H.264 编码器封装；
2. NV12 文件编码验证；
3. V4L2 实时采集编码验证；
4. AI 检测主程序串行 MPP 编码验证；
5. 异步 MPP 编码线程优化；
6. H.264 FIFO + FFmpeg + MediaMTX RTSP 推流验证。
```

最终关键数据：

```text
21-5 RTSP 推流测试：
frames               ：300
wall_fps             ：29.742
async_encoded_frames ：300
async_encode_failures：0
async_drop_frames    ：0
async_avg_encode_ms  ：2.582ms
async_avg_write_ms   ：0.193ms
async_avg_total_ms   ：2.776ms
RTSP                 ：H.264 High / 1280x720 / 30FPS
```

最终结论：

```text
实验21完成后，RK3588 AI 流媒体项目已经不再依赖外部 mpi_enc_test；
MPP 编码已封装并集成到自己的 C++ 主程序；
通过异步编码线程，系统恢复接近 30FPS；
RTSP 推流链路验证通过。
```

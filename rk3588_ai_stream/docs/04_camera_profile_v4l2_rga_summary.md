# 04 camera_profile / V4L2 / RGA 性能剖析实验总结

## 1. 实验背景

前面已经完成了三个基础实验：

```text
01_image_detect：
单张图片 → RKNN YOLO11 推理 → YOLO11 后处理 → 画框 → 保存结果图片

02_video_detect：
视频文件 → OpenCV 逐帧读取 → RKNN YOLO11 推理 → YOLO11 后处理 → 画框 → 保存结果视频

03_camera_detect：
摄像头 → OpenCV VideoCapture 读取 → RKNN YOLO11 推理 → YOLO11 后处理 → 画框 → 保存检测视频
```

03 实验已经证明摄像头检测链路可以跑通：

```text
/dev/video11 摄像头输入
        ↓
OpenCV VideoCapture 读取图像
        ↓
resize 到 1280x720
        ↓
BGR → RGB
        ↓
inference_yolo11_model()
        ↓
画框
        ↓
VideoWriter 保存视频
```

但是 03 只证明了“能跑通”，没有回答一个关键问题：

```text
当前每一帧到底慢在哪里？
```

因此 04 系列实验的目标是：

```text
对摄像头检测链路进行性能剖析，
找出当前 FPS 低的真正原因，
并为后续 V4L2、RGA、RKNN、MPP、三线程流水线优化做准备。
```

---

## 2. 实验编号说明

原计划路线是：

```text
04_camera_profile        性能剖析
05_camera_pipeline       三线程流水线
06_rga_preprocess        RGA 预处理
```

但是在 04 实验过程中发现：

```text
OpenCV VideoCapture 读取 RKISP 摄像头节点存在明显性能瓶颈。
```

所以实际实验中临时插入了更多子实验：

```text
04      完整链路性能剖析
04-1    去掉 VideoWriter，验证写视频是否是主瓶颈
04-2    单独测试 OpenCV 摄像头采集速度
04-3    设置摄像头输出 1280x720，重新测试完整链路
04-4    使用 V4L2 mmap 原生采集，绕开 OpenCV VideoCapture
04-5    保存 NV12 原始帧，并转 JPG 验证画面正确
06-1    使用 RGA 将 NV12 转 RGB/JPG，验证 RGA 格式转换链路
```

这里不是不做 05，而是：

```text
05 三线程流水线暂时后移。
```

原因是：

```text
如果仍然基于 OpenCV VideoCapture 做三线程，
输入端本身只有约 15FPS，
三线程只能优化串行等待，不能突破采集源本身的性能瓶颈。

所以需要先把采集链路从 OpenCV VideoCapture 替换为 V4L2 mmap，
再用 RGA 替代 OpenCV/GStreamer 隐式颜色转换，
最后再做三线程流水线才更有工程意义。
```

因此后续更合理的路线是：

```text
04_camera_profile                   性能剖析与瓶颈定位
05_v4l2_rga_realtime_preprocess      V4L2 原生采集 + RGA 实时预处理
06_v4l2_rga_rknn_detect              V4L2 + RGA + RKNN 推理
07_camera_pipeline                   采集 / 推理 / 编码三线程流水线
08_mpp_encode_record                 MPP 硬件编码保存
09_rtsp_stream_preview               RTSP / HTTP-FLV / HLS 实时预览
```

---

## 3. 04 实验：camera_profile 完整链路性能剖析

### 3.1 实验目的

基于 03 的 `src/main_camera.cpp`，另存为：

```text
src/main_camera_profile.cpp
```

不修改 03 稳定版本。

04 实验在完整摄像头检测链路中加入计时统计：

```text
capture_ms          摄像头读取耗时
resize_ms           OpenCV resize 耗时
cvtcolor_ms         BGR → RGB 耗时
input_prepare_ms    image_buffer_t 封装耗时
preprocess_ms       预处理总耗时
model_total_ms      inference_yolo11_model() 整体耗时
draw_ms             画框耗时
write_ms            VideoWriter 写视频耗时
total_ms            单帧总耗时
fps                 单帧等效 FPS
detect_count        当前帧检测目标数量
```

这里需要注意：

```text
model_total_ms 不是纯 rknn_run 的耗时，
它统计的是 inference_yolo11_model() 整体耗时，
其中可能包含输入设置、RGA/letterbox、rknn_run、输出获取、后处理和 NMS。
```

### 3.2 实验命令

```bash
cd ~/projects/rk3588_ai_stream

./build/camera_profile \
    models/yolo11.rknn \
    11 \
    output/exp04_camera_profile/camera_profile_60.mp4 \
    60 \
    output/exp04_camera_profile/profile_camera_60.csv
```

### 3.3 实验结果

```text
frames          : 60
capture_ms      : 116.705
resize_ms       : 7.942
cvtcolor_ms     : 0.409
input_prepare_ms: 0.002
preprocess_ms   : 8.353
model_total_ms  : 31.292
draw_ms         : 0.339
write_ms        : 44.460
total_ms        : 201.155
fps             : 4.971
```

### 3.4 实验分析

原始 04 完整链路只有：

```text
约 4.97 FPS
```

主要耗时来自：

```text
capture_ms      116.705 ms
write_ms         44.460 ms
model_total_ms   31.292 ms
```

初步判断：

```text
1. cap.read() 非常慢；
2. VideoWriter 写视频也比较慢；
3. inference_yolo11_model() 不是最大瓶颈；
4. OpenCV resize/cvtColor 不是最大瓶颈。
```

此时最关键的问题是：

```text
低 FPS 的根本原因到底是写视频慢，还是摄像头采集慢？
```

因此继续做 04-1。

---

## 4. 04-1 实验：nowrite，不写视频版本

### 4.1 实验目的

新建：

```text
src/main_camera_profile_nowrite.cpp
```

基于 04 版本，注释掉：

```cpp
writer.write(frame_720p);
```

目的是：

```text
去掉 VideoWriter 写视频耗时，
观察 FPS 是否明显提升。
```

### 4.2 实验结果

```text
frames          : 60
capture_ms      : 153.508
resize_ms       : 8.889
cvtcolor_ms     : 0.444
input_prepare_ms: 0.002
preprocess_ms   : 9.335
model_total_ms  : 36.476
draw_ms         : 0.508
write_ms        : 0.000
total_ms        : 199.835
fps             : 5.004
```

### 4.3 实验分析

不写视频后：

```text
FPS 从 4.971 只提升到 5.004。
```

说明：

```text
VideoWriter 不是最初 5FPS 的根本原因。
真正瓶颈更可能在 cap.read() 摄像头采集链路。
```

这里还出现一个重要现象：

```text
04 保存视频时 capture_ms 约 116ms；
04-1 不写视频时 capture_ms 反而约 153ms。
```

这并不是矛盾，而是因为：

```text
cap.read() 包含阻塞等待下一帧到来的时间。
```

保存视频时，`writer.write()` 已经消耗了一部分时间，下一帧快准备好了，所以 `cap.read()` 等待时间变短。

不写视频时，程序更早到达下一次 `cap.read()`，需要等待摄像头下一帧，因此 `capture_ms` 变大。

因此可以理解为：

```text
cap.read() 不只是数据拷贝，
还包含等待摄像头下一帧的阻塞时间。
```

---

## 5. 摄像头节点分析

使用：

```bash
v4l2-ctl -d /dev/video11 --all
```

得到关键信息：

```text
Driver name      : rkisp_v6
Card type        : rkisp_mainpath
Device Caps      : Video Capture Multiplanar / Streaming / Extended Pix Format

Format Video Capture Multiplanar:
Width/Height     : 3840/2160
Pixel Format     : 'NV12' (Y/CbCr 4:2:0)
Number of planes : 1
Size Image       : 12441600
```

说明：

```text
/dev/video11 不是普通 USB BGR 摄像头节点；
它是 RKISP mainpath；
原生输出格式是 3840x2160 NV12；
类型是 Video Capture Multiplanar。
```

进一步查看支持格式：

```bash
v4l2-ctl -d /dev/video11 --list-formats-ext
```

支持格式包括：

```text
UYVY
NV16
NV61
NV21
NV12
NM21
NM12
```

不支持：

```text
MJPG
BGR3
RGB3
```

这说明 OpenCV 读到的：

```text
3840x2160x3
```

不是摄像头原生 BGR，而是：

```text
RKISP 输出 NV12
        ↓
OpenCV / GStreamer / mplane plugin
        ↓
隐式转换成 BGR 三通道 Mat
```

这解释了为什么 `cap.read()` 很慢。

---

## 6. 04-2 实验：camera_capture_profile，单独测试 OpenCV 采集

### 6.1 实验目的

新建：

```text
src/main_camera_capture_profile.cpp
```

只测试 OpenCV `VideoCapture` 的摄像头采集速度，不跑 RKNN、不 resize、不写视频。

测试内容：

```text
1. 默认打开 /dev/video11；
2. 设置 1280x720 NV12；
3. 设置 1920x1080 NV12；
4. 设置 1280x720 UYVY。
```

### 6.2 默认采集结果

命令：

```bash
./build/camera_capture_profile 11
```

结果：

```text
actual settings after open/set:
  width : 3840
  height: 2160
  fps   : 120.00
  fourcc:

frame shape: 3840x2160x3

avg_read_ms  : 200.854
read_fps     : 4.979
wall_fps     : 4.979
```

说明默认 OpenCV 读取的是：

```text
3840x2160x3 BGR 图像
```

实际只有约：

```text
5 FPS
```

### 6.3 设置 1280x720 NV12

命令：

```bash
./build/camera_capture_profile 11 1280 720 30 NV12 120
```

结果：

```text
actual settings after open/set:
  width : 3840
  height: 2160
  fps   : 120.00
  fourcc:

last shape   : 1280x720x3
avg_read_ms  : 65.599
read_fps     : 15.244
wall_fps     : 15.242
```

虽然 `cap.get()` 仍然显示 3840x2160，但是实际 frame shape 已经变成：

```text
1280x720x3
```

说明：

```text
cap.get() 在 RKISP + GStreamer mplane 插件上不可信；
实际帧尺寸要以 frame.shape 为准。
```

### 6.4 设置 1920x1080 NV12

命令：

```bash
./build/camera_capture_profile 11 1920 1080 30 NV12 120
```

结果：

```text
last shape   : 1920x1080x3
avg_read_ms  : 69.118
read_fps     : 14.468
wall_fps     : 14.467
```

### 6.5 设置 1280x720 UYVY

命令：

```bash
./build/camera_capture_profile 11 1280 720 30 UYVY 120
```

结果：

```text
last shape   : 1280x720x3
avg_read_ms  : 65.828
read_fps     : 15.191
wall_fps     : 15.189
```

### 6.6 04-2 结论

```text
OpenCV 默认读取 4K，只有约 5FPS；
设置 1280x720 后，OpenCV 能读到 720P BGR，提升到约 15FPS；
但仍然达不到 30FPS。
```

因此：

```text
OpenCV/GStreamer VideoCapture 层仍然存在性能瓶颈。
```

---

## 7. 04-3 实验：setcap，设置摄像头直接输出 1280x720

### 7.1 实验目的

新建：

```text
src/main_camera_profile_setcap.cpp
```

基于 04 版本，增加：

```cpp
cap.set(cv::CAP_PROP_FOURCC, cv::VideoWriter::fourcc('N', 'V', '1', '2'));
cap.set(cv::CAP_PROP_FRAME_WIDTH, 1280);
cap.set(cv::CAP_PROP_FRAME_HEIGHT, 720);
cap.set(cv::CAP_PROP_FPS, 25.0);
```

并去掉原来的：

```cpp
cv::resize(raw_frame, frame_720p, cv::Size(1280, 720));
```

新的链路变成：

```text
OpenCV 直接读取 1280x720
        ↓
BGR → RGB
        ↓
RKNN 推理
        ↓
画框
        ↓
写视频
```

### 7.2 实验结果

```text
frames          : 60
capture_ms      : 6.270
resize_ms       : 0.000
cvtcolor_ms     : 0.682
input_prepare_ms: 0.002
preprocess_ms   : 0.684
model_total_ms  : 35.069
draw_ms         : 0.008
write_ms        : 26.611
total_ms        : 68.646
fps             : 14.567
```

### 7.3 实验分析

相比原始 04：

```text
FPS 从 4.97 提升到 14.57。
```

关键优化点：

```text
1. 不再读取 4K 图像；
2. 不再做 4K → 720P 的 OpenCV resize；
3. 摄像头输入尺寸直接变成 1280x720。
```

原始链路：

```text
/dev/video11 3840x2160 NV12
        ↓
OpenCV 转 3840x2160 BGR
        ↓
OpenCV resize 到 1280x720
        ↓
BGR → RGB
        ↓
RKNN
```

优化后：

```text
/dev/video11 设置输出 1280x720
        ↓
OpenCV 转 1280x720 BGR
        ↓
BGR → RGB
        ↓
RKNN
```

新的主要瓶颈变成：

```text
model_total_ms : 35.069 ms
write_ms       : 26.611 ms
```

---

## 8. 04-3-nowrite 实验：setcap + 不写视频

### 8.1 实验目的

新建：

```text
src/main_camera_profile_setcap_nowrite.cpp
```

在 04-3 基础上注释掉：

```cpp
writer.write(frame_720p);
```

目的是验证：

```text
不写视频时，设置 1280x720 后的检测主链路能达到多少 FPS。
```

### 8.2 实验结果

```text
frames          : 60
capture_ms      : 21.399
resize_ms       : 0.000
cvtcolor_ms     : 1.002
input_prepare_ms: 0.003
preprocess_ms   : 1.005
model_total_ms  : 43.201
draw_ms         : 0.000
write_ms        : 0.000
total_ms        : 65.613
fps             : 15.241
```

### 8.3 实验分析

不写视频后 FPS 是：

```text
15.241 FPS
```

和 04-2 中 OpenCV 1280x720 纯采集的：

```text
15.242 FPS
```

基本一致。

说明：

```text
当前 OpenCV 采集链路本身约 15FPS；
即使不写视频，也很难超过这个上限。
```

---

## 9. v4l2-ctl 原生采集测试

使用：

```bash
v4l2-ctl -d /dev/video11 \
  --stream-mmap=4 \
  --stream-count=120 \
  --stream-to=/dev/null
```

结果：

```text
29.99 fps
29.99 fps
29.99 fps
```

这说明：

```text
摄像头、ISP、V4L2 驱动本身可以达到 30FPS。
```

因此此前 OpenCV 只有 15FPS，不是摄像头硬件问题，也不是 RKISP 问题，而是：

```text
OpenCV / GStreamer / VideoCapture 层存在性能瓶颈。
```

---

## 10. 04-4 实验：V4L2 原生 mmap 采集

### 10.1 实验目的

新建：

```text
src/main_v4l2_capture_profile.cpp
```

绕开 OpenCV，直接使用 V4L2 原生接口采集：

```text
open("/dev/video11")
        ↓
VIDIOC_QUERYCAP
        ↓
VIDIOC_S_FMT 设置 1280x720 NV12
        ↓
VIDIOC_REQBUFS
        ↓
VIDIOC_QUERYBUF
        ↓
mmap
        ↓
VIDIOC_QBUF
        ↓
VIDIOC_STREAMON
        ↓
select
        ↓
VIDIOC_DQBUF
        ↓
VIDIOC_QBUF
```

### 10.2 实验结果

```text
WARN: VIDIOC_S_PARM failed: Inappropriate ioctl for device

request buffers count: 4
mmap buffer=0 plane=0 length=1382400 offset=0
mmap buffer=1 plane=0 length=1382400 offset=1384448
mmap buffer=2 plane=0 length=1382400 offset=2768896
mmap buffer=3 plane=0 length=1382400 offset=4153344

frame=0 index=0 dqbuf_ms=0.014 plane[0].bytesused=1382400
...
frame=119 index=3 dqbuf_ms=0.016 plane[0].bytesused=1382400

========== 04-4 v4l2 capture profile ==========
captured      : 120
avg_dqbuf_ms  : 0.021
min_dqbuf_ms  : 0.008
max_dqbuf_ms  : 0.082
dqbuf_fps     : 47003.673
wall_time_ms  : 4048.397
wall_fps      : 29.641
================================================
```

### 10.3 实验分析

`wall_fps = 29.641`，说明 C++ 原生 V4L2 mmap 采集也能接近 30FPS。

`bytesused = 1382400`，正好等于：

```text
1280 * 720 * 3 / 2 = 1382400
```

说明采集到的是正确的 NV12 数据。

`avg_dqbuf_ms` 很小，是因为真正等待帧到来的时间发生在 `select()`，而 `VIDIOC_DQBUF` 只是把已经就绪的 buffer 取出来。

判断真实采集 FPS 应该看：

```text
wall_fps
```

而不是看：

```text
dqbuf_fps
```

### 10.4 04-4 结论

```text
V4L2 原生 mmap 采集可以达到约 30FPS；
OpenCV VideoCapture 只有约 15FPS；
瓶颈在 OpenCV/GStreamer，而不是摄像头或 V4L2 驱动。
```

---

## 11. 04-5 实验：保存 NV12 原始帧并转 JPG

### 11.1 实验目的

04-4 只证明了“能高速采集”，还需要验证：

```text
采集到的 NV12 画面是否正确。
```

因此使用 `v4l2-ctl` 保存一帧 NV12：

```bash
mkdir -p output/exp04_v4l2_nv12_save

v4l2-ctl -d /dev/video11 \
  --set-fmt-video-mplane=width=1280,height=720,pixelformat=NV12

v4l2-ctl -d /dev/video11 \
  --stream-mmap=4 \
  --stream-count=1 \
  --stream-to=output/exp04_v4l2_nv12_save/frame_1280x720.nv12
```

再用 FFmpeg 转 JPG：

```bash
ffmpeg -y \
  -f rawvideo \
  -pix_fmt nv12 \
  -s 1280x720 \
  -i output/exp04_v4l2_nv12_save/frame_1280x720.nv12 \
  output/exp04_v4l2_nv12_save/frame_1280x720.jpg
```

### 11.2 实验结果

```text
-rw-r--r-- 1 cat cat  70K frame_1280x720.jpg
-rw-r--r-- 1 cat cat 1.4M frame_1280x720.nv12

frame_1280x720.jpg:
JPEG image data, baseline, precision 8, 1280x720, components 3
```

### 11.3 实验分析

NV12 文件大小为 1.4M：

```text
1280 * 720 * 3 / 2 = 1382400 bytes
```

JPG 文件为：

```text
1280x720, 3 components
```

说明：

```text
V4L2 采集到的 NV12 原始帧画面正确。
```

---

## 12. 06-1 实验：RGA NV12 转 RGB/JPG

### 12.1 为什么这里出现了 06？

原计划中：

```text
05：三线程流水线
06：RGA 预处理
```

但是由于 04 证明了：

```text
OpenCV VideoCapture 是瓶颈；
V4L2 原生采集能到 30FPS；
而 RKNN 推理需要 RGB 输入；
所以必须先验证 V4L2 NV12 如何变成 RGB。
```

因此临时先做了：

```text
06-1 RGA NV12 → RGB 离线验证
```

它是后续替换 OpenCV 采集链路的必要前置实验。

### 12.2 实验目的

输入：

```text
output/exp04_v4l2_nv12_save/frame_1280x720.nv12
```

使用 RGA 转换为：

```text
RGB888 raw
JPG 图片
```

验证：

```text
RGA 可以把 V4L2 采集到的 NV12 数据转换成 RKNN 所需的 RGB888。
```

### 12.3 实验命令

```bash
mkdir -p output/exp06_rga_nv12_to_rgb

./build/rga_nv12_to_rgb \
  output/exp04_v4l2_nv12_save/frame_1280x720.nv12 \
  1280 \
  720 \
  output/exp06_rga_nv12_to_rgb/frame_1280x720.rgb \
  output/exp06_rga_nv12_to_rgb/frame_1280x720.jpg
```

### 12.4 实验结果

```text
input nv12 : output/exp04_v4l2_nv12_save/frame_1280x720.nv12
width      : 1280
height     : 720
nv12 size  : 1382400
rgb size   : 2764800
output rgb : output/exp06_rga_nv12_to_rgb/frame_1280x720.rgb
output jpg : output/exp06_rga_nv12_to_rgb/frame_1280x720.jpg

rga_api version 1.10.1_[0]
RGA convert NV12 -> RGB success, time = 8.439 ms
write_image path: output/exp06_rga_nv12_to_rgb/frame_1280x720.jpg width=1280 height=720 channel=3
write rgb raw success: output/exp06_rga_nv12_to_rgb/frame_1280x720.rgb
write jpg success    : output/exp06_rga_nv12_to_rgb/frame_1280x720.jpg
```

### 12.5 实验分析

RGA 转换成功，输出：

```text
frame_1280x720.rgb
frame_1280x720.jpg
```

RGB 文件大小应为：

```text
1280 * 720 * 3 = 2764800 bytes
```

RGA 转换耗时：

```text
8.439 ms
```

这里需要注意：

```text
06-1 是离线文件验证；
使用的是 malloc 普通内存；
还不是最终的 DMA Buffer / zero-copy 最优路径。
```

因此 8.439ms 主要说明：

```text
RGA 转换功能已经跑通。
```

后续还要在实时链路中统计 RGA 耗时。

---

## 13. RGA 替代了什么？

之前 OpenCV 链路中，真实过程是：

```text
/dev/video11 原生 NV12
        ↓
OpenCV / GStreamer mplane plugin
        ↓
隐式 NV12 → BGR
        ↓
cv::Mat BGR
        ↓
cv::cvtColor(BGR → RGB)
        ↓
RKNN 推理
```

而目标工程链路是：

```text
/dev/video11 原生 NV12
        ↓
V4L2 mmap 直接拿 NV12 buffer
        ↓
RGA NV12 → RGB888
        ↓
image_buffer_t
        ↓
inference_yolo11_model()
```

所以 RGA 要替代的是：

```text
OpenCV/GStreamer 隐式 NV12 → BGR
+
OpenCV cvtColor BGR → RGB
```

06-1 已经证明：

```text
NV12 → RGA → RGB888 这条路可行。
```

但 06-1 只是离线验证，还没有完全替换实时 camera_detect 链路。

---

## 14. 当前各实验结果对比表

| 实验 | 输入链路 | 是否写视频 | 关键结果 |
|---|---|---|---|
| 04 | OpenCV 默认读取 4K，再 resize | 是 | 约 4.97 FPS |
| 04-1 | OpenCV 默认读取 4K，再 resize | 否 | 约 5.00 FPS |
| 04-2 默认 | OpenCV 默认读取 4K | 否 | 约 4.98 FPS |
| 04-2 1280x720 | OpenCV 设置 720P | 否 | 约 15.24 FPS |
| 04-3 | OpenCV 设置 720P + RKNN | 是 | 约 14.57 FPS |
| 04-3-nowrite | OpenCV 设置 720P + RKNN | 否 | 约 15.24 FPS |
| v4l2-ctl | V4L2 mmap 原生采集 | 否 | 约 29.99 FPS |
| 04-4 | C++ V4L2 mmap 原生采集 | 否 | 约 29.64 FPS |
| 04-5 | 保存 NV12 并转 JPG | 否 | 画面正确 |
| 06-1 | RGA NV12 → RGB/JPG | 否 | 转换成功，约 8.439ms |

---

## 15. 最终结论

04 系列实验最终定位出：

```text
原始 camera_detect 只有约 5FPS 的主要原因不是 RKNN 推理，
也不是 VideoWriter 写视频，
而是 OpenCV 默认从 /dev/video11 读取 3840x2160 图像并隐式转换成 BGR，
导致采集链路严重拖慢。
```

进一步验证发现：

```text
1. /dev/video11 是 RKISP mainpath，原生格式是 NV12，多平面采集；
2. OpenCV 默认读取 4K BGR，只有约 5FPS；
3. OpenCV 设置 1280x720 后，读取速度提升到约 15FPS；
4. 但 V4L2 原生 mmap 采集可以达到约 30FPS；
5. 因此真正瓶颈在 OpenCV/GStreamer VideoCapture 层；
6. V4L2 原生采集到的 NV12 原始帧是正确的；
7. RGA 可以将 NV12 转换为 RGB888；
8. 后续应该用 V4L2 + RGA 替代 OpenCV VideoCapture + cvtColor。
```

---

## 16. 为什么没有先做 05 三线程流水线？

原计划 05 是：

```text
采集线程 / 推理线程 / 保存线程
```

但是在 04 实验中发现：

```text
OpenCV VideoCapture 本身是主要瓶颈。
```

如果直接基于 OpenCV `cap.read()` 做三线程，那么输入端最多只有：

```text
约 15FPS
```

三线程只能优化串行等待，不能突破输入源本身的性能上限。

而 V4L2 原生采集已经证明可以达到：

```text
约 30FPS
```

所以更合理的路线是：

```text
先把采集链路从 OpenCV VideoCapture 替换为 V4L2 mmap；
再用 RGA 替换 OpenCV/GStreamer 的隐式颜色转换；
最后再做三线程流水线。
```

因此：

```text
05 不是取消，而是后移。
```

建议重新定义后续实验路线：

```text
05_v4l2_rga_realtime_preprocess：
    V4L2 实时采集 NV12 + RGA 实时转 RGB，统计 capture_ms / rga_ms / total_fps。

06_v4l2_rga_rknn_detect：
    V4L2 原生采集 + RGA 转 RGB + RKNN YOLO11 推理。

07_camera_pipeline：
    在 V4L2 + RGA + RKNN 基础上做采集 / 推理 / 编码三线程流水线。

08_mpp_encode_record：
    使用 MPP 硬件编码替代 OpenCV VideoWriter。

09_rtsp_stream_preview：
    推流实时预览。
```

如果仍然沿用旧编号：

```text
05_camera_pipeline
06_rga_preprocess
```

也可以，但工程上更推荐先做 V4L2 + RGA，再做 Pipeline。

---

## 17. 当前项目能力更新

完成 04 系列和 06-1 后，当前项目已经具备：

```text
1. RK3588 上 YOLO11 RKNN 单图推理；
2. 视频文件逐帧检测；
3. OpenCV 摄像头检测；
4. 摄像头检测性能剖析；
5. V4L2 设备格式分析；
6. OpenCV VideoCapture 瓶颈定位；
7. V4L2 mmap 原生采集；
8. NV12 原始帧保存与验证；
9. RGA NV12 → RGB888 离线转换验证。
```

这说明项目已经从简单 OpenCV Demo 逐步进入真正的 RK3588 工程优化阶段：

```text
OpenCV Demo 级别
        ↓
V4L2 原生采集
        ↓
RGA 硬件预处理
        ↓
RKNN 推理
        ↓
MPP 编码 / RTSP 推流
```

---

## 18. 下一步建议

下一步建议做：

```text
05_v4l2_rga_realtime_preprocess
```

目标：

```text
V4L2 mmap 实时采集 1280x720 NV12
        ↓
RGA 实时转换为 RGB888
        ↓
统计每帧：
    select / dqbuf 等待时间
    RGA 转换时间
    qbuf 时间
    total FPS
```

暂时不接 RKNN。

完成后再做：

```text
06_v4l2_rga_rknn_detect
```

目标：

```text
V4L2 mmap 采集 NV12
        ↓
RGA 转 RGB888
        ↓
构造 image_buffer_t
        ↓
inference_yolo11_model()
        ↓
统计完整推理 FPS
```

这样后续再做三线程流水线会更有意义。

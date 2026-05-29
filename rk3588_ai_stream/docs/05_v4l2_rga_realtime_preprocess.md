# 05 V4L2 + RGA 实时预处理实验记录

## 1. 实验背景

前面已经完成了 04 camera_profile / V4L2 / RGA 性能剖析实验。04 实验的核心结论是：OpenCV `VideoCapture` 读取 `/dev/video11` 时存在明显性能瓶颈。默认 4K 读取时约 5FPS；设置 1280x720 后约 15FPS；但使用 `v4l2-ctl` 原生 mmap 采集时可以接近 30FPS。

因此，后续如果继续基于 OpenCV `VideoCapture` 做三线程流水线，意义不大。因为 OpenCV 采集层本身已经限制在约 15FPS，即使后续做采集 / 推理 / 编码三线程，也突破不了输入端上限。

所以原计划中的 `05_camera_pipeline` 暂时后移，当前 05 实验改为：

```text
05_v4l2_rga_realtime_preprocess
```

也就是先完成：

```text
V4L2 mmap 原生采集 NV12
        ↓
RGA NV12 → RGB888
        ↓
统计实时预处理性能
```

这个实验的目的不是做检测，而是先验证能否绕开 OpenCV / GStreamer `VideoCapture`，直接从 RKISP 的 `/dev/video11` 节点采集 NV12，再使用 RGA 实时转换成 RKNN 后续需要的 RGB888。

---

## 2. 实验目标

本实验目标：

1. 使用 V4L2 mmap 方式直接打开 `/dev/video11`；
2. 设置采集格式为 `1280x720 NV12`；
3. 使用 `VIDIOC_QUERYCAP` 查询设备能力；
4. 使用 `VIDIOC_S_FMT` 设置采集分辨率和像素格式；
5. 使用 `VIDIOC_REQBUFS` 申请 V4L2 buffer；
6. 使用 `VIDIOC_QUERYBUF` 查询 buffer 信息；
7. 使用 `mmap` 将内核 buffer 映射到用户态；
8. 使用 `VIDIOC_QBUF` 将 buffer 加入采集队列；
9. 使用 `VIDIOC_STREAMON` 启动视频流；
10. 使用 `select` 等待帧到来；
11. 使用 `VIDIOC_DQBUF` 取出一帧 NV12 数据；
12. 使用 RGA 将 NV12 转换为 RGB888；
13. 使用 `VIDIOC_QBUF` 将 buffer 重新放回采集队列；
14. 统计每帧 `select_ms`、`dqbuf_ms`、`rga_ms`、`qbuf_ms`、`total_ms`、`fps`；
15. 保存最后一帧 RGB raw 文件；
16. 使用 FFmpeg 将 RGB raw 转为 JPG，验证画面正确；
17. 为 06 实验接入 RKNN 推理提供可靠输入链路。

---

## 3. 当前工程路径与文件

当前工程路径：

```bash
~/projects/rk3588_ai_stream
```

本实验新增文件：

```text
include/v4l2_mplane_capture.hpp
src/main_v4l2_rga_realtime_preprocess.cpp
docs/05_v4l2_rga_realtime_preprocess.md
```

本实验输出目录：

```text
output/exp05_v4l2_rga_realtime/
```

输出文件：

```text
output/exp05_v4l2_rga_realtime/profile_v4l2_rga.csv
output/exp05_v4l2_rga_realtime/last.rgb
output/exp05_v4l2_rga_realtime/last.jpg
```

---

## 4. 为什么使用 V4L2 mmap？

04 实验已经证明：

```text
/dev/video11 是 RKISP mainpath 节点；
原生输出格式是 NV12；
属于 Video Capture Multiplanar 设备；
OpenCV 读取时会发生隐式 NV12 → BGR 转换；
OpenCV / GStreamer 层会造成额外开销。
```

因此本实验使用 V4L2 原生接口：

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
处理 NV12 数据
        ↓
VIDIOC_QBUF
```

这样可以绕开 OpenCV 的隐式格式转换与额外封装。

---

## 5. 为什么还需要 RGA？

V4L2 从 `/dev/video11` 采集到的是 NV12，而当前鲁班猫 YOLO11 RKNN 推理接口使用的 `image_buffer_t` 输入格式通常是 `IMAGE_FORMAT_RGB888`。因此后续要送入 RKNN 的不是 NV12，而是 RGB888。

如果继续用 OpenCV 做：

```cpp
cv::cvtColor(...)
```

就又回到了 CPU 颜色转换路径。

所以本实验使用 RGA 做：

```text
NV12 → RGB888
```

对应数据大小：

```text
NV12:
    1280 * 720 * 3 / 2 = 1382400 bytes

RGB888:
    1280 * 720 * 3 = 2764800 bytes
```

---

## 6. RGA 环境检查

在编译前检查 RGA 头文件和动态库：

```bash
find /usr /usr/local ~/lubancat_ai_manual_code -name "im2d.hpp" 2>/dev/null
find /usr /usr/local ~/lubancat_ai_manual_code -name "RgaUtils.h" 2>/dev/null
find /usr /usr/local -name "librga.so*" 2>/dev/null
```

实际结果：

```text
/usr/include/rga/im2d.hpp
/usr/include/rga/RgaUtils.h
/usr/lib/aarch64-linux-gnu/librga.so
/usr/lib/aarch64-linux-gnu/librga.so.2
/usr/lib/aarch64-linux-gnu/librga.so.2.1.0
```

说明 RGA 头文件和动态库均存在，可以在 CMake 中直接使用：

```text
/usr/include/rga
/usr/lib/aarch64-linux-gnu/librga.so
```

---

## 7. CMake 配置问题与修复

实验过程中遇到过一次 CMake 报错：

```text
add_executable cannot create target "v4l2_rga_realtime_preprocess"
because another target with the same name already exists
```

原因是 05 / 06 的 CMake target 被重复追加了两次。表现为 CMake 配置时 RGA 信息打印了两遍：

```text
RGA_INCLUDE_DIR = /usr/include/rga
RGA_LIBRARY     = /usr/lib/aarch64-linux-gnu/librga.so
RGA_INCLUDE_DIR = /usr/include/rga
RGA_LIBRARY     = /usr/lib/aarch64-linux-gnu/librga.so
```

解决方式是删除重复追加的 05 / 06 CMake 代码块，只保留一份。最终 CMake 配置成功：

```text
-- RGA_INCLUDE_DIR = /usr/include/rga
-- RGA_LIBRARY     = /usr/lib/aarch64-linux-gnu/librga.so
-- Configuring done
-- Generating done
```

另外，编译过程中还出现过：

```text
structured bindings only available with -std=c++17
```

原因是 Rockchip 的 `rknpu2/yolo11.cc` 中使用了 C++17 的结构化绑定语法：

```cpp
for (auto const& [spatial_len, br] : branches)
```

因此将顶层 `CMakeLists.txt` 中：

```cmake
set(CMAKE_CXX_STANDARD 11)
```

改为：

```cmake
set(CMAKE_CXX_STANDARD 17)
```

---

## 8. 05 程序核心文件说明

### 8.1 `include/v4l2_mplane_capture.hpp`

该文件封装了 V4L2 multiplanar mmap 采集逻辑。

核心能力：

```text
open_device()
    打开 /dev/video11；
    查询设备能力；
    设置 1280x720 NV12；
    申请 buffer；
    mmap 映射；
    QBUF 入队；
    STREAMON 启动。

dequeue_frame()
    select 等待帧；
    DQBUF 取出一帧；
    返回用户态可访问的 NV12 数据指针。

requeue_frame()
    QBUF 重新入队。

close_device()
    STREAMOFF；
    munmap；
    close fd。
```

这样做的好处是后续 06、07、流水线实验都可以复用同一套 V4L2 采集封装。

### 8.2 `src/main_v4l2_rga_realtime_preprocess.cpp`

该文件完成：

```text
V4L2 采集一帧 NV12
        ↓
RGA NV12 → RGB888
        ↓
统计耗时
        ↓
重新 QBUF
        ↓
循环下一帧
```

核心 RGA 转换逻辑是：

```cpp
rga_buffer_t src = wrapbuffer_virtualaddr((void *)nv12,
                                          width,
                                          height,
                                          RK_FORMAT_YCbCr_420_SP);

rga_buffer_t dst = wrapbuffer_virtualaddr((void *)rgb,
                                          width,
                                          height,
                                          RK_FORMAT_RGB_888);

IM_STATUS status = imcvtcolor(src,
                              dst,
                              RK_FORMAT_YCbCr_420_SP,
                              RK_FORMAT_RGB_888);
```

这里使用的是普通 virtual address 路径，不是 DMA Buffer / zero-copy 最优路径。因此本实验验证的是功能正确性和实时性能基线，还不是最终极致优化版本。

---

## 9. 编译 05 程序

进入 build 目录：

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir build
cd build

cmake ..
```

编译 05：

```bash
make v4l2_rga_realtime_preprocess -j4
```

确认可执行文件：

```bash
ls -lh v4l2_rga_realtime_preprocess
```

---

## 10. 运行 05 实验

运行命令：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp05_v4l2_rga_realtime

./build/v4l2_rga_realtime_preprocess   /dev/video11   1280   720   120   output/exp05_v4l2_rga_realtime/profile_v4l2_rga.csv   output/exp05_v4l2_rga_realtime/last.rgb
```

参数含义：

| 参数 | 含义 |
|---|---|
| `/dev/video11` | RKISP mainpath 摄像头节点 |
| `1280` | 采集宽度 |
| `720` | 采集高度 |
| `120` | 测试帧数 |
| `profile_v4l2_rga.csv` | 性能统计 CSV |
| `last.rgb` | 保存最后一帧 RGB888 raw 文件 |

---

## 11. 运行日志

程序启动后输出：

```text
WARN: VIDIOC_S_PARM failed: Inappropriate ioctl for device
request buffers count: 4
mmap buffer=0 length=1382400 offset=0
mmap buffer=1 length=1382400 offset=1384448
mmap buffer=2 length=1382400 offset=2768896
mmap buffer=3 length=1382400 offset=4153344
rga_api version 1.9.2_[1]
```

其中：

```text
length=1382400
```

正好等于：

```text
1280 * 720 * 3 / 2 = 1382400 bytes
```

说明 V4L2 采集到的是正确的 1280x720 NV12 数据。

`VIDIOC_S_PARM failed` 这个 warning 当前可以忽略。含义是 `/dev/video11` 这个 RKISP multiplanar 采集节点不支持通过 `VIDIOC_S_PARM` 设置帧率，但它不影响 `VIDIOC_S_FMT`、`REQBUFS`、`mmap`、`STREAMON`、`DQBUF/QBUF` 这些主采集流程。

---

## 12. 05 实验性能结果

### 30 帧平均结果

```text
========== 05 avg ==========
frames    : 30
select_ms : 29.560
dqbuf_ms  : 0.020
rga_ms    : 5.143
qbuf_ms   : 0.150
total_ms  : 34.879
avg_fps   : 28.671
============================
```

### 60 帧平均结果

```text
========== 05 avg ==========
frames    : 60
select_ms : 29.003
dqbuf_ms  : 0.020
rga_ms    : 4.878
qbuf_ms   : 0.151
total_ms  : 34.063
avg_fps   : 29.357
============================
```

### 90 帧平均结果

```text
========== 05 avg ==========
frames    : 90
select_ms : 28.600
dqbuf_ms  : 0.020
rga_ms    : 5.038
qbuf_ms   : 0.154
total_ms  : 33.821
avg_fps   : 29.568
============================
```

### 120 帧最终结果

```text
========== 05 avg ==========
frames    : 120
select_ms : 28.360
dqbuf_ms  : 0.020
rga_ms    : 5.124
qbuf_ms   : 0.157
total_ms  : 33.670
avg_fps   : 29.700
============================

========== 05 final ==========
frames       : 120
wall_time_ms : 4052.589
wall_fps     : 29.611
avg_select_ms: 28.360
avg_dqbuf_ms : 0.020
avg_rga_ms   : 5.124
avg_qbuf_ms  : 0.157
avg_total_ms : 33.670
write last rgb success: output/exp05_v4l2_rga_realtime/last.rgb
csv saved: output/exp05_v4l2_rga_realtime/profile_v4l2_rga.csv
================================
```

---

## 13. 将 RGB raw 转 JPG 验证画面

运行 FFmpeg：

```bash
ffmpeg -y   -f rawvideo   -pix_fmt rgb24   -s 1280x720   -i output/exp05_v4l2_rga_realtime/last.rgb   output/exp05_v4l2_rga_realtime/last.jpg
```

检查输出：

```bash
ls -lh output/exp05_v4l2_rga_realtime
file output/exp05_v4l2_rga_realtime/last.jpg
```

实际结果：

```text
总用量 2.7M
-rw-r--r-- 1 cat cat  53K  last.jpg
-rw-r--r-- 1 cat cat 2.7M  last.rgb
-rw-r--r-- 1 cat cat 6.0K  profile_v4l2_rga.csv

output/exp05_v4l2_rga_realtime/last.jpg:
JPEG image data, baseline, precision 8, 1280x720, components 3
```

其中：

```text
last.rgb = 2.7M
```

正好接近：

```text
1280 * 720 * 3 = 2764800 bytes
```

说明 RGA 输出的 RGB888 数据大小正确。

---

## 14. 关键指标解释

### 14.1 `select_ms ≈ 28.360ms`

这个不是坏事。

30FPS 摄像头理论上一帧间隔是：

```text
1000 / 30 = 33.33ms
```

本实验中：

```text
select_ms ≈ 28.360ms
rga_ms    ≈ 5.124ms
total_ms  ≈ 33.670ms
```

也就是：

```text
等待摄像头下一帧 + RGA 转换 + QBUF 等操作 ≈ 一帧周期
```

这说明程序处理速度足够快，大部分时间是在等摄像头出下一帧。

### 14.2 `dqbuf_ms ≈ 0.020ms`

`DQBUF` 只是把已经准备好的 buffer 从驱动队列中取出来。它非常快，说明 V4L2 mmap buffer 取帧不是瓶颈。

### 14.3 `rga_ms ≈ 5.124ms`

当前 RGA 完成：

```text
1280x720 NV12 → RGB888
```

平均耗时约 5.124ms。

对于 30FPS 来说，一帧预算约 33.33ms，RGA 占比约：

```text
5.124 / 33.33 ≈ 15.4%
```

说明 RGA 颜色转换耗时可以接受。

### 14.4 `wall_fps = 29.611`

这是最关键的结论。说明：

```text
V4L2 mmap + RGA 实时预处理链路可以接近 30FPS。
```

对比 04 实验中的 OpenCV 采集：

```text
OpenCV 720P 采集：
    约 15 FPS

V4L2 mmap + RGA：
    约 29.6 FPS
```

说明 05 实验成功绕开了 OpenCV / GStreamer `VideoCapture` 的性能瓶颈。

---

## 15. 05 实验结论

本实验完成后，可以得到以下结论：

```text
1. V4L2 mmap 可以稳定从 /dev/video11 采集 1280x720 NV12 图像；
2. 单帧 NV12 数据大小为 1280×720×3/2 = 1382400 bytes；
3. RGA 可以将 NV12 实时转换为 RGB888；
4. 单帧 RGB888 数据大小为 1280×720×3 = 2764800 bytes；
5. RGA 平均转换耗时约 5.124ms；
6. 整体 wall_fps 达到 29.611FPS，接近 30FPS；
7. 相比 OpenCV VideoCapture 的约 15FPS，V4L2 + RGA 链路成功绕开了 OpenCV/GStreamer 的性能瓶颈；
8. 保存最后一帧 RGB raw 并通过 FFmpeg 转 JPG 后，图像格式验证正确；
9. 该实验为 06_v4l2_rga_rknn_detect 接入 RKNN 推理提供了可靠输入链路。
```

---

## 16. 和 04、06 实验的关系

04 实验的作用是定位瓶颈：

```text
OpenCV / GStreamer VideoCapture 是瓶颈；
摄像头、RKISP、V4L2 驱动本身不是瓶颈。
```

05 实验的作用是替换瓶颈链路：

```text
用 V4L2 mmap 替代 OpenCV VideoCapture；
用 RGA 替代 OpenCV 隐式颜色转换；
将输入链路恢复到接近 30FPS。
```

06 实验将在 05 的基础上继续接入：

```text
image_buffer_t
inference_yolo11_model()
YOLO11 后处理
检测结果画框
快照保存
完整链路性能统计
```

因此 05 是 06 的前置实验。

---

## 17. 后续优化方向

05 实验已经说明输入链路可以接近 30FPS。后续优化重点不再是 OpenCV 采集，而是：

```text
1. 接入 RKNN 后完整链路能达到多少 FPS；
2. inference_yolo11_model() 内部到底哪一段最慢；
3. 是否还存在内部 resize / letterbox；
4. 是否需要进一步使用 DMA Buffer / zero-copy；
5. 是否需要做采集 / 推理 / 编码三线程流水线；
6. 是否需要将 RGA 直接输出模型输入尺寸；
7. 是否需要优化 YOLO 后处理 / NMS；
8. 是否需要接入 MPP 硬件编码保存视频；
9. 是否需要后续接 RTSP / HTTP-FLV / HLS 推流。
```

当前 05 实验完成后，下一步进入：

```text
06_v4l2_rga_rknn_detect
```

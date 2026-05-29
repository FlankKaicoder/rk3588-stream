# 06 V4L2 + RGA + RKNN 实时检测实验记录

## 1. 实验背景

前面已经完成了 05 V4L2 + RGA 实时预处理实验。05 实验证明：

```text
V4L2 mmap 可以稳定从 /dev/video11 采集 1280x720 NV12；
RGA 可以将 NV12 实时转换为 RGB888；
完整预处理链路 wall_fps 达到 29.611FPS；
输入链路已经接近 30FPS，不再是主要瓶颈。
```

因此，06 实验继续在 05 的基础上接入 RKNN YOLO11 推理。

06 的目标是验证：

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
        ↓
定期保存 JPG 快照
        ↓
统计完整链路性能
```

也就是说，05 只验证输入预处理链路，06 验证完整检测链路。

---

## 2. 实验目标

本实验目标：

1. 复用 05 中的 V4L2 mmap 采集封装；
2. 从 `/dev/video11` 采集 1280x720 NV12 图像；
3. 使用 RGA 将 NV12 转换为 RGB888；
4. 构造 RKNN 推理所需的 `image_buffer_t`；
5. 调用 `inference_yolo11_model()` 执行 YOLO11 RKNN 推理；
6. 获取 `object_detect_result_list` 检测结果；
7. 在 RGB 图像上绘制检测框和类别文字；
8. 定期保存检测结果 JPG 快照；
9. 输出性能统计 CSV；
10. 统计完整链路 FPS；
11. 对比 05，判断接入 RKNN 后瓶颈是否转移；
12. 额外进行 06-nosnap 实验，验证保存快照是否是瓶颈。

---

## 3. 当前工程路径与文件

当前工程路径：

```bash
~/projects/rk3588_ai_stream
```

本实验新增文件：

```text
src/main_v4l2_rga_rknn_detect.cpp
docs/06_v4l2_rga_rknn_detect.md
```

复用文件：

```text
include/v4l2_mplane_capture.hpp
third_party/lubancat_yolo11_ref/postprocess.cc
third_party/lubancat_yolo11_ref/postprocess.h
~/lubancat_ai_manual_code/example/yolo11/cpp/rknpu2/yolo11.cc
```

本实验输出目录：

```text
output/exp06_v4l2_rga_rknn/
output/exp06_v4l2_rga_rknn_nosnap/
```

输出文件：

```text
output/exp06_v4l2_rga_rknn/profile_v4l2_rga_rknn.csv
output/exp06_v4l2_rga_rknn/frame_000000.jpg
output/exp06_v4l2_rga_rknn/frame_000030.jpg
output/exp06_v4l2_rga_rknn/frame_000060.jpg
output/exp06_v4l2_rga_rknn/frame_000090.jpg

output/exp06_v4l2_rga_rknn_nosnap/profile_v4l2_rga_rknn_nosnap.csv
```

---

## 4. 为什么 06 要接在 05 后面？

04 实验说明：

```text
OpenCV VideoCapture 是瓶颈；
不是摄像头硬件瓶颈；
不是 RKISP/V4L2 驱动瓶颈。
```

05 实验说明：

```text
V4L2 mmap + RGA 可以接近 30FPS；
输入链路已经可用。
```

因此 06 才有意义。如果没有 05，直接在 OpenCV `VideoCapture` 上接 RKNN，性能分析会混在一起：

```text
OpenCV 采集慢
OpenCV 隐式转换慢
RKNN 推理慢
VideoWriter 慢
```

而现在 06 建立在 05 基础上，输入链路已经基本排除。因此如果 06 变慢，就可以更明确地判断瓶颈主要来自 RKNN 推理整体链路。

---

## 5. 06 程序整体流程

06 程序流程如下：

```text
解析命令行参数
        ↓
打开 /dev/video11
        ↓
VIDIOC_S_FMT 设置 1280x720 NV12
        ↓
申请并 mmap V4L2 buffer
        ↓
启动视频流
        ↓
初始化 postprocess
        ↓
初始化 YOLO11 RKNN 模型
        ↓
循环处理每一帧
        ↓
select 等待帧
        ↓
VIDIOC_DQBUF 取出 NV12
        ↓
RGA NV12 → RGB888
        ↓
构造 image_buffer_t
        ↓
inference_yolo11_model()
        ↓
draw_results_to_rgb()
        ↓
按间隔保存 JPG 快照
        ↓
VIDIOC_QBUF 归还 buffer
        ↓
记录 CSV
        ↓
释放 RKNN / V4L2 资源
```

---

## 6. 06 程序参数格式

程序命令格式：

```bash
./build/v4l2_rga_rknn_detect   <model_path>   <video_device>   <width>   <height>   <frames>   <profile_csv>   <snapshot_dir>   <snapshot_interval>
```

参数说明：

| 参数 | 含义 |
|---|---|
| `model_path` | RKNN 模型路径 |
| `video_device` | V4L2 摄像头节点，例如 `/dev/video11` |
| `width` | 采集宽度 |
| `height` | 采集高度 |
| `frames` | 测试帧数 |
| `profile_csv` | 性能统计 CSV 路径 |
| `snapshot_dir` | JPG 快照保存目录 |
| `snapshot_interval` | 每隔多少帧保存一张快照 |

---

## 7. 编译 06 程序

进入工程目录：

```bash
cd ~/projects/rk3588_ai_stream
```

重新配置：

```bash
rm -rf build
mkdir build
cd build
cmake ..
```

编译 06：

```bash
make v4l2_rga_rknn_detect -j4
```

确认可执行文件：

```bash
ls -lh v4l2_rga_rknn_detect
```

---

## 8. 运行 06 实验

运行命令：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp06_v4l2_rga_rknn

./build/v4l2_rga_rknn_detect   models/yolo11.rknn   /dev/video11   1280   720   120   output/exp06_v4l2_rga_rknn/profile_v4l2_rga_rknn.csv   output/exp06_v4l2_rga_rknn   30
```

该命令会处理 120 帧，并每 30 帧保存一张快照：

```text
frame_000000.jpg
frame_000030.jpg
frame_000060.jpg
frame_000090.jpg
```

---

## 9. 06 运行结果

终端中可以看到 RGA 日志和 RKNN 推理日志：

```text
im2d_rga_impl rga_dump_opt(...)
im2d_rga_impl rga_task_submit(...)
rknn_run
frame=119 person @ (558 120 1278 710) 0.794
```

最终统计结果：

```text
========== 06 avg ==========
frames          : 120
select_ms       : 0.427
dqbuf_ms        : 0.006
rga_ms          : 2.888
input_prepare_ms: 0.002
model_total_ms  : 48.726
draw_ms         : 0.970
snapshot_ms     : 1.035
qbuf_ms         : 0.095
total_ms        : 54.157
avg_fps         : 18.465
============================

========== 06 final ==========
frames       : 120
wall_time_ms : 6505.845
wall_fps     : 18.445
avg_select_ms       : 0.427
avg_dqbuf_ms        : 0.006
avg_rga_ms          : 2.888
avg_input_prepare_ms: 0.002
avg_model_total_ms  : 48.726
avg_draw_ms         : 0.970
avg_snapshot_ms     : 1.035
avg_qbuf_ms         : 0.095
avg_total_ms        : 54.157
csv saved: output/exp06_v4l2_rga_rknn/profile_v4l2_rga_rknn.csv
================================
```

---

## 10. 06-nosnap 对照实验

为了确认保存 JPG 快照是否是性能瓶颈，又进行了 06-nosnap 实验。

方法是不修改代码，只把快照保存间隔设置得很大：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp06_v4l2_rga_rknn_nosnap

./build/v4l2_rga_rknn_detect   models/yolo11.rknn   /dev/video11   1280   720   120   output/exp06_v4l2_rga_rknn_nosnap/profile_v4l2_rga_rknn_nosnap.csv   output/exp06_v4l2_rga_rknn_nosnap   999999
```

这样只会保存第 0 帧，后续基本不保存图片。

06-nosnap 结果：

```text
========== 06 avg ==========
frames          : 120
select_ms       : 0.400
dqbuf_ms        : 0.006
rga_ms          : 2.932
input_prepare_ms: 0.002
model_total_ms  : 48.480
draw_ms         : 1.283
snapshot_ms     : 0.203
qbuf_ms         : 0.099
total_ms        : 53.412
avg_fps         : 18.722
============================

========== 06 final ==========
frames       : 120
wall_time_ms : 6416.177
wall_fps     : 18.703
avg_select_ms       : 0.400
avg_dqbuf_ms        : 0.006
avg_rga_ms          : 2.932
avg_input_prepare_ms: 0.002
avg_model_total_ms  : 48.480
avg_draw_ms         : 1.283
avg_snapshot_ms     : 0.203
avg_qbuf_ms         : 0.099
avg_total_ms        : 53.412
csv saved: output/exp06_v4l2_rga_rknn_nosnap/profile_v4l2_rga_rknn_nosnap.csv
================================
```

---

## 11. 06 与 06-nosnap 对比

| 实验 | wall_fps | model_total_ms | snapshot_ms | total_ms |
|---|---:|---:|---:|---:|
| 06 原始版本 | 18.445 | 48.726 ms | 1.035 ms | 54.157 ms |
| 06-nosnap | 18.703 | 48.480 ms | 0.203 ms | 53.412 ms |

可以看到：

```text
去掉大部分快照保存后：
    FPS 只从 18.445 提升到 18.703；
    model_total_ms 基本不变；
    total_ms 只减少约 0.745ms。
```

因此可以判断：

```text
保存 JPG 快照不是主要瓶颈。
真正瓶颈仍然是 inference_yolo11_model()。
```

---

## 12. 关键指标解释

### 12.1 `select_ms` 为什么从 05 的 28ms 变成 06 的 0.4ms？

05 中：

```text
select_ms ≈ 28.360ms
```

06 中：

```text
select_ms ≈ 0.400ms
```

这不是异常，反而说明瓶颈已经转移。

摄像头 30FPS 的帧周期约为：

```text
1000 / 30 = 33.33ms
```

05 中单帧处理时间约：

```text
33.670ms
```

程序处理很快，基本和摄像头出帧节奏同步，所以大部分时间都在 `select()` 等下一帧。

06 中单帧处理时间约：

```text
53.412ms
```

程序处理一帧已经超过摄像头帧周期。因此当程序处理完上一帧，再回到 `select()` 时，下一帧早就已经在 V4L2 buffer 中准备好了。所以 `select()` 基本不需要等待，`select_ms` 就变得很低。

这说明：

```text
不是摄像头不给帧；
是处理端跟不上摄像头 30FPS。
```

### 12.2 `dqbuf_ms ≈ 0.006ms`

`DQBUF` 本身几乎不耗时，说明 V4L2 mmap 取帧不是瓶颈。

### 12.3 `rga_ms ≈ 2.9ms`

06 中 RGA 完成：

```text
1280x720 NV12 → RGB888
```

平均耗时约 2.9ms。说明外部 RGA 颜色转换不是当前主要瓶颈。

05 中 RGA 约 5.124ms，06 中约 2.9ms，这种差异可以接受，可能与 RGA 驱动调度、缓存状态、程序节奏有关。关键点是无论是 5ms 还是 3ms，RGA 都不是当前 50ms 级别总耗时的主要来源。

### 12.4 `model_total_ms ≈ 48.5ms`

这是当前最关键的指标。

`model_total_ms` 统计的是：

```cpp
inference_yolo11_model(&rknn_app_ctx, &src_image, &od_results);
```

这一整个函数的耗时。它不等价于纯 `rknn_run`。

它可能包含：

```text
1. 输入图像检查；
2. RGB 图像 resize / letterbox 到模型输入尺寸，例如 640x640；
3. 内部 RGA / 图像转换；
4. rknn_inputs_set；
5. rknn_run；
6. rknn_outputs_get；
7. YOLO11 后处理；
8. NMS；
9. 结果写入 od_results。
```

因此当前只能说：

```text
瓶颈在 inference_yolo11_model() 整体内部。
```

还不能直接说瓶颈一定是 `rknn_run`。后续需要进一步做 07 实验，拆分 `inference_yolo11_model()` 内部耗时。

### 12.5 `draw_ms` 与 `snapshot_ms`

画框耗时约 1ms，不是主要瓶颈。

原始 06 中：

```text
snapshot_ms ≈ 1.035ms
```

06-nosnap 中：

```text
snapshot_ms ≈ 0.203ms
```

说明保存快照对整体 FPS 有一定影响，但影响很小，不是主瓶颈。

---

## 13. 和 05 实验对比

05 结果：

```text
wall_fps     : 29.611
avg_rga_ms   : 5.124
avg_total_ms : 33.670
```

06-nosnap 结果：

```text
wall_fps          : 18.703
avg_rga_ms        : 2.932
avg_model_total_ms: 48.480
avg_total_ms      : 53.412
```

对比说明：

```text
05 证明：
V4L2 mmap + RGA NV12→RGB 可以接近 30FPS，输入链路没有问题。

06 证明：
接入 RKNN 后，整体 FPS 降到约 18.7FPS，主要瓶颈变成 inference_yolo11_model()。
```

---

## 14. 当前完整链路耗时占比

以 06-nosnap 为准：

```text
avg_total_ms        : 53.412
avg_model_total_ms  : 48.480
```

占比：

```text
48.480 / 53.412 ≈ 90.8%
```

也就是说：

```text
inference_yolo11_model() 占了当前单帧总耗时的大约 90.8%。
```

其他模块：

```text
V4L2 取帧 / 还帧：
    基本可以忽略

外部 RGA NV12→RGB：
    约 2.9ms

画框：
    约 1.3ms

快照保存：
    约 0.2ms
```

因此当前优化重点已经非常明确：

```text
不再是摄像头采集；
不再是外部 RGA 颜色转换；
而是 inference_yolo11_model() 内部。
```

---

## 15. RGA 大量日志问题

运行时终端会出现大量类似日志：

```text
im2d_rga_impl rga_dump_opt(...)
im2d_rga_impl rga_task_submit(...)
```

这说明当前 RGA 库日志级别较高。

短期可以忽略，因为不影响实验结果。

可以尝试在运行前关闭：

```bash
export RGA_LOG_LEVEL=0
export RGA_DEBUG=0
```

如果仍然输出，说明当前 librga 版本可能默认打开了部分 dump 信息。该问题不影响本实验结论。

---

## 16. 06 实验结论

本实验完成后，可以得到以下结论：

```text
1. 程序成功完成 V4L2 mmap 采集、RGA NV12→RGB888 转换、RKNN YOLO11 推理和检测结果快照保存；
2. 120 帧测试中，完整链路 wall_fps 为 18.445FPS；
3. 06-nosnap 对照实验中，wall_fps 为 18.703FPS；
4. 去掉大部分快照保存后 FPS 提升很小，因此快照保存不是主要瓶颈；
5. V4L2 采集侧耗时很低，avg_select_ms 约 0.400ms，avg_dqbuf_ms 约 0.006ms；
6. 外部 RGA 颜色转换平均耗时约 2.9ms，不是主要瓶颈；
7. inference_yolo11_model() 平均耗时约 48.5ms，是当前完整链路的主要瓶颈；
8. 当前单线程串行链路无法达到 30FPS；
9. 由于处理耗时大于摄像头帧周期，select 基本不再等待，说明摄像头帧已经提前到达，瓶颈转移到了推理处理端；
10. 下一步需要拆解 inference_yolo11_model() 内部耗时。
```

---

## 17. 和 04、05 实验的关系

### 04 实验

04 用于发现问题：

```text
OpenCV VideoCapture 采集慢；
默认 4K 约 5FPS；
设置 720P 约 15FPS；
v4l2-ctl 原生采集可接近 30FPS。
```

### 05 实验

05 用于替换输入链路：

```text
V4L2 mmap + RGA NV12→RGB；
完整预处理链路接近 30FPS。
```

### 06 实验

06 用于接入 AI 推理：

```text
V4L2 mmap + RGA + RKNN；
完整检测链路约 18.7FPS；
瓶颈转移到 inference_yolo11_model()。
```

整体逻辑：

```text
04：定位 OpenCV 采集瓶颈
        ↓
05：用 V4L2 + RGA 替代 OpenCV 输入链路
        ↓
06：在新输入链路上接入 RKNN 推理
        ↓
07：拆解 inference_yolo11_model 内部耗时
```

---

## 18. 后续实验方向

当前最合理的下一步不是马上做三线程，而是先做：

```text
07_model_internal_profile
```

也就是拆解：

```cpp
inference_yolo11_model()
```

内部耗时。

需要分别统计：

```text
1. 内部 resize / letterbox / convert_image_with_letterbox；
2. rknn_inputs_set；
3. rknn_run；
4. rknn_outputs_get；
5. post_process；
6. NMS；
7. rknn_outputs_release；
8. 总耗时。
```

这样才能判断：

```text
如果 rknn_run 本身接近 40ms：
    主要瓶颈是 NPU 模型推理，需要考虑模型输入尺寸、量化、NPU core、RKNN 配置。

如果 preprocess 很高：
    说明内部又做了一次 resize / letterbox，需要考虑外部 RGA 直接输出模型输入尺寸。

如果 postprocess 很高：
    需要优化 YOLO11 后处理 / NMS。

如果 outputs_get 很高：
    可能是输出 tensor 拷贝或内存布局问题。
```

等 07 完成后，再决定后续是否进入：

```text
08_camera_pipeline
    采集 / 推理 / 编码三线程流水线

09_mpp_encode_record
    MPP 硬件编码保存

10_rtsp_stream_preview
    RTSP / HTTP-FLV / HLS 实时预览
```

---

## 19. 当前阶段总结

截至 06 实验结束，当前项目已经具备：

```text
1. 单图检测 image_detect；
2. 视频文件检测 video_detect；
3. OpenCV 摄像头检测 camera_detect；
4. OpenCV 摄像头性能剖析 camera_profile；
5. V4L2 mmap 原生采集能力；
6. RGA NV12→RGB888 实时转换能力；
7. V4L2 + RGA + RKNN 完整检测链路；
8. 完整链路性能统计 CSV；
9. 检测结果 JPG 快照保存；
10. 明确定位当前瓶颈在 inference_yolo11_model() 内部。
```

当前性能结果：

```text
05 V4L2 + RGA 预处理：
    wall_fps ≈ 29.611 FPS

06 V4L2 + RGA + RKNN：
    wall_fps ≈ 18.445 FPS

06-nosnap：
    wall_fps ≈ 18.703 FPS
```

最终判断：

```text
输入链路已经优化成功；
当前主要瓶颈已经转移到 RKNN 推理整体函数；
下一步应进行模型内部耗时拆解，而不是盲目继续堆流水线。
```

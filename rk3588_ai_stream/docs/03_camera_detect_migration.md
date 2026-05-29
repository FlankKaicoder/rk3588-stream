# 03 camera_detect 摄像头检测迁移记录

## 1. 实验背景

前面已经完成了两个基础实验：

```text
01_image_detect：
单张图片 → RKNN YOLO11 推理 → YOLO11 后处理 → 画框 → 保存结果图片

02_video_detect：
视频文件 → OpenCV 逐帧读取 → RKNN YOLO11 推理 → YOLO11 后处理 → 画框 → 保存结果视频
```

但是最终的 RK3588 端侧 AI 视频分析系统不能只处理离线图片和离线视频，还需要接入真实摄像头，完成从板端摄像头采集到 RKNN 推理、检测框绘制、结果视频保存的完整闭环。

因此本实验继续完成第三个里程碑：

```text
摄像头输入 → RKNN YOLO11 推理 → 检测框绘制 → 保存检测视频
```

本实验生成的程序为：

```bash
camera_detect
```

该程序是后续继续扩展 V4L2、RGA、MPP、RTSP、MP4 录制和孔探缺陷检测模型部署的基础。

---

## 2. 实验目标

本实验要完成：

1. 确认鲁班猫 RK3588 上的 `/dev/video*` 设备节点；
2. 使用 `v4l2-ctl` 查看各 video 节点对应的硬件模块；
3. 使用 OpenCV 扫描可以正常读取的摄像头 index；
4. 确认当前可用摄像头节点为 OpenCV index `11`，对应 `/dev/video11`；
5. 新建 `src/main_camera.cpp`；
6. 在 `CMakeLists.txt` 中加入 `camera_detect` 编译目标；
7. 使用 OpenCV `VideoCapture` 读取摄像头帧；
8. 将摄像头原始 4K 图像缩放到 1280x720；
9. 将 BGR 图像转换为 RGB；
10. 构造 `image_buffer_t` 并送入 `inference_yolo11_model()`；
11. 使用 YOLO11 后处理解析检测框和类别；
12. 使用 OpenCV 在图像上绘制检测框和类别文字；
13. 使用 OpenCV `VideoWriter` 保存检测结果视频；
14. 使用 OpenCV 重新读取输出视频，验证结果文件有效性。

---

## 3. 当前工程路径

当前工程路径：

```bash
~/projects/rk3588_ai_stream
```

当前相关文件结构：

```text
rk3588_ai_stream/
├── CMakeLists.txt
├── src/
│   ├── main_image.cpp
│   ├── main_video.cpp
│   └── main_camera.cpp
├── models/
│   └── yolo11.rknn
├── model/
│   └── coco_80_labels_list.txt
├── output/
│   ├── result.jpg
│   ├── video_result.mp4
│   └── camera_result_60.mp4
├── input/
│   └── test.mp4
├── docs/
│   ├── 00_lubancat_demo_baseline.md
│   ├── 01_image_detect_migration.md
│   ├── 02_video_detect_migration.md
│   └── 03_camera_detect_migration.md
└── third_party/
    └── lubancat_yolo11_ref/
        ├── yolo11_image_demo.cc
        ├── yolo11_videocapture_demo.cc
        ├── yolo11_image_demo_slide.cc
        ├── postprocess.cc
        ├── postprocess.h
        └── yolo11.h
```

---

## 4. 摄像头设备检查

首先查看当前系统中的视频节点：

```bash
cd ~/projects/rk3588_ai_stream
ls /dev/video*
```

当前系统存在多个视频节点：

```text
/dev/video0
/dev/video1
/dev/video2
/dev/video3
/dev/video4
/dev/video5
/dev/video6
/dev/video7
/dev/video8
/dev/video9
/dev/video10
/dev/video11
/dev/video12
/dev/video13
/dev/video14
/dev/video15
/dev/video16
/dev/video17
/dev/video18
/dev/video19
/dev/video20
/dev/video-camera0
/dev/video-enc0
/dev/video-dec0
```

进一步使用 `v4l2-ctl` 查看 video 设备对应关系：

```bash
v4l2-ctl --list-devices
```

关键输出如下：

```text
rk_hdmirx (fdee0000.hdmirx-controller):
        /dev/video20

rkisp-statistics (platform: rkisp):
        /dev/video18
        /dev/video19

rkcif-mipi-lvds (platform:rkcif):
        /dev/media0

rkcif (platform:rkcif-mipi-lvds):
        /dev/video0
        /dev/video1
        /dev/video2
        /dev/video3
        /dev/video4
        /dev/video5
        /dev/video6
        /dev/video7
        /dev/video8
        /dev/video9
        /dev/video10

rkisp_mainpath (platform:rkisp0-vir0):
        /dev/video11
        /dev/video12
        /dev/video13
        /dev/video14
        /dev/video15
        /dev/video16
        /dev/video17
        /dev/media1
```

从设备关系可以初步判断：

```text
/dev/video0 ~ /dev/video10：
    更偏 rkcif 底层输入节点，OpenCV 不一定能直接读取成普通三通道图像。

/dev/video11 ~ /dev/video17：
    属于 rkisp_mainpath，可能是 ISP 处理后的主路径或自路径输出，更适合应用层读取。

/dev/video18 /dev/video19：
    是 rkisp statistics 统计节点，不适合作为普通图像输入。

/dev/video20：
    是 HDMI RX 输入节点。
```

因此本实验重点测试 `/dev/video11` 附近的节点。

---

## 5. 使用 OpenCV 扫描可用摄像头 index

执行以下 Python 脚本，扫描 OpenCV 能够打开和读取的摄像头 index：

```bash
python3 - <<'PY'
import cv2

for i in range(0, 30):
    cap = cv2.VideoCapture(i)
    if cap.isOpened():
        ret, frame = cap.read()
        print("camera index:", i, "read:", ret, "shape:", None if frame is None else frame.shape)
        cap.release()
PY
```

关键输出：

```text
camera index: 11 read: True shape: (2160, 3840, 3)
camera index: 12 read: True shape: (2160, 1920)
```

结论：

```text
camera index 11：
    可以正常读取；
    输出 shape = (2160, 3840, 3)；
    即 3840x2160 三通道图像；
    适合作为本实验摄像头输入。

camera index 12：
    可以读取；
    但 shape = (2160, 1920)；
    只有两个维度，不是常规 BGR 三通道图像；
    可能是灰度、YUV 单平面或特殊格式；
    当前实验暂不使用。
```

因此本实验使用：

```bash
11
```

作为摄像头输入。

---

## 6. 为什么不直接使用 imshow 实时显示？

官方 `yolo11_videocapture_demo.cc` 中使用的是：

```cpp
cv::imshow("yolo11", frame);
cv::waitKey(1);
```

但是当前开发方式是：

```text
VSCode Remote SSH 远程连接鲁班猫 RK3588
```

在这种环境中，直接使用 `imshow()` 可能会遇到问题：

1. 板端没有桌面环境；
2. SSH 终端没有图形显示能力；
3. OpenCV GUI 后端不可用；
4. 程序可能卡住；
5. 无法通过 ESC 正常退出；
6. 结果不好保存和复现。

因此本实验采用：

```text
摄像头输入
    ↓
检测
    ↓
画框
    ↓
保存为 MP4 文件
```

---

## 7. 为什么将摄像头画面缩放为 1280x720？

摄像头 index 11 读取到的原始图像为：

```text
3840x2160x3
```

也就是 4K 图像。如果直接处理 4K 图像，会导致 CPU 侧 `resize` / `cvtColor` 开销较大，写视频慢，输出文件体积也大。

因此本实验采用：

```text
摄像头原始 3840x2160
        ↓
OpenCV resize
        ↓
1280x720
        ↓
RKNN 推理和画框
        ↓
保存为 1280x720 MP4
```

当前设置：

```cpp
const int output_width = 1280;
const int output_height = 720;
const double output_fps = 25.0;
```

这一步只是为了先完成摄像头检测闭环。后续可以继续用 RGA 替换 OpenCV resize，用 MPP 替换 OpenCV VideoWriter。

---

## 8. 为什么强制输出 FPS = 25？

一开始测试时，视频看起来只有 1 秒左右。原因可能是程序只保存了 100 帧，而摄像头上报 FPS 可能较高，播放器按较高 FPS 播放。

因此本实验固定输出：

```text
25 FPS
```

这样：

```text
60 帧 / 25 FPS = 2.4 秒
300 帧 / 25 FPS = 12 秒
```

当前实验先保存 60 帧，用于快速验证。

---

## 9. camera_detect 程序功能

程序命令格式：

```bash
./build/camera_detect <model_path> <camera_index_or_device_path> <output_video> [max_frames]
```

示例：

```bash
./build/camera_detect models/yolo11.rknn 11 output/camera_result_60.mp4 60
```

参数含义：

| 参数 | 说明 |
|---|---|
| `models/yolo11.rknn` | YOLO11 RKNN 模型 |
| `11` | OpenCV 摄像头 index，对应 `/dev/video11` |
| `output/camera_result_60.mp4` | 输出检测视频 |
| `60` | 最大处理帧数 |

---

## 10. 输入源判断逻辑

为了同时支持：

```bash
11
```

和：

```bash
/dev/video11
```

程序中加入了数字字符串判断函数：

```cpp
static bool is_number_string(const char *s)
{
    if (s == NULL || *s == '
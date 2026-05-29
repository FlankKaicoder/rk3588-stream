# 00 鲁班猫 YOLO11 官方 Demo 基线验证记录

## 1. 实验背景

本实验是整个 `rk3588_ai_stream` 项目的起点。

当前使用的开发板为：

- 板卡：鲁班猫 RK3588
- 系统环境：板端 Linux
- 操作方式：VSCode Remote SSH 远程连接开发板
- 参考代码库：`lubancat_ai_manual_code`
- 参考 Demo：YOLO11 C++ RKNN 推理 Demo

本项目后续目标是构建一个基于 RK3588 的端侧 AI 视频分析系统，包括：

1. 单图检测；
2. 视频文件检测；
3. 摄像头实时检测；
4. RGA 图像预处理；
5. RKNN NPU 推理；
6. 后续接入 MPP 编码、RTSP 推流、MP4 录制；
7. 后续替换为自训练孔探缺陷检测模型；
8. 后续接入远程文件管理系统，用于管理录像、检测结果、模型文件和日志。

在正式迁移到自己的工程前，必须先确认鲁班猫官方 YOLO11 Demo 能在当前板子上正常运行。

---

## 2. 实验目标

本实验目标：

1. 确认 `lubancat_ai_manual_code/example/yolo11/cpp` 代码完整；
2. 确认官方编译产物存在；
3. 确认 YOLO11 RKNN 模型能在 RK3588 上正常加载；
4. 确认 RKNN Runtime 能正常推理；
5. 确认 RGA 预处理链路可用；
6. 确认 YOLO11 后处理结果正常；
7. 确认输出检测图片 `out.png` 正常生成；
8. 为后续迁移到自己的 `rk3588_ai_stream` 工程提供基线。

---

## 3. 原始工程路径

原始 YOLO11 C++ Demo 路径：

~~~bash
~/lubancat_ai_manual_code/example/yolo11/cpp
~~~

进入目录：

~~~bash
cd ~/lubancat_ai_manual_code/example/yolo11/cpp
ls
~~~

实际目录内容：

~~~text
build
build-linux.sh
CMakeLists.txt
install
postprocess.cc
postprocess.h
rknpu2
yolo11.h
yolo11_image_demo.cc
yolo11_image_demo_slide.cc
yolo11_videocapture_demo.cc
~~~

说明：

| 文件 / 目录 | 作用 |
|---|---|
| `yolo11_image_demo.cc` | 普通单图检测 Demo |
| `yolo11_image_demo_slide.cc` | 切片 / 滑窗辅助推理 Demo |
| `yolo11_videocapture_demo.cc` | 摄像头 / 视频输入 Demo |
| `postprocess.cc` | YOLO11 后处理逻辑 |
| `postprocess.h` | 后处理头文件 |
| `yolo11.h` | RKNN YOLO11 接口声明 |
| `rknpu2/` | RK3588/RKNPU2 相关推理实现 |
| `CMakeLists.txt` | 原始编译配置 |
| `install/rk3588_linux/` | 已编译安装目录 |

---

## 4. 原始安装目录检查

进入官方安装目录：

~~~bash
cd ~/lubancat_ai_manual_code/example/yolo11/cpp/install/rk3588_linux
ls
~~~

实际内容：

~~~text
lib
model
out.png
out_slide.png
yolo11_image_demo
yolo11_image_demo_slide
yolo11_image_demo_zero_copy
yolo11_videocapture_demo
yolo11_videocapture_demo_zero_copy
~~~

说明当前官方 Demo 已经包含多个版本：

| 可执行程序 | 作用 |
|---|---|
| `yolo11_image_demo` | 普通单图检测 |
| `yolo11_image_demo_slide` | 切片 / 滑窗推理 |
| `yolo11_image_demo_zero_copy` | 单图 Zero-Copy 优化版本 |
| `yolo11_videocapture_demo` | 摄像头 / 视频检测 |
| `yolo11_videocapture_demo_zero_copy` | 视频 / 摄像头 Zero-Copy 优化版本 |

这说明当前鲁班猫代码库不仅能完成普通 YOLO11 推理，还已经包含后续可继续研究的：

1. 切片推理；
2. 摄像头检测；
3. Zero-Copy 优化。

---

## 5. 查看官方 Demo 参数格式

执行：

~~~bash
./yolo11_image_demo
~~~

输出：

~~~text
./yolo11_image_demo <model_path> <image_path>
~~~

说明官方单图检测程序需要两个参数：

1. RKNN 模型路径；
2. 输入图片路径。

---

## 6. 运行官方 YOLO11 单图检测 Demo

运行命令：

~~~bash
cd ~/lubancat_ai_manual_code/example/yolo11/cpp/install/rk3588_linux
./yolo11_image_demo ./model/yolo11.rknn ./model/bus.jpg
~~~

关键输出：

~~~text
model is NHWC input fmt
model input height=640, width=640, channel=3
origin size=640x640 crop size=640x640
input image: 640 x 640, subsampling: 4:2:0, colorspace: YCbCr, orientation: 1
scale=1.000000 dst_box=(0 0 639 639) allow_slight_change=1 _left_offset=0 _top_offset=0 padding_w=0 padding_h=0
rga_api version 1.10.1_[0]
rknn_run
bus @ (95 137 553 437) 0.931
person @ (108 235 224 534) 0.890
person @ (476 230 559 521) 0.831
person @ (212 240 284 509) 0.820
person @ (79 359 118 516) 0.484
write_image path: out.png width=640 height=640 channel=3
~~~

检查输出文件：

~~~bash
ls -lh out.png
~~~

结果：

~~~text
-rw-r--r-- 1 cat cat 703K  5月 28 22:06 out.png
~~~

---

## 7. 关键日志解释

### 7.1 模型输入格式

~~~text
model is NHWC input fmt
model input height=640, width=640, channel=3
~~~

说明当前 RKNN 模型输入格式为：

~~~text
NHWC = batch, height, width, channel
~~~

也就是：

~~~text
1 x 640 x 640 x 3
~~~

这对后续预处理非常重要。后续无论是 OpenCV、RGA，还是 V4L2 摄像头输入，最终都要把输入图像整理成模型需要的格式。

---

### 7.2 RGA 预处理可用

~~~text
rga_api version 1.10.1_[0]
~~~

说明当前 Demo 内部已经调用了 RGA 图像处理能力，至少用于 resize / letterbox / 图像拷贝等预处理流程。

这也证明当前板子的 RGA 环境可用。

---

### 7.3 RKNN 推理正常

~~~text
rknn_run
~~~

说明模型已经进入 RKNN Runtime 的推理阶段，并且推理成功返回。

---

### 7.4 后处理结果正常

输出结果：

~~~text
bus @ (95 137 553 437) 0.931
person @ (108 235 224 534) 0.890
person @ (476 230 559 521) 0.831
person @ (212 240 284 509) 0.820
person @ (79 359 118 516) 0.484
~~~

说明：

1. YOLO11 输出 Tensor 解析正常；
2. 后处理框坐标正常；
3. COCO 类别名正常；
4. 置信度正常；
5. 检测结果符合 `bus.jpg` 图像内容。

---

## 8. 当前基线结论

当前官方 Demo 已经验证成功：

1. `yolo11.rknn` 模型能在鲁班猫 RK3588 上加载；
2. RKNN Runtime 可以正常执行推理；
3. RGA 图像预处理链路可用；
4. YOLO11 后处理逻辑可用；
5. COCO 类别文件可用；
6. 检测框和类别均正常；
7. 输出图片 `out.png` 正常生成。

因此后续不需要从零开始写 RKNN 推理代码，而应该复用官方 Demo 的可靠实现，逐步迁移到自己的工程结构中。

---

## 9. 和后续项目的关系

本实验是后续所有工作的基础。

后续路线：

~~~text
官方 yolo11_image_demo 跑通
        ↓
迁移成自己的 image_detect
        ↓
迁移成 video_detect
        ↓
迁移成 camera_detect
        ↓
研究 slide / 切片推理
        ↓
研究 zero-copy 推理
        ↓
接入 MPP 编码 / RTSP 推流
        ↓
后续替换为孔探缺陷检测模型
~~~

---

## 10. 当前可复用资产

| 资产 | 后续用途 |
|---|---|
| `yolo11_image_demo.cc` | 单图检测迁移参考 |
| `yolo11_videocapture_demo.cc` | 视频 / 摄像头检测迁移参考 |
| `yolo11_image_demo_slide.cc` | 后续高分辨率切片推理参考 |
| `rknpu2/yolo11.cc` | RKNPU2 推理接口实现 |
| `postprocess.cc` | YOLO11 后处理逻辑 |
| `postprocess.h` | 后处理接口声明 |
| `yolo11.h` | RKNN YOLO11 模型接口 |
| `model/yolo11.rknn` | 当前 COCO 检测模型 |
| `model/bus.jpg` | 当前测试图片 |
| `model/coco_80_labels_list.txt` | COCO 类别文件 |

---

## 11. 实验状态

状态：完成。

当前已经完成官方 Demo 基线验证，可以进入下一步：

~~~text
01_image_detect_migration
~~~

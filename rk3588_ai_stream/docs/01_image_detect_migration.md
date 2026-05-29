# 01 image_detect 单图检测工程迁移记录

## 1. 实验背景

在实验 00 中，已经确认鲁班猫官方 YOLO11 单图检测 Demo 可以在 RK3588 上正常运行。

但是官方 Demo 仍然属于原始示例工程，存在几个问题：

1. 工程目录属于 `lubancat_ai_manual_code`，不是自己的项目；
2. 程序名是官方的 `yolo11_image_demo`；
3. 输出路径写死为 `out.png`；
4. 后续不方便继续扩展视频检测、摄像头检测、切片推理、MPP 编码、RTSP 推流等模块；
5. 不适合作为最终简历项目的工程结构。

因此本实验目标是将官方 Demo 中的单图检测逻辑迁移到自己的项目：

~~~bash
~/projects/rk3588_ai_stream
~~~

并生成自己的可执行程序：

~~~bash
image_detect
~~~

---

## 2. 实验目标

本实验目标：

1. 新建自己的工程目录 `rk3588_ai_stream`；
2. 复制鲁班猫 YOLO11 相关参考代码；
3. 复制 RKNN 模型和测试图片；
4. 基于官方 `yolo11_image_demo.cc` 生成自己的 `src/main_image.cpp`；
5. 修改程序参数格式，支持自定义输出路径；
6. 编写自己的顶层 `CMakeLists.txt`；
7. 复用原工程中的：
   - `rknpu2/yolo11.cc`
   - `postprocess.cc`
   - `postprocess.h`
   - `yolo11.h`
   - `3rdparty`
   - `utils`
8. 编译生成 `build/image_detect`；
9. 运行自己的 `image_detect`；
10. 输出检测结果图片 `output/result.jpg`；
11. 解决类别名显示 `null` 的问题。

---

## 3. 创建项目目录

执行：

~~~bash
mkdir -p ~/projects/rk3588_ai_stream/{include,src,models,configs,docs,output,third_party/lubancat_yolo11_ref}
cd ~/projects/rk3588_ai_stream
~~~

目录设计：

~~~text
rk3588_ai_stream/
├── include/                         # 后续放自己的头文件
├── src/                             # 自己的主程序源码
├── models/                          # RKNN 模型
├── configs/                         # 后续模型配置文件
├── docs/                            # 实验记录和项目文档
├── output/                          # 输出图片、视频、日志
└── third_party/
    └── lubancat_yolo11_ref/         # 鲁班猫 YOLO11 参考代码
~~~

说明：

这里没有直接修改官方工程，而是将官方工程作为参考代码复制到 `third_party` 目录中。这样做的好处是：

1. 保留官方工程原始状态；
2. 避免改坏官方 Demo；
3. 后续自己的代码可以逐步替换参考代码；
4. 方便对比官方实现和自己的实现。

---

## 4. 复制鲁班猫 YOLO11 参考代码

执行：

~~~bash
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/yolo11_image_demo.cc third_party/lubancat_yolo11_ref/
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/yolo11_image_demo_slide.cc third_party/lubancat_yolo11_ref/
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/yolo11_videocapture_demo.cc third_party/lubancat_yolo11_ref/
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/postprocess.cc third_party/lubancat_yolo11_ref/
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/postprocess.h third_party/lubancat_yolo11_ref/
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/yolo11.h third_party/lubancat_yolo11_ref/
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/CMakeLists.txt third_party/lubancat_yolo11_ref/
~~~

复制后的参考代码包括：

| 文件 | 作用 |
|---|---|
| `yolo11_image_demo.cc` | 官方单图检测入口 |
| `yolo11_image_demo_slide.cc` | 官方切片推理入口 |
| `yolo11_videocapture_demo.cc` | 官方摄像头 / 视频输入入口 |
| `postprocess.cc` | YOLO11 后处理 |
| `postprocess.h` | 后处理头文件 |
| `yolo11.h` | RKNN YOLO11 接口声明 |
| `CMakeLists.txt` | 官方编译配置参考 |

---

## 5. 复制模型和测试图片

执行：

~~~bash
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/install/rk3588_linux/model/*.rknn models/
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/install/rk3588_linux/model/bus.jpg output/
~~~

当前模型和测试图片：

~~~text
models/yolo11.rknn
output/bus.jpg
~~~

检查文件：

~~~bash
find . -maxdepth 3 -type f | sort
~~~

实际关键文件：

~~~text
./models/yolo11.rknn
./output/bus.jpg
./third_party/lubancat_yolo11_ref/CMakeLists.txt
./third_party/lubancat_yolo11_ref/postprocess.cc
./third_party/lubancat_yolo11_ref/postprocess.h
./third_party/lubancat_yolo11_ref/yolo11.h
./third_party/lubancat_yolo11_ref/yolo11_image_demo.cc
./third_party/lubancat_yolo11_ref/yolo11_image_demo_slide.cc
./third_party/lubancat_yolo11_ref/yolo11_videocapture_demo.cc
~~~

---

## 6. 生成自己的 `src/main_image.cpp`

最初做法是直接复制官方单图 Demo：

~~~bash
cd ~/projects/rk3588_ai_stream
mkdir -p src
cp third_party/lubancat_yolo11_ref/yolo11_image_demo.cc src/main_image.cpp
~~~

检查文件：

~~~bash
ls -lh src/main_image.cpp
~~~

输出：

~~~text
-rw-r--r-- 1 cat cat 4.1K  5月 28 22:18 src/main_image.cpp
~~~

---

## 7. 修改程序参数：支持自定义输出路径

官方 Demo 参数格式：

~~~bash
./yolo11_image_demo <model_path> <image_path>
~~~

官方 Demo 输出路径写死为：

~~~text
out.png
~~~

迁移后希望支持：

~~~bash
./build/image_detect models/yolo11.rknn output/bus.jpg output/result.jpg
~~~

也就是新增第三个参数：

~~~text
output_path
~~~

执行修改：

~~~bash
sed -i 's/if (argc != 3)/if (argc != 4)/' src/main_image.cpp

sed -i 's/printf("%s <model_path> <image_path>\\n", argv\[0\]);/printf("%s <model_path> <image_path> <output_path>\\n", argv[0]);/' src/main_image.cpp

sed -i '/const char \*image_path = argv\[2\];/a\    const char *output_path = argv[3];' src/main_image.cpp

sed -i 's/write_image("out.png", &src_image);/write_image(output_path, \&src_image);/' src/main_image.cpp
~~~

检查修改结果：

~~~bash
grep -n "argc\|output_path\|write_image" src/main_image.cpp
~~~

输出：

~~~text
35:int main(int argc, char **argv)
37:    if (argc != 4)
39:        printf("%s <model_path> <image_path> <output_path>\n", argv[0]);
45:    const char *output_path = argv[3];
111:    write_image(output_path, &src_image);
~~~

说明：

1. 参数数量已经从 3 改为 4；
2. 新增 `output_path`；
3. 输出图片路径不再写死为 `out.png`；
4. 现在可以由命令行指定结果图片路径。

---

## 8. 编写自己的 CMakeLists.txt

新工程需要自己的 `CMakeLists.txt`。

由于鲁班猫 YOLO11 Demo 依赖原工程中的多个模块，所以不能只编译 `main_image.cpp`。

依赖关系包括：

1. `rknpu2/yolo11.cc`
2. `postprocess.cc`
3. `imageutils`
4. `fileutils`
5. `imagedrawing`
6. `librknnrt`
7. `3rdparty`
8. `utils`

最终 `CMakeLists.txt` 内容如下：

~~~cmake
cmake_minimum_required(VERSION 3.10)

project(rk3588_ai_stream)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(TARGET_SOC "rk3588" CACHE STRING "Target SoC")

set(LUBANCAT_YOLO11_CPP
    "$ENV{HOME}/lubancat_ai_manual_code/example/yolo11/cpp"
    CACHE PATH "Path to LubanCat YOLO11 cpp demo")

set(LUBANCAT_EXAMPLE_DIR "${LUBANCAT_YOLO11_CPP}/../..")

message(STATUS "LUBANCAT_YOLO11_CPP = ${LUBANCAT_YOLO11_CPP}")
message(STATUS "LUBANCAT_EXAMPLE_DIR = ${LUBANCAT_EXAMPLE_DIR}")

find_package(OpenCV REQUIRED)

include_directories(${LUBANCAT_EXAMPLE_DIR}/3rdparty/allocator/dma)

add_subdirectory(${LUBANCAT_EXAMPLE_DIR}/3rdparty 3rdparty.out)
add_subdirectory(${LUBANCAT_EXAMPLE_DIR}/utils utils.out)

set(RKNPU_YOLO11_SRC "${LUBANCAT_YOLO11_CPP}/rknpu2/yolo11.cc")

add_executable(image_detect
    src/main_image.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(image_detect PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(image_detect
    imageutils
    fileutils
    imagedrawing
    ${LIBRKNNRT}
    dl
    pthread
)
~~~

说明：

| 配置 | 作用 |
|---|---|
| `LUBANCAT_YOLO11_CPP` | 指向原鲁班猫 YOLO11 C++ Demo |
| `LUBANCAT_EXAMPLE_DIR` | 指向原 example 根目录 |
| `add_subdirectory(3rdparty)` | 引入 RKNN/RGA 等第三方依赖 |
| `add_subdirectory(utils)` | 引入 image/file/drawing 工具库 |
| `RKNPU_YOLO11_SRC` | 使用 RK3588 对应的 RKNPU2 推理实现 |
| `imageutils` | 图像读取、写入、格式转换 |
| `fileutils` | 文件相关工具 |
| `imagedrawing` | 在图片上画框和文字 |
| `${LIBRKNNRT}` | RKNN Runtime 库 |

---

## 9. 编译 image_detect

执行：

~~~bash
cd ~/projects/rk3588_ai_stream
rm -rf build
mkdir build
cd build
cmake ..
make -j4
~~~

关键编译输出：

~~~text
-- LUBANCAT_YOLO11_CPP = /home/cat/lubancat_ai_manual_code/example/yolo11/cpp
-- LUBANCAT_EXAMPLE_DIR = /home/cat/lubancat_ai_manual_code/example/yolo11/cpp/../..
-- Found OpenCV: /usr (found version "4.5.1")
[100%] Linking CXX executable image_detect
[100%] Built target image_detect
~~~

说明：

1. CMake 找到了鲁班猫 YOLO11 原始路径；
2. CMake 找到了 OpenCV；
3. `utils` 和 `3rdparty` 相关库成功编译；
4. `image_detect` 成功生成。

---

## 10. 第一次运行 image_detect

执行：

~~~bash
cd ~/projects/rk3588_ai_stream
./build/image_detect models/yolo11.rknn output/bus.jpg output/result.jpg
ls -lh output/result.jpg
~~~

第一次运行出现了一个问题：

~~~text
Open ./model/coco_80_labels_list.txt fail!
~~~

后续检测框坐标正常，但是类别名显示为：

~~~text
null
~~~

例如：

~~~text
null @ (95 137 553 437) 0.931
null @ (108 235 224 534) 0.890
null @ (476 230 559 521) 0.831
null @ (212 240 284 509) 0.820
null @ (79 359 118 516) 0.484
~~~

同时结果图片依然生成：

~~~text
-rw-r--r-- 1 cat cat 201K  5月 28 22:19 output/result.jpg
~~~

---

## 11. 问题分析：为什么类别名显示 null？

问题原因：

`postprocess.cc` 中的类别名称加载逻辑默认读取：

~~~bash
./model/coco_80_labels_list.txt
~~~

但当前新工程中只有：

~~~text
models/yolo11.rknn
output/bus.jpg
~~~

并没有：

~~~text
model/coco_80_labels_list.txt
~~~

注意这里有两个目录名：

| 目录 | 用途 |
|---|---|
| `models/` | 当前新工程中存放 RKNN 模型 |
| `model/` | 原始后处理代码默认查找 COCO label 的路径 |

由于 label 文件没有放在 `./model/` 下，所以 `coco_cls_to_name()` 无法返回类别名，最终打印为 `null`。

---

## 12. 修复类别文件缺失问题

创建 `model/` 目录，并复制 COCO label 文件：

~~~bash
cd ~/projects/rk3588_ai_stream

mkdir -p model

cp ~/lubancat_ai_manual_code/example/yolo11/model/coco_80_labels_list.txt model/
~~~

重新运行：

~~~bash
./build/image_detect models/yolo11.rknn output/bus.jpg output/result.jpg
~~~

修复后输出：

~~~text
bus @ (95 137 553 437) 0.931
person @ (108 235 224 534) 0.890
person @ (476 230 559 521) 0.831
person @ (212 240 284 509) 0.820
person @ (79 359 118 516) 0.484
write_image path: output/result.jpg width=640 height=640 channel=3
~~~

说明类别名已经恢复正常。

---

## 13. 最终运行命令

最终单图检测命令：

~~~bash
cd ~/projects/rk3588_ai_stream
./build/image_detect models/yolo11.rknn output/bus.jpg output/result.jpg
~~~

输出结果：

~~~text
output/result.jpg
~~~

---

## 14. 当前 image_detect 程序工作流程

整体流程：

~~~text
命令行参数解析
        ↓
读取模型路径、图片路径、输出路径
        ↓
init_post_process()
        ↓
init_yolo11_model()
        ↓
read_image()
        ↓
inference_yolo11_model()
        ↓
YOLO11 后处理
        ↓
遍历检测结果
        ↓
draw_rectangle / draw_text
        ↓
write_image(output_path)
        ↓
release_yolo11_model()
        ↓
deinit_post_process()
~~~

---

## 15. 当前程序和官方 Demo 的区别

| 对比项 | 官方 `yolo11_image_demo` | 当前 `image_detect` |
|---|---|---|
| 所属工程 | 鲁班猫官方工程 | 自己的 `rk3588_ai_stream` |
| 输入参数 | `<model_path> <image_path>` | `<model_path> <image_path> <output_path>` |
| 输出路径 | 固定 `out.png` | 可自定义 |
| 可执行程序名 | `yolo11_image_demo` | `image_detect` |
| 后续扩展性 | 示例程序 | 可继续扩展为项目工程 |

---

## 16. 当前确认可用能力

本实验完成后，当前项目已经具备：

1. 自己的工程目录；
2. 自己的 CMake 构建入口；
3. 自己的单图检测程序 `image_detect`；
4. RKNN YOLO11 模型加载；
5. RKNN Runtime 推理；
6. RGA 预处理；
7. YOLO11 后处理；
8. COCO 类别显示；
9. 检测框绘制；
10. 结果图片保存。

---

## 17. 当前不足

当前 `image_detect` 仍然是基于官方 Demo 快速迁移而来，还存在一些不足：

1. 代码还没有拆成类；
2. `main_image.cpp` 仍然比较过程式；
3. label 文件路径仍然依赖 `./model/coco_80_labels_list.txt`；
4. 模型配置还没有 JSON 化；
5. 暂时只支持 COCO 模型；
6. 暂时没有性能统计；
7. 暂时没有错误码封装；
8. 暂时没有统一日志模块。

---

## 18. 后续优化方向

后续可以继续做：

1. 拆分 `RknnDetector` 类；
2. 拆分 `YoloPostProcessor` 类；
3. 支持配置文件指定：
   - 模型路径；
   - label 路径；
   - 输入尺寸；
   - score threshold；
   - nms threshold；
4. 增加推理耗时统计；
5. 增加 batch 或多图测试；
6. 替换为自训练孔探检测模型；
7. 研究不支持算子时的 ONNX 修改和 RKNN 自定义算子注册。

---

## 19. 实验结论

本实验完成了从鲁班猫官方 YOLO11 单图 Demo 到自建工程 `rk3588_ai_stream` 的第一步迁移。

当前已经能够使用自己的命令运行：

~~~bash
./build/image_detect models/yolo11.rknn output/bus.jpg output/result.jpg
~~~

并正常输出：

~~~text
bus
person
person
person
person
~~~

以及检测结果图片：

~~~text
output/result.jpg
~~~

状态：完成。

下一步进入：

~~~text
02_video_detect_migration
~~~

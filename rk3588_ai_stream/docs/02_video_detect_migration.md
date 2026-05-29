# 02 video_detect 视频文件检测迁移记录

## 1. 实验背景

在实验 01 中，已经成功将鲁班猫官方 `yolo11_image_demo` 迁移为当前工程中的：

~~~bash
image_detect
~~~

并且已经完成：

~~~text
单张图片 → RKNN YOLO11 推理 → 后处理 → 画框 → 保存结果图片
~~~

但是真实项目不能只处理单张图片。后续的端侧 AI 视频分析系统需要处理连续视频帧，因此本实验继续迁移鲁班猫官方：

~~~bash
yolo11_videocapture_demo.cc
~~~

目标是实现自己的：

~~~bash
video_detect
~~~

用于完成：

~~~text
视频文件 → 逐帧读取 → RKNN YOLO11 推理 → 画框 → 保存新视频
~~~

---

## 2. 实验目标

本实验目标：

1. 参考鲁班猫官方 `yolo11_videocapture_demo.cc`；
2. 新建自己的 `src/main_video.cpp`；
3. 将输入方式限制为视频文件；
4. 禁用 `imshow` 和 `waitKey`；
5. 使用 `cv::VideoCapture` 读取视频；
6. 使用 `cv::VideoWriter` 保存检测结果视频；
7. 逐帧执行 RKNN YOLO11 推理；
8. 在原始 BGR 帧上绘制检测框和类别；
9. 编译生成 `video_detect`；
10. 运行测试视频 `/home/cat/test.mp4`；
11. 输出 `output/video_result.mp4`；
12. 确认视频文件检测流程跑通。

---

## 3. 参考代码分析

查看官方视频 / 摄像头 Demo：

~~~bash
cd ~/projects/rk3588_ai_stream
sed -n '1,260p' third_party/lubancat_yolo11_ref/yolo11_videocapture_demo.cc
~~~

官方 Demo 主要流程：

~~~text
解析参数
        ↓
cv::VideoCapture 打开摄像头或视频文件
        ↓
init_post_process()
        ↓
init_yolo11_model()
        ↓
while 循环读取 frame
        ↓
cv::cvtColor(frame, image, cv::COLOR_BGR2RGB)
        ↓
构造 image_buffer_t
        ↓
inference_yolo11_model()
        ↓
OpenCV rectangle / putText 画框
        ↓
cv::imshow 显示结果
        ↓
waitKey 等待 ESC 退出
~~~

官方 Demo 支持两种输入：

| 输入形式 | 说明 |
|---|---|
| 数字，例如 `0` | 摄像头 index |
| 视频路径，例如 `/path/xxx.mp4` | 视频文件 |

---

## 4. 为什么本实验先只做视频文件，不做摄像头？

当前项目采用 VSCode Remote SSH 方式远程操作 RK3588。

如果直接使用官方 Demo 中的：

~~~cpp
cv::imshow("yolo11", frame);
cv::waitKey(1);
~~~

在无桌面环境或者远程终端中容易出现问题，例如：

1. 无显示窗口；
2. GUI 后端不可用；
3. 程序卡住；
4. 无法通过 ESC 正常退出；
5. 不利于保存实验结果。

因此本实验先做一个更稳定的版本：

~~~text
读取视频文件
        ↓
处理所有帧
        ↓
保存输出视频
~~~

这样更适合项目沉淀、复现实验和后续写简历。

---

## 5. 当前输入视频

测试视频路径：

~~~bash
/home/cat/test.mp4
~~~

复制到当前工程：

~~~bash
cd ~/projects/rk3588_ai_stream
mkdir -p input
cp /home/cat/test.mp4 input/test.mp4
ls -lh input/test.mp4
~~~

输出：

~~~text
-rw-r--r-- 1 cat cat 5.3M  5月 28 22:39 input/test.mp4
~~~

---

## 6. 创建 `src/main_video.cpp`

最终本实验采用直接覆盖写入的方式生成 `src/main_video.cpp`。

核心设计：

1. 参数格式改为：
   ~~~bash
   ./build/video_detect models/yolo11.rknn input/test.mp4 output/video_result.mp4
   ~~~

2. 只支持视频文件输入；
3. 使用 `cv::VideoCapture` 打开输入视频；
4. 使用 `cv::VideoWriter` 创建输出视频；
5. 每一帧：
   - BGR 转 RGB；
   - 构造 `image_buffer_t`；
   - 调用 `inference_yolo11_model()`；
   - 在 BGR 原图上画框；
   - 写入输出视频；
6. 不使用 `imshow`；
7. 不使用 `waitKey`；
8. 每处理 30 帧打印一次进度；
9. 视频读完后打印总处理帧数。

---

## 7. main_video.cpp 的关键逻辑

### 7.1 参数格式

~~~cpp
if (argc != 4)
{
    printf("Usage: %s <model_path> <input_video> <output_video>\n", argv[0]);
    printf("Example: %s models/yolo11.rknn input/test.mp4 output/video_result.mp4\n", argv[0]);
    return -1;
}

const char *model_path = argv[1];
const char *input_video_path = argv[2];
const char *output_video_path = argv[3];
~~~

当前程序需要三个参数：

| 参数 | 说明 |
|---|---|
| `model_path` | RKNN 模型路径 |
| `input_video_path` | 输入视频路径 |
| `output_video_path` | 输出检测视频路径 |

---

### 7.2 打开输入视频

~~~cpp
cv::VideoCapture cap;
cap.open(input_video_path);

if (!cap.isOpened())
{
    printf("Error: Could not open input video: %s\n", input_video_path);
    return -1;
}
~~~

说明：

这里不再判断摄像头 ID，不再打开摄像头，只打开视频文件。

---

### 7.3 获取视频参数

~~~cpp
int frame_width = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_WIDTH));
int frame_height = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_HEIGHT));
double fps = cap.get(cv::CAP_PROP_FPS);
int total_frames = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_COUNT));

if (fps <= 0.0 || fps > 120.0)
{
    fps = 25.0;
}
~~~

获取视频的：

1. 宽度；
2. 高度；
3. FPS；
4. 总帧数。

如果 FPS 异常，则默认使用 25 FPS。

---

### 7.4 创建输出视频

~~~cpp
cv::VideoWriter writer;
int fourcc = cv::VideoWriter::fourcc('m', 'p', '4', 'v');

writer.open(output_video_path,
            fourcc,
            fps,
            cv::Size(frame_width, frame_height),
            true);

if (!writer.isOpened())
{
    printf("Error: Could not open output video: %s\n", output_video_path);
    return -1;
}
~~~

这里使用 OpenCV `VideoWriter` 保存输出视频。

编码格式使用：

~~~text
mp4v
~~~

输出文件路径由命令行传入，例如：

~~~text
output/video_result.mp4
~~~

---

### 7.5 逐帧读取视频

~~~cpp
while (true)
{
    if (!cap.read(frame))
    {
        printf("cap read frame finished or failed.\n");
        break;
    }

    if (frame.empty())
    {
        printf("empty frame, skip.\n");
        continue;
    }

    ...
}
~~~

当视频读取结束时，`cap.read(frame)` 返回 false，程序退出循环。

---

### 7.6 OpenCV BGR 转 RGB

OpenCV 默认读取的视频帧格式是 BGR。

RKNN YOLO11 推理接口需要 RGB，因此需要转换：

~~~cpp
cv::cvtColor(frame, rgb_image, cv::COLOR_BGR2RGB);
~~~

然后构造 `image_buffer_t`：

~~~cpp
image_buffer_t src_image;
memset(&src_image, 0, sizeof(src_image));

src_image.width = rgb_image.cols;
src_image.height = rgb_image.rows;
src_image.format = IMAGE_FORMAT_RGB888;
src_image.virt_addr = (unsigned char *)rgb_image.data;
src_image.size = rgb_image.total() * rgb_image.elemSize();
~~~

---

### 7.7 RKNN 推理

~~~cpp
object_detect_result_list od_results;
memset(&od_results, 0, sizeof(od_results));

ret = inference_yolo11_model(&rknn_app_ctx, &src_image, &od_results);
if (ret != 0)
{
    printf("inference_yolo11_model fail! ret=%d frame=%d\n", ret, frame_count);
    break;
}
~~~

说明：

视频检测复用了 01 实验中已经验证过的：

1. `init_yolo11_model()`；
2. `inference_yolo11_model()`；
3. `postprocess.cc`；
4. `coco_cls_to_name()`。

---

### 7.8 OpenCV 画框

对每个检测结果：

~~~cpp
cv::rectangle(frame,
              cv::Rect(cv::Point(x1, y1), cv::Point(x2, y2)),
              box_color,
              2);

cv::putText(frame,
            text,
            cv::Point(tx, ty + label_size.height),
            cv::FONT_HERSHEY_SIMPLEX,
            0.5,
            cv::Scalar(255, 255, 255),
            1);
~~~

注意：

这里是在原始 `frame` 上画框，而不是在 RGB 图像上画框。

原因：

1. `frame` 是 OpenCV 读取出来的 BGR 原图；
2. `VideoWriter` 需要写入 BGR 图像；
3. 如果在 RGB 图像上写视频，颜色会异常。

---

### 7.9 写入输出视频

~~~cpp
writer.write(frame);
~~~

每处理完一帧，就写入输出视频。

每 30 帧打印一次进度：

~~~cpp
frame_count++;

if (frame_count % 30 == 0)
{
    printf("processed frames: %d\n", frame_count);
}
~~~

---

## 8. 修改 CMakeLists.txt

在已有 `image_detect` 后追加 `video_detect`：

~~~cmake
add_executable(video_detect
    src/main_video.cpp
    third_party/lubancat_yolo11_ref/postprocess.cc
    ${RKNPU_YOLO11_SRC}
)

target_include_directories(video_detect PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_yolo11_ref
    ${LUBANCAT_YOLO11_CPP}
    ${LIBRKNNRT_INCLUDES}
)

target_link_libraries(video_detect
    imageutils
    fileutils
    ${OpenCV_LIBS}
    ${LIBRKNNRT}
    dl
    pthread
)

set_target_properties(video_detect PROPERTIES
    BUILD_RPATH "$ORIGIN/lib;$ORIGIN/../lib"
)
~~~

说明：

`video_detect` 和 `image_detect` 的主要区别：

| 项目 | image_detect | video_detect |
|---|---|---|
| 输入 | 单张图片 | 视频文件 |
| 画框方式 | `image_drawing` | OpenCV |
| 输出 | 图片 | 视频 |
| 是否需要 OpenCV | 不直接依赖 | 直接依赖 |
| 是否使用 `imshow` | 否 | 否 |
| 是否使用 `VideoWriter` | 否 | 是 |

---

## 9. 编译 video_detect

执行：

~~~bash
cd ~/projects/rk3588_ai_stream
rm -rf build
mkdir build
cd build
cmake ..
make -j4
~~~

预期结果：

~~~text
[100%] Built target image_detect
[100%] Built target video_detect
~~~

---

## 10. 运行 video_detect

执行：

~~~bash
cd ~/projects/rk3588_ai_stream
mkdir -p output

./build/video_detect models/yolo11.rknn input/test.mp4 output/video_result.mp4
~~~

实际运行结果中，程序成功读取并处理视频，最后输出：

~~~text
cap read frame finished or failed.
finished. total processed frames: 596
~~~

说明：

1. 视频文件已经读完；
2. 程序没有中途崩溃；
3. RKNN 推理循环能够连续运行；
4. 逐帧处理逻辑正常；
5. 共处理 596 帧。

---

## 11. 输出文件检查

运行后检查输出视频：

~~~bash
ls -lh output/video_result.mp4
file output/video_result.mp4
~~~

输出文件：

~~~text
output/video_result.mp4
~~~

该文件为检测后的视频结果。

---

## 12. 当前看到的大量 RGA 日志说明

运行时可能会看到类似：

~~~text
rga_dump_channel_info
rga_dump_opt
rga_task_submit
~~~

说明当前推理链路内部调用了 RGA 图像处理。

这些日志较多，但当前不影响程序运行。

当前阶段先不处理 RGA 日志问题，原因：

1. 当前主要目标是跑通视频检测流程；
2. RGA 日志虽然多，但程序已成功处理完整视频；
3. 后续做性能优化时再研究关闭日志或调整日志等级。

---

## 13. 当前 video_detect 工作流程

整体流程：

~~~text
解析命令行参数
        ↓
打开输入视频
        ↓
读取视频宽、高、FPS、总帧数
        ↓
创建 VideoWriter
        ↓
init_post_process()
        ↓
init_yolo11_model()
        ↓
while 循环读取视频帧
        ↓
BGR 转 RGB
        ↓
构造 image_buffer_t
        ↓
inference_yolo11_model()
        ↓
遍历检测结果
        ↓
OpenCV 画框和类别
        ↓
writer.write(frame)
        ↓
读取下一帧
        ↓
视频结束后释放资源
~~~

---

## 14. 当前确认可用能力

本实验完成后，当前工程已经具备：

1. 视频文件输入能力；
2. OpenCV 逐帧读取能力；
3. BGR → RGB 转换能力；
4. RKNN YOLO11 连续帧推理能力；
5. YOLO11 后处理复用能力；
6. OpenCV 画框和文字绘制能力；
7. VideoWriter 输出视频能力；
8. 完整处理 596 帧视频的能力。

---

## 15. 与 image_detect 的关系

`image_detect` 解决的是：

~~~text
单张图片检测
~~~

`video_detect` 解决的是：

~~~text
连续视频帧检测
~~~

两者共同复用：

1. `models/yolo11.rknn`
2. `postprocess.cc`
3. `postprocess.h`
4. `yolo11.h`
5. `rknpu2/yolo11.cc`
6. RKNN Runtime
7. YOLO11 后处理逻辑

区别在于：

| 模块 | image_detect | video_detect |
|---|---|---|
| 输入 | 图片 | 视频 |
| 输出 | 图片 | 视频 |
| 读取方式 | `read_image()` | `cv::VideoCapture` |
| 画框方式 | `draw_rectangle()` / `draw_text()` | `cv::rectangle()` / `cv::putText()` |
| 保存方式 | `write_image()` | `cv::VideoWriter` |

---

## 16. 当前不足

当前 `video_detect` 仍然是基础版本，还存在不足：

1. 没有统计单帧耗时；
2. 没有统计平均 FPS；
3. 没有区分预处理、推理、后处理、写视频耗时；
4. 没有使用多线程流水线；
5. 没有使用摄像头实时输入；
6. 没有接入 RGA 独立预处理优化；
7. 没有接入 MPP 硬件编码；
8. 没有接入 RTSP 推流；
9. 输出视频使用 OpenCV `mp4v`，不是 RK3588 MPP 硬编码；
10. 还没有适配自训练孔探检测模型。

---

## 17. 后续优化方向

后续可以继续做：

1. 增加耗时统计：
   - 读取帧耗时；
   - BGR→RGB 耗时；
   - RKNN 推理耗时；
   - 后处理耗时；
   - 写视频耗时；
2. 增加平均 FPS 输出；
3. 增加摄像头输入版本 `camera_detect`；
4. 支持 `/dev/video11` 等真实设备；
5. 将 OpenCV 预处理替换为 RGA 预处理；
6. 将 OpenCV VideoWriter 替换为 MPP 硬编码；
7. 接入 RTSP 推流；
8. 增加多线程流水线：
   - 读取线程；
   - 推理线程；
   - 编码线程；
9. 后续接入切片推理，用于孔探高分辨率小目标缺陷检测。

---

## 18. 实验结论

本实验成功完成了从官方 `yolo11_videocapture_demo` 到自建工程 `video_detect` 的迁移。

当前可运行命令：

~~~bash
cd ~/projects/rk3588_ai_stream
./build/video_detect models/yolo11.rknn input/test.mp4 output/video_result.mp4
~~~

实际处理结果：

~~~text
finished. total processed frames: 596
~~~

输出结果：

~~~text
output/video_result.mp4
~~~

状态：完成。

下一步建议进入：

~~~text
03_camera_detect_migration
~~~

即摄像头实时检测版本。

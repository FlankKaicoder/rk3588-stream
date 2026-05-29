# 07 inference_yolo11_model 内部性能剖析与实时优化实验总结

## 1. 实验背景

前面已经完成了 05 和 06 两个关键实验。

05 实验完成了：

```text
V4L2 mmap 原生采集 NV12
        ↓
RGA NV12 → RGB888
        ↓
统计实时预处理性能
```

05 实验最终结果：

```text
========== 05 final ==========
frames       : 120
wall_time_ms : 4052.589
wall_fps     : 29.611
avg_select_ms: 28.360
avg_dqbuf_ms : 0.020
avg_rga_ms   : 5.124
avg_qbuf_ms  : 0.157
avg_total_ms : 33.670
```

05 证明：

```text
V4L2 mmap + RGA NV12→RGB888 预处理链路可以接近 30FPS。
输入链路本身已经不是瓶颈。
```

06 实验在 05 基础上接入 RKNN YOLO11 推理：

```text
V4L2 mmap 采集 NV12
        ↓
RGA NV12 → RGB888
        ↓
构造 image_buffer_t
        ↓
inference_yolo11_model()
        ↓
画框
        ↓
保存快照 / 统计性能
```

06 初始 nosnap 结果：

```text
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
```

06 初始结论：

```text
完整检测链路只有约 18.7FPS；
V4L2 采集、DQBUF/QBUF、外部 RGA、画框、快照保存都不是主要瓶颈；
主要瓶颈集中在 inference_yolo11_model()，平均耗时约 48.5ms。
```

因此 07 实验的目标不是继续盲目做三线程，而是先把：

```cpp
inference_yolo11_model()
```

内部拆开，确认它到底慢在哪里。

---

## 2. 07 实验目标

07 实验的核心目标：

```text
把 06 中约 48.5ms 的 inference_yolo11_model() 黑盒拆开。
```

需要拆解的阶段包括：

```text
1. convert_image_with_letterbox
   内部 resize / letterbox / 图像预处理

2. rknn_inputs_set
   设置 RKNN 输入

3. rknn_run
   NPU 真正执行模型

4. rknn_outputs_get
   获取 RKNN 输出 tensor

5. post_process
   YOLO11 后处理，包括输出解码、排序、NMS、结果打包

6. rknn_outputs_release
   释放输出 tensor
```

07 后续又继续细分：

```text
07-1：拆 post_process 内部 decode / sort / nms / pack
07-2：按输出分支拆 decode，分析 80x80 / 40x40 / 20x20 哪个最慢
07-3：统计 process_i8_nchw 内部扫描次数
07-4：验证 -O3 编译优化影响
07-5：验证 CPU performance governor 影响
07-6：在 Release + O3 + performance 下重测干净 06 完整链路 FPS
```

---

## 3. 本实验涉及的主要文件

### 3.1 原始推理文件

官方 YOLO11 RKNN 推理文件：

```text
~/lubancat_ai_manual_code/example/yolo11/cpp/rknpu2/yolo11.cc
```

07 中不直接修改官方文件，而是复制一份：

```bash
cp ~/lubancat_ai_manual_code/example/yolo11/cpp/rknpu2/yolo11.cc src/yolo11_profile.cc
```

用于插入 profiling 计时。

---

### 3.2 后处理文件

原始后处理文件：

```text
third_party/lubancat_yolo11_ref/postprocess.cc
```

07 中复制一份：

```bash
cp third_party/lubancat_yolo11_ref/postprocess.cc src/postprocess_profile.cc
```

用于插入 post_process 内部 profiling。

---

### 3.3 07 profile 编译目标

CMake 中新增目标：

```text
v4l2_rga_rknn_detect_profile
```

使用：

```text
src/main_v4l2_rga_rknn_detect.cpp
src/yolo11_profile.cc
src/postprocess_profile.cc
```

而不是直接使用原始官方 `yolo11.cc` 和 `postprocess.cc`。

---

## 4. 07-0：给 inference_yolo11_model 加内部计时

### 4.1 关键调用位置

首先检查 `src/yolo11_profile.cc` 中关键调用：

```bash
cd ~/projects/rk3588_ai_stream

grep -n "inference_yolo11_model\|convert_image_with_letterbox\|rknn_inputs_set\|rknn_run\|rknn_outputs_get\|post_process\|rknn_outputs_release" src/yolo11_profile.cc
```

实际结果：

```text
160:int inference_yolo11_model(rknn_app_context_t *app_ctx, image_buffer_t *img, object_detect_result_list *od_results)
207:    ret = convert_image_with_letterbox(img, &dst_img, &letter_box, bg_color);
221:    ret = rknn_inputs_set(app_ctx->rknn_ctx, app_ctx->io_num.n_input, inputs);
229:    printf("rknn_run\n");
230:    ret = rknn_run(app_ctx->rknn_ctx, nullptr);
244:    ret = rknn_outputs_get(app_ctx->rknn_ctx, app_ctx->io_num.n_output, outputs, NULL);
252:    post_process(app_ctx, outputs, &letter_box, box_conf_threshold, nms_threshold, od_results);
255:    rknn_outputs_release(app_ctx->rknn_ctx, app_ctx->io_num.n_output, outputs);
```

说明 `inference_yolo11_model()` 的内部结构清晰，可以在这些关键调用前后插入计时。

---

### 4.2 初次自动插入计时遇到的问题

初次自动插入时，在函数中间插入了类似：

```cpp
auto yolo11_prof_postprocess_start = std::chrono::steady_clock::now();
...
auto yolo11_prof_postprocess_end = std::chrono::steady_clock::now();
```

编译时报错：

```text
error: jump to label ‘out’
note: crosses initialization of ‘std::chrono::time_point ...’
```

原因：

```text
原始 yolo11.cc 中使用了 goto out;
C++ 不允许 goto 跳过局部对象初始化。
```

也就是说，如果在 `goto out` 之前的某些位置声明了新的 `auto time_point` 对象，而 `goto out` 可能跳过这些声明，就会触发 C++ 编译错误。

---

### 4.3 安全修复方式

最终采用的安全方式：

```text
在 inference_yolo11_model() 函数开头统一声明所有 time_point 变量；
后续只做赋值，不再在中途声明新的 auto 局部对象。
```

核心思想：

```cpp
auto yolo11_prof_func_start = std::chrono::steady_clock::now();

std::chrono::steady_clock::time_point yolo11_prof_stage_start;
std::chrono::steady_clock::time_point yolo11_prof_stage_end;

double yolo11_prof_preprocess_ms = 0.0;
double yolo11_prof_inputs_set_ms = 0.0;
double yolo11_prof_rknn_run_ms = 0.0;
double yolo11_prof_outputs_get_ms = 0.0;
double yolo11_prof_postprocess_ms = 0.0;
double yolo11_prof_outputs_release_ms = 0.0;
```

然后每个阶段只写：

```cpp
yolo11_prof_stage_start = std::chrono::steady_clock::now();

ret = rknn_run(app_ctx->rknn_ctx, nullptr);

yolo11_prof_stage_end = std::chrono::steady_clock::now();
yolo11_prof_rknn_run_ms += yolo11_profile_diff_ms(yolo11_prof_stage_start, yolo11_prof_stage_end);
```

这样不会产生 `goto out` 跨越局部对象初始化的问题。

---

### 4.4 插入后的输出格式

每一帧会输出：

```text
[YOLO11_PROFILE] preprocess=... inputs_set=... rknn_run=... outputs_get=... postprocess=... outputs_release=... total=...
```

含义：

| 字段 | 含义 |
|---|---|
| `preprocess` | `convert_image_with_letterbox()` 耗时 |
| `inputs_set` | `rknn_inputs_set()` 耗时 |
| `rknn_run` | `rknn_run()` 耗时 |
| `outputs_get` | `rknn_outputs_get()` 耗时 |
| `postprocess` | `post_process()` 耗时 |
| `outputs_release` | `rknn_outputs_release()` 耗时 |
| `total` | `inference_yolo11_model()` 总耗时 |

---

## 5. 07-1：inference_yolo11_model 初始内部拆解结果

运行 30 帧后，统计 `[YOLO11_PROFILE]` 平均值。

初始结果：

```text
========== 07 model internal profile avg ==========
frames: 30
preprocess      : 5.629 ms
inputs_set      : 0.572 ms
rknn_run        : 22.699 ms
outputs_get     : 2.763 ms
postprocess     : 14.992 ms
outputs_release : 0.009 ms
total           : 46.681 ms
--------------------------------------------------
preprocess      : 12.1%
inputs_set      : 1.2%
rknn_run        : 48.6%
outputs_get     : 5.9%
postprocess     : 32.1%
outputs_release : 0.0%
==================================================
```

---

### 5.1 初始结论

一开始我们只能从 06 得到：

```text
inference_yolo11_model() 约 48.5ms，是主要瓶颈。
```

07-1 拆开后发现：

```text
rknn_run        : 22.699ms，占 48.6%
post_process    : 14.992ms，占 32.1%
preprocess      : 5.629ms，占 12.1%
outputs_get     : 2.763ms，占 5.9%
```

说明：

```text
瓶颈不是只有 rknn_run。
YOLO11 后处理 post_process 也非常重。
```

当时的瓶颈排序是：

```text
第一：rknn_run，约 22.7ms
第二：post_process，约 15.0ms
第三：convert_image_with_letterbox，约 5.6ms
第四：rknn_outputs_get，约 2.8ms
```

---

## 6. 07-1 扩展：拆 post_process 内部

由于 `post_process()` 初始耗时约 15ms，占比约 32.1%，因此继续拆后处理内部。

拆分为：

```text
decode：多尺度输出解码 / proposal 生成
sort：候选框排序
nms：非极大值抑制
pack：结果打包到 od_results
```

输出格式：

```text
[POST_PROFILE] decode=... sort=... nms=... pack=... total=... validCount=... resultCount=...
```

---

### 6.1 单帧样例

某一帧结果：

```text
[POST_PROFILE] decode=17.863 sort=0.003 nms=0.007 pack=0.002 total=17.934 validCount=10 resultCount=1
```

说明：

```text
decode 占 post_process：
17.863 / 17.934 ≈ 99.6%
```

该帧中，sort、NMS、pack 几乎不耗时。

---

### 6.2 30 帧平均结果

```text
========== 07-1 post_process profile avg ==========
frames: 30
decode      : 15.164 ms
sort        : 0.003 ms
nms         : 0.010 ms
pack        : 0.002 ms
total       : 15.234 ms
validCount  : 11.37
resultCount : 1.70
---------------------------------------------------
decode      : 99.5%
sort        : 0.0%
nms         : 0.1%
pack        : 0.0%
===================================================
```

---

### 6.3 07-1 后处理结论

该结果说明：

```text
post_process 慢，不是因为 NMS；
post_process 慢，不是因为 sort；
post_process 慢，也不是因为结果打包；
post_process 几乎全部耗时都在 decode / proposal 生成阶段。
```

这里有一个关键现象：

```text
validCount 平均只有 11.37；
resultCount 平均只有 1.70；
NMS 只处理少量候选框，所以 NMS 几乎不耗时。
```

但是 decode 仍然要：

```text
遍历模型所有输出网格；
扫描类别分数；
执行阈值筛选；
必要时执行 DFL 解码；
生成候选框。
```

因此即使最后有效候选框很少，decode 仍然可能很慢。

---

## 7. 07-2：按输出分支拆 decode 耗时

接着继续拆 decode：

```text
80x80 分支
40x40 分支
20x20 分支
```

输出格式：

```text
[POST_BRANCH] h=80 w=80 spatial=6400 stride=8 dfl=16 decode=... validAdd=... validTotal=...
```

---

### 7.1 07-2 统计结果

```text
========== 07-2 branch decode profile avg ==========
h=80  w=80  stride=8  dfl=16 spatial=6400  avg_decode=  11.289 ms  avg_validAdd=  0.00  samples=30
h=40  w=40  stride=16 dfl=16 spatial=1600  avg_decode=   3.526 ms  avg_validAdd=  0.00  samples=30
h=20  w=20  stride=32 dfl=16 spatial=400   avg_decode=   0.019 ms  avg_validAdd=  0.10  samples=30
----------------------------------------------------
sum_branch_decode: 14.834 ms
sum_branch_valid : 0.10
----------------------------------------------------
h=80  w=80  stride=8 :  76.1%
h=40  w=40  stride=16:  23.8%
h=20  w=20  stride=32:   0.1%
====================================================
```

---

### 7.2 07-2 结论

该结果说明：

```text
80x80 高分辨率分支是 decode 的主要耗时来源，占 76.1%；
40x40 分支占 23.8%；
20x20 分支几乎不耗时。
```

更关键的是：

```text
80x80 和 40x40 平均 validAdd 都是 0；
也就是说它们没有产生有效候选框，但仍然消耗了几乎所有 decode 时间。
```

因此问题变成：

```text
为什么 80x80 / 40x40 没有有效框，却仍然很慢？
```

---

## 8. 07-3：统计 process_i8_nchw 内部扫描次数

继续在 `process_i8_nchw()` 中加入计数，不在每个网格点里加 `chrono`，避免严重扰动性能。

统计字段：

```text
grid：当前分支总网格数
sumReject：被 sum/objectness 分支提前过滤的网格数
sumPass：通过 sum/objectness 预筛的网格数
classScan：进入类别扫描的网格数
classOps：类别扫描访问次数，约等于 classScan * OBJ_CLASS_NUM
scoreHit：类别分数超过阈值的网格数
dflCount：进入 DFL 解码的数量
valid：当前分支最终有效候选框数量
```

输出格式：

```text
[PROCESS_I8] h=80 w=80 stride=8 dfl=16 grid=6400 sumReject=... sumPass=... classScan=... classOps=... scoreHit=... dfl=... valid=... threshold=...
```

---

### 8.1 07-3 统计结果

```text
========== 07-3 process_i8 scan profile avg ==========
h=80  w=80  stride=8  grid=6400 
  sumReject :     0.00 (  0.0%)
  sumPass   :  6400.00 (100.0%)
  classScan :  6400.00
  classOps  : 512000.00
  scoreHit  :     0.00
  dflCount  :     0.00
  valid     :     0.00

h=40  w=40  stride=16 grid=1600 
  sumReject :     0.00 (  0.0%)
  sumPass   :  1600.00 (100.0%)
  classScan :  1600.00
  classOps  : 128000.00
  scoreHit  :     0.00
  dflCount  :     0.00
  valid     :     0.00

h=20  w=20  stride=32 grid=400  
  sumReject :   399.57 ( 99.9%)
  sumPass   :     0.43 (  0.1%)
  classScan :     0.43
  classOps  :    34.67
  scoreHit  :     0.07
  dflCount  :     0.07
  valid     :     0.07
======================================================
```

---

### 8.2 07-3 关键结论

这是整个 07 实验中非常关键的数据。

对于 80x80 分支：

```text
grid = 6400
sumPass = 6400
classScan = 6400
classOps = 512000
valid = 0
```

说明：

```text
80x80 分支每一帧固定扫描 6400 个网格；
每个网格扫描 80 个 COCO 类别；
总共做 512000 次类别访问；
但最终没有产生任何有效候选框。
```

对于 40x40 分支：

```text
grid = 1600
sumPass = 1600
classScan = 1600
classOps = 128000
valid = 0
```

说明：

```text
40x40 分支每一帧也固定扫描 1600 个网格；
每个网格扫描 80 类；
总共做 128000 次类别访问；
但最终也没有有效框。
```

因此当前 decode 慢的直接原因是：

```text
80x80 和 40x40 分支没有被 sum/objectness 提前过滤；
即使最终没有有效框，也要完整执行大量类别扫描。
```

总的类别访问量：

```text
80x80：6400 * 80 = 512000
40x40：1600 * 80 = 128000
合计：640000 次类别访问
```

而这些访问基本没有贡献有效检测结果。

---

## 9. 关于 Gemini 建议的验证

当时将 07-1、07-2、07-3 的数据给 Gemini 询问，它提出三个可能原因：

```text
1. CPU 频率调度问题；
2. 编译没有开启 -O3；
3. NCHW 访存导致 cache miss。
```

这三个方向有参考价值，但不能盲目接受，需要逐一验证。

---

## 10. 07-4：检查当前编译是否开启 O3

首先检查 CMakeLists：

```bash
cd ~/projects/rk3588_ai_stream

grep -n "CMAKE_BUILD_TYPE\|CMAKE_CXX_FLAGS\|CMAKE_C_FLAGS\|CMAKE_CXX_STANDARD" CMakeLists.txt
```

结果：

```text
5:set(CMAKE_CXX_STANDARD 17)
6:set(CMAKE_CXX_STANDARD_REQUIRED ON)
```

说明：

```text
CMakeLists 中只设置了 C++17；
没有设置 CMAKE_BUILD_TYPE；
没有设置 CMAKE_CXX_FLAGS；
没有设置 CMAKE_C_FLAGS；
没有显式设置 -O2 / -O3。
```

然后用 verbose 编译检查：

```bash
cd ~/projects/rk3588_ai_stream/build

make VERBOSE=1 v4l2_rga_rknn_detect_profile -j1 2>&1 | tee ../output/exp07_build_verbose.log

cd ~/projects/rk3588_ai_stream
grep -- "-O" output/exp07_build_verbose.log | head -20
```

结果：

```text
无输出
```

说明：

```text
当前编译日志中没有看到 -O2 / -O3。
```

因此 Gemini 提到的“可能没有开 O3”被证实是一个真实问题。

---

## 11. 07-4：为 07 target 添加 -O3 -DNDEBUG

为 07 profile target 单独添加：

```cmake
target_compile_options(v4l2_rga_rknn_detect_profile PRIVATE
    -O3
    -DNDEBUG
)
```

重新编译：

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release
make v4l2_rga_rknn_detect_profile -j4
```

然后重新跑 30 帧 profile。

---

### 11.1 O3 后 YOLO11_PROFILE 平均结果

```text
========== O3 YOLO11_PROFILE avg ==========
frames: 30
preprocess      : 4.855 ms
inputs_set      : 0.590 ms
rknn_run        : 21.287 ms
outputs_get     : 2.811 ms
postprocess     : 6.650 ms
outputs_release : 0.009 ms
total           : 36.212 ms
```

---

### 11.2 O3 后 POST_PROFILE 平均结果

```text
========== O3 POST_PROFILE avg ==========
frames: 30
decode      : 6.613 ms
sort        : 0.000 ms
nms         : 0.000 ms
pack        : 0.000 ms
total       : 6.638 ms
validCount  : 0.03
resultCount : 0.03
```

---

### 11.3 O3 后 POST_BRANCH 平均结果

```text
========== O3 POST_BRANCH avg ==========
h=20 w=20 stride=32 : 0.038 ms, samples=30
h=40 w=40 stride=16 : 1.125 ms, samples=30
h=80 w=80 stride=8  : 5.450 ms, samples=30
```

---

### 11.4 O3 前后对比

| 指标 | O3 前 | O3 后 | 变化 |
|---|---:|---:|---:|
| `inference_yolo11_model total` | 46.681 ms | 36.212 ms | -10.469 ms |
| `postprocess` | 14.992 ms | 6.650 ms | -8.342 ms |
| `decode` | 15.164 ms | 6.613 ms | -8.551 ms |
| `80x80 decode` | 11.289 ms | 5.450 ms | -5.839 ms |
| `40x40 decode` | 3.526 ms | 1.125 ms | -2.401 ms |
| `rknn_run` | 22.699 ms | 21.287 ms | -1.412 ms |

---

### 11.5 O3 结论

O3 的作用非常明显：

```text
post_process 从约 15ms 降到约 6.65ms；
decode 从约 15.16ms 降到约 6.61ms；
inference_yolo11_model 总耗时从约 46.68ms 降到约 36.21ms。
```

说明：

```text
之前 15ms 后处理明显包含了“未开启编译优化”的影响。
```

因此：

```text
Gemini 关于 -O3 的判断被实验验证。
```

---

## 12. 07-5：验证 CPU performance governor

O3 后，继续验证 CPU 频率调度是否影响性能。

设置 CPU governor：

```bash
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee $gov
done
```

确认：

```bash
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

如果全部显示：

```text
performance
performance
performance
...
```

说明设置成功。

---

### 12.1 O3 + performance 后 YOLO11_PROFILE 平均结果

```text
========== O3 + performance YOLO11_PROFILE avg ==========
frames: 30
preprocess      : 3.789 ms
inputs_set      : 0.407 ms
rknn_run        : 19.204 ms
outputs_get     : 1.539 ms
postprocess     : 4.085 ms
outputs_release : 0.005 ms
total           : 29.034 ms
```

---

### 12.2 O3 + performance 后 POST_PROFILE 平均结果

```text
========== O3 + performance POST_PROFILE avg ==========
frames: 30
decode      : 4.047 ms
sort        : 0.000 ms
nms         : 0.000 ms
pack        : 0.000 ms
total       : 4.071 ms
validCount  : 0.03
resultCount : 0.03
```

---

### 12.3 O3 + performance 后 POST_BRANCH 平均结果

```text
========== O3 + performance POST_BRANCH avg ==========
h=20 w=20 stride=32 : 0.029 ms, samples=30
h=40 w=40 stride=16 : 0.693 ms, samples=30
h=80 w=80 stride=8  : 3.325 ms, samples=30
```

---

### 12.4 O3 与 O3 + performance 对比

| 指标 | O3 | O3 + performance | 变化 |
|---|---:|---:|---:|
| `preprocess` | 4.855 ms | 3.789 ms | -1.066 ms |
| `inputs_set` | 0.590 ms | 0.407 ms | -0.183 ms |
| `rknn_run` | 21.287 ms | 19.204 ms | -2.083 ms |
| `outputs_get` | 2.811 ms | 1.539 ms | -1.272 ms |
| `postprocess` | 6.650 ms | 4.085 ms | -2.565 ms |
| `total` | 36.212 ms | 29.034 ms | -7.178 ms |

---

### 12.5 performance governor 结论

CPU performance governor 同样影响很大：

```text
inference_yolo11_model 从 36.212ms 降到 29.034ms；
post_process 从 6.650ms 降到 4.085ms；
decode 从 6.613ms 降到 4.047ms；
outputs_get 从 2.811ms 降到 1.539ms；
rknn_run 从 21.287ms 降到 19.204ms。
```

说明：

```text
CPU governor 不只影响纯 CPU 后处理；
也可能影响 RKNN runtime 调用开销、输出同步、内存访问和调度。
```

因此：

```text
Gemini 关于 CPU 频率调度的判断也被实验验证。
```

---

## 13. 三阶段优化总对比

完整对比：

| 阶段 | 未开 O3 | O3 | O3 + performance |
|---|---:|---:|---:|
| `preprocess` | 5.629 ms | 4.855 ms | 3.789 ms |
| `inputs_set` | 0.572 ms | 0.590 ms | 0.407 ms |
| `rknn_run` | 22.699 ms | 21.287 ms | 19.204 ms |
| `outputs_get` | 2.763 ms | 2.811 ms | 1.539 ms |
| `postprocess` | 14.992 ms | 6.650 ms | 4.085 ms |
| `total` | 46.681 ms | 36.212 ms | 29.034 ms |

可以看到：

```text
未开 O3 时，postprocess 非常重，约 15ms；
开启 O3 后，postprocess 降到约 6.65ms；
再设置 performance governor 后，postprocess 降到约 4.09ms；
最终 inference_yolo11_model 总耗时降到约 29.03ms。
```

---

## 14. O3 + performance 后瓶颈重新排序

最终 `inference_yolo11_model()` 内部耗时排序：

```text
第一：rknn_run        19.204ms
第二：postprocess      4.085ms
第三：preprocess       3.789ms
第四：outputs_get      1.539ms
第五：inputs_set       0.407ms
第六：outputs_release  0.005ms
```

当前真正的大头重新变成：

```text
rknn_run
```

后处理已经从最初的异常高值降低到较合理区间。

---

## 15. 07-6：在 Release + O3 + performance 下重测干净 06

前面的 profile 版本有大量打印：

```text
[PROCESS_I8]
[POST_BRANCH]
[POST_PROFILE]
[YOLO11_PROFILE]
```

这些日志会带来额外开销。

因此最后重新编译正式 06 target：

```text
v4l2_rga_rknn_detect
```

并给它也添加：

```cmake
target_compile_options(v4l2_rga_rknn_detect PRIVATE
    -O3
    -DNDEBUG
)
```

重新编译正式版本：

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release
make v4l2_rga_rknn_detect -j4
```

确保 CPU governor 为：

```text
performance
```

运行干净 06：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp07_clean06_release_perf

export RGA_LOG_LEVEL=0
export RGA_DEBUG=0

./build/v4l2_rga_rknn_detect \
  models/yolo11.rknn \
  /dev/video11 \
  1280 \
  720 \
  120 \
  output/exp07_clean06_release_perf/profile_clean06_release_perf.csv \
  output/exp07_clean06_release_perf \
  999999 | tee output/exp07_clean06_release_perf/run_120.log
```

---

### 15.1 干净 06 最终结果

```text
========== 06 avg ==========
frames          : 120
select_ms       : 1.559
dqbuf_ms        : 0.005
rga_ms          : 2.379
input_prepare_ms: 0.000
model_total_ms  : 28.638
draw_ms         : 0.770
snapshot_ms     : 0.194
qbuf_ms         : 0.076
total_ms        : 33.624
avg_fps         : 29.741
============================

========== 06 final ==========
frames       : 120
wall_time_ms : 4039.317
wall_fps     : 29.708
avg_select_ms       : 1.559
avg_dqbuf_ms        : 0.005
avg_rga_ms          : 2.379
avg_input_prepare_ms: 0.000
avg_model_total_ms  : 28.638
avg_draw_ms         : 0.770
avg_snapshot_ms     : 0.194
avg_qbuf_ms         : 0.076
avg_total_ms        : 33.624
csv saved: output/exp07_clean06_release_perf/profile_clean06_release_perf.csv
================================
```

---

## 16. 最终优化前后对比

优化前 06-nosnap：

```text
wall_fps          : 18.703
avg_model_total_ms: 48.480
avg_total_ms      : 53.412
```

优化后 Release + O3 + performance：

```text
wall_fps          : 29.708
avg_model_total_ms: 28.638
avg_total_ms      : 33.624
```

对比表：

| 指标 | 优化前 | 优化后 | 变化 |
|---|---:|---:|---:|
| `wall_fps` | 18.703 FPS | 29.708 FPS | +11.005 FPS |
| `avg_model_total_ms` | 48.480 ms | 28.638 ms | -19.842 ms |
| `avg_total_ms` | 53.412 ms | 33.624 ms | -19.788 ms |

最终效果：

```text
完整 V4L2 + RGA + RKNN 检测链路从约 18.7FPS 提升到约 29.7FPS。
```

---

## 17. 30FPS 为什么基本到顶？

摄像头 30FPS 的理论帧周期：

```text
1000 / 30 = 33.333ms
```

最终干净版 06：

```text
avg_total_ms = 33.624ms
wall_fps     = 29.708FPS
```

两者几乎一致。

这说明：

```text
程序处理速度已经接近摄像头 30FPS 上限。
```

此时 `select_ms` 为：

```text
avg_select_ms = 1.559ms
```

说明：

```text
程序处理速度已经几乎追上摄像头出帧速度；
有时需要稍微等待下一帧。
```

和 05 纯 V4L2 + RGA 的情况不同：

```text
05 中处理很快，大部分时间在 select 等帧；
07 最终版本中，模型推理和后处理已经占满了大部分帧周期。
```

---

## 18. 对 Gemini 分析的最终评价

Gemini 的建议有参考价值，其中两个关键判断被实验验证：

```text
1. 未开启 O3 会显著拖慢后处理；
2. CPU governor 会影响 RK3588 上 CPU 后处理和 RKNN runtime 调用耗时。
```

但是它的一些说法需要谨慎：

```text
“优化良好 YOLO 后处理通常只需要 2~5ms”
```

这个只能作为经验目标，不能作为绝对标准。

因为后处理耗时取决于：

```text
模型输出格式；
是否 DFL；
类别数；
输出 tensor layout；
是否 int8；
是否开启 O3；
CPU governor；
是否做 topK；
是否使用 NEON；
是否使用 NHWC 连续访存；
是否是 COCO 80 类还是自定义少类别模型。
```

在当前实验中：

```text
COCO 80 类 + DFL + NCHW score scan + 未开 O3
```

会导致后处理非常慢。

但在：

```text
Release + O3 + CPU performance
```

后，后处理降到约 4ms，已经比较合理。

---

## 19. 关于 NCHW cache miss 的判断

当前后处理中类别分数读取类似：

```cpp
score_tensor[c * grid_len + offset]
```

这是 NCHW 格式。

对于 80x80 分支：

```text
grid_len = 6400
```

当类别 `c` 从 0 到 79 变化时，访问地址每次跳 6400 个 int8 元素，不是连续内存访问。

这确实可能导致：

```text
cache miss；
访存不连续；
CPU 读取效率下降。
```

所以 NCHW 访存问题仍然存在。

但是经过 O3 + performance 后：

```text
decode 已经从 15.164ms 降到 4.047ms。
```

因此 NCHW layout 优化不再是当前第一优先级。

后续如果继续极致优化，可以考虑：

```text
1. 修改后处理循环顺序；
2. 尝试 NHWC 输出；
3. 对 class score 访问做连续化；
4. 使用 topK / 预筛减少类别扫描；
5. 使用 NEON 优化 score scan。
```

---

## 20. 对后续自训练缺陷模型的启发

当前测试使用的是 COCO 80 类 YOLO11 模型，因此每个网格点需要扫描 80 个类别。

80x80 分支类别扫描量：

```text
COCO 80 类：
6400 * 80 = 512000 次类别访问
```

如果后续部署自己的孔探缺陷模型：

```text
1 类 defect
或 4 类缺陷
```

则类别扫描量会变成：

```text
1 类：
6400 * 1 = 6400 次类别访问

4 类：
6400 * 4 = 25600 次类别访问
```

相比 COCO 80 类：

```text
单类模型理论上类别扫描量下降 80 倍；
四类模型理论上类别扫描量下降 20 倍。
```

因此当前 COCO 80 类后处理耗时不能完全等价于后续孔探缺陷模型。

这个结论很重要：

```text
后续部署自训练少类别缺陷检测模型时，后处理 CPU 压力预计会显著下降。
```

---

## 21. 07 实验最终结论

07 实验完整结论：

```text
1. 初始 06 实验中，V4L2 + RGA + RKNN 完整检测链路只有约 18.7FPS；
2. 主要瓶颈集中在 inference_yolo11_model()，平均约 48.5ms；
3. 07-1 拆解 inference_yolo11_model 后发现：
   rknn_run 约 22.7ms；
   post_process 约 15.0ms；
   内部 preprocess 约 5.6ms；
4. 继续拆 post_process 后发现：
   99%以上耗时集中在 decode/proposal 生成阶段；
   sort、NMS、pack 几乎不耗时；
5. 按输出分支拆 decode 后发现：
   80x80 分支占 decode 约 76%；
   40x40 分支占约 24%；
   20x20 几乎不耗时；
6. 统计 process_i8_nchw 内部扫描后发现：
   80x80 和 40x40 分支没有产生有效候选框，
   但仍然分别做了 512000 和 128000 次类别扫描；
7. 检查 CMake 后发现：
   工程没有显式设置 CMAKE_BUILD_TYPE / CMAKE_CXX_FLAGS / CMAKE_C_FLAGS；
   verbose 编译日志中没有看到 -O2 / -O3；
8. 给 profile target 加入 -O3 -DNDEBUG 后：
   post_process 从约 15.0ms 降到约 6.65ms；
   inference_yolo11_model 从约 46.68ms 降到约 36.21ms；
9. 设置 CPU governor 为 performance 后：
   post_process 进一步降到约 4.09ms；
   inference_yolo11_model 进一步降到约 29.03ms；
10. 最后在正式干净 06 target 上使用 Release + O3 + performance，
    完整 V4L2 + RGA + RKNN 检测链路达到 29.708FPS；
11. 项目从最初 OpenCV 摄像头链路约 5FPS，
    逐步优化到 V4L2 + RGA + RKNN 接近 30FPS。
```

---

## 22. 07 实验的工程价值

07 实验不是简单调参，而是一个完整的工程性能优化闭环：

```text
1. 发现问题：
   06 完整链路只有 18.7FPS；

2. 定位黑盒：
   inference_yolo11_model() 约 48.5ms；

3. 拆解内部：
   rknn_run 和 post_process 是主要耗时；

4. 继续拆后处理：
   post_process 慢在 decode，不是 NMS；

5. 继续拆 decode：
   80x80 / 40x40 高分辨率分支是主要耗时来源；

6. 继续拆扫描逻辑：
   高分辨率分支大量无效类别扫描；

7. 验证系统配置：
   发现没有开启 -O3；

8. 验证 CPU 调度：
   performance governor 明显改善性能；

9. 回到干净正式程序：
   Release + O3 + performance 后完整链路达到 29.7FPS。
```

这条链路非常适合写进简历和项目文档：

```text
通过逐阶段性能剖析定位端侧 AI 推理瓶颈，
将 RK3588 上 V4L2 + RGA + RKNN 实时检测链路由约 18.7FPS 优化至约 29.7FPS。
```

---

## 23. 当前项目优化路线回顾

从 04 到 07，完整路线是：

```text
04 camera_profile：
    发现 OpenCV VideoCapture 是摄像头输入瓶颈；
    默认 4K 约 5FPS；
    设置 720P 后约 15FPS；
    v4l2-ctl / V4L2 mmap 可接近 30FPS。

05 v4l2_rga_realtime_preprocess：
    使用 V4L2 mmap 原生采集 NV12；
    使用 RGA 转 RGB888；
    输入预处理链路达到约 29.6FPS。

06 v4l2_rga_rknn_detect：
    接入 RKNN YOLO11 推理；
    初始完整链路约 18.7FPS；
    瓶颈集中在 inference_yolo11_model()。

07 model_internal_profile：
    拆解 inference_yolo11_model；
    拆解 post_process；
    定位 decode / 高分辨率分支 / 类别扫描；
    发现未开启 -O3 和 CPU governor 问题；
    通过 Release + O3 + performance 将完整链路提升到约 29.7FPS。
```

---

## 24. 后续建议

当前已经达到接近 30FPS，因此下一步不建议继续优先死磕后处理，而是转向完整流媒体链路：

```text
08_mpp_encode_record：
    将检测后的帧接入 MPP H.264 硬件编码；
    保存为 H.264 / MP4 文件；
    替代 CPU / OpenCV VideoWriter。

09_rtsp_stream_preview：
    将编码后的 H.264 码流通过 RTSP / HTTP-FLV / HLS 推流；
    实现局域网实时预览。

10_pipeline_thread：
    视情况再做采集 / 推理 / 编码三线程；
    因为当前单线程已经接近 30FPS，
    三线程更多用于稳定帧率、解耦模块、避免偶发阻塞。
```

当前建议路线：

```text
07 总结归档
        ↓
08 MPP 编码保存检测视频
        ↓
09 RTSP / HTTP-FLV 实时推流
        ↓
10 整理简历项目描述
```

---

## 25. 可以写进简历的表达

可以将 07 的结果压缩成简历项目描述：

```text
基于 RK3588 完成 YOLO11 RKNN 端侧实时检测部署，绕开 OpenCV VideoCapture 采集瓶颈，采用 V4L2 mmap 获取 NV12 帧并通过 RGA 完成颜色转换；进一步对 inference_yolo11_model() 进行阶段级性能剖析，定位后处理 decode 与 CPU 编译优化问题，通过 Release/O3 编译和 CPU performance governor 优化，将完整 V4L2 + RGA + RKNN 检测链路由约 18.7FPS 提升至约 29.7FPS，接近 30FPS 实时处理。
```

---

## 26. 07 实验最终一句话总结

```text
07 实验通过逐层剖析 inference_yolo11_model()、post_process() 和 process_i8_nchw()，证明初始 18.7FPS 的主要问题不是单纯 NPU 推理慢，而是未开启 O3、CPU 频率调度和 COCO 80 类高分辨率分支后处理共同造成；在 Release + O3 + performance 后，完整 V4L2 + RGA + RKNN 检测链路达到 29.7FPS，基本实现 720P 30FPS 实时检测。
```

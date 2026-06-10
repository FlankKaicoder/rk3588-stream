# 22 自研异步 MPP 编码与音视频双轨 RTSP 最终集成实验记录

> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：`22_av_async_mpp_rtsp`  
> 当前阶段目标：在实验21自研异步 MPP H.264 编码链路基础上，接入实验20已经验证过的 ALSA 音频采集、AAC 编码与 RTSP 双轨推流，形成当前项目的最终音视频实时检测推流闭环。

---

## 1. 实验背景

前面 00~21 实验已经完成了从 RK3588 官方 YOLO11 Demo 到完整 AI 视频流媒体系统的逐步迁移、优化和工程封装。

截至实验21结束，视频链路已经完成：

```text
/dev/video11 摄像头
    ↓
V4L2 mmap 采集 1280x720 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
YOLO11 后处理与检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
自研 C++ MppH264Encoder
    ↓
异步 MPP H.264 编码线程
    ↓
H.264 FIFO
    ↓
FFmpeg
    ↓
MediaMTX
    ↓
RTSP 预览
```

实验21的关键意义是：

```text
把原来依赖外部 mpi_enc_test 的编码流程，
替换成了当前工程内部自研封装的 MppH264Encoder，
并通过异步编码线程解耦主检测流程和 MPP 编码流程。
```

但是实验21仍然是视频单轨链路，还没有把音频接回最终系统。

前面实验20已经验证过：

```text
ALSA hw:2,0 音频采集
    ↓
FFmpeg AAC 编码
    ↓
H.264 + AAC
    ↓
RTSP 双轨推流
    ↓
MediaMTX / VLC / ffprobe 验证
```

因此实验22的目标是把两条已经验证过的能力合并：

```text
实验21：
    自研异步 MPP H.264 视频编码

实验20：
    ALSA 音频采集 + AAC 编码 + RTSP 双轨合流
```

最终形成：

```text
自研异步 MPP 视频编码
    +
ALSA 实时音频采集
    +
FFmpeg AAC 编码
    +
RTSP H.264 + AAC 双轨推流
```

---

## 2. 实验目标

实验22主要验证以下内容：

```text
1. 复用实验21的 exp21_detect_mpp_encode_async 程序；
2. 视频端由 C++ 主程序内部完成异步 MPP H.264 编码；
3. 视频 H.264 输出到 FIFO；
4. FFmpeg 同时读取：
   - H.264 FIFO
   - ALSA hw:2,0 PCM 音频
5. FFmpeg 对音频编码为 AAC；
6. FFmpeg 将 H.264 + AAC 封装为 RTSP；
7. MediaMTX 正常发布双轨 RTSP；
8. ffprobe 能识别 H.264 视频轨和 AAC 音频轨；
9. VLC 能打开 RTSP 地址进行音视频预览；
10. 300 帧短时验证接近 30FPS；
11. 3600 帧长时间验证稳定接近 30FPS；
12. 确认无 RGA、音频 xrun、时间戳、队列阻塞、Broken pipe 等异常。
```

---

## 3. 最终链路

实验22最终链路如下：

```text
摄像头 /dev/video11
    ↓
V4L2 mmap 采集 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
YOLO11 后处理
    ↓
检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
自研 C++ 异步 MPP H.264 编码线程
    ↓
H.264 FIFO
    ↓
FFmpeg 读取 H.264 FIFO
    ↓
视频轨：H.264 copy

ALSA hw:2,0
    ↓
FFmpeg 实时采集 PCM
    ↓
AAC 编码
    ↓
音频轨：AAC 48kHz stereo

H.264 + AAC
    ↓
FFmpeg RTSP MUX
    ↓
MediaMTX
    ↓
RTSP 双轨流
    ↓
VLC / ffprobe 验证
```

RTSP 播放地址格式：

```text
rtsp://板端IP:8554/exp22_av_async_mpp_rtsp_120s_perf
```

实际测试板端 IP 示例：

```text
rtsp://10.198.89.221:8554/exp22_av_async_mpp_rtsp_120s_perf
```

---

## 4. 当前实验环境

### 4.1 硬件平台

```text
开发板        ：RK3588 / LubanCat
摄像头节点    ：/dev/video11
V4L2 driver   ：rkisp_v6
V4L2 card     ：rkisp_mainpath
视频格式      ：NV12
视频分辨率    ：1280x720
目标帧率      ：30FPS
音频设备      ：hw:2,0
音频采样率    ：48000 Hz
音频声道      ：2 channels / stereo
```

### 4.2 软件模块

```text
视频采集       ：V4L2 mmap
图像转换       ：RGA
AI 推理        ：RKNN YOLO11
视频编码       ：自研 MppH264Encoder / Rockchip MPP H.264
视频编码线程   ：异步编码线程
音频采集       ：ALSA hw:2,0
音频编码       ：FFmpeg AAC
推流封装       ：FFmpeg RTSP
RTSP Server    ：MediaMTX
验证工具       ：ffprobe / VLC
```

---

## 5. 相关文件

### 5.1 复用实验21程序

```text
build/exp21_detect_mpp_encode_async
```

对应源码：

```text
src/main_exp21_detect_mpp_encode_async.cpp
include/mpp_h264_encoder.hpp
src/mpp_h264_encoder.cpp
src/yolo11_clean_silent.cc
```

### 5.2 实验22脚本

新增脚本：

```text
scripts/exp22_av_async_mpp_rtsp.sh
```

脚本作用：

```text
1. 启动 MediaMTX；
2. 创建 H.264 FIFO；
3. 启动 FFmpeg；
4. FFmpeg 同时读取 H.264 FIFO 和 ALSA hw:2,0；
5. 启动 exp21_detect_mpp_encode_async；
6. 等待 RTSP 双轨上线；
7. ffprobe 验证 H.264 + AAC；
8. 等待检测程序处理指定帧数；
9. 收尾清理 FFmpeg / MediaMTX / FIFO；
10. 统计异常日志。
```

### 5.3 输出目录

300 帧短测输出目录：

```text
output/exp22_av_async_mpp_rtsp_300f_20260610_151442
```

3600 帧长测输出目录：

```text
output/exp22_av_async_mpp_rtsp_3600f_20260610_153218
```

关键输出文件：

```text
22_1.log
detect_async_mpp_h264_fifo.log
ffmpeg_av_rtsp.log
ffprobe_av_rtsp.log
mediamtx.log
mediamtx_exp22.yml
profile_exp22_async_mpp_av.csv
summary.txt
detect_h264.fifo
```

---

## 6. 编译检查

实验22复用实验21异步程序，因此需要确认：

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir -p build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async -j4

cd ..
ls -lh build/exp21_detect_mpp_encode_async
```

---

## 7. 实验22脚本运行方式

### 7.1 300 帧短时验证

```bash
cd ~/projects/rk3588_ai_stream

./scripts/exp22_av_async_mpp_rtsp.sh \
  1280 \
  720 \
  30 \
  300 \
  hw:2,0 \
  48000 \
  2 \
  exp22_av_async_mpp_rtsp_300f_perf
```

参数含义：

| 参数 | 含义 |
|---|---|
| `1280` | 视频宽度 |
| `720` | 视频高度 |
| `30` | 目标 FPS |
| `300` | 处理帧数 |
| `hw:2,0` | ALSA 音频采集设备 |
| `48000` | 音频采样率 |
| `2` | 音频声道数 |
| `exp22_av_async_mpp_rtsp_300f_perf` | RTSP path |

### 7.2 3600 帧长时间验证

```bash
cd ~/projects/rk3588_ai_stream

./scripts/exp22_av_async_mpp_rtsp.sh \
  1280 \
  720 \
  30 \
  3600 \
  hw:2,0 \
  48000 \
  2 \
  exp22_av_async_mpp_rtsp_120s_perf
```

说明：

```text
3600 帧 / 30FPS = 120 秒
```

该测试用于验证当前最终链路能否在约 120 秒内稳定完成音视频双轨 RTSP 推流。

---

## 8. 实验过程中的脚本问题与修复

### 8.1 问题现象

第一次运行 300 帧时，主链路已经完成：

```text
detector finished.
[ENC] encoder thread exit, encoded=300 failures=0 drops=0
```

但是脚本卡在：

```text
========== key abnormal counters ==========
```

最后手动 Ctrl+C 才结束。

### 8.2 原因分析

原始统计逻辑使用了：

```bash
grep -R "RGA_COLORFILL" "$OUT_DIR" 2>/dev/null | wc -l
```

但是输出目录中存在 FIFO：

```text
detect_h264.fifo
```

`grep -R` 会递归扫描目录内所有文件，包括 FIFO。  
FIFO 不是普通文件，`grep` 读取 FIFO 可能阻塞等待数据，因此脚本卡住。

### 8.3 修复方式

修复原则：

```text
不要递归扫描整个 OUT_DIR；
不要扫描 FIFO；
不要扫描 summary.txt / 22_1.log 这类统计文件；
只扫描真实原始运行日志。
```

修复后只扫描：

```text
detect_async_mpp_h264_fifo.log
ffmpeg_av_rtsp.log
mediamtx.log
ffprobe_av_rtsp.log
```

核心代码：

```bash
LOG_FILES=(
  "$DETECT_LOG"
  "$FFMPEG_LOG"
  "$MEDIAMTX_LOG"
  "$FFPROBE_LOG"
)

count_pattern() {
    local pattern="$1"
    grep -h -F "$pattern" "${LOG_FILES[@]}" 2>/dev/null | wc -l | tr -d ' '
}

count_pattern_i() {
    local pattern="$1"
    grep -h -i -F "$pattern" "${LOG_FILES[@]}" 2>/dev/null | wc -l | tr -d ' '
}
```

### 8.4 二次误判问题

修复 FIFO 阻塞后，曾经出现统计结果为：

```text
RGA_COLORFILL                : 2
Failed to call RockChipRga   : 2
xrun                         : 2
Thread message queue blocking: 2
Timestamps are unset         : 2
Broken pipe                  : 2
```

但进一步检查真实运行日志：

```bash
grep -nH -E \
  "RGA_COLORFILL|Failed to call RockChipRga|xrun|Thread message queue blocking|Timestamps are unset|Broken pipe" \
  "$OUT/detect_async_mpp_h264_fifo.log" \
  "$OUT/ffmpeg_av_rtsp.log" \
  "$OUT/mediamtx.log" \
  "$OUT/ffprobe_av_rtsp.log" \
  2>/dev/null || echo "no real abnormal lines"
```

结果：

```text
no real abnormal lines
```

原因是统计脚本把 `summary.txt` / `summary_fixed.txt` / `22_1.log` 里“统计项名字本身”也统计进去了，属于假阳性。

最终修复为只扫描原始运行日志后，异常计数恢复正确。

---

## 9. 22-1：300 帧短时验证

### 9.1 测试目录

```text
output/exp22_av_async_mpp_rtsp_300f_20260610_151442
```

### 9.2 summary 结果

```text
FFPROBE_H264_AAC_OK          : 1
RGA_COLORFILL                : 0
Failed to call RockChipRga   : 0
xrun                         : 0
Thread message queue blocking: 0
Timestamps are unset         : 0
Broken pipe                  : 0
```

### 9.3 检测端与编码端结果

```text
frames     : 300

async_encoded_frames : 300
async_encode_failures: 0
async_drop_frames    : 0
async_avg_encode_ms  : 2.813
async_avg_write_ms   : 0.112
async_avg_total_ms   : 2.926

frames              : 300
wall_fps            : 29.761
avg_model_total_ms  : 27.640
avg_total_ms        : 33.537
```

### 9.4 结果分析

300 帧短时验证说明：

```text
1. 自研异步 MPP 编码线程正常工作；
2. 300 帧全部编码成功；
3. 编码失败为 0；
4. 编码丢帧为 0；
5. 平均 MPP 编码总耗时约 2.926ms；
6. 检测主链路 wall_fps = 29.761，接近 30FPS；
7. RKNN 推理整体平均耗时约 27.640ms；
8. 完整检测主循环平均耗时约 33.537ms；
9. H.264 + AAC 双轨 RTSP 验证通过；
10. 未出现 RGA / xrun / timestamp / broken pipe 异常。
```

---

## 10. 22-2：3600 帧长时间验证

### 10.1 测试目录

```text
output/exp22_av_async_mpp_rtsp_3600f_20260610_153218
```

### 10.2 summary 结果

```text
FFPROBE_H264_AAC_OK          : 1
RGA_COLORFILL                : 0
Failed to call RockChipRga   : 0
xrun                         : 0
Thread message queue blocking: 0
Timestamps are unset         : 0
Broken pipe                  : 0
```

### 10.3 检测端与编码端结果

```text
frames     : 3600

async_encoded_frames : 3600
async_encode_failures: 0
async_drop_frames    : 0
async_avg_encode_ms  : 2.698
async_avg_write_ms   : 0.191
async_avg_total_ms   : 2.889

frames              : 3600
wall_fps            : 29.980
avg_model_total_ms  : 27.366
avg_total_ms        : 33.303
```

### 10.4 ffprobe 结果

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp22_av_async_mpp_rtsp_120s_perf':
  Metadata:
    title           : No Name
  Duration: N/A, start: 0.000000, bitrate: N/A
    Stream #0:0: Video: h264 (High), yuv420p(progressive), 1280x720, 30 fps, 30 tbr, 90k tbn, 60 tbc
    Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp
```

说明 RTSP 中包含两条轨道：

```text
视频轨：
    H.264 High Profile
    yuv420p
    1280x720
    30 fps

音频轨：
    AAC LC
    48000 Hz
    stereo
    fltp
```

### 10.5 MediaMTX 关键日志

```text
2026/06/10 15:32:24 INF [path exp22_av_async_mpp_rtsp_120s_perf] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
2026/06/10 15:32:24 INF [RTSP] [session 3cc5c618] is publishing to path 'exp22_av_async_mpp_rtsp_120s_perf'
2026/06/10 15:32:24 INF [RTSP] [session 07c5d4e0] is reading from path 'exp22_av_async_mpp_rtsp_120s_perf', with TCP, 2 tracks (H264, MPEG-4 Audio)
2026/06/10 15:34:26 INF shutting down gracefully
```

说明：

```text
1. MediaMTX 成功发布 RTSP path；
2. RTSP path 上线后包含 2 tracks；
3. FFmpeg 正在向该 path 推流；
4. ffprobe / 客户端可以通过 TCP 读取该 path；
5. 实验结束后 MediaMTX 正常 graceful shutdown；
6. 不是异常崩溃。
```

### 10.6 真实异常检查

检查命令：

```bash
grep -nH -E \
  "RGA_COLORFILL|Failed to call RockChipRga|xrun|Thread message queue blocking|Timestamps are unset|Broken pipe" \
  "$OUT3600/detect_async_mpp_h264_fifo.log" \
  "$OUT3600/ffmpeg_av_rtsp.log" \
  "$OUT3600/mediamtx.log" \
  "$OUT3600/ffprobe_av_rtsp.log" \
  2>/dev/null || echo "no real abnormal lines"
```

结果：

```text
no real abnormal lines
```

说明 3600 帧测试中没有出现以下问题：

```text
RGA_COLORFILL
Failed to call RockChipRga
ALSA xrun
Thread message queue blocking
Timestamps are unset
Broken pipe
```

---

## 11. 性能分析

### 11.1 300 帧与 3600 帧对比

| 指标 | 300 帧 | 3600 帧 | 说明 |
|---|---:|---:|---|
| frames | 300 | 3600 | 测试帧数 |
| wall_fps | 29.761 | 29.980 | 长测仍接近 30FPS |
| avg_model_total_ms | 27.640ms | 27.366ms | RKNN 推理整体稳定 |
| avg_total_ms | 33.537ms | 33.303ms | 主循环稳定 |
| async_encoded_frames | 300 | 3600 | 编码帧数与输入帧一致 |
| async_encode_failures | 0 | 0 | 无编码失败 |
| async_drop_frames | 0 | 0 | 无编码丢帧 |
| async_avg_encode_ms | 2.813ms | 2.698ms | MPP 编码耗时低 |
| async_avg_write_ms | 0.112ms | 0.191ms | FIFO 写入开销低 |
| async_avg_total_ms | 2.926ms | 2.889ms | 编码线程负载较低 |

### 11.2 性能结论

```text
1. 3600 帧长时间运行后 wall_fps = 29.980，说明最终链路可以稳定接近 30FPS；
2. avg_model_total_ms = 27.366ms，说明 RKNN 推理整体耗时在长测中没有继续劣化；
3. avg_total_ms = 33.303ms，基本符合 30FPS 所需的 33.33ms 周期；
4. async_avg_total_ms = 2.889ms，说明自研 MPP 编码线程不是瓶颈；
5. async_drop_frames = 0，说明编码线程没有发生队列积压导致的丢帧；
6. H.264 + AAC 双轨 RTSP 可以稳定上线；
7. ALSA 音频采集与 AAC 编码没有出现 xrun；
8. FFmpeg 推流没有出现 timestamp unset / broken pipe；
9. MediaMTX 能正常发布与关闭。
```

---

## 12. 关于 performance governor 的说明

实验过程中曾出现一次 3600 帧测试结果：

```text
wall_fps            : 25.638
avg_model_total_ms  : 34.408
avg_total_ms        : 38.859
```

但当时没有在测试前重新确认 CPU governor / 频率状态。后续将 CPU governor 设置为 performance：

```bash
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$g"
done

cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c
```

结果：

```text
8 performance
```

重新进行 300 帧和 3600 帧验证后：

```text
300 帧：
    wall_fps = 29.761

3600 帧：
    wall_fps = 29.980
```

因此实验22最终结论以 performance governor 下复测结果为准。

这说明：

```text
1. RK3588 在 performance governor 下可以稳定支撑当前链路；
2. 若处于非 performance 状态，长时间运行可能出现模型整体耗时上升；
3. 最终脚本或部署文档中应显式检查 / 设置 CPU governor；
4. 面试或项目总结中不能只说“绝对稳定 30FPS”，应说明测试条件为 performance governor。
```

---

## 13. 关于多 NPU 推理线程池的讨论

实验过程中讨论过是否继续接入“三个 NPU 核心轮流推理 / 多推理线程池”。

当前实验22没有接入多 NPU worker，而是采用：

```text
单 RKNN 推理上下文
    +
异步 MPP 编码线程
```

当前版本的意义是：

```text
1. 保持链路稳定；
2. 保持帧顺序简单；
3. 避免多推理线程带来的乱序、队列、丢帧和时间戳问题；
4. 先完成最终系统闭环。
```

多 NPU worker 的潜在结构是：

```text
采集线程
    ↓
推理任务队列
    ↓
NPU Worker 0 / RKNN context 0 / NPU core 0
NPU Worker 1 / RKNN context 1 / NPU core 1
NPU Worker 2 / RKNN context 2 / NPU core 2
    ↓
完成队列
    ↓
按 frame_id 重排序
    ↓
异步 MPP 编码线程
```

但是这种设计会引入：

```text
多 RKNN context 管理
NPU core mask 设置
输入输出 buffer 生命周期管理
frame_id 顺序恢复
迟到帧丢弃策略
低延迟与完整帧率之间的取舍
```

因此本实验22不继续扩展多 NPU worker。它可以作为后续性能版优化方向，而不是当前稳定版最终链路的一部分。

最终项目可以表述为：

```text
当前稳定版采用单 RKNN 推理上下文 + 异步 MPP 编码线程；
后续可扩展多 RKNN context 推理池，利用 RK3588 三核 NPU 提升吞吐，
但需要额外处理帧序重排、队列积压和低延迟丢帧策略。
```

---

## 14. 实验22最终结论

实验22最终结论：

```text
实验22：通过。

本实验成功将实验21中的自研异步 MPP H.264 视频编码链路，
与实验20中的 ALSA 音频采集、AAC 编码、RTSP 双轨合流能力结合，
形成当前项目最终版音视频实时检测推流链路。

最终链路实现：

    V4L2 摄像头采集
        → RGA NV12/RGB 图像转换
        → RKNN YOLO11 推理
        → YOLO11 后处理与检测框绘制
        → RGA RGB/NV12 转换
        → 自研 C++ 异步 MPP H.264 编码
        → H.264 FIFO
        → FFmpeg 读取 H.264 FIFO
        → ALSA hw:2,0 音频采集
        → FFmpeg AAC 编码
        → FFmpeg RTSP 音视频双轨封装
        → MediaMTX 发布
        → VLC / ffprobe 预览与验证

最终验证结果：

    300 帧短测：
        wall_fps = 29.761
        async_encoded_frames = 300
        async_encode_failures = 0
        async_drop_frames = 0

    3600 帧长测：
        wall_fps = 29.980
        async_encoded_frames = 3600
        async_encode_failures = 0
        async_drop_frames = 0

    ffprobe：
        Video: H.264 High Profile, 1280x720, 30fps
        Audio: AAC LC, 48000Hz, stereo

    MediaMTX：
        stream is available and online, 2 tracks (H264, MPEG-4 Audio)

    异常检查：
        RGA_COLORFILL = 0
        Failed to call RockChipRga = 0
        xrun = 0
        Thread message queue blocking = 0
        Timestamps are unset = 0
        Broken pipe = 0

说明当前 RK3588 端侧 AI 音视频实时检测推流系统已经形成稳定闭环。
```

---

## 15. 后续方向

实验22完成后，当前项目已经具备最终演示能力。后续不建议继续盲目新增功能，而应进入最终收尾阶段：

```text
23_final_stability_profile：
    最终系统级稳定性与资源占用测试。

24_project_cleanup：
    工程目录、脚本、CMake target、README、docs 总整理。

final_project_summary：
    总项目总结文档。

resume_description：
    简历项目表述整理。

interview_questions：
    面试问题与回答整理。
```

实验23建议重点做：

```text
1. 300 秒最终稳定性测试；
2. 同步记录 CPU / 内存 / 温度 / 频率；
3. 记录 MediaMTX / FFmpeg / 检测程序日志；
4. 验证长时间运行是否仍然无 xrun / broken pipe / timestamp unset；
5. 形成最终项目验收数据。
```

# 实验25：H.264 + AAC 双轨 MP4 本地录像封装实验记录

> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：`25_av_mp4_mux_record` / `25_1_av_mp4_mux_baseline` / `25_2_sync_av_mp4_record`  
> 当前阶段目标：在实验24已经完成“实时检测 H.264 + PTS CSV + 自研视频 MP4 MUX”的基础上，接入 ALSA 音频采集与 AAC 编码，完成 H.264 视频轨 + AAC 音频轨的本地双轨 MP4 录像。

---

## 1. 实验背景

截至实验24，工程已经完成了比较完整的视频录像链路：

```text
/dev/video11 摄像头
    ↓
V4L2 mmap 采集 1280x720 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
自研异步 MPP H.264 编码
    ↓
H.264 裸流 + PTS CSV
    ↓
自研 libavformat MP4 muxer
    ↓
标准 video-only MP4 文件
```

实验24解决的核心问题是：

```text
不是简单让 FFmpeg 猜测裸 H.264 帧率，
而是把工程侧生成的编码端 PTS 显式写入 MP4 容器。
```

实验24中已经完成：

```text
1. MPP 编码端输出 H.264 packet；
2. 工程侧记录 frame_id、input_pts_us、mpp_packet_pts_us、packet_size；
3. 自研 muxer 从 PTS CSV 读取每个 packet 的时间戳；
4. 根据 packet_size 从 H.264 裸流中切分 packet；
5. 将 Annex-B H.264 转换为 MP4 所需的 AVCC length-prefixed sample；
6. 构造 avcC extradata；
7. 设置 AVPacket.pts / dts / duration；
8. 输出 video-only MP4；
9. 通过 ffprobe packet 级验证 MP4 与 PTS CSV 对齐。
```

但是实验24仍然只有视频轨，没有音频轨。

前面 13~16 实验已经证明 RK3588 板端具备音频基础能力：

```text
ALSA hw:2,0 音频采集；
AAC / Opus / G.711 编码；
压缩音频解码与播放；
FFmpeg 支持 ALSA、AAC、MP4 mux。
```

实验22也已经证明实时系统中可以完成：

```text
H.264 视频 + ALSA 音频 + AAC 编码 + RTSP 双轨推流。
```

因此实验25的目标是把本地录像能力从：

```text
video-only MP4
```

升级为：

```text
H.264 + AAC 双轨 MP4
```

也就是补齐本地音视频录像链路。

---

## 2. 实验目标

实验25主要验证以下内容：

```text
1. 使用实验24生成的 video-only MP4 与 AAC 音频文件合成双轨 MP4；
2. 验证 FFmpeg copy mux 是否能无重编码合成 H.264 + AAC MP4；
3. 在同一次实验中同步启动音频采集和视频检测录像；
4. 视频侧继续使用实验24自研 muxer 生成带 PTS 的 video-only MP4；
5. 音频侧使用 FFmpeg 从 ALSA hw:2,0 采集 PCM 并编码为 AAC M4A；
6. 根据音频与视频启动时间差 `audio_lead_sec` 对音频开头进行裁剪；
7. 将 video-only MP4 与 audio.m4a copy mux 成最终 AV MP4；
8. 通过 ffprobe 验证 H.264 视频轨与 AAC 音频轨；
9. 通过 ffmpeg 解码验证最终 MP4 可正常播放；
10. 检查是否存在 xrun、timestamp unset、Non-monotonous DTS、decode error 等异常；
11. 完成 1800 帧短测和 3600 帧长测。
```

---

## 3. 实验25总体链路

实验25最终链路为：

```text
视频侧：
/dev/video11
    ↓
V4L2 mmap 采集 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
YOLO11 后处理与检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
自研异步 MPP H.264 编码
    ↓
H.264 裸流 + PTS CSV
    ↓
实验24自研 MP4 muxer
    ↓
video-only MP4

音频侧：
ALSA hw:2,0
    ↓
FFmpeg 采集 PCM S16_LE 48kHz stereo
    ↓
AAC 编码
    ↓
audio.m4a

最终封装：
video-only MP4
    +
audio.m4a
    ↓
FFmpeg copy mux
    ↓
H.264 + AAC 双轨 MP4
```

需要注意：

```text
实验25不是完全自研音视频 MP4 muxer。
当前工程中自研的是“视频 MP4 muxer”；
最终音视频双轨合成使用 FFmpeg copy mux 完成。
```

更准确的工程表述是：

```text
实现了基于 libavformat 的 H.264 视频 MP4 muxer，
完成 Annex-B 到 AVCC 转换、SPS/PPS avcC extradata 构造、
AVPacket PTS/DTS/duration 写入和 packet 级对齐验证；
在此基础上使用 FFmpeg copy mux 接入 AAC 音频轨，
形成 H.264 + AAC 双轨 MP4 录像。
```

---

## 4. 相关文件与代码位置

### 4.1 视频检测与异步 MPP 编码

复用实验21 / 23 / 24 中已经形成的程序：

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

作用：

```text
1. 采集摄像头 NV12；
2. RGA 转 RGB；
3. RKNN YOLO11 推理；
4. 检测框绘制；
5. RGA 转回 NV12；
6. 异步 MPP H.264 编码；
7. 输出 H.264 裸流；
8. 输出 PTS CSV。
```

---

### 4.2 自研视频 MP4 muxer

代码位置：

```text
src/main_exp24_mp4_mux_from_pts.cpp
```

可执行程序：

```text
build/exp24_mp4_mux_from_pts
```

CMake target：

```text
exp24_mp4_mux_from_pts
```

作用：

```text
读取 input.h264 + input.pts.csv，
生成带正确 PTS / DTS / duration 的 video-only MP4。
```

该 muxer 主要完成：

```text
1. 读取 H.264 裸流；
2. 读取 PTS CSV；
3. 按 packet_size 切分每个 H.264 packet；
4. 解析 SPS / PPS；
5. 构造 avcC extradata；
6. 将 Annex-B H.264 转换为 AVCC sample；
7. 设置 AVPacket.pts；
8. 设置 AVPacket.dts；
9. 设置 AVPacket.duration；
10. 判断 IDR 关键帧并设置 AV_PKT_FLAG_KEY；
11. 写入 MP4 文件。
```

---

### 4.3 实验25脚本

25-1 基线脚本：

```text
scripts/exp25_1_av_mp4_mux_baseline.sh
```

作用：

```text
使用实验24已有 video-only MP4，
重新采集一段 AAC 音频，
通过 FFmpeg copy mux 合成双轨 MP4。
```

25-2 同步录制脚本：

```text
scripts/exp25_2_sync_av_mp4_record.sh
```

作用：

```text
1. 启动音频采集；
2. 启动实时视频检测录像；
3. 视频生成 H.264 + PTS CSV；
4. 调用 exp24_mp4_mux_from_pts 生成 video-only MP4；
5. 根据 audio_lead_sec 裁掉音频开头；
6. 使用 FFmpeg copy mux 合成最终 AV MP4；
7. ffprobe 验证；
8. ffmpeg decode 验证；
9. 输出 summary 和 abnormal 检查。
```

---

## 5. 实验25-1：已有视频 MP4 + 新采集 AAC 的双轨封装基线

### 5.1 实验目的

25-1 不重新跑摄像头检测，而是先用实验24已经生成的视频 MP4 作为输入。

这样可以把问题拆开：

```text
不引入实时摄像头；
不引入 RKNN；
不引入 MPP 编码；
只验证 video-only MP4 + AAC 音频能否合成为标准双轨 MP4。
```

实验链路：

```text
实验24生成的 realtime_detect_1800f.mp4
    +
FFmpeg 从 ALSA hw:2,0 新采集的 AAC 音频
    ↓
FFmpeg -c:v copy -c:a copy
    ↓
H.264 + AAC 双轨 MP4
```

---

### 5.2 25-1 输入输出

输入视频：

```text
output/exp24_3_realtime_mp4_record_1800f_20260625_160150/realtime_detect_1800f.mp4
```

音频文件：

```text
output/exp25_1_av_mp4_mux_baseline/exp25_1_audio_48k_stereo_aac.m4a
```

最终输出：

```text
output/exp25_1_av_mp4_mux_baseline/exp25_1_av_mux_baseline.mp4
```

---

### 5.3 25-1 关键结果

文件大小：

```text
video mp4 : 29M
audio m4a : 967K
av mp4    : 30M
```

最终双轨信息：

```text
video:
codec_name=h264
codec_type=video
width=1280
height=720
r_frame_rate=30/1
time_base=1/1000000
duration=59.999999
nb_frames=1800

 audio:
codec_name=aac
codec_type=audio
sample_rate=48000
channels=2
channel_layout=stereo
time_base=1/48000
duration=59.990000
nb_frames=2813
```

容器信息：

```text
duration=60.012000
size=31237999
bit_rate=4164233
```

异常检查：

```text
ffmpeg_audio_capture: 空
ffmpeg_av_mux:       空
decode_check:        空
```

---

### 5.4 25-1 结论

```text
25-1：通过。
```

说明：

```text
1. 实验24生成的视频 MP4 可以作为视频轨输入；
2. ALSA 采集后 AAC M4A 可以作为音频轨输入；
3. FFmpeg copy mux 可以无重编码合成 H.264 + AAC MP4；
4. 没有 timestamp unset；
5. 没有 Non-monotonous DTS；
6. 没有 ALSA xrun；
7. 没有 decode error。
```

但 25-1 只是文件级基线，不代表真实同步录制，因为音频和视频不是同一次采集得到的。

---

## 6. 实验25-2：1800 帧同步启动双轨 MP4 录像

### 6.1 实验目的

25-2 开始在同一次实验中同步启动音频采集与视频检测录像。

流程：

```text
启动 AAC 音频采集
    ↓
启动实时检测 + 异步 MPP H.264 编码
    ↓
得到 H.264 + PTS CSV
    ↓
自研 exp24 muxer 生成视频 MP4
    ↓
按启动时间差裁掉音频开头多录的一小段
    ↓
合成 H.264 + AAC 双轨 MP4
    ↓
ffprobe / decode / abnormal 检查
```

---

### 6.2 同步启动策略

当前脚本采用的是进程启动时间粗对齐：

```text
AUDIO_START_NS = 启动音频 FFmpeg 前后的系统时间；
VIDEO_START_NS = 启动视频检测程序前后的系统时间；
audio_lead_sec = VIDEO_START_NS - AUDIO_START_NS。
```

因为脚本故意让音频先启动约 0.35 秒，所以最终合成时使用：

```bash
-ss "$AUDIO_LEAD_SEC" -i "$AUDIO_M4A"
```

裁掉音频开头多录部分。

这一步的作用是：

```text
让音频轨与视频轨在文件时间轴上尽量从同一时刻开始。
```

注意：

```text
这还不是严格的采集层唇音同步。
严格唇音同步需要统一 V4L2 buffer timestamp 与 ALSA sample timestamp。
当前实验25属于“同步启动 + 启动偏移裁剪”的文件级对齐方案。
```

---

### 6.3 25-2 运行命令

```bash
cd ~/projects/rk3588_ai_stream

./scripts/exp25_2_sync_av_mp4_record.sh \
  1800 \
  1280 \
  720 \
  30 \
  hw:2,0 \
  48000 \
  2
```

---

### 6.4 25-2 输出目录

```text
output/exp25_2_sync_av_mp4_1800f_20260702_223129
```

关键输出文件：

```text
realtime_detect_1800f.h264
realtime_detect_1800f.h264.pts.csv
realtime_detect_1800f_video_only.mp4
realtime_audio_1800f_aac.m4a
realtime_detect_1800f_av_sync.mp4
profile_1800f.csv
summary.txt
ffprobe_av_streams.txt
ffprobe_av_format.txt
abnormal.txt
ffmpeg_decode_check.log
```

---

### 6.5 25-2 关键结果

summary 结果：

```text
frames=1800
width=1280
height=720
fps=30
video_duration_s=60.000

audio_dev=hw:2,0
audio_rate=48000
audio_ch=2
audio_duration_s=62.000
audio_lead_sec=0.365

detect_rc=0
audio_rc=0
mux_video_rc=0
mux_av_rc=0
decode_rc=0

async_encoded_frames=1800
async_encode_failures=0
async_drop_frames=0
wall_fps=29.960

pts_rows=1800
mp4_video_packets=1800
abnormal_lines=0

result=PASS
```

最终 AV MP4 轨道信息：

```text
video:
codec_name=h264
codec_type=video
width=1280
height=720
r_frame_rate=30/1
time_base=1/1000000
duration=59.999999
bit_rate=4011695
nb_frames=1800

audio:
codec_name=aac
codec_type=audio
sample_rate=48000
channels=2
channel_layout=stereo
time_base=1/48000
duration=60.009000
bit_rate=128517
nb_frames=2813
```

容器信息：

```text
duration=60.012000
size=31118838
bit_rate=4148348
```

---

### 6.6 25-2 结论

```text
25-2：通过。
```

说明：

```text
1. 60 秒同步启动录像成功；
2. 视频 1800 帧全部编码成功；
3. 编码失败 0；
4. 异步队列丢帧 0；
5. wall_fps = 29.960；
6. PTS CSV 行数 = 1800；
7. MP4 视频 packet 数 = 1800；
8. 最终 MP4 包含 H.264 + AAC 双轨；
9. ffmpeg decode 无错误；
10. abnormal 检查无真实异常。
```

---

## 7. 实验25-3：3600 帧 / 120 秒长测

### 7.1 实验目的

25-2 已经完成 1800 帧短测，但为了形成更有说服力的稳定性证据，需要继续做 3600 帧长测。

3600 帧在 30FPS 下约等于：

```text
3600 / 30 = 120 秒
```

该测试用于验证：

```text
1. 120 秒内视频检测链路是否稳定；
2. 异步 MPP 编码是否丢帧；
3. PTS CSV 是否完整；
4. video-only MP4 packet 是否完整；
5. AAC 音频采集是否无 xrun；
6. AV mux 是否无 timestamp / DTS 异常；
7. 最终 MP4 是否可解码。
```

---

### 7.2 运行命令

```bash
cd ~/projects/rk3588_ai_stream

./scripts/exp25_2_sync_av_mp4_record.sh \
  3600 \
  1280 \
  720 \
  30 \
  hw:2,0 \
  48000 \
  2
```

---

### 7.3 输出目录

```text
output/exp25_2_sync_av_mp4_3600f_20260702_223523
```

关键输出文件：

```text
realtime_detect_3600f.h264
realtime_detect_3600f.h264.pts.csv
realtime_detect_3600f_video_only.mp4
realtime_audio_3600f_aac.m4a
realtime_detect_3600f_av_sync.mp4
profile_3600f.csv
summary.txt
ffprobe_av_streams.txt
ffprobe_av_format.txt
abnormal.txt
ffmpeg_decode_check.log
```

---

### 7.4 3600 帧 summary 结果

```text
frames=3600
width=1280
height=720
fps=30
video_duration_s=120.000

audio_dev=hw:2,0
audio_rate=48000
audio_ch=2
audio_duration_s=122.000
audio_lead_sec=0.362

detect_rc=0
audio_rc=0
mux_video_rc=0
mux_av_rc=0
decode_rc=0

async_encoded_frames=3600
async_encode_failures=0
async_drop_frames=0
wall_fps=29.980

pts_rows=3600
mp4_video_packets=3600
abnormal_lines=0

result=PASS
```

---

### 7.5 3600 帧视频检测与编码性能

视频检测端最终统计：

```text
frames              : 3600
wall_time_ms        : 120080.386
wall_fps            : 29.980
avg_select_ms       : 1.560
avg_dqbuf_ms        : 0.004
avg_rga_nv12_to_rgb : 1.674
avg_input_prepare   : 0.001
avg_model_total_ms  : 27.324
avg_draw_ms         : 0.178
avg_rga_rgb_to_nv12 : 2.382
avg_mpp_queue_push  : 0.158
avg_qbuf_ms         : 0.032
avg_total_ms        : 33.313
```

异步编码线程统计：

```text
async_encoded_frames : 3600
async_encode_failures: 0
async_drop_frames    : 0
async_avg_encode_ms  : 2.908
async_avg_write_ms   : 0.090
async_avg_total_ms   : 2.999
```

说明：

```text
1. 主检测链路稳定接近 30FPS；
2. RKNN 推理整体仍然是最大耗时，约 27.324ms；
3. RGA 输入转换约 1.674ms；
4. RGA 输出转换约 2.382ms；
5. MPP 异步编码平均约 2.908ms；
6. 异步编码不是瓶颈；
7. 编码线程无失败、无丢帧。
```

---

### 7.6 3600 帧最终 AV MP4 轨道信息

最终 AV MP4 视频轨：

```text
index=0
codec_name=h264
codec_type=video
width=1280
height=720
r_frame_rate=30/1
avg_frame_rate=2039999987/67999999
time_base=1/1000000
duration=119.999999
bit_rate=4020999
nb_frames=3600
```

最终 AV MP4 音频轨：

```text
index=1
codec_name=aac
codec_type=audio
sample_rate=48000
channels=2
channel_layout=stereo
time_base=1/48000
duration=120.003000
bit_rate=128751
nb_frames=5626
```

容器信息：

```text
duration=120.024000
size=62380578
bit_rate=4157873
```

说明：

```text
视频轨为 H.264 High Profile，1280x720，30FPS，3600 帧；
音频轨为 AAC LC，48000Hz，stereo；
最终 MP4 容器时长约 120.024 秒；
视频和音频时长接近。
```

`avg_frame_rate=2039999987/67999999` 看起来比较奇怪，但本质上约等于 30FPS。
这是由于视频轨采用微秒 time_base：

```text
time_base=1/1000000
```

3600 帧对应约 119.999999 秒，因此 ffprobe 会显示成一个精确分数，不是异常。

---

### 7.7 3600 帧异常检查

`abnormal.txt` 内容：

```text
detect_async_mpp:
3344:async_encode_failures: 0
3345:async_drop_frames    : 0

ffmpeg_audio_capture:

mux_video_only:

ffmpeg_av_mux:

decode_check:
```

这里 `async_encode_failures` 和 `async_drop_frames` 被 grep 出来只是因为字段名包含 `failures` / `drop_frames`，但数值都是 0，因此不是真实异常。

真正需要关注的异常没有出现：

```text
xrun
Timestamps are unset
Non-monotonous DTS
Application provided invalid
Thread message queue blocking
RGA_COLORFILL
select timeout
decode error
corrupt
missing
```

因此 3600 帧长测异常检查通过。

---

### 7.8 25-3 结论

```text
25-3：通过。
```

说明：

```text
1. 120 秒同步音视频录像成功；
2. 视频 3600 帧全部编码成功；
3. 编码失败 0；
4. 异步队列丢帧 0；
5. wall_fps = 29.980；
6. PTS CSV 行数 = 3600；
7. MP4 视频 packet 数 = 3600；
8. 最终 MP4 包含 H.264 视频轨与 AAC 音频轨；
9. ffmpeg 解码验证无错误；
10. 未出现 xrun、timestamp unset、Non-monotonous DTS、decode error 等异常。
```

---

## 8. 当前 MP4 mux 机制解释

实验25中实际有两级 mux。

### 8.1 第一级：自研视频 MP4 mux

输入：

```text
realtime_detect_3600f.h264
realtime_detect_3600f.h264.pts.csv
```

输出：

```text
realtime_detect_3600f_video_only.mp4
```

调用方式：

```bash
./build/exp24_mp4_mux_from_pts \
    "$H264" \
    "$PTS_CSV" \
    "$VIDEO_MP4" \
    "$WIDTH" \
    "$HEIGHT" \
    "$FPS"
```

该阶段是真正自研代码完成的 mux。

其核心意义：

```text
将工程侧生成的 H.264 packet PTS 真正写入 MP4 容器，
避免裸 H.264 被 FFmpeg 自动猜测时间戳。
```

---

### 8.2 第二级：FFmpeg 音视频 copy mux

输入：

```text
realtime_detect_3600f_video_only.mp4
realtime_audio_3600f_aac.m4a
```

输出：

```text
realtime_detect_3600f_av_sync.mp4
```

调用方式：

```bash
ffmpeg -hide_banner -y -nostdin \
    -i "$VIDEO_MP4" \
    -ss "$AUDIO_LEAD_SEC" \
    -i "$AUDIO_M4A" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a copy \
    -shortest \
    -movflags +faststart \
    "$AV_MP4"
```

这里没有重新编码：

```text
Stream #0:0 -> #0:0 (copy)
Stream #1:0 -> #0:1 (copy)
```

也就是说：

```text
视频轨继续使用实验24自研 muxer 生成的 H.264 MP4 时间轴；
音频轨使用 FFmpeg 采集编码后的 AAC M4A 时间轴；
最终 FFmpeg 只负责把两个已有轨道合成到同一个 MP4 容器中。
```

---

## 9. 关于音视频同步的边界说明

实验25完成了文件级音视频时间轴对齐，但不能夸大为严格唇音同步。

当前同步策略是：

```text
1. 音频先启动；
2. 视频稍后启动；
3. 记录 AUDIO_START_NS 和 VIDEO_START_NS；
4. 计算 audio_lead_sec；
5. 最终 mux 时裁掉音频开头多录部分。
```

这种方式可以保证：

```text
1. 双轨 MP4 时长接近；
2. 播放器按合法时间戳播放；
3. 不会因为 timestamp unset 或 DTS 异常导致音画漂移；
4. 120 秒测试中无明显容器级同步问题。
```

但它还不能严格保证：

```text
真实画面事件时间 == 真实声音采样时间。
```

原因是：

```text
AUDIO_START_NS 不一定等于第一批真实 PCM 样本进入 ALSA 的时间；
VIDEO_START_NS 不一定等于第一帧真实图像曝光或 DQBUF 的时间；
当前视频 PTS 仍然主要按 frame_id / fps 生成；
音频和视频暂未统一使用同一个采集层时间戳。
```

更严谨的后续方案应该是：

```text
视频侧：使用 V4L2 buffer timestamp 或 DQBUF monotonic 时间；
音频侧：使用 ALSA sample counter / timestamp；
共同归一到 record_start_us；
然后分别写入 video_pts_us 和 audio_pts_us。
```

因此文档和简历中建议表述为：

```text
实现了 H.264 视频轨与 AAC 音频轨的双轨 MP4 录像，
通过同步启动与 audio_lead_sec 裁剪方式完成初步音视频时间轴对齐；
120 秒测试中双轨时长接近，解码无错误，未出现 timestamp unset、Non-monotonous DTS、xrun 等异常。
```

不要写成：

```text
实现了严格唇音同步。
```

---

## 10. 实验25最终结论

```text
实验25：通过。
```

本实验在实验24“实时检测 H.264 + PTS CSV + 自研 MP4 MUX”的基础上，进一步接入 ALSA `hw:2,0` 实时音频采集与 FFmpeg AAC 编码，完成了 H.264 视频轨 + AAC 音频轨的本地双轨 MP4 录像。

最终 3600 帧 / 约 120 秒长测结果：

```text
1. 视频检测与异步 MPP 编码成功；
2. async_encoded_frames = 3600；
3. async_encode_failures = 0；
4. async_drop_frames = 0；
5. wall_fps = 29.980；
6. PTS CSV 行数 = 3600；
7. MP4 视频 packet 数 = 3600；
8. 音频轨为 AAC LC，48000Hz，stereo；
9. 最终 MP4 同时包含 H.264 视频轨与 AAC 音频轨；
10. ffmpeg 解码验证无错误；
11. 未出现 xrun、timestamp unset、Non-monotonous DTS、decode error 等异常。
```

说明当前项目已经具备：

```text
实时摄像头采集、
RGA 图像转换、
RKNN YOLO11 实时检测、
异步 MPP H.264 编码、
编码端 PTS 记录、
自研 MP4 视频封装、
ALSA 音频采集、
AAC 编码、
H.264 + AAC 双轨 MP4 本地录像能力。
```

---

## 11. 当前项目阶段性状态

到实验25为止，当前项目已经形成两条完整能力线。

### 11.1 实时预览线

```text
V4L2 摄像头
    ↓
RGA
    ↓
RKNN YOLO11
    ↓
异步 MPP H.264
    ↓
FFmpeg + ALSA AAC
    ↓
MediaMTX
    ↓
RTSP 双轨预览
```

### 11.2 本地录像线

```text
V4L2 摄像头
    ↓
RGA
    ↓
RKNN YOLO11
    ↓
异步 MPP H.264
    ↓
PTS CSV
    ↓
自研 MP4 视频 MUX
    ↓
ALSA AAC 音频
    ↓
H.264 + AAC 双轨 MP4 文件
```

这说明当前工程已经不再是单纯 RKNN Demo 或摄像头检测 Demo，而是一个比较完整的 RK3588 端侧 AI 音视频系统闭环。

---

## 12. 后续实验建议

实验25之后，如果继续推进，建议进入实验26。

建议实验名称：

```text
26_av_sync_timestamp_ground_truth
```

实验26目标：

```text
1. 视频侧记录 V4L2 DQBUF timestamp；
2. 音频侧记录 ALSA sample timestamp / sample counter；
3. 将音频和视频统一到同一个 monotonic 时间轴；
4. 输出 av_sync_report.csv；
5. 统计 first_audio_ts、first_video_ts、duration_diff、drift_ppm；
6. 做拍手测试，估计真实音画 offset；
7. 为严格唇音同步提供验证依据。
```

实验26不是为了证明“能 mux”，而是为了从文件级同步进一步推进到采集层同步。


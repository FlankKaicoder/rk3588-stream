# 实验26：基于采集层时间戳的音视频同步验证与 MP4 封装

> 项目：`rk3588_ai_stream`  
> 平台：LubanCat / RK3588  
> 主链路：V4L2 + RGA + RKNN + MPP + ALSA + AAC + FFmpeg + MP4  
> 实验目标：将实验25中“基于进程启动时间差的音频裁剪”升级为“基于 V4L2 / ALSA 采集层时间戳的音视频同步”。

---

## 1. 实验背景

实验25已经完成了 H.264 + AAC 双轨 MP4 录制：

- 视频侧：V4L2 摄像头采集 + RGA 预处理 + RKNN YOLO11 推理 + 画框 + MPP H.264 编码；
- 音频侧：ALSA 采集 + AAC 编码；
- 封装侧：先生成视频 MP4 和音频 M4A，再通过 FFmpeg 合成最终 AV MP4。

实验25的核心问题在于：

```text
音频裁剪依据主要来自脚本层面的进程启动时间差，
而不是来自摄像头和声卡的真实采集时间戳。
```

这种方案可以让文件层面的音视频时长大致一致，但不能严格证明“唇音同步”。如果要证明更可靠的同步，需要知道：

```text
第一帧视频真正是在什么时候采集到的；
第一段音频真正是从什么时候开始采集的；
二者是否处于同一个 monotonic 时间轴；
最终 MP4 的视频 PTS 是否对应真实采集时间，而不是简单 frame_id / fps。
```

因此，实验26的目标是补齐这一层证据。

---

## 2. 实验目标

实验26分成几个阶段逐步验证：

| 阶段 | 目标 | 状态 |
|---|---|---|
| 26-0 | 验证 V4L2 / ALSA 是否能提供 monotonic timestamp | 已通过 |
| 26-1 | 验证音频先启动、多录 padding 后，能否按 timestamp 裁剪覆盖完整视频 | 已通过 |
| 26-2b | 在真实异步 MPP 录像程序中输出 V4L2 sync metadata | 已通过 |
| 26-2c | 将 MPP encoder PTS 从 `frame_id / fps` 改成 V4L2 timestamp 派生 PTS | 已通过 |
| 26-3 | 生成 V4L2 timestamp 视频 + ALSA timestamp 裁剪音频的 H.264/AAC MP4 | 已通过 |
| 性能复核 | 确认 26-3 在 performance 模式下仍可接近 30FPS | 已通过 |

---

## 3. 关键概念说明

### 3.1 旧视频 PTS 方案

实验23、24、25中，视频 PTS 主要按帧号生成：

```cpp
pts_us = frame_id * 1000000 / fps;
```

这种做法的前提是：

```text
程序确实稳定处理 30FPS，且没有跳帧。
```

如果实际处理速度低于 30FPS，或者 V4L2 sequence 已经出现跳帧，那么这种 PTS 会把真实时间轴压短。例如：

```text
真实世界经过 5.36 秒，
但 120 帧按 30FPS 只会被写成约 4 秒。
```

这会导致 MP4 里的视频时间轴不再代表真实采集时间。

### 3.2 新视频 PTS 方案

实验26-2c后，视频 PTS 改为：

```cpp
enc_frame.pts_us = exp26_video_sync_pts_us;
```

其中：

```text
exp26_video_sync_pts_us = (当前帧 V4L2 timestamp - 第一帧 V4L2 timestamp) / 1000
```

也就是说，视频 MP4 的时间轴直接来自 V4L2 buffer timestamp。

这样做的好处是：

```text
程序实际 30FPS，MP4 就表现为接近 30FPS；
程序实际 22FPS，MP4 就如实表现为约 22FPS；
不会再用 frame_id / 30 强行伪造时间轴。
```

### 3.3 音频同步方案

音频侧通过 ALSA timestamp 估算音频流起点：

```text
audio_stream_start_est_ns = alsa_htstamp_ns - total_frames / sample_rate
```

然后与第一帧视频的 V4L2 timestamp 做差：

```text
audio_trim_s = first_video_v4l2_ts_ns - audio_stream_start_est_ns
```

最终对 PCM 音频执行：

```bash
atrim=start=${audio_trim_s}:duration=${video_duration}
asetpts=PTS-STARTPTS
```

再编码 AAC，与视频 MP4 合成双轨 MP4。

---

## 4. 实验26-0：V4L2 / ALSA 时间戳探针

### 4.1 实验目的

确认 RK3588 当前摄像头和声卡是否能提供可用于同步的 monotonic timestamp。

### 4.2 结果摘要

输出目录：

```text
output/exp26_0_av_ts_probe_60s_20260703_230156
```

关键结果：

```text
video_rows=1800
audio_chunks=2813
video_ref=v4l2_ts_ns
audio_ref=alsa_htstamp_ns
first_audio_minus_video_ms=-306.964
video_duration_s=59.967323
audio_sample_duration_s=60.010667
drift_ppm=722.788
video_interval_avg_ms=33.334
video_interval_min_ms=33.166
video_interval_max_ms=33.877
expected_video_interval_ms=33.333
```

程序返回码：

```text
video_rc=0
audio_rc=0
```

异常检查：

```text
audio_ts.log: 空
video_ts.log: 空
```

### 4.3 结果解释

视频侧结果很好：

```text
V4L2 buffer.timestamp 类型为 MONOTONIC；
DQBUF 时间和 V4L2 timestamp 的差值通常只有 0.1ms 左右；
视频帧间隔接近 33.33ms。
```

音频侧也能拿到 ALSA htimestamp，并且程序正常退出。

`first_audio_minus_video_ms=-306.964` 表示音频第一段有效时间戳比视频第一帧早约 307ms。这个现象符合脚本设计，因为实验中是先启动音频，再延迟启动视频。

这一轮中 `drift_ppm=722.788` 不能直接理解成真实漂移，原因是脚本中 `video_duration_s` 用的是“最后一帧时间戳 - 第一帧时间戳”，少算了最后一帧的显示时长；同时音频按 period 读取，尾部也会存在一个 period 内的超出量。因此后续需要修正分析口径。

### 4.4 结论

实验26-0证明：

```text
V4L2 和 ALSA 都能提供可用的 monotonic 时间戳；
后续可以使用采集层时间戳构建同步策略。
```

---

## 5. 实验26-1：音频 padding + timestamp 裁剪验证

### 5.1 实验目的

验证在音频先启动、并额外多录一段 padding 的情况下，按真实时间戳裁掉音频开头后，剩余音频是否仍然能覆盖完整视频。

### 5.2 结果摘要

输出目录：

```text
output/exp26_1_av_ts_probe_padded_audio_60s_pad2s_20260703_231220
```

关键结果：

```text
video_rows=1800
audio_chunks=11625
video_ref=v4l2_ts_ns
audio_ref=alsa_htstamp_ns
first_audio_minus_video_ms=-319.087
audio_trim_s=0.319087
video_nominal_duration_s=60.000000
video_ts_first_to_last_s=59.967327
video_ts_effective_duration_s=60.000660
audio_sample_duration_s=62.000000
audio_after_trim_s=61.680913
audio_tail_margin_s=1.680913
RESULT=PASS_AUDIO_CAN_COVER_FULL_VIDEO_AFTER_TRIM
```

程序返回码：

```text
video_rc=0
audio_rc=0
```

异常检查为空。

### 5.3 结果解释

本轮音频采集 62 秒，视频采集 60 秒。音频比视频早约 319ms 开始，因此裁掉前：

```text
audio_trim_s = 0.319087s
```

裁剪后，剩余音频仍有：

```text
audio_after_trim_s = 61.680913s
```

相对于 60 秒视频，尾部余量：

```text
audio_tail_margin_s = 1.680913s
```

因此，多录 2 秒音频 padding 的策略是可行的。

### 5.4 结论

实验26-1证明：

```text
音频先启动 + 多录 padding + 按采集层 timestamp 裁剪，
可以保证裁剪后音频覆盖完整视频。
```

---

## 6. 实验26-2b：真实录像程序输出 V4L2 sync metadata

### 6.1 实验目的

将 V4L2 采集层 timestamp 接入真实的异步 MPP 录像程序 `main_exp21_detect_mpp_encode_async.cpp`，额外输出：

```text
<output_h264>.sync_meta.csv
```

记录每一帧的真实采集时间戳。

### 6.2 新增字段

`sync_meta.csv` 字段如下：

```text
frame_id
v4l2_sequence
v4l2_ts_ns
first_video_v4l2_ts_ns
video_sync_pts_us
encoder_pts_us
encoder_pts_minus_sync_pts_us
v4l2_flags
```

其中：

```text
v4l2_ts_ns：当前帧 V4L2 buffer.timestamp；
first_video_v4l2_ts_ns：第一帧 V4L2 timestamp；
video_sync_pts_us：以第一帧为 0 点归一化的视频真实采集 PTS；
encoder_pts_us：当前写给 MPP encoder 的 PTS；
encoder_pts_minus_sync_pts_us：编码器 PTS 与真实采集 PTS 的差值。
```

### 6.3 结果摘要

最终成功输出目录：

```text
output/exp26_2b_sync_meta_120f_linepatch_20260704_155738
```

关键结果：

```text
rows=120
first_frame_id=0
last_frame_id=119
first_video_sync_pts_us=0
last_video_sync_pts_us=5367225
first_encoder_pts_us=0
last_encoder_pts_us=3966666
bad_frame_id=0
bad_v4l2_ts_monotonic=0
bad_sync_pts_monotonic=0
encoder_minus_sync_min_us=-1400559
encoder_minus_sync_max_us=0
encoder_minus_sync_last_us=-1400559
v4l2_interval_avg_ms=45.103
v4l2_interval_min_ms=33.236
v4l2_interval_max_ms=66.750
RESULT=PASS_SYNC_META_VALID
```

### 6.4 重要发现：旧 PTS 方案会压缩真实时间轴

这一轮发现：

```text
真实 V4L2 时间轴：120 帧跨度约 5.367 秒；
旧 encoder PTS：120 帧跨度约 3.967 秒。
```

原因是旧方案仍然使用：

```cpp
enc_frame.pts_us = frame_id * 1000000 / 30;
```

而当前程序实际处理速度只有约 21.6FPS，因此 V4L2 sequence 出现跳帧：

```text
frame_id=119 时，v4l2_sequence=161
```

这说明摄像头真实已经产生到第 161 帧，而程序只处理并编码了 120 帧。旧的 `frame_id / 30` PTS 会把真实时间轴压短。

### 6.5 结论

实验26-2b证明：

```text
真实录像程序已经可以输出 V4L2 sync_meta.csv；
同时证明旧的 frame_id / fps PTS 方案在掉帧或低于 30FPS 时不可靠。
```

---

## 7. 实验26-2c：MPP encoder PTS 改为 V4L2-derived PTS

### 7.1 实验目的

将 MPP encoder PTS 从：

```cpp
enc_frame.pts_us = frame_id * 1000000 / mpp_fps;
```

改为：

```cpp
enc_frame.pts_us = exp26_video_sync_pts_us;
```

也就是使用真实 V4L2 采集时间戳派生的视频 PTS。

### 7.2 结果摘要

输出目录：

```text
output/exp26_2c_v4l2_pts_120f_20260704_160134
```

`.pts.csv` 关键结果：

```text
frame_id,input_pts_us,mpp_packet_pts_us,mpp_packet_dts_us,pts_match,...
0,0,0,0,1,...
1,33841,33841,0,1,...
2,67195,67195,0,1,...
...
119,5333816,5333816,0,1,...
```

`sync_meta.csv` 关键结果：

```text
frame_id,v4l2_sequence,v4l2_ts_ns,first_video_v4l2_ts_ns,video_sync_pts_us,encoder_pts_us,encoder_pts_minus_sync_pts_us
0,0,...,0,0,0
1,1,...,33841,33841,0
2,2,...,67195,67195,0
...
119,160,...,5333816,5333816,0
```

MP4 ffprobe 结果：

```text
Duration: 00:00:05.37
Video: h264, 1280x720, 2797 kb/s, 22.36 fps
r_frame_rate=30/1
avg_frame_rate=120000000/5367149
time_base=1/1000000
duration=5.367149
nb_frames=120
```

### 7.3 结果解释

这轮验证了：

```text
input_pts_us == mpp_packet_pts_us == video_sync_pts_us
encoder_pts_minus_sync_pts_us = 0
```

也就是说，MPP packet 的 PTS 已经和 V4L2 真实采集时间轴一致。

MP4 duration 变成约 5.367 秒，不再是旧的 4 秒。这是正确结果，因为本轮实际处理速度低于 30FPS，且 V4L2 sequence 有跳帧。新方案如实反映真实采集时间轴。

### 7.4 结论

实验26-2c证明：

```text
可以将 V4L2 采集层 timestamp 直接作为 MPP encoder PTS，
并通过实验24的自研 MP4 muxer 写入 MP4 时间轴。
```

---

## 8. 实验26-3：V4L2 timestamp 视频 + ALSA timestamp 音频双轨 MP4

### 8.1 实验目的

构建完整 AV MP4 同步链路：

```text
视频：V4L2 timestamp → MPP packet PTS → video MP4
音频：ALSA timestamp → audio_trim_s → PCM 裁剪 → AAC
封装：video MP4 + trimmed AAC → H.264/AAC MP4
```

### 8.2 新增音频采集程序

新增程序：

```text
src/main_exp26_alsa_pcm_capture_ts.cpp
```

功能：

```text
1. 使用 ALSA 采集 S16_LE PCM；
2. 保存原始 PCM 文件；
3. 同步保存 audio_ts.csv；
4. 每个 chunk 记录 ALSA htimestamp、total_frames、audio_stream_start_est_ns 等信息。
```

`audio_ts.csv` 关键字段：

```text
chunk_id
read_before_ns
read_after_ns
alsa_htstamp_ns
frames_read
total_frames
audio_end_pts_us
audio_stream_start_est_ns
read_ms
avail_frames
delay_frames
```

### 8.3 第一次 300f 结果：功能通过，但性能状态未上来

输出目录：

```text
output/exp26_3_av_mp4_v4l2_alsa_ts_300f_20260704_160722
```

关键结果：

```text
FRAMES=300
AUDIO_DURATION=25
AUDIO_TRIM=0.379841
VIDEO_DURATION=13.134000
```

同步计划：

```text
first_video_v4l2_ts_ns=4336804077000
audio_stream_start_est_ns=4336424236465
audio_trim_s=0.379841
video_duration_s=13.134000
audio_sample_duration_s=25.002667
audio_after_trim_s=24.622826
audio_tail_margin_s=11.488826
RESULT=PASS_AUDIO_COVERS_VIDEO
```

最终 AV MP4：

```text
Video: h264, 1280x720, duration=13.133876, nb_frames=300
Audio: aac, 48000 Hz, stereo, duration=13.134000, nb_frames=617
Format duration=13.156000
```

异常检查为空。

但是本轮视频性能只有：

```text
wall_fps=22.569
avg_model_total_ms=37.207
avg_total_ms=44.210
```

因此，虽然同步方案通过，但实际处理速度低于 30FPS。

### 8.4 性能问题分析

随后对视频-only 链路重新设置 performance governor 后复测：

```text
output/exp26_perf_check_video_only_300f_20260704_161400
```

结果：

```text
wall_fps=29.764
avg_model_total_ms=27.574
avg_total_ms=33.564
async_drop_frames=0
async_encode_failures=0
```

说明低帧率不是实验26新增 timestamp 或音频采集导致的，而是当时板端性能状态未恢复到 performance 模式，导致 RKNN 推理耗时从约 27ms 上升到约 37ms。

### 8.5 performance 模式下重新运行 26-3

重新设置 performance 后，再次运行 26-3 的 300f 验证，结果：

```text
output/exp26_3_av_mp4_v4l2_alsa_ts_300f_20260704_161505
```

关键性能：

```text
frames=300
wall_fps=29.761
avg_select_ms=1.223
avg_dqbuf_ms=0.003
avg_rga_nv12_to_rgb=1.749
avg_model_total_ms=27.432
avg_draw_ms=0.437
avg_rga_rgb_to_nv12=2.539
avg_mpp_queue_push=0.159
avg_qbuf_ms=0.029
avg_total_ms=33.573
async_encoded_frames=300
async_encode_failures=0
async_drop_frames=0
```

异常检查为空：

```text
video_record.log: 空
audio_capture.log: 空
video_mux.log: 空
ffmpeg_audio_trim_encode.log: 空
ffmpeg_av_mux.log: 空
ffmpeg_decode_check.log: 空
```

### 8.6 结论

实验26-3证明：

```text
V4L2 timestamp 视频 PTS + ALSA timestamp 音频裁剪的完整 AV MP4 方案可行；
在 performance 模式下，该方案仍可接近 30FPS；
新增 timestamp 记录和音频同步处理没有破坏主链路性能。
```

---

## 9. 本次源码和脚本改动

### 9.1 修改的已有文件

#### `src/main_exp21_detect_mpp_encode_async.cpp`

主要修改：

1. 新增 `exp26_timeval_to_ns()`，将 V4L2 `timeval` 转成 ns；
2. 扩展 `Exp21EncFrame`，增加：

```cpp
int64_t v4l2_ts_ns;
int64_t video_sync_pts_us;
uint32_t v4l2_sequence;
uint32_t v4l2_flags;
```

3. DQBUF 后读取：

```cpp
buf.timestamp
buf.sequence
buf.flags
```

4. 新增：

```text
<output_h264>.sync_meta.csv
```

5. 将 encoder PTS 改为：

```cpp
enc_frame.pts_us = exp26_video_sync_pts_us;
```

### 9.2 新增文件

#### `src/main_exp26_alsa_ts_probe.cpp`

用于 26-0 / 26-1，采集 ALSA timestamp，不保存 PCM。

#### `src/main_exp26_v4l2_ts_probe.cpp`

用于 26-0 / 26-1，采集 V4L2 timestamp。

#### `src/main_exp26_alsa_pcm_capture_ts.cpp`

用于 26-3，采集 PCM 文件并同步输出 `audio_ts.csv`。

#### `scripts/exp26_0_av_timestamp_probe.sh`

用于 26-0，V4L2 / ALSA timestamp 探针。

#### `scripts/exp26_1_av_ts_probe_padded_audio.sh`

用于 26-1，验证音频 padding 裁剪后能否覆盖视频。

#### `scripts/exp26_3_av_mp4_v4l2_alsa_ts.sh`

用于 26-3，完整生成 V4L2 timestamp 视频 + ALSA timestamp 音频的 AV MP4。

### 9.3 建议脚本固定 performance 模式

为了避免板子重启或频率状态变化导致帧率波动，建议在 26-3 脚本开头固定加入：

```bash
echo "========== set performance mode =========="
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance | sudo tee "$g" >/dev/null || true
done

export RGA_LOG_LEVEL=0
export RGA_DEBUG=0
```

---

## 10. 最终结论

实验26相比实验25的核心提升是：

```text
实验25：
使用进程启动时间差估算 audio_lead_sec，属于脚本层粗同步。

实验26：
使用 V4L2 / ALSA 采集层 monotonic timestamp，
让视频 PTS 和音频裁剪都建立在真实采集时间轴上。
```

实验26已经证明：

```text
1. V4L2 buffer.timestamp 可用，并且是 MONOTONIC；
2. ALSA htimestamp 可用，可以估算音频采集起点；
3. 音频先启动 + padding + timestamp 裁剪可以覆盖完整视频；
4. 真实录像程序可以输出 sync_meta.csv；
5. MPP encoder PTS 可以改为 V4L2 timestamp 派生 PTS；
6. 自研 MP4 muxer 可以写入真实采集时间轴；
7. 最终可生成 H.264 + AAC 双轨 MP4；
8. 在 performance 模式下，300f 链路仍可接近 30FPS。
```

因此，实验26的阶段性结论是：

```text
RK3588 项目已经从“文件时长对齐”升级为“采集层时间戳驱动的音视频同步封装”。
```

---

## 11. 当前限制和后续建议

### 11.1 当前限制

1. 当前已经验证 300f，尚未在本轮对话中提供 1800f / 60s 级别的最终 26-3 结果；
2. 音频起点使用多个 `audio_stream_start_est_ns` 的中位数估算，仍属于工程可用方案，不是专业音频硬件级同步；
3. 当前 ALSA AAC 编码仍通过 FFmpeg 完成，音频不是在 C++ 主程序内直接 AAC 编码；
4. 当前同步验证主要基于 timestamp 和 duration，还没有做 clap test / 声画事件级人工验证；
5. 如果板端 governor / 频率状态不稳定，RKNN 推理耗时会从约 27ms 上升到约 37ms，导致实际帧率下降。

### 11.2 建议补充实验

建议继续做：

```bash
./scripts/exp26_3_av_mp4_v4l2_alsa_ts.sh \
  1800 \
  1280 \
  720 \
  30 \
  hw:2,0 \
  48000 \
  2 \
  256 \
  20 \
  10
```

目标结果：

```text
wall_fps ≈ 29~30
video duration ≈ 60s
audio duration ≈ video duration
async_drop_frames = 0
async_encode_failures = 0
abnormal 为空
```

如果 1800f 也通过，则实验26可以作为项目中的正式“采集层时间戳音视频同步录制”阶段结果。

---

## 12. 可用于简历或项目总结的表述

可以写成：

```text
在 RK3588 端侧实时 AI 音视频系统中，实现基于 V4L2 / ALSA 采集层 monotonic timestamp 的音视频同步录制方案。视频侧将 V4L2 buffer timestamp 归一化后写入 MPP H.264 packet PTS，并通过自研 libavformat MP4 muxer 保留真实采集时间轴；音频侧基于 ALSA htimestamp 估算采集起点，对 PCM 执行时间戳驱动裁剪后编码 AAC，最终合成 H.264/AAC 双轨 MP4。解决了原先依赖进程启动时间估算音频裁剪的问题，并在 performance 模式下验证 1280x720 YOLO11 检测、画框、H.264 编码与 AV 封装链路可接近 30FPS 运行。
```

---

## 13. 实验结论一句话

```text
实验26完成了从“按帧号假定 30FPS”到“按采集层真实 timestamp 生成视频 PTS 与裁剪音频”的升级，是项目音视频同步录制链路的重要收口实验。
```

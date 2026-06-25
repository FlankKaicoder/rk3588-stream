# 实验24：基于编码端 PTS 的 MP4 MUX 与实时检测录像实验记录

> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：`24_mp4_mux_timestamp_record`  
> 当前阶段目标：在实验23已经补全 MPP H.264 编码端 PTS 时间戳的基础上，实现基于 `libavformat` 的自研 MP4 MUX，将实时检测得到的 H.264 packet 与 PTS CSV 正确封装为标准 MP4 文件，并通过 `ffprobe` / `ffmpeg` 验证时间戳、帧数、解码和稳定性。

---

## 1. 实验背景

截至实验23，工程已经完成了如下链路：

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
异步 MPP H.264 编码线程
    ↓
H.264 裸流输出
    ↓
PTS CSV 记录
```

实验23解决了一个非常关键的问题：

```text
每一帧进入 MPP 编码器前都有 input_pts_us；
编码后可以从 MppPacket 中读回 mpp_packet_pts_us；
并输出 frame_id / input_pts_us / packet_pts_us / packet_dts_us / packet_size 等信息到 CSV。
```

但是实验23结束后，输出仍然是：

```text
H.264 裸流文件 + PTS CSV
```

也就是说，工程侧已经有了每个编码 packet 对应的时间戳，但这些时间戳还没有真正进入容器文件。

如果继续直接用 FFmpeg 从裸 H.264 自动封装 MP4，例如：

```bash
ffmpeg -f h264 -framerate 30 -i input.h264 -c:v copy output.mp4
```

虽然可以得到 MP4 文件，但 FFmpeg 仍然会提示：

```text
Timestamps are unset in a packet for stream 0.
This is deprecated and will stop working in the future.
Fix your code to set the timestamps properly.
```

这说明裸 H.264 自动封装并没有真正使用工程侧生成的精确 PTS，而是由 FFmpeg 自行根据帧率推断时间戳。

因此实验24的核心目标是：

```text
把实验23生成的 PTS 真正写入 MP4 容器。
```

---

## 2. 实验目标

实验24主要验证以下内容：

```text
1. 验证实验23输出的 H.264 + PTS CSV 是否完整可用于 MP4 MUX；
2. 对比 FFmpeg baseline 裸流封装的 timestamp warning；
3. 编写自研 libavformat MP4 muxer；
4. 从 PTS CSV 中读取每个 packet 的 frame_id / input_pts_us / packet_size；
5. 根据 packet_size 从 H.264 文件中切分每个编码 packet；
6. 从 H.264 header 中解析 SPS / PPS；
7. 构造 MP4 所需的 avcC extradata；
8. 将 Annex-B H.264 packet 转换为 MP4 需要的 AVCC length-prefixed sample；
9. 显式设置 AVPacket.pts / AVPacket.dts / AVPacket.duration；
10. 通过 ffprobe 验证 MP4 packet 数量、PTS、DTS、duration 与 PTS CSV 完全一致；
11. 通过 ffmpeg 解码验证 MP4 文件可正常播放；
12. 进行实时 300f、900f、1800f 检测录像验证。
```

---

## 3. 实验24最终链路

实验24完成后的文件录像链路为：

```text
/dev/video11 摄像头
    ↓
V4L2 mmap 采集 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
YOLO 后处理与检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
异步 MPP H.264 编码
    ↓
H.264 裸流 + PTS CSV
    ↓
自研 libavformat MP4 muxer
    ↓
标准 MP4 文件
    ↓
ffprobe packet timestamp 对齐验证
    ↓
ffmpeg decode 验证
```

最终验证通过的一键链路为：

```text
实时检测 1800 帧 / 约 60 秒
    ↓
H.264 + PTS CSV
    ↓
自研 MP4 MUX
    ↓
realtime_detect_1800f.mp4
```

---

## 4. 实验24关键输出文件

### 4.1 24-0 输出目录

```text
output/exp24_0_mp4_mux_probe/
```

主要文件：

```text
24_0.log
pts_analysis.txt
ffprobe_baseline_mp4.log
ffmpeg_baseline_mux.log
exp24_0_ffmpeg_baseline_30fps.mp4
```

### 4.2 24-1 输出目录

```text
output/exp24_1_mp4_mux_from_pts/
```

主要文件：

```text
exp24_1_pts_mux_300f.mp4
exp24_1_pts_mux_300f.mp4.packets.csv
mux_run.log
pts_compare.txt
ffprobe_mp4_stream.log
ffprobe_packets.csv
```

### 4.3 24-2 输出目录

首次 900f 运行出现一次偶发 timeout：

```text
output/exp24_2_realtime_record_mux_900f_20260625_152537/
```

后续通过 24-2a / 24-2b 诊断和重跑，确认摄像头裸采集与完整链路均可稳定运行。

24-2b 通过目录：

```text
output/exp24_2b_detect_mux_300f_20260625_155909/
output/exp24_2b_detect_mux_900f_20260625_155936/
```

### 4.4 24-3 最终通过目录

```text
output/exp24_3_realtime_mp4_record_1800f_20260625_160150/
```

主要文件：

```text
summary.txt
realtime_detect_1800f.h264
realtime_detect_1800f.h264.pts.csv
realtime_detect_1800f.mp4
profile_1800f.csv
detect_async_mpp.log
mux_run.log
pts_compare.txt
ffprobe_mp4_stream.log
ffprobe_packets.csv
ffmpeg_decode_check.log
abnormal.txt
dmesg_after.log
```

最终 MP4 文件：

```text
output/exp24_3_realtime_mp4_record_1800f_20260625_160150/realtime_detect_1800f.mp4
```

文件大小：

```text
29 MB
```

---

## 5. 实验24-0：环境探测与 FFmpeg baseline

### 5.1 实验目的

24-0 的目的不是完成自研 MUX，而是确认：

```text
1. 实验23输出的 H.264 + PTS CSV 是否完整；
2. 系统是否具备 libavformat / libavcodec / libavutil 开发环境；
3. FFmpeg baseline 直接封装裸 H.264 的表现；
4. 是否仍存在 timestamp warning。
```

### 5.2 PTS CSV 检查结果

使用实验23输出：

```text
output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264
output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264.pts.csv
```

PTS CSV 分析结果：

```text
rows                 : 300
first_frame_id       : 0
last_frame_id        : 299
first_input_pts_us   : 0
last_input_pts_us    : 9966666
estimated_duration_s : 9.999999
pts_match_count      : 300 / 300
bad_count            : 0
packet_size_min      : 4560
packet_size_max      : 166481
packet_size_avg      : 16350.35
dts_unique_first20   : [0]
```

结论：

```text
实验23输出的 frame_id 连续；
input_pts_us 单调递增；
MPP packet pts 与 input_pts 完全一致；
CSV 可以作为 MP4 MUX 的时间戳输入。
```

### 5.3 开发环境检查

FFmpeg / libav 版本与头文件存在：

```text
libavutil      56.51.100
libavcodec     58.91.100
libavformat    58.45.100
/usr/include/aarch64-linux-gnu/libavformat/avformat.h
/usr/include/aarch64-linux-gnu/libavcodec/avcodec.h
/usr/include/aarch64-linux-gnu/libavutil/avutil.h
```

说明当前系统可以编译基于 `libavformat` 的 C++ muxer。

### 5.4 FFmpeg baseline 封装结果

FFmpeg baseline 得到的 MP4 信息：

```text
codec_name=h264
codec_type=video
width=1280
height=720
r_frame_rate=30/1
avg_frame_rate=1000000/33333
time_base=1/1200000
duration=9.999900
nb_frames=300
bit_rate=3924153
```

但存在 warning：

```text
Timestamps are unset in a packet for stream 0.
This is deprecated and will stop working in the future.
Fix your code to set the timestamps properly.
```

### 5.5 24-0 结论

```text
24-0 判定为：部分通过。
```

具体含义：

```text
1. 实验23的 PTS CSV 完整可用；
2. FFmpeg baseline 可以生成 MP4；
3. 但是 baseline 仍然依赖裸流自动推断时间戳；
4. 因此必须进入 24-1，自研 MP4 muxer，显式设置 AVPacket.pts / dts / duration。
```

---

## 6. 实验24-1：自研 libavformat MP4 muxer

### 6.1 实验目的

24-1 的目标是：

```text
读取实验23输出的 H.264 文件和 PTS CSV，
通过自研 C++ 程序封装为 MP4，
并验证 MP4 中每个 packet 的 PTS / DTS 与 CSV 完全一致。
```

### 6.2 新增源码文件

```text
src/main_exp24_mp4_mux_from_pts.cpp
```

### 6.3 新增 CMake target

```text
exp24_mp4_mux_from_pts
```

对应依赖：

```cmake
libavformat
libavcodec
libavutil
```

### 6.4 MUX 程序输入参数

程序用法：

```bash
./build/exp24_mp4_mux_from_pts \
  <input.h264> \
  <input.pts.csv> \
  <output.mp4> \
  <width> \
  <height> \
  <fps>
```

实际调用示例：

```bash
./build/exp24_mp4_mux_from_pts \
  output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264 \
  output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264.pts.csv \
  output/exp24_1_mp4_mux_from_pts/exp24_1_pts_mux_300f.mp4 \
  1280 \
  720 \
  30
```

### 6.5 核心设计

自研 muxer 的关键设计如下。

#### 6.5.1 使用 PTS CSV 切分 H.264 packet

实验23输出的 H.264 文件结构为：

```text
H.264 header / SPS / PPS
    +
packet_0
    +
packet_1
    +
...
    +
packet_N
```

CSV 中有每个 packet 的大小：

```text
packet_size
```

因此可以计算：

```text
header_size = h264_file_size - sum(packet_size)
```

24-1 实测：

```text
h264 file bytes  : 4905143
packet rows      : 300
packet bytes sum : 4905104
header bytes     : 39
```

这与实验23中获取到的 MPP H.264 header 大小一致。

#### 6.5.2 解析 SPS / PPS

MP4 不能只简单保存 Annex-B 裸流。对于 H.264 MP4，需要将 SPS / PPS 写入 `AVCodecParameters.extradata` 中，也就是构造 `avcC`。

24-1 实测：

```text
sps bytes        : 26
pps bytes        : 5
avcc bytes       : 42
```

#### 6.5.3 Annex-B 转 AVCC sample

MPP 输出的 H.264 packet 是 Annex-B 格式：

```text
00 00 00 01 NALU
00 00 01 NALU
```

MP4 中 H.264 sample 需要使用 length-prefixed 格式：

```text
4字节 NALU 长度 + NALU data
4字节 NALU 长度 + NALU data
...
```

因此 muxer 做了以下转换：

```text
Annex-B start code → 4-byte big-endian NALU length
```

同时跳过 sample 内部的 SPS/PPS，因为 SPS/PPS 已经写入 extradata。

#### 6.5.4 显式设置 AVPacket 时间戳

实验23中，`mpp_packet_get_dts()` 返回值恒为 0。由于当前编码链路是低延迟 H.264，没有 B 帧重排序，因此实验24采用：

```text
AVPacket.pts = input_pts_us
AVPacket.dts = input_pts_us
AVPacket.duration = next_input_pts_us - current_input_pts_us
```

最后一帧的 duration 使用：

```text
1000000 / fps
```

当前 30FPS 下：

```text
duration_us ≈ 33333
```

#### 6.5.5 关键帧判断

实验23中发现：

```text
mpp_packet_get_flag() 得到的 intra 信息不可靠。
```

因此实验24不再依赖 MPP packet flag，而是解析 H.264 NAL type：

```text
NAL type 5 = IDR frame
NAL type 7 = SPS
NAL type 8 = PPS
```

MP4 中关键帧通过：

```cpp
pkt.flags |= AV_PKT_FLAG_KEY;
```

### 6.6 24-1 运行结果

```text
input h264       : output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264
pts csv          : output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264.pts.csv
output mp4       : output/exp24_1_mp4_mux_from_pts/exp24_1_pts_mux_300f.mp4
width/height/fps : 1280x720@30
h264 file bytes  : 4905143
packet rows      : 300
packet bytes sum : 4905104
header bytes     : 39
sps bytes        : 26
pps bytes        : 5
avcc bytes       : 42
written packets  : 300
keyframes        : 5
avcc sample bytes: 4905104
exp24 mux success
```

### 6.7 ffprobe 对齐结果

```text
pts_rows        : 300
mp4_packets     : 300
compare_count   : 300
bad_count       : 0
key_packet_count: 5
first_input_pts : 0
last_input_pts  : 9966666
```

首个 packet：

```text
['0', '0.000000', '0', '0.000000', '33333', '0.033333', '116397', 'K_']
```

最后一个 packet：

```text
['9966666', '9.966666', '9966666', '9.966666', '33333', '0.033333', '15913', '__']
```

### 6.8 MP4 stream 信息

```text
codec_name=h264
codec_type=video
width=1280
height=720
r_frame_rate=30/1
avg_frame_rate=100000000/3333333
time_base=1/1000000
duration=9.999999
nb_frames=300
bit_rate=3924083
```

### 6.9 24-1 结论

```text
24-1 判定为：通过。
```

具体结论：

```text
1. 自研 MP4 muxer 可以正确解析 H.264 header；
2. 可以从 PTS CSV 精确切分每个 packet；
3. 可以完成 Annex-B → AVCC 转换；
4. 可以正确构造 avcC extradata；
5. 可以显式写入 AVPacket.pts / dts / duration；
6. ffprobe 看到的 MP4 packet 与 CSV 完全对齐；
7. 24-0 的 Timestamps are unset warning 被解决。
```

---

## 7. 实验24-2：实时检测生成 H.264 + PTS CSV 后自动 MUX

### 7.1 实验目的

24-1 只是使用实验23已有的 300 帧输出进行离线验证。24-2 的目标是重新实时采集、检测、编码，然后再自动调用自研 MP4 muxer：

```text
实时检测
    ↓
异步 MPP 编码
    ↓
H.264 + PTS CSV
    ↓
自研 MP4 muxer
    ↓
MP4
```

### 7.2 首次 900f 运行情况

首次执行 900 帧时，程序在 253 帧处出现：

```text
select timeout at frame=253
```

当次结果：

```text
async_encoded_frames : 253
async_encode_failures: 0
async_drop_frames    : 0
```

但是 MUX 部分仍然成功处理了实际得到的 253 帧：

```text
packet rows      : 253
written packets  : 253
pts_rows         : 253
mp4_packets      : 253
bad_count        : 0
```

结论：

```text
首次 900f 的问题不是 MP4 muxer 失败，而是实时采集链路在第 253 帧后没有继续拿到帧。
```

### 7.3 24-2a：裸 V4L2 采集诊断

为了判断是否是摄像头或 RKISP 状态异常，重新执行最小 V4L2 采集：

```bash
./build/v4l2_dump_nv12 \
  /dev/video11 \
  1280 \
  720 \
  300 \
  /dev/null
```

结果：

```text
frames          : 300
wall_time_ms    : 10047.887
wall_fps        : 29.857
avg_select_ms   : 33.425
avg_dqbuf_ms    : 0.006
avg_write_ms    : 0.006
avg_qbuf_ms     : 0.055
```

dmesg 只有正常的：

```text
rkisp set isp clk
rkcif-mipi-lvds stream start
rockchip-mipi-csi2 stream ON
imx415 s_stream: 1
...
stream OFF
imx415 s_stream: 0
```

没有：

```text
failed
timeout
invalid
VIDIOC error
```

因此 24-2a 结论是：

```text
/dev/video11、IMX415、RKISP、MIPI 当前状态正常；
首次 253 帧 timeout 不能归因于摄像头裸采集链路必然失败。
```

### 7.4 24-2b：300f / 900f 对照重跑

为了确认 timeout 是否稳定复现，执行 300f 和 900f 对照。

#### 7.4.1 300f 结果

```text
DETECT_RC=0
async_encoded_frames : 300
async_encode_failures: 0
async_drop_frames    : 0
wall_fps             : 29.764
avg_total_ms         : 33.557
```

MUX 对齐结果：

```text
pts_rows        : 300
mp4_packets     : 300
compare_count   : 300
bad_count       : 0
key_packet_count: 5
```

#### 7.4.2 900f 结果

```text
DETECT_RC=0
async_encoded_frames : 900
async_encode_failures: 0
async_drop_frames    : 0
wall_fps             : 29.920
avg_total_ms         : 33.385
```

MUX 对齐结果：

```text
pts_rows        : 900
mp4_packets     : 900
compare_count   : 900
bad_count       : 0
key_packet_count: 15
first_input_pts : 0
last_input_pts  : 29966666
```

dmesg 同样只有正常的 stream on/off 和 IMX415 曝光增益日志，没有真正异常。

### 7.5 24-2 结论

```text
24-2 判定为：通过。
```

首次 900f 的 `select timeout at frame=253` 记录为一次偶发状态问题。后续裸采集、300f 完整链路、900f 完整链路均验证通过，因此不再阻塞实验24。

---

## 8. 实验24-3：一键实时检测 MP4 录像验证

### 8.1 实验目的

24-3 的目标是把前面的流程固化为一键脚本：

```text
实时检测 + 异步 MPP 编码
    ↓
H.264 + PTS CSV
    ↓
自研 MP4 MUX
    ↓
ffprobe stream 验证
    ↓
ffprobe packet PTS/DTS 对齐验证
    ↓
ffmpeg decode 验证
    ↓
summary.txt 输出 PASS / FAIL
```

### 8.2 新增脚本

```text
scripts/exp24_3_realtime_mp4_record_validated.sh
```

运行方式：

```bash
./scripts/exp24_3_realtime_mp4_record_validated.sh 1800 1280 720 30
```

含义：

```text
1800 帧
1280x720
30FPS
约 60 秒实时检测录像
```

### 8.3 最终输出目录

```text
output/exp24_3_realtime_mp4_record_1800f_20260625_160150
```

### 8.4 summary.txt 结果

```text
# exp24-3 realtime MP4 record validated

OUT_DIR=output/exp24_3_realtime_mp4_record_1800f_20260625_160150
frames=1800
width=1280
height=720
fps=30

detect_rc=0
async_encoded_frames=1800
async_encode_failures=0
async_drop_frames=0
wall_fps=29.960
avg_total_ms=33.337

pts_rows=1800
mp4_packets=1800
bad_count=0

h264=output/exp24_3_realtime_mp4_record_1800f_20260625_160150/realtime_detect_1800f.h264
pts_csv=output/exp24_3_realtime_mp4_record_1800f_20260625_160150/realtime_detect_1800f.h264.pts.csv
mp4=output/exp24_3_realtime_mp4_record_1800f_20260625_160150/realtime_detect_1800f.mp4
profile_csv=output/exp24_3_realtime_mp4_record_1800f_20260625_160150/profile_1800f.csv

result=PASS
```

### 8.5 PTS 对齐结果

```text
pts_rows        : 1800
mp4_packets     : 1800
compare_count   : 1800
bad_count       : 0
key_packet_count: 30
first_input_pts : 0
last_input_pts  : 59966666
```

首个 MP4 packet：

```text
['0', '0.000000', '0', '0.000000', '33333', '0.033333', '113272', 'K_']
```

最后一个 MP4 packet：

```text
['59966666', '59.966666', '59966666', '59.966666', '33333', '0.033333', '14466', '__']
```

说明：

```text
MP4 内部 packet PTS 与 CSV 中 input_pts_us 完全一致；
DTS 当前按低延迟无 B 帧策略设置为 PTS；
每帧 duration 为约 33333us；
关键帧数量 30，约 2 秒一个关键帧。
```

### 8.6 MP4 stream 信息

```text
codec_name=h264
codec_type=video
width=1280
height=720
r_frame_rate=30/1
avg_frame_rate=1800000000/59999999
time_base=1/1000000
duration=59.999999
nb_frames=1800
bit_rate=4027451
```

format 层 duration：

```text
duration=60.000000
bit_rate=4029872
```

生成 MP4 文件：

```text
-rw-r--r-- 1 cat cat 29M 6月 25 16:02 realtime_detect_1800f.mp4
```

### 8.7 decode 验证

`ffmpeg_decode_check.log` 为空，说明：

```text
ffmpeg -v error -i realtime_detect_1800f.mp4 -f null -
```

没有产生解码错误。

### 8.8 abnormal 验证

`abnormal.txt` 为空，说明没有出现：

```text
select timeout
failed
invalid
non-positive
negative
Timestamps are unset
missing picture
Could not
No such
malformed
deprecated
Segmentation
段错误
Broken pipe
timeout
error
```

### 8.9 dmesg 验证

dmesg 中只有正常日志：

```text
rkisp_hw set isp clk
rkcif-mipi-lvds stream start streaming
rockchip-mipi-csi2 stream ON
imx415 s_stream: 1
imx415 set exposure / analog gain
...
rkcif-mipi-lvds stream start stopping
rockchip-mipi-csi2 stream OFF
imx415 s_stream: 0
rkcif-mipi-lvds stream stopping finished
```

没有摄像头、MIPI、RKISP 的错误。

### 8.10 24-3 结论

```text
24-3 判定为：通过。
```

这是实验24的最终核心成功结果：

```text
60 秒实时 AI 检测 MP4 录像成功；
1800 帧全部编码；
无编码失败；
无丢帧；
MP4 packet 与 PTS CSV 逐帧对齐；
ffmpeg 解码无错误；
无 timestamp warning；
摄像头链路 dmesg 正常。
```

---

## 9. 本次实验涉及的关键程序与脚本

### 9.1 自研 MP4 muxer

```text
src/main_exp24_mp4_mux_from_pts.cpp
```

功能：

```text
1. 读取 H.264 文件；
2. 读取 PTS CSV；
3. 根据 packet_size 切分每个 H.264 packet；
4. 从 header / 前几个 packet 中解析 SPS / PPS；
5. 构造 avcC extradata；
6. 将 Annex-B packet 转换为 AVCC sample；
7. 创建 MP4 container；
8. 写入 H.264 video stream；
9. 设置 AVPacket.pts / dts / duration；
10. 输出 MP4 文件和 packet debug CSV。
```

### 9.2 CMake target

```text
exp24_mp4_mux_from_pts
```

### 9.3 实验脚本

```text
scripts/exp24_0_mp4_mux_probe.sh
scripts/exp24_1_mp4_mux_from_pts.sh
scripts/exp24_2_realtime_record_then_mux.sh
scripts/exp24_2b_detect_mux_with_dmesg.sh
scripts/exp24_3_realtime_mp4_record_validated.sh
```

其中最终推荐保留并复用的是：

```text
scripts/exp24_3_realtime_mp4_record_validated.sh
```

---

## 10. 关键技术点总结

### 10.1 为什么不能只靠 FFmpeg 自动封装裸 H.264？

因为裸 H.264 文件本身没有容器时间戳。FFmpeg 可以根据 `-framerate 30` 生成一个看似可用的 MP4，但会提示：

```text
Timestamps are unset in a packet for stream 0.
```

这说明输入 packet 没有明确的 PTS/DTS。

对于工程系统来说，尤其是后续要做历史录像、回放、Demux/VDEC、音视频同步时，不能依赖外部工具猜时间戳，而应该在编码端维护并写入精确时间戳。

### 10.2 为什么 DTS 现在可以等于 PTS？

当前 MPP H.264 编码链路面向低延迟实时检测：

```text
没有显式启用 B 帧；
编码顺序与显示顺序一致；
实验23中 MPP packet DTS 返回值恒为 0，不可直接使用。
```

因此实验24采用：

```text
DTS = PTS = input_pts_us
```

这是当前阶段合理的工程策略。

如果后续启用 B 帧或重排序编码，就需要重新设计 DTS 逻辑。

### 10.3 为什么需要 Annex-B 转 AVCC？

MPP 输出 H.264 通常是 Annex-B：

```text
start code + NALU
```

而 MP4 中 H.264 sample 通常需要：

```text
length-prefixed NALU
```

同时 SPS/PPS 需要写入 MP4 的 avcC extradata。

因此不能简单把裸 H.264 packet 直接塞进 MP4，需要做格式转换。

### 10.4 为什么要解析 NAL type 判断关键帧？

实验23中发现 MPP packet flag 对 intra 的标记不可靠，因此实验24改为直接解析 H.264 NAL：

```text
NAL type 5 → IDR / keyframe
NAL type 7 → SPS
NAL type 8 → PPS
```

这种方法更接近码流本身，适合后续 MP4 mux、分段录像、关键帧索引等功能。

### 10.5 本实验和实验23的关系

实验23完成的是：

```text
编码端 PTS 元数据生成与 CSV 记录
```

实验24完成的是：

```text
将 PTS 元数据真正写入 MP4 容器
```

两者关系如下：

```text
实验23：frame_id + input_pts_us + packet_pts_us + packet_size
    ↓
实验24：AVPacket.pts + AVPacket.dts + AVPacket.duration
    ↓
MP4 文件可准确记录每帧时间戳
```

---

## 11. 本次实验最终结论

实验24最终完成了 RK3588 实时检测系统从裸 H.264 输出到标准 MP4 文件录像的关键升级。

最终通过结果：

```text
实时检测时长      ：约 60 秒
实时检测帧数      ：1800 帧
输入分辨率        ：1280x720
目标帧率          ：30FPS
实际 wall_fps     ：29.960
平均总耗时        ：33.337 ms / frame
异步编码帧数      ：1800
编码失败          ：0
编码丢帧          ：0
PTS CSV 行数      ：1800
MP4 packet 数     ：1800
PTS 对齐错误      ：0
关键帧数量        ：30
MP4 duration      ：60.000000 s
MP4 文件大小      ：约 29 MB
ffmpeg 解码错误   ：无
abnormal 关键词   ：无
```

因此实验24可以判定为：

```text
PASS
```

---

## 12. 工程意义

本实验完成后，项目能力从：

```text
实时检测 + RTSP 预览
```

进一步扩展为：

```text
实时检测 + 本地 MP4 录像 + 精确时间戳记录
```

这对后续方向非常重要：

```text
1. 历史录像保存；
2. 录像文件回放；
3. 文件级 Demux / VDEC 解码；
4. 关键帧索引；
5. 后续音视频同步；
6. 分段录像；
7. 远程文件管理；
8. 事件触发录像；
9. 边缘 AI 检测结果与视频时间戳绑定。
```

简历或项目表述中，可以把这部分描述为：

```text
实现基于 Rockchip MPP 编码输出的 H.264 时间戳补全与 MP4 封装模块，
通过 libavformat 自研 MP4 muxer，将端侧 AI 检测视频按帧级 PTS/DTS 写入容器，
解决裸 H.264 自动封装 timestamp 缺失问题，完成 720P@30FPS、60s、1800 帧实时检测录像验证，
ffprobe 验证 MP4 packet 与编码端 PTS CSV 逐帧对齐，编码失败和丢帧均为 0。
```

---

## 13. 当前限制与后续方向

### 13.1 当前限制

当前实验24的最终方案是：

```text
先实时生成 H.264 + PTS CSV；
再调用自研 muxer 生成 MP4。
```

也就是说，目前是“检测后自动封装”，不是“边编码边写 MP4”。

这种方式已经足够验证：

```text
编码端 PTS 正确；
MP4 MUX 正确；
MP4 文件可解码；
60 秒实时录像链路稳定。
```

但还没有实现：

```text
1. 编码线程边输出 packet 边写入 MP4；
2. 程序异常退出时 MP4 moov 原子安全落盘；
3. 长时间循环分段录像；
4. 音频 AAC track 与视频 H.264 track 合并为 AV MP4；
5. 检测结果 metadata 与视频时间戳绑定。
```

### 13.2 后续建议实验

后续可以继续设计：

```text
24-4：在线 MP4 muxer，边编码边写 MP4
24-5：异常退出 / SIGINT 下 MP4 trailer 安全写入
25：H.264 + AAC 双轨 MP4 mux
26：按时间分段录像，例如每 60 秒一个 MP4
27：检测事件触发录像，例如检测到 person 后保存前后 N 秒
28：MP4 demux + VDEC 解码回放
29：录像文件管理与远程下载
```

其中最推荐的下一步是：

```text
先做实验25：视频 H.264 + 音频 AAC 双轨 MP4 MUX。
```

原因是实验18已经做过文件级音视频 MUX，实验22已经完成实时 H.264 + AAC RTSP 双轨推流，现在实验24又完成了视频 MP4 封装。把这三部分合起来，就可以形成：

```text
实时检测视频 + 实时音频采集 + AAC 编码 + MP4 双轨录像
```

这比立刻做在线写 MP4 更贴近“完整音视频系统”的目标。

---

## 14. 实验24一句话总结

实验24基于实验23补全的 MPP 编码端 PTS 信息，实现了自研 libavformat MP4 muxer，完成 H.264 Annex-B 到 MP4 AVCC 的封装转换，并通过 720P@30FPS、60 秒、1800 帧实时检测录像验证，确认 MP4 packet 与编码端 PTS CSV 逐帧对齐、无 timestamp warning、无编码失败、无丢帧、可正常解码。

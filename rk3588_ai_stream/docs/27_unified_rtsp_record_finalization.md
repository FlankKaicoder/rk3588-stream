# 实验27：统一 RTSP 推流与本地 MP4 录制工程收尾

> 项目：`rk3588_ai_stream`  
> 平台：LubanCat / RK3588  
> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：统一入口、视频单次编码双输出、音频单次采集双输出、RTSP 与本地 MP4 同时输出、60 秒稳定性验收  
> 最终状态：**通过**

---

## 1. 实验背景

截至实验26，项目已经分别具备以下能力：

```text
视频侧：
V4L2 摄像头采集
    ↓
RGA NV12 ↔ RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
异步 MPP H.264 编码
    ↓
H.264 裸流 + PTS CSV
    ↓
自研 libavformat MP4 MUX

音频侧：
ALSA PCM 采集
    ↓
ALSA htimestamp 探针
    ↓
AAC 编码

网络侧：
H.264 + AAC
    ↓
FFmpeg RTSP MUX
    ↓
MediaMTX
    ↓
VLC / ffprobe 双轨预览

本地录像侧：
H.264 视频 MP4
    +
AAC 音频
    ↓
FFmpeg copy mux
    ↓
H.264 + AAC 双轨 MP4
```

实验26进一步完成了：

```text
1. 读取 V4L2 buffer timestamp；
2. 读取 ALSA htimestamp；
3. 将视频 PTS 从 frame_id / fps 改为 V4L2 timestamp 派生；
4. 将 V4L2 派生 PTS 写入 MPP；
5. 从 MPP packet 中读回 PTS；
6. 根据第一帧 V4L2 时间戳和音频流起点估算值计算音频裁剪量；
7. 生成采集层起点对齐的 H.264 + AAC 双轨 MP4。
```

但是实验26结束后，项目仍然存在最后几个工程缺口：

```text
1. RTSP 和本地 MP4 仍然是两套分散脚本；
2. 缺少统一用户入口；
3. 同时启动两套脚本会竞争 /dev/video11 和 hw:2,0；
4. 需要保证摄像头只采集一次；
5. 需要保证 RKNN 只推理一次；
6. 需要保证 MPP 只编码一次；
7. 需要保证 ALSA 声卡只打开一次；
8. 需要从同一轮采集数据同时生成实时 RTSP 和本地 MP4；
9. 需要进行完整 60 秒稳定性验收。
```

因此实验27不是增加新功能，而是对前26个实验进行最终工程整合与收尾。

---

## 2. 实验目标

实验27的核心目标是实现统一工程入口：

```bash
./scripts/rk3588_ai_stream.sh rtsp   <duration_sec> <stream_path>
./scripts/rk3588_ai_stream.sh record <duration_sec>
./scripts/rk3588_ai_stream.sh both   <duration_sec> <stream_path>
./scripts/rk3588_ai_stream.sh status
./scripts/rk3588_ai_stream.sh stop
```

需要满足：

```text
rtsp：
    实时检测画面 + AAC 音频双轨 RTSP。

record：
    基于 V4L2 / ALSA 采集层时间戳对齐的本地 MP4。

both：
    同一次摄像头采集、同一次推理、同一次 MPP 编码、
    同一次 ALSA 采集，同时输出 RTSP 和本地 MP4。
```

最终验收指标：

```text
1. 摄像头只打开一次；
2. 声卡采集节点只打开一次；
3. 视频采集帧数与 MPP 编码帧数一致；
4. 异步编码失败为 0；
5. 异步编码丢帧为 0；
6. ALSA xrun 为 0；
7. RTSP 中存在 H.264 + AAC 双轨；
8. 本地 MP4 中存在 H.264 + AAC 双轨；
9. 视频 PTS 与 V4L2 派生 PTS 一致；
10. 音频起点按 ALSA htimestamp 对齐；
11. 无 Non-monotonous DTS；
12. 无 Timestamps are unset；
13. 无 Broken pipe；
14. 60 秒链路稳定接近 30FPS。
```

---

## 3. 最终架构

最终采用的架构为：

```text
视频生产侧：
/dev/video11
    ↓
V4L2 mmap 单次采集
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 单次推理
    ↓
YOLO 后处理与检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
异步 MPP 单次 H.264 编码
    ↓
持续增长的普通 H.264 文件
    ├── tail 跟随新增字节 → FFmpeg → RTSP 视频轨
    └── H.264 + PTS CSV → 自研 MP4 MUX → 本地视频 MP4

音频生产侧：
hw:2,0
    ↓
ALSA 单次 PCM 采集 + htimestamp
    ↓
持续增长的普通 PCM 文件
    ├── tail 跟随新增字节 → FFmpeg AAC → RTSP 音频轨
    └── ALSA timestamp CSV → 起点裁剪 → AAC M4A

实时输出：
H.264 视频流 + PCM→AAC 音频流
    ↓
FFmpeg RTSP MUX
    ↓
MediaMTX
    ↓
RTSP H.264 + AAC 双轨流

本地输出：
V4L2 PTS 视频 MP4 + ALSA timestamp 对齐 AAC
    ↓
FFmpeg copy mux
    ↓
H.264 + AAC 双轨 MP4
```

最终使用“持续增长的普通文件”作为生产者与 RTSP 消费者之间的缓冲层，而不是使用同步 FIFO 直接连接。

---

## 4. 相关文件

### 4.1 统一入口

```text
scripts/rk3588_ai_stream.sh
```

支持：

```text
rtsp
record
both
status
stop
help
```

### 4.2 实验27主要脚本

```text
scripts/exp27_2_video_dual_output_rtsp_record.sh
scripts/exp27_3_audio_single_capture_fanout.sh
scripts/exp27_4_both_rtsp_record.sh
scripts/exp27_4b_both_rtsp_record_fixed.sh
scripts/exp27_4c_both_spool_rtsp_record.sh
```

### 4.3 复用程序

```text
build/exp21_detect_mpp_encode_async
build/exp24_mp4_mux_from_pts
build/exp26_alsa_pcm_capture_ts
tools/mediamtx/mediamtx
```

### 4.4 关键源码

```text
src/main_exp21_detect_mpp_encode_async.cpp
src/mpp_h264_encoder.cpp
include/mpp_h264_encoder.hpp
src/main_exp24_mp4_mux_from_pts.cpp
src/main_exp26_alsa_pcm_capture_ts.cpp
```

---

# 5. 实验27-1：统一用户入口

## 5.1 实验目的

首先将已有 RTSP 与本地录像能力包装为统一入口：

```text
rtsp：调用实验22双轨 RTSP 脚本。
record：调用实验26-3基于采集层时间戳的本地 MP4 脚本。
```

使用方式：

```bash
./scripts/rk3588_ai_stream.sh rtsp 10 exp27_rtsp_smoke
./scripts/rk3588_ai_stream.sh record 10
./scripts/rk3588_ai_stream.sh status
./scripts/rk3588_ai_stream.sh stop
```

## 5.2 RTSP入口验证

300帧结果：

```text
frames                  : 300
async_encoded_frames    : 300
async_encode_failures   : 0
async_drop_frames       : 0
wall_fps                : 29.766
```

RTSP轨道：

```text
视频：H.264，1280x720
音频：AAC，48000Hz，双声道
```

结论：

```text
统一 RTSP 入口功能回归通过。
```

需要注意：该 RTSP 分支通过裸 H.264 FIFO 进入 FFmpeg，FFmpeg没有读取视频 PTS CSV，因此此阶段只证明实时双轨功能正常，不宣称 RTSP 严格保留 V4L2 原始 PTS。

## 5.3 record入口验证

300帧结果：

```text
frames                  : 300
async_encoded_frames    : 300
async_encode_failures   : 0
async_drop_frames       : 0
```

时间戳结果：

```text
video_duration          : 10.000527s
audio_duration          : 10.001000s
duration_difference     : 0.000473s
```

最终 MP4：

```text
H.264 1280x720
AAC 48000Hz stereo
video_start_time=0
audio_start_time=0
```

结论：

```text
统一 record 入口通过。
```

## 5.4 阶段结论

27-1完成了统一入口，但 `both` 不能简单并行调用 RTSP 与 record，因为两套脚本会竞争 `/dev/video11` 和 `hw:2,0`。

---

# 6. 实验27-2：视频单次编码双输出

## 6.1 实验目的

验证：

```text
/dev/video11
    ↓
V4L2 + RGA + RKNN
    ↓
单次异步 MPP 编码
    ↓
H.264源FIFO
    ↓ tee
    ├── 本地H.264文件
    └── RTSP H.264 FIFO
```

本阶段音频仍由 FFmpeg 直接从 ALSA 读取，重点只验证视频。

## 6.2 结果

```text
DETECT_RC=0
TEE_RC=0

frames                  : 300
async_encoded_frames    : 300
async_encode_failures   : 0
async_drop_frames       : 0
wall_fps                : 29.763
```

H.264完整性：

```text
PTS CSV rows             : 300
packet_size_sum          : 4,927,207 bytes
H.264 file size          : 4,927,246 bytes
header_plus_other_bytes  : 39 bytes
```

39字节对应 MPP H.264 Header，即 SPS/PPS 等编码头。

RTSP：

```text
H.264 + AAC双轨发布成功
```

结论：

```text
一次MPP编码可以同时服务本地H.264和实时RTSP视频分支。
```

---

# 7. 实验27-3：音频单次采集双输出

## 7.1 实验目的

验证：

```text
ALSA hw:2,0
    ↓
exp26_alsa_pcm_capture_ts单次采集
    ↓
PCM源FIFO
    ↓ tee
    ├── 本地PCM文件
    └── 实时PCM FIFO → FFmpeg AAC
```

FFmpeg不再直接打开声卡，只读取PCM FIFO。

## 7.2 结果

```text
CAPTURE_RC=0
TEE_RC=0
FFMPEG_RC=0
```

数据完整性：

```text
timestamp_rows          : 938
total_frames            : 240128
expected_pcm_size       : 960512 bytes
actual_pcm_size         : 960512 bytes
pcm_size_match          : 1
```

时长：

```text
PCM duration            : 5.002667s
AAC duration            : 5.002000s
duration difference     : 0.000667s
```

设备占用：

```text
/dev/snd/pcmC2D0c 只由 exp26_alsa_pcm_capture_ts 打开
```

FFmpeg输入：

```text
Input #0, s16le, from 'audio_live.fifo'
```

结论：

```text
一次ALSA采集可以同时生成本地PCM和实时AAC分支。
```

---

# 8. 实验27-4：FIFO双输出整合失败

## 8.1 初始设计

```text
视频：MPP输出FIFO → tee → H.264文件 + RTSP视频FIFO
音频：ALSA输出FIFO → tee → PCM文件 + RTSP音频FIFO
FFmpeg：同时读取视频FIFO和音频FIFO → RTSP双轨
```

## 8.2 结果

视频本身完成300帧，但出现：

```text
ALSA xrun at chunk=65
Non-monotonous DTS
SYNC_RESULT=FAIL
```

同步分析：

```text
first_video_v4l2_ts_ns    = 26418269138000
audio_stream_start_est_ns = 26418663218352
audio_lead_s              = -0.394080
```

音频看起来比视频晚约394ms，但实际上是ALSA发生xrun后重新执行 `snd_pcm_prepare()`，导致时间轴不连续。

## 8.3 根因

```text
FFmpeg等待视频输入初始化
    ↓
尚未持续消费音频FIFO
    ↓
音频tee输出阻塞
    ↓
音频tee停止读取ALSA源FIFO
    ↓
ALSA采集线程被反压
    ↓
ALSA buffer溢出
    ↓
xrun
```

结论：

```text
同步FIFO消费者可能反向阻塞生产者。
```

---

# 9. 实验27-4b：调换FFmpeg输入顺序仍失败

## 9.1 修改内容

将FFmpeg输入顺序改成先音频、后视频，同时：

```text
period_frames由256改为1024
去掉音频wallclock timestamp
使用 asetpts=N/SR/TB
```

## 9.2 结果

```text
frames                  : 300
async_encoded_frames    : 286
async_drop_frames       : 14
ALSA xrun               : 1
```

同步结果：

```text
audio_lead_s=-3.814995
SYNC_RESULT=FAIL
```

本地MP4只有：

```text
video_nb_frames=286
```

RTSP出现：

```text
Timestamps are unset in a packet for stream 0
```

## 9.3 根因

调换输入顺序后，阻塞从音频侧转移到视频侧：

```text
FFmpeg先初始化音频
    ↓
等待第二个视频输入
    ↓
视频RTSP FIFO消费不及时
    ↓
video tee阻塞
    ↓
MPP编码线程写输出阻塞
    ↓
有限异步编码队列被填满
    ↓
主线程丢弃14帧
```

## 9.4 关键结论

```text
27-4：视频优先 → 音频生产者被反压。
27-4b：音频优先 → 视频生产者被反压。
```

因此调换FFmpeg输入顺序、增大 `thread_queue_size`、增大ALSA period只能延迟问题，不能消除问题。最终停止使用“同步 tee + FIFO”作为both模式架构。

---

# 10. 实验27-4c：增长文件解耦双输出

## 10.1 最终设计

生产者直接写普通文件：

```text
视频生产者：MPP编码程序 → 持续增长H.264文件
音频生产者：ALSA采集程序 → 持续增长PCM文件
```

RTSP消费者通过：

```bash
tail --pid=<producer_pid> --sleep-interval=0.05 -c +1 -f <growing_file>
```

跟随新增数据。

## 10.2 为什么能够解决问题

以前：

```text
生产者 → FIFO → 消费者
```

消费者停止读取时，FIFO写满，生产者会被直接阻塞。

现在：

```text
生产者 → 普通文件
          ↓
        tail消费者
```

消费者变慢只会让 `tail` 读取变慢，不会阻止生产者继续写普通文件，因此彻底切断RTSP消费者对V4L2、MPP、ALSA生产线程的反压路径。

当前写入带宽约：

```text
H.264约4Mbps       ≈ 0.5MB/s
PCM 1.536Mbps      ≈ 0.192MB/s
合计               ≈ 0.7MB/s
```

对板端存储带宽和Linux页缓存压力较小。

## 10.3 300帧冒烟测试

```text
FINAL_RESULT=PASS_EXP27_4C_BOTH

VIDEO_RC=0
AUDIO_RC=0
FFMPEG_RC=0
MEDIAMTX_RC=0

FRAMES=300
ASYNC_ENCODED=300
ASYNC_FAILURES=0
ASYNC_DROPS=0
WALL_FPS=29.761

XRUN_COUNT=0
RTSP_H264_OK=1
RTSP_AAC_OK=1
SYNC_RESULT=PASS_V4L2_ALSA_ALIGNMENT_PLAN
LOCAL_RESULT=PASS_LOCAL_TIMESTAMP_ALIGNED_AV_MP4
ABNORMAL_HITS=0
```

时间戳结果：

```text
audio_lead_s              = 0.693066
audio_trim_s              = 0.693066
video_duration_s          = 10.000451
audio_duration_s          = 10.000000
duration_delta_s          = 0.000451
```

结论：

```text
300帧短时both模式通过。
```

---

# 11. 60秒1800帧稳定性验收

## 11.1 运行命令

```bash
cd ~/projects/rk3588_ai_stream

./scripts/rk3588_ai_stream.sh stop

AUDIO_LEAD_MS=500 \
AUDIO_PAD_SEC=2 \
./scripts/exp27_4c_both_spool_rtsp_record.sh \
  1280 \
  720 \
  30 \
  1800 \
  hw:2,0 \
  48000 \
  2 \
  256 \
  exp27_4c_both_spool_60s
```

## 11.2 最终结果目录

```text
output/exp27_4c_both_spool_1800f_20260726_233349
```

## 11.3 视频结果

```text
FRAMES                  = 1800
ASYNC_ENCODED           = 1800
ASYNC_FAILURES          = 0
ASYNC_DROPS             = 0
WALL_FPS                = 29.959
```

结论：

```text
60秒内没有编码失败；
没有异步队列丢帧；
链路稳定接近30FPS。
```

## 11.4 音频结果

```text
XRUN_COUNT              = 0
audio_total_frames      = 2,976,000
audio_sample_duration   = 62.000000s
```

结论：

```text
62秒ALSA连续采集无xrun。
```

## 11.5 V4L2 / ALSA起点对齐

```text
first_video_v4l2_ts_ns    = 28172240953000
audio_stream_start_est_ns = 28171558438229
audio_lead_s              = 0.682515
audio_trim_s              = 0.682515
audio_tail_margin_s       = 1.317084
```

解释：音频真实采集起点比第一帧视频早约682.515ms，因此本地录制时裁掉音频开头682.515ms。

视频时间戳检查：

```text
video_sync_rows               = 1800
encoder_pts_delta_bad_rows    = 0
```

说明全部1800帧满足：

```text
V4L2派生PTS = MPP输入帧PTS = MPP输出packet PTS
```

同步计划：

```text
RESULT=PASS_V4L2_ALSA_ALIGNMENT_PLAN
```

## 11.6 本地MP4结果

```text
video_codec            = h264
audio_codec            = aac
video_nb_frames        = 1800
video_start_time       = 0.000000
audio_start_time       = 0.000000
video_duration_s       = 60.000401
audio_duration_s       = 60.000000
duration_delta_s       = 0.000401
```

最终文件：

```text
av_both_v4l2_alsa.mp4
```

文件信息：

```text
分辨率             ：1280x720
视频编码           ：H.264
音频编码           ：AAC
音频采样率         ：48000Hz
音频声道           ：2
视频帧数           ：1800
音频帧数           ：2814
文件大小           ：31,150,796 bytes，约30MB
平均码率           ：4,151,917 bit/s
```

本地验证：

```text
RESULT=PASS_LOCAL_TIMESTAMP_ALIGNED_AV_MP4
```

## 11.7 RTSP结果

```text
RTSP_H264_OK=1
RTSP_AAC_OK=1
```

ffprobe：

```text
Stream 0：H.264，1280x720
Stream 1：AAC，48000Hz，2 channels
```

异常统计：

```text
Non-monotonous DTS    = 0
Timestamps are unset  = 0
Broken pipe           = 0
xrun                   = 0
ABNORMAL_HITS          = 0
```

最终结果：

```text
FINAL_RESULT=PASS_EXP27_4C_BOTH
```

---

# 12. 统一入口接入both模式

## 12.1 修改前备份

```bash
cd ~/projects/rk3588_ai_stream

cp \
  scripts/rk3588_ai_stream.sh \
  "scripts/rk3588_ai_stream.sh.bak_$(date +%Y%m%d_%H%M%S)"
```

## 12.2 both分支

```bash
both)
    duration="${2:-60}"
    stream_path="${3:-rk3588_ai_stream_both}"

    if ! [[ "$duration" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: duration must be a positive integer"
        exit 1
    fi

    frames=$((duration * 30))

    export AUDIO_LEAD_MS="${AUDIO_LEAD_MS:-500}"
    export AUDIO_PAD_SEC="${AUDIO_PAD_SEC:-2}"

    exec ./scripts/exp27_4c_both_spool_rtsp_record.sh \
        1280 \
        720 \
        30 \
        "$frames" \
        hw:2,0 \
        48000 \
        2 \
        256 \
        "$stream_path"
    ;;
```

## 12.3 最终使用方法

### 仅实时RTSP

```bash
./scripts/rk3588_ai_stream.sh rtsp 60 final_rtsp
```

### 仅本地MP4录制

```bash
./scripts/rk3588_ai_stream.sh record 60
```

### 同时RTSP与本地MP4

```bash
./scripts/rk3588_ai_stream.sh both 60 final_both
```

### 查看状态

```bash
./scripts/rk3588_ai_stream.sh status
```

### 停止运行

```bash
./scripts/rk3588_ai_stream.sh stop
```

---

# 13. 最终能力总结

实验27结束后，项目已经具备：

```text
1. 统一用户入口；
2. 单独RTSP模式；
3. 单独本地MP4模式；
4. RTSP + 本地MP4同时输出模式；
5. 摄像头只打开一次；
6. RKNN只推理一次；
7. MPP只编码一次；
8. ALSA只采集一次；
9. 视频实时分支与本地分支共享同一份H.264数据；
10. 音频实时分支与本地分支共享同一份PCM数据；
11. RTSP包含H.264 + AAC双轨；
12. 本地MP4包含H.264 + AAC双轨；
13. 本地视频PTS来自V4L2时间戳；
14. 本地音频起点来自ALSA htimestamp估算；
15. 60秒1800帧无视频丢帧；
16. 62秒音频采集无xrun；
17. RTSP无非单调DTS；
18. RTSP无未设置时间戳警告；
19. 本地MP4可正常解码；
20. 完整链路稳定接近30FPS。
```

最终系统：

```text
同一次运行
├── /dev/video11只打开一次
├── hw:2,0只打开一次
├── RKNN只执行一次
├── MPP只编码一次
├── 输出实时H.264 + AAC双轨RTSP
└── 输出采集层时间戳起点对齐的H.264 + AAC双轨MP4
```

---

# 14. 技术边界与准确表述

## 14.1 本地MP4已实现的同步

可以表述为：

```text
基于V4L2和ALSA monotonic采集层时间戳完成音视频起点对齐；
视频PTS由V4L2 buffer timestamp派生并写入MPP与MP4；
音频通过ALSA htimestamp估算流起点，并依据起点差进行裁剪。
```

已经验证：

```text
1. V4L2 PTS → MPP输入PTS → MPP packet PTS一致；
2. 60秒1800帧时间戳传递无异常；
3. ALSA采集无xrun；
4. 本地MP4双轨起点均为0；
5. 音视频轨时长差为0.401ms；
6. 最终文件可正常解码。
```

## 14.2 尚未实现长期动态漂移补偿

当前没有实现：

```text
实时周期性测量音频时钟与视频时钟偏差
    ↓
动态计算drift
    ↓
动态重采样
    ↓
插入或丢弃少量音频采样
```

本地MP4音频通过“起点裁剪 + 按视频时长atrim”生成，因此准确说法是：

```text
完成采集层起点对齐与60秒连续性验证。
```

不应表述为：

```text
已经实现无限时长下的动态漂移补偿。
```

## 14.3 RTSP的时间戳边界

RTSP分支是：

```text
增长H.264文件 + 增长PCM文件
    ↓
tail跟随读取
    ↓
FFmpeg重新生成实时流时间轴
```

FFmpeg没有直接读取视频PTS CSV和音频timestamp CSV，因此RTSP可以证明：

```text
1. 双轨实时推流稳定；
2. 无xrun；
3. 无非单调DTS；
4. 无未设置时间戳警告；
5. 无消费者反压生产者。
```

但不应宣称：

```text
RTSP严格保留V4L2/ALSA采集层原始PTS。
```

---

# 15. 实验结论

实验27最终完成了前26个实验的工程收尾。

最终结论：

```text
1. 统一入口已经形成；
2. rtsp、record、both三种运行模式均可用；
3. 视频和音频生产者均只运行一份；
4. 同一次采集数据可以同时服务实时预览和本地录像；
5. 同步FIFO双分发方案存在消费者反压问题；
6. 调换FFmpeg输入顺序不能消除反压，只会转移阻塞；
7. 使用持续增长普通文件作为spool缓冲层后，
   成功切断RTSP消费者对V4L2、MPP、ALSA生产线程的反压；
8. 300帧短测通过；
9. 1800帧60秒稳定性测试通过；
10. 视频1800帧全部编码，无失败、无丢帧；
11. ALSA连续采集62秒无xrun；
12. RTSP H.264 + AAC双轨正常；
13. 本地H.264 + AAC MP4正常；
14. 本地视频PTS与V4L2时间戳保持一致；
15. 本地音频根据ALSA htimestamp完成起点裁剪；
16. 最终系统达到约29.959FPS。
```

实验27可以正式收尾。

---

# 16. 项目最终工程表述建议

## 16.1 技术总结

```text
基于RK3588实现端侧AI音视频实时检测与录制系统，使用V4L2 mmap采集IMX415摄像头NV12帧，RGA完成格式转换，RKNN部署YOLO11模型，自研Rockchip MPP H.264编码封装及异步编码队列；通过MediaMTX输出H.264/AAC双轨RTSP，并使用libavformat实现基于V4L2 PTS的H.264 MP4封装。基于ALSA htimestamp估算音频采集起点，完成本地MP4音视频起点对齐。设计增长文件spool层解耦实时推流消费者与采集/编码生产者，实现单次视频采集、单次模型推理、单次MPP编码和单次ALSA采集，同时输出RTSP与本地MP4。60秒测试达到29.959FPS，1800帧无编码失败、无队列丢帧、无ALSA xrun。
```

## 16.2 简历精简表述

```text
• 基于V4L2、RGA、RKNN与Rockchip MPP构建RK3588端侧AI视频链路，完成720P YOLO11实时检测、异步H.264硬件编码及RTSP双轨推流，稳定运行约30FPS。
• 封装MPP编码模块并维护V4L2派生PTS，基于libavformat实现Annex-B到AVCC转换、SPS/PPS extradata构造及MP4 packet级时间戳写入。
• 基于ALSA htimestamp估算音频流起点，完成H.264/AAC本地双轨MP4起点对齐；设计增长文件spool层消除RTSP消费者对V4L2/MPP/ALSA生产线程的反压。
• 统一rtsp、record、both运行入口，实现单次摄像头采集、单次RKNN推理、单次MPP编码和单次ALSA采集同时服务实时预览与本地录像；60秒测试1800帧无丢帧、无xrun，平均29.959FPS。
```

---

## 17. 参考实验文档

```text
docs/21_integrated_async_mpp_rtsp_summary.md
docs/22_av_async_mpp_rtsp.md
docs/23_mpp_pts_timestamp.md
docs/24_mp4_mux_timestamp_record.md
docs/25_av_mp4_mux_record.md
docs/26_av_sync_timestamp_ground_truth.md
```

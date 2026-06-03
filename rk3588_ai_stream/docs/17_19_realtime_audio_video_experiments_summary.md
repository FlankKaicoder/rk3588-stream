# 17~19-1 音视频实验总结：RK3588 实时音频、音视频封装与 RTSP 双轨推流

> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：`17_realtime_audio_capture_encode`、`18_av_mux_file`、`19_realtime_av_rtsp`、`19-1_realtime_av_rtsp_fix`  
> 当前阶段目标：在 13~16 已经完成音频采集、编码、解码、播放基础链路之后，继续完成实时音频编码、文件级音视频封装，以及实时视频 + 实时音频 RTSP 双轨推流。

---

## 1. 阶段背景

前面 00~12 实验已经完成了 RK3588 端侧 AI 视频流媒体链路：

```text
摄像头 /dev/video11
    ↓
V4L2 mmap 采集 NV12
    ↓
RGA NV12 ↔ RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
MPP H.264 硬件编码
    ↓
FFmpeg / MediaMTX
    ↓
RTSP / HLS / WebRTC 预览
    ↓
稳定性与资源占用评估
```

13~16 实验补齐了音频基础链路：

```text
13_audio_probe：
    探测 ALSA 声卡、ES8388 codec、FFmpeg ALSA/AAC/Opus/G.711 能力。

14_alsa_pcm_capture_playback：
    使用 ES8388 hw:2,0 完成 PCM WAV 采集和播放。

15_audio_encode：
    将采集到的 PCM/WAV 编码成 AAC、ADTS AAC、Opus、G.711 A-law、G.711 μ-law。

16_audio_decode_playback：
    将压缩音频解码回 PCM，并统一转换成 ES8388 可播放的 48kHz / stereo / S16_LE。
```

本阶段 17~19-1 的目标是把音频从“离线文件实验”推进到“实时音视频系统”：

```text
17：实时音频采集与编码，并验证纯音频 RTSP 推流。
18：已有检测视频文件 + 17 生成的音频文件，合成带视频轨和音频轨的 MP4。
19：实时检测视频 H.264 + 实时 ALSA 音频 AAC，合流推送到 RTSP。
19-1：修正 19 中的帧率、ffprobe 时机和队列问题，形成当前可用的 RTSP 音视频双轨链路。
```

---

## 2. 当前阶段总路线

```text
17_realtime_audio_capture_encode
    ES8388 hw:2,0
        ↓
    ALSA 实时采集 48kHz / stereo / S16_LE
        ↓
    FFmpeg 实时编码
        ↓
    AAC / ADTS AAC / Opus / G.711 文件
        ↓
    AAC 纯音频 RTSP 推流
        ↓
    MediaMTX / ffprobe / VLC 验证

18_av_mux_file
    08 已有检测 MP4
        +
    17 实时采集 AAC 音频
        ↓
    FFmpeg 文件级 MUX
        ↓
    带 H.264 视频轨 + AAC 音频轨的 MP4

19_realtime_av_rtsp
    实时检测视频 H.264 FIFO
        +
    实时 ALSA PCM 音频
        ↓
    FFmpeg AAC 编码 + RTSP MUX
        ↓
    MediaMTX
        ↓
    VLC / ffprobe 验证

19-1_realtime_av_rtsp_fix
    在 19 基础上修正为 20FPS、增大队列、等待双轨上线后再 ffprobe
        ↓
    RTSP over TCP 音视频双轨稳定验证
```

---

# 17 实验：实时音频采集与编码 / 纯音频 RTSP 推流

## 17.1 实验目的

17 实验的目标是从 15 的离线音频编码推进到实时音频编码：

```text
ES8388 hw:2,0
    ↓
ALSA 实时采集 48kHz / stereo / S16_LE
    ↓
FFmpeg 实时编码
    ↓
AAC / Opus / G.711 文件
    ↓
MediaMTX
    ↓
RTSP 纯音频流
```

本实验只做音频，不接视频。这样可以先独立验证：

```text
1. ALSA 实时采集是否正常；
2. FFmpeg 是否能直接从 ALSA 设备实时编码；
3. AAC / Opus / G.711 文件是否能实时生成；
4. MediaMTX 是否能发布纯音频 RTSP；
5. ffprobe / VLC 是否能拉到 AAC 音频流。
```

## 17.2 实验脚本

实验脚本：

```bash
scripts/exp17_realtime_audio_capture_encode.sh
```

执行命令：

```bash
cd ~/projects/rk3588_ai_stream
./scripts/exp17_realtime_audio_capture_encode.sh hw:2,0 48000 2 20 30
```

参数含义：

| 参数 | 含义 |
|---|---|
| `hw:2,0` | ES8388 ALSA 采集设备 |
| `48000` | 采样率 48kHz |
| `2` | 双声道 stereo |
| `20` | 文件录制/编码时长 20 秒 |
| `30` | RTSP 纯音频流保持 30 秒 |

## 17.3 17-1：实时采集编码文件

17 实验实时生成了以下文件：

```text
live_capture_aac_128k_20s.m4a
live_capture_aac_128k_20s.adts.aac
live_capture_opus_64k_20s.ogg
live_capture_g711a_8k_mono_20s.wav
live_capture_g711u_8k_mono_20s.wav
```

ffprobe 关键结果：

```text
AAC M4A：
Duration: 00:00:20.02
Audio: aac (LC), 48000 Hz, stereo, 129 kb/s

AAC ADTS：
Duration: 00:00:19.83
Audio: aac (LC), 48000 Hz, stereo, 133 kb/s

Opus OGG：
Duration: 00:00:20.01
Audio: opus, 48000 Hz, stereo

G.711 A-law：
Duration: 00:00:20.00
Audio: pcm_alaw, 8000 Hz, mono, 64 kb/s

G.711 μ-law：
Duration: 00:00:20.00
Audio: pcm_mulaw, 8000 Hz, mono, 64 kb/s
```

文件大小：

```text
AAC M4A      约 322K
AAC ADTS     约 323K
Opus OGG     约 100K
G.711 A-law  约 157K
G.711 μ-law  约 157K
```

这说明实时音频编码链路正常。

## 17.4 17-2：纯音频 RTSP 推流

推流路径：

```text
rtsp://127.0.0.1:8554/exp17_audio_aac
```

外部 VLC 地址：

```text
rtsp://10.198.89.221:8554/exp17_audio_aac
```

FFmpeg 输入：

```text
Input #0, alsa, from 'hw:2,0':
Audio: pcm_s16le, 48000 Hz, stereo, s16, 1536 kb/s
```

FFmpeg 输出：

```text
Output #0, rtsp, to 'rtsp://127.0.0.1:8554/exp17_audio_aac':
Audio: aac (LC), 48000 Hz, stereo, fltp, 128 kb/s
```

ffprobe 验证：

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp17_audio_aac':
Stream #0:0: Audio: aac (LC), 48000 Hz, stereo, fltp
```

MediaMTX 日志：

```text
[path exp17_audio_aac] stream is available and online, 1 track (MPEG-4 Audio)
[RTSP] is publishing to path 'exp17_audio_aac'
[RTSP] is reading from path 'exp17_audio_aac', with TCP, 1 track (MPEG-4 Audio)
```

## 17.5 17 实验结论

```text
17_realtime_audio_capture_encode：通过

已完成：
1. ALSA hw:2,0 实时采集 PCM；
2. 实时编码 AAC M4A；
3. 实时编码 AAC ADTS；
4. 实时编码 Opus OGG；
5. 实时编码 G.711 A-law；
6. 实时编码 G.711 μ-law；
7. FFmpeg 将 ALSA PCM 实时编码为 AAC；
8. MediaMTX 发布纯音频 RTSP；
9. ffprobe 能识别 RTSP 中 AAC 音频轨；
10. FFmpeg / MediaMTX 均正常受控退出。
```

---

# 18 实验：视频文件 + 音频文件 MP4 封装

## 18.1 实验目的

18 实验不做实时推流，而是先验证文件级音视频封装：

```text
08 已有检测视频 MP4
    +
17 实时采集得到的 AAC 音频
    ↓
FFmpeg MUX
    ↓
带 H.264 视频轨 + AAC 音频轨的 MP4
    ↓
ffprobe / VLC 验证
```

这样可以先排除容器封装、轨道识别、音频编码格式等基础问题，再进入 19 的实时音视频合流。

## 18.2 实验脚本

实验脚本：

```bash
scripts/exp18_av_mux_file.sh
```

默认输入：

```text
视频输入：output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4
音频输入：output/exp17_realtime_audio/live_capture_aac_128k_20s.m4a
```

执行命令：

```bash
cd ~/projects/rk3588_ai_stream
./scripts/exp18_av_mux_file.sh
```

## 18.3 输入文件参数

视频输入：

```text
Duration: 00:00:10.00
Video: h264 (High), yuvj420p, 1280x720, 3424 kb/s, 30 fps
```

音频输入：

```text
Duration: 00:00:20.02
Audio: aac (LC), 48000 Hz, stereo, 129 kb/s
```

由于视频约 10 秒，音频约 20 秒，因此封装时使用：

```bash
-shortest
```

这样输出 MP4 会以较短的视频时长为准，音频被裁剪到约 10 秒。

## 18.4 输出文件

18 实验生成了 3 个主要 MP4：

```text
detect_with_audio_copy.mp4
    视频 copy + 音频 copy

detect_with_audio_reenc_aac.mp4
    视频 copy + 音频重新编码 AAC

detect_with_audio_gain12db.mp4
    音频先 +12dB 增益后再封装，方便听声音
```

输出文件大小：

```text
detect_with_audio_copy.mp4       约 4.3M
detect_with_audio_reenc_aac.mp4  约 4.3M
detect_with_audio_gain12db.mp4   约 4.3M
audio_gain12db.m4a               约 322K
```

## 18.5 ffprobe 验证

3 个输出文件均具有相同结构：

```text
Stream #0:0 Video: h264, 1280x720, 30 fps
Stream #0:1 Audio: aac (LC), 48000 Hz, stereo
```

紧凑流信息：

```text
0|h264|video|1280|720|9.999900|3424853
1|aac|audio|48000|2|10.005000|129860
```

说明：

```text
1. 视频轨存在；
2. 音频轨存在；
3. 视频仍然是 H.264；
4. 音频是 AAC；
5. 音视频时长都约 10 秒；
6. -shortest 生效；
7. MP4 文件级 MUX 成功。
```

## 18.6 音频增益版本

因为前面 14~17 录音电平偏低，所以 18 额外生成了：

```text
detect_with_audio_gain12db.mp4
```

其音频音量检测：

```text
mean_volume: -36.4 dB
max_volume : -10.2 dB
```

这只是为了方便 VLC 播放时听到声音，不代表原始采集音量已经优化。

## 18.7 18 实验结论

```text
18_av_mux_file：通过

已完成：
1. 使用已有 H.264 检测视频 MP4；
2. 使用 17 生成的 AAC 音频文件；
3. FFmpeg 成功封装出带视频轨和音频轨的 MP4；
4. 输出 MP4 同时包含 H.264 视频和 AAC 音频；
5. -shortest 成功将 20 秒音频裁剪到约 10 秒，与视频对齐；
6. 额外生成 +12dB 音频增益版本，便于播放验证。
```

---

# 19 实验：实时视频 + 实时音频 RTSP 推流

## 19.1 实验目的

19 实验开始把实时视频链路和实时音频链路真正合起来：

```text
视频侧：
摄像头 /dev/video11
    ↓
V4L2 mmap 采集 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
NV12 FIFO
    ↓
MPP H.264 编码
    ↓
H.264 FIFO

音频侧：
ES8388 hw:2,0
    ↓
ALSA 实时采集 PCM
    ↓
FFmpeg AAC 编码

合流：
H.264 FIFO + ALSA PCM
    ↓
FFmpeg MUX
    ↓
RTSP 推送到 MediaMTX
    ↓
VLC / ffprobe 拉流
```

## 19.2 实验脚本

实验脚本：

```bash
scripts/exp19_realtime_av_rtsp.sh
```

执行命令：

```bash
cd ~/projects/rk3588_ai_stream
./scripts/exp19_realtime_av_rtsp.sh 1280 720 30 1800 hw:2,0 48000 2
```

参数含义：

| 参数 | 含义 |
|---|---|
| `1280 720` | 视频分辨率 |
| `30` | 初始按 30FPS 送给 FFmpeg |
| `1800` | 处理 1800 帧 |
| `hw:2,0` | ALSA 音频设备 |
| `48000` | 音频采样率 |
| `2` | 双声道 |

## 19.3 19 的关键成功证据

FFmpeg 输入端识别：

```text
Input #0, h264, from realtime_detect_h264.fifo:
Video: h264 (High), yuvj420p, 1280x720, 30 fps

Input #1, alsa, from 'hw:2,0':
Audio: pcm_s16le, 48000 Hz, stereo, s16, 1536 kb/s
```

FFmpeg 输出端识别：

```text
Output #0, rtsp, to 'rtsp://127.0.0.1:8554/exp19_av_detect':
Stream #0:0: Video: h264 (High), 1280x720
Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, 128 kb/s
```

MediaMTX 日志：

```text
[path exp19_av_detect] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
[RTSP] is publishing to path 'exp19_av_detect'
[RTSP] is reading from path 'exp19_av_detect', with TCP, 2 tracks (H264, MPEG-4 Audio)
```

这说明 19 已经证明：

```text
实时视频 + 实时音频可以合流成 RTSP 双轨。
```

## 19.4 19 中出现的问题

### 19.4.1 ffprobe 过早导致 404

19 的 ffprobe 一开始出现：

```text
method DESCRIBE failed: 404 Not Found
no stream is available on path 'exp19_av_detect'
```

但 MediaMTX 时间顺序显示：

```text
17:48:50 no stream is available
17:48:53 stream is available and online, 2 tracks
```

所以这是脚本里 ffprobe 执行过早导致的，不是双轨流本身失败。

### 19.4.2 实际帧率不是 30FPS

检测程序统计：

```text
frames              : 1800
wall_time_ms        : 88440.093
wall_fps            : 20.353
avg_total_ms        : 49.036
```

MPP 编码统计：

```text
encode 1800 frames time 88543 ms
average frame rate 20.33
```

这说明当前完整音视频链路实际只有约：

```text
20.3 FPS
```

而脚本初始给 FFmpeg 的视频帧率是 30FPS。裸 H.264 FIFO 没有容器时间戳，FFmpeg 需要根据 `-framerate` / `-r` 去解释输入节奏。实际 20FPS 却按 30FPS 解释，会导致音视频时间基不匹配。

### 19.4.3 音频 xrun

19 的 FFmpeg 日志出现：

```text
Thread message queue blocking
ALSA buffer xrun
```

这说明音频采集缓冲出现欠载/溢出，主要原因可能是视频侧生产节奏与音频实时采集节奏不匹配。

### 19.4.4 裸 H.264 时间戳警告

FFmpeg 还出现：

```text
Timestamps are unset in a packet for stream 0
```

这是因为 H.264 FIFO 是裸码流，没有容器层 PTS/DTS。短期可以用 FFmpeg 生成 PTS；长期更严谨的做法是编码端或封装端提供稳定时间戳。

## 19.5 19 实验结论

```text
19_realtime_av_rtsp：功能跑通，但不作为最终稳定版本

已完成：
1. 实时检测视频 H.264 FIFO；
2. 实时 ALSA PCM 音频输入；
3. FFmpeg 将视频 copy、音频编码 AAC；
4. MediaMTX 成功发布 H264 + AAC 双轨 RTSP；
5. 外部客户端可以读取 2 tracks。

存在问题：
1. ffprobe 执行过早导致 404；
2. 实际完整链路约 20FPS，不是 30FPS；
3. FFmpeg 出现 ALSA buffer xrun；
4. 裸 H.264 缺少时间戳警告；
5. VLC 播放端最初出现只有画面、声音不明显或中断现象。
```

因此继续做 19-1 修正版。

---

# 19-1 实验：实时音视频 RTSP 修正版验证

## 19-1.1 实验目的

19-1 不是重新设计链路，而是在 19 的基础上修正实际问题：

```text
1. 不再按名义 30FPS，而是按实测 20FPS 推流；
2. 增大 FFmpeg 输入队列；
3. 尝试让 FFmpeg 生成 PTS；
4. 等 MediaMTX 双轨上线后再 ffprobe；
5. VLC 强制 RTSP over TCP；
6. 只评价 RTSP，不评价 HLS/WebRTC。
```

## 19-1.2 实验脚本

实验脚本：

```bash
scripts/exp19_1_realtime_av_rtsp_fix.sh
```

执行命令：

```bash
cd ~/projects/rk3588_ai_stream
./scripts/exp19_1_realtime_av_rtsp_fix.sh 1280 720 20 1200 hw:2,0 48000 2
```

推荐 VLC 命令：

```bash
vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none \
  rtsp://10.198.89.221:8554/exp19_1_av_detect_fix
```

## 19-1.3 FFmpeg 修正点

19-1 中 FFmpeg 使用：

```bash
-fflags +genpts+nobuffer
-flags low_delay
-thread_queue_size 4096
-use_wallclock_as_timestamps 1
-f h264
-r 20
-i realtime_detect_h264.fifo
-thread_queue_size 4096
-f alsa
-ar 48000
-ac 2
-i hw:2,0
-map 0:v:0
-map 1:a:0
-c:v copy
-c:a aac
-b:a 128k
-f rtsp
-rtsp_transport tcp
rtsp://127.0.0.1:8554/exp19_1_av_detect_fix
```

核心变化：

```text
1. 视频输入节奏改为 20FPS；
2. 队列从 512 增大到 4096；
3. 增加 genpts / wallclock timestamp 尝试；
4. RTSP 使用 TCP；
5. 等 MediaMTX 检测到 2 tracks online 后再 ffprobe。
```

## 19-1.4 检测链路结果

检测程序：

```text
frames              : 1200
wall_time_ms        : 57516.282
wall_fps            : 20.864
avg_select_ms       : 0.077
avg_dqbuf_ms        : 0.007
avg_rga_nv12_to_rgb : 2.717
avg_input_prepare   : 0.001
avg_model_total_ms  : 35.717
avg_draw_ms         : 0.029
avg_rga_rgb_to_nv12 : 3.467
avg_write_ms        : 5.710
avg_qbuf_ms         : 0.098
avg_total_ms        : 47.825
```

MPP 编码：

```text
encode 1200 frames time 57623 ms
average frame rate 20.82
bps 3512234
```

这说明 19-1 当前完整视频侧稳定能力约：

```text
20.8 FPS
```

## 19-1.5 RTSP 双轨验证

ffprobe 成功识别：

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp19_1_av_detect_fix':
Stream #0:0: Video: h264 (High), yuvj420p, 1280x720, 30 fps
Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp
```

MediaMTX 日志：

```text
[path exp19_1_av_detect_fix] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
[RTSP] is publishing to path 'exp19_1_av_detect_fix'
[RTSP] is reading from path 'exp19_1_av_detect_fix', with TCP, 2 tracks (H264, MPEG-4 Audio)
```

外部客户端：

```text
10.198.210.113 通过 RTSP over TCP 读取 2 tracks
```

用户侧最终确认：

```text
VLC 可以看到实时检测画面，并且可以听到声音。
```

这条确认非常关键，说明 19-1 不只是服务端有音频轨，客户端实际播放体验也已经验证成功。

## 19-1.6 19-1 相比 19 的改进

19 中的问题：

```text
ffprobe 过早导致 404
ALSA buffer xrun
Thread message queue blocking
Timestamps are unset warning
VLC 只能看到画面、声音不明显或中断
```

19-1 中：

```text
1. ffprobe 成功识别双轨，不再 404；
2. MediaMTX 稳定发布 H264 + AAC 双轨；
3. 外部 VLC 通过 TCP 读取 2 tracks；
4. FFmpeg 尾部没有再出现 ALSA buffer xrun；
5. FFmpeg / MediaMTX 均为脚本主动结束；
6. 用户确认 VLC 可以听到声音。
```

## 19-1.7 遗留问题

虽然 19-1 可以判定通过，但仍然有几个遗留问题：

### 1. 完整链路仍然是 20~21 FPS

当前性能主要由完整视频处理链路决定：

```text
avg_model_total_ms  : 35.717 ms
avg_rga_rgb_to_nv12 : 3.467 ms
avg_write_ms        : 5.710 ms
avg_total_ms        : 47.825 ms
```

换算：

```text
1000 / 47.825 ≈ 20.9 FPS
```

后续如果要回到 25~30FPS，需要优化：

```text
1. YOLO11 推理内部耗时；
2. RGA_COLORFILL fail 导致的日志和潜在开销；
3. RGB → NV12 转换；
4. FIFO 写入阻塞；
5. MPP 编码参数和缓冲队列；
6. 是否改成多线程流水线或真正的零拷贝链路。
```

### 2. RGA_COLORFILL fail 日志仍然存在

检测日志仍然刷：

```text
RGA_COLORFILL fail: Invalid argument
```

这是 YOLO11 内部 letterbox / padding 阶段的老问题，目前没有阻断推理和推流，但会污染日志，也可能带来额外开销。后续应单独清理。

### 3. HLS 低延迟切片存在 warning

MediaMTX 中仍然有：

```text
HLS part duration changed ...
```

19-1 当前只评价 RTSP。HLS/WebRTC 后续需要单独适配稳定帧率和 GOP/时间戳后再评价。

---

# 3. 17~19-1 阶段总表

| 实验 | 目标 | 结果 |
|---|---|---|
| 17 | 实时 ALSA 采集并编码 AAC/Opus/G.711，验证纯音频 RTSP | 通过 |
| 18 | 已有检测视频 + 音频文件封装成 MP4 | 通过 |
| 19 | 实时视频 + 实时音频 RTSP 双轨合流 | 功能跑通，但存在 xrun/帧率/ffprobe 时机问题 |
| 19-1 | 修正 19，按 20FPS 稳定验证 RTSP 双轨 | 通过，VLC 可看到画面并听到声音 |

---

# 4. 当前项目链路更新

完成 19-1 后，项目已经从“视频流媒体系统”升级为“实时音视频 AI 流媒体系统”。

当前可描述为：

```text
摄像头 /dev/video11
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
MPP H.264 硬件编码
    ↓
H.264 FIFO

ES8388 hw:2,0
    ↓
ALSA 采集 PCM 48kHz / stereo
    ↓
FFmpeg AAC 编码

H.264 视频 + AAC 音频
    ↓
FFmpeg RTSP MUX
    ↓
MediaMTX
    ↓
VLC RTSP over TCP
    ↓
实时检测画面 + 实时声音
```

当前稳定验证版本：

```text
rtsp://10.198.89.221:8554/exp19_1_av_detect_fix
```

推荐 VLC：

```bash
vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none \
  rtsp://10.198.89.221:8554/exp19_1_av_detect_fix
```

---

# 5. 当前可以写进简历的阶段性描述

在 19-1 通过后，可以将项目从“视频推流”升级描述为：

```text
基于 RK3588 构建端侧 AI 音视频实时分析与流媒体系统，完成 V4L2 摄像头采集、RGA 图像预处理、RKNN YOLO11 推理、MPP H.264 硬件编码、ALSA 音频采集、AAC 音频编码，以及 FFmpeg/MediaMTX 音视频 RTSP 双轨推流。系统支持在 VLC 端通过 RTSP over TCP 实时查看检测画面并播放同步音频，当前完整音视频链路实测约 20~21FPS。
```

更工程化一点的表述：

```text
在 RK3588 平台实现实时音视频 AI 流媒体链路：视频侧基于 V4L2 mmap 获取 RKISP 输出的 NV12 数据，经 RGA 转 RGB 后送入 RKNN YOLO11 推理并绘制检测框，再通过 RGA 转回 NV12 送入 MPP H.264 硬件编码；音频侧基于 ALSA 从 ES8388 codec 实时采集 PCM，并使用 FFmpeg 编码为 AAC；最终通过 FFmpeg 将 H.264 视频流和 AAC 音频流合封装推送至 MediaMTX，实现 RTSP 双轨实时预览。
```

---

# 6. 后续建议

## 6.1 先做 20 稳定性实验

下一步建议做：

```text
20_av_rtsp_stability_profile
```

不要再按 30FPS 测，应该基于当前已经验证的：

```text
20FPS / RTSP over TCP / H.264 + AAC 双轨
```

建议测试：

```text
1. 120 秒稳定性测试；
2. 240 秒稳定性测试；
3. CPU / 内存 / 温度 / 进程状态；
4. FFmpeg 日志是否有 xrun；
5. MediaMTX 是否持续保持 2 tracks；
6. VLC 是否持续播放画面和声音；
7. 检测程序、MPP、FFmpeg、MediaMTX 是否正常受控退出。
```

## 6.2 后续再考虑优化到 25~30FPS

当前完整链路只有 20~21FPS。后续优化方向：

```text
1. 清理 YOLO11 内部 RGA_COLORFILL fail；
2. 优化 inference_yolo11_model() 内部耗时；
3. 减少 FIFO 写入阻塞；
4. 检测 / 编码 / 推流多线程解耦；
5. 尝试降低模型输入分辨率或优化后处理；
6. 使用更稳定的 PTS/时间戳生成方式；
7. 后续再评价 HLS / WebRTC 双轨播放。
```

---

# 7. 本阶段最终结论

```text
17~19-1 阶段已经完成音频从基础实验到实时音视频系统的关键升级。

当前已经跑通：
1. ALSA 实时音频采集；
2. AAC / Opus / G.711 实时编码；
3. 纯音频 RTSP 推流；
4. 检测视频文件 + 音频文件 MP4 封装；
5. 实时检测视频 H.264 + 实时音频 AAC 合流；
6. MediaMTX 发布 H264 + MPEG-4 Audio 双轨；
7. VLC 通过 RTSP over TCP 实时播放画面和声音。

当前系统状态：
RTSP 音视频双轨链路功能通过，当前稳定工作帧率约 20~21FPS。

下一步：
做 20_av_rtsp_stability_profile，验证 120~240 秒稳定性与资源占用。
```

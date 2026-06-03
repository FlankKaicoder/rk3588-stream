# 13~16 音频实验总结：RK3588 音频采集、编解码与播放链路

> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：`13_audio_probe`、`14_alsa_pcm_capture_playback`、`15_audio_encode`、`16_audio_decode_playback`  
> 当前阶段目标：在已经完成 00~12 视频流媒体链路的基础上，补齐音频基础链路，为后续“音视频同步封装 / 推流”做准备。

---

## 1. 阶段背景

前面 00~12 实验已经完成了 RK3588 端侧 AI 视频链路：

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

但是这个链路本质上仍然是“视频流媒体链路”，还没有音频采集、音频编码、音频解码、音频播放和音视频合流。

最初参考的全志项目串联路线里，音频部分通常对应：

```text
AI    Audio Input，音频采集
AO    Audio Output，音频播放
AENC  Audio Encoder，音频编码
ADEC  Audio Decoder，音频解码
MUX   音视频封装
```

在 RK3588 当前工程中，不能直接照搬全志 MPP 的 `AW_MPI_AI / AW_MPI_AO / AW_MPI_AENC / AW_MPI_ADEC` 接口。更合理的对应关系是：

```text
全志 AI      → RK3588 ALSA / arecord / snd_pcm_readi
全志 AO      → RK3588 ALSA / aplay / snd_pcm_writei
全志 AENC    → FFmpeg / libavcodec AAC、Opus、G.711 编码
全志 ADEC    → FFmpeg / libavcodec 解码到 PCM
全志 MUX     → FFmpeg MP4 / RTSP / HLS / WebRTC 封装与推流
```

因此 13~16 实验的目标是先把音频基础能力跑通。

---

## 2. 当前音频实验路线

```text
13_audio_probe
    音频设备与 FFmpeg 编解码能力探测

14_alsa_pcm_capture_playback
    ALSA PCM 采集与播放

15_audio_encode
    AAC / Opus / G.711 音频编码

16_audio_decode_playback
    AAC / Opus / G.711 解码与播放
```

这四个实验完成后，可以说明当前 RK3588 板端已经具备：

```text
音频输入设备识别
音频输出设备识别
PCM 原始音频采集
PCM 原始音频播放
AAC 编码 / 解码
Opus 编码 / 解码
G.711 A-law 编码 / 解码
G.711 μ-law 编码 / 解码
压缩音频解码后重新适配硬件声卡播放
```

---

# 13 实验：audio_probe 音频环境探测

## 13.1 实验目的

13 实验不是录音，也不是播放，而是先确认当前板端音频环境是否具备继续做实验的条件。

主要确认：

```text
1. 系统中有哪些声卡；
2. 哪些声卡支持 capture；
3. 哪些声卡支持 playback；
4. ES8388 codec 是否存在；
5. ALSA 工具 arecord / aplay 是否可用；
6. FFmpeg 是否支持 ALSA 输入；
7. FFmpeg 是否支持 AAC / Opus / G.711 编解码；
8. FFmpeg 是否支持后续需要的封装格式，例如 WAV、ADTS、MP4、RTSP、HLS、WebM、Ogg。
```

## 13.2 核心命令

实验脚本：

```bash
scripts/exp13_audio_probe.sh
```

关键探测命令包括：

```bash
cat /proc/asound/cards
cat /proc/asound/pcm
arecord -l
aplay -l
arecord -L
aplay -L
amixer
ffmpeg -hide_banner -devices
ffmpeg -hide_banner -encoders
ffmpeg -hide_banner -decoders
ffmpeg -hide_banner -muxers
ffmpeg -hide_banner -demuxers
```

## 13.3 声卡探测结果

当前系统识别到 3 张声卡：

```text
card 0: rockchip-hdmiin
    类型：rockchip-hdmiin
    作用：HDMI 音频输入
    能力：capture

card 1: rockchip-dp0
    类型：rockchip-dp0
    作用：DP / HDMI 音频输出
    能力：playback

card 2: rockchip-es8388
    类型：rockchip-es8388
    作用：板载 ES8388 codec
    能力：capture + playback
```

对应 `/proc/asound/pcm`：

```text
00-00: rockchip-hdmiin i2s-hifi-0
    capture 1

01-00: rockchip-dp0 spdif-hifi-0
    playback 1

02-00: dailink-multicodecs ES8323.7-0011-0
    playback 1 : capture 1
```

其中最适合后续实验的是：

```text
card 2: rockchip-es8388
设备名：hw:2,0
能力：采集 + 播放
```

所以后续音频实验统一优先使用：

```text
采集设备：hw:2,0
播放设备：hw:2,0
```

## 13.4 FFmpeg 能力探测结果

13 实验确认：

```text
FFMPEG_ALSA_OK
    FFmpeg 支持 ALSA 输入 / 输出

FFMPEG_AAC_ENCODER_OK
    FFmpeg 存在 native AAC encoder

FFMPEG_OPUS_ENCODER_OK
    FFmpeg 存在 libopus encoder
```

FFmpeg 支持的关键 muxer：

```text
adts
wav
mp4 / mov / m4a
matroska / webm
ogg / opus
flv
hls
mpegts
rtp
rtsp
```

FFmpeg 支持的关键 demuxer：

```text
aac
alsa
wav
mp4 / mov / m4a
matroska / webm
ogg
hls
rtp
rtsp
flv
mpegts
```

说明后续可以继续做：

```text
ALSA 实时采集
AAC 编码
Opus 编码
G.711 编码
RTSP 音频推流
HLS 音频封装
音视频 MP4 封装
```

## 13.5 13 实验结论

```text
13_audio_probe：通过

结论：
1. 板端 ALSA 音频环境存在；
2. 系统存在 capture 设备；
3. 系统存在 playback 设备；
4. ES8388 codec 可作为后续主要音频输入 / 输出设备；
5. FFmpeg 支持 ALSA；
6. FFmpeg 支持 AAC；
7. FFmpeg 支持 Opus；
8. FFmpeg 支持 G.711 A-law / μ-law；
9. 可以进入 14 ALSA PCM 采集与播放实验。
```

---

# 14 实验：ALSA PCM 采集与播放

## 14.1 实验目的

14 实验的目标是完成最基础的音频闭环：

```text
ES8388 codec / MIC 输入
    ↓
ALSA 采集 PCM
    ↓
保存 WAV / raw PCM
    ↓
ffprobe 检查音频参数
    ↓
volumedetect 分析音量
    ↓
生成测试音
    ↓
ALSA 播放测试音
    ↓
ALSA 播放录音文件
```

本实验对应全志链路中的：

```text
AI：音频采集
AO：音频播放
```

## 14.2 实验脚本

实验脚本：

```bash
scripts/exp14_alsa_pcm_capture_playback.sh
```

第一次执行时使用了：

```bash
./scripts/exp14_alsa_pcm_capture_playback.sh hw:2,0 hw:2,0 48000 1 10
```

含义：

```text
采集设备：hw:2,0
播放设备：hw:2,0
采样率：48000 Hz
声道数：1 channel，mono
录音时长：10 秒
```

## 14.3 第一次失败：mono 参数不被硬件接受

第一次失败不是因为声卡不存在，而是因为 `hw:2,0` 这个硬件设备当前不接受 1 声道。

硬件参数显示：

```text
FORMAT:  S16_LE S24_LE
CHANNELS: 2
RATE: [8000 96000]
```

但是第一次命令请求的是：

```text
48000 Hz / mono / S16_LE
```

所以 ALSA 报错：

```text
arecord: set_params:1349: Channels count non available
aplay: set_params:1349: Channels count non available
```

这说明：

```text
ES8388 的 hw:2,0 硬件设备当前只接受 2 声道，不能直接用 hw 设备录 mono。
```

如果后续要得到 mono，有两种方式：

```text
方式 1：硬件保持 2ch，后处理用 FFmpeg 转 mono；
方式 2：使用 plughw:2,0，让 ALSA 插件层帮忙做声道转换。
```

在底层实验中，为了贴近真实硬件能力，本项目优先使用：

```text
hw:2,0 + 2ch
```

## 14.4 第二次执行：改为 stereo 成功

第二次执行：

```bash
./scripts/exp14_alsa_pcm_capture_playback.sh hw:2,0 hw:2,0 48000 2 10
```

实际生成文件名中记录为 11 秒：

```text
capture_48000_2ch_11s.wav
capture_48000_2ch_11s.pcm
```

关键输出文件：

```text
capture_48000_2ch_11s.wav    约 2.1M
capture_48000_2ch_11s.pcm    约 4.1M
test_tone_1000hz_48000_2ch.wav 约 563K
```

注意：WAV 文件为标准 RIFF/WAV 封装，PCM 文件为 raw PCM 数据。实际 raw PCM 文件大小大于 WAV 文件，说明这次 raw 采集文件可能包含了更多数据或命令执行时长不完全一致，后续以 ffprobe 能识别的 WAV 为主要分析对象。

## 14.5 ffprobe 验证

录音 WAV 文件参数：

```text
Input #0, wav, from 'capture_48000_2ch_11s.wav':
  Duration: 00:00:11.00
  bitrate: 1536 kb/s
  Stream #0:0: Audio: pcm_s16le, 48000 Hz, 2 channels, s16, 1536 kb/s
```

这说明录音文件符合预期：

```text
采样格式：pcm_s16le
采样率：48000 Hz
声道数：2 channels / stereo
码率：1536 kb/s
```

码率计算：

```text
48000 samples/s × 2 channels × 16 bit
= 1536000 bit/s
= 1536 kb/s
```

## 14.6 音量分析

`volumedetect` 结果：

```text
mean_volume: -60.4 dB
max_volume : -30.4 dB
```

这说明：

```text
1. 录音不是全静音；
2. 但是平均音量偏低；
3. 后续如果要提高听感，需要调 ES8388 mixer 增益，或者在 FFmpeg 中临时加 gain；
4. 当前阶段不影响继续做编码 / 解码实验。
```

## 14.7 播放验证

14 实验中完成了两类播放：

```text
1. 播放 1kHz test tone；
2. 播放录音 WAV 文件。
```

日志显示：

```text
Playing WAVE 'test_tone_1000hz_48000_2ch.wav' : Signed 16 bit Little Endian, Rate 48000 Hz, Stereo

Playing WAVE 'capture_48000_2ch_11s.wav' : Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
```

说明 `hw:2,0` 播放链路可用。

## 14.8 14 实验结论

```text
14_alsa_pcm_capture_playback：通过

结论：
1. ES8388 的 hw:2,0 可以完成 PCM 采集；
2. ES8388 的 hw:2,0 可以完成 PCM 播放；
3. hw:2,0 当前硬件参数要求 2 声道；
4. 48000 Hz / stereo / S16_LE 是当前推荐基础格式；
5. 当前采集音量偏低，但不是全静音；
6. 后续编码实验可以使用 capture_48000_2ch_11s.wav 作为输入。
```

---

# 15 实验：AAC / Opus / G.711 音频编码

## 15.1 实验目的

15 实验的目标是把 14 采集到的 PCM WAV 编码成常见压缩音频格式，并验证这些压缩音频文件能够再解码回 PCM。

实验覆盖：

```text
AAC M4A
AAC ADTS
Opus OGG
G.711 A-law
G.711 μ-law
```

对应全志链路中的：

```text
AENC：音频编码
```

## 15.2 实验输入

输入文件：

```text
output/exp14_alsa_pcm/capture_48000_2ch_11s.wav
```

输入音频参数：

```text
pcm_s16le
48000 Hz
stereo
1536 kb/s
时长约 11 秒
文件大小约 2.1M
```

## 15.3 实验脚本

实验脚本：

```bash
scripts/exp15_audio_encode.sh
```

主要编码命令逻辑：

```bash
# AAC M4A
ffmpeg -i input.wav -c:a aac -b:a 128k capture_aac_128k.m4a

# AAC ADTS
ffmpeg -i input.wav -c:a aac -b:a 128k -f adts capture_aac_128k.adts.aac

# Opus OGG
ffmpeg -i input.wav -c:a libopus -b:a 64k capture_opus_64k.ogg

# G.711 A-law
ffmpeg -i input.wav -af "pan=mono|c0=0.5*c0+0.5*c1" -ar 8000 -ac 1 -c:a pcm_alaw capture_g711a_8k_mono.wav

# G.711 μ-law
ffmpeg -i input.wav -af "pan=mono|c0=0.5*c0+0.5*c1" -ar 8000 -ac 1 -c:a pcm_mulaw capture_g711u_8k_mono.wav
```

## 15.4 编码结果

编码输出文件：

```text
capture_aac_128k.m4a          180756 bytes，约 177K
capture_aac_128k.adts.aac     181500 bytes，约 178K
capture_opus_64k.ogg           58711 bytes，约 58K
capture_g711a_8k_mono.wav      88092 bytes，约 87K
capture_g711u_8k_mono.wav      88092 bytes，约 87K
```

## 15.5 ffprobe 验证

### AAC M4A

```text
Audio: aac (LC)
48000 Hz
stereo
fltp
129 kb/s
Duration: 00:00:11.02
```

说明 AAC M4A 编码正常。

### AAC ADTS

```text
Audio: aac (LC)
48000 Hz
stereo
fltp
136 kb/s
Duration: 00:00:10.64
```

ADTS 是裸 AAC 码流常见封装形式，适合流式传输或中间码流验证。

### Opus OGG

```text
Audio: opus
48000 Hz
stereo
encoder: libopus
Duration: 00:00:11.01
bitrate: 42 kb/s
```

Opus 输出文件最小，说明其压缩效率较高。

### G.711 A-law

```text
Audio: pcm_alaw
8000 Hz
1 channel
64 kb/s
Duration: 00:00:11.00
```

### G.711 μ-law

```text
Audio: pcm_mulaw
8000 Hz
1 channel
64 kb/s
Duration: 00:00:11.00
```

G.711 是固定 8kHz / mono / 64kbps 的传统语音编码，适合语音通信，不适合高保真音频。

## 15.6 编码后再解码验证

15 实验中将所有压缩文件重新解码为 WAV：

```text
decoded_aac_m4a.wav
decoded_aac_adts.wav
decoded_opus.wav
decoded_g711a.wav
decoded_g711u.wav
```

文件大小：

```text
decoded_aac_m4a.wav      约 2.1M
decoded_aac_adts.wav     约 2.1M
decoded_opus.wav         约 2.1M
decoded_g711a.wav        约 172K
decoded_g711u.wav        约 172K
```

其中 AAC / Opus 解码后回到 48kHz stereo PCM；G.711 解码后仍然是 8kHz mono PCM。

## 15.7 音量分析

由于 14 中原始录音电平较低，15 脚本额外生成了一个方便听感检查的增益文件：

```text
capture_mono_48k_gain12db.wav
```

增益后音量：

```text
mean_volume: -48.4 dB
max_volume : -18.4 dB
```

这只是为了方便听声音，不作为原始采集证据。

## 15.8 压缩效果对比

以 14 采集的原始 WAV 约 2.1M 为基准：

```text
原始 PCM WAV：约 2.1M
AAC M4A：约 177K
AAC ADTS：约 178K
Opus OGG：约 58K
G.711 A-law：约 87K
G.711 μ-law：约 87K
```

直观结论：

```text
1. Opus 文件最小，压缩效率最高；
2. AAC 适合 MP4 / HLS / RTSP 等通用音视频场景；
3. G.711 固定 64kbps，更偏语音通信；
4. 后续音视频合流优先考虑 AAC；
5. 如果做 WebRTC，Opus 更适合浏览器低延迟语音链路。
```

## 15.9 15 实验结论

```text
15_audio_encode：通过

结论：
1. PCM WAV → AAC M4A 编码成功；
2. PCM WAV → AAC ADTS 编码成功；
3. PCM WAV → Opus OGG 编码成功；
4. PCM WAV → G.711 A-law 编码成功；
5. PCM WAV → G.711 μ-law 编码成功；
6. 所有编码文件均可重新解码回 WAV；
7. 当前板端具备 FFmpeg 音频编码能力；
8. 可以进入 16 音频解码与播放实验。
```

---

# 16 实验：音频解码与播放

## 16.1 实验目的

15 已经证明“PCM → 压缩音频”的编码链路可用。16 实验进一步验证：

```text
压缩音频文件
    ↓
FFmpeg 解码为 PCM WAV
    ↓
转换为 ES8388 硬件可播放格式
    ↓
aplay -D hw:2,0 播放
```

本实验对应全志链路中的：

```text
ADEC：音频解码
AO：音频播放
```

## 16.2 为什么需要格式转换

前面 14 实验证明，`hw:2,0` 当前硬件设备接受的基础格式是：

```text
48000 Hz / stereo / S16_LE
```

但是 15 中不同压缩音频解码后的格式并不完全一致：

```text
AAC / Opus：通常解码为 48000 Hz / stereo PCM
G.711：解码为 8000 Hz / mono PCM
```

尤其是 G.711，不能直接送给 `hw:2,0`，否则可能再次出现：

```text
Channels count non available
Sample format non available
```

所以 16 实验统一转换为：

```text
48000 Hz / stereo / pcm_s16le
```

再播放。

## 16.3 实验脚本

实验脚本：

```bash
scripts/exp16_audio_decode_playback.sh
```

输入文件：

```text
output/exp15_audio_encode/capture_aac_128k.m4a
output/exp15_audio_encode/capture_aac_128k.adts.aac
output/exp15_audio_encode/capture_opus_64k.ogg
output/exp15_audio_encode/capture_g711a_8k_mono.wav
output/exp15_audio_encode/capture_g711u_8k_mono.wav
```

## 16.4 解码输出

首先解码为 PCM WAV：

```text
decoded_aac_m4a.wav
decoded_aac_adts.wav
decoded_opus.wav
decoded_g711a.wav
decoded_g711u.wav
```

文件大小：

```text
decoded_aac_m4a.wav      2113614 bytes
decoded_aac_adts.wav     2117710 bytes
decoded_opus.wav         2112078 bytes
decoded_g711a.wav         176078 bytes
decoded_g711u.wav         176078 bytes
```

## 16.5 转换为硬件可播放格式

转换后用于播放的文件：

```text
play_aac_m4a_48k_2ch_s16.wav
play_aac_adts_48k_2ch_s16.wav
play_opus_48k_2ch_s16.wav
play_g711a_48k_2ch_s16.wav
play_g711u_48k_2ch_s16.wav
```

ffprobe 结果均为：

```text
Audio: pcm_s16le
48000 Hz
2 channels
s16
1536 kb/s
```

说明所有解码后的音频都已经适配 ES8388 的播放格式。

## 16.6 播放验证

16 实验对 5 个文件都执行了：

```bash
aplay -D hw:2,0 xxx.wav
```

日志显示全部成功：

```text
Playing WAVE 'play_aac_m4a_48k_2ch_s16_gain12db.wav' : Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
Playing WAVE 'play_aac_adts_48k_2ch_s16_gain12db.wav' : Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
Playing WAVE 'play_opus_48k_2ch_s16_gain12db.wav' : Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
Playing WAVE 'play_g711a_48k_2ch_s16_gain12db.wav' : Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
Playing WAVE 'play_g711u_48k_2ch_s16_gain12db.wav' : Signed 16 bit Little Endian, Rate 48000 Hz, Stereo
```

说明：

```text
AAC 解码后可以播放；
ADTS AAC 解码后可以播放；
Opus 解码后可以播放；
G.711 A-law 解码后经重采样 / 双声道转换可以播放；
G.711 μ-law 解码后经重采样 / 双声道转换可以播放。
```

## 16.7 +12dB 增益文件说明

由于原始录音电平偏低，16 实验生成了 +12dB 的 review 文件：

```text
play_aac_m4a_48k_2ch_s16_gain12db.wav
play_aac_adts_48k_2ch_s16_gain12db.wav
play_opus_48k_2ch_s16_gain12db.wav
play_g711a_48k_2ch_s16_gain12db.wav
play_g711u_48k_2ch_s16_gain12db.wav
```

这些文件只是为了方便听感检查。真正证明链路的是：

```text
压缩文件可解码；
解码后可转换为 48k/stereo/S16_LE；
转换后可由 hw:2,0 播放。
```

## 16.8 16 实验结论

```text
16_audio_decode_playback：通过

结论：
1. AAC M4A 可以解码并播放；
2. AAC ADTS 可以解码并播放；
3. Opus OGG 可以解码并播放；
4. G.711 A-law 可以解码、重采样、转双声道并播放；
5. G.711 μ-law 可以解码、重采样、转双声道并播放；
6. 所有播放文件均统一适配为 48000 Hz / stereo / S16_LE；
7. 音频 ADEC + AO 等价链路已经成立；
8. 后续可以进入实时音频采集编码实验。
```

---

# 3. 四个实验的整体关系

13~16 的关系可以总结为：

```text
13：确认设备和能力
    ↓
14：确认 PCM 采集 / 播放
    ↓
15：确认 PCM → 压缩音频编码
    ↓
16：确认 压缩音频 → PCM 解码 → 播放
```

完整闭环为：

```text
ES8388 codec
    ↓
ALSA hw:2,0 采集
    ↓
PCM S16_LE / 48kHz / stereo
    ↓
AAC / Opus / G.711 编码
    ↓
压缩音频文件
    ↓
FFmpeg 解码
    ↓
PCM WAV
    ↓
格式适配为 48kHz / stereo / S16_LE
    ↓
ALSA hw:2,0 播放
```

---

# 4. 当前阶段性成果

截至 16 实验，当前音频链路已经完成：

```text
1. 声卡枚举；
2. capture / playback 设备确认；
3. ES8388 codec 使用；
4. ALSA PCM 采集；
5. ALSA PCM 播放；
6. WAV 文件保存；
7. raw PCM 文件保存；
8. ffprobe 音频参数分析；
9. volumedetect 音量分析；
10. AAC M4A 编码；
11. AAC ADTS 编码；
12. Opus OGG 编码；
13. G.711 A-law 编码；
14. G.711 μ-law 编码；
15. AAC 解码；
16. Opus 解码；
17. G.711 解码；
18. 解码后重采样；
19. 解码后声道转换；
20. 解码音频重新播放。
```

这说明项目已经从“只有视频”扩展到了“具备音频输入 / 输出 / 编码 / 解码基础能力”。

---

# 5. 当前问题与注意点

## 5.1 ES8388 硬件声道限制

`hw:2,0` 当前硬件参数要求：

```text
CHANNELS: 2
FORMAT: S16_LE / S24_LE
RATE: 8000 ~ 96000
```

因此底层实验建议使用：

```text
48000 Hz / stereo / S16_LE
```

如果需要 mono：

```text
不要直接用 hw:2,0 录 mono；
应当先采集 stereo，再用 FFmpeg 转 mono；
或者使用 plughw:2,0 让 ALSA 插件层转换。
```

## 5.2 录音电平偏低

当前录音：

```text
mean_volume: -60.4 dB
max_volume : -30.4 dB
```

说明不是全静音，但音量偏低。

后续可优化方向：

```text
1. 检查 ES8388 mixer 输入通道；
2. 调整 Capture Volume / PGA / ADC 相关增益；
3. 确认麦克风硬件是否正确连接；
4. 如果只是实验验证，可以临时用 FFmpeg volume=12dB 增益；
5. 真正工程中应优先从硬件 mixer 增益解决，而不是只靠软件放大。
```

## 5.3 G.711 的定位

G.711 已经跑通，但它更适合语音通信，而不是高质量音频。

特点：

```text
采样率：8000 Hz
声道：mono
码率：64 kb/s
类型：窄带语音编码
```

后续项目推荐：

```text
RTSP / MP4 / HLS：优先 AAC
WebRTC：优先 Opus
传统语音通话 / 兼容性测试：可用 G.711
```

---

# 6. 和全志音频模块的对应关系

| 全志模块 | 当前 RK3588 实验对应内容 | 当前完成情况 |
|---|---|---|
| AI | ALSA `arecord` / `hw:2,0` 采集 PCM | 14 已完成 |
| AO | ALSA `aplay` / `hw:2,0` 播放 PCM | 14、16 已完成 |
| AENC | FFmpeg AAC / Opus / G.711 编码 | 15 已完成 |
| ADEC | FFmpeg AAC / Opus / G.711 解码 | 16 已完成 |
| MUX | 音频与视频封装到 MP4 / RTSP / HLS / WebRTC | 后续 18 / 19 |
| AVSync | 音视频 PTS 同步 | 后续 20 |

因此当前阶段已经补齐了全志路线中的音频基础模块，但还没有进入音视频合流与同步。

---

# 7. 后续实验建议

虽然当前先暂停 17，但后续合理路线是：

```text
17_realtime_audio_capture_encode
    实时 ALSA 采集 → AAC / Opus / G.711 编码文件 / RTSP 音频流

18_av_mux_file
    已有检测 MP4 + AAC 音频 → 合成带音频的 MP4 文件

19_realtime_av_stream
    实时视频 H.264 + 实时音频 AAC → RTSP / HLS / WebRTC 推流

20_av_sync_stability_profile
    音视频同步、资源占用、稳定性、延迟观测
```

其中 18 和 19 是把当前音频实验真正接回 00~12 的视频流媒体链路。

最终希望形成：

```text
摄像头 /dev/video11
    ↓
V4L2 + RGA + RKNN
    ↓
MPP H.264 编码
    ↓
视频码流

ES8388 / hw:2,0
    ↓
ALSA 采集 PCM
    ↓
AAC / Opus 编码
    ↓
音频码流

视频码流 + 音频码流
    ↓
FFmpeg MUX
    ↓
RTSP / HLS / WebRTC / MP4
```

---

# 8. 简历表述草稿

当前做到 16 实验后，可以谨慎写成：

```text
在 RK3588 平台完成端侧音频链路验证，基于 ALSA 枚举并测试 ES8388 codec 采集与播放能力，实现 48kHz / stereo / S16_LE PCM 音频采集、WAV 保存及播放；基于 FFmpeg 完成 AAC、Opus、G.711 A-law / μ-law 编码与解码验证，并将解码后的不同格式音频统一转换为声卡可播放的 PCM 格式，为后续音视频封装、RTSP/HLS/WebRTC 推流和音视频同步实验提供基础。
```

等后续 18~20 做完后，可以升级为：

```text
完成 RK3588 端侧音视频一体化流媒体链路，视频侧基于 V4L2/RGA/RKNN/MPP 实现 AI 检测与 H.264 编码，音频侧基于 ALSA/ES8388 完成 PCM 采集与 AAC/Opus 编码，并通过 FFmpeg/MediaMTX 实现音视频封装、RTSP/HLS/WebRTC 实时预览及稳定性评估。
```

---

# 9. 最终结论

13~16 四个实验完成后，可以确认：

```text
1. RK3588 板端音频设备可用；
2. ES8388 codec 可作为主要音频输入 / 输出设备；
3. ALSA PCM 采集链路可用；
4. ALSA PCM 播放链路可用；
5. AAC 编码 / 解码链路可用；
6. Opus 编码 / 解码链路可用；
7. G.711 A-law / μ-law 编码 / 解码链路可用；
8. 解码后的音频可以统一转换为 hw:2,0 可播放格式；
9. 当前音频基础链路已经具备接入后续音视频合流实验的条件。
```

当前最关键的阶段性结论：

```text
项目已经从“纯视频 AI 流媒体链路”扩展为“具备音频采集、播放、编码、解码能力的音视频系统雏形”。
```

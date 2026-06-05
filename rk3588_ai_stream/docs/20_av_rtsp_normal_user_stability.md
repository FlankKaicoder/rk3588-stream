# 20 音视频双轨 RTSP 普通用户稳定性实验记录

## 1. 实验背景

前面已经完成了 01~12 的视频流实验，以及 13~19 的音频采集、AAC 编码、音视频合流与 RTSP 双轨预览实验。实验 20 的目标是在这些基础上完成一个更完整的普通用户版稳定性验证：

```text
V4L2 摄像头采集
    → RGA NV12 → RGB
    → RKNN YOLO11 推理
    → 后处理与画框
    → RGA RGB → NV12
    → MPP H.264 编码
    → FFmpeg 读取 H.264 FIFO

ALSA hw:2,0 音频采集
    → FFmpeg AAC 编码

H.264 + AAC
    → RTSP 推流
    → MediaMTX
    → VLC / ffprobe 拉流验证
```

实验 20 中还处理了一个长期遗留问题：

```text
YOLO11 letterbox 阶段每帧触发 RGA_COLORFILL fail: Invalid argument
```

这个问题虽然不一定阻断推理和推流，但会严重污染日志，也会影响长期稳定性分析。因此实验 20 同时完成：

```text
1. RGA_COLORFILL 刷屏问题修复；
2. 视频单轨 RTSP 验证；
3. 音频单轨 RTSP 验证；
4. 普通用户音视频双轨 RTSP 验证；
5. 120 秒稳定性测试。
```

---

## 2. 实验目标

本实验希望达到：

```text
RGA_COLORFILL              = 0
Failed to call RockChipRga = 0
xrun                       = 0
Thread message queue block = 0
Timestamps are unset       = 0
ffprobe 能看到 H.264 + AAC 双轨
VLC 能看到画面并听到声音
检测端 wall_fps 接近 20FPS
MPP 编码帧率接近 20FPS
```

---

## 3. 初始问题现象

实验 20 初始 240 秒链路测试中，音视频双轨本身能识别，但日志中出现大量 RGA 报错：

```text
RGA_COLORFILL              2534
Failed to call RockChipRga 1267
```

当时检测端结果为：

```text
frames              : 1267
wall_fps            : 20.224
```

同时音频和 RTSP 侧的典型问题没有出现：

```text
xrun                       0
Timestamps are unset       0
Thread message queue block 0
```

因此当时判断：

```text
主链路问题不在音频；
也不在 RTSP 双轨本身；
而集中在 YOLO11 内部预处理 letterbox 灰边填充阶段。
```

---

## 4. RGA_COLORFILL 问题定位

YOLO11 模型输入为 640x640，摄像头输入为 1280x720。为了不拉伸图像，需要做 letterbox：

```text
1280x720
    ↓ 等比例缩放 0.5 倍
640x360
    ↓ 上下补灰边
640x640
```

灰边通常填充：

```text
114, 114, 114
```

日志中也出现过：

```text
color=0x72727272
```

其中：

```text
0x72 = 114
```

说明它确实是在填 YOLO letterbox 常用灰边颜色。

问题发生位置在鲁班猫公共图像处理工具中：

```text
/home/cat/lubancat_ai_manual_code/example/utils/image_utils.c
```

而不是最初以为的：

```text
/home/cat/lubancat_ai_manual_code/example/yolo11/cpp/utils/image_utils.c
```

原因是当前工程虽然从：

```text
/home/cat/lubancat_ai_manual_code/example/yolo11/cpp
```

迁移 YOLO11 demo 主体代码，但 yolo11/cpp 本身依赖的是上层公共 utils：

```text
/home/cat/lubancat_ai_manual_code/example/utils
```

---

## 5. 工程结构清理：迁移公共 utils 到 third_party

为了避免直接修改官方示例源码，本实验将公共 utils 复制到当前工程内：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p third_party

cp -a /home/cat/lubancat_ai_manual_code/example/utils   third_party/lubancat_common_utils
```

迁移后，当前工程结构变为：

```text
rk3588_ai_stream
├── CMakeLists.txt
├── src
├── scripts
├── output
├── docs
└── third_party
    └── lubancat_common_utils
        ├── image_utils.c
        ├── image_utils.h
        ├── file_utils.c
        ├── file_utils.h
        ├── image_drawing.c
        └── ...
```

然后修改 `CMakeLists.txt`：

原来：

```cmake
add_subdirectory(${LUBANCAT_EXAMPLE_DIR}/utils utils.out)
```

改为：

```cmake
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/third_party/lubancat_common_utils utils.out)
```

重新编译后，确认当前实际编译的是本地副本：

```text
../third_party/lubancat_common_utils/image_utils.c
```

这样后续修改只影响当前工程，不污染官方 `lubancat_ai_manual_code` 目录。

---

## 6. RGA_COLORFILL 修复方法

原始逻辑大致是：

```c
if (drect.width != dstWidth || drect.height != dstHeight) {
    im_rect dst_whole_rect = {0, 0, dstWidth, dstHeight};
    int imcolor;
    char* p_imcolor = &imcolor;

    p_imcolor[0] = color;
    p_imcolor[1] = color;
    p_imcolor[2] = color;
    p_imcolor[3] = color;

    printf("fill dst image ... with color=0x%x\n", imcolor);

    ret_rga = imfill(rga_buf_dst, dst_whole_rect, imcolor);

    if (ret_rga <= 0) {
        if (dst != NULL) {
            size_t dst_size = get_image_size(dst_img);
            memset(dst, color, dst_size);
        } else {
            printf("Warning: Can not fill color on target image\n");
        }
    }
}
```

也就是说，官方逻辑其实已经有 CPU fallback：

```text
先尝试 RGA imfill
    ↓
RGA ColorFill 失败
    ↓
再 CPU memset
```

问题在于：

```text
RGA imfill 每帧都失败；
虽然 CPU fallback 能补救画面，但错误日志每帧刷屏。
```

因此本实验改成：

```text
不再先调用 RGA imfill；
只要需要 letterbox padding，就直接 CPU memset；
后续 resize / copy 仍然继续使用 RGA improcess。
```

修改后的核心逻辑：

```c
if (drect.width != dstWidth || drect.height != dstHeight) {
    /*
     * Original code calls RGA imfill first, then falls back to CPU memset
     * after RGA_COLORFILL fails. On RK3588 RGB888 letterbox this fails
     * every frame. Use CPU memset directly for padding, then keep RGA
     * improcess below for resize/copy.
     */
    if (dst != NULL) {
        size_t dst_size = get_image_size(dst_img);
        memset(dst, color, dst_size);
    } else {
        printf("Warning: Can not fill color on target image\n");
    }
}
```

这个修改的工程含义是：

```text
小画布灰边填充：
    CPU memset

大图像格式转换 / resize / copy：
    继续使用 RGA
```

也就是：

```text
不是放弃 RGA；
而是把容易在 RGB888 letterbox 下触发兼容性问题的 ColorFill 单独交给 CPU。
```

---

## 7. 为什么 CPU memset 可以接受

YOLO11 输入画布大小为：

```text
640 × 640 × 3 = 1,228,800 bytes ≈ 1.2MB
```

20FPS 下，每秒填充量约为：

```text
1.2MB × 20 = 24MB/s
```

对 RK3588 的 CPU 和内存带宽来说，这个量很小。

相比之下，继续让 RGA ColorFill 每帧失败会带来：

```text
1. 日志污染；
2. 调用失败开销；
3. 稳定性分析困难；
4. 长时间运行日志文件膨胀；
5. 面试 / 项目总结中难以解释。
```

因此本实验采用：

```text
CPU memset 灰边填充 + RGA 大图像转换
```

是更稳妥的工程取舍。

---

## 8. 重新编译

修改本地 `third_party/lubancat_common_utils/image_utils.c` 后，重新编译：

```bash
cd ~/projects/rk3588_ai_stream

rm -rf build
mkdir -p build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release
make v4l2_rga_rknn_detect_to_nv12_clean -j4
```

---

## 9. 视频单轨 RTSP 验证

为了把问题拆开，先验证视频单轨：

```text
V4L2 → RGA → RKNN → RGA → MPP H.264 → FFmpeg → MediaMTX → VLC
```

视频单轨 RTSP path：

```text
exp20_video_only
```

板端 ffprobe 成功：

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp20_video_only':
    Stream #0:0: Video: h264 (High), 1280x720
```

MediaMTX 日志显示：

```text
[path exp20_video_only] stream is available and online, 1 track (H264)
[RTSP] is publishing to path 'exp20_video_only'
[RTSP] is reading from path 'exp20_video_only', with TCP, 1 track (H264)
```

电脑端 VLC 地址：

```text
rtsp://10.198.89.221:8554/exp20_video_only
```

最终结果：

```text
VLC 能看到画面；
RGA_COLORFILL = 0；
Failed to call RockChipRga = 0。
```

视频单轨链路验证通过。

---

## 10. 音频普通用户问题排查

在修复 RGA 后，继续验证音频单轨时，曾出现普通用户音频采集卡住的问题：

```text
普通用户 arecord -l 卡住；
普通用户 arecord hw:2,0 卡住；
普通用户 ffmpeg -f alsa -i hw:2,0 卡住。
```

但是 sudo 下正常：

```text
sudo arecord -l        RC=0
sudo arecord hw:2,0    RC=0
```

并且能生成：

```text
sudo_test_hw_2_0.wav
5 秒
48000 Hz
2 channels
S16_LE
```

检查权限后发现：

```text
cat 用户已经在 audio 组；
/dev/snd/controlC2 有 user:cat:rw-；
/dev/snd/pcmC2D0c 有 user:cat:rw-；
/dev/snd/pcmC2D0p 有 user:cat:rw-。
```

所以问题不是简单权限问题。

进一步测试发现：

```text
env -i 最小环境 + 普通用户 arecord hw:2,0 成功；
env -i 最小环境 + 普通用户 ffmpeg hw:2,0 成功。
```

说明当时普通用户完整 shell 环境中可能有用户态音频服务 / 会话状态异常。

后来重启后，普通用户音频恢复：

```text
普通用户 arecord -l：RC=0
普通用户 arecord hw:2,0：RC=0
普通用户 ffmpeg -f alsa -i hw:2,0：RC=0
普通用户音频 RTSP：成功
```

因此该问题最终判断为：

```text
不是硬件问题；
不是权限问题；
不是 FFmpeg 本身问题；
更像是重启前用户态 ALSA / PulseAudio / 会话状态卡死。
```

---

## 11. 重启后普通用户音频验证

重启后普通用户 `arecord -l` 正常：

```text
**** List of CAPTURE Hardware Devices ****
card 0: rockchiphdmiin
card 2: rockchipes8388
```

普通用户直接录制 ES8388：

```bash
arecord -vvv   -D hw:2,0   -f S16_LE   -r 48000   -c 2   -d 5   output/exp20_4_audio_only_rtsp/reboot_test_hw_2_0.wav
```

结果：

```text
RC=0
Recording WAVE ...
Hardware PCM card 2 'rockchip-es8388' device 0 subdevice 0
48000 Hz
Stereo
S16_LE
```

生成文件：

```text
reboot_test_hw_2_0.wav
938K
Duration: 00:00:05.00
bitrate: 1536 kb/s
Audio: pcm_s16le, 48000 Hz, 2 channels, s16
```

普通用户 FFmpeg 本地 AAC 编码：

```bash
ffmpeg -hide_banner -y   -f alsa   -ar 48000   -ac 2   -i hw:2,0   -t 5   -c:a aac   -b:a 128k   output/exp20_4_audio_only_rtsp/reboot_test_hw_2_0.m4a
```

结果：

```text
RC=0
Input #0, alsa, from 'hw:2,0'
Audio: pcm_s16le, 48000 Hz, stereo
Output #0: AAC LC, 48000 Hz, stereo, 128 kb/s
```

音频单轨 RTSP 验证：

```text
rtsp://127.0.0.1:8554/reboot_audio_only
```

ffprobe 结果：

```text
Stream #0:0: Audio: aac (LC), 48000 Hz, stereo, fltp
```

MediaMTX：

```text
[path reboot_audio_only] stream is available and online, 1 track (MPEG-4 Audio)
```

结论：

```text
普通用户音频采集、AAC 编码、音频 RTSP 推流均恢复正常。
```

---

## 12. 普通用户 30 秒 AV 双轨验证

普通用户 30 秒测试路径：

```text
exp20_av_normal
```

ffprobe 结果：

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp20_av_normal':
    Stream #0:0: Video: h264 (High), 1280x720
    Stream #0:1: Audio: aac (LC), 48000 Hz, stereo
```

MediaMTX：

```text
[path exp20_av_normal] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
[RTSP] is publishing to path 'exp20_av_normal'
[RTSP] is reading from path 'exp20_av_normal', with TCP, 2 tracks
```

FFmpeg：

```text
Input #0, h264, from test_h264.fifo
Input #1, alsa, from hw:2,0
Output #0, rtsp, to rtsp://127.0.0.1:8554/exp20_av_normal
Stream #0:0: Video: h264
Stream #0:1: Audio: aac
```

异常统计：

```text
RGA_COLORFILL              0
Failed to call RockChipRga 0
xrun                       0
Thread message queue       0
Timestamps are unset       0
```

结论：

```text
普通用户 30 秒音视频双轨 RTSP 验证通过。
```

---

## 13. 普通用户 120 秒 AV 双轨稳定性测试

### 13.1 测试命令

创建输出目录：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp20_6_av_rtsp_normal_120s
OUT=output/exp20_6_av_rtsp_normal_120s
```

清理残留进程：

```bash
pkill -f mediamtx || true
pkill -f ffmpeg || true
pkill -f mpi_enc_test || true
pkill -f v4l2_rga_rknn_detect_to_nv12_clean || true
```

创建 FIFO：

```bash
rm -f "$OUT/test_nv12.fifo" "$OUT/test_h264.fifo"
mkfifo "$OUT/test_nv12.fifo"
mkfifo "$OUT/test_h264.fifo"
```

启动 MediaMTX：

```bash
./tools/mediamtx/mediamtx output/exp19_1_realtime_av_rtsp_fix/mediamtx_av_fix.yml   > "$OUT/mediamtx_av_normal_120s.log" 2>&1 &
```

启动 FFmpeg 普通用户音视频合流推流：

```bash
ffmpeg -nostdin -hide_banner   -fflags +genpts+nobuffer   -flags low_delay   -thread_queue_size 4096   -use_wallclock_as_timestamps 1   -f h264   -r 20   -i "$OUT/test_h264.fifo"   -thread_queue_size 4096   -f alsa   -ar 48000   -ac 2   -i hw:2,0   -map 0:v:0   -map 1:a:0   -c:v copy   -c:a aac   -b:a 128k   -ar 48000   -ac 2   -f rtsp   -rtsp_transport tcp   rtsp://127.0.0.1:8554/exp20_av_normal_120s   > "$OUT/ffmpeg_av_normal_120s.log" 2>&1 &
```

启动 MPP 编码：

```bash
/home/cat/mpp/build/test/mpi_enc_test   -i "$OUT/test_nv12.fifo"   -o "$OUT/test_h264.fifo"   -w 1280   -h 720   -f 0   -t 7   -n 2400   > "$OUT/mpi_enc_av_normal_120s.log" 2>&1 &
```

启动实时检测程序：

```bash
./build/v4l2_rga_rknn_detect_to_nv12_clean   models/yolo11.rknn   /dev/video11   1280   720   2400   "$OUT/test_nv12.fifo"   "$OUT/profile_av_normal_120s.csv"   > "$OUT/detect_av_normal_120s.log" 2>&1 &
```

电脑端 VLC：

```bash
vlc --rtsp-tcp --network-caching=800 --avcodec-hw=none   rtsp://10.198.89.221:8554/exp20_av_normal_120s
```

---

## 14. 120 秒测试结果

### 14.1 ffprobe 结果

```text
Input #0, rtsp, from 'rtsp://127.0.0.1:8554/exp20_av_normal_120s':
  Metadata:
    title           : No Name
  Duration: N/A, start: 0.102583, bitrate: N/A
    Stream #0:0: Video: h264 (High), yuvj420p(pc, progressive), 1280x720, 30 fps, 30 tbr, 90k tbn, 60 tbc
    Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, fltp
```

说明：

```text
RTSP 中包含 H.264 视频轨；
RTSP 中包含 AAC 音频轨；
音频采样率为 48000Hz；
声道为 stereo。
```

### 14.2 MediaMTX 结果

```text
[path exp20_av_normal_120s] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
[RTSP] is publishing to path 'exp20_av_normal_120s'
[RTSP] is reading from path 'exp20_av_normal_120s', with TCP, 2 tracks (H264, MPEG-4 Audio)
```

电脑端客户端：

```text
10.198.210.113
```

已经通过 RTSP TCP 读取：

```text
2 tracks (H264, MPEG-4 Audio)
```

说明：

```text
MediaMTX 发布成功；
电脑端 VLC / RTSP 客户端读取成功；
推流和拉流都不是本机单独验证，而是跨设备验证。
```

### 14.3 FFmpeg 结果

FFmpeg 成功打开两个输入：

```text
Input #0, h264, from 'output/exp20_6_av_rtsp_normal_120s/test_h264.fifo'
Input #1, alsa, from 'hw:2,0'
```

视频输入：

```text
Video: h264 (High), yuvj420p, 1280x720
```

音频输入：

```text
Audio: pcm_s16le, 48000 Hz, stereo, s16, 1536 kb/s
```

输出：

```text
Output #0, rtsp, to 'rtsp://127.0.0.1:8554/exp20_av_normal_120s'
Stream #0:0: Video: h264
Stream #0:1: Audio: aac (LC), 48000 Hz, stereo, 128 kb/s
```

运行中状态：

```text
frame=1761 fps=20 time=00:01:27.20 speed=1x
```

结束时状态：

```text
frame=2340 fps=19 time=00:02:05.03 speed=0.999x
video:33434kB
audio:1962kB
```

结束时出现：

```text
av_interleaved_write_frame(): Broken pipe
Error writing trailer ... Broken pipe
Conversion failed!
```

该错误发生在链路收尾阶段。因为：

```text
检测端已经完成 2400 帧；
MPP 已经编码 2400 帧；
MediaMTX 后续显示 publisher / reader terminated；
运行期间 xrun、queue blocking、timestamp unset 均为 0。
```

因此这个 Broken pipe 判断为：

```text
收尾阶段 RTSP 连接关闭导致；
不作为主链路失败。
```

### 14.4 检测端结果

检测端最终结果：

```text
frames              : 2400
wall_time_ms        : 115190.576
wall_fps            : 20.835
avg_select_ms       : 0.044
avg_dqbuf_ms        : 0.007
avg_rga_nv12_to_rgb : 2.640
avg_input_prepare   : 0.001
avg_model_total_ms  : 35.780
avg_draw_ms         : 0.260
avg_rga_rgb_to_nv12 : 3.277
avg_write_ms        : 5.792
avg_qbuf_ms         : 0.099
avg_total_ms        : 47.902
profile csv         : output/exp20_6_av_rtsp_normal_120s/profile_av_normal_120s.csv
output nv12/fifo    : output/exp20_6_av_rtsp_normal_120s/test_nv12.fifo
```

说明：

```text
实时检测端完成 2400 帧；
平均 wall_fps 为 20.835；
满足 20FPS 目标；
平均单帧总耗时约 47.902ms。
```

各阶段平均耗时：

```text
V4L2 select         : 0.044 ms
V4L2 dqbuf          : 0.007 ms
RGA NV12 → RGB      : 2.640 ms
输入准备             : 0.001 ms
RKNN 模型总耗时       : 35.780 ms
画框                 : 0.260 ms
RGA RGB → NV12      : 3.277 ms
FIFO write          : 5.792 ms
V4L2 qbuf           : 0.099 ms
总耗时               : 47.902 ms
```

主要耗时仍然集中在：

```text
RKNN YOLO11 推理：35.780ms
FIFO 写入：5.792ms
RGA 双向转换：2.640 + 3.277 = 5.917ms
```

### 14.5 MPP 编码结果

MPP 最终结果：

```text
encode 2400 frames
time 115288 ms
delay 3 ms
fps 20.82
bps 3498983
average frame rate 20.82
```

说明：

```text
MPP 完成 2400 帧 H.264 编码；
平均编码输出帧率 20.82FPS；
与检测端 20.835FPS 基本一致；
视频链路吞吐匹配。
```

---

## 15. 关键异常统计

120 秒测试最终统计：

```text
RGA_COLORFILL              0
Failed to call RockChipRga 0
xrun                       0
Thread message queue       0
Timestamps are unset       0
```

含义如下：

```text
RGA_COLORFILL = 0：
    YOLO11 letterbox 灰边填充已经不再触发 RGA ColorFill 失败。

Failed to call RockChipRga = 0：
    RGA 调用失败日志清零。

xrun = 0：
    ALSA 音频采集中没有出现音频缓冲欠载 / 过载。

Thread message queue blocking = 0：
    FFmpeg 没有出现输入队列阻塞警告。

Timestamps are unset = 0：
    当前合流命令中没有再出现未设置时间戳警告。
```

该结果相比实验 20 初期有明显改善：

```text
初期：
    RGA_COLORFILL              2534
    Failed to call RockChipRga 1267

最终：
    RGA_COLORFILL              0
    Failed to call RockChipRga 0
```

---

## 16. 当前完整链路

实验 20 最终普通用户链路为：

```text
/dev/video11 摄像头
    ↓ V4L2 DQBUF
NV12 1280x720
    ↓ RGA
RGB888 1280x720
    ↓ YOLO11 letterbox
640x640 RGB 输入
    ↓ RKNN YOLO11 推理
检测框 / 类别 / 置信度
    ↓ 后处理 + 画框
RGB888 1280x720
    ↓ RGA
NV12 1280x720
    ↓ FIFO
test_nv12.fifo
    ↓ MPP mpi_enc_test
H.264 Annex-B
    ↓ FIFO
test_h264.fifo
    ↓ FFmpeg input #0

ALSA hw:2,0
    ↓ FFmpeg input #1
PCM S16_LE 48000Hz stereo
    ↓ AAC 编码

H.264 + AAC
    ↓ FFmpeg RTSP mux
rtsp://127.0.0.1:8554/exp20_av_normal_120s
    ↓ MediaMTX
rtsp://10.198.89.221:8554/exp20_av_normal_120s
    ↓ VLC / ffprobe
浏览与验证
```

---

## 17. 实验中遇到的问题与解决方案

### 17.1 RGA_COLORFILL 每帧刷屏

现象：

```text
RGA_COLORFILL fail: Invalid argument
Failed to call RockChipRga interface
```

原因：

```text
YOLO11 letterbox 阶段对 640x640 RGB 目标图做 RGA imfill；
当前 RK3588 + RGB888 + RGA ColorFill 参数组合不兼容；
imfill 每帧失败，然后再 CPU fallback。
```

解决：

```text
迁移公共 utils 到工程 third_party；
修改本地 image_utils.c；
跳过 RGA imfill；
直接 CPU memset 填充 letterbox 灰边；
保留后续 RGA improcess 做 resize/copy。
```

结果：

```text
RGA_COLORFILL = 0
Failed to call RockChipRga = 0
```

---

### 17.2 最初 ffprobe / VLC 报 404

现象：

```text
method DESCRIBE failed: 404 Not Found
no stream is available on path
```

原因：

```text
RTSP path 存在，但当时 publisher 没有成功上线；
或者测试太短，VLC / ffprobe 连接时流已经结束；
也可能是 FFmpeg 卡在音频输入阶段，没有进入 RTSP Output。
```

排查方式：

```text
先拆成视频单轨；
再拆成音频单轨；
最后合成 AV 双轨。
```

结果：

```text
视频单轨成功；
音频单轨重启后普通用户成功；
AV 双轨最终成功。
```

---

### 17.3 普通用户音频卡住

现象：

```text
普通用户 arecord -l 卡住；
普通用户 arecord hw:2,0 卡住；
普通用户 ffmpeg -f alsa -i hw:2,0 卡住；
sudo 正常；
env -i 最小环境正常。
```

权限检查：

```text
cat 用户在 audio 组；
/dev/snd/controlC2 有 cat rw 权限；
/dev/snd/pcmC2D0c 有 cat rw 权限。
```

说明：

```text
不是权限问题；
不是 ES8388 硬件问题；
不是 FFmpeg 问题。
```

最终处理：

```text
重启板端后普通用户音频恢复。
```

推测：

```text
重启前可能是用户态 ALSA / PulseAudio / 会话状态异常；
重启后音频服务与 ALSA 状态恢复。
```

后续如果复现，可按以下顺序排查：

```bash
sudo fuser -v /dev/snd/* || true
ps -ef | grep -Ei "pulse|pipewire|ffmpeg|arecord" | grep -v grep || true
timeout 8 arecord -l
timeout 10 arecord -D hw:2,0 -f S16_LE -r 48000 -c 2 -d 5 test.wav
sudo timeout 10 arecord -D hw:2,0 -f S16_LE -r 48000 -c 2 -d 5 sudo_test.wav
```

如果普通用户卡住但 sudo 正常，可尝试：

```bash
pkill -f pulseaudio || true
pkill -f ffmpeg || true
pkill -f arecord || true
```

如果仍不恢复，可重启板端。

---

### 17.4 FFmpeg 结束时 Broken pipe

现象：

```text
av_interleaved_write_frame(): Broken pipe
Error writing trailer ... Broken pipe
Conversion failed!
```

判断：

```text
该错误出现在检测端和 MPP 已经完成 2400 帧之后；
MediaMTX 后续也显示 RTSP session / connection 被 terminated / EOF；
运行期间没有 xrun、queue blocking、timestamp unset；
因此该错误属于收尾阶段连接关闭问题，不是运行中推流失败。
```

后续可以优化：

```text
让 FFmpeg 受控退出；
在 FIFO 结束后主动关闭 publisher；
或者使用脚本统一管理进程生命周期。
```

---

## 18. 实验 20 最终结论

实验 20 最终完成了普通用户下的音视频双轨 RTSP 稳定性验证。

最终结果：

```text
输入视频：/dev/video11，1280x720
目标帧率：20FPS
测试帧数：2400
测试时长：约 115s
音频输入：ALSA hw:2,0，48000Hz，stereo
视频编码：MPP H.264
音频编码：FFmpeg AAC
流媒体服务：MediaMTX
播放验证：ffprobe + VLC
```

关键指标：

```text
检测端 frames              : 2400
检测端 wall_fps            : 20.835
MPP 编码 frames            : 2400
MPP 平均 fps               : 20.82
RTSP 轨道                  : H.264 + AAC
RGA_COLORFILL              : 0
Failed to call RockChipRga : 0
xrun                       : 0
Thread message queue       : 0
Timestamps are unset       : 0
```

实验结论：

```text
1. YOLO11 letterbox 阶段 RGA_COLORFILL 刷屏问题已解决；
2. 工程已从直接依赖官方 example/utils 改为引用本地 third_party/lubancat_common_utils；
3. 视频单轨 RTSP 验证通过；
4. 音频单轨 RTSP 验证通过；
5. 普通用户音视频双轨 RTSP 验证通过；
6. 120 秒稳定性测试中，H.264 + AAC 双轨可以正常上线并被 VLC / ffprobe 读取；
7. 检测端和 MPP 编码端均达到约 20FPS；
8. 当前链路已经具备作为简历项目“RK3588 边缘 AI 音视频实时推流系统”的阶段性成果。
```

---

## 19. 后续优化方向

### 19.1 封装统一脚本

当前测试命令较长，可以封装为：

```text
scripts/exp20_av_rtsp_normal_user_stability.sh
```

支持参数：

```text
width
height
fps
duration
audio_device
stream_path
```

并自动完成：

```text
清理旧进程；
创建 FIFO；
启动 MediaMTX；
启动 FFmpeg；
启动 MPP；
启动检测程序；
执行 ffprobe；
收集日志；
统计异常；
生成 summary.txt。
```

### 19.2 优化 FFmpeg 收尾

当前测试结束阶段可能出现：

```text
Broken pipe
```

可以通过脚本管理进程顺序：

```text
1. 等检测程序结束；
2. 等 MPP 编码结束；
3. 给 FFmpeg 发送 q 或 SIGINT；
4. 再关闭 MediaMTX；
5. 避免 RTSP output 端被动断开。
```

### 19.3 优化时间戳

虽然当前测试中：

```text
Timestamps are unset = 0
```

但 H.264 FIFO + ALSA 双输入合流仍然依赖 FFmpeg 生成时间戳。后续可以进一步研究：

```text
H.264 PTS / DTS 明确生成；
音视频同步策略；
FFmpeg -use_wallclock_as_timestamps；
实时 FIFO 输入的时间基；
RTSP 输出端时间戳稳定性。
```

### 19.4 降低延迟

当前 VLC 使用：

```text
--rtsp-tcp
--network-caching=800
```

后续可以测试：

```text
network-caching=500
network-caching=300
UDP RTSP
HLS 延迟
WebRTC 低延迟
```

并记录：

```text
端到端延迟；
卡顿次数；
音画同步主观表现；
丢帧情况。
```

### 19.5 改造 MPP 编码为工程内部模块

当前使用：

```text
/home/cat/mpp/build/test/mpi_enc_test
```

后续可以将 MPP 编码集成进 C++ 主程序：

```text
V4L2 捕获
RGA 预处理
RKNN 推理
MPP 编码
RTSP 推流
```

这样可以减少 FIFO 进程链路，提升工程完整性。

### 19.6 加入资源监控

后续稳定性测试可以记录：

```text
CPU 占用
内存占用
NPU 占用
RGA 占用
MPP 编码状态
进程状态
端口状态
温度
```

并生成 CSV，用于论文 / 简历 / 面试展示。

---

## 20. 面试表述建议

这个实验可以在简历或面试中描述为：

```text
在 RK3588 平台上实现了基于 V4L2 + RGA + RKNN + MPP + FFmpeg + MediaMTX 的边缘 AI 音视频实时推流链路。
系统从摄像头采集 NV12 图像，经 RGA 转换为 RGB 后输入 YOLO11 RKNN 模型进行实时目标检测，并将画框后的图像重新转换为 NV12，送入 MPP 进行 H.264 硬件编码；同时通过 ALSA 采集 ES8388 音频并由 FFmpeg 编码为 AAC，最终将 H.264 视频与 AAC 音频封装为 RTSP 双轨流，通过 MediaMTX 发布，并在 VLC 端实时预览。

在实验中排查并修复了 YOLO11 letterbox 阶段 RGA ColorFill 在 RGB888 场景下每帧失败的问题。通过将鲁班猫公共 utils 迁移到工程 third_party，并将 letterbox 灰边填充从 RGA imfill 改为 CPU memset，清除了每帧 RGA_COLORFILL fail 日志，同时保留 RGA 用于大图像格式转换。

最终普通用户下完成 120 秒稳定性测试，检测端完成 2400 帧，平均 20.835FPS，MPP 编码平均 20.82FPS，RTSP 输出包含 H.264 视频轨与 AAC 音频轨，RGA_COLORFILL、RockChipRga fail、音频 xrun、FFmpeg 队列阻塞和时间戳警告均为 0。
```

---

## 21. 本实验产物

主要输出目录：

```text
output/exp20_4_audio_only_rtsp
output/exp20_5_av_rtsp_normal_user
output/exp20_6_av_rtsp_normal_120s
```

关键日志：

```text
output/exp20_6_av_rtsp_normal_120s/detect_av_normal_120s.log
output/exp20_6_av_rtsp_normal_120s/mpi_enc_av_normal_120s.log
output/exp20_6_av_rtsp_normal_120s/ffmpeg_av_normal_120s.log
output/exp20_6_av_rtsp_normal_120s/mediamtx_av_normal_120s.log
output/exp20_6_av_rtsp_normal_120s/profile_av_normal_120s.csv
```

关键工程修改：

```text
CMakeLists.txt
third_party/lubancat_common_utils/image_utils.c
```

关键 RTSP 地址：

```text
rtsp://10.198.89.221:8554/exp20_av_normal_120s
```

---

## 22. 总结

实验 20 是整个 RK3588 AI 流媒体项目中第一个比较完整的阶段性闭环：

```text
摄像头采集
AI 推理
图像画框
硬件编码
音频采集
音频编码
音视频合流
RTSP 发布
电脑端播放
稳定性统计
问题修复
```

它把前面视频实验和音频实验真正串联了起来。

最终链路达到了：

```text
普通用户运行；
H.264 + AAC 双轨；
RTSP TCP 播放；
120 秒稳定运行；
20FPS 级实时性能；
关键异常计数为 0。
```

因此实验 20 可以作为当前项目从“单点实验”进入“完整音视频 AI 流媒体系统”的重要节点。

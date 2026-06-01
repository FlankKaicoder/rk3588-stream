#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream
mkdir -p docs

cat > docs/11_webrtc_browser_preview.md <<'EOF_MD'
# 11 WebRTC / 浏览器低延迟实时检测预览实验记录

## 1. 实验背景

前面已经完成了 10 个实验，项目已经从最初的 RKNN YOLO11 Demo 验证，逐步推进到了完整的端侧 AI 实时流媒体链路。

截至 10 实验结束，已经完成：

```text
00_lubancat_demo_baseline：验证鲁班猫官方 YOLO11 RKNN Demo 可以正常运行。
01_image_detect：单图检测迁移到自己的 rk3588_ai_stream 工程。
02_video_detect：视频文件逐帧检测，保存检测结果视频。
03_camera_detect：OpenCV VideoCapture 摄像头检测，保存检测视频。
04_camera_profile：对 OpenCV 摄像头检测链路做性能剖析，发现 OpenCV VideoCapture 是输入瓶颈。
05_v4l2_rga_realtime_preprocess：使用 V4L2 mmap 原生采集 NV12，并通过 RGA 转 RGB888，输入链路接近 30FPS。
06_v4l2_rga_rknn_detect：V4L2 + RGA + RKNN 完整检测链路，初始约 18.7FPS，瓶颈转移到 inference_yolo11_model()。
07_model_internal_profile：拆解 inference_yolo11_model() 内部耗时，定位后处理 decode、编译优化和 CPU governor 问题。
08_mpp_encode_record：接入 Rockchip MPP H.264 硬件编码，实现检测画面本地录像保存。
09_hls_stream_preview：将 MPP H.264 编码输出接入 FFmpeg HLS 切片，通过 HTTP 服务和 VLC 实现 HLS 网络预览。
10_rtsp_stream_preview：准备 MediaMTX 作为 RTSP Server，实现实时检测画面的 RTSP 推流和 VLC 预览。
```

10 实验完成后，项目已经具备摄像头采集、AI 实时检测、MPP 硬件编码、RTSP / HLS 网络预览和 VLC 客户端播放能力。

但是此时仍然主要依赖 VLC 作为播放端。实际边缘 AI 视频系统还需要支持浏览器端实时预览、Web 管理后台、远程控制台、移动端网页访问和低延迟视频交互。

因此，11 实验继续在 10 实验基础上推进：将实时检测画面通过 MediaMTX 转换为 WebRTC / HLS，使电脑浏览器可以直接打开板端地址查看检测画面。

## 2. 实验目标

11 实验的核心目标是实现浏览器端实时检测预览。

具体目标包括：复用 10 实验已经跑通的 MediaMTX；不修改 C++ 检测主程序；继续复用 V4L2 + RGA + RKNN + MPP + FFmpeg 链路；使用 MediaMTX 提供 WebRTC 服务；使用浏览器打开 WebRTC 地址查看检测画面；同时保留 HLS 和 RTSP 作为备用播放方案；对比 WebRTC、HLS、RTSP 的访问方式和适用场景；总结 WebRTC 失败时的排查路径；将项目从“VLC 可预览”升级为“浏览器可预览”。

## 3. 为什么在 RTSP 之后继续做 WebRTC？

RTSP 的优点是工程上常见，VLC、Qt、监控软件支持好，TCP 模式稳定，适合嵌入式视频系统演示。缺点是普通浏览器不能直接播放 RTSP，需要 VLC、ffplay 或专门客户端。

HLS 的优点是浏览器兼容性好、HTTP 访问简单、稳定性好，适合远程观看和弱网环境。缺点是切片机制导致延迟较高，不适合强调低延迟交互的实时检测预览。

WebRTC 的优点是浏览器原生支持、延迟低、适合实时交互，更接近“Web 控制台 / 远程监控后台”的最终形态。缺点是配置比 HLS / RTSP 复杂，依赖 UDP / ICE / 浏览器兼容性，排查难度更高。

因此，11 实验不是替代 RTSP，而是补齐浏览器端低延迟预览能力。

## 4. 11 实验总体链路

```text
摄像头 /dev/video11
        ↓
V4L2 mmap 采集 1280x720 NV12
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
NV12 FIFO
        ↓
Rockchip MPP H.264 硬件编码
        ↓
H.264 FIFO
        ↓
FFmpeg 读取 H.264 FIFO
        ↓
FFmpeg RTSP 推流到 MediaMTX
        ↓
MediaMTX 同时提供 RTSP / HLS / WebRTC
        ↓
电脑端浏览器 / VLC 播放
```

11 实验中的 WebRTC 不是检测程序直接输出的。检测程序仍然只负责输出 NV12 FIFO。WebRTC 是由检测程序、MPP 编码、FFmpeg 推流和 MediaMTX 转发共同组成的。

## 5. 实验编号说明

```text
11-0_browser_file_preview：
    MP4 文件 → FFmpeg → MediaMTX → 浏览器 WebRTC / HLS 预览。

11-1_realtime_detect_browser_preview：
    实时检测 → MPP 编码 → FFmpeg → MediaMTX → 浏览器 WebRTC / HLS 预览。
```

这样拆分是为了避免一开始就把实时摄像头、RKNN、MPP、FFmpeg、MediaMTX 和浏览器全部串在一起。先使用已有 MP4 文件验证浏览器播放链路，再切换到实时检测链路。

## 6. 当前工程路径与文件结构

当前工程路径：

```bash
~/projects/rk3588_ai_stream
```

关键文件：

```text
scripts/exp11_0_browser_file_preview.sh
scripts/exp11_1_realtime_detect_browser.sh
output/exp11_0_browser_file_preview/
output/exp11_1_realtime_detect_browser/
docs/11_webrtc_browser_preview.md
```

## 7. 11-0：文件流浏览器预览实验

11-0 不接摄像头，不跑 RKNN，只用 08 / 10 中已经生成的检测 MP4 文件作为输入，先验证 MediaMTX 的浏览器预览能力。

链路：

```text
已有检测 MP4 文件
        ↓
FFmpeg 循环读取
        ↓
FFmpeg 复制 H.264 码流
        ↓
RTSP 推送到 MediaMTX
        ↓
MediaMTX 提供 WebRTC / HLS / RTSP
        ↓
浏览器 / VLC 播放
```

输入文件：

```text
output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4
```

推流路径：

```text
exp11_file_browser
```

MediaMTX 核心配置：

```yaml
rtspAddress: :8554

hls: true
hlsAddress: :8888
hlsAllowOrigins: ["*"]
hlsVariant: lowLatency
hlsAlwaysRemux: true

webrtc: true
webrtcAddress: :8889
webrtcAllowOrigins: ["*"]
webrtcLocalUDPAddress: :8189
webrtcIPsFromInterfaces: true

paths:
  all_others:
```

11-0 执行命令：

```bash
cd ~/projects/rk3588_ai_stream
./scripts/exp11_0_browser_file_preview.sh
```

FFmpeg 推流命令核心形式：

```bash
ffmpeg -nostdin -re -stream_loop -1 \
    -i "$INPUT_MP4" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    "rtsp://127.0.0.1:8554/$STREAM_PATH"
```

播放地址示例：

```text
浏览器 WebRTC： http://10.198.89.221:8889/exp11_file_browser
浏览器 HLS：    http://10.198.89.221:8888/exp11_file_browser
VLC HLS：       http://10.198.89.221:8888/exp11_file_browser/index.m3u8
VLC RTSP：      rtsp://10.198.89.221:8554/exp11_file_browser
```

11-0 成功后，说明 MediaMTX 的 WebRTC / HLS 浏览器预览链路可用。

## 8. 11-1：实时检测浏览器预览实验

11-1 在 11-0 的基础上，将输入从已有 MP4 文件替换为实时检测链路。

链路：

```text
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
        ↓
FFmpeg RTSP 推送
        ↓
MediaMTX
        ↓
浏览器 WebRTC / HLS 预览
```

推流路径：

```text
exp11_detect_browser
```

输出目录：

```text
output/exp11_1_realtime_detect_browser
```

关键文件：

```text
realtime_detect_nv12.fifo              检测程序输出的 NV12 FIFO
realtime_detect_h264.fifo              MPP 编码器输出的 H.264 FIFO
profile_realtime_detect_browser.csv    实时检测程序性能统计 CSV
realtime_detect_to_nv12.log            检测程序日志
mpi_enc.log                            MPP 编码器日志
ffmpeg_push.log                        FFmpeg 推流日志
mediamtx.log                           MediaMTX 日志
11_1.log                               总控脚本日志
```

11-1 执行命令：

```bash
cd ~/projects/rk3588_ai_stream
./scripts/exp11_1_realtime_detect_browser.sh
```

关键参数：

```text
WIDTH=1280
HEIGHT=720
FPS=30
FRAMES=18000
```

其中 18000 帧约等于 10 分钟，方便打开浏览器观察稳定性。

检测程序命令核心形式：

```bash
sudo ./build/v4l2_rga_rknn_detect_to_nv12_clean \
    models/yolo11.rknn \
    /dev/video11 \
    "$WIDTH" \
    "$HEIGHT" \
    "$FRAMES" \
    "$NV12_FIFO" \
    "$PROFILE"
```

MPP 编码命令核心形式：

```bash
/home/cat/mpp/build/test/mpi_enc_test \
    -i "$NV12_FIFO" \
    -o "$H264_FIFO" \
    -w "$WIDTH" \
    -h "$HEIGHT" \
    -f 0 \
    -t 7 \
    -n "$FRAMES"
```

FFmpeg 推流命令核心形式：

```bash
ffmpeg -nostdin \
    -fflags nobuffer \
    -flags low_delay \
    -f h264 \
    -framerate "$FPS" \
    -i "$H264_FIFO" \
    -an \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    "rtsp://127.0.0.1:8554/$STREAM_PATH"
```

播放地址示例：

```text
浏览器 WebRTC： http://10.198.89.221:8889/exp11_detect_browser
浏览器 HLS：    http://10.198.89.221:8888/exp11_detect_browser
VLC HLS：       http://10.198.89.221:8888/exp11_detect_browser/index.m3u8
VLC RTSP：      rtsp://10.198.89.221:8554/exp11_detect_browser
```

11-1 成功后，说明检测链路、编码链路、推流链路和浏览器预览链路全部串通，RK3588 端侧 AI 检测系统已经支持浏览器实时预览。

## 9. WebRTC / HLS / RTSP 地址对比

| 方式 | 地址示例 | 客户端 | 延迟 | 稳定性 | 适用场景 |
|---|---|---|---|---|---|
| WebRTC | `http://板端IP:8889/exp11_detect_browser` | 浏览器 | 低 | 受 UDP / ICE 影响 | 浏览器低延迟预览 |
| HLS | `http://板端IP:8888/exp11_detect_browser` | 浏览器 / VLC | 较高 | 好 | 兼容性优先 |
| HLS m3u8 | `http://板端IP:8888/exp11_detect_browser/index.m3u8` | VLC | 较高 | 好 | HLS 流验证 |
| RTSP | `rtsp://板端IP:8554/exp11_detect_browser` | VLC / ffplay / Qt | 中 | TCP 模式稳定 | 工业客户端 / Qt 上位机 |

## 10. 本实验遇到或需要注意的问题

### 10.1 MediaMTX 必须允许 path

如果 MediaMTX 使用空配置启动，可能出现：

```text
path 'xxx' is not configured
```

解决方式：

```yaml
paths:
  all_others:
```

### 10.2 FFmpeg 后台运行必须加 `-nostdin`

如果 FFmpeg 后台运行时没有加 `-nostdin`，可能被 shell 挂起，表现为 `[1]+ 已停止 ffmpeg ...`。

### 10.3 WebRTC 失败时不要马上怀疑检测程序

如果 WebRTC 地址打不开，应该按下面顺序排查：

```text
1. 先打开 RTSP：rtsp://板端IP:8554/exp11_detect_browser
2. 再打开 HLS：http://板端IP:8888/exp11_detect_browser
3. 如果 RTSP / HLS 都能打开，说明主链路没问题，问题更可能在 WebRTC / UDP / ICE / 浏览器端。
4. 如果 RTSP / HLS 也打不开，再检查检测程序日志、MPP 编码日志、FFmpeg 推流日志、MediaMTX 日志。
```

### 10.4 WebRTC 可能受 UDP 端口影响

WebRTC 使用 TCP 8889 做页面 / 信令，使用 UDP 8189 做媒体传输。

排查命令：

```bash
ss -lntup | grep -E ":8554|:8888|:8889"
ss -lunp | grep -E ":8189"
tail -120 output/exp11_1_realtime_detect_browser/mediamtx.log
```

### 10.5 浏览器兼容性问题

WebRTC 对浏览器和 H.264 支持有一定要求。可以尝试 Chrome / Edge，关闭缓存刷新，或换 HLS / VLC RTSP 验证主流是否正常。

## 11. 11 实验的核心结论

11 实验成功后，当前系统能力升级为：

```text
摄像头实时采集
    ↓
V4L2 mmap
    ↓
RGA 预处理
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA 转回 NV12
    ↓
MPP H.264 硬件编码
    ↓
FFmpeg / MediaMTX
    ↓
RTSP / HLS / WebRTC
    ↓
VLC / 浏览器实时预览
```

项目已经具备板端摄像头实时采集、板端 NPU 实时目标检测、RGA 硬件图像格式转换、MPP H.264 编码、本地 H.264 / MP4 录像保存、HLS 网络预览、RTSP 网络预览、WebRTC 浏览器低延迟预览、VLC 客户端预览和浏览器端预览能力。

这意味着项目已经从单纯 RKNN 推理 Demo 发展为 RK3588 端侧 AI 实时视频分析与流媒体预览系统。

## 12. 和前面实验的关系

```text
00 / 01：证明 RKNN YOLO11 单图推理可用。
02 / 03：证明视频文件和摄像头检测逻辑可用。
04：找到 OpenCV VideoCapture 是瓶颈。
05：用 V4L2 mmap + RGA 替代 OpenCV 输入链路。
06：接入 RKNN，完成 V4L2 + RGA + RKNN 实时检测。
07：优化推理链路，使完整检测达到接近 30FPS。
08：接入 MPP H.264 编码，实现本地录像。
09：接入 HLS，实现 HTTP 网络预览。
10：接入 RTSP，实现 VLC 实时预览。
11：接入 WebRTC，实现浏览器低延迟实时预览。
```

因此 11 实验是一个系统级闭环实验，不是单点功能验证。

## 13. 当前项目可以如何表述

简历项目主线可以写成：

```text
基于 RK3588 构建端侧 AI 实时视频分析系统，实现 V4L2 摄像头采集、RGA 图像预处理、RKNN YOLO11 推理、MPP H.264 硬件编码，并通过 RTSP / HLS / WebRTC 支持 VLC 与浏览器端实时预览。
```

更技术化一点可以写成：

```text
设计并实现 RK3588 端侧 AI 流媒体处理链路，采用 V4L2 mmap 采集 RKISP 输出的 NV12 图像，利用 RGA 完成 NV12/RGB888 双向转换，接入 RKNN Runtime 完成 YOLO11 实时检测，使用 Rockchip MPP 进行 H.264 硬件编码，并通过 MediaMTX 提供 RTSP、HLS、WebRTC 多协议预览能力。
```

强调优化过程可以写：

```text
通过性能剖析定位 OpenCV VideoCapture 输入瓶颈，改用 V4L2 mmap 原生采集和 RGA 硬件预处理，将输入链路提升至接近 30FPS；进一步拆解 RKNN 推理和 YOLO 后处理耗时，结合 Release/O3 编译优化和 CPU performance governor，使完整检测链路稳定接近实时。
```

## 14. 后续实验方向

11 实验完成后，不建议马上继续堆新协议。下一步更有价值的是做：

```text
12_stream_latency_stability_profile
```

也就是端到端延迟与稳定性评估实验。

主要评估：RTSP 延迟、HLS 延迟、WebRTC 延迟、VLC 播放稳定性、浏览器播放稳定性、CPU 占用、NPU 推理耗时、RGA 转换耗时、MPP 编码稳定性、长时间运行是否掉帧、卡死或断流。

最终形成类似表格：

| 协议 | 客户端 | 延迟 | 稳定性 | 优点 | 缺点 | 适合场景 |
|---|---|---|---|---|---|---|
| HLS | 浏览器 / VLC | 高 | 好 | 兼容性最好 | 延迟高 | 远程观看 |
| RTSP TCP | VLC / Qt | 中 | 很好 | 工程稳定 | 浏览器不能直接播 | 工业客户端 |
| WebRTC | 浏览器 | 低 | 需要实测 | 浏览器低延迟 | 配置复杂 | Web 控制台 |

## 15. 本实验总结

11 实验完成了文件流浏览器预览、实时检测浏览器预览、MediaMTX WebRTC / HLS 配置、RTSP / HLS / WebRTC 多协议访问、VLC / 浏览器双客户端验证。

最终证明当前 RK3588 AI 流媒体项目已经具备完整演示形态：板端实时检测、板端硬件编码、网络推流、VLC 预览、浏览器预览和 WebRTC 低延迟访问。

项目主线已经从底层采集、硬件加速、NPU 推理、硬件编码，推进到了完整的网络预览系统。
EOF_MD

echo "docs/11_webrtc_browser_preview.md written."
ls -lh docs/11_webrtc_browser_preview.md

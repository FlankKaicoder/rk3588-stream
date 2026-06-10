# rk3588_ai_stream 实验文档索引

> 项目：RK3588 端侧 AI 音视频实时检测推流系统  
> 平台：LubanCat / RK3588  
> 主链路：V4L2 + RGA + RKNN + MPP + ALSA + AAC + FFmpeg + MediaMTX + RTSP

---

## 1. 基础迁移阶段

| 编号 | 文档 | 内容 |
|---|---|---|
| 00 | `00_lubancat_demo_baseline.md` | 鲁班猫官方 YOLO11 RKNN Demo 基线验证 |
| 01 | `01_image_detect_migration.md` | 单图检测迁移到自有工程 |
| 02 | `02_video_detect_migration.md` | 视频文件逐帧检测迁移 |
| 03 | `03_camera_detect_migration.md` | OpenCV 摄像头检测迁移 |

---

## 2. 摄像头采集与推理优化阶段

| 编号 | 文档 | 内容 |
|---|---|---|
| 04 | `04_camera_profile_v4l2_rga_summary.md` | OpenCV 摄像头链路性能剖析，定位 VideoCapture 瓶颈 |
| 05 | `05_v4l2_rga_realtime_preprocess.md` | V4L2 mmap + RGA 实时预处理 |
| 06 | `06_v4l2_rga_rknn_detect.md` | V4L2 + RGA + RKNN 实时检测 |
| 07 | `07_model_internal_profile_summary.md` | YOLO11 推理内部性能剖析与 Release / O3 / performance 优化 |

---

## 3. 视频编码与流媒体阶段

| 编号 | 文档 | 内容 |
|---|---|---|
| 08 | `08_mpp_encode_record.md` | MPP H.264 编码录像实验 |
| 09 | `09_hls_stream_preview.md` | HLS 实时检测预览 |
| 10 | `10_rtsp_stream_preview.md` | RTSP 实时检测预览 |
| 11 | `11_webrtc_browser_preview.md` | WebRTC / 浏览器实时检测预览 |
| 12 | `12_stream_latency_stability_profile.md` | 端到端流媒体稳定性与资源评估 |

---

## 4. 音频与音视频合流阶段

| 编号 | 文档 | 内容 |
|---|---|---|
| 13~16 | `13_16_audio_experiments_summary.md` | 音频设备探测、PCM 采集播放、AAC / Opus / G.711 编解码 |
| 17~19 | `17_19_realtime_audio_video_experiments_summary.md` | 实时音频编码、文件音视频封装、实时 AV RTSP 双轨推流 |
| 20 | `20_av_rtsp_normal_user_stability.md` | 普通用户音视频双轨 RTSP 稳定性与 RGA_COLORFILL 修复 |

---

## 5. 自研 MPP 与最终系统阶段

| 编号 | 文档 | 内容 |
|---|---|---|
| 21 | `21_integrated_async_mpp_rtsp_summary.md` | 自研 C++ MPP H.264 编码封装与异步 RTSP 推流 |
| 22 | `22_av_async_mpp_rtsp.md` | 自研异步 MPP 编码 + ALSA + AAC + RTSP 双轨最终集成 |
| 23 | `23_final_stability_profile.md` | 9000 帧 / 300 秒最终系统级稳定性与资源占用验收 |

---

## 6. 最终运行脚本

| 脚本 | 作用 |
|---|---|
| `scripts/run_final_av_rtsp.sh` | 最终音视频 AI 检测 RTSP 一键运行 |
| `scripts/check_final_stream.sh` | 检查最终 RTSP 状态、ffprobe、资源、异常 |
| `scripts/stop_final_stream.sh` | 停止最终推流相关进程 |
| `scripts/exp23_final_stability_300s.sh` | 300 秒最终稳定性验收 |
| `scripts/exp23_resource_monitor.sh` | 资源占用采样 |

---

## 7. 最终系统链路

```text
/dev/video11
    → V4L2 mmap NV12
    → RGA NV12/RGB
    → RKNN YOLO11
    → YOLO11 后处理与画框
    → RGA RGB/NV12
    → 自研异步 MPP H.264 编码
    → H.264 FIFO
    → FFmpeg

ALSA hw:2,0
    → FFmpeg AAC 编码

H.264 + AAC
    → FFmpeg RTSP MUX
    → MediaMTX
    → VLC / ffprobe / 浏览器辅助验证
```

---

## 8. 最终验收结果

9000 帧 / 约 300 秒最终稳定性测试通过。

```text
frames = 9000
wall_fps = 29.992
avg_model_total_ms = 27.360ms
avg_total_ms = 33.283ms

async_encoded_frames = 9000
async_encode_failures = 0
async_drop_frames = 0
async_avg_total_ms = 3.119ms
```

ffprobe：

```text
Video: H.264 High Profile, 1280x720, 30fps
Audio: AAC LC, 48000Hz, stereo
```

MediaMTX：

```text
stream is available and online, 2 tracks (H264, MPEG-4 Audio)
```

异常检查：

```text
RGA_COLORFILL = 0
Failed to call RockChipRga = 0
xrun = 0
Thread message queue blocking = 0
Timestamps are unset = 0
Broken pipe = 0
```

资源状态：

```text
CPU 温度约 40.7℃ ~ 41.6℃
CPU 平均频率约 2076.0MHz
流媒体相关进程 CPU 合计约 49%
流媒体相关进程 RSS 约 140MB
MemAvailable 约 14.6GB
```

---

## 9. 文档整理建议

建议最终 docs 目录保留以下核心文档：

```text
docs/00_lubancat_demo_baseline.md
docs/01_image_detect_migration.md
docs/02_video_detect_migration.md
docs/03_camera_detect_migration.md
docs/04_camera_profile_v4l2_rga_summary.md
docs/05_v4l2_rga_realtime_preprocess.md
docs/06_v4l2_rga_rknn_detect.md
docs/07_model_internal_profile_summary.md
docs/08_mpp_encode_record.md
docs/09_hls_stream_preview.md
docs/10_rtsp_stream_preview.md
docs/11_webrtc_browser_preview.md
docs/12_stream_latency_stability_profile.md
docs/13_16_audio_experiments_summary.md
docs/17_19_realtime_audio_video_experiments_summary.md
docs/20_av_rtsp_normal_user_stability.md
docs/21_integrated_async_mpp_rtsp_summary.md
docs/22_av_async_mpp_rtsp.md
docs/23_final_stability_profile.md
docs/experiment_index.md
```

---

## 10. 项目当前状态

当前项目已经完成从官方 YOLO11 RKNN Demo 到最终音视频双轨实时检测推流系统的完整迁移和工程化：

```text
官方 Demo 验证
    → 单图检测
    → 视频文件检测
    → 摄像头检测
    → V4L2/RGA 输入优化
    → RKNN 推理性能剖析
    → MPP H.264 编码
    → HLS/RTSP/WebRTC 网络预览
    → 音频采集与编码
    → 音视频双轨 RTSP
    → 自研 MPP 编码封装
    → 异步 MPP 编码线程
    → 9000 帧 / 300 秒最终稳定性验收
```

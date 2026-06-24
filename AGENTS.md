# 仓库指南

## 项目结构与模块组织

当前项目位于 `rk3588_ai_stream/`。C++ 源码在 `src/`，公共头文件在 `include/`，LubanCat 参考代码在 `third_party/`。运行资产分布在 `models/`（RKNN 模型）、`model/`（标签文件）、`input/`（测试媒体）和 `tools/mediamtx/`（RTSP 服务端文件）。脚本流程在 `scripts/`，实验记录和稳定性报告在 `docs/`。`build/` 是生成目录，不要手动修改。

## 构建、测试与开发命令

请在 RK3588/LubanCat 环境中，从 `rk3588_ai_stream/` 目录执行命令，并确保已安装 OpenCV、RKNN Runtime、RGA、MPP、FFmpeg、ALSA 和 MediaMTX。

```bash
rm -rf build && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async -j4
```

以上命令会构建最终的异步检测与 MPP H.264 编码目标。其他目标可用 `make <target> -j4` 构建，例如 `image_detect`、`video_detect` 或 `v4l2_capture_profile`。

```bash
./scripts/run_final_av_rtsp.sh
./scripts/check_final_stream.sh final_ai_av_rtsp
./scripts/stop_final_stream.sh
```

这些脚本分别用于启动、检查和停止最终音视频 RTSP 推流链路。

## 编码风格与命名规范

项目使用 C++17 和 CMake。保持现有代码风格：函数左大括号另起一行，控制语句左大括号跟随同一行。使用 4 空格缩进，函数和变量使用 `snake_case`，CMake 目标名应对应实验阶段，例如 `exp21_detect_mpp_encode_async`。硬件相关常量应靠近对应管线代码或脚本默认参数，并显式记录帧率、延迟、丢帧和错误计数。

## 测试指南

本仓库没有独立单元测试框架。验证修改时，应构建受影响目标，并在目标硬件上运行对应脚本或可执行文件。涉及推流的改动，需要记录 `ffprobe`/VLC 检查结果，并确认 MediaMTX 显示 H.264 与 AAC 双轨在线。性能相关改动应在 `docs/` 中补充帧数、FPS、延迟、丢帧、编码失败和资源占用。

## 提交与 Pull Request 指南

近期提交使用过 `21exp`、`22md`、`resume` 等短标题。后续建议使用更清晰的祈使句标题，例如 `Add async RTSP validation notes` 或 `Fix MPP encoder timestamp handling`。PR 应包含变更摘要、影响的目标或脚本、硬件假设（如 `/dev/video*`、ALSA 设备）、验证命令和实测结果，并链接相关实验文档或 issue。

## 安全与配置建议

不要提交板端私有信息、私有推流地址或大型生成文件。设备路径和音频设备覆盖项应保留在脚本或命令示例中。除非明确进行模型升级，否则不要修改已提交的模型文件。

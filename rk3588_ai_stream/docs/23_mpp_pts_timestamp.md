# 23 MPP 编码端 PTS 时间戳补全与 Header API 修复实验记录

> 项目路径：`~/projects/rk3588_ai_stream`  
> 实验范围：`23_mpp_pts_timestamp`  
> 当前阶段目标：在实验21/22已经完成的自研异步 MPP H.264 编码链路基础上，为编码端补全可追踪的 PTS 时间戳，并修复 MPP Header 获取方式导致的资源释放 warning，为后续 MP4 MUX、历史文件回放、Demux/VDEC 实验打基础。

---

## 1. 实验背景

截至实验22，项目已经形成了较完整的 RK3588 端侧 AI 音视频实时检测推流链路：

```text
/dev/video11 摄像头
    ↓
V4L2 mmap 采集 1280x720 NV12
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
YOLO11 后处理与检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
自研 C++ MppH264Encoder
    ↓
异步 MPP H.264 编码线程
    ↓
H.264 FIFO
    ↓
FFmpeg + ALSA 音频采集 + AAC 编码
    ↓
MediaMTX
    ↓
RTSP H.264 + AAC 双轨预览
```

实验21已经完成了自研 MPP H.264 编码器和异步编码线程，实验22完成了音视频双轨 RTSP 集成。

但是实验21/22中，视频编码侧仍然存在一个重要工程缺口：

```text
编码线程可以输出 H.264 packet，
但工程侧没有显式维护每个 packet 的 PTS / DTS 时间戳。
```

这对实时预览影响不明显，因为实验22阶段仍然借助 FFmpeg 从 H.264 FIFO 中读取裸流并自行推断时间戳。但是后续如果要做：

```text
1. 自己封装 MP4；
2. 本地录制历史文件；
3. 根据时间戳回放历史流；
4. Demux MP4 后再 VDEC 解码；
5. 音视频同步；
6. 远程文件管理与录像检索；
```

就必须在编码端明确记录：

```text
frame_id
input_pts_us
packet_pts_us
packet_dts_us
queue_delay_ms
encode_wall_ms
packet_size
```

因此实验23的核心目标是：

```text
把“裸 H.264 packet 输出”升级为“带时间戳元数据的编码 packet 输出”。
```

---

## 2. 实验目标

实验23主要验证以下内容：

```text
1. 为进入异步 MPP 编码线程的每一帧增加 frame_id；
2. 按 30FPS 为每一帧生成 input_pts_us；
3. 通过 mpp_frame_set_pts() 将 input_pts_us 写入 MppFrame；
4. 编码完成后通过 mpp_packet_get_pts() 从 MppPacket 读回 packet PTS；
5. 记录 mpp_packet_get_dts() 的返回情况；
6. 输出独立的 PTS CSV 文件；
7. 验证 300 帧 frame_id 连续、PTS 单调递增、input PTS 与 packet PTS 完全一致；
8. 观察异步队列等待时间和 MPP 编码耗时；
9. 修复实验中发现的 MPP Header 获取 unsafe API 和 release warning；
10. 为后续实验24的 MP4 MUX 提供有效 PTS / effective DTS 设计依据。
```

---

## 3. 实验前的问题

实验22结束后，当前链路虽然可以实时编码、推流和预览，但编码输出层面仍然类似：

```text
std::vector<uint8_t> h264_packet
```

也就是只有数据本身，没有严格的时间信息。

这种方式的问题是：

```text
1. 无法知道每个 packet 对应哪一帧；
2. 无法知道 packet 应该在什么时间显示；
3. 后续 MP4 mux 时无法直接生成 AVPacket.pts / AVPacket.dts；
4. 后续历史流回放时无法按照原始时间节奏播放；
5. 音视频同步只能依赖外部工具估算；
6. 不能形成工程上可靠的 EncodedPacket 数据结构。
```

因此，实验23不是单纯“继续推流”，而是为项目从实时推流系统升级到可录制、可回放、可封装、可解码的完整流媒体系统补齐时间戳基础。

---

## 4. 本次实验最终链路

实验23在实验21的自研异步 MPP 编码链路上修改：

```text
V4L2 摄像头采集
    ↓
RGA NV12 → RGB888
    ↓
RKNN YOLO11 推理
    ↓
检测框绘制
    ↓
RGA RGB888 → NV12
    ↓
构造 Exp21EncFrame
    ├── frame_id
    ├── pts_us
    ├── enqueue_ts_us
    └── nv12 data
    ↓
异步编码队列
    ↓
编码线程
    ├── set_next_pts_us(item.pts_us)
    ├── mpp_frame_set_pts(frame, pts_us)
    ├── MPP H.264 encode
    ├── mpp_packet_get_pts(packet)
    ├── mpp_packet_get_dts(packet)
    ├── mpp_packet_get_flag(packet)
    └── 写入 PTS CSV
    ↓
H.264 文件输出
```

最终输出除了裸 H.264 文件和 profile CSV，还新增：

```text
<output_h264>.pts.csv
```

例如最终成功输出：

```text
output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264
output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264.pts.csv
output/exp23_3_header_sync_buffer_300f/profile_exp23_3_header_sync_buffer_300f.csv
output/exp23_3_header_sync_buffer_300f/run.log
```

---

## 5. 涉及文件

本次实验主要修改：

```text
include/mpp_h264_encoder.hpp
src/mpp_h264_encoder.cpp
src/main_exp21_detect_mpp_encode_async.cpp
```

最终成功脚本：

```text
scripts/exp23_3_fix_header_sync_buffer.sh
```

最终成功输出目录：

```text
output/exp23_3_header_sync_buffer_30f
output/exp23_3_header_sync_buffer_300f
```

实验过程中产生但最终归档/清理的中间脚本和输出包括：

```text
release probe 调试脚本
release inner probe 调试脚本
错误的 MPP_ENC_GET_HDR_SYNC 空 packet 尝试版本
safe restore 临时恢复版本
旧的 exp23_2 带 release warning 的输出
```

---

## 6. 关键代码改动一：MppH264Encoder 增加 PTS 接口

### 6.1 头文件新增接口

在 `include/mpp_h264_encoder.hpp` 中新增：

```cpp
void set_next_pts_us(int64_t pts_us);
int64_t last_packet_pts_us() const;
int64_t last_packet_dts_us() const;
uint32_t last_packet_flags() const;
bool last_packet_is_intra() const;
```

新增内部成员：

```cpp
int64_t next_pts_us_ = -1;
int64_t last_packet_pts_us_ = -1;
int64_t last_packet_dts_us_ = -1;
uint32_t last_packet_flags_ = 0;
```

这些接口的作用是：

```text
set_next_pts_us():
    在调用 encode() 前设置当前输入帧的 PTS。

last_packet_pts_us():
    编码完成后读取 MPP 输出 packet 的 PTS。

last_packet_dts_us():
    编码完成后读取 MPP 输出 packet 的 DTS。

last_packet_flags():
    读取 packet flag，用于后续判断关键帧。

last_packet_is_intra():
    封装 intra / IDR 判断，当前实验中发现该 flag 暂不可靠。
```

---

## 7. 关键代码改动二：MppFrame 写入 PTS

在 `src/mpp_h264_encoder.cpp` 的 `encode()` 中，构造 MppFrame 后新增：

```cpp
mpp_frame_set_buffer(frame, frame_buf);

if (next_pts_us_ >= 0) {
    mpp_frame_set_pts(frame, next_pts_us_);
}

mpp_frame_set_eos(frame, 0);
```

这一步的意义是：

```text
把工程侧生成的 input_pts_us 写入 MPP 编码输入帧。
```

如果该链路有效，后面从 MppPacket 读回来的 PTS 应该和 input_pts_us 一致。

---

## 8. 关键代码改动三：MppPacket 回读 PTS / DTS / flags

在 `encode_get_packet()` 成功返回 packet 后新增：

```cpp
last_packet_pts_us_ = mpp_packet_get_pts(packet);
last_packet_dts_us_ = mpp_packet_get_dts(packet);
last_packet_flags_ = mpp_packet_get_flag(packet);
```

然后再读取码流数据：

```cpp
void *ptr = mpp_packet_get_pos(packet);
size_t len = mpp_packet_get_length(packet);

if (ptr != nullptr && len > 0)
{
    const uint8_t *p = static_cast<const uint8_t *>(ptr);
    out_packet.assign(p, p + len);
    got_packet = true;
}
```

这一步验证的是：

```text
mpp_frame_set_pts(frame, pts)
        ↓
MPP encoder
        ↓
mpp_packet_get_pts(packet)
```

是否能够完整传递。

---

## 9. 关键代码改动四：异步编码帧结构增加时间戳

在 `src/main_exp21_detect_mpp_encode_async.cpp` 中，异步编码队列中的结构从原来只包含 `frame_id` 和 `nv12` 数据，扩展为：

```cpp
struct Exp21EncFrame
{
    int frame_id = 0;
    int64_t pts_us = -1;
    int64_t enqueue_ts_us = -1;
    std::vector<uint8_t> nv12;
};
```

其中：

```text
frame_id:
    当前帧编号，从 0 开始递增。

pts_us:
    当前帧显示时间戳，单位微秒。

enqueue_ts_us:
    当前帧进入异步编码队列的时间，用于计算 queue_delay_ms。

nv12:
    当前帧经过检测框绘制后重新转换得到的 NV12 图像数据。
```

---

## 10. 关键代码改动五：生成 input_pts_us

主线程把帧推入异步编码队列时，按帧号和目标帧率生成 PTS：

```cpp
enc_frame.frame_id = frame_id;
enc_frame.pts_us = (int64_t)frame_id * 1000000LL / (int64_t)mpp_fps;
enc_frame.enqueue_ts_us = exp23_now_us();
```

当前目标帧率：

```text
mpp_fps = 30
```

所以理论上：

```text
frame 0   -> 0 us
frame 1   -> 33333 us
frame 2   -> 66666 us
frame 3   -> 100000 us
...
frame 299 -> 9966666 us
```

由于 `1000000 / 30 = 33333.333...`，整数微秒无法表达小数，因此间隔会在：

```text
33333 us / 33334 us
```

之间波动，这是正常现象。

---

## 11. 关键代码改动六：编码线程写 PTS CSV

编码线程中新增 PTS CSV 文件：

```text
<output_h264>.pts.csv
```

CSV 表头：

```text
frame_id,input_pts_us,mpp_packet_pts_us,mpp_packet_dts_us,pts_match,is_intra,queue_delay_ms,encode_wall_ms,packet_size
```

每一行记录一个编码 packet：

```text
frame_id:
    原始帧编号。

input_pts_us:
    工程侧生成并写入 MppFrame 的 PTS。

mpp_packet_pts_us:
    从 MppPacket 读回的 PTS。

mpp_packet_dts_us:
    从 MppPacket 读回的 DTS。

pts_match:
    input_pts_us 是否等于 mpp_packet_pts_us。

is_intra:
    是否被 MPP packet flag 识别为 intra。

queue_delay_ms:
    当前帧在异步编码队列中等待的时间。

encode_wall_ms:
    当前帧 MPP 编码耗时。

packet_size:
    当前 H.264 packet 字节数。
```

该文件是本实验最核心的验证依据。

---

## 12. 实验中发现的问题一：终端 `[ENC]` 打印参数错位

实验23初期新增 `[ENC]` 日志时，曾出现类似：

```text
[ENC] encoded=... pts=366944519881 pkt_pts=367795495609 ...
```

这种明显异常的大数。

经过排查，CSV 中的 PTS 是正确的，异常来自 `printf` 参数和格式不匹配导致的打印错位。

修复后 `[ENC]` 日志改为只打印确定存在的字段：

```text
[ENC] encoded=300 src_frame=299 packet=15913 input_pts=9966666 pkt_pts=9966666 pkt_dts=0 intra=0 qdelay=0.175 encode=3.106
```

修复后的字段含义清晰，且与 CSV 数据一致。

---

## 13. 实验中发现的问题二：MPP release 阶段资源 warning

在实验23-2中，虽然 PTS 验证成功，但程序退出阶段出现 MPP warning：

```text
mpp_buffer_ref_dec buffer from mpp_enc_check_pkt_buf found non-positive ref_count 0 caller mpp_packet_deinit
mpp_meta: put_meta invalid negative ref_count -1
mpp_mem_pool_put invalid mem pool ptr ...
mpp_buffer_service_deinit cleaning misc group
```

当时 300 帧结果为：

```text
async_encoded_frames : 300
async_encode_failures: 0
async_drop_frames    : 0
pts_match count      : 300 / 300
bad count            : 0
```

说明该 warning 没有破坏编码和 PTS 功能，但它意味着 MPP 内部资源释放不够干净，不能直接收口。

---

## 14. release warning 定位过程

### 14.1 第一次定位：给 packet deinit 和 release 加 marker

添加 release probe 后，观察到：

```text
[EXP23_RELEASE_PROBE] get_header before mpp_packet_deinit packet=...
[EXP23_RELEASE_PROBE] get_header after  mpp_packet_deinit packet=(nil)

[EXP23_RELEASE_PROBE] encode before mpp_packet_deinit packet=... pts=...
[EXP23_RELEASE_PROBE] encode after  mpp_packet_deinit packet=(nil)
```

每一帧 packet deinit 前后都没有立刻触发 warning。

真正 warning 出现在：

```text
[EXP23_RELEASE_PROBE] release begin ctx=... mpi=... cfg=...
mpp_buffer_ref_dec ... non-positive ref_count ...
mpp_meta ... negative ref_count ...
mpp_mem_pool_put invalid mem pool ptr ...
```

初步判断：

```text
warning 不是每帧 packet 当场释放触发的，
而是在 MppH264Encoder::release() 阶段释放 MPP context 时触发。
```

### 14.2 第二次定位：细化 release 内部

继续在 release 内部添加 marker：

```text
before mpp_enc_cfg_deinit
after  mpp_enc_cfg_deinit
before mpp_destroy
after  mpp_destroy
```

最终输出：

```text
before mpp_enc_cfg_deinit cfg=...
after  mpp_enc_cfg_deinit cfg=...
before mpp_destroy ctx=... mpi=...
mpp_buffer_ref_dec ... non-positive ref_count ...
mpp_meta ... negative ref_count ...
mpp_mem_pool_put invalid mem pool ptr ...
after  mpp_destroy ctx=... mpi=...
```

由此确定：

```text
warning 出现在 mpp_destroy(ctx_) 内部，
不是 mpp_enc_cfg_deinit(cfg_) 触发的。
```

---

## 15. release warning 根因：旧 Header API 不安全

运行日志中 MPP 自己给出提示：

```text
mpp_enc: Please use MPP_ENC_GET_HDR_SYNC instead of unsafe MPP_ENC_GET_EXTRA_INFO
mpp_enc: NOTE: MPP_ENC_GET_HDR_SYNC needs MppPacket input
```

这说明旧代码中获取 H.264 SPS/PPS header 的方式存在问题。

旧方式类似：

```cpp
MppPacket packet = nullptr;
MPP_RET ret = mpi_->control(ctx_, MPP_ENC_GET_EXTRA_INFO, &packet);
...
mpp_packet_deinit(&packet);
```

但是根据 MPP 文档：

```text
MPP_ENC_GET_EXTRA_INFO 返回的是编码器内部 MppPacket，
调用者不应该按普通外部分配 packet 的方式管理其生命周期。
```

而且当前 MPP 版本已经明确提示：

```text
Please use MPP_ENC_GET_HDR_SYNC instead of unsafe MPP_ENC_GET_EXTRA_INFO
```

因此 release warning 很可能是旧的 unsafe Header 获取方式污染了 MPP 内部 packet/buffer 引用状态，最终在 `mpp_destroy(ctx_)` 时暴露。

---

## 16. 第一次错误修复：空 MppPacket 导致段错误

初次尝试替换为 `MPP_ENC_GET_HDR_SYNC` 时，错误地写成：

```cpp
MppPacket packet = nullptr;
mpp_packet_init(&packet, nullptr, 0);
mpi_->control(ctx_, MPP_ENC_GET_HDR_SYNC, packet);
```

运行结果：

```text
段错误
```

运行日志只到 MPP 初始化和码率配置，没有进入模型加载和摄像头主循环，说明崩溃发生在 `get_header()` 阶段。

原因是：

```text
MPP_ENC_GET_HDR_SYNC 需要一个带有有效外部存储空间的 MppPacket。
空 packet 没有可写 buffer，control() 内部写 header 时可能直接访问非法地址。
```

该错误版本随后被废弃并清理。

---

## 17. 官方示例确认 GET_HDR_SYNC 正确用法

查阅 `/home/cat/mpp/test/mpi_enc_test.c`，官方写法为：

```c
MppPacket packet = NULL;

/*
 * Can use packet with normal malloc buffer as input not pkt_buf.
 * Please refer to vpu_api_legacy.cpp for normal buffer case.
 * Using pkt_buf buffer here is just for simplifing demo.
 */
mpp_packet_init_with_buffer(&packet, p->pkt_buf);
/* NOTE: It is important to clear output packet length!! */
mpp_packet_set_length(packet, 0);

ret = mpi->control(ctx, MPP_ENC_GET_HDR_SYNC, packet);
```

MPP 文档也说明：

```text
MPP_ENC_GET_HDR_SYNC 输入参数为 MppPacket，
需要外部用户分配好空间并封装为 MppPacket 再 control 到编码器。
control 接口调用返回时就完成了数据拷贝，线程安全。
需要用户手动释放之前分配的 MppPacket。
```

因此正确做法是：

```text
1. 外部分配一块 header buffer；
2. 用该 buffer 初始化 MppPacket；
3. 调用前 mpp_packet_set_length(packet, 0)；
4. control(ctx, MPP_ENC_GET_HDR_SYNC, packet)；
5. 从 packet 中读取 header；
6. mpp_packet_deinit(&packet)。
```

---

## 18. 最终修复：GET_HDR_SYNC + 外部 buffer

最终 `get_header()` 改为：

```cpp
bool MppH264Encoder::get_header(std::vector<uint8_t> &out_packet)
{
    out_packet.clear();

    if (!inited_ || ctx_ == nullptr || mpi_ == nullptr)
    {
        printf("get_header failed: encoder not initialized\n");
        return false;
    }

    constexpr size_t kHeaderBufSize = 4096;
    uint8_t header_buf[kHeaderBufSize];

    MppPacket packet = nullptr;
    MPP_RET ret = mpp_packet_init(&packet, header_buf, kHeaderBufSize);
    if (ret != MPP_OK || packet == nullptr)
    {
        printf("mpp_packet_init for header failed, ret=%d\n", ret);
        return false;
    }

    mpp_packet_set_length(packet, 0);

    ret = mpi_->control(ctx_, MPP_ENC_GET_HDR_SYNC, packet);
    if (ret != MPP_OK)
    {
        printf("MPP_ENC_GET_HDR_SYNC failed, ret=%d\n", ret);
        mpp_packet_deinit(&packet);
        return false;
    }

    void *ptr = mpp_packet_get_pos(packet);
    size_t len = mpp_packet_get_length(packet);

    if (ptr != nullptr && len > 0)
    {
        const uint8_t *p = static_cast<const uint8_t *>(ptr);
        out_packet.assign(p, p + len);
        printf("got h264 header by MPP_ENC_GET_HDR_SYNC: %zu bytes\n", len);
    }
    else
    {
        printf("warning: MPP_ENC_GET_HDR_SYNC returned empty header\n");
    }

    mpp_packet_deinit(&packet);
    return !out_packet.empty();
}
```

最终成功日志：

```text
got h264 header by MPP_ENC_GET_HDR_SYNC: 39 bytes
write h264 header: 39 bytes
```

旧的 unsafe 提示消失：

```text
不再出现：
Please use MPP_ENC_GET_HDR_SYNC instead of unsafe MPP_ENC_GET_EXTRA_INFO
```

原来的 release warning 也消失：

```text
不再出现：
non-positive ref_count
negative ref_count
invalid mem pool
```

---

## 19. 最终 300 帧验证命令

最终使用 300 帧测试：

```bash
cd ~/projects/rk3588_ai_stream

mkdir -p output/exp23_3_header_sync_buffer_300f

./build/exp21_detect_mpp_encode_async \
  models/yolo11.rknn \
  /dev/video11 \
  1280 \
  720 \
  300 \
  output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264 \
  output/exp23_3_header_sync_buffer_300f/profile_exp23_3_header_sync_buffer_300f.csv \
  > output/exp23_3_header_sync_buffer_300f/run.log 2>&1
```

关键检查命令：

```bash
grep -nE "GET_EXTRA_INFO|GET_HDR_SYNC|unsafe|段错误|Segmentation|non-positive|negative ref_count|invalid mem pool|mpp_buffer|mpp_meta|mpp_mem_pool|failed|error|async_encoded_frames|async_encode_failures|async_drop_frames|got h264 header" \
  output/exp23_3_header_sync_buffer_300f/run.log || true
```

最终输出：

```text
33:got h264 header by MPP_ENC_GET_HDR_SYNC: 39 bytes
97:mpp[929722]: mpp_buffer: mpp_buffer_service_deinit cleaning misc group
99:async_encoded_frames : 300
100:async_encode_failures: 0
101:async_drop_frames    : 0
```

其中只剩：

```text
mpp_buffer_service_deinit cleaning misc group
```

这是 MPP buffer service 退出时的普通清理日志，不包含 `invalid`、`negative`、`non-positive`，不再视为异常。

---

## 20. 最终运行日志关键片段

最终运行日志中，每 30 帧输出一次编码信息：

```text
[ENC] encoded=30 src_frame=29 packet=14457 input_pts=966666 pkt_pts=966666 pkt_dts=0 intra=0 qdelay=0.240 encode=3.539
[ENC] encoded=60 src_frame=59 packet=15306 input_pts=1966666 pkt_pts=1966666 pkt_dts=0 intra=0 qdelay=0.207 encode=3.339
[ENC] encoded=90 src_frame=89 packet=16882 input_pts=2966666 pkt_pts=2966666 pkt_dts=0 intra=0 qdelay=0.209 encode=3.915
[ENC] encoded=120 src_frame=119 packet=14934 input_pts=3966666 pkt_pts=3966666 pkt_dts=0 intra=0 qdelay=0.254 encode=3.054
[ENC] encoded=150 src_frame=149 packet=11986 input_pts=4966666 pkt_pts=4966666 pkt_dts=0 intra=0 qdelay=0.249 encode=3.105
[ENC] encoded=180 src_frame=179 packet=15531 input_pts=5966666 pkt_pts=5966666 pkt_dts=0 intra=0 qdelay=0.200 encode=3.320
[ENC] encoded=210 src_frame=209 packet=13461 input_pts=6966666 pkt_pts=6966666 pkt_dts=0 intra=0 qdelay=0.211 encode=3.091
[ENC] encoded=240 src_frame=239 packet=15319 input_pts=7966666 pkt_pts=7966666 pkt_dts=0 intra=0 qdelay=0.237 encode=3.207
[ENC] encoded=270 src_frame=269 packet=14405 input_pts=8966666 pkt_pts=8966666 pkt_dts=0 intra=0 qdelay=0.178 encode=2.964
[ENC] encoded=300 src_frame=299 packet=15913 input_pts=9966666 pkt_pts=9966666 pkt_dts=0 intra=0 qdelay=0.175 encode=3.106
```

这些日志证明：

```text
1. encoded 从 30 到 300 连续推进；
2. src_frame 与 encoded 计数对应正常，因为 frame_id 从 0 开始；
3. input_pts 与 pkt_pts 完全一致；
4. pkt_dts 仍然恒为 0；
5. queue delay 大约 0.2ms，编码线程没有明显积压；
6. MPP 编码耗时大约 3ms。
```

---

## 21. 最终 300 帧运行结果

最终 summary：

```text
[ENC] encoder thread exit, encoded=300 failures=0 drops=0
async_encoded_frames : 300
async_encode_failures: 0
async_drop_frames    : 0
async_avg_encode_ms  : 3.311
enc pts csv saved   : output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264.pts.csv
async_avg_write_ms   : 0.123
async_avg_total_ms   : 3.435

========== exp21-4 async detect mpp encode result ==========
frames              : 300
wall_time_ms        : 10079.968
wall_fps            : 29.762
avg_select_ms       : 1.170
avg_dqbuf_ms        : 0.003
avg_rga_nv12_to_rgb : 1.769
avg_input_prepare   : 0.001
avg_model_total_ms  : 27.583
avg_draw_ms         : 0.030
avg_rga_rgb_to_nv12 : 2.778
avg_mpp_queue_push  : 0.166
avg_qbuf_ms         : 0.030
avg_total_ms        : 33.532
profile csv         : output/exp23_3_header_sync_buffer_300f/profile_exp23_3_header_sync_buffer_300f.csv
output h264         : output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264
================================================
```

结论：

```text
300 帧全部完成；
编码失败 0 次；
异步丢帧 0 次；
wall_fps 为 29.762FPS；
平均总耗时 33.532ms；
MPP 平均编码耗时 3.311ms；
异步队列 push 平均耗时 0.166ms。
```

---

## 22. PTS CSV 统计结果

最终 PTS 统计脚本输出：

```text
file: output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264.pts.csv
rows: 300
frame_id first/last: 0 299
frame_id continuous: True
input_pts first/last: 0 9966666
input_pts delta avg/min/max: 33333.33110367893 33333 33334
pkt_pts first/last: 0 9966666
pkt_pts delta avg/min/max: 33333.33110367893 33333 33334
pts_match count: 300 / 300
dts unique first 10: [0]
queue_delay_ms avg/min/max: 0.2239933333333335 0.15 1.445
encode_wall_ms avg/min/max: 3.3115633333333325 2.943 5.429
packet_size avg/min/max: 16350.346666666666 4560 166481
bad count: 0
```

### 22.1 frame_id 结果

```text
rows: 300
frame_id first/last: 0 299
frame_id continuous: True
```

说明：

```text
一共统计到 300 个编码 packet；
frame_id 从 0 到 299；
没有断帧；
没有乱序。
```

### 22.2 input_pts 结果

```text
input_pts first/last: 0 9966666
input_pts delta avg/min/max: 33333.33110367893 33333 33334
```

说明工程侧生成的输入 PTS 正确：

```text
第 0 帧：0 us
第 299 帧：9966666 us
平均间隔约 33333.33 us
最小间隔 33333 us
最大间隔 33334 us
```

该结果符合 30FPS 的理论时间戳。

### 22.3 packet PTS 结果

```text
pkt_pts first/last: 0 9966666
pkt_pts delta avg/min/max: 33333.33110367893 33333 33334
pts_match count: 300 / 300
bad count: 0
```

说明：

```text
mpp_packet_get_pts() 读回的 PTS 与 input_pts_us 完全一致；
300 帧全部匹配；
没有 PTS 不递增；
没有 PTS 不匹配。
```

这是本实验的核心成功证据。

### 22.4 DTS 结果

```text
dts unique first 10: [0]
```

说明：

```text
mpp_packet_get_dts() 当前返回值恒为 0。
```

因此后续实验24做 MP4 MUX 时，不能直接依赖 MPP packet DTS。

后续建议：

```text
EncodedPacket.pts_us = input_pts_us
EncodedPacket.dts_us = input_pts_us
```

因为当前实时编码没有使用 B 帧重排序，编码顺序和显示顺序一致，所以第一版封装中 `DTS = PTS` 是合理工程选择。

### 22.5 queue delay 结果

```text
queue_delay_ms avg/min/max: 0.2239933333333335 0.15 1.445
```

说明：

```text
异步编码队列平均等待约 0.224ms；
最大等待约 1.445ms；
编码线程没有明显积压。
```

### 22.6 MPP encode 结果

```text
encode_wall_ms avg/min/max: 3.3115633333333325 2.943 5.429
```

说明：

```text
MPP 编码平均耗时约 3.31ms；
最小约 2.94ms；
最大约 5.43ms；
对于 30FPS 的 33.33ms 单帧预算来说，编码耗时较小。
```

### 22.7 packet size 结果

```text
packet_size avg/min/max: 16350.346666666666 4560 166481
```

说明：

```text
平均 H.264 packet 大小约 16KB；
最小约 4.5KB；
最大约 166KB；
最大值通常可能来自首帧或关键帧附近，属于正常现象。
```

---

## 23. 实验23最终结论

实验23完成了自研 MPP H.264 编码链路的编码端 PTS 补全。

工程侧为每个进入异步编码线程的视频帧生成 `frame_id` 和 `input_pts_us`，并通过 `mpp_frame_set_pts()` 写入 `MppFrame`；编码完成后通过 `mpp_packet_get_pts()` 从 `MppPacket` 回读 packet PTS。300 帧测试结果显示，`frame_id` 从 0 到 299 连续递增，`input_pts_us` 与 `mpp_packet_pts_us` 全部一致，`pts_match` 为 300/300，`bad count` 为 0，PTS 间隔稳定在 33333/33334us，证明编码端 PTS 设置与回读链路已经打通。

同时，实验将 H.264 header 获取方式从旧的 `MPP_ENC_GET_EXTRA_INFO` 替换为线程安全的 `MPP_ENC_GET_HDR_SYNC`，并按 Rockchip 官方示例为 `MppPacket` 提供外部 buffer，且在调用前执行 `mpp_packet_set_length(packet, 0)`。替换后，原先 `mpp_destroy()` 阶段出现的 `non-positive ref_count`、`negative ref_count` 和 `invalid mem pool` warning 消失，程序退出阶段仅保留 MPP buffer service 的普通清理日志。

300 帧测试中，异步编码线程完成 300 帧编码，编码失败为 0，丢帧为 0，`wall_fps` 为 29.762FPS，MPP 平均编码耗时约 3.31ms，异步队列平均等待时间约 0.224ms，说明 PTS 补全和安全 Header 获取改造没有破坏实时性。

---

## 24. 当前仍需注意的问题

### 24.1 DTS 当前不可直接使用

实验中观察到：

```text
dts unique first 10: [0]
```

说明当前 MPP packet DTS 返回值恒为 0。

因此后续 MP4 MUX 实验中不要直接使用：

```cpp
mpp_packet_get_dts(packet)
```

而应使用工程侧生成的：

```text
effective_dts_us = input_pts_us
```

原因：

```text
当前编码链路为低延迟实时编码，没有引入 B 帧重排序，
编码顺序与显示顺序一致，因此 DTS 和 PTS 可以先保持一致。
```

### 24.2 is_intra 当前不可靠

PTS CSV 中：

```text
intra count: 0
```

说明当前通过 `mpp_packet_get_flag()` 判断 intra 的结果不可靠。

后续如果要做关键帧索引、历史回放 seek 或 HLS 切片，建议直接解析 H.264 NALU：

```text
NAL type 5 -> IDR
NAL type 7 -> SPS
NAL type 8 -> PPS
```

不要完全依赖当前 packet flag。

### 24.3 `mpp_buffer_service_deinit cleaning misc group` 不视为异常

最终日志中仍有：

```text
mpp_buffer: mpp_buffer_service_deinit cleaning misc group
```

该日志不包含：

```text
non-positive
negative
invalid
failed
error
```

因此当前将其视为 MPP 退出阶段普通清理信息，不作为实验失败项。

---

## 25. 对后续实验24的意义

实验23为实验24提供了时间戳基础。

后续实验24可以构造更完整的编码包结构：

```cpp
struct EncodedPacket
{
    int frame_id;
    int64_t pts_us;
    int64_t dts_us;
    bool is_keyframe;
    std::vector<uint8_t> data;
};
```

当前实验23已经证明：

```text
pts_us 可以由 frame_id 按 30FPS 生成；
pts_us 可以通过 mpp_frame_set_pts() 写入 MPP；
mpp_packet_get_pts() 可以正确回读；
DTS 当前需要工程侧生成；
H.264 header 可通过 MPP_ENC_GET_HDR_SYNC 安全获取。
```

实验24可以在此基础上继续：

```text
EncodedPacket{data, pts_us, dts_us}
    ↓
AVPacket.pts / AVPacket.dts
    ↓
libavformat MP4 mux
    ↓
ffprobe 验证视频轨时长、帧率、PTS 单调性
```

---

## 26. 实验23收口状态

```text
23-1：为异步编码帧增加 frame_id / pts_us / enqueue_ts_us —— 完成
23-2：mpp_frame_set_pts 到 mpp_packet_get_pts 链路验证 —— 完成
23-3：定位 MPP release 阶段 ref_count warning —— 完成
23-4：将 Header 获取从 GET_EXTRA_INFO 替换为 GET_HDR_SYNC —— 完成
23-5：300 帧 PTS、性能、warning 回归验证 —— 完成
```

最终实验状态：

```text
实验23通过，可以收口。
```

---

## 27. 最终保留文件建议

建议保留：

```text
scripts/exp23_3_fix_header_sync_buffer.sh
output/exp23_3_header_sync_buffer_30f
output/exp23_3_header_sync_buffer_300f
```

其中 300 帧目录中最重要文件：

```text
output/exp23_3_header_sync_buffer_300f/run.log
output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264
output/exp23_3_header_sync_buffer_300f/detect_pts_300f.h264.pts.csv
output/exp23_3_header_sync_buffer_300f/profile_exp23_3_header_sync_buffer_300f.csv
```

中间失败版本和调试 probe 脚本可移动到归档目录或删除。

---

## 28. 一句话总结

```text
实验23完成了 RK3588 自研异步 MPP H.264 编码链路的 PTS 补全，验证了 mpp_frame_set_pts() 到 mpp_packet_get_pts() 的 300 帧稳定传递，并将 H.264 Header 获取方式从 unsafe 的 MPP_ENC_GET_EXTRA_INFO 修复为线程安全的 MPP_ENC_GET_HDR_SYNC，消除了 mpp_destroy 阶段 ref_count / meta / mem_pool warning，为后续 MP4 MUX、历史录像、回放和 Demux/VDEC 实验奠定了时间戳基础。
```

# Exp21 / Exp23 MPP 异步编码代码逐行理解笔记

> 对应文件：
>
> - `main_exp21_detect_mpp_encode_async.cpp`
> - `mpp_h264_encoder.cpp`
> - `23_mpp_pts_timestamp.md`
>
> 阅读说明：这份笔记按“**完整语句 / 完整代码块**”逐行解释。C/C++ 里很多语句会被拆成多行，例如一个 `printf(...)` 或一个函数调用可能占 5～10 行。如果每一行都单独解释会变成大量重复内容，所以这里采用“**行号范围 + 逐句解释**”的方式。凡是语法、逻辑、作用、为什么这样写，我都尽量展开。

---

## 0. 先建立整体认识

这份代码不是普通的 C++ 小程序，而是 RK3588 端侧视频 AI 链路的一部分。它同时涉及：

```text
摄像头 V4L2 采集
    ↓
摄像头输出 NV12 原始图像
    ↓
RGA 硬件加速：NV12 → RGB
    ↓
RKNN YOLO11 目标检测
    ↓
OpenCV 在 RGB 图上画检测框
    ↓
RGA 硬件加速：RGB → NV12
    ↓
主线程把 NV12 帧放入异步编码队列
    ↓
编码线程调用 MppH264Encoder
    ↓
MPP 硬件编码 H.264
    ↓
写入 .h264 文件或 FIFO
    ↓
同时记录 profile.csv 和 .pts.csv
```

你可以把两个 `.cpp` 文件分成两层理解：

| 文件 | 角色 | 可以理解成 |
|---|---|---|
| `main_exp21_detect_mpp_encode_async.cpp` | 总调度程序 | 负责摄像头、RGA、YOLO、画框、队列、性能统计 |
| `mpp_h264_encoder.cpp` | H.264 编码器封装 | 把一帧 NV12 图像交给 RK MPP，拿回 H.264 packet |

最重要的一句话：

```text
main 文件负责“拿到一帧处理好的 NV12 图像”；
mpp_h264_encoder 文件负责“把这一帧 NV12 压成 H.264 码流”。
```

---

## 1. 小白必须先知道的几个概念

### 1.1 什么是 NV12？

NV12 是一种 YUV 图像格式。摄像头和硬件编码器很常用它。

一张 `width × height` 的 NV12 图像大小是：

```cpp
width * height * 3 / 2
```

原因：

```text
Y 平面：width * height 字节
UV 平面：width * height / 2 字节
总大小：1.5 * width * height
```

所以代码里有：

```cpp
const size_t nv12_size = (size_t)width * height * 3 / 2;
```

### 1.2 什么是 RGB？

RGB 每个像素 3 个通道：R、G、B。每个通道 1 字节，所以大小是：

```cpp
width * height * 3
```

YOLO 模型通常更容易接收 RGB，所以摄像头的 NV12 要先转成 RGB。

### 1.3 什么是 RGA？

RGA 是 Rockchip 的图像硬件加速模块。它可以做：

```text
格式转换：NV12 ↔ RGB
缩放
裁剪
旋转
拷贝
```

这里主要用它做两次格式转换：

```text
第一次：NV12 → RGB，给 YOLO 推理和 OpenCV 画框用
第二次：RGB → NV12，给 MPP H.264 编码器用
```

### 1.4 什么是 MPP？

MPP 是 Rockchip 的硬件编解码框架。这里用它做 H.264 编码。

你可以理解成：

```text
输入：一帧 NV12 图片
输出：一段 H.264 压缩码流 packet
```

### 1.5 什么是 PTS / DTS？

- PTS：Presentation Timestamp，显示时间戳，表示这一帧应该什么时候显示。
- DTS：Decoding Timestamp，解码时间戳，表示这一帧应该什么时候被解码。

本实验主要验证：

```text
工程侧给 MppFrame 写入 input_pts_us
MPP 编码后从 MppPacket 读回 packet_pts_us
二者是否一致
```

---


# 2. `mpp_h264_encoder.cpp` 逐行理解

这个文件是编码器封装，先讲它，因为它比主程序短，而且是后面异步线程真正调用的核心。


## 2.1 头文件包含：第 1～7 行


```cpp
   1  #include "mpp_h264_encoder.hpp"
   2  
   3  #include <cstdio>
   4  #include <cstdlib>
   5  #include <cstring>
   6  #include <algorithm>
   7  #include <unistd.h>
```


逐行解释：

- 第 1 行：包含自己的头文件 `mpp_h264_encoder.hpp`。`.cpp` 是实现文件，`.hpp` 通常是声明文件。类 `MppH264Encoder` 的成员变量、函数声明应该在头文件里。
- 第 3 行：`<cstdio>` 提供 C 风格输入输出函数，例如 `printf`。
- 第 4 行：`<cstdlib>` 提供一些通用函数，例如 `atoi`、`malloc` 等。这个文件里不一定大量使用，但常见于 C/C++ 工程。
- 第 5 行：`<cstring>` 提供 `memcpy`、`memset` 等内存操作函数。
- 第 6 行：`<algorithm>` 提供算法函数，例如 `std::max`、`std::min`。当前文件中可能不是核心使用。
- 第 7 行：`<unistd.h>` 是 Linux/Unix 系统头文件，提供 `usleep` 等函数。

语法点：

```cpp
#include <xxx>
```

表示把某个头文件的声明引入当前文件，否则编译器不知道 `printf`、`memcpy`、`usleep` 是什么。

---

## 2.2 构造函数：第 9～22 行


```cpp
   9  MppH264Encoder::MppH264Encoder()   //初始化，所有指针置空然后清零防止野指针
  10      : ctx_(nullptr), //省略部分初始化代码
  11        mpi_(nullptr),
  12        cfg_(nullptr),
  13        width_(0),
  14        height_(0),
  15        fps_(0),
  16        bitrate_(0),
  17        hor_stride_(0),
  18        ver_stride_(0),
  19        frame_size_(0),
  20        inited_(false)
  21  {
  22  }
```


逐行解释：

- 第 9 行：这是 `MppH264Encoder` 类的构造函数。构造函数在对象创建时自动执行。
- 第 10～20 行：这是“成员初始化列表”。比在函数体里赋值更推荐。
- `ctx_(nullptr)`：把 MPP 上下文指针初始化为空。`nullptr` 表示“当前不指向任何有效对象”。
- `mpi_(nullptr)`：把 MPP 接口指针初始化为空。
- `cfg_(nullptr)`：把 MPP 编码配置句柄初始化为空。
- `width_(0)` / `height_(0)`：初始宽高为 0。
- `fps_(0)`：初始帧率为 0。
- `bitrate_(0)`：初始码率为 0。
- `hor_stride_(0)` / `ver_stride_(0)`：初始 stride 为 0。
- `frame_size_(0)`：初始一帧大小为 0。
- `inited_(false)`：表示编码器还没有初始化。
- 第 21～22 行：构造函数函数体为空，因为初始化工作已经在初始化列表完成。

语法点：

```cpp
MppH264Encoder::MppH264Encoder()
```

`类名::函数名` 表示“这个函数属于这个类”。

为什么要把指针设成 `nullptr`？

```text
避免野指针。野指针指向未知地址，后面如果释放或访问，可能段错误。
```

---

## 2.3 析构函数：第 24～27 行


```cpp
  24  MppH264Encoder::~MppH264Encoder()
  25  {
  26      release();
  27  }
```


逐行解释：

- 第 24 行：析构函数。对象销毁时自动调用。
- 第 26 行：调用 `release()` 释放 MPP 资源。

语法点：

```cpp
~MppH264Encoder()
```

函数名前面有 `~`，表示析构函数。它没有返回值，也不能手动指定参数。

工程意义：

```text
只要 MppH264Encoder 对象生命周期结束，就自动释放 MPP 配置和上下文，避免资源泄漏。
```

---

## 2.4 向上对齐函数：第 29～32 行


```cpp
  29  int MppH264Encoder::align_up(int value, int align)  //向上对齐
  30  {
  31      return (value + align - 1) / align * align;
  32  }
```


逐行解释：

- 第 29 行：定义 `align_up` 函数。作用是把 `value` 向上补齐到 `align` 的整数倍。
- 第 31 行：核心公式。

例如：

```text
align_up(1280, 16) = 1280
align_up(721, 16)  = 736
```

公式解释：

```cpp
(value + align - 1) / align * align
```

以 `value=721, align=16` 为例：

```text
721 + 16 - 1 = 736
736 / 16 = 46
46 * 16 = 736
```

为什么编码要对齐？

```text
硬件编码器通常不一定按真实宽高直接访问内存，而是按 stride 访问。
stride 往往要求 16 字节对齐，这样硬件 DMA / 编码模块更容易高效读取。
```

---

## 2.5 初始化编码器：第 34～155 行


```cpp
  34  bool MppH264Encoder::init(int width, int height, int fps, int bitrate)
  35  {
  36      if (inited_)
  37      {
  38          return true;
  39      }
  40  
  41      width_ = width;
  42      height_ = height;
  43      fps_ = fps;
  44      bitrate_ = bitrate;
  45  
  46      /*
  47       * RK3588 MPP H.264 编码通常要求 stride 按 16 对齐。
  48       * 1280x720 本身刚好都是 16 对齐：
  49       * 1280 / 16 = 80
  50       * 720  / 16 = 45
  51       */
  52      hor_stride_ = align_up(width_, 16);
  53      ver_stride_ = align_up(height_, 16);
  54      frame_size_ = static_cast<size_t>(hor_stride_) * ver_stride_ * 3 / 2;
  55  
  56      printf("========== MppH264Encoder init ==========\n");
  57      printf("width       : %d\n", width_);
  58      printf("height      : %d\n", height_);
  59      printf("fps         : %d\n", fps_);
  60      printf("bitrate     : %d\n", bitrate_);
  61      printf("hor_stride  : %d\n", hor_stride_);
  62      printf("ver_stride  : %d\n", ver_stride_);
  63      printf("frame_size  : %zu\n", frame_size_);
  64      printf("=========================================\n");
  65  
  66      MPP_RET ret = MPP_OK;
  67  
  68      ret = mpp_create(&ctx_, &mpi_);  //向mpp框架申请实例拿到上下文ctx_和接口指针mpi_
  69      if (ret != MPP_OK || ctx_ == nullptr || mpi_ == nullptr)
  70      {
  71          printf("mpp_create failed, ret=%d\n", ret);
  72          return false;
  73      }
  74  
  75      ret = mpp_init(ctx_, MPP_CTX_ENC, MPP_VIDEO_CodingAVC);
  76      if (ret != MPP_OK)
  77      {
  78          printf("mpp_init failed, ret=%d\n", ret);
  79          release();
  80          return false;
  81      }
  82  
  83      ret = mpp_enc_cfg_init(&cfg_);    //分配一个配置句柄然后getcfg获取默认的配置模板，方便之后修改
  84      if (ret != MPP_OK || cfg_ == nullptr)
  85      {
  86          printf("mpp_enc_cfg_init failed, ret=%d\n", ret);
  87          release();
  88          return false;
  89      }
  90  
  91      ret = mpi_->control(ctx_, MPP_ENC_GET_CFG, cfg_);
  92      if (ret != MPP_OK)
  93      {
  94          printf("MPP_ENC_GET_CFG failed, ret=%d\n", ret);
  95          release();
  96          return false;
  97      }
  98  
  99      /*
 100       * prep：输入图像参数。《prep预处理阶段》
 101       * 当前实验输入为 1280x720 NV12。
 102       */
 103      mpp_enc_cfg_set_s32(cfg_, "prep:width", width_);
 104      mpp_enc_cfg_set_s32(cfg_, "prep:height", height_);
 105      mpp_enc_cfg_set_s32(cfg_, "prep:hor_stride", hor_stride_);
 106      mpp_enc_cfg_set_s32(cfg_, "prep:ver_stride", ver_stride_);
 107      mpp_enc_cfg_set_s32(cfg_, "prep:format", MPP_FMT_YUV420SP);
 108  
 109      /*
 110       * rc：码率控制。《rc码率控制》
 111       * 这里先使用 CBR，方便后续和 mpi_enc_test 对比。
 112       */
 113      mpp_enc_cfg_set_s32(cfg_, "rc:mode", MPP_ENC_RC_MODE_CBR);
 114  
 115      mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_flex", 0);
 116      mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_num", fps_);
 117      mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_denorm", 1);
 118  
 119      mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_flex", 0);
 120      mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_num", fps_);
 121      mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_denorm", 1);
 122  
 123      mpp_enc_cfg_set_s32(cfg_, "rc:gop", fps_ * 2);
 124  
 125      mpp_enc_cfg_set_s32(cfg_, "rc:bps_target", bitrate_);
 126      mpp_enc_cfg_set_s32(cfg_, "rc:bps_max", bitrate_ * 17 / 16);
 127      mpp_enc_cfg_set_s32(cfg_, "rc:bps_min", bitrate_ * 15 / 16);
 128  
 129      /*
 130       * codec：H.264 / AVC。《编码器特性》
 131       */
 132      mpp_enc_cfg_set_s32(cfg_, "codec:type", MPP_VIDEO_CodingAVC);
 133  
 134      /*
 135       * H.264 profile：
 136       * 66  = baseline
 137       * 77  = main
 138       * 100 = high
 139       */
 140      mpp_enc_cfg_set_s32(cfg_, "h264:profile", 100);  //设置为100代表最高压缩率和画质的压缩
 141      mpp_enc_cfg_set_s32(cfg_, "h264:level", 40);     //规定最大分辨率和码率支持上限
 142      mpp_enc_cfg_set_s32(cfg_, "h264:cabac_en", 1);
 143      mpp_enc_cfg_set_s32(cfg_, "h264:cabac_idc", 0);
 144      mpp_enc_cfg_set_s32(cfg_, "h264:trans8x8", 1);
 145  
 146      ret = mpi_->control(ctx_, MPP_ENC_SET_CFG, cfg_);   //将修改好的配置写回硬件
 147      if (ret != MPP_OK)
 148      {
 149          printf("MPP_ENC_SET_CFG failed, ret=%d\n", ret);
 150          release();
 151          return false;
 152      }
 153  
 154      inited_ = true;  //标记初始化完成
 155      return true;
```


这是整个编码器最关键的初始化函数。你可以把它分成 7 步：

```text
1. 防止重复初始化
2. 保存宽高、fps、码率
3. 计算 stride 和 frame_size
4. 创建 MPP 实例
5. 初始化为 H.264 编码器
6. 获取并修改编码配置
7. 写回配置并标记初始化成功
```

逐段解释：

### 第 34 行

```cpp
bool MppH264Encoder::init(int width, int height, int fps, int bitrate)
```

这是类成员函数 `init` 的实现。返回值是 `bool`：

- `true`：初始化成功。
- `false`：初始化失败。

参数含义：

| 参数 | 含义 |
|---|---|
| `width` | 输入图像宽度 |
| `height` | 输入图像高度 |
| `fps` | 目标编码帧率 |
| `bitrate` | 目标码率，单位一般是 bit/s |

### 第 36～39 行

如果 `inited_` 已经是 `true`，说明之前初始化过了，直接返回成功，避免重复创建 MPP 资源。

### 第 41～44 行

把传入的参数保存到成员变量中。成员变量后面有 `_`，这是常见命名习惯，表示它属于类对象内部。

### 第 46～54 行

这段计算 stride 和 frame_size：

```cpp
hor_stride_ = align_up(width_, 16);
ver_stride_ = align_up(height_, 16);
frame_size_ = static_cast<size_t>(hor_stride_) * ver_stride_ * 3 / 2;
```

- `hor_stride_`：一行实际占用多少字节。
- `ver_stride_`：实际按多少行对齐。
- `frame_size_`：编码器输入 buffer 需要的大小。

`static_cast<size_t>` 是 C++ 类型转换，防止整数乘法溢出或类型不匹配。

### 第 56～64 行

打印初始化参数，便于运行时确认宽高、码率、stride 是否正确。

### 第 66 行

```cpp
MPP_RET ret = MPP_OK;
```

`MPP_RET` 是 MPP API 的返回码类型。`MPP_OK` 表示成功。

### 第 68～73 行

```cpp
ret = mpp_create(&ctx_, &mpi_);
```

向 MPP 框架申请一个实例：

- `ctx_`：上下文，可以理解为“这个编码器实例本身”。
- `mpi_`：函数接口表，可以理解为“一组函数指针”，后面通过 `mpi_->control(...)`、`mpi_->encode_put_frame(...)` 调 MPP。

为什么传 `&ctx_`？

因为 `mpp_create` 需要修改 `ctx_` 的值，让它指向新创建的 MPP 对象。所以要传指针的地址。

### 第 75～81 行

```cpp
ret = mpp_init(ctx_, MPP_CTX_ENC, MPP_VIDEO_CodingAVC);
```

把 MPP 实例初始化为“编码器”，而且编码格式是 AVC，也就是 H.264。

- `MPP_CTX_ENC`：编码模式。
- `MPP_VIDEO_CodingAVC`：H.264 / AVC。

如果失败，就 `release()` 清理前面已经创建的资源，然后返回 `false`。

### 第 83～97 行

先创建配置对象 `cfg_`，再从 MPP 获取默认配置：

```cpp
mpp_enc_cfg_init(&cfg_);
mpi_->control(ctx_, MPP_ENC_GET_CFG, cfg_);
```

这样做的好处是：

```text
先拿一份默认配置模板，再只修改我们关心的字段。
```

### 第 99～107 行：prep 输入图像配置

这些配置告诉 MPP：我送给你的原始图像长什么样。

```cpp
mpp_enc_cfg_set_s32(cfg_, "prep:width", width_);
mpp_enc_cfg_set_s32(cfg_, "prep:height", height_);
mpp_enc_cfg_set_s32(cfg_, "prep:hor_stride", hor_stride_);
mpp_enc_cfg_set_s32(cfg_, "prep:ver_stride", ver_stride_);
mpp_enc_cfg_set_s32(cfg_, "prep:format", MPP_FMT_YUV420SP);
```

- `width` / `height`：真实图像宽高。
- `hor_stride` / `ver_stride`：内存对齐后的宽高。
- `MPP_FMT_YUV420SP`：NV12 这类格式。

### 第 109～127 行：码率控制 rc 配置

`rc` 是 rate control，码率控制。

```cpp
mpp_enc_cfg_set_s32(cfg_, "rc:mode", MPP_ENC_RC_MODE_CBR);
```

CBR 是 Constant Bitrate，恒定码率。意思是尽量让码流接近固定码率。

`fps_in` / `fps_out`：输入帧率和输出帧率。这里都设成 `fps_`。

```cpp
mpp_enc_cfg_set_s32(cfg_, "rc:gop", fps_ * 2);
```

`gop` 表示关键帧间隔。`fps_ * 2` 表示约 2 秒一个 GOP。例如 30fps 时 GOP=60。

码率部分：

```cpp
bps_target = bitrate_
bps_max    = bitrate_ * 17 / 16
bps_min    = bitrate_ * 15 / 16
```

即允许码率在目标值附近轻微浮动。

### 第 129～144 行：H.264 编码特性

```cpp
mpp_enc_cfg_set_s32(cfg_, "codec:type", MPP_VIDEO_CodingAVC);
```

再次指定编码格式为 H.264。

```cpp
mpp_enc_cfg_set_s32(cfg_, "h264:profile", 100);
```

H.264 profile：

| 数值 | 含义 |
|---|---|
| 66 | Baseline |
| 77 | Main |
| 100 | High |

High profile 通常压缩效率更高，但解码端要求也稍高。

```cpp
h264:cabac_en = 1
h264:trans8x8 = 1
```

这些都是提升压缩效率的编码工具。

### 第 146～155 行：写回配置

```cpp
ret = mpi_->control(ctx_, MPP_ENC_SET_CFG, cfg_);
```

前面只是修改了本地配置对象，这里才真正把配置交给 MPP 编码器。

成功后：

```cpp
inited_ = true;
return true;
```

---

## 2.6 获取 H.264 Header：第 158～223 行


```cpp
 158  bool MppH264Encoder::get_header(std::vector<uint8_t> &out_packet)
 159  {
 160      out_packet.clear();
 161  
 162      if (!inited_ || ctx_ == nullptr || mpi_ == nullptr)
 163      {
 164          printf("get_header failed: encoder not initialized\n");
 165          return false;
 166      }
 167  
 168      /*
 169       * exp23-3:
 170       * Use MPP_ENC_GET_HDR_SYNC instead of unsafe MPP_ENC_GET_EXTRA_INFO.
 171       *
 172       * Rockchip official usage:
 173       *   mpp_packet_init_with_buffer(&packet, p->pkt_buf);
 174       *   mpp_packet_set_length(packet, 0);
 175       *   mpi->control(ctx, MPP_ENC_GET_HDR_SYNC, packet);
 176       *
 177       * For this project, we use a normal external memory buffer and wrap it
 178       * as MppPacket. The important point is that packet must have valid
 179       * external storage, and packet length must be cleared before control().
 180       */
 181      constexpr size_t kHeaderBufSize = 4096;
 182      uint8_t header_buf[kHeaderBufSize];
 183  
 184      MppPacket packet = nullptr;
 185      MPP_RET ret = mpp_packet_init(&packet, header_buf, kHeaderBufSize);
 186      if (ret != MPP_OK || packet == nullptr)
 187      {
 188          printf("mpp_packet_init for header failed, ret=%d\n", ret);
 189          return false;
 190      }
 191  
 192      /*
 193       * Important:
 194       * Official mpi_enc_test.c explicitly clears output packet length before
 195       * MPP_ENC_GET_HDR_SYNC.
 196       */
 197      mpp_packet_set_length(packet, 0);
 198  
 199      ret = mpi_->control(ctx_, MPP_ENC_GET_HDR_SYNC, packet);
 200      if (ret != MPP_OK)
 201      {
 202          printf("MPP_ENC_GET_HDR_SYNC failed, ret=%d\n", ret);
 203          mpp_packet_deinit(&packet);
 204          return false;
 205      }
 206  
 207      void *ptr = mpp_packet_get_pos(packet);
 208      size_t len = mpp_packet_get_length(packet);
 209  
 210      if (ptr != nullptr && len > 0)
 211      {
 212          const uint8_t *p = static_cast<const uint8_t *>(ptr);
 213          out_packet.assign(p, p + len);
 214          printf("got h264 header by MPP_ENC_GET_HDR_SYNC: %zu bytes\n", len);
 215      }
 216      else
 217      {
 218          printf("warning: MPP_ENC_GET_HDR_SYNC returned empty header\n");
 219      }
 220  
 221      mpp_packet_deinit(&packet);
 222      return !out_packet.empty();
 223  }
```


这段函数用于获取 H.264 的 SPS/PPS Header。

H.264 裸流通常需要先写入 SPS/PPS，播放器或解码器才知道：

```text
编码格式、profile、level、分辨率等参数
```

逐段解释：

### 第 158 行

```cpp
bool MppH264Encoder::get_header(std::vector<uint8_t> &out_packet)
```

参数 `out_packet` 是引用，用来把 header 数据返回给调用者。

`std::vector<uint8_t>` 可以理解成“可自动扩容的字节数组”。

### 第 160 行

```cpp
out_packet.clear();
```

先清空输出，避免里面残留旧数据。

### 第 162～166 行

检查编码器是否已经初始化。如果没初始化就不能拿 Header。

### 第 168～180 行

这是注释，说明为什么使用 `MPP_ENC_GET_HDR_SYNC`，不用旧的 unsafe API。

实验记录里也说明，旧 Header 获取方式可能导致 release 阶段 MPP 内部资源 warning，而最终修复方式是使用 `MPP_ENC_GET_HDR_SYNC + 外部 buffer`。

### 第 181～182 行

```cpp
constexpr size_t kHeaderBufSize = 4096;
uint8_t header_buf[kHeaderBufSize];
```

在栈上准备一个 4096 字节数组，用来接收 MPP 写出的 header。

`constexpr` 表示编译期常量。

### 第 184～190 行

```cpp
MppPacket packet = nullptr;
MPP_RET ret = mpp_packet_init(&packet, header_buf, kHeaderBufSize);
```

把普通内存 `header_buf` 包装成 MPP 认识的 `MppPacket`。

注意：这里不是让 MPP 自己分配 packet，而是我们提供外部存储。

### 第 197 行

```cpp
mpp_packet_set_length(packet, 0);
```

这行非常关键。意思是：告诉 MPP，这个 packet 当前有效长度为 0，后面你可以从头写 header。

### 第 199～205 行

```cpp
ret = mpi_->control(ctx_, MPP_ENC_GET_HDR_SYNC, packet);
```

向 MPP 请求同步生成 H.264 Header。

如果失败，要先释放 `packet`，再返回 `false`。

### 第 207～208 行

```cpp
void *ptr = mpp_packet_get_pos(packet);
size_t len = mpp_packet_get_length(packet);
```

从 MppPacket 中拿：

- `ptr`：数据起始位置。
- `len`：数据长度。

### 第 210～219 行

如果 `ptr` 不为空且 `len > 0`，说明拿到了 Header：

```cpp
out_packet.assign(p, p + len);
```

把 `[p, p+len)` 范围内的字节拷贝到 `out_packet`。

### 第 221～222 行

释放 MppPacket，然后返回是否真的拿到了数据。

---

## 2.7 拷贝 NV12 到 MPP Buffer：第 225～281 行


```cpp
 225  bool MppH264Encoder::copy_nv12_to_mpp_buffer(const uint8_t *src,
 226                                               size_t src_size,
 227                                               uint8_t *dst,
 228                                               size_t dst_size)
 229  {
 230      if (src == nullptr || dst == nullptr)
 231      {
 232          return false;
 233      }
 234  
 235      const size_t compact_size = static_cast<size_t>(width_) * height_ * 3 / 2;
 236      if (src_size < compact_size || dst_size < frame_size_)
 237      {
 238          printf("copy_nv12_to_mpp_buffer size mismatch: src_size=%zu compact=%zu dst_size=%zu frame_size=%zu\n",
 239                 src_size, compact_size, dst_size, frame_size_);
 240          return false;
 241      }
 242  
 243      memset(dst, 0, dst_size);
 244  
 245      /*
 246       * 如果宽高和 stride 完全一致，直接拷贝即可。
 247       * 1280x720 就是这种情况。
 248       */
 249      if (hor_stride_ == width_ && ver_stride_ == height_)
 250      {
 251          memcpy(dst, src, compact_size);
 252          return true;
 253      }
 254  
 255      /*
 256       * 通用 stride 拷贝：
 257       * Y 平面：height 行，每行 width 字节；
 258       * UV 平面：height/2 行，每行 width 字节。
 259       */
 260      const uint8_t *src_y = src;
 261      const uint8_t *src_uv = src + static_cast<size_t>(width_) * height_;
 262  
 263      uint8_t *dst_y = dst;
 264      uint8_t *dst_uv = dst + static_cast<size_t>(hor_stride_) * ver_stride_;
 265  
 266      for (int y = 0; y < height_; ++y)
 267      {
 268          memcpy(dst_y + static_cast<size_t>(y) * hor_stride_,
 269                 src_y + static_cast<size_t>(y) * width_,
 270                 width_);
 271      }
 272  
 273      for (int y = 0; y < height_ / 2; ++y)
 274      {
 275          memcpy(dst_uv + static_cast<size_t>(y) * hor_stride_,
 276                 src_uv + static_cast<size_t>(y) * width_,
 277                 width_);
 278      }
 279  
 280      return true;
 281  }
```


这个函数负责把外部传进来的紧凑 NV12 数据，拷贝到 MPP 要求的输入 buffer。

为什么不一定能直接 `memcpy`？

因为 MPP 输入 buffer 可能按 stride 对齐，例如真实宽度 641，但 stride 可能要对齐到 656。此时每行后面有 padding 字节，必须逐行拷贝。

逐段解释：

### 第 225～228 行

函数参数：

| 参数 | 含义 |
|---|---|
| `src` | 源 NV12 数据地址 |
| `src_size` | 源数据大小 |
| `dst` | 目标 MPP buffer 地址 |
| `dst_size` | 目标 buffer 大小 |

### 第 230～233 行

空指针检查。只要源或目标为空，就失败。

### 第 235～241 行

计算紧凑 NV12 理论大小：

```cpp
width_ * height_ * 3 / 2
```

如果源不够大，或者目标小于 `frame_size_`，就不能安全拷贝。

### 第 243 行

```cpp
memset(dst, 0, dst_size);
```

先把目标 buffer 清零。这样如果 stride 区域有 padding，也不会留下脏数据。

### 第 245～253 行

如果 stride 和真实宽高完全一致，说明没有 padding，直接拷贝即可：

```cpp
memcpy(dst, src, compact_size);
```

### 第 255～264 行

如果 stride 不一致，就分别处理 Y 平面和 UV 平面。

NV12 内存布局：

```text
src_y  指向开头
src_uv 指向 Y 平面后面的位置，也就是 src + width * height

dst_y  指向目标开头
dst_uv 指向目标 Y 平面对齐区域后面，也就是 dst + hor_stride * ver_stride
```

### 第 266～271 行

逐行拷贝 Y 平面：

```cpp
for 每一行 y:
    从 src_y 的第 y 行复制 width 字节
    到 dst_y 的第 y 行，但目标每行跨度是 hor_stride
```

### 第 273～278 行

逐行拷贝 UV 平面。UV 平面高度是 `height_/2`。

### 第 280 行

全部成功后返回 `true`。

---

## 2.8 PTS / DTS / flags 接口：第 284～311 行


```cpp
 284  void MppH264Encoder::set_next_pts_us(int64_t pts_us)
 285  {
 286      next_pts_us_ = pts_us;
 287  }
 288  
 289  int64_t MppH264Encoder::last_packet_pts_us() const
 290  {
 291      return last_packet_pts_us_;
 292  }
 293  
 294  int64_t MppH264Encoder::last_packet_dts_us() const
 295  {
 296      return last_packet_dts_us_;
 297  }
 298  
 299  uint32_t MppH264Encoder::last_packet_flags() const
 300  {
 301      return last_packet_flags_;
 302  }
 303  
 304  bool MppH264Encoder::last_packet_is_intra() const
 305  {
 306  #ifdef MPP_PACKET_FLAG_INTRA
 307      return (last_packet_flags_ & MPP_PACKET_FLAG_INTRA) != 0;
 308  #else
 309      return (last_packet_flags_ & 0x00000008) != 0;
 310  #endif
 311  }
```


这些函数是实验23新增的时间戳接口。

逐行解释：

- 第 284～287 行：`set_next_pts_us` 设置下一帧要写入 MppFrame 的 PTS。
- 第 289～292 行：`last_packet_pts_us` 返回上一次编码得到的 packet PTS。
- 第 294～297 行：`last_packet_dts_us` 返回上一次编码得到的 packet DTS。
- 第 299～302 行：`last_packet_flags` 返回上一次 packet 的 flags。
- 第 304～311 行：根据 flags 判断是否为 intra / IDR 帧。

语法点：

```cpp
int64_t MppH264Encoder::last_packet_pts_us() const
```

最后的 `const` 表示这个函数不会修改对象内部状态。

`#ifdef ... #else ... #endif` 是预处理条件编译：

```text
如果编译环境定义了 MPP_PACKET_FLAG_INTRA，就用官方宏；
否则用 0x00000008 作为兼容值。
```

---

## 2.9 核心编码函数 encode：第 313～430 行


```cpp
 313  bool MppH264Encoder::encode(const uint8_t *nv12_data,
 314                              size_t nv12_size,
 315                              std::vector<uint8_t> &out_packet) // 核心编码流水线
 316  {
 317      out_packet.clear();
 318  
 319      if (!inited_ || ctx_ == nullptr || mpi_ == nullptr)
 320      {
 321          printf("encode failed: encoder not initialized\n");
 322          return false;
 323      }
 324  
 325      MPP_RET ret = MPP_OK;
 326  
 327      MppBuffer frame_buf = nullptr;  
 328      ret = mpp_buffer_get(nullptr, &frame_buf, frame_size_);  //申请内存
 329      if (ret != MPP_OK || frame_buf == nullptr)
 330      {
 331          printf("mpp_buffer_get failed, ret=%d\n", ret);
 332          return false;
 333      }
 334  
 335      void *buf_ptr = mpp_buffer_get_ptr(frame_buf);
 336      if (buf_ptr == nullptr)
 337      {
 338          printf("mpp_buffer_get_ptr failed\n");
 339          mpp_buffer_put(frame_buf);
 340          return false;
 341      }
 342  
 343      bool copy_ok = copy_nv12_to_mpp_buffer(nv12_data,
 344                                             nv12_size,
 345                                             static_cast<uint8_t *>(buf_ptr),
 346                                             frame_size_);   // 搬运数据，
 347      if (!copy_ok)
 348      {
 349          mpp_buffer_put(frame_buf);
 350          return false;
 351      }
 352      // 开始打包成frame结构，然后做成MppFrame结构，打标签（数据宽高以及对齐的跨距和格式等等）
 353      MppFrame frame = nullptr;
 354      ret = mpp_frame_init(&frame);
 355      if (ret != MPP_OK || frame == nullptr)
 356      {
 357          printf("mpp_frame_init failed, ret=%d\n", ret);
 358          mpp_buffer_put(frame_buf);
 359          return false;
 360      }
 361  
 362      mpp_frame_set_width(frame, width_);
 363      mpp_frame_set_height(frame, height_);
 364      mpp_frame_set_hor_stride(frame, hor_stride_);
 365      mpp_frame_set_ver_stride(frame, ver_stride_);
 366      mpp_frame_set_fmt(frame, MPP_FMT_YUV420SP);
 367      mpp_frame_set_buffer(frame, frame_buf);
 368      if (next_pts_us_ >= 0) {
 369          mpp_frame_set_pts(frame, next_pts_us_);
 370      }
 371      mpp_frame_set_eos(frame, 0);
 372  
 373      ret = mpi_->encode_put_frame(ctx_, frame);
 374      if (ret != MPP_OK)
 375      {
 376          printf("encode_put_frame failed, ret=%d\n", ret);
 377          mpp_frame_deinit(&frame);
 378          mpp_buffer_put(frame_buf);
 379          return false;
 380      }
 381  
 382      MppPacket packet = nullptr;
 383      bool got_packet = false;
 384  
 385      /*
 386       * H.264 一般每输入一帧可以取到一个 packet。
 387       * 这里加短暂轮询，避免偶发的异步返回。
 388       */
 389      for (int retry = 0; retry < 100; ++retry) //硬件计算耗时，代码中进行循环的轮询 
 390      {
 391          ret = mpi_->encode_get_packet(ctx_, &packet); //不断调用此函数直到拿到非空的packet然后追加到out_packet当中，跳出循环
 392          if (ret != MPP_OK)
 393          {
 394              printf("encode_get_packet failed, ret=%d retry=%d\n", ret, retry);
 395              usleep(1000);
 396              continue;
 397          }
 398  
 399          if (packet != nullptr)
 400          {
 401              last_packet_pts_us_ = mpp_packet_get_pts(packet);
 402              last_packet_dts_us_ = mpp_packet_get_dts(packet);
 403              last_packet_flags_ = mpp_packet_get_flag(packet);
 404  
 405              void *ptr = mpp_packet_get_pos(packet);
 406              size_t len = mpp_packet_get_length(packet);
 407  
 408              if (ptr != nullptr && len > 0)
 409              {
 410                  const uint8_t *p = static_cast<const uint8_t *>(ptr);
 411                  out_packet.assign(p, p + len);
 412                  got_packet = true;
 413              }
 414              mpp_packet_deinit(&packet);
 415              break;
 416          }
 417  
 418          usleep(1000);
 419      }
 420  
 421      mpp_frame_deinit(&frame);
 422      mpp_buffer_put(frame_buf);
 423  
 424      if (!got_packet)
 425      {
 426          printf("warning: encode finished but no packet got\n");
 427      }
 428  
 429      return got_packet;
 430  }
```


这是最核心的函数。它的作用是：

```text
输入一帧 NV12
    ↓
复制到 MPP buffer
    ↓
封装成 MppFrame
    ↓
送进 MPP 编码器
    ↓
轮询取出 MppPacket
    ↓
把 packet 内容拷贝到 out_packet
```

逐段解释：

### 第 313～315 行

```cpp
bool MppH264Encoder::encode(const uint8_t *nv12_data,
                            size_t nv12_size,
                            std::vector<uint8_t> &out_packet)
```

参数含义：

| 参数 | 含义 |
|---|---|
| `nv12_data` | 输入一帧 NV12 数据地址 |
| `nv12_size` | 输入数据大小 |
| `out_packet` | 输出 H.264 packet 字节数组 |

返回值：

```text
true  = 编码成功并拿到 packet
false = 编码失败或没有拿到 packet
```

### 第 317 行

清空输出 packet，避免旧数据残留。

### 第 319～323 行

检查编码器是否初始化。

### 第 327～333 行

申请 MPP 输入 buffer：

```cpp
mpp_buffer_get(nullptr, &frame_buf, frame_size_)
```

这块 buffer 是给硬件编码器读取的输入图像内存。

### 第 335～341 行

拿到 buffer 的 CPU 可访问地址：

```cpp
void *buf_ptr = mpp_buffer_get_ptr(frame_buf);
```

如果拿不到地址，说明不能拷贝数据进去，要释放 buffer 并返回失败。

### 第 343～351 行

调用前面的 `copy_nv12_to_mpp_buffer`，把外部 NV12 数据搬进 MPP buffer。

注意这里：

```cpp
static_cast<uint8_t *>(buf_ptr)
```

`buf_ptr` 原来是 `void*`，表示“未知类型指针”。拷贝字节时需要转成 `uint8_t*`。

### 第 353～360 行

创建 `MppFrame`。`MppFrame` 不是图像数据本身，而是描述一帧图像的“元信息对象”。

里面会记录：

```text
宽、高、stride、格式、buffer、PTS、是否结束等
```

### 第 362～371 行

给 MppFrame 填属性：

```cpp
mpp_frame_set_width(frame, width_);
mpp_frame_set_height(frame, height_);
mpp_frame_set_hor_stride(frame, hor_stride_);
mpp_frame_set_ver_stride(frame, ver_stride_);
mpp_frame_set_fmt(frame, MPP_FMT_YUV420SP);
mpp_frame_set_buffer(frame, frame_buf);
```

最关键的是：

```cpp
if (next_pts_us_ >= 0) {
    mpp_frame_set_pts(frame, next_pts_us_);
}
```

这把当前帧的 PTS 写入 MPP。后续可以从编码输出 packet 里读回来。

```cpp
mpp_frame_set_eos(frame, 0);
```

`eos` 是 end of stream。这里为 0，表示还不是最后一帧。

### 第 373～380 行

```cpp
ret = mpi_->encode_put_frame(ctx_, frame);
```

把一帧送进编码器。

如果失败，需要释放：

```cpp
mpp_frame_deinit(&frame);
mpp_buffer_put(frame_buf);
```

### 第 382～419 行

编码器可能不是立刻返回 packet，所以用循环最多轮询 100 次：

```cpp
for (int retry = 0; retry < 100; ++retry)
```

每次调用：

```cpp
mpi_->encode_get_packet(ctx_, &packet)
```

如果没有拿到，就 `usleep(1000)` 等 1ms 再试。

拿到 packet 后：

```cpp
last_packet_pts_us_ = mpp_packet_get_pts(packet);
last_packet_dts_us_ = mpp_packet_get_dts(packet);
last_packet_flags_ = mpp_packet_get_flag(packet);
```

读回时间戳和 flags。

再通过：

```cpp
void *ptr = mpp_packet_get_pos(packet);
size_t len = mpp_packet_get_length(packet);
```

拿到 H.264 数据地址和长度。

最后：

```cpp
out_packet.assign(p, p + len);
```

把 H.264 packet 拷贝到标准 C++ vector 中，方便外部写文件。

### 第 414 行

释放 MppPacket。

### 第 421～422 行

无论成功失败，输入 frame 和 buffer 都要释放。

### 第 424～429 行

如果没拿到 packet，打印 warning，然后返回 `got_packet`。

---

## 2.10 释放资源：第 432～448 行


```cpp
 432  void MppH264Encoder::release()
 433  {
 434      if (cfg_ != nullptr)
 435      {
 436          mpp_enc_cfg_deinit(cfg_);
 437          cfg_ = nullptr;
 438      }
 439  
 440      if (ctx_ != nullptr)
 441      {
 442          mpp_destroy(ctx_);
 443          ctx_ = nullptr;
 444          mpi_ = nullptr;
 445      }
 446  
 447      inited_ = false;
 448  }
```


逐行解释：

- 第 434～438 行：如果配置对象 `cfg_` 不为空，就释放它，然后把指针置空。
- 第 440～445 行：如果 MPP 上下文 `ctx_` 不为空，就销毁 MPP 实例，然后把 `ctx_` 和 `mpi_` 置空。
- 第 447 行：标记编码器未初始化。

为什么释放后要置空？

```text
避免悬空指针。释放后的地址不能再用，把它设为 nullptr 可以降低误用风险。
```

---

# 3. `main_exp21_detect_mpp_encode_async.cpp` 逐行理解

这个文件是主程序。它比较长，可以按运行顺序拆成 13 个阶段。

---

## 3.1 头文件包含和时间函数：第 1～42 行


```cpp
   1  #include "mpp_h264_encoder.hpp"
   2  #include <queue>
   3  #include <mutex>
   4  #include <condition_variable>
   5  #include <thread>
   6  #include <cstdint>
   7  #include <string>
   8  
   9  static int64_t exp23_now_us()
  10  {
  11      using namespace std::chrono;
  12      return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
  13  }
  14  
  15  
  16  #include <atomic>
  17  #include <utility>
  18  #include <fcntl.h>
  19  #include <linux/videodev2.h>
  20  #include <sys/ioctl.h>
  21  #include <sys/mman.h>
  22  #include <sys/select.h>
  23  #include <sys/stat.h>
  24  #include <unistd.h>
  25  
  26  #include <cerrno>
  27  #include <cstdio>
  28  #include <cstdlib>
  29  #include <cstring>
  30  #include <vector>
  31  #include <chrono>
  32  #include <fstream>
  33  #include <iomanip>
  34  
  35  #include "yolo11.h"
  36  #include "image_utils.h"
  37  #include "file_utils.h"
  38  
  39  #include <opencv2/opencv.hpp>
  40  
  41  #include "im2d.hpp"
  42  #include "RgaUtils.h"
```


逐段解释：

- 第 1 行：包含自研的 MPP H.264 编码器头文件，后面才能创建 `MppH264Encoder mpp_encoder;`。
- 第 2～7 行：包含 C++ 标准库：队列、互斥锁、条件变量、线程、整数类型、字符串。
- 第 9～13 行：定义 `exp23_now_us()`，返回当前单调时钟时间，单位微秒。

`using namespace std::chrono;` 的作用是让后面可以直接写 `duration_cast`、`microseconds`、`steady_clock`，不用每个都写 `std::chrono::`。

`steady_clock` 是单调时钟，适合做耗时统计，因为它不会像系统时间那样被人为校时影响。

- 第 16 行：`<atomic>` 提供原子变量，用于多线程安全计数。
- 第 18～24 行：Linux 系统调用相关头文件，V4L2 摄像头、ioctl、mmap、select、close 等都需要。
- 第 26～33 行：错误码、printf、字符串处理、vector、时间、文件流、格式化输出。
- 第 35～37 行：YOLO/RKNN demo 相关头文件。
- 第 39 行：OpenCV 头文件，用来画框、保存图片。
- 第 41～42 行：RGA 相关头文件，用来做 NV12/RGB 转换。

---

## 3.2 V4L2 Buffer 结构和 ioctl 包装：第 43～62 行


```cpp
  43  //结构体用来记录映射之后的内存地址方便代码读取
  44  struct Buffer {
  45      void* start = nullptr;
  46      size_t length = 0;
  47  };
  48  //封装原生的ioctl函数，避免系统软中断打断系统调用（ioctl控制摄像头被系统软终端打断）
  49  static int xioctl(int fd, unsigned long request, void* arg)
  50  {
  51      int r;
  52      do {
  53          r = ioctl(fd, request, arg);
  54      } while (r == -1 && errno == EINTR);
  55      return r;
  56  }
  57  //用chrono库进行高精度耗时计算，进行性能分析
  58  static double diff_ms(const std::chrono::steady_clock::time_point& a,
  59                        const std::chrono::steady_clock::time_point& b)
  60  {
  61      return std::chrono::duration<double, std::milli>(b - a).count();
  62  }
```


逐行解释：

### 第 44～47 行

```cpp
struct Buffer {
    void* start = nullptr;
    size_t length = 0;
};
```

这个结构体保存 mmap 后的缓冲区信息：

| 成员 | 含义 |
|---|---|
| `start` | 映射到用户态后的内存地址 |
| `length` | 这块 buffer 的长度 |

摄像头驱动把图像写到内核 buffer 中，用户程序通过 `mmap` 映射到自己的进程地址空间。`start` 就是我们读取这一帧数据的入口。

### 第 49～56 行

`xioctl` 是对 Linux `ioctl` 的小封装。

```cpp
r = ioctl(fd, request, arg);
```

`ioctl` 用来向设备驱动发送控制命令，比如：

```text
查询摄像头能力
设置格式
申请 buffer
取出一帧
归还 buffer
启动视频流
停止视频流
```

为什么要用 `do ... while`？

```cpp
} while (r == -1 && errno == EINTR);
```

如果系统调用被信号中断，`errno` 会是 `EINTR`，这不是设备真正失败，所以重新调用一次。

### 第 58～62 行

`diff_ms(a, b)` 计算两个时间点之间的毫秒差。

```cpp
std::chrono::duration<double, std::milli>(b - a).count()
```

意思是把 `b-a` 这段时间转换为“double 类型的毫秒”。

---

## 3.3 检测框颜色表和画框函数：第 64～174 行


```cpp
  64  static const unsigned char colors[19][3] = {
  65      {54, 67, 244},
  66      {99, 30, 233},
  67      {176, 39, 156},
  68      {183, 58, 103},
  69      {181, 81, 63},
  70      {243, 150, 33},
  71      {244, 169, 3},
  72      {212, 188, 0},
  73      {136, 150, 0},
  74      {80, 175, 76},
  75      {74, 195, 139},
  76      {57, 220, 205},
  77      {59, 235, 255},
  78      {7, 193, 255},
  79      {0, 152, 255},
  80      {34, 87, 255},
  81      {72, 85, 121},
  82      {158, 158, 158},
  83      {139, 125, 96}
  84  };
  85  //cv::mat默认是BGR，但是此时cv::scalar按照内存通道写入
  86  static void draw_detections_on_rgb(cv::Mat& rgb,
  87                                     const object_detect_result_list& od_results,
  88                                     int frame_id)
  89  {
  90      char text[256];
  91  
  92      for (int i = 0; i < od_results.count; i++) {
  93          const unsigned char* color = colors[i % 19];
  94  
  95          /*
  96           * 注意：
  97           * 这里的 Mat 内存实际是 RGB，不是 OpenCV 默认 BGR。
  98           * cv::Scalar 只是按内存通道写入，所以这里传入近似 RGB 顺序即可。
  99           */
 100          cv::Scalar box_color(color[2], color[1], color[0]);
 101  
 102          const object_detect_result* det = &(od_results.results[i]);
 103          //从npu推理完成之后的结果中提取边界框置信度然后打印到终端
 104          printf("frame=%d %s @ (%d %d %d %d) %.3f\n",
 105                 frame_id,
 106                 coco_cls_to_name(det->cls_id),
 107                 det->box.left,
 108                 det->box.top,
 109                 det->box.right,
 110                 det->box.bottom,
 111                 det->prop);
 112          //边界保护
 113          int x1 = det->box.left;
 114          int y1 = det->box.top;
 115          int x2 = det->box.right;
 116          int y2 = det->box.bottom;
 117          //
 118          if (x1 < 0) x1 = 0;
 119          if (y1 < 0) y1 = 0;
 120          if (x2 > rgb.cols - 1) x2 = rgb.cols - 1;
 121          if (y2 > rgb.rows - 1) y2 = rgb.rows - 1;
 122  
 123          if (x2 <= x1 || y2 <= y1) {
 124              continue;
 125          }
 126          //调用opencv::rectangle画框，snprintf格式化类别名称和置信度，gettextsize计算文字大小画上文字背景板，puttext协商白色文字
 127          cv::rectangle(rgb,
 128                        cv::Rect(cv::Point(x1, y1), cv::Point(x2, y2)),
 129                        box_color,
 130                        2);
 131  
 132          snprintf(text,
 133                   sizeof(text),
 134                   "%s %.1f%%",
 135                   coco_cls_to_name(det->cls_id),
 136                   det->prop * 100.0f);
 137  
 138          int baseLine = 0;
 139          cv::Size label_size = cv::getTextSize(text,
 140                                                cv::FONT_HERSHEY_SIMPLEX,
 141                                                0.5,
 142                                                1,
 143                                                &baseLine);
 144  
 145          int tx = x1;
 146          int ty = y1 - label_size.height - baseLine;
 147  
 148          if (ty < 0) {
 149              ty = 0;
 150          }
 151  
 152          if (tx + label_size.width > rgb.cols) {
 153              tx = rgb.cols - label_size.width;
 154          }
 155  
 156          if (tx < 0) {
 157              tx = 0;
 158          }
 159  
 160          cv::rectangle(rgb,
 161                        cv::Rect(cv::Point(tx, ty),
 162                                 cv::Size(label_size.width, label_size.height + baseLine)),
 163                        box_color,
 164                        -1);
 165  
 166          cv::putText(rgb,
 167                      text,
 168                      cv::Point(tx, ty + label_size.height),
 169                      cv::FONT_HERSHEY_SIMPLEX,
 170                      0.5,
 171                      cv::Scalar(255, 255, 255),
 172                      1);
 173      }
 174  }
```


这段负责把 YOLO 检测结果画到 RGB 图像上。

### 第 64～84 行：颜色表

```cpp
static const unsigned char colors[19][3] = { ... };
```

这是一个 19 行 3 列的数组。每一行代表一种颜色，每种颜色有 3 个通道。

为什么有 19 种？

```text
检测结果可能有很多框，用 i % 19 循环取颜色，可以让不同框颜色不一样。
```

### 第 86～89 行：函数声明

```cpp
static void draw_detections_on_rgb(cv::Mat& rgb,
                                   const object_detect_result_list& od_results,
                                   int frame_id)
```

参数含义：

| 参数 | 含义 |
|---|---|
| `cv::Mat& rgb` | 要画框的 RGB 图像，引用传入，函数内部直接修改原图 |
| `od_results` | YOLO 检测结果列表 |
| `frame_id` | 当前帧编号，打印日志用 |

### 第 90 行

```cpp
char text[256];
```

准备一个 C 风格字符数组，用来保存标签文字，例如 `person 88.5%`。

### 第 92 行

```cpp
for (int i = 0; i < od_results.count; i++)
```

遍历每个检测框。

### 第 93 行

```cpp
const unsigned char* color = colors[i % 19];
```

用第 `i` 个检测结果选择一种颜色。如果检测框超过 19 个，就循环使用颜色表。

### 第 100 行

```cpp
cv::Scalar box_color(color[2], color[1], color[0]);
```

OpenCV 常默认 BGR，但这里 Mat 内存实际是 RGB。注释也提醒了这一点。这里按实际通道写入颜色。

### 第 102 行

```cpp
const object_detect_result* det = &(od_results.results[i]);
```

取第 `i` 个检测结果的地址。`det` 是一个指针。

### 第 104～111 行

打印检测结果：

```text
frame=当前帧 类别名 @ (left top right bottom) 置信度
```

`coco_cls_to_name(det->cls_id)` 把类别编号转成类别名称。

### 第 113～121 行

从检测结果里取框坐标，并做边界保护。

为什么要边界保护？

```text
模型后处理得到的坐标可能略微超出图像边界。
如果直接拿超出边界的坐标画图，OpenCV 可能报错或画错。
```

### 第 123～125 行

如果右边界不大于左边界，或者下边界不大于上边界，说明框无效，跳过。

### 第 127～130 行

调用 OpenCV 画矩形框：

```cpp
cv::rectangle(rgb, cv::Rect(...), box_color, 2);
```

最后的 `2` 表示线宽为 2。

### 第 132～136 行

用 `snprintf` 格式化标签文字，例如：

```text
person 87.3%
```

`sizeof(text)` 可以防止写超过 `text[256]` 的长度，比 `sprintf` 更安全。

### 第 138～143 行

计算文字大小，方便后面给文字画背景板。

### 第 145～158 行

计算文字左上角位置，并保证文字不会越界。

### 第 160～164 行

画文字背景矩形。最后的 `-1` 表示填充整个矩形，而不是只画边框。

### 第 166～172 行

画白色文字。

---

## 3.4 保存 debug 图片函数：第 175～182 行


```cpp
 175  //保留debug开发工具
 176  static bool save_rgb_debug_jpg(const char* path, const unsigned char* rgb_data, int width, int height)
 177  {
 178      cv::Mat rgb(height, width, CV_8UC3, const_cast<unsigned char*>(rgb_data));
 179      cv::Mat bgr;
 180      cv::cvtColor(rgb, bgr, cv::COLOR_RGB2BGR);
 181      return cv::imwrite(path, bgr);
 182  }
```


这个函数目前是 debug 工具，不是主流程必须。

逐行解释：

- 第 176 行：函数输入路径、RGB 数据地址、宽高。
- 第 178 行：把原始 RGB 内存包装成 OpenCV Mat。
- 第 179 行：创建一个 BGR Mat。
- 第 180 行：OpenCV 保存图片通常按 BGR，所以先 `RGB2BGR`。
- 第 181 行：写入 jpg/png 文件，返回是否成功。

`const_cast<unsigned char*>` 是去掉 const 的类型转换。这里是因为 `cv::Mat` 构造函数需要非 const 指针，但函数本身不会修改数据。

---

## 3.5 异步编码帧结构：第 185～191 行


```cpp
 185  struct Exp21EncFrame
 186  {
 187      int frame_id = 0;
 188      int64_t pts_us = -1;
 189      int64_t enqueue_ts_us = -1;
 190      std::vector<unsigned char> nv12;
 191  };
```


这个结构体表示“准备交给编码线程的一帧”。

| 成员 | 含义 |
|---|---|
| `frame_id` | 当前帧编号 |
| `pts_us` | 当前帧显示时间戳，单位微秒 |
| `enqueue_ts_us` | 进入编码队列的真实时间，用来计算排队延迟 |
| `nv12` | 当前帧的 NV12 图像数据 |

为什么要把 `nv12` 放进 `std::vector`？

```text
主线程很快会把 V4L2 buffer 归还给摄像头驱动。
如果编码线程还直接指向原始 buffer，数据可能被下一帧覆盖。
所以必须拷贝一份独立 NV12 数据给编码线程。
```

---

## 3.6 main 参数解析和基础变量：第 193～225 行


```cpp
 193  int main(int argc, char** argv)
 194  {   //参数校验
 195      if (argc != 8) {
 196          printf("Usage: %s <model_path> <video_dev> <width> <height> <frames> <output_h264> <profile_csv>\n", argv[0]);
 197          printf("Example: %s models/yolo11.rknn /dev/video11 1280 720 120 output/exp21_3_detect_mpp_encode/detect_120f_1280x720.h264 output/exp08_3_detect_fifo_mpp/profile.csv\n", argv[0]);
 198          return -1;
 199      }
 200      //atoi字符串转成整数，赋值给相应变量
 201      const char* model_path = argv[1];
 202      const char* dev_name = argv[2];
 203      int width = atoi(argv[3]);
 204      int height = atoi(argv[4]);
 205      int frames = atoi(argv[5]);
 206      const char* out_path = argv[6];
 207      const char* profile_csv_path = argv[7];
 208  
 209      const int mpp_fps = 30;
 210      const int mpp_bitrate = 4000000;
 211      //计算图像大小
 212      const size_t nv12_size = (size_t)width * height * 3 / 2;
 213      const size_t rgb_size = (size_t)width * height * 3;
 214  
 215      printf("model      : %s\n", model_path);
 216      printf("video dev  : %s\n", dev_name);
 217      printf("width      : %d\n", width);
 218      printf("height     : %d\n", height);
 219      printf("frames     : %d\n", frames);
 220      printf("out h264   : %s\n", out_path);
 221      printf("profile csv: %s\n", profile_csv_path);
 222      printf("nv12 size  : %zu\n", nv12_size);
 223      printf("mpp fps    : %d\n", mpp_fps);
 224      printf("mpp bitrate: %d\n", mpp_bitrate);
 225      printf("rgb size   : %zu\n", rgb_size);
```


逐段解释：

### 第 193 行

```cpp
int main(int argc, char** argv)
```

C/C++ 程序入口。

- `argc`：命令行参数个数。
- `argv`：命令行参数数组。

例如命令：

```bash
./build/exp21_detect_mpp_encode_async model.rknn /dev/video11 1280 720 300 out.h264 profile.csv
```

对应：

| argv 下标 | 内容 |
|---|---|
| `argv[0]` | 程序名 |
| `argv[1]` | model_path |
| `argv[2]` | video_dev |
| `argv[3]` | width |
| `argv[4]` | height |
| `argv[5]` | frames |
| `argv[6]` | output_h264 |
| `argv[7]` | profile_csv |

所以一共 8 个参数。

### 第 195～199 行

如果参数数量不是 8，打印用法并退出。

### 第 201～207 行

把命令行参数保存到变量。

`atoi(argv[3])` 把字符串转成整数。

例如：

```text
"1280" → 1280
```

### 第 209～210 行

固定 MPP 编码帧率和码率：

```cpp
mpp_fps = 30
mpp_bitrate = 4000000
```

即 30fps、4Mbps。

### 第 212～213 行

计算 NV12 和 RGB 图像大小。

### 第 215～225 行

打印参数，便于确认程序是不是按预期运行。

---

## 3.7 打开并检查摄像头设备：第 226～255 行


```cpp
 226      //打开设备查询能力（非阻塞模式进行设备能力查询）
 227      int fd = open(dev_name, O_RDWR | O_NONBLOCK, 0);
 228      if (fd < 0) {
 229          perror("open video device failed");
 230          return -1;
 231      }
 232  
 233      v4l2_capability cap;
 234      memset(&cap, 0, sizeof(cap));
 235  
 236      if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
 237          perror("VIDIOC_QUERYCAP failed");
 238          close(fd);
 239          return -1;
 240      }
 241  
 242      printf("driver     : %s\n", cap.driver);
 243      printf("card       : %s\n", cap.card);
 244  
 245      if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE)) {
 246          printf("ERROR: device does not support V4L2_CAP_VIDEO_CAPTURE_MPLANE\n");
 247          close(fd);
 248          return -1;
 249      }
 250  
 251      if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
 252          printf("ERROR: device does not support V4L2_CAP_STREAMING\n");
 253          close(fd);
 254          return -1;
 255      }
```


逐段解释：

### 第 227 行

```cpp
int fd = open(dev_name, O_RDWR | O_NONBLOCK, 0);
```

打开摄像头设备，例如 `/dev/video11`。

- `O_RDWR`：可读可写。
- `O_NONBLOCK`：非阻塞模式。
- 返回值 `fd` 是文件描述符。Linux 里设备也像文件一样操作。

### 第 228～231 行

如果 `fd < 0`，说明打开失败，打印错误并退出。

### 第 233～240 行

创建 `v4l2_capability cap`，并调用：

```cpp
VIDIOC_QUERYCAP
```

查询摄像头能力，例如驱动名、设备名、是否支持采集、是否支持 streaming。

### 第 242～243 行

打印驱动和设备名。

### 第 245～249 行

检查是否支持多平面视频采集：

```cpp
V4L2_CAP_VIDEO_CAPTURE_MPLANE
```

RK 摄像头常使用 multi-plane API。

### 第 251～255 行

检查是否支持 streaming 模式。后续 mmap buffer 和 streamon 都需要这个能力。

---

## 3.8 设置摄像头输出格式：第 257～282 行


```cpp
 257      v4l2_format fmt; //填充这个结构体
 258      memset(&fmt, 0, sizeof(fmt));
 259  
 260      fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;  //瑞芯微采用多平面采集
 261      fmt.fmt.pix_mp.width = width;
 262      fmt.fmt.pix_mp.height = height;
 263      fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
 264      fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
 265      fmt.fmt.pix_mp.num_planes = 1;
 266  
 267      if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
 268          perror("VIDIOC_S_FMT failed");
 269          close(fd);
 270          return -1;
 271      }
 272  
 273      printf("actual fmt : %ux%u fourcc=%c%c%c%c planes=%u sizeimage=%u bytesperline=%u\n",
 274             fmt.fmt.pix_mp.width,
 275             fmt.fmt.pix_mp.height,
 276             fmt.fmt.pix_mp.pixelformat & 0xff,
 277             (fmt.fmt.pix_mp.pixelformat >> 8) & 0xff,
 278             (fmt.fmt.pix_mp.pixelformat >> 16) & 0xff,
 279             (fmt.fmt.pix_mp.pixelformat >> 24) & 0xff,
 280             fmt.fmt.pix_mp.num_planes,
 281             fmt.fmt.pix_mp.plane_fmt[0].sizeimage,
 282             fmt.fmt.pix_mp.plane_fmt[0].bytesperline);
```


逐行解释：

- 第 257 行：创建格式结构体 `v4l2_format fmt`。
- 第 258 行：清零结构体，避免未初始化字段影响 ioctl。
- 第 260 行：指定 buffer 类型为多平面采集。
- 第 261～262 行：设置宽高。
- 第 263 行：设置像素格式为 NV12。
- 第 264 行：不使用隔行扫描。
- 第 265 行：设置 plane 数量为 1。
- 第 267～271 行：调用 `VIDIOC_S_FMT` 把格式设置给摄像头驱动。
- 第 273～282 行：打印驱动实际接受的格式。

注意：

```text
你设置的是期望格式，但驱动可能调整成它支持的实际格式，所以设置完要打印 actual fmt。
```

---

## 3.9 申请、查询、mmap、入队 V4L2 buffer：第 284～358 行


```cpp
 284      v4l2_requestbuffers req;
 285      memset(&req, 0, sizeof(req));
 286  
 287      req.count = 4;  //多缓冲队列
 288      req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
 289      req.memory = V4L2_MEMORY_MMAP; //指定采用内存映射模式
 290  
 291      if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
 292          perror("VIDIOC_REQBUFS failed");
 293          close(fd);
 294          return -1;
 295      }
 296  
 297      printf("request buffers count: %u\n", req.count);
 298  
 299      std::vector<Buffer> buffers(req.count);
 300  
 301      for (unsigned int i = 0; i < req.count; ++i) {
 302          v4l2_buffer buf;
 303          v4l2_plane planes[1];
 304  
 305          memset(&buf, 0, sizeof(buf));
 306          memset(planes, 0, sizeof(planes));
 307  
 308          buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
 309          buf.memory = V4L2_MEMORY_MMAP;
 310          buf.index = i;
 311          buf.length = 1;
 312          buf.m.planes = planes;
 313  
 314          if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
 315              perror("VIDIOC_QUERYBUF failed");
 316              close(fd);
 317              return -1;
 318          }
 319  
 320          buffers[i].length = buf.m.planes[0].length;  //保存缓冲区长度
 321          buffers[i].start = mmap(NULL,                               //内核选择映射地址
 322                                  buffers[i].length,                  //映射大小
 323                                  PROT_READ | PROT_WRITE,//读写
 324                                  MAP_SHARED,  //共享映射（对硬件的修改也可见）
 325                                  fd,                 //文件描述符
 326                                  buf.m.planes[0].m.mem_offset);    //缓冲区在设备内存中的偏移量
 327  
 328          if (buffers[i].start == MAP_FAILED) {
 329              perror("mmap failed");
 330              close(fd);
 331              return -1;
 332          }
 333  
 334          printf("mmap buffer=%u length=%zu offset=%u\n",
 335                 i,
 336                 buffers[i].length,
 337                 buf.m.planes[0].m.mem_offset);
 338      }
 339  
 340      for (unsigned int i = 0; i < req.count; ++i) {
 341          v4l2_buffer buf;
 342          v4l2_plane planes[1];
 343  
 344          memset(&buf, 0, sizeof(buf));
 345          memset(planes, 0, sizeof(planes));
 346  
 347          buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
 348          buf.memory = V4L2_MEMORY_MMAP;
 349          buf.index = i;
 350          buf.length = 1;
 351          buf.m.planes = planes;
 352  
 353          if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
 354              perror("VIDIOC_QBUF failed");
 355              close(fd);
 356              return -1;
 357          }
 358      }
```


这是 V4L2 采集里最核心的一部分。

### 第 284～295 行：申请 buffer

```cpp
v4l2_requestbuffers req;
req.count = 4;
req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
req.memory = V4L2_MEMORY_MMAP;
VIDIOC_REQBUFS
```

意思是：向驱动申请 4 个 mmap buffer。

为什么申请多个 buffer？

```text
摄像头在采集，用户程序在处理。
如果只有一个 buffer，采集和处理容易互相等待。
多个 buffer 可以形成流水线。
```

### 第 299 行

```cpp
std::vector<Buffer> buffers(req.count);
```

创建用户态数组，保存每个 buffer 的地址和长度。

### 第 301～338 行：查询并 mmap 每个 buffer

对每个 buffer：

1. 创建 `v4l2_buffer buf` 和 `v4l2_plane planes[1]`。
2. 清零。
3. 设置类型、内存方式、索引。
4. 调用 `VIDIOC_QUERYBUF` 查询 buffer 长度和偏移。
5. 调用 `mmap` 把内核 buffer 映射到用户空间。

最关键的是：

```cpp
buffers[i].start = mmap(..., fd, buf.m.planes[0].m.mem_offset);
```

这之后，用户程序就可以通过 `buffers[i].start` 直接读取摄像头填好的 NV12 数据。

### 第 340～358 行：把 buffer 全部放回驱动队列

```cpp
VIDIOC_QBUF
```

QBUF 的意思是 queue buffer。把空 buffer 交给驱动，驱动才能往里面写图像。

V4L2 基本循环是：

```text
初始化时：QBUF 把空 buffer 交给驱动
采集中：DQBUF 取出装满图像的 buffer
处理完：QBUF 把 buffer 归还驱动
```

---

## 3.10 初始化输出文件、MPP 编码器、异步队列：第 359～402 行


```cpp
 359      //打开输出管道等
 360      FILE* fout = fopen(out_path, "wb");
 361      if (!fout) {
 362          perror("fopen output failed");
 363          close(fd);
 364          return -1;
 365      }
 366  
 367      MppH264Encoder mpp_encoder;
 368      if (!mpp_encoder.init(width, height, mpp_fps, mpp_bitrate)) {
 369          printf("MppH264Encoder init failed\n");
 370          fclose(fout);
 371          return -1;
 372      }
 373  
 374      std::vector<uint8_t> h264_header;
 375      if (mpp_encoder.get_header(h264_header) && !h264_header.empty()) {
 376          fwrite(h264_header.data(), 1, h264_header.size(), fout);
 377          printf("write h264 header: %zu bytes\n", h264_header.size());
 378      } else {
 379          printf("warning: empty h264 header\n");
 380      }
 381  
 382      std::vector<uint8_t> h264_packet;
 383  
 384      std::queue<Exp21EncFrame> enc_queue;
 385      std::mutex enc_mutex;
 386      std::condition_variable enc_cv;
 387      std::atomic<bool> enc_stop(false);
 388      std::atomic<int> async_encoded_frames(0);
 389      std::atomic<int> async_encode_failures(0);
 390      std::atomic<int> async_drop_frames(0);
 391      std::atomic<long long> async_encode_us(0);
 392      std::atomic<long long> async_write_us(0);
 393      std::atomic<long long> async_total_us(0);
 394  
 395      const size_t max_enc_queue_size = 8;
 396  
 397  
 398      std::string enc_pts_csv_path = std::string(out_path) + ".pts.csv";
 399      std::ofstream enc_pts_csv(enc_pts_csv_path);
 400      enc_pts_csv << "frame_id,input_pts_us,mpp_packet_pts_us,mpp_packet_dts_us,"
 401                     "pts_match,is_intra,queue_delay_ms,encode_wall_ms,packet_size\n";
 402  
```


逐段解释：

### 第 360～365 行

打开输出 H.264 文件或 FIFO：

```cpp
FILE* fout = fopen(out_path, "wb");
```

- `w`：写入。
- `b`：二进制模式。

### 第 367～372 行

创建 MPP 编码器对象并初始化。

```cpp
MppH264Encoder mpp_encoder;
mpp_encoder.init(width, height, mpp_fps, mpp_bitrate)
```

### 第 374～380 行

获取 H.264 header，并先写入输出文件。

为什么要先写 header？

```text
裸 H.264 文件需要 SPS/PPS，解码器才能知道如何解码后面的帧。
```

### 第 382 行

```cpp
std::vector<uint8_t> h264_packet;
```

这个变量在当前异步版本里基本没用，因为真正写 packet 的是编码线程里的 `local_packet`。

### 第 384～393 行

创建异步编码需要的数据结构：

| 变量 | 作用 |
|---|---|
| `enc_queue` | 主线程向编码线程传递帧的队列 |
| `enc_mutex` | 保护队列的互斥锁 |
| `enc_cv` | 条件变量，用来唤醒编码线程 |
| `enc_stop` | 通知编码线程退出 |
| `async_encoded_frames` | 已编码帧数 |
| `async_encode_failures` | 编码失败次数 |
| `async_drop_frames` | 队列满时丢弃的帧数 |
| `async_encode_us` | 编码耗时累计，单位微秒 |
| `async_write_us` | 写文件耗时累计 |
| `async_total_us` | 编码线程总耗时累计 |

### 第 395 行

最大编码队列长度为 8。

如果编码线程跟不上主线程，队列超过 8，就丢旧帧，避免延迟无限累积。

### 第 398～401 行

创建 PTS CSV 文件，写入表头。

这个文件记录：

```text
frame_id,input_pts_us,mpp_packet_pts_us,mpp_packet_dts_us,
pts_match,is_intra,queue_delay_ms,encode_wall_ms,packet_size
```

---

## 3.11 异步编码线程：第 403～502 行


```cpp
 403      std::thread encoder_thread([&]() {
 404          std::vector<uint8_t> local_packet;
 405  
 406          while (true) {
 407              Exp21EncFrame item;
 408  
 409              {
 410                  std::unique_lock<std::mutex> lk(enc_mutex);
 411                  enc_cv.wait(lk, [&]() {
 412                      return enc_stop.load() || !enc_queue.empty();
 413                  });
 414  
 415                  if (enc_queue.empty()) {
 416                      if (enc_stop.load()) {
 417                          break;
 418                      }
 419                      continue;
 420                  }
 421  
 422                  item = std::move(enc_queue.front());
 423                  enc_queue.pop();
 424              }
 425  
 426              auto t0 = std::chrono::steady_clock::now();
 427  
 428              int64_t exp23_encode_start_us = exp23_now_us();
 429              int64_t exp23_queue_delay_us = item.enqueue_ts_us >= 0 ? (exp23_encode_start_us - item.enqueue_ts_us) : -1;
 430  
 431              mpp_encoder.set_next_pts_us(item.pts_us);
 432              bool ok = mpp_encoder.encode(item.nv12.data(), nv12_size, local_packet);
 433              int64_t exp23_encode_end_us = exp23_now_us();
 434  
 435              int64_t exp23_mpp_packet_pts_us = mpp_encoder.last_packet_pts_us();
 436              int64_t exp23_mpp_packet_dts_us = mpp_encoder.last_packet_dts_us();
 437              bool exp23_is_intra = mpp_encoder.last_packet_is_intra();
 438  
 439              auto t1 = std::chrono::steady_clock::now();
 440  
 441              if (!ok) {
 442                  async_encode_failures++;
 443                  printf("[ENC] encode failed at frame=%d\n", item.frame_id);
 444                  continue;
 445              }
 446  
 447              size_t written = 0;
 448              if (!local_packet.empty()) {
 449                  written = fwrite(local_packet.data(), 1, local_packet.size(), fout);
 450              }
 451  
 452              auto t2 = std::chrono::steady_clock::now();
 453  
 454              if (!local_packet.empty() && written != local_packet.size()) {
 455                  async_encode_failures++;
 456                  printf("[ENC] write failed at frame=%d written=%zu expected=%zu\n",
 457                         item.frame_id, written, local_packet.size());
 458                  continue;
 459              }
 460  
 461              double enc_ms = diff_ms(t0, t1);
 462              double wr_ms = diff_ms(t1, t2);
 463              double total_ms = diff_ms(t0, t2);
 464  
 465              if (enc_pts_csv.is_open()) {
 466                  int pts_match = (exp23_mpp_packet_pts_us == item.pts_us) ? 1 : 0;
 467                  enc_pts_csv << item.frame_id << ","
 468                              << item.pts_us << ","
 469                              << exp23_mpp_packet_pts_us << ","
 470                              << exp23_mpp_packet_dts_us << ","
 471                              << pts_match << ","
 472                              << (exp23_is_intra ? 1 : 0) << ","
 473                              << (exp23_queue_delay_us >= 0 ? exp23_queue_delay_us / 1000.0 : -1.0) << ","
 474                              << ((exp23_encode_end_us - exp23_encode_start_us) / 1000.0) << ","
 475                              << local_packet.size() << "\n";
 476              }
 477  
 478              async_encode_us += (long long)(enc_ms * 1000.0);
 479              async_write_us += (long long)(wr_ms * 1000.0);
 480              async_total_us += (long long)(total_ms * 1000.0);
 481  
 482              int cnt = ++async_encoded_frames;
 483              if (cnt == 1 || cnt % 30 == 0) {
 484                  printf("[ENC] encoded=%d src_frame=%d packet=%zu input_pts=%lld pkt_pts=%lld pkt_dts=%lld intra=%d qdelay=%.3f encode=%.3f\n",
 485                         cnt,
 486                         item.frame_id,
 487                         local_packet.size(),
 488                         (long long)item.pts_us,
 489                         (long long)exp23_mpp_packet_pts_us,
 490                         (long long)exp23_mpp_packet_dts_us,
 491                         exp23_is_intra ? 1 : 0,
 492                         exp23_queue_delay_us >= 0 ? exp23_queue_delay_us / 1000.0 : -1.0,
 493                         enc_ms);
 494                  fflush(stdout);
 495              }
 496          }
 497  
 498          printf("[ENC] encoder thread exit, encoded=%d failures=%d drops=%d\n",
 499                 async_encoded_frames.load(),
 500                 async_encode_failures.load(),
 501                 async_drop_frames.load());
 502      });
```


这段是异步编码核心。

### 第 403 行

```cpp
std::thread encoder_thread([&]() {
```

创建一个新线程。`[&]` 是 lambda 捕获方式，表示线程函数可以引用外部变量，比如 `enc_queue`、`mpp_encoder`、`fout` 等。

### 第 404 行

```cpp
std::vector<uint8_t> local_packet;
```

编码线程内部使用的 H.264 输出 buffer。

### 第 406 行

```cpp
while (true)
```

编码线程一直循环，直到主线程设置 `enc_stop=true` 且队列为空。

### 第 409～424 行：等待队列中有帧

```cpp
std::unique_lock<std::mutex> lk(enc_mutex);
enc_cv.wait(lk, [&]() {
    return enc_stop.load() || !enc_queue.empty();
});
```

这段是标准条件变量用法。

意思是：

```text
如果队列为空，而且还没停止，编码线程就睡眠。
主线程 push 新帧后 notify_one，编码线程被唤醒。
```

为什么这里用 `unique_lock` 而不是 `lock_guard`？

因为 `condition_variable::wait` 需要在等待时临时释放锁，被唤醒后再重新加锁。`unique_lock` 支持这种操作。

### 第 415～420 行

如果队列为空：

- 如果 `enc_stop` 为真，说明主线程结束了，线程退出。
- 否则继续等待。

### 第 422～423 行

```cpp
item = std::move(enc_queue.front());
enc_queue.pop();
```

从队列取出一帧。

`std::move` 表示移动资源，避免复制整个 NV12 vector，提高效率。

### 第 426～429 行

记录编码开始时间，并计算排队延迟：

```cpp
exp23_queue_delay_us = exp23_encode_start_us - item.enqueue_ts_us
```

也就是这帧从进入队列到真正开始编码等了多久。

### 第 431～433 行

```cpp
mpp_encoder.set_next_pts_us(item.pts_us);
bool ok = mpp_encoder.encode(item.nv12.data(), nv12_size, local_packet);
```

先把这一帧的 PTS 设置给编码器，然后编码 NV12 数据。

### 第 435～437 行

从编码器取回 MPP 输出 packet 的 PTS / DTS / 是否 intra。

### 第 441～445 行

如果编码失败，失败计数加一，打印日志，继续下一帧。

### 第 447～459 行

如果编码成功，把 H.264 packet 写入输出文件或 FIFO。

`fwrite` 返回实际写入字节数。如果和 packet 大小不一致，说明写入失败。

### 第 461～463 行

计算编码耗时、写文件耗时、总耗时。

### 第 465～476 行

写 PTS CSV。

最关键字段：

```cpp
int pts_match = (exp23_mpp_packet_pts_us == item.pts_us) ? 1 : 0;
```

如果 `pts_match=1`，说明 MPP packet 读回的 PTS 和主线程写入的 PTS 一致。

### 第 478～480 行

把耗时累计到原子变量。

### 第 482～495 行

编码成功帧数加一。第一帧和每 30 帧打印一次编码线程日志。

`fflush(stdout)` 强制刷新标准输出，避免日志缓存太久不显示。

### 第 498～501 行

线程退出前打印最终统计。

---

## 3.12 profile CSV、模型初始化、启动流：第 504～557 行


```cpp
 504      //创建csv文件记录性能
 505      std::ofstream profile_csv(profile_csv_path);
 506      if (!profile_csv.is_open()) {
 507          printf("ERROR: could not open profile csv: %s\n", profile_csv_path);
 508          fclose(fout);
 509          close(fd);
 510          return -1;
 511      }
 512  
 513      profile_csv << std::fixed << std::setprecision(3);
 514      profile_csv << "frame_id,"
 515                  << "select_ms,"
 516                  << "dqbuf_ms,"
 517                  << "rga_nv12_to_rgb_ms,"
 518                  << "input_prepare_ms,"
 519                  << "model_total_ms,"
 520                  << "draw_ms,"
 521                  << "rga_rgb_to_nv12_ms,"
 522                  << "write_ms,"
 523                  << "qbuf_ms,"
 524                  << "total_ms,"
 525                  << "fps,"
 526                  << "detect_count"
 527                  << std::endl;
 528  
 529      std::vector<unsigned char> rgb_buf(rgb_size);
 530      std::vector<unsigned char> out_nv12_buf(nv12_size);
 531  
 532      int ret = 0;
 533      rknn_app_context_t rknn_app_ctx;
 534      memset(&rknn_app_ctx, 0, sizeof(rknn_app_ctx));
 535  
 536      init_post_process();
 537      //创建模型结构体然后将内容送到NPU中
 538      ret = init_yolo11_model(model_path, &rknn_app_ctx);
 539      if (ret != 0) {
 540          printf("init_yolo11_model fail! ret=%d model_path=%s\n", ret, model_path);
 541          deinit_post_process();
 542          profile_csv.close();
 543          fclose(fout);
 544          close(fd);
 545          return -1;
 546      }
 547  
 548      v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; // VIDIOC_STREAM是一个宏定义常量，只是数字用于标识视频流启动；启动失败则资源释放
 549      if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
 550          perror("VIDIOC_STREAMON failed");
 551          release_yolo11_model(&rknn_app_ctx);
 552          deinit_post_process();
 553          profile_csv.close();
 554          fclose(fout);
 555          close(fd);
 556          return -1;
 557      }
```


逐段解释：

### 第 505～511 行

打开 profile CSV 文件，用来记录每帧各阶段耗时。

### 第 513～527 行

设置小数精度为 3，并写入 CSV 表头。

每一列对应一帧的耗时：

```text
select_ms,dqbuf_ms,rga_nv12_to_rgb_ms,input_prepare_ms,
model_total_ms,draw_ms,rga_rgb_to_nv12_ms,write_ms,
qbuf_ms,total_ms,fps,detect_count
```

### 第 529～530 行

申请两个图像 buffer：

- `rgb_buf`：存放 RGA 转出来的 RGB 图像。
- `out_nv12_buf`：存放画框后再转回的 NV12 图像。

### 第 532～534 行

创建 RKNN 模型上下文结构体并清零。

### 第 536～546 行

初始化 YOLO 后处理和模型。

```cpp
init_post_process();
init_yolo11_model(model_path, &rknn_app_ctx);
```

如果模型加载失败，释放资源并退出。

### 第 548～557 行

启动 V4L2 视频流：

```cpp
VIDIOC_STREAMON
```

启动后，摄像头驱动才开始往之前 QBUF 的 buffer 里填图像。

---

## 3.13 性能累计变量和主循环开始：第 558～597 行


```cpp
 558      //double变量用于累加所有帧中的各个阶段的耗时，最后计算平均值
 559      double sum_select_ms = 0.0;
 560      double sum_dqbuf_ms = 0.0;
 561      double sum_rga_nv12_to_rgb_ms = 0.0;
 562      double sum_input_prepare_ms = 0.0;
 563      double sum_model_total_ms = 0.0;
 564      double sum_draw_ms = 0.0;
 565      double sum_rga_rgb_to_nv12_ms = 0.0;
 566      double sum_write_ms = 0.0;
 567      double sum_qbuf_ms = 0.0;
 568      double sum_total_ms = 0.0;
 569      //记录整个采集循环的墙钟开始时间，计算总运行时间和帧率
 570      auto wall_start = std::chrono::steady_clock::now();
 571      //成功处理的帧数计数器
 572      int actual_frames = 0;
 573  
 574      for (int frame_id = 0; frame_id < frames; ++frame_id) {
 575          auto t_total0 = std::chrono::steady_clock::now(); //记录此帧开始的时间
 576          //设置select监听
 577          fd_set fds;  //文件描述集合
 578          FD_ZERO(&fds);  //清空
 579          FD_SET(fd, &fds);  //加入集合
 580  
 581          timeval tv;   //设置超时时间
 582          tv.tv_sec = 2;   //超时两秒就select返回0
 583          tv.tv_usec = 0;
 584  
 585          auto t_select0 = std::chrono::steady_clock::now();
 586          int sret = select(fd + 1, &fds, NULL, NULL, &tv); //等待摄像头，超时两秒
 587          auto t_select1 = std::chrono::steady_clock::now();   //t_select0和1记录等待耗时
 588          //错误超时终止循环
 589          if (sret < 0) {
 590              perror("select failed");
 591              break;
 592          }
 593  
 594          if (sret == 0) {
 595              printf("select timeout at frame=%d\n", frame_id);
 596              break;
 597          }
```


逐段解释：

### 第 558～568 行

这些 `sum_xxx_ms` 用来累计每个阶段耗时，最后计算平均值。

例如：

```cpp
sum_model_total_ms += model_ms;
```

循环结束后：

```cpp
avg_model_total_ms = sum_model_total_ms / actual_frames
```

### 第 570 行

记录整个主循环开始时间，用来计算 wall fps。

### 第 572 行

记录实际处理成功的帧数。

### 第 574 行

```cpp
for (int frame_id = 0; frame_id < frames; ++frame_id)
```

主循环。理论上处理 `frames` 帧，例如 300 帧。

### 第 575 行

记录当前帧开始时间。

### 第 577～579 行

准备 `select` 监听的文件描述符集合。

### 第 581～583 行

设置超时时间 2 秒。

### 第 585～587 行

调用 `select` 等待摄像头 fd 可读。

为什么要 `select`？

```text
摄像头不是每时每刻都有新帧。
select 可以等到驱动告诉我们“有帧可取了”再继续。
```

### 第 589～597 行

处理 select 错误或超时。

---

## 3.14 从 V4L2 取出一帧并用 RGA 转 RGB：第 599～649 行


```cpp
 599          v4l2_buffer buf;
 600          v4l2_plane planes[1];
 601  
 602          memset(&buf, 0, sizeof(buf));
 603          memset(planes, 0, sizeof(planes));
 604  
 605          buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
 606          buf.memory = V4L2_MEMORY_MMAP;
 607          buf.length = 1;
 608          buf.m.planes = planes;
 609  
 610          auto t_dq0 = std::chrono::steady_clock::now();
 611          if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {           //VIDIOC_DQBUF从驱动中取出已经填充的buffer
 612              if (errno == EAGAIN) {
 613                  --frame_id;
 614                  continue;
 615              }
 616              perror("VIDIOC_DQBUF failed");
 617              break;
 618          }
 619          auto t_dq1 = std::chrono::steady_clock::now();
 620  
 621          unsigned char* nv12_in = (unsigned char*)buffers[buf.index].start;  //获取NV12原始数据的指针，通过buffer.index就可以找到对应的虚拟地址，指向摄像头输出的NV12帧数据
 622  
 623          auto t_rga_in0 = std::chrono::steady_clock::now();
 624          //NV12格式转成RGA认识NV类型
 625          rga_buffer_t rga_src_nv12 = wrapbuffer_virtualaddr((void*)nv12_in,    //wrapbuffer_virtualaddr将虚拟地址和图像参数重新包装RGA可操作的rga_buffer_t类型
 626                                                             width,
 627                                                             height,
 628                                                             RK_FORMAT_YCbCr_420_SP);
 629          //准备空的RGB内存
 630          rga_buffer_t rga_dst_rgb = wrapbuffer_virtualaddr((void*)rgb_buf.data(),
 631                                                            width,
 632                                                            height,
 633                                                            RK_FORMAT_RGB_888);
 634          //调用RGA执行转换
 635          IM_STATUS rga_status = imcvtcolor(rga_src_nv12,
 636                                            rga_dst_rgb,
 637                                            RK_FORMAT_YCbCr_420_SP,
 638                                            RK_FORMAT_RGB_888);
 639  
 640          auto t_rga_in1 = std::chrono::steady_clock::now();
 641  
 642          if (rga_status != IM_STATUS_SUCCESS) {
 643              printf("RGA NV12->RGB failed at frame=%d status=%d %s\n",
 644                     frame_id,
 645                     rga_status,
 646                     imStrError(rga_status));
 647              xioctl(fd, VIDIOC_QBUF, &buf);   //取出装满的buffer
 648              break;
 649          }
```


逐段解释：

### 第 599～608 行

准备 `v4l2_buffer` 和 `v4l2_plane`，告诉 V4L2 我要取多平面 mmap buffer。

### 第 610～619 行

```cpp
VIDIOC_DQBUF
```

从驱动队列中取出一个已经装满图像数据的 buffer。

如果 `errno == EAGAIN`，说明非阻塞模式下暂时没有帧，于是：

```cpp
--frame_id;
continue;
```

这表示这次不算一帧，下次继续处理同一个编号。

### 第 621 行

```cpp
unsigned char* nv12_in = (unsigned char*)buffers[buf.index].start;
```

根据驱动返回的 `buf.index`，找到对应 mmap 地址。这就是当前帧 NV12 数据的起始指针。

### 第 623～638 行

用 RGA 做 NV12 → RGB：

1. 把 NV12 输入地址包装成 `rga_buffer_t`。
2. 把 RGB 输出地址包装成 `rga_buffer_t`。
3. 调用 `imcvtcolor` 转格式。

`wrapbuffer_virtualaddr` 不复制数据，它只是告诉 RGA：

```text
这块虚拟地址对应一张什么格式、什么宽高的图像。
```

### 第 642～649 行

如果 RGA 转换失败，打印错误，把 buffer 归还给驱动，然后退出循环。

注意：第 647 行注释写“取出装满的buffer”不准确，这里实际做的是 `QBUF`，也就是把 buffer 归还给驱动。

---

## 3.15 准备 YOLO 输入并推理：第 650～675 行


```cpp
 650          //准备模型输入
 651          auto t_prepare0 = std::chrono::steady_clock::now();
 652  
 653          image_buffer_t src_image;
 654          memset(&src_image, 0, sizeof(src_image));
 655  
 656          src_image.width = width;
 657          src_image.height = height;
 658          src_image.format = IMAGE_FORMAT_RGB888;
 659          src_image.virt_addr = rgb_buf.data();
 660          src_image.size = rgb_size;
 661  
 662          object_detect_result_list od_results;
 663          memset(&od_results, 0, sizeof(od_results));  //od_results用于检验接收结果（框的坐标、类别置信度都填充到结构体中）
 664  
 665          auto t_prepare1 = std::chrono::steady_clock::now();
 666  
 667          auto t_model0 = std::chrono::steady_clock::now();
 668          ret = inference_yolo11_model(&rknn_app_ctx, &src_image, &od_results);//inference_yolo11_model需要一个标准化输入参数来描述图像而不是一堆变量，用以统一接口
 669          auto t_model1 = std::chrono::steady_clock::now();
 670  
 671          if (ret != 0) {
 672              printf("inference_yolo11_model fail! ret=%d frame=%d\n", ret, frame_id);
 673              xioctl(fd, VIDIOC_QBUF, &buf);
 674              break;
 675          }
```


逐段解释：

### 第 651 行

记录输入准备开始时间。

### 第 653～660 行

构造 `image_buffer_t src_image`。

这个结构体用于告诉 YOLO 推理函数：

```text
图像宽度是多少
图像高度是多少
图像格式是什么
图像数据地址在哪里
图像数据大小是多少
```

这里格式是：

```cpp
IMAGE_FORMAT_RGB888
```

因为前面 RGA 已经把 NV12 转成 RGB 了。

### 第 662～663 行

创建检测结果结构体 `od_results` 并清零。

推理后，模型会把检测框、类别、置信度填到这里。

### 第 667～669 行

调用 YOLO 推理：

```cpp
ret = inference_yolo11_model(&rknn_app_ctx, &src_image, &od_results);
```

参数含义：

| 参数 | 含义 |
|---|---|
| `&rknn_app_ctx` | 已加载好的模型上下文 |
| `&src_image` | 输入图像描述 |
| `&od_results` | 输出检测结果 |

### 第 671～675 行

如果推理失败，打印错误，归还 buffer，退出循环。

---

## 3.16 画框并转回 NV12：第 676～710 行


```cpp
 676          //rgb图上绘制检测结果
 677          auto t_draw0 = std::chrono::steady_clock::now();
 678  
 679          cv::Mat rgb_mat(height, width, CV_8UC3, rgb_buf.data());
 680          draw_detections_on_rgb(rgb_mat, od_results, frame_id);
 681  
 682          auto t_draw1 = std::chrono::steady_clock::now();
 683          //第二次格式转换
 684          auto t_rga_out0 = std::chrono::steady_clock::now();
 685  
 686          rga_buffer_t rga_src_rgb = wrapbuffer_virtualaddr((void*)rgb_buf.data(),
 687                                                            width,
 688                                                            height,
 689                                                            RK_FORMAT_RGB_888);
 690  
 691          rga_buffer_t rga_dst_nv12 = wrapbuffer_virtualaddr((void*)out_nv12_buf.data(),
 692                                                             width,
 693                                                             height,
 694                                                             RK_FORMAT_YCbCr_420_SP);
 695          //RGB转换成NV12格式（底层编码器对NV12格式压缩效率最高）
 696          rga_status = imcvtcolor(rga_src_rgb,
 697                                  rga_dst_nv12,
 698                                  RK_FORMAT_RGB_888,
 699                                  RK_FORMAT_YCbCr_420_SP);
 700  
 701          auto t_rga_out1 = std::chrono::steady_clock::now();
 702  
 703          if (rga_status != IM_STATUS_SUCCESS) {
 704              printf("RGA RGB->NV12 failed at frame=%d status=%d %s\n",
 705                     frame_id,
 706                     rga_status,
 707                     imStrError(rga_status));
 708              xioctl(fd, VIDIOC_QBUF, &buf);
 709              break;
 710          }
```


逐段解释：

### 第 677～680 行

把 `rgb_buf` 包装成 OpenCV Mat，然后调用前面的画框函数。

注意：`cv::Mat` 这里不会拷贝图像数据，它只是引用 `rgb_buf.data()` 这块内存。所以画框函数修改的是 `rgb_buf` 本身。

### 第 683～699 行

用 RGA 做 RGB → NV12。

为什么画完框还要转回 NV12？

```text
MPP H.264 编码器更适合吃 NV12。
如果直接给 RGB，编码器可能不支持或者效率很低。
```

### 第 703～710 行

如果 RGB → NV12 失败，打印错误，归还 V4L2 buffer，退出循环。

---

## 3.17 把当前帧送入异步编码队列：第 711～729 行


```cpp
 711          //写入输出文件或者fifo
 712          auto t_write0 = std::chrono::steady_clock::now();
 713          Exp21EncFrame enc_frame;
 714          enc_frame.frame_id = frame_id;
 715          enc_frame.pts_us = (int64_t)frame_id * 1000000LL / (int64_t)mpp_fps;
 716          enc_frame.enqueue_ts_us = exp23_now_us();
 717          enc_frame.nv12.assign(out_nv12_buf.begin(), out_nv12_buf.end());
 718  
 719          {
 720              std::lock_guard<std::mutex> lk(enc_mutex);
 721              if (enc_queue.size() >= max_enc_queue_size) {
 722                  enc_queue.pop();
 723                  async_drop_frames++;
 724              }
 725              enc_queue.push(std::move(enc_frame));
 726          }
 727  
 728          enc_cv.notify_one();
 729          auto t_write1 = std::chrono::steady_clock::now();
```


这是主线程和编码线程的交界处。

逐行解释：

### 第 712 行

记录“队列 push 阶段”开始时间。变量名还是 `t_write0`，历史原因，实际这里不是直接写文件，而是入队。

### 第 713～717 行

构造 `Exp21EncFrame enc_frame`：

```cpp
enc_frame.frame_id = frame_id;
enc_frame.pts_us = (int64_t)frame_id * 1000000LL / (int64_t)mpp_fps;
enc_frame.enqueue_ts_us = exp23_now_us();
enc_frame.nv12.assign(out_nv12_buf.begin(), out_nv12_buf.end());
```

重点是 PTS 计算：

```cpp
frame_id * 1000000 / fps
```

因为单位是微秒，1 秒 = 1,000,000 微秒。

30fps 时：

```text
第0帧：0 us
第1帧：33333 us
第2帧：66666 us
第3帧：100000 us
```

`1000000LL` 后面的 `LL` 表示 long long 常量，避免整数范围不够。

`assign(begin, end)` 把 `out_nv12_buf` 整个复制到 `enc_frame.nv12`。

### 第 719～726 行

加锁后操作队列。

```cpp
std::lock_guard<std::mutex> lk(enc_mutex);
```

`lock_guard` 是 RAII 锁：创建时自动加锁，离开作用域自动解锁。

如果队列长度超过上限 8：

```cpp
enc_queue.pop();
async_drop_frames++;
```

丢掉最旧的一帧，避免延迟越来越大。

然后把当前帧 move 进队列：

```cpp
enc_queue.push(std::move(enc_frame));
```

### 第 728 行

```cpp
enc_cv.notify_one();
```

唤醒编码线程，让它知道队列里有新帧了。

### 第 729 行

记录入队结束时间。

---

## 3.18 归还 V4L2 buffer、统计耗时、写 profile：第 730～792 行


```cpp
 730          //缓冲区重新入队（归还buffer）
 731          auto t_q0 = std::chrono::steady_clock::now();
 732          if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
 733              perror("VIDIOC_QBUF requeue failed");
 734              break;
 735          }
 736          auto t_q1 = std::chrono::steady_clock::now();
 737          //记录总的耗时
 738          auto t_total1 = std::chrono::steady_clock::now();
 739          //各个阶段耗时
 740          double select_ms = diff_ms(t_select0, t_select1);
 741          double dqbuf_ms = diff_ms(t_dq0, t_dq1);
 742          double rga_in_ms = diff_ms(t_rga_in0, t_rga_in1);
 743          double prepare_ms = diff_ms(t_prepare0, t_prepare1);
 744          double model_ms = diff_ms(t_model0, t_model1);
 745          double draw_ms = diff_ms(t_draw0, t_draw1);
 746          double rga_out_ms = diff_ms(t_rga_out0, t_rga_out1);
 747          double write_ms = diff_ms(t_write0, t_write1);
 748          double qbuf_ms = diff_ms(t_q0, t_q1);
 749          double total_ms = diff_ms(t_total0, t_total1);
 750          double fps = total_ms > 0.0 ? 1000.0 / total_ms : 0.0;
 751  
 752          sum_select_ms += select_ms;
 753          sum_dqbuf_ms += dqbuf_ms;
 754          sum_rga_nv12_to_rgb_ms += rga_in_ms;
 755          sum_input_prepare_ms += prepare_ms;
 756          sum_model_total_ms += model_ms;
 757          sum_draw_ms += draw_ms;
 758          sum_rga_rgb_to_nv12_ms += rga_out_ms;
 759          sum_write_ms += write_ms;
 760          sum_qbuf_ms += qbuf_ms;
 761          sum_total_ms += total_ms;
 762  
 763          actual_frames++;
 764  
 765          profile_csv << frame_id << ","
 766                      << select_ms << ","
 767                      << dqbuf_ms << ","
 768                      << rga_in_ms << ","
 769                      << prepare_ms << ","
 770                      << model_ms << ","
 771                      << draw_ms << ","
 772                      << rga_out_ms << ","
 773                      << write_ms << ","
 774                      << qbuf_ms << ","
 775                      << total_ms << ","
 776                      << fps << ","
 777                      << od_results.count
 778                      << std::endl;
 779  
 780          if (frame_id % 30 == 0) {
 781              printf("frame=%d total=%.3f fps=%.3f rga_in=%.3f model=%.3f draw=%.3f rga_out=%.3f queue_push=%.3f det=%d\n",
 782                     frame_id,
 783                     total_ms,
 784                     fps,
 785                     rga_in_ms,
 786                     model_ms,
 787                     draw_ms,
 788                     rga_out_ms,
 789                     write_ms,
 790                     od_results.count);
 791          }
 792      }
```


逐段解释：

### 第 731～736 行

调用 `VIDIOC_QBUF` 把当前 buffer 归还给摄像头驱动。

这是必须的。如果不归还，驱动可用 buffer 会越来越少，最后采集停住。

### 第 738～750 行

计算每个阶段耗时：

| 变量 | 含义 |
|---|---|
| `select_ms` | 等待摄像头帧到来的时间 |
| `dqbuf_ms` | 从 V4L2 取出 buffer 的时间 |
| `rga_in_ms` | NV12 → RGB 时间 |
| `prepare_ms` | 准备模型输入结构体时间 |
| `model_ms` | YOLO 推理时间 |
| `draw_ms` | 画框时间 |
| `rga_out_ms` | RGB → NV12 时间 |
| `write_ms` | 入编码队列耗时 |
| `qbuf_ms` | 归还 V4L2 buffer 时间 |
| `total_ms` | 当前帧主线程总耗时 |
| `fps` | 当前帧折算 fps |

### 第 752～761 行

把每个阶段耗时累加。

### 第 763 行

成功处理帧数加一。

### 第 765～778 行

把当前帧性能数据写入 profile CSV。

### 第 780～791 行

每 30 帧打印一次主线程性能日志。

---

## 3.19 退出、停止流、等待编码线程结束：第 793～827 行


```cpp
 793      //记录墙钟结束时间
 794      auto wall_end = std::chrono::steady_clock::now();
 795      double wall_ms = diff_ms(wall_start, wall_end);
 796      //停止视频流
 797      xioctl(fd, VIDIOC_STREAMOFF, &type);
 798      //释放模型后处理资源
 799      release_yolo11_model(&rknn_app_ctx);
 800      deinit_post_process();
 801      //关闭文件
 802      profile_csv.close();
 803  
 804      {
 805          std::lock_guard<std::mutex> lk(enc_mutex);
 806          enc_stop = true;
 807      }
 808      enc_cv.notify_all();
 809  
 810      if (encoder_thread.joinable()) {
 811          encoder_thread.join();
 812      }
 813  
 814      int async_count = async_encoded_frames.load();
 815      double async_avg_encode_ms = async_count > 0 ? (double)async_encode_us.load() / 1000.0 / async_count : 0.0;
 816      double async_avg_write_ms = async_count > 0 ? (double)async_write_us.load() / 1000.0 / async_count : 0.0;
 817      double async_avg_total_ms = async_count > 0 ? (double)async_total_us.load() / 1000.0 / async_count : 0.0;
 818  
 819      printf("async_encoded_frames : %d\n", async_count);
 820      printf("async_encode_failures: %d\n", async_encode_failures.load());
 821      printf("async_drop_frames    : %d\n", async_drop_frames.load());
 822      printf("async_avg_encode_ms  : %.3f\n", async_avg_encode_ms);
 823      printf("enc pts csv saved   : %s\n", enc_pts_csv_path.c_str());
 824      printf("async_avg_write_ms   : %.3f\n", async_avg_write_ms);
 825      printf("async_avg_total_ms   : %.3f\n", async_avg_total_ms);
 826  
 827      fclose(fout);
```


逐段解释：

### 第 794～795 行

记录主循环结束时间，并计算总 wall time。

### 第 797 行

停止 V4L2 视频流：

```cpp
VIDIOC_STREAMOFF
```

### 第 799～800 行

释放 YOLO 模型和后处理资源。

### 第 802 行

关闭 profile CSV。

### 第 804～808 行

设置 `enc_stop = true`，并通知编码线程。

这里必须加锁修改 `enc_stop`，因为它和队列状态一起控制线程退出。

### 第 810～812 行

```cpp
encoder_thread.join();
```

等待编码线程结束。

为什么必须 join？

```text
主线程不能直接退出。否则 fout、mpp_encoder 等资源可能被销毁，编码线程还在用，可能崩溃。
```

### 第 814～825 行

读取异步编码统计结果，并打印平均编码耗时、写文件耗时、总耗时。

### 第 827 行

关闭 H.264 输出文件。

注意：这里在 `join` 之后关闭 `fout` 是对的，因为编码线程已经不再写这个文件。

---

## 3.20 解除 mmap、关闭设备、打印最终结果：第 828～860 行


```cpp
 828      //解除内存映射，关闭设备
 829      for (auto& b : buffers) {
 830          if (b.start && b.start != MAP_FAILED) {
 831              munmap(b.start, b.length);
 832          }
 833      }
 834  
 835      close(fd);
 836  
 837      if (actual_frames <= 0) {
 838          actual_frames = 1;
 839      }
 840  
 841      printf("\n========== exp21-4 async detect mpp encode result ==========\n");
 842      printf("frames              : %d\n", actual_frames);
 843      printf("wall_time_ms        : %.3f\n", wall_ms);
 844      printf("wall_fps            : %.3f\n", actual_frames * 1000.0 / wall_ms);
 845      printf("avg_select_ms       : %.3f\n", sum_select_ms / actual_frames);
 846      printf("avg_dqbuf_ms        : %.3f\n", sum_dqbuf_ms / actual_frames);
 847      printf("avg_rga_nv12_to_rgb : %.3f\n", sum_rga_nv12_to_rgb_ms / actual_frames);
 848      printf("avg_input_prepare   : %.3f\n", sum_input_prepare_ms / actual_frames);
 849      printf("avg_model_total_ms  : %.3f\n", sum_model_total_ms / actual_frames);
 850      printf("avg_draw_ms         : %.3f\n", sum_draw_ms / actual_frames);
 851      printf("avg_rga_rgb_to_nv12 : %.3f\n", sum_rga_rgb_to_nv12_ms / actual_frames);
 852      printf("avg_mpp_queue_push : %.3f\n", sum_write_ms / actual_frames);
 853      printf("avg_qbuf_ms         : %.3f\n", sum_qbuf_ms / actual_frames);
 854      printf("avg_total_ms        : %.3f\n", sum_total_ms / actual_frames);
 855      printf("profile csv         : %s\n", profile_csv_path);
 856      printf("output h264         : %s\n", out_path);
 857          printf("================================================\n");
 858  
 859      return 0;
 860  }
```


逐段解释：

### 第 829～833 行

遍历所有 mmap buffer，调用 `munmap` 解除映射。

### 第 835 行

关闭摄像头设备 fd。

### 第 837～839 行

如果没有成功处理任何帧，把 `actual_frames` 设置成 1，避免后面除以 0。

### 第 841～857 行

打印最终性能统计。

包括：

```text
总帧数
总 wall time
wall fps
各阶段平均耗时
profile csv 路径
output h264 路径
```

### 第 859 行

```cpp
return 0;
```

程序正常结束。

---

# 4. 两个文件放在一起的完整运行逻辑

用一段伪代码总结：

```cpp
main() {
    解析命令行参数;
    打开摄像头;
    设置摄像头为 NV12;
    申请并 mmap V4L2 buffers;
    初始化 MPP H264 encoder;
    写入 H264 header;
    创建编码线程;
    初始化 YOLO 模型;
    启动摄像头采集;

    for 每一帧 {
        select 等待摄像头;
        DQBUF 取出 NV12;
        RGA: NV12 -> RGB;
        YOLO 推理;
        OpenCV 画框;
        RGA: RGB -> NV12;
        构造 Exp21EncFrame;
        push 到编码队列;
        QBUF 归还摄像头 buffer;
        记录 profile;
    }

    停止摄像头;
    通知编码线程退出;
    join 编码线程;
    释放所有资源;
}
```

编码线程伪代码：

```cpp
encoder_thread() {
    while true {
        等待队列非空或者停止信号;
        如果停止且队列空，退出;
        从队列取一帧;
        设置 PTS;
        调用 MppH264Encoder::encode;
        写 H264 packet;
        写 PTS CSV;
        更新异步统计;
    }
}
```

MPP 编码器伪代码：

```cpp
encode(nv12) {
    申请 MppBuffer;
    拷贝 NV12 到 MppBuffer;
    创建 MppFrame;
    设置宽高、stride、格式、buffer、PTS;
    encode_put_frame;
    encode_get_packet;
    读取 packet PTS/DTS/flags;
    拷贝 packet 数据到 vector;
    释放 frame、buffer、packet;
}
```

---

# 5. 这份代码中最容易混淆的点

## 5.1 为什么需要两次 RGA？

```text
摄像头输出：NV12
YOLO / OpenCV 更适合：RGB
MPP 编码器更适合：NV12
```

所以必须：

```text
NV12 → RGB → NV12
```

## 5.2 为什么不直接在主线程编码？

因为主线程已经做了：

```text
等待摄像头
RGA 转换
YOLO 推理
画框
RGA 转换
```

如果再同步 MPP 编码，主线程耗时会增加，采集可能更容易掉帧。

异步编码的好处：

```text
主线程负责实时采集和推理；
编码线程负责慢慢压缩和写文件；
两者通过队列解耦。
```

## 5.3 为什么队列满了丢旧帧？

实时视频更怕“延迟越来越大”，不是只怕“丢帧”。

如果编码慢，队列一直堆积，最后看到的是几秒前的画面。

所以这里选择：

```text
队列满了，丢掉最旧帧，尽量保实时性。
```

## 5.4 为什么要复制 NV12 数据进 vector？

因为 V4L2 buffer 后面要马上 QBUF 归还给驱动。

如果编码线程还引用原始 buffer，驱动可能已经把下一帧写进去了。

所以必须复制一份独立数据：

```cpp
enc_frame.nv12.assign(out_nv12_buf.begin(), out_nv12_buf.end());
```

## 5.5 为什么 PTS 用 frame_id 算？

当前实验希望稳定验证 30fps 时间戳，所以用：

```cpp
frame_id * 1000000 / 30
```

这样每帧间隔约 33333 微秒。

这比直接用系统时间更稳定，适合固定帧率编码和后续 MP4 mux。

---

# 6. 建议你按这个顺序复习

第一遍只看主线：

```text
main 参数解析
V4L2 初始化
RGA NV12->RGB
YOLO 推理
画框
RGA RGB->NV12
入队
编码线程
MPP encode
释放资源
```

第二遍重点看多线程：

```text
enc_queue
enc_mutex
enc_cv
enc_stop
encoder_thread
join
```

第三遍重点看 MPP：

```text
mpp_create
mpp_init
mpp_enc_cfg_set_s32
mpp_buffer_get
mpp_frame_init
encode_put_frame
encode_get_packet
mpp_packet_get_pts
```

第四遍重点看性能统计：

```text
select_ms
dqbuf_ms
rga_in_ms
model_ms
draw_ms
rga_out_ms
write_ms
qbuf_ms
total_ms
```

---

# 7. 面试或汇报时可以这样描述

这段代码实现了 RK3588 上的实时 AI 视频处理与硬件编码链路。主线程通过 V4L2 mmap 从摄像头采集 NV12 图像，使用 RGA 将 NV12 转为 RGB，送入 RKNN YOLO11 模型推理，并用 OpenCV 绘制检测框。绘制完成后，再通过 RGA 将 RGB 转回 NV12。为了避免 MPP 编码阻塞主采集推理链路，代码使用 `std::queue + mutex + condition_variable + thread` 构建异步编码线程。主线程将带有 `frame_id`、`pts_us`、`enqueue_ts_us` 和 NV12 数据的 `Exp21EncFrame` 推入队列，编码线程取帧后调用自研 `MppH264Encoder`，通过 `mpp_frame_set_pts` 写入 PTS，并从 `MppPacket` 读回 PTS/DTS/flags，最后写入 H.264 裸流和 PTS CSV，从而为后续 MP4 封装、历史回放和音视频同步打基础。

---

# 8. 你下一步应该重点补的基础知识

如果你要真正完全吃透这份代码，建议按优先级学习：

1. C++ 指针、引用、vector、RAII。
2. Linux 文件描述符、open/close/ioctl/select。
3. V4L2 mmap 采集流程：REQBUFS、QUERYBUF、mmap、QBUF、STREAMON、DQBUF、QBUF、STREAMOFF。
4. 图像格式：RGB、YUV、NV12、stride。
5. 多线程：mutex、lock_guard、unique_lock、condition_variable、atomic、join。
6. MPP 编码流程：MppBuffer、MppFrame、MppPacket、PTS。
7. H.264 基础：SPS/PPS、IDR、P/B帧、GOP、码率控制。


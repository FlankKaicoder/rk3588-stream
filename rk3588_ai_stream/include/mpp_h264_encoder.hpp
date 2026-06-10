#pragma once
//包含了c++标准库的定宽整数、尺寸类型、动态数组等用于后续处理
#include <cstdint>
#include <cstddef>
#include <vector>
//瑞芯微mpp库是c语言，所以让c++编译器以c语言规则链接头文件函数
extern "C" {
#include "rk_mpi.h"   //mpp核心接口
#include "mpp_buffer.h"  //mpp内存分配和缓冲区管理
#include "mpp_frame.h"   //定义了未压缩的图像帧结构
#include "mpp_packet.h"  // 定义压缩后的数据包结构
#include "mpp_enc_cfg.h" // 编码器高级配置接口
}

class MppH264Encoder
{
public:
    MppH264Encoder();
    ~MppH264Encoder();

    bool init(int width, int height, int fps, int bitrate); //初始化函数，传入视频的宽高帧率码率等信息
    bool get_header(std::vector<uint8_t> &out_packet);  // H.264编码中必须首先获取sps\pps（序列参数集\图像参数集）（视频目录信息），out_packet用于传出数据
    bool encode(const uint8_t *nv12_data,
                size_t nv12_size,
                std::vector<uint8_t> &out_packet);// 核心编码函数
    void release();  //手动释放编码器资源
    //内联的getter函数，用于安全的获取内部状态
    int width() const { return width_; }
    int height() const { return height_; }
    int hor_stride() const { return hor_stride_; }
    int ver_stride() const { return ver_stride_; }
    size_t raw_nv12_size() const { return static_cast<size_t>(width_) * height_ * 3 / 2; }
    size_t mpp_frame_size() const { return frame_size_; }

private:
    static int align_up(int value, int align); // 工具函数，用于将给定的数值向上对齐（硬件一般要对其16字节或者64字节） （向上对齐：1080对齐到16倍数就是1088）

    bool copy_nv12_to_mpp_buffer(const uint8_t *src,
                                 size_t src_size,
                                 uint8_t *dst,
                                 size_t dst_size);  //输入图像没有经过硬件对齐、必须有一个中间步骤将紧凑的源数据(src)按照硬件的跨度（stride）要求，进行逐行拷贝到对齐的mpp缓冲池中（dst）

private:
    MppCtx ctx_;      //mpp框架上下文句柄
    MppApi *mpi_;
    MppEncCfg cfg_;  //配置结构体

    int width_;
    int height_;
    int fps_;
    int bitrate_;

    int hor_stride_;
    int ver_stride_;
    size_t frame_size_;

    bool inited_;
};
//外部程度只需要init()->get_header()->循环调用encode()即可完成H.264编码
#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>

extern "C" {
#include "rk_mpi.h"
#include "mpp_buffer.h"
#include "mpp_frame.h"
#include "mpp_packet.h"
#include "mpp_enc_cfg.h"
}

class MppH264Encoder
{
public:
    MppH264Encoder();
    ~MppH264Encoder();

    bool init(int width, int height, int fps, int bitrate);
    bool get_header(std::vector<uint8_t> &out_packet);
    bool encode(const uint8_t *nv12_data,
                size_t nv12_size,
                std::vector<uint8_t> &out_packet);
    void release();

    int width() const { return width_; }
    int height() const { return height_; }
    int hor_stride() const { return hor_stride_; }
    int ver_stride() const { return ver_stride_; }
    size_t raw_nv12_size() const { return static_cast<size_t>(width_) * height_ * 3 / 2; }
    size_t mpp_frame_size() const { return frame_size_; }

private:
    static int align_up(int value, int align);

    bool copy_nv12_to_mpp_buffer(const uint8_t *src,
                                 size_t src_size,
                                 uint8_t *dst,
                                 size_t dst_size);

private:
    MppCtx ctx_;
    MppApi *mpi_;
    MppEncCfg cfg_;

    int width_;
    int height_;
    int fps_;
    int bitrate_;

    int hor_stride_;
    int ver_stride_;
    size_t frame_size_;

    bool inited_;
};

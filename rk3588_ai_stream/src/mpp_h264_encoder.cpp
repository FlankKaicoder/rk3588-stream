#include "mpp_h264_encoder.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <unistd.h>

MppH264Encoder::MppH264Encoder()   //初始化，所有指针置空然后清零防止野指针
    : ctx_(nullptr), //省略部分初始化代码
      mpi_(nullptr),
      cfg_(nullptr),
      width_(0),
      height_(0),
      fps_(0),
      bitrate_(0),
      hor_stride_(0),
      ver_stride_(0),
      frame_size_(0),
      inited_(false)
{
}

MppH264Encoder::~MppH264Encoder()
{
    release();
}

int MppH264Encoder::align_up(int value, int align)  //向上对齐
{
    return (value + align - 1) / align * align;
}

bool MppH264Encoder::init(int width, int height, int fps, int bitrate)
{
    if (inited_)
    {
        return true;
    }

    width_ = width;
    height_ = height;
    fps_ = fps;
    bitrate_ = bitrate;

    /*
     * RK3588 MPP H.264 编码通常要求 stride 按 16 对齐。
     * 1280x720 本身刚好都是 16 对齐：
     * 1280 / 16 = 80
     * 720  / 16 = 45
     */
    hor_stride_ = align_up(width_, 16);
    ver_stride_ = align_up(height_, 16);
    frame_size_ = static_cast<size_t>(hor_stride_) * ver_stride_ * 3 / 2;

    printf("========== MppH264Encoder init ==========\n");
    printf("width       : %d\n", width_);
    printf("height      : %d\n", height_);
    printf("fps         : %d\n", fps_);
    printf("bitrate     : %d\n", bitrate_);
    printf("hor_stride  : %d\n", hor_stride_);
    printf("ver_stride  : %d\n", ver_stride_);
    printf("frame_size  : %zu\n", frame_size_);
    printf("=========================================\n");

    MPP_RET ret = MPP_OK;

    ret = mpp_create(&ctx_, &mpi_);  //向mpp框架申请实例拿到上下文ctx_和接口指针mpi_
    if (ret != MPP_OK || ctx_ == nullptr || mpi_ == nullptr)
    {
        printf("mpp_create failed, ret=%d\n", ret);
        return false;
    }

    ret = mpp_init(ctx_, MPP_CTX_ENC, MPP_VIDEO_CodingAVC);
    if (ret != MPP_OK)
    {
        printf("mpp_init failed, ret=%d\n", ret);
        release();
        return false;
    }

    ret = mpp_enc_cfg_init(&cfg_);    //分配一个配置句柄然后getcfg获取默认的配置模板，方便之后修改
    if (ret != MPP_OK || cfg_ == nullptr)
    {
        printf("mpp_enc_cfg_init failed, ret=%d\n", ret);
        release();
        return false;
    }

    ret = mpi_->control(ctx_, MPP_ENC_GET_CFG, cfg_);
    if (ret != MPP_OK)
    {
        printf("MPP_ENC_GET_CFG failed, ret=%d\n", ret);
        release();
        return false;
    }

    /*
     * prep：输入图像参数。《prep预处理阶段》
     * 当前实验输入为 1280x720 NV12。
     */
    mpp_enc_cfg_set_s32(cfg_, "prep:width", width_);
    mpp_enc_cfg_set_s32(cfg_, "prep:height", height_);
    mpp_enc_cfg_set_s32(cfg_, "prep:hor_stride", hor_stride_);
    mpp_enc_cfg_set_s32(cfg_, "prep:ver_stride", ver_stride_);
    mpp_enc_cfg_set_s32(cfg_, "prep:format", MPP_FMT_YUV420SP);

    /*
     * rc：码率控制。《rc码率控制》
     * 这里先使用 CBR，方便后续和 mpi_enc_test 对比。
     */
    mpp_enc_cfg_set_s32(cfg_, "rc:mode", MPP_ENC_RC_MODE_CBR);

    mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_flex", 0);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_num", fps_);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_denorm", 1);

    mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_flex", 0);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_num", fps_);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_denorm", 1);

    mpp_enc_cfg_set_s32(cfg_, "rc:gop", fps_ * 2);

    mpp_enc_cfg_set_s32(cfg_, "rc:bps_target", bitrate_);
    mpp_enc_cfg_set_s32(cfg_, "rc:bps_max", bitrate_ * 17 / 16);
    mpp_enc_cfg_set_s32(cfg_, "rc:bps_min", bitrate_ * 15 / 16);

    /*
     * codec：H.264 / AVC。《编码器特性》
     */
    mpp_enc_cfg_set_s32(cfg_, "codec:type", MPP_VIDEO_CodingAVC);

    /*
     * H.264 profile：
     * 66  = baseline
     * 77  = main
     * 100 = high
     */
    mpp_enc_cfg_set_s32(cfg_, "h264:profile", 100);  //设置为100代表最高压缩率和画质的压缩
    mpp_enc_cfg_set_s32(cfg_, "h264:level", 40);     //规定最大分辨率和码率支持上限
    mpp_enc_cfg_set_s32(cfg_, "h264:cabac_en", 1);
    mpp_enc_cfg_set_s32(cfg_, "h264:cabac_idc", 0);
    mpp_enc_cfg_set_s32(cfg_, "h264:trans8x8", 1);

    ret = mpi_->control(ctx_, MPP_ENC_SET_CFG, cfg_);   //将修改好的配置写回硬件
    if (ret != MPP_OK)
    {
        printf("MPP_ENC_SET_CFG failed, ret=%d\n", ret);
        release();
        return false;
    }

    inited_ = true;  //标记初始化完成
    return true;
}

bool MppH264Encoder::get_header(std::vector<uint8_t> &out_packet)
{
    out_packet.clear();

    if (!inited_ || ctx_ == nullptr || mpi_ == nullptr)
    {
        printf("get_header failed: encoder not initialized\n");
        return false;
    }

    MppPacket packet = nullptr; //一开始不能接受，必须先接受sps\pps
    MPP_RET ret = mpi_->control(ctx_, MPP_ENC_GET_EXTRA_INFO, &packet);//通过MPP_ENC_GET_EXTRA_INFO函数向硬件索要这段头部数据，然后提取内存指针和长度，塞进packet中返回给调用，最后清理

    if (ret != MPP_OK)
    {
        printf("MPP_ENC_GET_EXTRA_INFO failed, ret=%d\n", ret);
        return false;
    }

    if (packet != nullptr)
    {
        void *ptr = mpp_packet_get_pos(packet);
        size_t len = mpp_packet_get_length(packet);

        if (ptr != nullptr && len > 0)
        {
            const uint8_t *p = static_cast<const uint8_t *>(ptr);
            out_packet.assign(p, p + len);
            printf("got h264 header: %zu bytes\n", len);
        }

        mpp_packet_deinit(&packet);
    }

    return true;
}

bool MppH264Encoder::copy_nv12_to_mpp_buffer(const uint8_t *src,
                                             size_t src_size,
                                             uint8_t *dst,
                                             size_t dst_size)
{
    if (src == nullptr || dst == nullptr)
    {
        return false;
    }

    const size_t compact_size = static_cast<size_t>(width_) * height_ * 3 / 2;
    if (src_size < compact_size || dst_size < frame_size_)
    {
        printf("copy_nv12_to_mpp_buffer size mismatch: src_size=%zu compact=%zu dst_size=%zu frame_size=%zu\n",
               src_size, compact_size, dst_size, frame_size_);
        return false;
    }

    memset(dst, 0, dst_size);

    /*
     * 如果宽高和 stride 完全一致，直接拷贝即可。
     * 1280x720 就是这种情况。
     */
    if (hor_stride_ == width_ && ver_stride_ == height_)
    {
        memcpy(dst, src, compact_size);
        return true;
    }

    /*
     * 通用 stride 拷贝：
     * Y 平面：height 行，每行 width 字节；
     * UV 平面：height/2 行，每行 width 字节。
     */
    const uint8_t *src_y = src;
    const uint8_t *src_uv = src + static_cast<size_t>(width_) * height_;

    uint8_t *dst_y = dst;
    uint8_t *dst_uv = dst + static_cast<size_t>(hor_stride_) * ver_stride_;

    for (int y = 0; y < height_; ++y)
    {
        memcpy(dst_y + static_cast<size_t>(y) * hor_stride_,
               src_y + static_cast<size_t>(y) * width_,
               width_);
    }

    for (int y = 0; y < height_ / 2; ++y)
    {
        memcpy(dst_uv + static_cast<size_t>(y) * hor_stride_,
               src_uv + static_cast<size_t>(y) * width_,
               width_);
    }

    return true;
}

bool MppH264Encoder::encode(const uint8_t *nv12_data,
                            size_t nv12_size,
                            std::vector<uint8_t> &out_packet) // 核心编码流水线
{
    out_packet.clear();

    if (!inited_ || ctx_ == nullptr || mpi_ == nullptr)
    {
        printf("encode failed: encoder not initialized\n");
        return false;
    }

    MPP_RET ret = MPP_OK;

    MppBuffer frame_buf = nullptr;  
    ret = mpp_buffer_get(nullptr, &frame_buf, frame_size_);  //申请内存
    if (ret != MPP_OK || frame_buf == nullptr)
    {
        printf("mpp_buffer_get failed, ret=%d\n", ret);
        return false;
    }

    void *buf_ptr = mpp_buffer_get_ptr(frame_buf);
    if (buf_ptr == nullptr)
    {
        printf("mpp_buffer_get_ptr failed\n");
        mpp_buffer_put(frame_buf);
        return false;
    }

    bool copy_ok = copy_nv12_to_mpp_buffer(nv12_data,
                                           nv12_size,
                                           static_cast<uint8_t *>(buf_ptr),
                                           frame_size_);   // 搬运数据，
    if (!copy_ok)
    {
        mpp_buffer_put(frame_buf);
        return false;
    }
    // 开始打包成frame结构，然后做成MppFrame结构，打标签（数据宽高以及对齐的跨距和格式等等）
    MppFrame frame = nullptr;
    ret = mpp_frame_init(&frame);
    if (ret != MPP_OK || frame == nullptr)
    {
        printf("mpp_frame_init failed, ret=%d\n", ret);
        mpp_buffer_put(frame_buf);
        return false;
    }

    mpp_frame_set_width(frame, width_);
    mpp_frame_set_height(frame, height_);
    mpp_frame_set_hor_stride(frame, hor_stride_);
    mpp_frame_set_ver_stride(frame, ver_stride_);
    mpp_frame_set_fmt(frame, MPP_FMT_YUV420SP);
    mpp_frame_set_buffer(frame, frame_buf);
    mpp_frame_set_eos(frame, 0);

    ret = mpi_->encode_put_frame(ctx_, frame);
    if (ret != MPP_OK)
    {
        printf("encode_put_frame failed, ret=%d\n", ret);
        mpp_frame_deinit(&frame);
        mpp_buffer_put(frame_buf);
        return false;
    }

    MppPacket packet = nullptr;
    bool got_packet = false;

    /*
     * H.264 一般每输入一帧可以取到一个 packet。
     * 这里加短暂轮询，避免偶发的异步返回。
     */
    for (int retry = 0; retry < 100; ++retry) //硬件计算耗时，代码中进行循环的轮询 
    {
        ret = mpi_->encode_get_packet(ctx_, &packet); //不断调用此函数直到拿到非空的packet然后追加到out_packet当中，跳出循环
        if (ret != MPP_OK)
        {
            printf("encode_get_packet failed, ret=%d retry=%d\n", ret, retry);
            usleep(1000);
            continue;
        }

        if (packet != nullptr)
        {
            void *ptr = mpp_packet_get_pos(packet);
            size_t len = mpp_packet_get_length(packet);

            if (ptr != nullptr && len > 0)
            {
                const uint8_t *p = static_cast<const uint8_t *>(ptr);
                out_packet.assign(p, p + len);
                got_packet = true;
            }

            mpp_packet_deinit(&packet);
            break;
        }

        usleep(1000);
    }

    mpp_frame_deinit(&frame);
    mpp_buffer_put(frame_buf);

    if (!got_packet)
    {
        printf("warning: encode finished but no packet got\n");
    }

    return got_packet;
}

void MppH264Encoder::release()
{
    if (cfg_ != nullptr)
    {
        mpp_enc_cfg_deinit(cfg_);
        cfg_ = nullptr;
    }

    if (ctx_ != nullptr)
    {
        mpp_destroy(ctx_);
        ctx_ = nullptr;
        mpi_ = nullptr;
    }

    inited_ = false;
}

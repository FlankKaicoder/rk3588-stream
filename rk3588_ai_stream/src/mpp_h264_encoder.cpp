#include "mpp_h264_encoder.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <unistd.h>

MppH264Encoder::MppH264Encoder()   //初始化，所有指针置空然后清零防止野指针
    : ctx_(nullptr), //mpp上下文指针置空不指向有效对象  //省略部分初始化代码
      mpi_(nullptr), //MPP接口指针初始化为空
      cfg_(nullptr), //MPP编码配置句柄
      width_(0),
      height_(0),
      fps_(0),
      bitrate_(0),
      hor_stride_(0),
      ver_stride_(0),
      frame_size_(0),
      inited_(false)
{
} // 构造为空，初始化在初始化列表中完成

MppH264Encoder::~MppH264Encoder()
{
    release();
}

int MppH264Encoder::align_up(int value, int align)  //向上对齐（硬件编码器按照stride访问，所以按照16字节对齐然后硬件可以更加高效的读取）
{
    return (value + align - 1) / align * align;
}
//初始化编码器（防止重复初始化、保存宽高等等、计算步长帧大小、创建MPP实例、初始化264编码器、获取修改配置、写回配置初始化成功）
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
    hor_stride_ = align_up(width_, 16);  //一行实际占用的字节大小
    ver_stride_ = align_up(height_, 16); //一列
    frame_size_ = static_cast<size_t>(hor_stride_) * ver_stride_ * 3 / 2;  //编码器buffer需要的大小

    printf("========== MppH264Encoder init ==========\n");
    printf("width       : %d\n", width_);
    printf("height      : %d\n", height_);
    printf("fps         : %d\n", fps_);
    printf("bitrate     : %d\n", bitrate_);
    printf("hor_stride  : %d\n", hor_stride_);
    printf("ver_stride  : %d\n", ver_stride_);
    printf("frame_size  : %zu\n", frame_size_);
    printf("=========================================\n");

    MPP_RET ret = MPP_OK; //MPP_RET是MPP API返回类型  初始化成功

    ret = mpp_create(&ctx_, &mpi_);  //向mpp框架申请实例拿到上下文ctx_和接口指针mpi_
    if (ret != MPP_OK || ctx_ == nullptr || mpi_ == nullptr)
    {
        printf("mpp_create failed, ret=%d\n", ret);
        return false;
    }

    ret = mpp_init(ctx_, MPP_CTX_ENC, MPP_VIDEO_CodingAVC);  //编码模式确定为AVC也就是H.264
    if (ret != MPP_OK)
    {
        printf("mpp_init failed, ret=%d\n", ret);
        release();
        return false;
    }

    ret = mpp_enc_cfg_init(&cfg_);    // 先创建配置对象cfg //分配一个配置句柄然后getcfg获取默认的配置模板，方便之后修改（直接拿默认的配置模板然后修改即可）
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
    //rate control 进行码率控制
    /*
     * rc：码率控制。《rc码率控制》
     * 这里先使用 CBR，方便后续和 mpi_enc_test 对比。
     */
    mpp_enc_cfg_set_s32(cfg_, "rc:mode", MPP_ENC_RC_MODE_CBR); //恒定码率

    mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_flex", 0);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_num", fps_);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_in_denorm", 1);

    mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_flex", 0);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_num", fps_);
    mpp_enc_cfg_set_s32(cfg_, "rc:fps_out_denorm", 1);

    mpp_enc_cfg_set_s32(cfg_, "rc:gop", fps_ * 2); //gop表示关键帧间隔：每两秒一个关键帧

    mpp_enc_cfg_set_s32(cfg_, "rc:bps_target", bitrate_);
    mpp_enc_cfg_set_s32(cfg_, "rc:bps_max", bitrate_ * 17 / 16);//允许码率轻微浮动
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
    mpp_enc_cfg_set_s32(cfg_, "h264:cabac_en", 1);   //提升压缩效率工具
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
// H.264裸流需要先写入sps\pps然后才能编解码 （编码格式、profile、level、分辨率参数等）
bool MppH264Encoder::get_header(std::vector<uint8_t> &out_packet)
{
    out_packet.clear();  //先清空避免数据残留

    if (!inited_ || ctx_ == nullptr || mpi_ == nullptr) // 初始化成功再拿到header
    {
        printf("get_header failed: encoder not initialized\n");
        return false;
    }

    /*
     * exp23-3:
     * Use MPP_ENC_GET_HDR_SYNC instead of unsafe MPP_ENC_GET_EXTRA_INFO.
     *
     * Rockchip official usage:
     *   mpp_packet_init_with_buffer(&packet, p->pkt_buf);
     *   mpp_packet_set_length(packet, 0);
     *   mpi->control(ctx, MPP_ENC_GET_HDR_SYNC, packet);
     *
     * For this project, we use a normal external memory buffer and wrap it
     * as MppPacket. The important point is that packet must have valid
     * external storage, and packet length must be cleared before control().
     */
    constexpr size_t kHeaderBufSize = 4096; //在栈区准备4096字节的buffer用来接受MPP写出的header
    uint8_t header_buf[kHeaderBufSize];

    MppPacket packet = nullptr;
    MPP_RET ret = mpp_packet_init(&packet, header_buf, kHeaderBufSize); //将申请的buffer变成MPP认识的Mpppacket
    if (ret != MPP_OK || packet == nullptr)
    {
        printf("mpp_packet_init for header failed, ret=%d\n", ret);
        return false;
    }

    /*
     * Important:
     * Official mpi_enc_test.c explicitly clears output packet length before
     * MPP_ENC_GET_HDR_SYNC.
     */
    mpp_packet_set_length(packet, 0);  //告诉MPP外部自定义的有效长度为0，后续可以从头写header

    ret = mpi_->control(ctx_, MPP_ENC_GET_HDR_SYNC, packet); //向MPP请求同步生成h264header
    if (ret != MPP_OK)
    {
        printf("MPP_ENC_GET_HDR_SYNC failed, ret=%d\n", ret);
        mpp_packet_deinit(&packet);
        return false;
    }
    //从packet中拿数据起始位置和数据长度
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

    mpp_packet_deinit(&packet);  //释放MppPacket
    return !out_packet.empty();
}
//将外部的nv12数据拷贝到MPP要求的输入buffer中（不能直接进行memcpy因为MPP输入buffer可能按照stride对齐，每一行之后可能会有padding填充字节，必须逐行拷贝）
bool MppH264Encoder::copy_nv12_to_mpp_buffer(const uint8_t *src,  //源nv12数据地址
                                             size_t src_size,     // 源数据大小
                                             uint8_t *dst,       //目标buffer地址以及大小
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

    memset(dst, 0, dst_size);  // 目标buffer清0，避免留下脏数据

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

 
void MppH264Encoder::set_next_pts_us(int64_t pts_us) // 下一帧要写入的pts
{
    next_pts_us_ = pts_us;
}
 // 函数最后的const表示函数不会修改对象的内部状态
int64_t MppH264Encoder::last_packet_pts_us() const   // 返回上次编码得到的packet pts
{
    return last_packet_pts_us_;
}

int64_t MppH264Encoder::last_packet_dts_us() const  // 返回上次编码得到的packet dts
{
    return last_packet_dts_us_;
}

uint32_t MppH264Encoder::last_packet_flags() const  // 返回上次packet de  flags
{
    return last_packet_flags_;
}

bool MppH264Encoder::last_packet_is_intra() const  // 根据flags判断是不是intra/IDR帧
{
#ifdef MPP_PACKET_FLAG_INTRA
    return (last_packet_flags_ & MPP_PACKET_FLAG_INTRA) != 0;
#else
    return (last_packet_flags_ & 0x00000008) != 0;
#endif
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
    ret = mpp_buffer_get(nullptr, &frame_buf, frame_size_);  //申请MPP输入的buffer(给硬件编码器读取的输入图像内存)
    if (ret != MPP_OK || frame_buf == nullptr)
    {
        printf("mpp_buffer_get failed, ret=%d\n", ret);
        return false;
    }
    //拿到buffer之后就访问这个地址
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
                                           frame_size_);   // 搬运数据，外部nv12搬送到mppbuffer中
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
    if (next_pts_us_ >= 0) {
        mpp_frame_set_pts(frame, next_pts_us_); //当前帧的PTS写进MPP，后续可以从编码输出packet中读回来
    }
    mpp_frame_set_eos(frame, 0);  //eos表示end of stream，这里还不是最后一帧

    ret = mpi_->encode_put_frame(ctx_, frame);// 送一帧进入编码器 
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

        if (packet != nullptr)  //拿到packet之后读取pts和dts；h264的数据地址和长度
        {
            last_packet_pts_us_ = mpp_packet_get_pts(packet);
            last_packet_dts_us_ = mpp_packet_get_dts(packet);
            last_packet_flags_ = mpp_packet_get_flag(packet);

            void *ptr = mpp_packet_get_pos(packet);
            size_t len = mpp_packet_get_length(packet);

            if (ptr != nullptr && len > 0)
            {
                const uint8_t *p = static_cast<const uint8_t *>(ptr);
                out_packet.assign(p, p + len);  //将H264packet拷贝到vector中，方便外部写入
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

#include "mpp_h264_encoder.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <chrono>
#include <string>

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <linux/videodev2.h>

static double diff_ms(const std::chrono::steady_clock::time_point &a,
                      const std::chrono::steady_clock::time_point &b)
{
    return std::chrono::duration<double, std::milli>(b - a).count();
}

static int xioctl(int fd, unsigned long request, void *arg)
{
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

class SimpleV4L2MPlaneCapture
{
public:
    struct Frame {
        int index;
        uint8_t *data;
        size_t bytesused;
    };

    SimpleV4L2MPlaneCapture()
        : fd_(-1),
          width_(0),
          height_(0),
          streaming_(false)
    {
    }

    ~SimpleV4L2MPlaneCapture()
    {
        close_device();
    }

    bool open_device(const char *dev, int width, int height)
    {
        width_ = width;
        height_ = height;

        fd_ = open(dev, O_RDWR | O_NONBLOCK, 0);
        if (fd_ < 0)
        {
            perror("open video device");
            return false;
        }

        v4l2_capability cap;
        memset(&cap, 0, sizeof(cap));
        if (xioctl(fd_, VIDIOC_QUERYCAP, &cap) < 0)
        {
            perror("VIDIOC_QUERYCAP");
            return false;
        }

        printf("driver     : %s\n", cap.driver);
        printf("card       : %s\n", cap.card);

        v4l2_format fmt;
        memset(&fmt, 0, sizeof(fmt));

        fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        fmt.fmt.pix_mp.width = width_;
        fmt.fmt.pix_mp.height = height_;
        fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
        fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
        fmt.fmt.pix_mp.num_planes = 1;
        fmt.fmt.pix_mp.plane_fmt[0].bytesperline = width_;
        fmt.fmt.pix_mp.plane_fmt[0].sizeimage = width_ * height_ * 3 / 2;

        if (xioctl(fd_, VIDIOC_S_FMT, &fmt) < 0)
        {
            perror("VIDIOC_S_FMT");
            return false;
        }

        printf("actual fmt : %ux%u fourcc=%c%c%c%c planes=%u sizeimage=%u bytesperline=%u\n",
               fmt.fmt.pix_mp.width,
               fmt.fmt.pix_mp.height,
               fmt.fmt.pix_mp.pixelformat & 0xff,
               (fmt.fmt.pix_mp.pixelformat >> 8) & 0xff,
               (fmt.fmt.pix_mp.pixelformat >> 16) & 0xff,
               (fmt.fmt.pix_mp.pixelformat >> 24) & 0xff,
               fmt.fmt.pix_mp.num_planes,
               fmt.fmt.pix_mp.plane_fmt[0].sizeimage,
               fmt.fmt.pix_mp.plane_fmt[0].bytesperline);

        v4l2_requestbuffers req;
        memset(&req, 0, sizeof(req));
        req.count = 4;
        req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        req.memory = V4L2_MEMORY_MMAP;

        if (xioctl(fd_, VIDIOC_REQBUFS, &req) < 0)
        {
            perror("VIDIOC_REQBUFS");
            return false;
        }

        if (req.count < 2)
        {
            printf("insufficient V4L2 buffers: %u\n", req.count);
            return false;
        }

        buffers_.resize(req.count);

        for (unsigned int i = 0; i < req.count; ++i)
        {
            v4l2_buffer buf;
            v4l2_plane planes[VIDEO_MAX_PLANES];
            memset(&buf, 0, sizeof(buf));
            memset(planes, 0, sizeof(planes));

            buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            buf.memory = V4L2_MEMORY_MMAP;
            buf.index = i;
            buf.length = VIDEO_MAX_PLANES;
            buf.m.planes = planes;

            if (xioctl(fd_, VIDIOC_QUERYBUF, &buf) < 0)
            {
                perror("VIDIOC_QUERYBUF");
                return false;
            }

            buffers_[i].length = planes[0].length;
            buffers_[i].start = mmap(NULL,
                                      planes[0].length,
                                      PROT_READ | PROT_WRITE,
                                      MAP_SHARED,
                                      fd_,
                                      planes[0].m.mem_offset);

            if (buffers_[i].start == MAP_FAILED)
            {
                perror("mmap");
                return false;
            }

            printf("mmap buffer=%u length=%zu offset=%u\n",
                   i,
                   buffers_[i].length,
                   planes[0].m.mem_offset);
        }

        for (unsigned int i = 0; i < buffers_.size(); ++i)
        {
            if (!queue_buffer(i))
            {
                return false;
            }
        }

        v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        if (xioctl(fd_, VIDIOC_STREAMON, &type) < 0)
        {
            perror("VIDIOC_STREAMON");
            return false;
        }

        streaming_ = true;
        return true;
    }

    bool dequeue_frame(Frame &frame, double &select_ms, double &dqbuf_ms)
    {
        frame.index = -1;
        frame.data = nullptr;
        frame.bytesused = 0;

        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd_, &fds);

        timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;

        auto t0 = std::chrono::steady_clock::now();
        int r = select(fd_ + 1, &fds, NULL, NULL, &tv);
        auto t1 = std::chrono::steady_clock::now();
        select_ms = diff_ms(t0, t1);

        if (r == -1)
        {
            perror("select");
            return false;
        }

        if (r == 0)
        {
            printf("select timeout\n");
            return false;
        }

        v4l2_buffer buf;
        v4l2_plane planes[VIDEO_MAX_PLANES];
        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = VIDEO_MAX_PLANES;
        buf.m.planes = planes;

        auto t2 = std::chrono::steady_clock::now();
        if (xioctl(fd_, VIDIOC_DQBUF, &buf) < 0)
        {
            if (errno == EAGAIN)
            {
                return false;
            }
            perror("VIDIOC_DQBUF");
            return false;
        }
        auto t3 = std::chrono::steady_clock::now();
        dqbuf_ms = diff_ms(t2, t3);

        if (buf.index >= buffers_.size())
        {
            printf("invalid buffer index: %u\n", buf.index);
            return false;
        }

        frame.index = static_cast<int>(buf.index);
        frame.data = static_cast<uint8_t *>(buffers_[buf.index].start);
        frame.bytesused = planes[0].bytesused;

        return true;
    }

    bool requeue_frame(int index)
    {
        return queue_buffer(index);
    }

    void close_device()
    {
        if (fd_ >= 0)
        {
            if (streaming_)
            {
                v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
                xioctl(fd_, VIDIOC_STREAMOFF, &type);
                streaming_ = false;
            }

            for (auto &b : buffers_)
            {
                if (b.start && b.start != MAP_FAILED)
                {
                    munmap(b.start, b.length);
                    b.start = nullptr;
                    b.length = 0;
                }
            }

            buffers_.clear();

            close(fd_);
            fd_ = -1;
        }
    }

private:
    struct Buffer {
        void *start = nullptr;
        size_t length = 0;
    };

    bool queue_buffer(unsigned int index)
    {
        v4l2_buffer buf;
        v4l2_plane planes[VIDEO_MAX_PLANES];
        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = index;
        buf.length = VIDEO_MAX_PLANES;
        buf.m.planes = planes;

        if (xioctl(fd_, VIDIOC_QBUF, &buf) < 0)
        {
            perror("VIDIOC_QBUF");
            return false;
        }

        return true;
    }

private:
    int fd_;
    int width_;
    int height_;
    bool streaming_;
    std::vector<Buffer> buffers_;
};

int main(int argc, char **argv)
{
    if (argc != 8)
    {
        printf("Usage:\n");
        printf("  %s <video_device> <width> <height> <fps> <frames> <bitrate> <output_h264>\n", argv[0]);
        printf("\nExample:\n");
        printf("  %s /dev/video11 1280 720 30 120 4000000 output/exp21_2_v4l2_mpp_encode/camera_mpp.h264\n", argv[0]);
        return -1;
    }

    const char *video_device = argv[1];
    int width = atoi(argv[2]);
    int height = atoi(argv[3]);
    int fps = atoi(argv[4]);
    int frames = atoi(argv[5]);
    int bitrate = atoi(argv[6]);
    const char *output_h264 = argv[7];

    const size_t expected_nv12_size = static_cast<size_t>(width) * height * 3 / 2;

    printf("========== exp21-2 v4l2 mpp encode ==========\n");
    printf("video dev  : %s\n", video_device);
    printf("output h264: %s\n", output_h264);
    printf("width      : %d\n", width);
    printf("height     : %d\n", height);
    printf("fps        : %d\n", fps);
    printf("frames     : %d\n", frames);
    printf("bitrate    : %d\n", bitrate);
    printf("nv12 size  : %zu\n", expected_nv12_size);
    printf("=============================================\n");

    FILE *fout = fopen(output_h264, "wb");
    if (!fout)
    {
        perror("fopen output_h264");
        return -1;
    }

    SimpleV4L2MPlaneCapture cap;
    if (!cap.open_device(video_device, width, height))
    {
        printf("open V4L2 device failed\n");
        fclose(fout);
        return -1;
    }

    MppH264Encoder encoder;
    if (!encoder.init(width, height, fps, bitrate))
    {
        printf("encoder init failed\n");
        fclose(fout);
        return -1;
    }

    std::vector<uint8_t> header;
    if (encoder.get_header(header) && !header.empty())
    {
        fwrite(header.data(), 1, header.size(), fout);
        printf("write h264 header: %zu bytes\n", header.size());
    }
    else
    {
        printf("warning: empty h264 header\n");
    }

    std::vector<uint8_t> packet;

    int encoded_frames = 0;
    size_t total_packet_bytes = 0;

    double sum_select_ms = 0.0;
    double sum_dqbuf_ms = 0.0;
    double sum_encode_ms = 0.0;
    double sum_write_ms = 0.0;
    double sum_qbuf_ms = 0.0;
    double sum_total_ms = 0.0;

    auto wall_start = std::chrono::steady_clock::now();

    for (int i = 0; i < frames; ++i)
    {
        auto ft0 = std::chrono::steady_clock::now();

        SimpleV4L2MPlaneCapture::Frame frame;
        double select_ms = 0.0;
        double dqbuf_ms = 0.0;

        if (!cap.dequeue_frame(frame, select_ms, dqbuf_ms))
        {
            printf("dequeue_frame failed at i=%d\n", i);
            break;
        }

        if (frame.bytesused < expected_nv12_size)
        {
            printf("warning: frame=%d bytesused=%zu expected=%zu\n",
                   i, frame.bytesused, expected_nv12_size);
        }

        auto t_enc0 = std::chrono::steady_clock::now();
        bool ok = encoder.encode(frame.data, expected_nv12_size, packet);
        auto t_enc1 = std::chrono::steady_clock::now();
        double encode_ms = diff_ms(t_enc0, t_enc1);

        if (!ok)
        {
            printf("encoder.encode failed at frame=%d\n", i);
            cap.requeue_frame(frame.index);
            break;
        }

        auto t_write0 = std::chrono::steady_clock::now();
        if (!packet.empty())
        {
            fwrite(packet.data(), 1, packet.size(), fout);
            total_packet_bytes += packet.size();
        }
        auto t_write1 = std::chrono::steady_clock::now();
        double write_ms = diff_ms(t_write0, t_write1);

        auto t_q0 = std::chrono::steady_clock::now();
        if (!cap.requeue_frame(frame.index))
        {
            printf("requeue_frame failed at frame=%d index=%d\n", i, frame.index);
            break;
        }
        auto t_q1 = std::chrono::steady_clock::now();
        double qbuf_ms = diff_ms(t_q0, t_q1);

        auto ft1 = std::chrono::steady_clock::now();
        double total_ms = diff_ms(ft0, ft1);

        encoded_frames++;

        sum_select_ms += select_ms;
        sum_dqbuf_ms += dqbuf_ms;
        sum_encode_ms += encode_ms;
        sum_write_ms += write_ms;
        sum_qbuf_ms += qbuf_ms;
        sum_total_ms += total_ms;

        if (encoded_frames == 1 || encoded_frames % 30 == 0)
        {
            double inst_fps = total_ms > 0.0 ? 1000.0 / total_ms : 0.0;
            printf("frame=%d packet=%zu select=%.3f dqbuf=%.3f encode=%.3f write=%.3f qbuf=%.3f total=%.3f fps=%.3f\n",
                   encoded_frames,
                   packet.size(),
                   select_ms,
                   dqbuf_ms,
                   encode_ms,
                   write_ms,
                   qbuf_ms,
                   total_ms,
                   inst_fps);
            fflush(stdout);
        }
    }

    auto wall_end = std::chrono::steady_clock::now();
    double wall_ms = diff_ms(wall_start, wall_end);
    double wall_fps = wall_ms > 0.0 ? encoded_frames * 1000.0 / wall_ms : 0.0;

    cap.close_device();
    encoder.release();

    fclose(fout);

    double avg_select = encoded_frames > 0 ? sum_select_ms / encoded_frames : 0.0;
    double avg_dqbuf = encoded_frames > 0 ? sum_dqbuf_ms / encoded_frames : 0.0;
    double avg_encode = encoded_frames > 0 ? sum_encode_ms / encoded_frames : 0.0;
    double avg_write = encoded_frames > 0 ? sum_write_ms / encoded_frames : 0.0;
    double avg_qbuf = encoded_frames > 0 ? sum_qbuf_ms / encoded_frames : 0.0;
    double avg_total = encoded_frames > 0 ? sum_total_ms / encoded_frames : 0.0;

    printf("\n========== exp21-2 result ==========\n");
    printf("encoded_frames    : %d\n", encoded_frames);
    printf("wall_time_ms      : %.3f\n", wall_ms);
    printf("wall_fps          : %.3f\n", wall_fps);
    printf("avg_select_ms     : %.3f\n", avg_select);
    printf("avg_dqbuf_ms      : %.3f\n", avg_dqbuf);
    printf("avg_encode_ms     : %.3f\n", avg_encode);
    printf("avg_write_ms      : %.3f\n", avg_write);
    printf("avg_qbuf_ms       : %.3f\n", avg_qbuf);
    printf("avg_total_ms      : %.3f\n", avg_total);
    printf("h264_packet_bytes : %zu\n", total_packet_bytes);
    printf("output_h264       : %s\n", output_h264);
    printf("====================================\n");

    return encoded_frames > 0 ? 0 : -1;
}

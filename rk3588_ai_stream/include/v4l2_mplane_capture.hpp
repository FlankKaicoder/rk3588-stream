#pragma once

#include <fcntl.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <errno.h>
//对ioctl进行健壮性封装;被打断之后就继续进行循环；inline 关键字是内联函数减少函数调用开销；
static inline int xioctl_retry(int fd, unsigned long request, void *arg)
{
    int r;
    do
    {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

static inline double time_diff_ms(const std::chrono::steady_clock::time_point &a,
                                  const std::chrono::steady_clock::time_point &b)
{
    return std::chrono::duration<double, std::milli>(b - a).count();
}

class V4L2MPlaneCapture
{
public:
    struct Frame //帧数据包裹的结构体用于定义缓冲在队列中的索引指向图像的指针和实际使用的字节数等；
    {
        int index = -1;
        unsigned char *data = nullptr;
        size_t bytesused = 0;
    };

    V4L2MPlaneCapture() = default;

    ~V4L2MPlaneCapture()
    {
        close_device();
    }

    bool open_device(const char *device, int width, int height, int fps = 30, int buffer_count = 4) //核心初始化
    {
        device_ = device;
        width_ = width;
        height_ = height;

        fd_ = open(device, O_RDWR | O_NONBLOCK, 0); //非阻塞模式打开设备保证操作流程不会卡死
        if (fd_ < 0)
        {
            perror("open video device failed");
            return false;
        }

        struct v4l2_capability cap;
        memset(&cap, 0, sizeof(cap));
        if (xioctl_retry(fd_, VIDIOC_QUERYCAP, &cap) < 0) // 获取打印设备能力
        {
            perror("VIDIOC_QUERYCAP failed");
            return false;
        }

        printf("driver : %s\n", cap.driver);
        printf("card   : %s\n", cap.card);
        printf("bus    : %s\n", cap.bus_info);
   
        if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE)) //校验摄像头能力
        {
            printf("ERROR: device does not support VIDEO_CAPTURE_MPLANE\n");
            return false;
        }

        if (!(cap.capabilities & V4L2_CAP_STREAMING))
        {
            printf("ERROR: device does not support STREAMING\n");
            return false;
        }

        struct v4l2_format fmt; //设置采集格式
        memset(&fmt, 0, sizeof(fmt));
        fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        fmt.fmt.pix_mp.width = width_;
        fmt.fmt.pix_mp.height = height_;
        fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
        fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
        fmt.fmt.pix_mp.num_planes = 1;

        if (xioctl_retry(fd_, VIDIOC_S_FMT, &fmt) < 0)
        {
            perror("VIDIOC_S_FMT failed");
            return false;
        }

        width_ = fmt.fmt.pix_mp.width;
        height_ = fmt.fmt.pix_mp.height;
        image_size_ = width_ * height_ * 3 / 2;

        printf("actual fmt: %dx%d NV12, image_size=%zu\n", width_, height_, image_size_);

        struct v4l2_streamparm parm; //设置采集格式，多平面采集；
        memset(&parm, 0, sizeof(parm));
        parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        parm.parm.capture.timeperframe.numerator = 1;
        parm.parm.capture.timeperframe.denominator = fps;

        if (xioctl_retry(fd_, VIDIOC_S_PARM, &parm) < 0)
        {
            printf("WARN: VIDIOC_S_PARM failed: %s\n", strerror(errno));
        }

        struct v4l2_requestbuffers req;  //申请内核内存
        memset(&req, 0, sizeof(req));
        req.count = buffer_count;
        req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        req.memory = V4L2_MEMORY_MMAP;

        if (xioctl_retry(fd_, VIDIOC_REQBUFS, &req) < 0) //申请内核内存
        {
            perror("VIDIOC_REQBUFS failed");
            return false;
        }

        if (req.count < 2)  //少于两块就不能进行循环交替缓冲；
        {
            printf("ERROR: insufficient V4L2 buffers\n");
            return false;
        }

        buffers_.resize(req.count);
        printf("request buffers count: %u\n", req.count);

        for (unsigned int i = 0; i < req.count; ++i) //内存映射核心循环：将分配好的物理内存直接映射到用户空间的buffer_[i].start指针上，实现零拷贝
        {
            struct v4l2_buffer buf;
            struct v4l2_plane planes[VIDEO_MAX_PLANES];

            memset(&buf, 0, sizeof(buf));
            memset(planes, 0, sizeof(planes));

            buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            buf.memory = V4L2_MEMORY_MMAP;
            buf.index = i;
            buf.length = 1;
            buf.m.planes = planes;

            if (xioctl_retry(fd_, VIDIOC_QUERYBUF, &buf) < 0)
            {
                perror("VIDIOC_QUERYBUF failed");
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
                perror("mmap failed");
                return false;
            }

            printf("mmap buffer=%u length=%zu offset=%u\n",
                   i,
                   buffers_[i].length,
                   planes[0].m.mem_offset);
        }

        for (unsigned int i = 0; i < buffers_.size(); ++i) //调用queue_buffer全部回到内核中进行重新排列，准备接受图像；
        {
            if (!queue_buffer(i))
            {
                return false;
            }
        }

        enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; //开始采集，开启硬件感光
        if (xioctl_retry(fd_, VIDIOC_STREAMON, &type) < 0)
        {
            perror("VIDIOC_STREAMON failed");
            return false;
        }

        streaming_ = true;  // 标记状态
        return true;
    }

    bool dequeue_frame(Frame &frame, double &select_ms, double &dqbuf_ms, int timeout_sec = 2)// 参数frame用于带回数据图像；然后传出参数select_ms和dqbuf_ms用于记录耗时，timeout默认两秒；
    {
        fd_set fds; // linux多路复用IO写法，创建文件描述集合，然后清空再把摄像头设备放进去；
        FD_ZERO(&fds);
        FD_SET(fd_, &fds);

        struct timeval tv;  //设置超时时间；
        tv.tv_sec = timeout_sec;
        tv.tv_usec = 0;

        auto t_select0 = std::chrono::steady_clock::now();
        int r = select(fd_ + 1, &fds, NULL, NULL, &tv);
        auto t_select1 = std::chrono::steady_clock::now();
        select_ms = time_diff_ms(t_select0, t_select1);

        if (r == -1)  //select返回-1的情况（异常错误）；
        {
            if (errno == EINTR)
            {
                return false;
            }
            perror("select failed");
            return false;
        }

        if (r == 0) // 超时没有数据；
        {
            printf("select timeout\n");
            return false;
        }

        struct v4l2_buffer buf; //准备dqbuf
        struct v4l2_plane planes[VIDEO_MAX_PLANES];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = 1;
        buf.m.planes = planes;

        auto t_dq0 = std::chrono::steady_clock::now();
        if (xioctl_retry(fd_, VIDIOC_DQBUF, &buf) < 0) //执行取餐动作；
        {
            if (errno == EAGAIN)  //非阻塞的平滑处理
            {
                return false;
            }
            perror("VIDIOC_DQBUF failed");
            return false;
        }
        auto t_dq1 = std::chrono::steady_clock::now();
        dqbuf_ms = time_diff_ms(t_dq0, t_dq1);

        frame.index = buf.index; // 打包数据返回上层
        frame.data = static_cast<unsigned char *>(buffers_[buf.index].start); //零拷贝实现传递了指针；
        frame.bytesused = planes[0].bytesused;

        return true;
    }

    bool requeue_frame(const Frame &frame)//还帧逻辑：返回frame.index传回去；
    {
        return queue_buffer(frame.index); //复用底部私有函数；
    }

    void close_device() //安全清理资源
    {
        if (streaming_) //关流
        {
            enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            xioctl_retry(fd_, VIDIOC_STREAMOFF, &type);
            streaming_ = false;
        }

        for (auto &b : buffers_)
        {
            if (b.start && b.start != MAP_FAILED)
            {
                munmap(b.start, b.length); //解除内存映射
                b.start = nullptr;
            }
        }

        buffers_.clear(); //清空buffer

        if (fd_ >= 0) //关闭描述符
        {
            close(fd_);
            fd_ = -1;
        }
    }
    //方便外部获取图像宽、高和大小；
    int width() const { return width_; }
    int height() const { return height_; }
    size_t image_size() const { return image_size_; }

private:
    struct Buffer // 私有结构体用于记录四个buffer（长度和映射地址）
    {
        void *start = nullptr;
        size_t length = 0;
    };

    bool queue_buffer(int index) // 私有函数执行操作；
    {
        struct v4l2_buffer buf;
        struct v4l2_plane planes[VIDEO_MAX_PLANES];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = index;
        buf.length = 1;
        buf.m.planes = planes;

        if (xioctl_retry(fd_, VIDIOC_QBUF, &buf) < 0)
        {
            perror("VIDIOC_QBUF failed");
            return false;
        }

        return true;
    }

private:
    int fd_ = -1;
    int width_ = 0;
    int height_ = 0;
    size_t image_size_ = 0;
    bool streaming_ = false;
    std::string device_;
    std::vector<Buffer> buffers_;
};

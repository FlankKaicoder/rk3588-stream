#include <fcntl.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <chrono>

struct Buffer {
    void* start = nullptr;
    size_t length = 0;
};

static int xioctl(int fd, unsigned long request, void* arg)
{
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

static double diff_ms(const std::chrono::steady_clock::time_point& a,
                      const std::chrono::steady_clock::time_point& b)
{
    return std::chrono::duration<double, std::milli>(b - a).count();
}

int main(int argc, char** argv)
{
    if (argc != 6) {
        printf("Usage: %s <video_dev> <width> <height> <frames> <out_nv12>\n", argv[0]);
        printf("Example: %s /dev/video11 1280 720 120 output/exp08_mpp_encode_record/input_120f_1280x720.nv12\n", argv[0]);
        return -1;
    }

    const char* dev_name = argv[1];
    int width = atoi(argv[2]);
    int height = atoi(argv[3]);
    int frames = atoi(argv[4]);
    const char* out_path = argv[5];

    const size_t expected_frame_size = (size_t)width * height * 3 / 2;

    printf("video dev  : %s\n", dev_name);
    printf("width      : %d\n", width);
    printf("height     : %d\n", height);
    printf("frames     : %d\n", frames);
    printf("out nv12   : %s\n", out_path);
    printf("frame size : %zu\n", expected_frame_size);

    int fd = open(dev_name, O_RDWR | O_NONBLOCK, 0);
    if (fd < 0) {
        perror("open video device failed");
        return -1;
    }

    v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        perror("VIDIOC_QUERYCAP failed");
        close(fd);
        return -1;
    }

    printf("driver     : %s\n", cap.driver);
    printf("card       : %s\n", cap.card);

    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE_MPLANE)) {
        printf("ERROR: device does not support V4L2_CAP_VIDEO_CAPTURE_MPLANE\n");
        close(fd);
        return -1;
    }

    if (!(cap.capabilities & V4L2_CAP_STREAMING)) {
        printf("ERROR: device does not support V4L2_CAP_STREAMING\n");
        close(fd);
        return -1;
    }

    v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    fmt.fmt.pix_mp.width = width;
    fmt.fmt.pix_mp.height = height;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
    fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
    fmt.fmt.pix_mp.num_planes = 1;

    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        perror("VIDIOC_S_FMT failed");
        close(fd);
        return -1;
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

    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        perror("VIDIOC_REQBUFS failed");
        close(fd);
        return -1;
    }

    printf("request buffers count: %u\n", req.count);

    std::vector<Buffer> buffers(req.count);

    for (unsigned int i = 0; i < req.count; ++i) {
        v4l2_buffer buf;
        v4l2_plane planes[1];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = 1;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            perror("VIDIOC_QUERYBUF failed");
            close(fd);
            return -1;
        }

        buffers[i].length = buf.m.planes[0].length;
        buffers[i].start = mmap(NULL,
                                buffers[i].length,
                                PROT_READ | PROT_WRITE,
                                MAP_SHARED,
                                fd,
                                buf.m.planes[0].m.mem_offset);

        if (buffers[i].start == MAP_FAILED) {
            perror("mmap failed");
            close(fd);
            return -1;
        }

        printf("mmap buffer=%u length=%zu offset=%u\n",
               i,
               buffers[i].length,
               buf.m.planes[0].m.mem_offset);
    }

    for (unsigned int i = 0; i < req.count; ++i) {
        v4l2_buffer buf;
        v4l2_plane planes[1];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = 1;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF failed");
            close(fd);
            return -1;
        }
    }

    FILE* fout = fopen(out_path, "wb");
    if (!fout) {
        perror("fopen output failed");
        close(fd);
        return -1;
    }

    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON failed");
        fclose(fout);
        close(fd);
        return -1;
    }

    double sum_select_ms = 0.0;
    double sum_dqbuf_ms = 0.0;
    double sum_write_ms = 0.0;
    double sum_qbuf_ms = 0.0;

    auto wall_start = std::chrono::steady_clock::now();

    for (int frame_id = 0; frame_id < frames; ++frame_id) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;

        auto t_select0 = std::chrono::steady_clock::now();
        int r = select(fd + 1, &fds, NULL, NULL, &tv);
        auto t_select1 = std::chrono::steady_clock::now();

        if (r < 0) {
            perror("select failed");
            break;
        }

        if (r == 0) {
            printf("select timeout at frame=%d\n", frame_id);
            break;
        }

        v4l2_buffer buf;
        v4l2_plane planes[1];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = 1;
        buf.m.planes = planes;

        auto t_dq0 = std::chrono::steady_clock::now();
        if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) {
                --frame_id;
                continue;
            }
            perror("VIDIOC_DQBUF failed");
            break;
        }
        auto t_dq1 = std::chrono::steady_clock::now();

        size_t bytesused = buf.m.planes[0].bytesused;
        if (bytesused == 0 || bytesused > buffers[buf.index].length) {
            bytesused = expected_frame_size;
        }

        if (bytesused > expected_frame_size) {
            bytesused = expected_frame_size;
        }

        auto t_write0 = std::chrono::steady_clock::now();
        size_t written = fwrite(buffers[buf.index].start, 1, bytesused, fout);
        auto t_write1 = std::chrono::steady_clock::now();

        if (written != bytesused) {
            printf("short write frame=%d written=%zu bytesused=%zu\n",
                   frame_id, written, bytesused);
            break;
        }

        auto t_q0 = std::chrono::steady_clock::now();
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF requeue failed");
            break;
        }
        auto t_q1 = std::chrono::steady_clock::now();

        double select_ms = diff_ms(t_select0, t_select1);
        double dqbuf_ms = diff_ms(t_dq0, t_dq1);
        double write_ms = diff_ms(t_write0, t_write1);
        double qbuf_ms = diff_ms(t_q0, t_q1);

        sum_select_ms += select_ms;
        sum_dqbuf_ms += dqbuf_ms;
        sum_write_ms += write_ms;
        sum_qbuf_ms += qbuf_ms;

        if (frame_id % 30 == 0) {
            printf("frame=%d index=%u bytesused=%zu select=%.3f dqbuf=%.3f write=%.3f qbuf=%.3f\n",
                   frame_id,
                   buf.index,
                   bytesused,
                   select_ms,
                   dqbuf_ms,
                   write_ms,
                   qbuf_ms);
        }
    }

    auto wall_end = std::chrono::steady_clock::now();
    double wall_ms = diff_ms(wall_start, wall_end);

    xioctl(fd, VIDIOC_STREAMOFF, &type);

    fclose(fout);

    for (auto& b : buffers) {
        if (b.start && b.start != MAP_FAILED) {
            munmap(b.start, b.length);
        }
    }

    close(fd);

    printf("\n========== 08-1 dump nv12 result ==========\n");
    printf("frames          : %d\n", frames);
    printf("wall_time_ms    : %.3f\n", wall_ms);
    printf("wall_fps        : %.3f\n", frames * 1000.0 / wall_ms);
    printf("avg_select_ms   : %.3f\n", sum_select_ms / frames);
    printf("avg_dqbuf_ms    : %.3f\n", sum_dqbuf_ms / frames);
    printf("avg_write_ms    : %.3f\n", sum_write_ms / frames);
    printf("avg_qbuf_ms     : %.3f\n", sum_qbuf_ms / frames);
    printf("saved nv12      : %s\n", out_path);
    printf("==========================================\n");

    return 0;
}

#include <linux/videodev2.h>

#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <sys/types.h>

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

#include <chrono>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <vector>
#include <string>

struct PlaneMap {
    void *start = nullptr;
    size_t length = 0;
};

struct Buffer {
    std::vector<PlaneMap> planes;
};

static int xioctl(int fd, unsigned long request, void *arg)
{
    int ret;
    do {
        ret = ioctl(fd, request, arg);
    } while (ret == -1 && errno == EINTR);

    return ret;
}

static inline double diff_ms(const std::chrono::steady_clock::time_point &start,
                             const std::chrono::steady_clock::time_point &end)
{
    return std::chrono::duration<double, std::milli>(end - start).count();
}

static uint32_t fourcc_from_string(const char *s)
{
    if (s == nullptr || strlen(s) != 4) {
        return V4L2_PIX_FMT_NV12;
    }

    return v4l2_fourcc(s[0], s[1], s[2], s[3]);
}

static void print_fourcc(uint32_t pixelformat)
{
    char fcc[5] = {0};
    fcc[0] = pixelformat & 0xFF;
    fcc[1] = (pixelformat >> 8) & 0xFF;
    fcc[2] = (pixelformat >> 16) & 0xFF;
    fcc[3] = (pixelformat >> 24) & 0xFF;
    printf("%s", fcc);
}

int main(int argc, char **argv)
{
    const char *dev_path = "/dev/video11";
    int req_width = 1280;
    int req_height = 720;
    int req_fps = 30;
    const char *req_pixfmt_str = "NV12";
    int max_frames = 120;

    if (argc != 1 && argc != 2 && argc != 7) {
        printf("Usage:\n");
        printf("  %s\n", argv[0]);
        printf("  %s <device>\n", argv[0]);
        printf("  %s <device> <width> <height> <fps> <pixfmt> <max_frames>\n", argv[0]);
        printf("\nExamples:\n");
        printf("  %s /dev/video11 1280 720 30 NV12 120\n", argv[0]);
        printf("  %s /dev/video11 1920 1080 30 NV12 120\n", argv[0]);
        return -1;
    }

    if (argc == 2) {
        dev_path = argv[1];
    }

    if (argc == 7) {
        dev_path = argv[1];
        req_width = atoi(argv[2]);
        req_height = atoi(argv[3]);
        req_fps = atoi(argv[4]);
        req_pixfmt_str = argv[5];
        max_frames = atoi(argv[6]);
    }

    if (req_width <= 0) req_width = 1280;
    if (req_height <= 0) req_height = 720;
    if (req_fps <= 0) req_fps = 30;
    if (max_frames <= 0) max_frames = 120;

    uint32_t req_pixfmt = fourcc_from_string(req_pixfmt_str);

    printf("device      : %s\n", dev_path);
    printf("request fmt : %dx%d %d fps ", req_width, req_height, req_fps);
    print_fourcc(req_pixfmt);
    printf("\n");
    printf("max frames  : %d\n\n", max_frames);

    int fd = open(dev_path, O_RDWR | O_NONBLOCK, 0);
    if (fd < 0) {
        printf("ERROR: open %s failed: %s\n", dev_path, strerror(errno));
        return -1;
    }

    v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        printf("ERROR: VIDIOC_QUERYCAP failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    printf("Driver Info:\n");
    printf("  driver      : %s\n", cap.driver);
    printf("  card        : %s\n", cap.card);
    printf("  bus_info    : %s\n", cap.bus_info);
    printf("  capabilities: 0x%08x\n", cap.capabilities);
    printf("  device caps : 0x%08x\n\n", cap.device_caps);

    if (!(cap.device_caps & V4L2_CAP_VIDEO_CAPTURE_MPLANE)) {
        printf("ERROR: device is not VIDEO_CAPTURE_MPLANE\n");
        close(fd);
        return -1;
    }

    if (!(cap.device_caps & V4L2_CAP_STREAMING)) {
        printf("ERROR: device does not support streaming\n");
        close(fd);
        return -1;
    }

    // 1. 设置采集格式：mplane / NV12 / 1280x720
    v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));

    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    fmt.fmt.pix_mp.width = req_width;
    fmt.fmt.pix_mp.height = req_height;
    fmt.fmt.pix_mp.pixelformat = req_pixfmt;
    fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
    fmt.fmt.pix_mp.num_planes = 1;

    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        printf("ERROR: VIDIOC_S_FMT failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    printf("Actual format after VIDIOC_S_FMT:\n");
    printf("  width       : %u\n", fmt.fmt.pix_mp.width);
    printf("  height      : %u\n", fmt.fmt.pix_mp.height);
    printf("  pixelformat : ");
    print_fourcc(fmt.fmt.pix_mp.pixelformat);
    printf("\n");
    printf("  num_planes  : %u\n", fmt.fmt.pix_mp.num_planes);

    for (unsigned int i = 0; i < fmt.fmt.pix_mp.num_planes; i++) {
        printf("  plane[%u] bytesperline=%u sizeimage=%u\n",
               i,
               fmt.fmt.pix_mp.plane_fmt[i].bytesperline,
               fmt.fmt.pix_mp.plane_fmt[i].sizeimage);
    }
    printf("\n");

    unsigned int num_planes = fmt.fmt.pix_mp.num_planes;
    if (num_planes == 0 || num_planes > VIDEO_MAX_PLANES) {
        printf("ERROR: invalid num_planes=%u\n", num_planes);
        close(fd);
        return -1;
    }

    // 2. 尝试设置 FPS。驱动可能忽略，但不影响后续实测。
    v4l2_streamparm parm;
    memset(&parm, 0, sizeof(parm));
    parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    parm.parm.capture.timeperframe.numerator = 1;
    parm.parm.capture.timeperframe.denominator = req_fps;

    if (xioctl(fd, VIDIOC_S_PARM, &parm) < 0) {
        printf("WARN: VIDIOC_S_PARM failed: %s\n", strerror(errno));
    } else {
        printf("Actual stream parm:\n");
        printf("  timeperframe: %u/%u\n",
               parm.parm.capture.timeperframe.numerator,
               parm.parm.capture.timeperframe.denominator);
        if (parm.parm.capture.timeperframe.numerator != 0) {
            double real_fps =
                (double)parm.parm.capture.timeperframe.denominator /
                (double)parm.parm.capture.timeperframe.numerator;
            printf("  reported fps : %.3f\n", real_fps);
        }
    }
    printf("\n");

    // 3. 申请 mmap buffer
    v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));

    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    req.memory = V4L2_MEMORY_MMAP;

    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        printf("ERROR: VIDIOC_REQBUFS failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    if (req.count < 2) {
        printf("ERROR: insufficient buffer memory, count=%u\n", req.count);
        close(fd);
        return -1;
    }

    printf("request buffers count: %u\n", req.count);

    std::vector<Buffer> buffers(req.count);

    for (unsigned int i = 0; i < req.count; i++) {
        v4l2_buffer buf;
        v4l2_plane planes[VIDEO_MAX_PLANES];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = num_planes;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            printf("ERROR: VIDIOC_QUERYBUF index=%u failed: %s\n", i, strerror(errno));
            close(fd);
            return -1;
        }

        buffers[i].planes.resize(num_planes);

        for (unsigned int p = 0; p < num_planes; p++) {
            buffers[i].planes[p].length = planes[p].length;
            buffers[i].planes[p].start = mmap(NULL,
                                               planes[p].length,
                                               PROT_READ | PROT_WRITE,
                                               MAP_SHARED,
                                               fd,
                                               planes[p].m.mem_offset);

            if (buffers[i].planes[p].start == MAP_FAILED) {
                printf("ERROR: mmap buffer=%u plane=%u failed: %s\n",
                       i, p, strerror(errno));
                close(fd);
                return -1;
            }

            printf("mmap buffer=%u plane=%u length=%zu offset=%u\n",
                   i,
                   p,
                   buffers[i].planes[p].length,
                   planes[p].m.mem_offset);
        }
    }

    printf("\n");

    // 4. 所有 buffer 入队
    for (unsigned int i = 0; i < req.count; i++) {
        v4l2_buffer buf;
        v4l2_plane planes[VIDEO_MAX_PLANES];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = num_planes;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            printf("ERROR: VIDIOC_QBUF index=%u failed: %s\n", i, strerror(errno));
            close(fd);
            return -1;
        }
    }

    // 5. 开启采集
    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        printf("ERROR: VIDIOC_STREAMON failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }

    printf("stream on. start capture...\n\n");

    double sum_dqbuf_ms = 0.0;
    double min_dqbuf_ms = 1e9;
    double max_dqbuf_ms = 0.0;

    int captured = 0;

    auto t_all_start = std::chrono::steady_clock::now();

    while (captured < max_frames) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;

        int r = select(fd + 1, &fds, NULL, NULL, &tv);
        if (r == -1) {
            if (errno == EINTR) {
                continue;
            }
            printf("ERROR: select failed: %s\n", strerror(errno));
            break;
        }

        if (r == 0) {
            printf("ERROR: select timeout\n");
            break;
        }

        v4l2_buffer buf;
        v4l2_plane planes[VIDEO_MAX_PLANES];

        memset(&buf, 0, sizeof(buf));
        memset(planes, 0, sizeof(planes));

        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = num_planes;
        buf.m.planes = planes;

        auto t_dq_start = std::chrono::steady_clock::now();

        if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) {
                continue;
            }
            printf("ERROR: VIDIOC_DQBUF failed: %s\n", strerror(errno));
            break;
        }

        auto t_dq_end = std::chrono::steady_clock::now();
        double dqbuf_ms = diff_ms(t_dq_start, t_dq_end);

        sum_dqbuf_ms += dqbuf_ms;
        if (dqbuf_ms < min_dqbuf_ms) min_dqbuf_ms = dqbuf_ms;
        if (dqbuf_ms > max_dqbuf_ms) max_dqbuf_ms = dqbuf_ms;

        if (captured < 10 || (captured + 1) % 30 == 0) {
            printf("frame=%d index=%u dqbuf_ms=%.3f",
                   captured,
                   buf.index,
                   dqbuf_ms);

            for (unsigned int p = 0; p < num_planes; p++) {
                printf(" plane[%u].bytesused=%u", p, planes[p].bytesused);
            }

            printf("\n");
        }

        // 这里不处理图像数据，只是性能测试。
        // 后续 04-5 可以把 buffers[buf.index].planes[0].start 保存成 NV12 文件。

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            printf("ERROR: VIDIOC_QBUF requeue failed: %s\n", strerror(errno));
            break;
        }

        captured++;
    }

    auto t_all_end = std::chrono::steady_clock::now();
    double wall_ms = diff_ms(t_all_start, t_all_end);

    double avg_dqbuf_ms = captured > 0 ? sum_dqbuf_ms / captured : 0.0;
    double dqbuf_fps = avg_dqbuf_ms > 0.0 ? 1000.0 / avg_dqbuf_ms : 0.0;
    double wall_fps = wall_ms > 0.0 ? 1000.0 * captured / wall_ms : 0.0;

    printf("\n========== 04-4 v4l2 capture profile ==========\n");
    printf("captured      : %d\n", captured);
    printf("avg_dqbuf_ms  : %.3f\n", avg_dqbuf_ms);
    printf("min_dqbuf_ms  : %.3f\n", min_dqbuf_ms);
    printf("max_dqbuf_ms  : %.3f\n", max_dqbuf_ms);
    printf("dqbuf_fps     : %.3f\n", dqbuf_fps);
    printf("wall_time_ms  : %.3f\n", wall_ms);
    printf("wall_fps      : %.3f\n", wall_fps);
    printf("================================================\n");

    // 6. 停止采集
    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_STREAMOFF, &type) < 0) {
        printf("WARN: VIDIOC_STREAMOFF failed: %s\n", strerror(errno));
    }

    for (unsigned int i = 0; i < buffers.size(); i++) {
        for (unsigned int p = 0; p < buffers[i].planes.size(); p++) {
            if (buffers[i].planes[p].start &&
                buffers[i].planes[p].start != MAP_FAILED) {
                munmap(buffers[i].planes[p].start, buffers[i].planes[p].length);
            }
        }
    }

    close(fd);

    return 0;
}

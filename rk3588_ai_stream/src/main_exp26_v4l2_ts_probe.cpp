#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/time.h>
#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>
#include <time.h>

struct Buffer {
    void* start = nullptr;
    size_t length = 0;
};

static int xioctl(int fd, unsigned long request, void* arg) {
    int r = 0;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

static int64_t now_monotonic_ns() {
    struct timespec ts {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int64_t timeval_to_ns(const timeval& tv) {
    return (int64_t)tv.tv_sec * 1000000000LL + (int64_t)tv.tv_usec * 1000LL;
}

static std::string timestamp_flag_name(uint32_t flags) {
#ifdef V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC
    if (flags & V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC) return "MONOTONIC";
#endif
#ifdef V4L2_BUF_FLAG_TIMESTAMP_COPY
    if (flags & V4L2_BUF_FLAG_TIMESTAMP_COPY) return "COPY";
#endif
    return "UNKNOWN_OR_DEVICE";
}

int main(int argc, char** argv) {
    if (argc != 6) {
        std::cerr << "Usage: " << argv[0]
                  << " <video_dev> <width> <height> <frames> <out_csv>\n";
        return 1;
    }

    const char* dev = argv[1];
    int width = std::stoi(argv[2]);
    int height = std::stoi(argv[3]);
    int frames = std::stoi(argv[4]);
    const char* csv_path = argv[5];

    int fd = open(dev, O_RDWR | O_NONBLOCK, 0);
    if (fd < 0) {
        std::cerr << "open failed: " << dev << " errno=" << errno
                  << " " << strerror(errno) << "\n";
        return 2;
    }

    v4l2_capability cap {};
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) < 0) {
        std::cerr << "VIDIOC_QUERYCAP failed: " << strerror(errno) << "\n";
        close(fd);
        return 3;
    }

    std::cout << "driver     : " << cap.driver << "\n";
    std::cout << "card       : " << cap.card << "\n";

    v4l2_format fmt {};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    fmt.fmt.pix_mp.width = width;
    fmt.fmt.pix_mp.height = height;
    fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
    fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
    fmt.fmt.pix_mp.num_planes = 1;

    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        std::cerr << "VIDIOC_S_FMT failed: " << strerror(errno) << "\n";
        close(fd);
        return 4;
    }

    std::cout << "actual fmt : "
              << fmt.fmt.pix_mp.width << "x" << fmt.fmt.pix_mp.height
              << " fourcc=NV12"
              << " planes=" << (int)fmt.fmt.pix_mp.num_planes
              << " sizeimage=" << fmt.fmt.pix_mp.plane_fmt[0].sizeimage
              << " bytesperline=" << fmt.fmt.pix_mp.plane_fmt[0].bytesperline
              << "\n";

    v4l2_requestbuffers req {};
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    req.memory = V4L2_MEMORY_MMAP;

    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
        std::cerr << "VIDIOC_REQBUFS failed: " << strerror(errno) << "\n";
        close(fd);
        return 5;
    }

    if (req.count < 2) {
        std::cerr << "insufficient V4L2 buffers\n";
        close(fd);
        return 6;
    }

    std::vector<Buffer> buffers(req.count);

    for (uint32_t i = 0; i < req.count; ++i) {
        v4l2_buffer buf {};
        v4l2_plane planes[VIDEO_MAX_PLANES] {};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = 1;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) {
            std::cerr << "VIDIOC_QUERYBUF failed: " << strerror(errno) << "\n";
            close(fd);
            return 7;
        }

        buffers[i].length = planes[0].length;
        buffers[i].start = mmap(nullptr,
                                planes[0].length,
                                PROT_READ | PROT_WRITE,
                                MAP_SHARED,
                                fd,
                                planes[0].m.mem_offset);

        if (buffers[i].start == MAP_FAILED) {
            std::cerr << "mmap failed: " << strerror(errno) << "\n";
            close(fd);
            return 8;
        }

        std::cout << "mmap buffer=" << i
                  << " length=" << buffers[i].length
                  << " offset=" << planes[0].m.mem_offset << "\n";
    }

    for (uint32_t i = 0; i < req.count; ++i) {
        v4l2_buffer buf {};
        v4l2_plane planes[VIDEO_MAX_PLANES] {};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        buf.length = 1;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            std::cerr << "VIDIOC_QBUF failed: " << strerror(errno) << "\n";
            close(fd);
            return 9;
        }
    }

    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        std::cerr << "VIDIOC_STREAMON failed: " << strerror(errno) << "\n";
        close(fd);
        return 10;
    }

    std::ofstream csv(csv_path);
    if (!csv.is_open()) {
        std::cerr << "open csv failed: " << csv_path << "\n";
        close(fd);
        return 11;
    }

    csv << "frame_id,"
        << "dqbuf_monotonic_ns,"
        << "v4l2_ts_ns,"
        << "v4l2_ts_type,"
        << "dqbuf_minus_v4l2_ms,"
        << "sequence,"
        << "index,"
        << "bytesused,"
        << "flags\n";

    int64_t first_v4l2_ts_ns = -1;
    int64_t first_dqbuf_ns = -1;

    for (int frame_id = 0; frame_id < frames; ++frame_id) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        timeval tv {};
        tv.tv_sec = 2;
        tv.tv_usec = 0;

        int r = select(fd + 1, &fds, nullptr, nullptr, &tv);
        if (r == -1) {
            std::cerr << "select failed at frame=" << frame_id
                      << " " << strerror(errno) << "\n";
            break;
        }
        if (r == 0) {
            std::cerr << "select timeout at frame=" << frame_id << "\n";
            break;
        }

        v4l2_buffer buf {};
        v4l2_plane planes[VIDEO_MAX_PLANES] {};
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.length = 1;
        buf.m.planes = planes;

        if (xioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EAGAIN) {
                --frame_id;
                continue;
            }
            std::cerr << "VIDIOC_DQBUF failed at frame=" << frame_id
                      << " " << strerror(errno) << "\n";
            break;
        }

        int64_t dq_ns = now_monotonic_ns();
        int64_t v4l2_ts_ns = timeval_to_ns(buf.timestamp);

        if (first_v4l2_ts_ns < 0) first_v4l2_ts_ns = v4l2_ts_ns;
        if (first_dqbuf_ns < 0) first_dqbuf_ns = dq_ns;

        double diff_ms = (double)(dq_ns - v4l2_ts_ns) / 1000000.0;

        csv << frame_id << ","
            << dq_ns << ","
            << v4l2_ts_ns << ","
            << timestamp_flag_name(buf.flags) << ","
            << std::fixed << std::setprecision(3) << diff_ms << ","
            << buf.sequence << ","
            << buf.index << ","
            << planes[0].bytesused << ","
            << buf.flags << "\n";

        if (frame_id % 30 == 0) {
            std::cout << "frame=" << frame_id
                      << " seq=" << buf.sequence
                      << " idx=" << buf.index
                      << " v4l2_ts_ns=" << v4l2_ts_ns
                      << " dq_minus_v4l2_ms=" << std::fixed << std::setprecision(3) << diff_ms
                      << " type=" << timestamp_flag_name(buf.flags)
                      << "\n";
        }

        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            std::cerr << "VIDIOC_QBUF requeue failed at frame=" << frame_id
                      << " " << strerror(errno) << "\n";
            break;
        }
    }

    xioctl(fd, VIDIOC_STREAMOFF, &type);

    for (auto& b : buffers) {
        if (b.start && b.start != MAP_FAILED) {
            munmap(b.start, b.length);
        }
    }

    close(fd);
    csv.close();

    std::cout << "video timestamp csv: " << csv_path << "\n";
    return 0;
}

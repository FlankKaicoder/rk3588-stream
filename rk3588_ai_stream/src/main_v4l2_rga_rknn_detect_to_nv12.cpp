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
#include <fstream>
#include <iomanip>

#include "yolo11.h"
#include "image_utils.h"
#include "file_utils.h"

#include <opencv2/opencv.hpp>

#include "im2d.hpp"
#include "RgaUtils.h"

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

static const unsigned char colors[19][3] = {
    {54, 67, 244},
    {99, 30, 233},
    {176, 39, 156},
    {183, 58, 103},
    {181, 81, 63},
    {243, 150, 33},
    {244, 169, 3},
    {212, 188, 0},
    {136, 150, 0},
    {80, 175, 76},
    {74, 195, 139},
    {57, 220, 205},
    {59, 235, 255},
    {7, 193, 255},
    {0, 152, 255},
    {34, 87, 255},
    {72, 85, 121},
    {158, 158, 158},
    {139, 125, 96}
};

static void draw_detections_on_rgb(cv::Mat& rgb,
                                   const object_detect_result_list& od_results,
                                   int frame_id)
{
    char text[256];

    for (int i = 0; i < od_results.count; i++) {
        const unsigned char* color = colors[i % 19];

        /*
         * 注意：
         * 这里的 Mat 内存实际是 RGB，不是 OpenCV 默认 BGR。
         * cv::Scalar 只是按内存通道写入，所以这里传入近似 RGB 顺序即可。
         */
        cv::Scalar box_color(color[2], color[1], color[0]);

        const object_detect_result* det = &(od_results.results[i]);

        printf("frame=%d %s @ (%d %d %d %d) %.3f\n",
               frame_id,
               coco_cls_to_name(det->cls_id),
               det->box.left,
               det->box.top,
               det->box.right,
               det->box.bottom,
               det->prop);

        int x1 = det->box.left;
        int y1 = det->box.top;
        int x2 = det->box.right;
        int y2 = det->box.bottom;

        if (x1 < 0) x1 = 0;
        if (y1 < 0) y1 = 0;
        if (x2 > rgb.cols - 1) x2 = rgb.cols - 1;
        if (y2 > rgb.rows - 1) y2 = rgb.rows - 1;

        if (x2 <= x1 || y2 <= y1) {
            continue;
        }

        cv::rectangle(rgb,
                      cv::Rect(cv::Point(x1, y1), cv::Point(x2, y2)),
                      box_color,
                      2);

        snprintf(text,
                 sizeof(text),
                 "%s %.1f%%",
                 coco_cls_to_name(det->cls_id),
                 det->prop * 100.0f);

        int baseLine = 0;
        cv::Size label_size = cv::getTextSize(text,
                                              cv::FONT_HERSHEY_SIMPLEX,
                                              0.5,
                                              1,
                                              &baseLine);

        int tx = x1;
        int ty = y1 - label_size.height - baseLine;

        if (ty < 0) {
            ty = 0;
        }

        if (tx + label_size.width > rgb.cols) {
            tx = rgb.cols - label_size.width;
        }

        if (tx < 0) {
            tx = 0;
        }

        cv::rectangle(rgb,
                      cv::Rect(cv::Point(tx, ty),
                               cv::Size(label_size.width, label_size.height + baseLine)),
                      box_color,
                      -1);

        cv::putText(rgb,
                    text,
                    cv::Point(tx, ty + label_size.height),
                    cv::FONT_HERSHEY_SIMPLEX,
                    0.5,
                    cv::Scalar(255, 255, 255),
                    1);
    }
}

static bool save_rgb_debug_jpg(const char* path, const unsigned char* rgb_data, int width, int height)
{
    cv::Mat rgb(height, width, CV_8UC3, const_cast<unsigned char*>(rgb_data));
    cv::Mat bgr;
    cv::cvtColor(rgb, bgr, cv::COLOR_RGB2BGR);
    return cv::imwrite(path, bgr);
}

int main(int argc, char** argv)
{
    if (argc != 8) {
        printf("Usage: %s <model_path> <video_dev> <width> <height> <frames> <out_nv12_or_fifo> <profile_csv>\n", argv[0]);
        printf("Example: %s models/yolo11.rknn /dev/video11 1280 720 120 output/exp08_3_detect_fifo_mpp/live_detect_nv12.fifo output/exp08_3_detect_fifo_mpp/profile.csv\n", argv[0]);
        return -1;
    }

    const char* model_path = argv[1];
    const char* dev_name = argv[2];
    int width = atoi(argv[3]);
    int height = atoi(argv[4]);
    int frames = atoi(argv[5]);
    const char* out_path = argv[6];
    const char* profile_csv_path = argv[7];

    const size_t nv12_size = (size_t)width * height * 3 / 2;
    const size_t rgb_size = (size_t)width * height * 3;

    printf("model      : %s\n", model_path);
    printf("video dev  : %s\n", dev_name);
    printf("width      : %d\n", width);
    printf("height     : %d\n", height);
    printf("frames     : %d\n", frames);
    printf("out nv12   : %s\n", out_path);
    printf("profile csv: %s\n", profile_csv_path);
    printf("nv12 size  : %zu\n", nv12_size);
    printf("rgb size   : %zu\n", rgb_size);

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

    std::ofstream profile_csv(profile_csv_path);
    if (!profile_csv.is_open()) {
        printf("ERROR: could not open profile csv: %s\n", profile_csv_path);
        fclose(fout);
        close(fd);
        return -1;
    }

    profile_csv << std::fixed << std::setprecision(3);
    profile_csv << "frame_id,"
                << "select_ms,"
                << "dqbuf_ms,"
                << "rga_nv12_to_rgb_ms,"
                << "input_prepare_ms,"
                << "model_total_ms,"
                << "draw_ms,"
                << "rga_rgb_to_nv12_ms,"
                << "write_ms,"
                << "qbuf_ms,"
                << "total_ms,"
                << "fps,"
                << "detect_count"
                << std::endl;

    std::vector<unsigned char> rgb_buf(rgb_size);
    std::vector<unsigned char> out_nv12_buf(nv12_size);

    int ret = 0;
    rknn_app_context_t rknn_app_ctx;
    memset(&rknn_app_ctx, 0, sizeof(rknn_app_ctx));

    init_post_process();

    ret = init_yolo11_model(model_path, &rknn_app_ctx);
    if (ret != 0) {
        printf("init_yolo11_model fail! ret=%d model_path=%s\n", ret, model_path);
        deinit_post_process();
        profile_csv.close();
        fclose(fout);
        close(fd);
        return -1;
    }

    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        perror("VIDIOC_STREAMON failed");
        release_yolo11_model(&rknn_app_ctx);
        deinit_post_process();
        profile_csv.close();
        fclose(fout);
        close(fd);
        return -1;
    }

    double sum_select_ms = 0.0;
    double sum_dqbuf_ms = 0.0;
    double sum_rga_nv12_to_rgb_ms = 0.0;
    double sum_input_prepare_ms = 0.0;
    double sum_model_total_ms = 0.0;
    double sum_draw_ms = 0.0;
    double sum_rga_rgb_to_nv12_ms = 0.0;
    double sum_write_ms = 0.0;
    double sum_qbuf_ms = 0.0;
    double sum_total_ms = 0.0;

    auto wall_start = std::chrono::steady_clock::now();

    int actual_frames = 0;

    for (int frame_id = 0; frame_id < frames; ++frame_id) {
        auto t_total0 = std::chrono::steady_clock::now();

        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);

        timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;

        auto t_select0 = std::chrono::steady_clock::now();
        int sret = select(fd + 1, &fds, NULL, NULL, &tv);
        auto t_select1 = std::chrono::steady_clock::now();

        if (sret < 0) {
            perror("select failed");
            break;
        }

        if (sret == 0) {
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

        unsigned char* nv12_in = (unsigned char*)buffers[buf.index].start;

        auto t_rga_in0 = std::chrono::steady_clock::now();

        rga_buffer_t rga_src_nv12 = wrapbuffer_virtualaddr((void*)nv12_in,
                                                           width,
                                                           height,
                                                           RK_FORMAT_YCbCr_420_SP);

        rga_buffer_t rga_dst_rgb = wrapbuffer_virtualaddr((void*)rgb_buf.data(),
                                                          width,
                                                          height,
                                                          RK_FORMAT_RGB_888);

        IM_STATUS rga_status = imcvtcolor(rga_src_nv12,
                                          rga_dst_rgb,
                                          RK_FORMAT_YCbCr_420_SP,
                                          RK_FORMAT_RGB_888);

        auto t_rga_in1 = std::chrono::steady_clock::now();

        if (rga_status != IM_STATUS_SUCCESS) {
            printf("RGA NV12->RGB failed at frame=%d status=%d %s\n",
                   frame_id,
                   rga_status,
                   imStrError(rga_status));
            xioctl(fd, VIDIOC_QBUF, &buf);
            break;
        }

        auto t_prepare0 = std::chrono::steady_clock::now();

        image_buffer_t src_image;
        memset(&src_image, 0, sizeof(src_image));

        src_image.width = width;
        src_image.height = height;
        src_image.format = IMAGE_FORMAT_RGB888;
        src_image.virt_addr = rgb_buf.data();
        src_image.size = rgb_size;

        object_detect_result_list od_results;
        memset(&od_results, 0, sizeof(od_results));

        auto t_prepare1 = std::chrono::steady_clock::now();

        auto t_model0 = std::chrono::steady_clock::now();
        ret = inference_yolo11_model(&rknn_app_ctx, &src_image, &od_results);
        auto t_model1 = std::chrono::steady_clock::now();

        if (ret != 0) {
            printf("inference_yolo11_model fail! ret=%d frame=%d\n", ret, frame_id);
            xioctl(fd, VIDIOC_QBUF, &buf);
            break;
        }

        auto t_draw0 = std::chrono::steady_clock::now();

        cv::Mat rgb_mat(height, width, CV_8UC3, rgb_buf.data());
        draw_detections_on_rgb(rgb_mat, od_results, frame_id);

        if (frame_id == 0) {
            save_rgb_debug_jpg("output/exp08_3_detect_fifo_mpp/debug_first_rgb_detect.jpg",
                               rgb_buf.data(),
                               width,
                               height);
        }

        auto t_draw1 = std::chrono::steady_clock::now();

        auto t_rga_out0 = std::chrono::steady_clock::now();

        rga_buffer_t rga_src_rgb = wrapbuffer_virtualaddr((void*)rgb_buf.data(),
                                                          width,
                                                          height,
                                                          RK_FORMAT_RGB_888);

        rga_buffer_t rga_dst_nv12 = wrapbuffer_virtualaddr((void*)out_nv12_buf.data(),
                                                           width,
                                                           height,
                                                           RK_FORMAT_YCbCr_420_SP);

        rga_status = imcvtcolor(rga_src_rgb,
                                rga_dst_nv12,
                                RK_FORMAT_RGB_888,
                                RK_FORMAT_YCbCr_420_SP);

        auto t_rga_out1 = std::chrono::steady_clock::now();

        if (rga_status != IM_STATUS_SUCCESS) {
            printf("RGA RGB->NV12 failed at frame=%d status=%d %s\n",
                   frame_id,
                   rga_status,
                   imStrError(rga_status));
            xioctl(fd, VIDIOC_QBUF, &buf);
            break;
        }

        auto t_write0 = std::chrono::steady_clock::now();
        size_t written = fwrite(out_nv12_buf.data(), 1, nv12_size, fout);
        fflush(fout);
        auto t_write1 = std::chrono::steady_clock::now();

        if (written != nv12_size) {
            printf("short write frame=%d written=%zu expected=%zu\n",
                   frame_id, written, nv12_size);
            xioctl(fd, VIDIOC_QBUF, &buf);
            break;
        }

        auto t_q0 = std::chrono::steady_clock::now();
        if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            perror("VIDIOC_QBUF requeue failed");
            break;
        }
        auto t_q1 = std::chrono::steady_clock::now();

        auto t_total1 = std::chrono::steady_clock::now();

        double select_ms = diff_ms(t_select0, t_select1);
        double dqbuf_ms = diff_ms(t_dq0, t_dq1);
        double rga_in_ms = diff_ms(t_rga_in0, t_rga_in1);
        double prepare_ms = diff_ms(t_prepare0, t_prepare1);
        double model_ms = diff_ms(t_model0, t_model1);
        double draw_ms = diff_ms(t_draw0, t_draw1);
        double rga_out_ms = diff_ms(t_rga_out0, t_rga_out1);
        double write_ms = diff_ms(t_write0, t_write1);
        double qbuf_ms = diff_ms(t_q0, t_q1);
        double total_ms = diff_ms(t_total0, t_total1);
        double fps = total_ms > 0.0 ? 1000.0 / total_ms : 0.0;

        sum_select_ms += select_ms;
        sum_dqbuf_ms += dqbuf_ms;
        sum_rga_nv12_to_rgb_ms += rga_in_ms;
        sum_input_prepare_ms += prepare_ms;
        sum_model_total_ms += model_ms;
        sum_draw_ms += draw_ms;
        sum_rga_rgb_to_nv12_ms += rga_out_ms;
        sum_write_ms += write_ms;
        sum_qbuf_ms += qbuf_ms;
        sum_total_ms += total_ms;

        actual_frames++;

        profile_csv << frame_id << ","
                    << select_ms << ","
                    << dqbuf_ms << ","
                    << rga_in_ms << ","
                    << prepare_ms << ","
                    << model_ms << ","
                    << draw_ms << ","
                    << rga_out_ms << ","
                    << write_ms << ","
                    << qbuf_ms << ","
                    << total_ms << ","
                    << fps << ","
                    << od_results.count
                    << std::endl;

        if (frame_id % 30 == 0) {
            printf("frame=%d total=%.3f fps=%.3f rga_in=%.3f model=%.3f draw=%.3f rga_out=%.3f write=%.3f det=%d\n",
                   frame_id,
                   total_ms,
                   fps,
                   rga_in_ms,
                   model_ms,
                   draw_ms,
                   rga_out_ms,
                   write_ms,
                   od_results.count);
        }
    }

    auto wall_end = std::chrono::steady_clock::now();
    double wall_ms = diff_ms(wall_start, wall_end);

    xioctl(fd, VIDIOC_STREAMOFF, &type);

    release_yolo11_model(&rknn_app_ctx);
    deinit_post_process();

    profile_csv.close();
    fclose(fout);

    for (auto& b : buffers) {
        if (b.start && b.start != MAP_FAILED) {
            munmap(b.start, b.length);
        }
    }

    close(fd);

    if (actual_frames <= 0) {
        actual_frames = 1;
    }

    printf("\n========== 08-3 detect to nv12 result ==========\n");
    printf("frames              : %d\n", actual_frames);
    printf("wall_time_ms        : %.3f\n", wall_ms);
    printf("wall_fps            : %.3f\n", actual_frames * 1000.0 / wall_ms);
    printf("avg_select_ms       : %.3f\n", sum_select_ms / actual_frames);
    printf("avg_dqbuf_ms        : %.3f\n", sum_dqbuf_ms / actual_frames);
    printf("avg_rga_nv12_to_rgb : %.3f\n", sum_rga_nv12_to_rgb_ms / actual_frames);
    printf("avg_input_prepare   : %.3f\n", sum_input_prepare_ms / actual_frames);
    printf("avg_model_total_ms  : %.3f\n", sum_model_total_ms / actual_frames);
    printf("avg_draw_ms         : %.3f\n", sum_draw_ms / actual_frames);
    printf("avg_rga_rgb_to_nv12 : %.3f\n", sum_rga_rgb_to_nv12_ms / actual_frames);
    printf("avg_write_ms        : %.3f\n", sum_write_ms / actual_frames);
    printf("avg_qbuf_ms         : %.3f\n", sum_qbuf_ms / actual_frames);
    printf("avg_total_ms        : %.3f\n", sum_total_ms / actual_frames);
    printf("profile csv         : %s\n", profile_csv_path);
    printf("output nv12/fifo    : %s\n", out_path);
    printf("debug jpg           : output/exp08_3_detect_fifo_mpp/debug_first_rgb_detect.jpg\n");
    printf("================================================\n");

    return 0;
}

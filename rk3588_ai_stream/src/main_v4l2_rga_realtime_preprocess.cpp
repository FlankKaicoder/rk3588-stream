#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <vector>
#include <chrono>

#include "v4l2_mplane_capture.hpp"

#include "im2d.hpp"
#include "RgaUtils.h"

static int rga_nv12_to_rgb(unsigned char *nv12,
                           unsigned char *rgb,
                           int width,
                           int height)
{
    rga_buffer_t src = wrapbuffer_virtualaddr((void *)nv12,
                                              width,
                                              height,
                                              RK_FORMAT_YCbCr_420_SP);

    rga_buffer_t dst = wrapbuffer_virtualaddr((void *)rgb,
                                              width,
                                              height,
                                              RK_FORMAT_RGB_888);

    IM_STATUS status = imcvtcolor(src,
                                  dst,
                                  RK_FORMAT_YCbCr_420_SP,
                                  RK_FORMAT_RGB_888);

    if (status != IM_STATUS_SUCCESS)
    {
        printf("RGA imcvtcolor failed: %s\n", imStrError(status));
        return -1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 7)
    {
        printf("Usage: %s <video_device> <width> <height> <frames> <profile_csv> <last_rgb_raw>\n", argv[0]);
        printf("Example: %s /dev/video11 1280 720 120 output/exp05_v4l2_rga_realtime/profile.csv output/exp05_v4l2_rga_realtime/last.rgb\n", argv[0]);
        return -1;
    }

    const char *dev = argv[1];
    int width = atoi(argv[2]);
    int height = atoi(argv[3]);
    int max_frames = atoi(argv[4]);
    const char *csv_path = argv[5];
    const char *last_rgb_path = argv[6];

    if (width <= 0 || height <= 0 || max_frames <= 0)
    {
        printf("invalid width / height / frames\n");
        return -1;
    }

    printf("========== 05 V4L2 + RGA realtime preprocess ==========\n");
    printf("device    : %s\n", dev);
    printf("size      : %dx%d\n", width, height);
    printf("frames    : %d\n", max_frames);
    printf("csv       : %s\n", csv_path);
    printf("last rgb  : %s\n", last_rgb_path);

    V4L2MPlaneCapture cap;
    if (!cap.open_device(dev, width, height, 30, 4))
    {
        printf("open_device failed\n");
        return -1;
    }

    width = cap.width();
    height = cap.height();

    size_t rgb_size = static_cast<size_t>(width) * height * 3;
    std::vector<unsigned char> rgb(rgb_size);

    std::ofstream csv(csv_path);
    if (!csv.is_open())
    {
        printf("open csv failed: %s\n", csv_path);
        return -1;
    }

    csv << std::fixed << std::setprecision(3);
    csv << "frame_id,select_ms,dqbuf_ms,rga_ms,qbuf_ms,total_ms,fps,bytesused\n";

    double sum_select = 0.0;
    double sum_dqbuf = 0.0;
    double sum_rga = 0.0;
    double sum_qbuf = 0.0;
    double sum_total = 0.0;

    auto t_wall0 = std::chrono::steady_clock::now();

    int count = 0;

    for (int i = 0; i < max_frames; ++i)
    {
        auto t_total0 = std::chrono::steady_clock::now();

        V4L2MPlaneCapture::Frame frame;
        double select_ms = 0.0;
        double dqbuf_ms = 0.0;

        if (!cap.dequeue_frame(frame, select_ms, dqbuf_ms))
        {
            printf("dequeue_frame failed at frame=%d\n", i);
            break;
        }

        if (frame.bytesused < cap.image_size())
        {
            printf("WARN: frame=%d bytesused=%zu expected=%zu\n",
                   i,
                   frame.bytesused,
                   cap.image_size());
        }

        auto t_rga0 = std::chrono::steady_clock::now();
        int ret = rga_nv12_to_rgb(frame.data, rgb.data(), width, height);
        auto t_rga1 = std::chrono::steady_clock::now();

        if (ret != 0)
        {
            printf("rga_nv12_to_rgb failed at frame=%d\n", i);
            cap.requeue_frame(frame);
            break;
        }

        double rga_ms = time_diff_ms(t_rga0, t_rga1);

        auto t_qbuf0 = std::chrono::steady_clock::now();
        cap.requeue_frame(frame);
        auto t_qbuf1 = std::chrono::steady_clock::now();

        double qbuf_ms = time_diff_ms(t_qbuf0, t_qbuf1);

        auto t_total1 = std::chrono::steady_clock::now();
        double total_ms = time_diff_ms(t_total0, t_total1);
        double fps = total_ms > 0.0 ? 1000.0 / total_ms : 0.0;

        csv << i << ","
            << select_ms << ","
            << dqbuf_ms << ","
            << rga_ms << ","
            << qbuf_ms << ","
            << total_ms << ","
            << fps << ","
            << frame.bytesused << "\n";

        sum_select += select_ms;
        sum_dqbuf += dqbuf_ms;
        sum_rga += rga_ms;
        sum_qbuf += qbuf_ms;
        sum_total += total_ms;

        count++;

        if (count % 30 == 0)
        {
            double n = static_cast<double>(count);
            double avg_total = sum_total / n;
            double avg_fps = avg_total > 0.0 ? 1000.0 / avg_total : 0.0;

            printf("\n========== 05 avg ==========\n");
            printf("frames    : %d\n", count);
            printf("select_ms : %.3f\n", sum_select / n);
            printf("dqbuf_ms  : %.3f\n", sum_dqbuf / n);
            printf("rga_ms    : %.3f\n", sum_rga / n);
            printf("qbuf_ms   : %.3f\n", sum_qbuf / n);
            printf("total_ms  : %.3f\n", avg_total);
            printf("avg_fps   : %.3f\n", avg_fps);
            printf("============================\n");
        }
    }

    auto t_wall1 = std::chrono::steady_clock::now();
    double wall_ms = time_diff_ms(t_wall0, t_wall1);
    double wall_fps = wall_ms > 0.0 ? count * 1000.0 / wall_ms : 0.0;

    printf("\n========== 05 final ==========\n");
    printf("frames       : %d\n", count);
    printf("wall_time_ms : %.3f\n", wall_ms);
    printf("wall_fps     : %.3f\n", wall_fps);

    if (count > 0)
    {
        double n = static_cast<double>(count);
        printf("avg_select_ms: %.3f\n", sum_select / n);
        printf("avg_dqbuf_ms : %.3f\n", sum_dqbuf / n);
        printf("avg_rga_ms   : %.3f\n", sum_rga / n);
        printf("avg_qbuf_ms  : %.3f\n", sum_qbuf / n);
        printf("avg_total_ms : %.3f\n", sum_total / n);
    }

    FILE *fp = fopen(last_rgb_path, "wb");
    if (fp)
    {
        fwrite(rgb.data(), 1, rgb.size(), fp);
        fclose(fp);
        printf("write last rgb success: %s\n", last_rgb_path);
    }
    else
    {
        printf("WARN: write last rgb failed: %s\n", last_rgb_path);
    }

    printf("csv saved: %s\n", csv_path);
    printf("================================\n");

    return 0;
}

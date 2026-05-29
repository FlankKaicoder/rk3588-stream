#include <opencv2/opencv.hpp>

#include <chrono>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool is_number_string(const char *s)
{
    if (s == NULL || *s == '\0')
    {
        return false;
    }

    for (const char *p = s; *p; ++p)
    {
        if (!isdigit(*p))
        {
            return false;
        }
    }

    return true;
}

static inline double diff_ms(const std::chrono::steady_clock::time_point &start,
                             const std::chrono::steady_clock::time_point &end)
{
    return std::chrono::duration<double, std::milli>(end - start).count();
}

static int fourcc_from_string(const char *s)
{
    if (s == NULL || strlen(s) != 4)
    {
        return 0;
    }

    return cv::VideoWriter::fourcc(s[0], s[1], s[2], s[3]);
}

int main(int argc, char **argv)
{
    if (argc != 2 && argc != 6 && argc != 7)
    {
        printf("Usage:\n");
        printf("  %s <camera_index_or_device_path>\n", argv[0]);
        printf("  %s <camera_index_or_device_path> <width> <height> <fps> <fourcc> [max_frames]\n", argv[0]);
        printf("\n");
        printf("Examples:\n");
        printf("  %s 11\n", argv[0]);
        printf("  %s /dev/video11 1280 720 30 MJPG 120\n", argv[0]);
        printf("  %s /dev/video11 1920 1080 30 YUYV 120\n", argv[0]);
        printf("  %s /dev/video11 1280 720 30 NV12 120\n", argv[0]);
        return -1;
    }

    const char *camera_source = argv[1];

    int req_width = 0;
    int req_height = 0;
    int req_fps = 0;
    const char *req_fourcc_str = NULL;
    int max_frames = 120;

    if (argc >= 6)
    {
        req_width = atoi(argv[2]);
        req_height = atoi(argv[3]);
        req_fps = atoi(argv[4]);
        req_fourcc_str = argv[5];
    }

    if (argc == 7)
    {
        max_frames = atoi(argv[6]);
        if (max_frames <= 0)
        {
            max_frames = 120;
        }
    }

    printf("camera source : %s\n", camera_source);
    printf("max frames    : %d\n", max_frames);

    cv::VideoCapture cap;

    if (is_number_string(camera_source))
    {
        int camera_index = atoi(camera_source);
        printf("open camera by index: %d\n", camera_index);
        cap.open(camera_index);
    }
    else
    {
        printf("open camera by path: %s\n", camera_source);
        cap.open(camera_source);
    }

    if (!cap.isOpened())
    {
        printf("Error: Could not open camera source: %s\n", camera_source);
        return -1;
    }

    if (argc >= 6)
    {
        int fourcc = fourcc_from_string(req_fourcc_str);

        printf("\nrequest settings:\n");
        printf("  width : %d\n", req_width);
        printf("  height: %d\n", req_height);
        printf("  fps   : %d\n", req_fps);
        printf("  fourcc: %s\n", req_fourcc_str);

        if (fourcc != 0)
        {
            cap.set(cv::CAP_PROP_FOURCC, fourcc);
        }

        if (req_width > 0)
        {
            cap.set(cv::CAP_PROP_FRAME_WIDTH, req_width);
        }

        if (req_height > 0)
        {
            cap.set(cv::CAP_PROP_FRAME_HEIGHT, req_height);
        }

        if (req_fps > 0)
        {
            cap.set(cv::CAP_PROP_FPS, req_fps);
        }
    }

    double actual_width = cap.get(cv::CAP_PROP_FRAME_WIDTH);
    double actual_height = cap.get(cv::CAP_PROP_FRAME_HEIGHT);
    double actual_fps = cap.get(cv::CAP_PROP_FPS);
    int actual_fourcc = static_cast<int>(cap.get(cv::CAP_PROP_FOURCC));

    char fourcc_chars[5] = {0};
    fourcc_chars[0] = actual_fourcc & 0xFF;
    fourcc_chars[1] = (actual_fourcc >> 8) & 0xFF;
    fourcc_chars[2] = (actual_fourcc >> 16) & 0xFF;
    fourcc_chars[3] = (actual_fourcc >> 24) & 0xFF;

    printf("\nactual settings after open/set:\n");
    printf("  width : %.0f\n", actual_width);
    printf("  height: %.0f\n", actual_height);
    printf("  fps   : %.2f\n", actual_fps);
    printf("  fourcc: %s\n", fourcc_chars);
    printf("\n");

    cv::Mat frame;

    double sum_read_ms = 0.0;
    double min_read_ms = 1e9;
    double max_read_ms = 0.0;

    auto t_all_start = std::chrono::steady_clock::now();

    for (int i = 0; i < max_frames; i++)
    {
        auto t0 = std::chrono::steady_clock::now();
        bool ok = cap.read(frame);
        auto t1 = std::chrono::steady_clock::now();

        double read_ms = diff_ms(t0, t1);

        if (!ok || frame.empty())
        {
            printf("read failed or empty frame at i=%d\n", i);
            break;
        }

        sum_read_ms += read_ms;
        if (read_ms < min_read_ms) min_read_ms = read_ms;
        if (read_ms > max_read_ms) max_read_ms = read_ms;

        if (i < 10 || (i + 1) % 30 == 0)
        {
            printf("frame=%d read_ms=%.3f shape=%dx%dx%d\n",
                   i,
                   read_ms,
                   frame.cols,
                   frame.rows,
                   frame.channels());
        }
    }

    auto t_all_end = std::chrono::steady_clock::now();
    double total_wall_ms = diff_ms(t_all_start, t_all_end);

    double n = static_cast<double>(max_frames);
    double avg_read_ms = sum_read_ms / n;
    double read_fps = avg_read_ms > 0.0 ? 1000.0 / avg_read_ms : 0.0;
    double wall_fps = total_wall_ms > 0.0 ? 1000.0 * n / total_wall_ms : 0.0;

    printf("\n========== 04-2 camera capture profile ==========\n");
    printf("frames       : %d\n", max_frames);
    printf("avg_read_ms  : %.3f\n", avg_read_ms);
    printf("min_read_ms  : %.3f\n", min_read_ms);
    printf("max_read_ms  : %.3f\n", max_read_ms);
    printf("read_fps     : %.3f\n", read_fps);
    printf("wall_time_ms : %.3f\n", total_wall_ms);
    printf("wall_fps     : %.3f\n", wall_fps);
    printf("last shape   : %dx%dx%d\n", frame.cols, frame.rows, frame.channels());
    printf("=================================================\n");

    cap.release();

    return 0;
}

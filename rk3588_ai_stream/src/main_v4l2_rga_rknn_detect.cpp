#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <vector>
#include <chrono>
#include <string>

#include "v4l2_mplane_capture.hpp"

#include "im2d.hpp"
#include "RgaUtils.h"

#include "yolo11.h"
#include "image_utils.h"
#include "image_drawing.h"
#include "file_utils.h"

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

static void draw_results_to_rgb(image_buffer_t *img,
                                const object_detect_result_list *results,
                                int frame_id)
{
    char text[256];

    for (int i = 0; i < results->count; ++i)
    {
        const object_detect_result *det = &results->results[i];

        int x1 = det->box.left;
        int y1 = det->box.top;
        int x2 = det->box.right;
        int y2 = det->box.bottom;

        if (x1 < 0) x1 = 0;
        if (y1 < 0) y1 = 0;
        if (x2 > img->width - 1) x2 = img->width - 1;
        if (y2 > img->height - 1) y2 = img->height - 1;

        if (x2 <= x1 || y2 <= y1)
        {
            continue;
        }

        printf("frame=%d %s @ (%d %d %d %d) %.3f\n",
               frame_id,
               coco_cls_to_name(det->cls_id),
               x1,
               y1,
               x2,
               y2,
               det->prop);

        draw_rectangle(img, x1, y1, x2 - x1, y2 - y1, COLOR_BLUE, 3);

        snprintf(text,
                 sizeof(text),
                 "%s %.1f%%",
                 coco_cls_to_name(det->cls_id),
                 det->prop * 100.0f);

        int text_y = y1 - 20;
        if (text_y < 0) text_y = y1 + 10;

        draw_text(img, text, x1, text_y, COLOR_RED, 10);
    }
}

int main(int argc, char **argv)
{
    if (argc != 9)
    {
        printf("Usage: %s <model_path> <video_device> <width> <height> <frames> <profile_csv> <snapshot_dir> <snapshot_interval>\n", argv[0]);
        printf("Example: %s models/yolo11.rknn /dev/video11 1280 720 120 output/exp06_v4l2_rga_rknn/profile.csv output/exp06_v4l2_rga_rknn 30\n", argv[0]);
        return -1;
    }

    const char *model_path = argv[1];
    const char *dev = argv[2];
    int width = atoi(argv[3]);
    int height = atoi(argv[4]);
    int max_frames = atoi(argv[5]);
    const char *csv_path = argv[6];
    const char *snapshot_dir = argv[7];
    int snapshot_interval = atoi(argv[8]);

    if (width <= 0 || height <= 0 || max_frames <= 0)
    {
        printf("invalid width / height / frames\n");
        return -1;
    }

    if (snapshot_interval <= 0)
    {
        snapshot_interval = 30;
    }

    printf("========== 06 V4L2 + RGA + RKNN detect ==========\n");
    printf("model     : %s\n", model_path);
    printf("device    : %s\n", dev);
    printf("size      : %dx%d\n", width, height);
    printf("frames    : %d\n", max_frames);
    printf("csv       : %s\n", csv_path);
    printf("snap dir  : %s\n", snapshot_dir);
    printf("snap intv : %d\n", snapshot_interval);

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
    csv << "frame_id,select_ms,dqbuf_ms,rga_ms,input_prepare_ms,model_total_ms,draw_ms,snapshot_ms,qbuf_ms,total_ms,fps,detect_count,bytesused\n";

    int ret = 0;

    rknn_app_context_t rknn_app_ctx;
    memset(&rknn_app_ctx, 0, sizeof(rknn_app_ctx));

    init_post_process();

    ret = init_yolo11_model(model_path, &rknn_app_ctx);
    if (ret != 0)
    {
        printf("init_yolo11_model failed: ret=%d model=%s\n", ret, model_path);
        deinit_post_process();
        return -1;
    }

    double sum_select = 0.0;
    double sum_dqbuf = 0.0;
    double sum_rga = 0.0;
    double sum_input_prepare = 0.0;
    double sum_model = 0.0;
    double sum_draw = 0.0;
    double sum_snapshot = 0.0;
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

        auto t_rga0 = std::chrono::steady_clock::now();
        ret = rga_nv12_to_rgb(frame.data, rgb.data(), width, height);
        auto t_rga1 = std::chrono::steady_clock::now();

        if (ret != 0)
        {
            printf("rga_nv12_to_rgb failed at frame=%d\n", i);
            cap.requeue_frame(frame);
            break;
        }

        double rga_ms = time_diff_ms(t_rga0, t_rga1);

        auto t_input0 = std::chrono::steady_clock::now();

        image_buffer_t src_image;
        memset(&src_image, 0, sizeof(src_image));
        src_image.width = width;
        src_image.height = height;
        src_image.format = IMAGE_FORMAT_RGB888;
        src_image.virt_addr = rgb.data();
        src_image.size = rgb.size();

        object_detect_result_list od_results;
        memset(&od_results, 0, sizeof(od_results));

        auto t_input1 = std::chrono::steady_clock::now();
        double input_prepare_ms = time_diff_ms(t_input0, t_input1);

        auto t_model0 = std::chrono::steady_clock::now();
        ret = inference_yolo11_model(&rknn_app_ctx, &src_image, &od_results);
        auto t_model1 = std::chrono::steady_clock::now();

        if (ret != 0)
        {
            printf("inference_yolo11_model failed: ret=%d frame=%d\n", ret, i);
            cap.requeue_frame(frame);
            break;
        }

        double model_total_ms = time_diff_ms(t_model0, t_model1);

        auto t_draw0 = std::chrono::steady_clock::now();
        draw_results_to_rgb(&src_image, &od_results, i);
        auto t_draw1 = std::chrono::steady_clock::now();
        double draw_ms = time_diff_ms(t_draw0, t_draw1);

        double snapshot_ms = 0.0;
        if (i % snapshot_interval == 0)
        {
            char snapshot_path[512];
            snprintf(snapshot_path,
                     sizeof(snapshot_path),
                     "%s/frame_%06d.jpg",
                     snapshot_dir,
                     i);

            auto t_snap0 = std::chrono::steady_clock::now();
            write_image(snapshot_path, &src_image);
            auto t_snap1 = std::chrono::steady_clock::now();

            snapshot_ms = time_diff_ms(t_snap0, t_snap1);
            printf("snapshot saved: %s\n", snapshot_path);
        }

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
            << input_prepare_ms << ","
            << model_total_ms << ","
            << draw_ms << ","
            << snapshot_ms << ","
            << qbuf_ms << ","
            << total_ms << ","
            << fps << ","
            << od_results.count << ","
            << frame.bytesused << "\n";

        sum_select += select_ms;
        sum_dqbuf += dqbuf_ms;
        sum_rga += rga_ms;
        sum_input_prepare += input_prepare_ms;
        sum_model += model_total_ms;
        sum_draw += draw_ms;
        sum_snapshot += snapshot_ms;
        sum_qbuf += qbuf_ms;
        sum_total += total_ms;

        count++;

        if (count % 30 == 0)
        {
            double n = static_cast<double>(count);
            double avg_total = sum_total / n;
            double avg_fps = avg_total > 0.0 ? 1000.0 / avg_total : 0.0;

            printf("\n========== 06 avg ==========\n");
            printf("frames          : %d\n", count);
            printf("select_ms       : %.3f\n", sum_select / n);
            printf("dqbuf_ms        : %.3f\n", sum_dqbuf / n);
            printf("rga_ms          : %.3f\n", sum_rga / n);
            printf("input_prepare_ms: %.3f\n", sum_input_prepare / n);
            printf("model_total_ms  : %.3f\n", sum_model / n);
            printf("draw_ms         : %.3f\n", sum_draw / n);
            printf("snapshot_ms     : %.3f\n", sum_snapshot / n);
            printf("qbuf_ms         : %.3f\n", sum_qbuf / n);
            printf("total_ms        : %.3f\n", avg_total);
            printf("avg_fps         : %.3f\n", avg_fps);
            printf("============================\n");
        }
    }

    auto t_wall1 = std::chrono::steady_clock::now();
    double wall_ms = time_diff_ms(t_wall0, t_wall1);
    double wall_fps = wall_ms > 0.0 ? count * 1000.0 / wall_ms : 0.0;

    printf("\n========== 06 final ==========\n");
    printf("frames       : %d\n", count);
    printf("wall_time_ms : %.3f\n", wall_ms);
    printf("wall_fps     : %.3f\n", wall_fps);

    if (count > 0)
    {
        double n = static_cast<double>(count);
        printf("avg_select_ms       : %.3f\n", sum_select / n);
        printf("avg_dqbuf_ms        : %.3f\n", sum_dqbuf / n);
        printf("avg_rga_ms          : %.3f\n", sum_rga / n);
        printf("avg_input_prepare_ms: %.3f\n", sum_input_prepare / n);
        printf("avg_model_total_ms  : %.3f\n", sum_model / n);
        printf("avg_draw_ms         : %.3f\n", sum_draw / n);
        printf("avg_snapshot_ms     : %.3f\n", sum_snapshot / n);
        printf("avg_qbuf_ms         : %.3f\n", sum_qbuf / n);
        printf("avg_total_ms        : %.3f\n", sum_total / n);
    }

    ret = release_yolo11_model(&rknn_app_ctx);
    if (ret != 0)
    {
        printf("release_yolo11_model failed: ret=%d\n", ret);
    }

    deinit_post_process();

    printf("csv saved: %s\n", csv_path);
    printf("================================\n");

    return 0;
}

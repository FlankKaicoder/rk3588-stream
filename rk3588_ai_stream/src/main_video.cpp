#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "yolo11.h"
#include "image_utils.h"
#include "file_utils.h"

#include <opencv2/opencv.hpp>

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

int main(int argc, char **argv)
{
    if (argc != 4)
    {
        printf("Usage: %s <model_path> <input_video> <output_video>\n", argv[0]);
        printf("Example: %s models/yolo11.rknn input/test.mp4 output/video_result.mp4\n", argv[0]);
        return -1;
    }

    const char *model_path = argv[1];
    const char *input_video_path = argv[2];
    const char *output_video_path = argv[3];

    int ret = 0;

    rknn_app_context_t rknn_app_ctx;
    memset(&rknn_app_ctx, 0, sizeof(rknn_app_ctx));

    cv::VideoCapture cap;
    cap.open(input_video_path);

    if (!cap.isOpened())
    {
        printf("Error: Could not open input video: %s\n", input_video_path);
        return -1;
    }

    int frame_width = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_WIDTH));
    int frame_height = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_HEIGHT));
    double fps = cap.get(cv::CAP_PROP_FPS);
    int total_frames = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_COUNT));

    if (fps <= 0.0 || fps > 120.0)
    {
        fps = 25.0;
    }

    printf("input video : %s\n", input_video_path);
    printf("output video: %s\n", output_video_path);
    printf("video width=%d height=%d fps=%.2f total_frames=%d\n",
           frame_width, frame_height, fps, total_frames);

    cv::VideoWriter writer;
    int fourcc = cv::VideoWriter::fourcc('m', 'p', '4', 'v');

    writer.open(output_video_path,
                fourcc,
                fps,
                cv::Size(frame_width, frame_height),
                true);

    if (!writer.isOpened())
    {
        printf("Error: Could not open output video: %s\n", output_video_path);
        return -1;
    }

    init_post_process();

    ret = init_yolo11_model(model_path, &rknn_app_ctx);
    if (ret != 0)
    {
        printf("init_yolo11_model fail! ret=%d model_path=%s\n", ret, model_path);
        deinit_post_process();
        return -1;
    }

    cv::Mat frame;
    cv::Mat rgb_image;

    int frame_count = 0;

    while (true)
    {
        if (!cap.read(frame))
        {
            printf("cap read frame finished or failed.\n");
            break;
        }

        if (frame.empty())
        {
            printf("empty frame, skip.\n");
            continue;
        }

        cv::cvtColor(frame, rgb_image, cv::COLOR_BGR2RGB);

        image_buffer_t src_image;
        memset(&src_image, 0, sizeof(src_image));

        src_image.width = rgb_image.cols;
        src_image.height = rgb_image.rows;
        src_image.format = IMAGE_FORMAT_RGB888;
        src_image.virt_addr = (unsigned char *)rgb_image.data;
        src_image.size = rgb_image.total() * rgb_image.elemSize();

        object_detect_result_list od_results;
        memset(&od_results, 0, sizeof(od_results));

        ret = inference_yolo11_model(&rknn_app_ctx, &src_image, &od_results);
        if (ret != 0)
        {
            printf("inference_yolo11_model fail! ret=%d frame=%d\n", ret, frame_count);
            break;
        }

        int color_index = 0;
        char text[256];

        for (int i = 0; i < od_results.count; i++)
        {
            const unsigned char *color = colors[color_index % 19];
            cv::Scalar box_color(color[0], color[1], color[2]);
            color_index++;

            object_detect_result *det_result = &(od_results.results[i]);

            printf("frame=%d %s @ (%d %d %d %d) %.3f\n",
                   frame_count,
                   coco_cls_to_name(det_result->cls_id),
                   det_result->box.left,
                   det_result->box.top,
                   det_result->box.right,
                   det_result->box.bottom,
                   det_result->prop);

            int x1 = det_result->box.left;
            int y1 = det_result->box.top;
            int x2 = det_result->box.right;
            int y2 = det_result->box.bottom;

            if (x1 < 0) x1 = 0;
            if (y1 < 0) y1 = 0;
            if (x2 > frame.cols - 1) x2 = frame.cols - 1;
            if (y2 > frame.rows - 1) y2 = frame.rows - 1;

            cv::rectangle(frame,
                          cv::Rect(cv::Point(x1, y1), cv::Point(x2, y2)),
                          box_color,
                          2);

            snprintf(text,
                     sizeof(text),
                     "%s %.1f%%",
                     coco_cls_to_name(det_result->cls_id),
                     det_result->prop * 100.0f);

            int baseLine = 0;
            cv::Size label_size = cv::getTextSize(text,
                                                  cv::FONT_HERSHEY_SIMPLEX,
                                                  0.5,
                                                  1,
                                                  &baseLine);

            int tx = x1;
            int ty = y1 - label_size.height - baseLine;

            if (ty < 0)
            {
                ty = 0;
            }

            if (tx + label_size.width > frame.cols)
            {
                tx = frame.cols - label_size.width;
            }

            cv::rectangle(frame,
                          cv::Rect(cv::Point(tx, ty),
                                   cv::Size(label_size.width, label_size.height + baseLine)),
                          box_color,
                          -1);

            cv::putText(frame,
                        text,
                        cv::Point(tx, ty + label_size.height),
                        cv::FONT_HERSHEY_SIMPLEX,
                        0.5,
                        cv::Scalar(255, 255, 255),
                        1);
        }

        writer.write(frame);

        frame_count++;

        if (frame_count % 30 == 0)
        {
            printf("processed frames: %d\n", frame_count);
        }
    }

    printf("finished. total processed frames: %d\n", frame_count);

    writer.release();
    cap.release();

    ret = release_yolo11_model(&rknn_app_ctx);
    if (ret != 0)
    {
        printf("release_yolo11_model fail! ret=%d\n", ret);
    }

    deinit_post_process();

    return 0;
}

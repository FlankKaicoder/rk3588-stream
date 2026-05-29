#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "yolo11.h"
#include "image_utils.h"
#include "file_utils.h"

#include <opencv2/opencv.hpp>

//BGR2RGB的颜色
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
//判断摄像头参数是数字还是路劲
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
//检测结果绘图逻辑
static void draw_detections(cv::Mat &frame,
                            const object_detect_result_list &od_results,
                            int frame_count)
{
    int color_index = 0;
    char text[256];

    for (int i = 0; i < od_results.count; i++)
    {
        const unsigned char *color = colors[color_index % 19];
        cv::Scalar box_color(color[0], color[1], color[2]);
        color_index++;

        const object_detect_result *det_result = &(od_results.results[i]);

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

        if (x2 <= x1 || y2 <= y1)
        {
            continue;
        }

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

        if (tx < 0)
        {
            tx = 0;
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
}

int main(int argc, char **argv)
{
    if (argc != 4 && argc != 5) //如果用户输入不是四个或者五个参数就提示正确参数类型
    {
        printf("Usage: %s <model_path> <camera_index_or_device_path> <output_video> [max_frames]\n", argv[0]);
        printf("Example 1: %s models/yolo11.rknn 11 output/camera_result.mp4 300\n", argv[0]);
        printf("Example 2: %s models/yolo11.rknn /dev/video11 output/camera_result.mp4 300\n", argv[0]);
        return -1;
    }

    const char *model_path = argv[1];
    const char *camera_source = argv[2];
    const char *output_video_path = argv[3];

    int max_frames = 300;
    if (argc == 5)
    {
        max_frames = atoi(argv[4]);
        if (max_frames <= 0)
        {
            max_frames = 300;
        }
    }

    const int output_width = 1280;
    const int output_height = 720;
    const double output_fps = 25.0;
    //打印参数信息
    printf("model path   : %s\n", model_path);
    printf("camera source: %s\n", camera_source);
    printf("output video : %s\n", output_video_path);
    printf("max frames   : %d\n", max_frames);
    printf("force output : %dx%d %.2f fps\n", output_width, output_height, output_fps);
    //创建视频捕获对象
    cv::VideoCapture cap;
    //判断摄像头是数字还是路劲
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

    double camera_fps = cap.get(cv::CAP_PROP_FPS);
    double camera_width = cap.get(cv::CAP_PROP_FRAME_WIDTH);
    double camera_height = cap.get(cv::CAP_PROP_FRAME_HEIGHT);

    printf("camera reported width=%.0f height=%.0f fps=%.2f\n",
           camera_width,
           camera_height,
           camera_fps);

    cv::VideoWriter writer;
    int fourcc = cv::VideoWriter::fourcc('m', 'p', '4', 'v');

    writer.open(output_video_path,
                fourcc,
                output_fps,
                cv::Size(output_width, output_height),
                true);

    if (!writer.isOpened())
    {
        printf("Error: Could not open output video: %s\n", output_video_path);
        cap.release();
        return -1;
    }
    //初始化AI模型
    int ret = 0;//创建结构体，保存AI上下文环境

    rknn_app_context_t rknn_app_ctx;
    memset(&rknn_app_ctx, 0, sizeof(rknn_app_ctx));
    //初始化后处理模块
    init_post_process();
    //加载模型文件到NPU
    ret = init_yolo11_model(model_path, &rknn_app_ctx);
    if (ret != 0)
    {
        printf("init_yolo11_model fail! ret=%d model_path=%s\n", ret, model_path);
        writer.release();
        cap.release();
        deinit_post_process();
        return -1;
    }

    cv::Mat raw_frame;
    cv::Mat frame_720p;
    cv::Mat rgb_image;

    int frame_count = 0;

    while (frame_count < max_frames)
    {
        if (!cap.read(raw_frame))
        {
            printf("cap read frame finished or failed.\n");
            break;
        }

        if (raw_frame.empty())
        {
            printf("empty frame, skip.\n");
            continue;
        }
        //cpu进行预处理缩放和颜色格式转换等
        cv::resize(raw_frame, frame_720p, cv::Size(output_width, output_height));
        cv::cvtColor(frame_720p, rgb_image, cv::COLOR_BGR2RGB);
        //构建模型输入数据结构
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

        draw_detections(frame_720p, od_results, frame_count);
        //画好的框写道最终的mp4文件中
        writer.write(frame_720p);

        frame_count++;

        if (frame_count % 30 == 0)
        {
            printf("processed frames: %d\n", frame_count);
        }
    }

    printf("finished. total processed frames: %d\n", frame_count);
    printf("expected duration: %.2f seconds\n", frame_count / output_fps);

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

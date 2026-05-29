// Copyright (c) 2024 by Rockchip Electronics Co., Ltd. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//

/*-------------------------------------------
                Includes
-------------------------------------------*/
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "yolo11.h"
#include "image_utils.h"
#include "file_utils.h"
#include "image_drawing.h"

#if defined(RV1106_1103)
#include "dma_alloc.hpp"
#endif

#include <vector>
#include <algorithm>
#include <set>

/*-------------------------------------------
                Config
-------------------------------------------*/
static const int PATCH_W = 1024;
static const int PATCH_H = 1024;
static const int STRIDE_X = 896;
static const int STRIDE_Y = 896;
static const float GLOBAL_NMS_THRESH = 0.35f;
// 可选：过滤 patch 边缘框，第一版可以先设为 0
static const int BORDER_FILTER_MARGIN = 5;

/*-------------------------------------------
                Structs
-------------------------------------------*/
struct WindowInfo
{
    int x;
    int y;
    int w;
    int h;
};

struct GlobalDetectBox
{
    float left;
    float top;
    float right;
    float bottom;
    float score;
    int cls_id;
};

/*-------------------------------------------
                Utils
-------------------------------------------*/
static std::vector<WindowInfo> split_windows(int img_w, int img_h,
                                             int patch_w, int patch_h,
                                             int stride_x, int stride_y)
{
    std::vector<WindowInfo> windows;
    std::set<std::pair<int, int>> added;

    for (int y = 0; y < img_h; y += stride_y)
    {
        for (int x = 0; x < img_w; x += stride_x)
        {
            int cur_x = x;
            int cur_y = y;

            if (cur_x + patch_w > img_w)
                cur_x = std::max(0, img_w - patch_w);
            if (cur_y + patch_h > img_h)
                cur_y = std::max(0, img_h - patch_h);

            if (added.count({cur_x, cur_y}))
                continue;
            added.insert({cur_x, cur_y});

            WindowInfo win;
            win.x = cur_x;
            win.y = cur_y;
            win.w = std::min(patch_w, img_w - cur_x);
            win.h = std::min(patch_h, img_h - cur_y);
            windows.push_back(win);
        }
    }

    return windows;
}

static float calc_iou(const GlobalDetectBox &a, const GlobalDetectBox &b)
{
    float xx1 = std::max(a.left, b.left);
    float yy1 = std::max(a.top, b.top);
    float xx2 = std::min(a.right, b.right);
    float yy2 = std::min(a.bottom, b.bottom);

    float w = std::max(0.0f, xx2 - xx1);
    float h = std::max(0.0f, yy2 - yy1);
    float inter = w * h;

    float area_a = std::max(0.0f, a.right - a.left) * std::max(0.0f, a.bottom - a.top);
    float area_b = std::max(0.0f, b.right - b.left) * std::max(0.0f, b.bottom - b.top);

    return inter / (area_a + area_b - inter + 1e-6f);
}

static std::vector<GlobalDetectBox> global_nms(std::vector<GlobalDetectBox> boxes, float iou_thres)
{
    std::vector<GlobalDetectBox> result;

    std::sort(boxes.begin(), boxes.end(),
              [](const GlobalDetectBox &a, const GlobalDetectBox &b)
              {
                  return a.score > b.score;
              });

    std::vector<int> removed(boxes.size(), 0);

    for (size_t i = 0; i < boxes.size(); ++i)
    {
        if (removed[i])
            continue;

        result.push_back(boxes[i]);

        for (size_t j = i + 1; j < boxes.size(); ++j)
        {
            if (removed[j])
                continue;
            if (boxes[i].cls_id != boxes[j].cls_id)
                continue;

            if (calc_iou(boxes[i], boxes[j]) > iou_thres)
            {
                removed[j] = 1;
            }
        }
    }

    return result;
}

static bool is_near_border(float left, float top, float right, float bottom,
                           int patch_w, int patch_h, int margin)
{
    if (margin <= 0)
        return false;

    if (left < margin || top < margin ||
        right > patch_w - margin || bottom > patch_h - margin)
    {
        return true;
    }
    return false;
}

static void collect_patch_boxes(const object_detect_result_list *patch_results,
                                const WindowInfo &win,
                                std::vector<GlobalDetectBox> &all_boxes)
{
    for (int i = 0; i < patch_results->count; ++i)
    {
        const object_detect_result *det_result = &(patch_results->results[i]);

        float l = det_result->box.left;
        float t = det_result->box.top;
        float r = det_result->box.right;
        float b = det_result->box.bottom;

        // 裁掉超出 patch 有效区域的框
        if (l >= win.w || t >= win.h)
            continue;
        if (r <= 0 || b <= 0)
            continue;

        l = std::max(0.0f, l);
        t = std::max(0.0f, t);
        r = std::min((float)win.w, r);
        b = std::min((float)win.h, b);

        if (r <= l || b <= t)
            continue;

        // 可选：过滤靠近 patch 边缘的框
        if (is_near_border(l, t, r, b, win.w, win.h, BORDER_FILTER_MARGIN))
            continue;

        GlobalDetectBox g;
        g.left = l + win.x;
        g.top = t + win.y;
        g.right = r + win.x;
        g.bottom = b + win.y;
        g.score = det_result->prop;
        g.cls_id = det_result->cls_id;

        all_boxes.push_back(g);
    }
}

static int copy_patch_to_image_buffer(const image_buffer_t *src_image,
                                      const WindowInfo &win,
                                      image_buffer_t *patch_image)
{
    memset(patch_image, 0, sizeof(image_buffer_t));

    int channels = 3; // RGB888 / BGR888
    int patch_size = win.w * win.h * channels;

    patch_image->width = win.w;
    patch_image->height = win.h;
    patch_image->format = src_image->format;
    patch_image->size = patch_size;
    patch_image->fd = 0;
    patch_image->virt_addr = (unsigned char *)malloc(patch_size);
    if (patch_image->virt_addr == NULL)
    {
        printf("malloc patch buffer fail!\n");
        return -1;
    }

    int src_stride = src_image->width * channels;
    int dst_stride = win.w * channels;

    for (int row = 0; row < win.h; ++row)
    {
        unsigned char *src_ptr = src_image->virt_addr + ((win.y + row) * src_stride) + (win.x * channels);
        unsigned char *dst_ptr = patch_image->virt_addr + row * dst_stride;
        memcpy(dst_ptr, src_ptr, dst_stride);
    }

    return 0;
}

/*-------------------------------------------
                  Main Function
-------------------------------------------*/
int main(int argc, char **argv)
{
    std::vector<WindowInfo> windows;
    std::vector<GlobalDetectBox> all_boxes;
    std::vector<GlobalDetectBox> final_boxes;
    if (argc != 3)
    {
        printf("%s <model_path> <image_path>\n", argv[0]);
        return -1;
    }

    const char *model_path = argv[1];
    const char *image_path = argv[2];

    int ret;
    rknn_app_context_t rknn_app_ctx;
    memset(&rknn_app_ctx, 0, sizeof(rknn_app_context_t));

    init_post_process();

    ret = init_yolo11_model(model_path, &rknn_app_ctx);
    if (ret != 0)
    {
        printf("init_yolo11_model fail! ret=%d model_path=%s\n", ret, model_path);
        goto out;
    }

    image_buffer_t src_image;
    memset(&src_image, 0, sizeof(image_buffer_t));
    ret = read_image(image_path, &src_image);
    if (ret != 0)
    {
        printf("read image fail! ret=%d image_path=%s\n", ret, image_path);
        goto out;
    }

#if defined(RV1106_1103)
    // 这部分先保持原始 demo 的处理方式
    ret = dma_buf_alloc(RV1106_CMA_HEAP_PATH, src_image.size, &rknn_app_ctx.img_dma_buf.dma_buf_fd,
                        (void **)&(rknn_app_ctx.img_dma_buf.dma_buf_virt_addr));
    memcpy(rknn_app_ctx.img_dma_buf.dma_buf_virt_addr, src_image.virt_addr, src_image.size);
    dma_sync_cpu_to_device(rknn_app_ctx.img_dma_buf.dma_buf_fd);
    free(src_image.virt_addr);
    src_image.virt_addr = (unsigned char *)rknn_app_ctx.img_dma_buf.dma_buf_virt_addr;
    src_image.fd = rknn_app_ctx.img_dma_buf.dma_buf_fd;
    rknn_app_ctx.img_dma_buf.size = src_image.size;
#endif

    // 滑窗切片
    windows = split_windows(src_image.width, src_image.height,
                                                    PATCH_W, PATCH_H,
                                                    STRIDE_X, STRIDE_Y);

    printf("image size: %d x %d\n", src_image.width, src_image.height);
    printf("patch size: %d x %d, stride: %d x %d\n", PATCH_W, PATCH_H, STRIDE_X, STRIDE_Y);
    printf("window count: %zu\n", windows.size());

    //std::vector<GlobalDetectBox> all_boxes;

    for (size_t wi = 0; wi < windows.size(); ++wi)
    {
        image_buffer_t patch_image;
        ret = copy_patch_to_image_buffer(&src_image, windows[wi], &patch_image);
        if (ret != 0)
        {
            printf("copy_patch_to_image_buffer fail at window %zu\n", wi);
            continue;
        }

        object_detect_result_list od_results;
        memset(&od_results, 0, sizeof(object_detect_result_list));

        ret = inference_yolo11_model(&rknn_app_ctx, &patch_image, &od_results);
        if (ret != 0)
        {
            printf("inference_yolo11_model fail! ret=%d, window=%zu\n", ret, wi);
            free(patch_image.virt_addr);
            continue;
        }

        printf("window[%zu]: x=%d y=%d w=%d h=%d, det_count=%d\n",
               wi, windows[wi].x, windows[wi].y, windows[wi].w, windows[wi].h, od_results.count);

        collect_patch_boxes(&od_results, windows[wi], all_boxes);

        free(patch_image.virt_addr);
    }

    final_boxes = global_nms(all_boxes, GLOBAL_NMS_THRESH);

    printf("all_boxes=%zu, final_boxes=%zu\n", all_boxes.size(), final_boxes.size());

    // 在原图上画最终结果
    char text[256];
    for (size_t i = 0; i < final_boxes.size(); ++i)
    {
        const GlobalDetectBox &det = final_boxes[i];

        printf("%s @ (%d %d %d %d) %.3f\n",
               coco_cls_to_name(det.cls_id),
               (int)det.left, (int)det.top,
               (int)det.right, (int)det.bottom,
               det.score);

        int x1 = (int)det.left;
        int y1 = (int)det.top;
        int x2 = (int)det.right;
        int y2 = (int)det.bottom;

        draw_rectangle(&src_image, x1, y1, x2 - x1, y2 - y1, COLOR_BLUE, 3);

        sprintf(text, "%s %.1f%%", coco_cls_to_name(det.cls_id), det.score * 100);
        draw_text(&src_image, text, x1, y1 - 20, COLOR_RED, 10);
    }

    write_image("out_slide.png", &src_image);

out:
    deinit_post_process();

    ret = release_yolo11_model(&rknn_app_ctx);
    if (ret != 0)
    {
        printf("release_yolo11_model fail! ret=%d\n", ret);
    }

    if (src_image.virt_addr != NULL)
    {
#if defined(RV1106_1103)
        dma_buf_free(rknn_app_ctx.img_dma_buf.size, &rknn_app_ctx.img_dma_buf.dma_buf_fd,
                     rknn_app_ctx.img_dma_buf.dma_buf_virt_addr);
#else
        free(src_image.virt_addr);
#endif
    }

    return 0;
}
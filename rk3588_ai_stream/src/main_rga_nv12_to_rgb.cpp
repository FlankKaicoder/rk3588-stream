#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <chrono>

#include "image_utils.h"
#include "file_utils.h"

static inline double diff_ms(const std::chrono::steady_clock::time_point &start,
                             const std::chrono::steady_clock::time_point &end)
{
    return std::chrono::duration<double, std::milli>(end - start).count();
}

static int read_binary_file(const char *path, unsigned char *buf, size_t size)
{
    FILE *fp = fopen(path, "rb");
    if (!fp)
    {
        printf("ERROR: fopen input failed: %s\n", path);
        return -1;
    }

    size_t n = fread(buf, 1, size, fp);
    fclose(fp);

    if (n != size)
    {
        printf("ERROR: fread size mismatch, expect=%zu actual=%zu\n", size, n);
        return -1;
    }

    return 0;
}

static int write_binary_file(const char *path, const unsigned char *buf, size_t size)
{
    FILE *fp = fopen(path, "wb");
    if (!fp)
    {
        printf("ERROR: fopen output failed: %s\n", path);
        return -1;
    }

    size_t n = fwrite(buf, 1, size, fp);
    fclose(fp);

    if (n != size)
    {
        printf("ERROR: fwrite size mismatch, expect=%zu actual=%zu\n", size, n);
        return -1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 6)
    {
        printf("Usage: %s <input_nv12> <width> <height> <output_rgb_raw> <output_jpg>\n", argv[0]);
        printf("Example:\n");
        printf("  %s output/exp04_v4l2_nv12_save/frame_1280x720.nv12 1280 720 output/exp06_rga_nv12_to_rgb/frame.rgb output/exp06_rga_nv12_to_rgb/frame.jpg\n", argv[0]);
        return -1;
    }

    const char *input_nv12_path = argv[1];
    int width = atoi(argv[2]);
    int height = atoi(argv[3]);
    const char *output_rgb_path = argv[4];
    const char *output_jpg_path = argv[5];

    if (width <= 0 || height <= 0)
    {
        printf("ERROR: invalid width/height: %d x %d\n", width, height);
        return -1;
    }

    size_t nv12_size = width * height * 3 / 2;
    size_t rgb_size = width * height * 3;

    printf("input nv12 : %s\n", input_nv12_path);
    printf("width      : %d\n", width);
    printf("height     : %d\n", height);
    printf("nv12 size  : %zu\n", nv12_size);
    printf("rgb size   : %zu\n", rgb_size);
    printf("output rgb : %s\n", output_rgb_path);
    printf("output jpg : %s\n", output_jpg_path);

    unsigned char *nv12_buf = (unsigned char *)malloc(nv12_size);
    unsigned char *rgb_buf = (unsigned char *)malloc(rgb_size);

    if (!nv12_buf || !rgb_buf)
    {
        printf("ERROR: malloc failed\n");
        if (nv12_buf) free(nv12_buf);
        if (rgb_buf) free(rgb_buf);
        return -1;
    }

    if (read_binary_file(input_nv12_path, nv12_buf, nv12_size) != 0)
    {
        free(nv12_buf);
        free(rgb_buf);
        return -1;
    }

    image_buffer_t src_img;
    memset(&src_img, 0, sizeof(src_img));

    src_img.width = width;
    src_img.height = height;
    src_img.format = IMAGE_FORMAT_YUV420SP_NV12;
    src_img.virt_addr = nv12_buf;
    src_img.size = nv12_size;

    image_buffer_t dst_img;
    memset(&dst_img, 0, sizeof(dst_img));

    dst_img.width = width;
    dst_img.height = height;
    dst_img.format = IMAGE_FORMAT_RGB888;
    dst_img.virt_addr = rgb_buf;
    dst_img.size = rgb_size;

    image_rect_t src_box;
    memset(&src_box, 0, sizeof(src_box));
    src_box.left = 0;
    src_box.top = 0;
    src_box.right = width - 1;
    src_box.bottom = height - 1;

    image_rect_t dst_box;
    memset(&dst_box, 0, sizeof(dst_box));
    dst_box.left = 0;
    dst_box.top = 0;
    dst_box.right = width - 1;
    dst_box.bottom = height - 1;

    auto t0 = std::chrono::steady_clock::now();

    int ret = convert_image(&src_img, &dst_img, &src_box, &dst_box, 0);

    auto t1 = std::chrono::steady_clock::now();
    double rga_ms = diff_ms(t0, t1);

    if (ret != 0)
    {
        printf("ERROR: convert_image NV12->RGB failed, ret=%d\n", ret);
        free(nv12_buf);
        free(rgb_buf);
        return -1;
    }

    printf("RGA convert NV12 -> RGB success, time = %.3f ms\n", rga_ms);

    if (write_binary_file(output_rgb_path, rgb_buf, rgb_size) != 0)
    {
        free(nv12_buf);
        free(rgb_buf);
        return -1;
    }

    ret = write_image(output_jpg_path, &dst_img);
    if (ret != 0)
    {
        printf("ERROR: write_image failed, ret=%d\n", ret);
        free(nv12_buf);
        free(rgb_buf);
        return -1;
    }

    printf("write rgb raw success: %s\n", output_rgb_path);
    printf("write jpg success    : %s\n", output_jpg_path);

    free(nv12_buf);
    free(rgb_buf);

    return 0;
}

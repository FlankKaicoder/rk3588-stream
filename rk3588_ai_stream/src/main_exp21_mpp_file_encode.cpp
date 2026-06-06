#include "mpp_h264_encoder.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <chrono>

static double diff_ms(const std::chrono::steady_clock::time_point &a,
                      const std::chrono::steady_clock::time_point &b)
{
    return std::chrono::duration<double, std::milli>(b - a).count();
}

int main(int argc, char **argv)
{
    if (argc != 8)
    {
        printf("Usage:\n");
        printf("  %s <input_nv12> <width> <height> <fps> <frames> <bitrate> <output_h264>\n", argv[0]);
        printf("\nExample:\n");
        printf("  %s output/exp08_mpp_encode_record/input_120f_1280x720.nv12 1280 720 30 120 4000000 output/exp21_1_mpp_file_encode/test.h264\n", argv[0]);
        return -1;
    }

    const char *input_nv12 = argv[1];
    int width = atoi(argv[2]);
    int height = atoi(argv[3]);
    int fps = atoi(argv[4]);
    int frames = atoi(argv[5]);
    int bitrate = atoi(argv[6]);
    const char *output_h264 = argv[7];

    if (width <= 0 || height <= 0 || fps <= 0 || frames <= 0 || bitrate <= 0)
    {
        printf("invalid args\n");
        return -1;
    }

    const size_t raw_frame_size = static_cast<size_t>(width) * height * 3 / 2;

    printf("========== exp21 mpp file encode ==========\n");
    printf("input nv12 : %s\n", input_nv12);
    printf("output h264: %s\n", output_h264);
    printf("width      : %d\n", width);
    printf("height     : %d\n", height);
    printf("fps        : %d\n", fps);
    printf("frames     : %d\n", frames);
    printf("bitrate    : %d\n", bitrate);
    printf("frame size : %zu\n", raw_frame_size);
    printf("==========================================\n");

    FILE *fin = fopen(input_nv12, "rb");
    if (!fin)
    {
        perror("fopen input");
        return -1;
    }

    FILE *fout = fopen(output_h264, "wb");
    if (!fout)
    {
        perror("fopen output");
        fclose(fin);
        return -1;
    }

    MppH264Encoder encoder;
    if (!encoder.init(width, height, fps, bitrate))
    {
        printf("encoder init failed\n");
        fclose(fin);
        fclose(fout);
        return -1;
    }

    std::vector<uint8_t> header;
    if (encoder.get_header(header) && !header.empty())
    {
        fwrite(header.data(), 1, header.size(), fout);
        printf("write h264 header: %zu bytes\n", header.size());
    }
    else
    {
        printf("warning: empty h264 header\n");
    }

    std::vector<uint8_t> raw(raw_frame_size);
    std::vector<uint8_t> packet;

    int encoded_frames = 0;
    size_t total_packet_bytes = 0;

    auto wall_start = std::chrono::steady_clock::now();

    for (int i = 0; i < frames; ++i)
    {
        size_t n = fread(raw.data(), 1, raw_frame_size, fin);
        if (n != raw_frame_size)
        {
            printf("input EOF or short frame at frame=%d read=%zu expected=%zu\n",
                   i, n, raw_frame_size);
            break;
        }

        auto t0 = std::chrono::steady_clock::now();

        bool ok = encoder.encode(raw.data(), raw.size(), packet);

        auto t1 = std::chrono::steady_clock::now();

        if (!ok)
        {
            printf("encode failed at frame=%d\n", i);
            break;
        }

        if (!packet.empty())
        {
            fwrite(packet.data(), 1, packet.size(), fout);
            total_packet_bytes += packet.size();
        }

        encoded_frames++;

        if (encoded_frames % 30 == 0 || encoded_frames == 1)
        {
            double enc_ms = diff_ms(t0, t1);
            printf("frame=%d packet=%zu encode_ms=%.3f\n",
                   encoded_frames,
                   packet.size(),
                   enc_ms);
            fflush(stdout);
        }
    }

    auto wall_end = std::chrono::steady_clock::now();
    double wall_ms = diff_ms(wall_start, wall_end);
    double wall_fps = wall_ms > 0.0 ? encoded_frames * 1000.0 / wall_ms : 0.0;

    encoder.release();

    fclose(fin);
    fclose(fout);

    printf("\n========== exp21 result ==========\n");
    printf("encoded_frames    : %d\n", encoded_frames);
    printf("wall_time_ms      : %.3f\n", wall_ms);
    printf("wall_fps          : %.3f\n", wall_fps);
    printf("h264_packet_bytes : %zu\n", total_packet_bytes);
    printf("output_h264       : %s\n", output_h264);
    printf("==================================\n");

    return encoded_frames > 0 ? 0 : -1;
}

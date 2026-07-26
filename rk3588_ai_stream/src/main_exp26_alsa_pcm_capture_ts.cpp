#include <alsa/asoundlib.h>

#include <cstdint>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <string>
#include <vector>
#include <time.h>

static int64_t now_monotonic_ns()
{
    struct timespec ts {};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int64_t htimestamp_to_ns(const snd_htimestamp_t& ts)
{
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static void print_alsa_error(const char* msg, int err)
{
    std::cerr << msg << ": " << snd_strerror(err) << "\n";
}

int main(int argc, char** argv)
{
    if (argc != 8) {
        std::cerr << "Usage: " << argv[0]
                  << " <alsa_dev> <rate> <channels> <duration_sec> <period_frames> <out_pcm> <out_csv>\n";
        return 1;
    }

    const char* dev = argv[1];
    unsigned int rate = std::stoul(argv[2]);
    unsigned int channels = std::stoul(argv[3]);
    double duration_sec = std::stod(argv[4]);
    snd_pcm_uframes_t period_frames = std::stoul(argv[5]);
    const char* pcm_path = argv[6];
    const char* csv_path = argv[7];

    snd_pcm_t* pcm = nullptr;
    int err = snd_pcm_open(&pcm, dev, SND_PCM_STREAM_CAPTURE, 0);
    if (err < 0) {
        print_alsa_error("snd_pcm_open failed", err);
        return 2;
    }

    snd_pcm_hw_params_t* hw = nullptr;
    snd_pcm_hw_params_malloc(&hw);
    snd_pcm_hw_params_any(pcm, hw);
    snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED);
    snd_pcm_hw_params_set_format(pcm, hw, SND_PCM_FORMAT_S16_LE);
    snd_pcm_hw_params_set_channels(pcm, hw, channels);

    unsigned int actual_rate = rate;
    snd_pcm_hw_params_set_rate_near(pcm, hw, &actual_rate, nullptr);

    snd_pcm_uframes_t actual_period = period_frames;
    snd_pcm_hw_params_set_period_size_near(pcm, hw, &actual_period, nullptr);

    snd_pcm_uframes_t buffer_frames = actual_period * 4;
    snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer_frames);

    err = snd_pcm_hw_params(pcm, hw);
    if (err < 0) {
        print_alsa_error("snd_pcm_hw_params failed", err);
        snd_pcm_hw_params_free(hw);
        snd_pcm_close(pcm);
        return 3;
    }
    snd_pcm_hw_params_free(hw);

    snd_pcm_sw_params_t* sw = nullptr;
    snd_pcm_sw_params_malloc(&sw);
    snd_pcm_sw_params_current(pcm, sw);
    snd_pcm_sw_params_set_tstamp_mode(pcm, sw, SND_PCM_TSTAMP_ENABLE);

#ifdef SND_PCM_TSTAMP_TYPE_MONOTONIC
    int tr = snd_pcm_sw_params_set_tstamp_type(pcm, sw, SND_PCM_TSTAMP_TYPE_MONOTONIC);
    if (tr < 0) {
        std::cerr << "warning: set monotonic timestamp type failed: "
                  << snd_strerror(tr) << "\n";
    }
#endif

    err = snd_pcm_sw_params(pcm, sw);
    if (err < 0) {
        print_alsa_error("snd_pcm_sw_params failed", err);
        snd_pcm_sw_params_free(sw);
        snd_pcm_close(pcm);
        return 4;
    }
    snd_pcm_sw_params_free(sw);

    err = snd_pcm_prepare(pcm);
    if (err < 0) {
        print_alsa_error("snd_pcm_prepare failed", err);
        snd_pcm_close(pcm);
        return 5;
    }

    std::ofstream pcm_out(pcm_path, std::ios::binary);
    if (!pcm_out.is_open()) {
        std::cerr << "open pcm failed: " << pcm_path << "\n";
        snd_pcm_close(pcm);
        return 6;
    }

    std::ofstream csv(csv_path);
    if (!csv.is_open()) {
        std::cerr << "open csv failed: " << csv_path << "\n";
        snd_pcm_close(pcm);
        return 7;
    }

    csv << "chunk_id,"
        << "read_before_ns,"
        << "read_after_ns,"
        << "alsa_htstamp_ns,"
        << "frames_read,"
        << "total_frames,"
        << "audio_end_pts_us,"
        << "audio_stream_start_est_ns,"
        << "read_ms,"
        << "avail_frames,"
        << "delay_frames\n";

    std::cout << "alsa dev       : " << dev << "\n";
    std::cout << "rate requested : " << rate << "\n";
    std::cout << "rate actual    : " << actual_rate << "\n";
    std::cout << "channels       : " << channels << "\n";
    std::cout << "period frames  : " << actual_period << "\n";
    std::cout << "buffer frames  : " << buffer_frames << "\n";
    std::cout << "duration sec   : " << duration_sec << "\n";
    std::cout << "out pcm        : " << pcm_path << "\n";
    std::cout << "out csv        : " << csv_path << "\n";

    std::vector<int16_t> buffer((size_t)actual_period * channels);
    const int64_t target_frames =
        (int64_t)std::llround(duration_sec * (double)actual_rate);

    int64_t total_frames = 0;
    int chunk_id = 0;

    while (total_frames < target_frames) {
        int64_t before_ns = now_monotonic_ns();

        snd_pcm_sframes_t rc = snd_pcm_readi(pcm, buffer.data(), actual_period);

        int64_t after_ns = now_monotonic_ns();

        if (rc == -EPIPE) {
            std::cerr << "ALSA xrun at chunk=" << chunk_id << ", prepare again\n";
            snd_pcm_prepare(pcm);
            continue;
        }

        if (rc < 0) {
            rc = snd_pcm_recover(pcm, rc, 1);
            if (rc < 0) {
                std::cerr << "snd_pcm_readi unrecovered error at chunk="
                          << chunk_id << ": " << snd_strerror((int)rc) << "\n";
                break;
            }
            continue;
        }

        if (rc == 0) {
            continue;
        }

        pcm_out.write(reinterpret_cast<const char*>(buffer.data()),
                      (std::streamsize)rc * channels * sizeof(int16_t));

        snd_pcm_uframes_t avail = 0;
        snd_htimestamp_t hts {};
        int ht_rc = snd_pcm_htimestamp(pcm, &avail, &hts);
        int64_t hts_ns = ht_rc >= 0 ? htimestamp_to_ns(hts) : -1;

        snd_pcm_sframes_t delay = 0;
        int delay_rc = snd_pcm_delay(pcm, &delay);
        if (delay_rc < 0) delay = -1;

        total_frames += rc;

        int64_t audio_end_pts_us =
            total_frames * 1000000LL / (int64_t)actual_rate;

        int64_t audio_stream_start_est_ns = -1;
        if (hts_ns > 0) {
            audio_stream_start_est_ns =
                hts_ns - total_frames * 1000000000LL / (int64_t)actual_rate;
        }

        double read_ms = (double)(after_ns - before_ns) / 1000000.0;

        csv << chunk_id << ","
            << before_ns << ","
            << after_ns << ","
            << hts_ns << ","
            << rc << ","
            << total_frames << ","
            << audio_end_pts_us << ","
            << audio_stream_start_est_ns << ","
            << std::fixed << std::setprecision(3) << read_ms << ","
            << avail << ","
            << delay << "\n";

        if (chunk_id % 100 == 0) {
            std::cout << "chunk=" << chunk_id
                      << " frames_read=" << rc
                      << " total_frames=" << total_frames
                      << " audio_end_pts_us=" << audio_end_pts_us
                      << " stream_start_est_ns=" << audio_stream_start_est_ns
                      << " delay=" << delay
                      << "\n";
        }

        ++chunk_id;
    }

    snd_pcm_drop(pcm);
    snd_pcm_close(pcm);
    pcm_out.close();
    csv.close();

    std::cout << "pcm saved: " << pcm_path << "\n";
    std::cout << "csv saved: " << csv_path << "\n";
    return 0;
}

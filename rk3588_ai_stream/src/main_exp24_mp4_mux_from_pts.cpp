#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/packet.h>
#include <libavutil/pixfmt.h>
#include <libavutil/error.h>
}

struct PtsRow {
    int64_t frame_id = -1;
    int64_t input_pts_us = -1;
    int64_t packet_pts_us = -1;
    int64_t packet_dts_us = -1;
    int64_t packet_size = -1;
};

struct Nalu {
    size_t start = 0;
    size_t size = 0;
    int type = -1;
};

static std::string ff_err(int ret)
{
    char buf[256];
    av_strerror(ret, buf, sizeof(buf));
    return std::string(buf);
}

static std::vector<std::string> split_csv_line(const std::string &line)
{
    std::vector<std::string> out;
    std::string cur;
    bool in_quote = false;

    for (char c : line) {
        if (c == '"') {
            in_quote = !in_quote;
        } else if (c == ',' && !in_quote) {
            out.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    out.push_back(cur);
    return out;
}

static int64_t to_i64(const std::string &s, int64_t def = -1)
{
    try {
        return std::stoll(s);
    } catch (...) {
        return def;
    }
}

static bool read_pts_csv(const std::string &path, std::vector<PtsRow> &rows)
{
    rows.clear();

    std::ifstream fin(path);
    if (!fin.is_open()) {
        std::cerr << "open pts csv failed: " << path << "\n";
        return false;
    }

    std::string header;
    if (!std::getline(fin, header)) {
        std::cerr << "empty pts csv\n";
        return false;
    }

    auto cols = split_csv_line(header);
    std::map<std::string, int> idx;
    for (int i = 0; i < (int)cols.size(); ++i) {
        idx[cols[i]] = i;
    }

    auto need = [&](const std::string &name) -> bool {
        if (!idx.count(name)) {
            std::cerr << "missing csv column: " << name << "\n";
            return false;
        }
        return true;
    };

    if (!need("frame_id") ||
        !need("input_pts_us") ||
        !need("mpp_packet_pts_us") ||
        !need("mpp_packet_dts_us") ||
        !need("packet_size")) {
        return false;
    }

    std::string line;
    while (std::getline(fin, line)) {
        if (line.empty()) continue;

        auto v = split_csv_line(line);
        auto get = [&](const std::string &name) -> std::string {
            int i = idx[name];
            if (i < 0 || i >= (int)v.size()) return "";
            return v[i];
        };

        PtsRow r;
        r.frame_id = to_i64(get("frame_id"));
        r.input_pts_us = to_i64(get("input_pts_us"));
        r.packet_pts_us = to_i64(get("mpp_packet_pts_us"));
        r.packet_dts_us = to_i64(get("mpp_packet_dts_us"));
        r.packet_size = to_i64(get("packet_size"));
        rows.push_back(r);
    }

    return !rows.empty();
}

static bool read_file(const std::string &path, std::vector<uint8_t> &data)
{
    data.clear();

    std::ifstream fin(path, std::ios::binary);
    if (!fin.is_open()) {
        std::cerr << "open file failed: " << path << "\n";
        return false;
    }

    fin.seekg(0, std::ios::end);
    std::streamoff n = fin.tellg();
    fin.seekg(0, std::ios::beg);

    if (n <= 0) {
        std::cerr << "empty file: " << path << "\n";
        return false;
    }

    data.resize((size_t)n);
    fin.read((char *)data.data(), n);
    return fin.good();
}

static size_t start_code_len(const uint8_t *p, size_t remain)
{
    if (remain >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) return 4;
    if (remain >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1) return 3;
    return 0;
}

static std::vector<Nalu> find_annexb_nalus(const uint8_t *data, size_t size)
{
    std::vector<Nalu> nalus;

    size_t pos = 0;
    while (pos + 3 < size) {
        size_t sc = 0;
        size_t sc_len = 0;

        for (; pos + 3 < size; ++pos) {
            sc_len = start_code_len(data + pos, size - pos);
            if (sc_len > 0) {
                sc = pos;
                break;
            }
        }

        if (sc_len == 0) break;

        size_t nal_start = sc + sc_len;
        size_t next = nal_start;

        pos = nal_start;
        while (pos + 3 < size) {
            size_t next_sc_len = start_code_len(data + pos, size - pos);
            if (next_sc_len > 0) {
                next = pos;
                break;
            }
            ++pos;
        }

        if (pos + 3 >= size) {
            next = size;
        }

        while (next > nal_start && data[next - 1] == 0) {
            next--;
        }

        if (next > nal_start) {
            Nalu n;
            n.start = nal_start;
            n.size = next - nal_start;
            n.type = data[nal_start] & 0x1F;
            nalus.push_back(n);
        }

        pos = next;
    }

    return nalus;
}

static void put_be16(std::vector<uint8_t> &out, uint16_t v)
{
    out.push_back((uint8_t)((v >> 8) & 0xFF));
    out.push_back((uint8_t)(v & 0xFF));
}

static void put_be32(std::vector<uint8_t> &out, uint32_t v)
{
    out.push_back((uint8_t)((v >> 24) & 0xFF));
    out.push_back((uint8_t)((v >> 16) & 0xFF));
    out.push_back((uint8_t)((v >> 8) & 0xFF));
    out.push_back((uint8_t)(v & 0xFF));
}

static bool build_avcc_extradata(const std::vector<uint8_t> &sps,
                                 const std::vector<uint8_t> &pps,
                                 std::vector<uint8_t> &avcc)
{
    avcc.clear();

    if (sps.size() < 4 || pps.empty()) {
        std::cerr << "invalid sps/pps for avcc. sps=" << sps.size()
                  << " pps=" << pps.size() << "\n";
        return false;
    }

    if (sps.size() > 65535 || pps.size() > 65535) {
        std::cerr << "sps/pps too large\n";
        return false;
    }

    avcc.push_back(1);          // configurationVersion
    avcc.push_back(sps[1]);     // AVCProfileIndication
    avcc.push_back(sps[2]);     // profile_compatibility
    avcc.push_back(sps[3]);     // AVCLevelIndication
    avcc.push_back(0xFF);       // reserved + lengthSizeMinusOne = 3, 4-byte length
    avcc.push_back(0xE1);       // reserved + numOfSequenceParameterSets = 1

    put_be16(avcc, (uint16_t)sps.size());
    avcc.insert(avcc.end(), sps.begin(), sps.end());

    avcc.push_back(1);          // numOfPictureParameterSets = 1
    put_be16(avcc, (uint16_t)pps.size());
    avcc.insert(avcc.end(), pps.begin(), pps.end());

    return true;
}

static bool annexb_to_avcc_sample(const uint8_t *data,
                                  size_t size,
                                  std::vector<uint8_t> &sample,
                                  bool &has_idr,
                                  bool &has_sps,
                                  bool &has_pps)
{
    sample.clear();
    has_idr = false;
    has_sps = false;
    has_pps = false;

    auto nalus = find_annexb_nalus(data, size);
    if (nalus.empty()) {
        std::cerr << "no annexb nalu found in packet size=" << size << "\n";
        return false;
    }

    for (const auto &n : nalus) {
        if (n.type == 5) has_idr = true;
        if (n.type == 7) has_sps = true;
        if (n.type == 8) has_pps = true;

        // SPS/PPS 已经写入 MP4 extradata，sample 中跳过，避免重复污染样本。
        if (n.type == 7 || n.type == 8) {
            continue;
        }

        if (n.size == 0 || n.size > 0xFFFFFFFFULL) {
            continue;
        }

        put_be32(sample, (uint32_t)n.size);
        sample.insert(sample.end(), data + n.start, data + n.start + n.size);
    }

    if (sample.empty()) {
        std::cerr << "sample is empty after filtering sps/pps\n";
        return false;
    }

    return true;
}

static bool find_sps_pps(const std::vector<uint8_t> &h264,
                         size_t header_size,
                         const std::vector<PtsRow> &rows,
                         std::vector<uint8_t> &sps,
                         std::vector<uint8_t> &pps)
{
    sps.clear();
    pps.clear();

    auto scan_range = [&](size_t off, size_t len) {
        if (off >= h264.size()) return;
        len = std::min(len, h264.size() - off);

        auto nalus = find_annexb_nalus(h264.data() + off, len);
        for (const auto &n : nalus) {
            if (n.type == 7 && sps.empty()) {
                sps.assign(h264.begin() + off + n.start, h264.begin() + off + n.start + n.size);
            } else if (n.type == 8 && pps.empty()) {
                pps.assign(h264.begin() + off + n.start, h264.begin() + off + n.start + n.size);
            }
        }
    };

    // 优先从实验23写出的 header 区域提取 SPS/PPS。
    scan_range(0, header_size);

    // 如果 header 区域没找到，再扫描前几个编码 packet。
    size_t off = header_size;
    for (size_t i = 0; i < rows.size() && i < 5 && (sps.empty() || pps.empty()); ++i) {
        if (rows[i].packet_size <= 0) return false;
        scan_range(off, (size_t)rows[i].packet_size);
        off += (size_t)rows[i].packet_size;
    }

    return !sps.empty() && !pps.empty();
}

int main(int argc, char **argv)
{
    if (argc != 7) {
        std::cerr << "Usage:\n"
                  << "  " << argv[0] << " <input.h264> <input.pts.csv> <output.mp4> <width> <height> <fps>\n";
        return 1;
    }

    const std::string h264_path = argv[1];
    const std::string pts_csv_path = argv[2];
    const std::string mp4_path = argv[3];
    const int width = std::atoi(argv[4]);
    const int height = std::atoi(argv[5]);
    const int fps = std::atoi(argv[6]);

    if (width <= 0 || height <= 0 || fps <= 0) {
        std::cerr << "invalid width/height/fps\n";
        return 1;
    }

    std::vector<PtsRow> rows;
    if (!read_pts_csv(pts_csv_path, rows)) {
        return 1;
    }

    std::vector<uint8_t> h264;
    if (!read_file(h264_path, h264)) {
        return 1;
    }

    int64_t sum_packet_size = 0;
    for (const auto &r : rows) {
        if (r.packet_size <= 0) {
            std::cerr << "invalid packet_size at frame_id=" << r.frame_id << "\n";
            return 1;
        }
        sum_packet_size += r.packet_size;
    }

    if (sum_packet_size <= 0 || sum_packet_size > (int64_t)h264.size()) {
        std::cerr << "bad packet size sum. sum=" << sum_packet_size
                  << " file=" << h264.size() << "\n";
        return 1;
    }

    const size_t header_size = h264.size() - (size_t)sum_packet_size;

    std::vector<uint8_t> sps, pps;
    if (!find_sps_pps(h264, header_size, rows, sps, pps)) {
        std::cerr << "failed to find SPS/PPS\n";
        return 1;
    }

    std::vector<uint8_t> avcc;
    if (!build_avcc_extradata(sps, pps, avcc)) {
        return 1;
    }

    std::cout << "input h264       : " << h264_path << "\n";
    std::cout << "pts csv          : " << pts_csv_path << "\n";
    std::cout << "output mp4       : " << mp4_path << "\n";
    std::cout << "width/height/fps : " << width << "x" << height << "@" << fps << "\n";
    std::cout << "h264 file bytes  : " << h264.size() << "\n";
    std::cout << "packet rows      : " << rows.size() << "\n";
    std::cout << "packet bytes sum : " << sum_packet_size << "\n";
    std::cout << "header bytes     : " << header_size << "\n";
    std::cout << "sps bytes        : " << sps.size() << "\n";
    std::cout << "pps bytes        : " << pps.size() << "\n";
    std::cout << "avcc bytes       : " << avcc.size() << "\n";

    avformat_network_init();

    AVFormatContext *ofmt = nullptr;
    int ret = avformat_alloc_output_context2(&ofmt, nullptr, nullptr, mp4_path.c_str());
    if (ret < 0 || ofmt == nullptr) {
        std::cerr << "avformat_alloc_output_context2 failed: " << ff_err(ret) << "\n";
        return 1;
    }

    AVStream *st = avformat_new_stream(ofmt, nullptr);
    if (!st) {
        std::cerr << "avformat_new_stream failed\n";
        avformat_free_context(ofmt);
        return 1;
    }

    st->id = 0;
    st->time_base = AVRational{1, 1000000};
    st->avg_frame_rate = AVRational{fps, 1};
    st->r_frame_rate = AVRational{fps, 1};

    AVCodecParameters *par = st->codecpar;
    par->codec_type = AVMEDIA_TYPE_VIDEO;
    par->codec_id = AV_CODEC_ID_H264;
    par->codec_tag = 0;
    par->width = width;
    par->height = height;
    par->format = AV_PIX_FMT_YUV420P;

    if (rows.size() >= 2) {
        int64_t duration_us = rows.back().input_pts_us - rows.front().input_pts_us;
        duration_us += rows.back().input_pts_us - rows[rows.size() - 2].input_pts_us;
        if (duration_us > 0) {
            par->bit_rate = (int64_t)((h264.size() * 8.0 * 1000000.0) / (double)duration_us);
        }
    }

    par->extradata_size = (int)avcc.size();
    par->extradata = (uint8_t *)av_mallocz(avcc.size() + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!par->extradata) {
        std::cerr << "av_mallocz extradata failed\n";
        avformat_free_context(ofmt);
        return 1;
    }
    std::memcpy(par->extradata, avcc.data(), avcc.size());

    if (!(ofmt->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&ofmt->pb, mp4_path.c_str(), AVIO_FLAG_WRITE);
        if (ret < 0) {
            std::cerr << "avio_open failed: " << ff_err(ret) << "\n";
            avformat_free_context(ofmt);
            return 1;
        }
    }

    AVDictionary *mux_opts = nullptr;
    ret = avformat_write_header(ofmt, &mux_opts);
    av_dict_free(&mux_opts);
    if (ret < 0) {
        std::cerr << "avformat_write_header failed: " << ff_err(ret) << "\n";
        if (!(ofmt->oformat->flags & AVFMT_NOFILE)) avio_closep(&ofmt->pb);
        avformat_free_context(ofmt);
        return 1;
    }

    std::string packet_csv_path = mp4_path + ".packets.csv";
    std::ofstream pkt_csv(packet_csv_path);
    pkt_csv << "frame_id,input_pts_us,effective_dts_us,duration_us,avpkt_pts,avpkt_dts,avpkt_duration,keyframe,input_packet_size,avcc_sample_size\n";

    size_t off = header_size;
    int64_t written = 0;
    int64_t keyframes = 0;
    int64_t total_avcc_bytes = 0;

    for (size_t i = 0; i < rows.size(); ++i) {
        const auto &r = rows[i];

        if (off + (size_t)r.packet_size > h264.size()) {
            std::cerr << "packet range overflow at row=" << i << "\n";
            ret = AVERROR_INVALIDDATA;
            break;
        }

        std::vector<uint8_t> sample;
        bool has_idr = false;
        bool has_sps = false;
        bool has_pps = false;

        if (!annexb_to_avcc_sample(h264.data() + off, (size_t)r.packet_size,
                                   sample, has_idr, has_sps, has_pps)) {
            std::cerr << "annexb_to_avcc_sample failed at frame_id=" << r.frame_id << "\n";
            ret = AVERROR_INVALIDDATA;
            break;
        }

        int64_t pts_us = r.input_pts_us;
        int64_t dts_us = r.input_pts_us;

        int64_t duration_us = 1000000 / fps;
        if (i + 1 < rows.size()) {
            duration_us = rows[i + 1].input_pts_us - rows[i].input_pts_us;
        }

        AVPacket pkt;
        av_init_packet(&pkt);
        ret = av_new_packet(&pkt, (int)sample.size());
        if (ret < 0) {
            std::cerr << "av_new_packet failed: " << ff_err(ret) << "\n";
            break;
        }

        std::memcpy(pkt.data, sample.data(), sample.size());
        pkt.stream_index = st->index;
        pkt.pts = pts_us;
        pkt.dts = dts_us;
        pkt.duration = duration_us;
        pkt.pos = -1;

        bool key = has_idr || i == 0;
        if (key) {
            pkt.flags |= AV_PKT_FLAG_KEY;
            keyframes++;
        }

        ret = av_interleaved_write_frame(ofmt, &pkt);
        if (ret < 0) {
            std::cerr << "av_interleaved_write_frame failed at frame_id="
                      << r.frame_id << ": " << ff_err(ret) << "\n";
            av_packet_unref(&pkt);
            break;
        }

        pkt_csv << r.frame_id << ","
                << pts_us << ","
                << dts_us << ","
                << duration_us << ","
                << pts_us << ","
                << dts_us << ","
                << duration_us << ","
                << (key ? 1 : 0) << ","
                << r.packet_size << ","
                << sample.size() << "\n";

        av_packet_unref(&pkt);

        total_avcc_bytes += (int64_t)sample.size();
        written++;
        off += (size_t)r.packet_size;
    }

    if (ret >= 0) {
        ret = av_write_trailer(ofmt);
        if (ret < 0) {
            std::cerr << "av_write_trailer failed: " << ff_err(ret) << "\n";
        }
    }

    pkt_csv.close();

    if (!(ofmt->oformat->flags & AVFMT_NOFILE)) {
        avio_closep(&ofmt->pb);
    }
    avformat_free_context(ofmt);

    std::cout << "written packets   : " << written << "\n";
    std::cout << "keyframes         : " << keyframes << "\n";
    std::cout << "avcc sample bytes : " << total_avcc_bytes << "\n";
    std::cout << "packet csv        : " << packet_csv_path << "\n";

    if (ret < 0 || written != (int64_t)rows.size()) {
        std::cerr << "mux failed or incomplete. ret=" << ret
                  << " written=" << written
                  << " expected=" << rows.size() << "\n";
        return 1;
    }

    std::cout << "exp24 mux success\n";
    return 0;
}

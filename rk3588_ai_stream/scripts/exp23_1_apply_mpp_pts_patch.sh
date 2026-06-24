#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT=output/exp23_1_mpp_pts_patch
mkdir -p "$OUT/source_backup"

echo "========== backup =========="
for f in \
  include/mpp_h264_encoder.hpp \
  src/mpp_h264_encoder.cpp \
  src/main_exp21_detect_mpp_encode_async.cpp
do
  if [ -f "$f" ]; then
    mkdir -p "$OUT/source_backup/$(dirname "$f")"
    cp -a "$f" "$OUT/source_backup/$f"
    echo "backup $f"
  else
    echo "missing $f"
    exit 1
  fi
done

cat > "$OUT/patch_exp23_1.py" <<'PY'
from pathlib import Path
import re
import sys

def read(p):
    return Path(p).read_text()

def write(p, s):
    Path(p).write_text(s)

def require(cond, msg):
    if not cond:
        print("[ERR]", msg)
        sys.exit(1)

# ============================================================
# 1. patch include/mpp_h264_encoder.hpp
# ============================================================
hpp_path = Path("include/mpp_h264_encoder.hpp")
hpp = read(hpp_path)

if "#include <cstdint>" not in hpp:
    if "#include <vector>" in hpp:
        hpp = hpp.replace("#include <vector>", "#include <vector>\n#include <cstdint>")
    else:
        hpp = hpp.replace("#pragma once", "#pragma once\n#include <vector>\n#include <cstdint>")

if "set_next_pts_us" not in hpp:
    # 在 encode 声明前插入 PTS 相关接口
    pattern = re.compile(
        r"(\s*bool\s+encode\s*\(\s*const\s+uint8_t\s*\*\s*nv12_data\s*,\s*\n"
        r"\s*size_t\s+nv12_size\s*,\s*\n"
        r"\s*std::vector\s*<\s*uint8_t\s*>\s*&\s*out_packet\s*\)\s*;)",
        re.M
    )
    m = pattern.search(hpp)
    require(m, "cannot find encode declaration in mpp_h264_encoder.hpp")

    insert = """
    // exp23: PTS metadata interface.
    // The old encode() byte-stream interface is kept unchanged.
    void set_next_pts_us(int64_t pts_us);
    int64_t last_packet_pts_us() const;
    int64_t last_packet_dts_us() const;
    uint32_t last_packet_flags() const;
    bool last_packet_is_intra() const;

"""
    hpp = hpp[:m.start()] + insert + hpp[m.start():]

if "next_pts_us_" not in hpp:
    # 插入 private 成员。优先放到 private: 后面。
    if "private:" in hpp:
        hpp = hpp.replace(
            "private:",
            """private:
    // exp23: PTS metadata cache.
    int64_t next_pts_us_ = -1;
    int64_t last_packet_pts_us_ = -1;
    int64_t last_packet_dts_us_ = -1;
    uint32_t last_packet_flags_ = 0;
""",
            1
        )
    else:
        # 极端情况下没有 private:，就在 class 结束前补一个 private 块
        hpp = re.sub(
            r"\n};\s*$",
            """
private:
    // exp23: PTS metadata cache.
    int64_t next_pts_us_ = -1;
    int64_t last_packet_pts_us_ = -1;
    int64_t last_packet_dts_us_ = -1;
    uint32_t last_packet_flags_ = 0;
};
""",
            hpp
        )

write(hpp_path, hpp)

# ============================================================
# 2. patch src/mpp_h264_encoder.cpp
# ============================================================
cpp_path = Path("src/mpp_h264_encoder.cpp")
cpp = read(cpp_path)

if "MppH264Encoder::set_next_pts_us" not in cpp:
    marker = "bool MppH264Encoder::encode("
    require(marker in cpp, "cannot find MppH264Encoder::encode definition")

    methods = r'''
void MppH264Encoder::set_next_pts_us(int64_t pts_us)
{
    next_pts_us_ = pts_us;
}

int64_t MppH264Encoder::last_packet_pts_us() const
{
    return last_packet_pts_us_;
}

int64_t MppH264Encoder::last_packet_dts_us() const
{
    return last_packet_dts_us_;
}

uint32_t MppH264Encoder::last_packet_flags() const
{
    return last_packet_flags_;
}

bool MppH264Encoder::last_packet_is_intra() const
{
#ifdef MPP_PACKET_FLAG_INTRA
    return (last_packet_flags_ & MPP_PACKET_FLAG_INTRA) != 0;
#else
    return (last_packet_flags_ & 0x00000008) != 0;
#endif
}

'''
    cpp = cpp.replace(marker, methods + marker, 1)

# 每次 encode 开始前清空上一次 packet 元信息
if "last_packet_pts_us_ = -1;" not in cpp:
    cpp = re.sub(
        r"(bool\s+MppH264Encoder::encode\s*\([^{]+\)\s*\{\s*)",
        r"\1\n    last_packet_pts_us_ = -1;\n    last_packet_dts_us_ = -1;\n    last_packet_flags_ = 0;\n",
        cpp,
        count=1,
        flags=re.S
    )

# 给 MppFrame 设置 PTS
if "mpp_frame_set_pts(frame, next_pts_us_);" not in cpp:
    old = "    mpp_frame_set_eos(frame, 0);"
    require(old in cpp, "cannot find mpp_frame_set_eos(frame, 0)")
    new = """    if (next_pts_us_ >= 0) {
        mpp_frame_set_pts(frame, next_pts_us_);
    }
    mpp_frame_set_eos(frame, 0);"""
    cpp = cpp.replace(old, new, 1)

# 从 MppPacket 取回 PTS / DTS / flag
if "last_packet_pts_us_ = mpp_packet_get_pts(packet);" not in cpp:
    old = """            void *ptr = mpp_packet_get_pos(packet);
            size_t len = mpp_packet_get_length(packet);"""
    require(old in cpp, "cannot find packet pos/length block")
    new = """            last_packet_pts_us_ = mpp_packet_get_pts(packet);
            last_packet_dts_us_ = mpp_packet_get_dts(packet);
            last_packet_flags_ = mpp_packet_get_flag(packet);

            void *ptr = mpp_packet_get_pos(packet);
            size_t len = mpp_packet_get_length(packet);"""
    cpp = cpp.replace(old, new, 1)

write(cpp_path, cpp)

# ============================================================
# 3. patch src/main_exp21_detect_mpp_encode_async.cpp
# ============================================================
main_path = Path("src/main_exp21_detect_mpp_encode_async.cpp")
main = read(main_path)

# include
if "#include <cstdint>" not in main:
    main = main.replace("#include <thread>", "#include <thread>\n#include <cstdint>\n#include <string>", 1)

# helper
if "static int64_t exp23_now_us()" not in main:
    insert_after = "#include <string>"
    helper = r'''

static int64_t exp23_now_us()
{
    using namespace std::chrono;
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

'''
    if insert_after in main:
        main = main.replace(insert_after, insert_after + helper, 1)
    else:
        main = main.replace("\n\n", helper, 1)

# struct Exp21EncFrame fields
if "pts_us" not in re.search(r"struct\s+Exp21EncFrame\s*\{[^}]*\};", main, re.S).group(0):
    main = main.replace(
        "    int frame_id = 0;",
        """    int frame_id = 0;
    int64_t pts_us = -1;
    int64_t enqueue_ts_us = -1;""",
        1
    )

# PTS csv
if "enc_pts_csv_path" not in main:
    old = "    std::ofstream profile_csv(profile_csv_path);"
    require(old in main, "cannot find profile_csv creation")
    new = """    std::ofstream profile_csv(profile_csv_path);

    std::string enc_pts_csv_path = std::string(output_h264_path) + ".pts.csv";
    std::ofstream enc_pts_csv(enc_pts_csv_path);
    enc_pts_csv << "frame_id,input_pts_us,mpp_packet_pts_us,mpp_packet_dts_us,"
                   "pts_match,is_intra,queue_delay_ms,encode_wall_ms,packet_size\\n";"""
    main = main.replace(old, new, 1)

# 在 encoder thread 中 set_next_pts_us + 记录 encode 起止
if "exp23_encode_start_us" not in main:
    old = "            bool ok = mpp_encoder.encode(item.nv12.data(), nv12_size, local_packet);"
    require(old in main, "cannot find mpp_encoder.encode call")
    new = """            int64_t exp23_encode_start_us = exp23_now_us();
            int64_t exp23_queue_delay_us = item.enqueue_ts_us >= 0 ? (exp23_encode_start_us - item.enqueue_ts_us) : -1;

            mpp_encoder.set_next_pts_us(item.pts_us);
            bool ok = mpp_encoder.encode(item.nv12.data(), nv12_size, local_packet);
            int64_t exp23_encode_end_us = exp23_now_us();

            int64_t exp23_mpp_packet_pts_us = mpp_encoder.last_packet_pts_us();
            int64_t exp23_mpp_packet_dts_us = mpp_encoder.last_packet_dts_us();
            bool exp23_is_intra = mpp_encoder.last_packet_is_intra();"""
    main = main.replace(old, new, 1)

# 写 pts csv。插入到 async_encode_us 累加前。
if "enc_pts_csv << item.frame_id" not in main:
    old = "            async_encode_us += (long long)(enc_ms * 1000.0);"
    require(old in main, "cannot find async_encode_us accumulation")
    new = """            if (enc_pts_csv.is_open()) {
                int pts_match = (exp23_mpp_packet_pts_us == item.pts_us) ? 1 : 0;
                enc_pts_csv << item.frame_id << ","
                            << item.pts_us << ","
                            << exp23_mpp_packet_pts_us << ","
                            << exp23_mpp_packet_dts_us << ","
                            << pts_match << ","
                            << (exp23_is_intra ? 1 : 0) << ","
                            << (exp23_queue_delay_us >= 0 ? exp23_queue_delay_us / 1000.0 : -1.0) << ","
                            << ((exp23_encode_end_us - exp23_encode_start_us) / 1000.0) << ","
                            << local_packet.size() << "\\n";
            }

            async_encode_us += (long long)(enc_ms * 1000.0);"""
    main = main.replace(old, new, 1)

# 日志中增加 pts 信息
if "pkt_pts=%lld" not in main:
    main = main.replace(
        """                printf("[ENC] encoded=%d src_frame=%d packet=%zu encode=%.3f write=%.3f total=%.3f\\n",""",
        """                printf("[ENC] encoded=%d src_frame=%d packet=%zu pts=%lld pkt_pts=%lld dts=%lld intra=%d qdelay=%.3f encode=%.3f write=%.3f total=%.3f\\n",""",
        1
    )
    main = main.replace(
        """                       item.frame_id,
                       local_packet.size(),
                       enc_ms,
                       write_ms,
                       total_ms);""",
        """                       item.frame_id,
                       local_packet.size(),
                       (long long)item.pts_us,
                       (long long)exp23_mpp_packet_pts_us,
                       (long long)exp23_mpp_packet_dts_us,
                       exp23_is_intra ? 1 : 0,
                       exp23_queue_delay_us >= 0 ? exp23_queue_delay_us / 1000.0 : -1.0,
                       enc_ms,
                       write_ms,
                       total_ms);""",
        1
    )

# 入队时设置 pts_us / enqueue_ts_us
if "enc_frame.pts_us" not in main:
    old = "        enc_frame.frame_id = frame_id;"
    require(old in main, "cannot find enc_frame.frame_id assignment")
    new = """        enc_frame.frame_id = frame_id;
        enc_frame.pts_us = (int64_t)frame_id * 1000000LL / (int64_t)mpp_fps;
        enc_frame.enqueue_ts_us = exp23_now_us();"""
    main = main.replace(old, new, 1)

# 程序结束时打印 pts csv 路径
if "enc pts csv saved" not in main:
    old = """    printf("async_avg_encode_ms  : %.3f\\n", async_avg_encode_ms);"""
    if old in main:
        new = """    printf("async_avg_encode_ms  : %.3f\\n", async_avg_encode_ms);
    printf("enc pts csv saved   : %s\\n", enc_pts_csv_path.c_str());"""
        main = main.replace(old, new, 1)

write(main_path, main)

print("[OK] exp23-1 patch applied")
PY

python3 "$OUT/patch_exp23_1.py"

echo
echo "========== build =========="
rm -rf build
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async -j4
cd ..

echo
echo "========== grep check =========="
grep -nE "set_next_pts_us|last_packet_pts|mpp_frame_set_pts|mpp_packet_get_pts|mpp_packet_get_dts|mpp_packet_get_flag" \
  include/mpp_h264_encoder.hpp src/mpp_h264_encoder.cpp || true

grep -nE "pts_us|enc_pts_csv|pkt_pts|qdelay|exp23_now_us" \
  src/main_exp21_detect_mpp_encode_async.cpp || true

echo
echo "exp23-1 patch done"

#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT=output/exp23_3_header_sync_buffer_fix
mkdir -p "$OUT/source_backup"

cp -a src/mpp_h264_encoder.cpp "$OUT/source_backup/mpp_h264_encoder.cpp.before_header_sync_buffer_fix"

cat > "$OUT/fix_header_sync_buffer.py" <<'PY'
from pathlib import Path
import re
import sys

p = Path("src/mpp_h264_encoder.cpp")
s = p.read_text()

def fail(msg):
    print("[ERR]", msg)
    sys.exit(1)

# ============================================================
# 1. 替换 get_header()：正确使用 MPP_ENC_GET_HDR_SYNC
# ============================================================
m = re.search(
    r'bool\s+MppH264Encoder::get_header\s*\(\s*std::vector\s*<\s*uint8_t\s*>\s*&\s*out_packet\s*\)\s*\{.*?\n\}',
    s,
    re.S
)

if not m:
    fail("cannot find MppH264Encoder::get_header()")

new_get_header = r'''bool MppH264Encoder::get_header(std::vector<uint8_t> &out_packet)
{
    out_packet.clear();

    if (!inited_ || ctx_ == nullptr || mpi_ == nullptr)
    {
        printf("get_header failed: encoder not initialized\n");
        return false;
    }

    /*
     * exp23-3:
     * Use MPP_ENC_GET_HDR_SYNC instead of unsafe MPP_ENC_GET_EXTRA_INFO.
     *
     * Rockchip official usage:
     *   mpp_packet_init_with_buffer(&packet, p->pkt_buf);
     *   mpp_packet_set_length(packet, 0);
     *   mpi->control(ctx, MPP_ENC_GET_HDR_SYNC, packet);
     *
     * For this project, we use a normal external memory buffer and wrap it
     * as MppPacket. The important point is that packet must have valid
     * external storage, and packet length must be cleared before control().
     */
    constexpr size_t kHeaderBufSize = 4096;
    uint8_t header_buf[kHeaderBufSize];

    MppPacket packet = nullptr;
    MPP_RET ret = mpp_packet_init(&packet, header_buf, kHeaderBufSize);
    if (ret != MPP_OK || packet == nullptr)
    {
        printf("mpp_packet_init for header failed, ret=%d\n", ret);
        return false;
    }

    /*
     * Important:
     * Official mpi_enc_test.c explicitly clears output packet length before
     * MPP_ENC_GET_HDR_SYNC.
     */
    mpp_packet_set_length(packet, 0);

    ret = mpi_->control(ctx_, MPP_ENC_GET_HDR_SYNC, packet);
    if (ret != MPP_OK)
    {
        printf("MPP_ENC_GET_HDR_SYNC failed, ret=%d\n", ret);
        mpp_packet_deinit(&packet);
        return false;
    }

    void *ptr = mpp_packet_get_pos(packet);
    size_t len = mpp_packet_get_length(packet);

    if (ptr != nullptr && len > 0)
    {
        const uint8_t *p = static_cast<const uint8_t *>(ptr);
        out_packet.assign(p, p + len);
        printf("got h264 header by MPP_ENC_GET_HDR_SYNC: %zu bytes\n", len);
    }
    else
    {
        printf("warning: MPP_ENC_GET_HDR_SYNC returned empty header\n");
    }

    mpp_packet_deinit(&packet);
    return !out_packet.empty();
}'''

s = s[:m.start()] + new_get_header + s[m.end():]

# ============================================================
# 2. 清理 release()，避免保留调试 probe
# ============================================================
m = re.search(r'void\s+MppH264Encoder::release\s*\(\s*\)\s*\{.*?\n\}', s, re.S)
if not m:
    fail("cannot find MppH264Encoder::release()")

new_release = r'''void MppH264Encoder::release()
{
    if (cfg_ != nullptr)
    {
        mpp_enc_cfg_deinit(cfg_);
        cfg_ = nullptr;
    }

    if (ctx_ != nullptr)
    {
        mpp_destroy(ctx_);
        ctx_ = nullptr;
        mpi_ = nullptr;
    }

    inited_ = false;
}'''

s = s[:m.start()] + new_release + s[m.end():]

# ============================================================
# 3. 清理 encode() 里的 EXP23_RELEASE_PROBE 调试块
# ============================================================
pattern_encode_packet_probe = re.compile(
    r'\s*printf\("\[EXP23_RELEASE_PROBE\] encode before mpp_packet_deinit packet=%p pts=%lld dts=%lld flags=0x%x len=%zu\\n",\s*'
    r'packet,\s*'
    r'\(long long\)last_packet_pts_us_,\s*'
    r'\(long long\)last_packet_dts_us_,\s*'
    r'last_packet_flags_,\s*'
    r'len\);\s*'
    r'fflush\(stdout\);\s*'
    r'mpp_packet_deinit\(&packet\);\s*'
    r'printf\("\[EXP23_RELEASE_PROBE\] encode after  mpp_packet_deinit packet=%p\\n", packet\);\s*'
    r'fflush\(stdout\);',
    re.S
)
s, n1 = pattern_encode_packet_probe.subn("\n            mpp_packet_deinit(&packet);", s)

pattern_frame_probe = re.compile(
    r'printf\("\[EXP23_RELEASE_PROBE\] before mpp_frame_deinit frame=%p pts=%lld\\n",\s*'
    r'frame,\s*'
    r'\(long long\)next_pts_us_\);\s*'
    r'fflush\(stdout\);\s*'
    r'mpp_frame_deinit\(&frame\);\s*'
    r'printf\("\[EXP23_RELEASE_PROBE\] after  mpp_frame_deinit frame=%p\\n", frame\);\s*'
    r'fflush\(stdout\);',
    re.S
)
s, n2 = pattern_frame_probe.subn("mpp_frame_deinit(&frame);", s)

# 4. 防御：如果还残留 EXP23_RELEASE_PROBE 行，直接报错，让用户知道源码没清干净
if "EXP23_RELEASE_PROBE" in s:
    print("[WARN] EXP23_RELEASE_PROBE still exists; please inspect source")
else:
    print("[OK] no EXP23_RELEASE_PROBE remains")

p.write_text(s)
print("[OK] get_header fixed to MPP_ENC_GET_HDR_SYNC with external buffer")
print("[INFO] removed encode packet probe blocks:", n1)
print("[INFO] removed frame probe blocks:", n2)
PY

python3 "$OUT/fix_header_sync_buffer.py"

echo
echo "========== source check: get_header =========="
grep -nA85 -B8 "MppH264Encoder::get_header" src/mpp_h264_encoder.cpp

echo
echo "========== source check: release =========="
grep -nA28 -B8 "MppH264Encoder::release" src/mpp_h264_encoder.cpp

echo
echo "========== key grep =========="
grep -nE "GET_EXTRA_INFO|GET_HDR_SYNC|EXP23_RELEASE_PROBE|mpp_packet_init|mpp_packet_set_length|mpp_frame_set_pts|mpp_packet_get_pts|mpp_packet_get_dts" \
  src/mpp_h264_encoder.cpp || true

echo
echo "========== rebuild =========="
rm -rf build
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async -j4
cd ..

echo
echo "exp23-3 header sync buffer fix build done"

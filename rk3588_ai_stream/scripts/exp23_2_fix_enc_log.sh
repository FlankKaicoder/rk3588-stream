#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT=output/exp23_2_fix_enc_log
mkdir -p "$OUT/source_backup"

cp -a src/main_exp21_detect_mpp_encode_async.cpp \
  "$OUT/source_backup/main_exp21_detect_mpp_encode_async.cpp.before_fix_enc_log"

cat > "$OUT/fix_enc_log.py" <<'PY'
from pathlib import Path
import sys

p = Path("src/main_exp21_detect_mpp_encode_async.cpp")
lines = p.read_text().splitlines()

out = []
i = 0
replaced = False

while i < len(lines):
    line = lines[i]

    if 'printf("[ENC] encoded=' in line:
        # 保留 printf 前面的缩进
        indent = line[:len(line) - len(line.lstrip())]

        # 跳过旧 printf 整块，直到遇到包含 total_ms); 的行
        j = i
        while j < len(lines):
            if "total_ms);" in lines[j]:
                j += 1
                break
            j += 1

        if j >= len(lines):
            print("[ERR] cannot find end of old [ENC] printf block")
            sys.exit(1)

        new_block = [
            f'{indent}printf("[ENC] encoded=%d src_frame=%d packet=%zu input_pts=%lld pkt_pts=%lld pkt_dts=%lld intra=%d qdelay=%.3f encode=%.3f write=%.3f total=%.3f\\n",',
            f'{indent}       cnt,',
            f'{indent}       item.frame_id,',
            f'{indent}       local_packet.size(),',
            f'{indent}       (long long)item.pts_us,',
            f'{indent}       (long long)exp23_mpp_packet_pts_us,',
            f'{indent}       (long long)exp23_mpp_packet_dts_us,',
            f'{indent}       exp23_is_intra ? 1 : 0,',
            f'{indent}       exp23_queue_delay_us >= 0 ? exp23_queue_delay_us / 1000.0 : -1.0,',
            f'{indent}       enc_ms,',
            f'{indent}       write_ms,',
            f'{indent}       total_ms);',
        ]

        out.extend(new_block)
        i = j
        replaced = True
        continue

    out.append(line)
    i += 1

if not replaced:
    print("[ERR] did not find [ENC] printf block")
    sys.exit(1)

p.write_text("\n".join(out) + "\n")
print("[OK] fixed [ENC] printf block")
PY

python3 "$OUT/fix_enc_log.py"

echo
echo "========== check printf block =========="
grep -nA16 -B4 '\[ENC\] encoded=' src/main_exp21_detect_mpp_encode_async.cpp

echo
echo "========== rebuild =========="
rm -rf build
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async -j4
cd ..

echo
echo "exp23-2 build done"

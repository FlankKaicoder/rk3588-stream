#!/usr/bin/env bash
set -e

cd ~/projects/rk3588_ai_stream

OUT=output/exp23_1_mpp_pts_patch_fix
mkdir -p "$OUT/source_backup"

echo "========== backup current patched source =========="
cp -a src/main_exp21_detect_mpp_encode_async.cpp "$OUT/source_backup/main_exp21_detect_mpp_encode_async.cpp.broken_pts_patch"
cp -a include/mpp_h264_encoder.hpp "$OUT/source_backup/mpp_h264_encoder.hpp"
cp -a src/mpp_h264_encoder.cpp "$OUT/source_backup/mpp_h264_encoder.cpp"

cat > "$OUT/fix_pts_csv_scope.py" <<'PY'
from pathlib import Path
import re
import sys

p = Path("src/main_exp21_detect_mpp_encode_async.cpp")
s = p.read_text()

def fail(msg):
    print("[ERR]", msg)
    sys.exit(1)

# 1. 找 argv[6] 对应的 H.264 输出路径变量
# 支持：
# const char *xxx = argv[6];
# char *xxx = argv[6];
# std::string xxx = argv[6];
patterns = [
    r'(?:const\s+char\s*\*|char\s*\*)\s*(\w+)\s*=\s*argv\s*\[\s*6\s*\]\s*;',
    r'std::string\s+(\w+)\s*=\s*argv\s*\[\s*6\s*\]\s*;',
]

out_var = None
for pat in patterns:
    m = re.search(pat, s)
    if m:
        out_var = m.group(1)
        break

if not out_var:
    print("[DEBUG] argv[6] related lines:")
    for i, line in enumerate(s.splitlines(), 1):
        if "argv[6]" in line or "h264" in line.lower() or "output" in line.lower():
            print(f"{i}: {line}")
    fail("cannot find output h264 variable from argv[6]")

print("[INFO] detected output h264 variable:", out_var)

# 2. 删除之前错误插入到 profile_csv 后面的 enc_pts_csv 块
s = re.sub(
    r'\n\s*std::string\s+enc_pts_csv_path\s*=\s*std::string\s*\([^)]+\)\s*\+\s*"\.pts\.csv"\s*;\s*'
    r'\n\s*std::ofstream\s+enc_pts_csv\s*\(\s*enc_pts_csv_path\s*\)\s*;\s*'
    r'\n\s*enc_pts_csv\s*<<\s*"frame_id,input_pts_us,mpp_packet_pts_us,mpp_packet_dts_us,"\s*'
    r'\n\s*"pts_match,is_intra,queue_delay_ms,encode_wall_ms,packet_size\\n"\s*;',
    '',
    s,
    flags=re.S
)

# 兼容另一种被格式化成一行的情况
s = re.sub(
    r'\n\s*std::string\s+enc_pts_csv_path\s*=\s*std::string\s*\([^)]+\)\s*\+\s*"\.pts\.csv"\s*;\s*'
    r'\n\s*std::ofstream\s+enc_pts_csv\s*\(\s*enc_pts_csv_path\s*\)\s*;\s*'
    r'\n\s*enc_pts_csv\s*<<[^;]+packet_size\\n"\s*;',
    '',
    s,
    flags=re.S
)

# 3. 如果还有 output_h264_path 的错误引用，替换成真实变量
s = s.replace("std::string(output_h264_path)", f"std::string({out_var})")

# 4. 把 enc_pts_csv 声明插入到 encoder_thread 定义之前
if "std::ofstream enc_pts_csv(enc_pts_csv_path);" not in s:
    marker = "    std::thread encoder_thread([&]() {"
    if marker not in s:
        fail("cannot find encoder_thread marker")

    block = f'''
    std::string enc_pts_csv_path = std::string({out_var}) + ".pts.csv";
    std::ofstream enc_pts_csv(enc_pts_csv_path);
    enc_pts_csv << "frame_id,input_pts_us,mpp_packet_pts_us,mpp_packet_dts_us,"
                   "pts_match,is_intra,queue_delay_ms,encode_wall_ms,packet_size\\n";

'''
    s = s.replace(marker, block + marker, 1)

# 5. 确保结尾打印 enc_pts_csv_path 的地方在 main 作用域内即可
# 如果之前没有插入打印，则补一条
if "enc pts csv saved" not in s:
    old = '    printf("async_avg_encode_ms  : %.3f\\n", async_avg_encode_ms);'
    if old in s:
        s = s.replace(
            old,
            old + '\n    printf("enc pts csv saved   : %s\\n", enc_pts_csv_path.c_str());',
            1
        )

p.write_text(s)
print("[OK] fixed enc_pts_csv scope and output h264 variable")
PY

python3 "$OUT/fix_pts_csv_scope.py"

echo
echo "========== grep fixed source =========="
grep -nE "argv\\[6\\]|enc_pts_csv_path|enc_pts_csv|std::thread encoder_thread|output_h264_path" \
  src/main_exp21_detect_mpp_encode_async.cpp || true

echo
echo "========== rebuild =========="
rm -rf build
mkdir -p build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make exp21_detect_mpp_encode_async -j4
cd ..

echo
echo "========== build done =========="

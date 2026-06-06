#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

SRC=/home/cat/lubancat_ai_manual_code/example/utils/image_utils.c
OUT=output/exp20_1_rga_colorfill_cpu_fallback

mkdir -p "$OUT"

if [ ! -f "$SRC" ]; then
    echo "ERROR: source file not found: $SRC"
    exit 1
fi

python3 - <<'PY'
from pathlib import Path
import shutil
import datetime
import re

src = Path("/home/cat/lubancat_ai_manual_code/example/utils/image_utils.c")
out = Path("output/exp20_1_rga_colorfill_cpu_fallback")
out.mkdir(parents=True, exist_ok=True)

text = src.read_text(errors="ignore")

marker_begin = "EXP20_1_CPU_LETTERBOX_FILL_BEGIN"
marker_end = "EXP20_1_CPU_LETTERBOX_FILL_END"

if marker_begin in text:
    print("already patched:", src)
    raise SystemExit(0)

func_name = "convert_image_with_letterbox"
idx = text.find(func_name)
if idx < 0:
    raise SystemExit(f"ERROR: {func_name} not found in {src}")

brace = text.find("{", idx)
if brace < 0:
    raise SystemExit("ERROR: function opening brace not found")

depth = 0
end = None
for i in range(brace, len(text)):
    ch = text[i]
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break

if end is None:
    raise SystemExit("ERROR: function end not found")

func = text[brace:end]

# 找函数内部 imfill 调用。通常就是 RGA color fill 的封装。
m = re.search(r"(?P<indent>^[ \t]*)(?P<stmt>(?:ret\s*=\s*)?imfill\s*\((?P<args>[^;]+)\)\s*;)", func, flags=re.M | re.S)
if not m:
    raise SystemExit("ERROR: imfill(...) statement not found inside convert_image_with_letterbox")

stmt_start = brace + m.start("stmt")
stmt_end = brace + m.end("stmt")
indent = m.group("indent")
stmt = m.group("stmt")
args = m.group("args")

# imfill 第一个参数一般是 dst_img / dst_image
first_arg = args.split(",")[0].strip()

# 去掉可能的取地址符号，保留指针表达式判断
dst_expr = first_arg

replacement = f'''/* {marker_begin}: replace RGA ColorFill with CPU memset for YOLO letterbox padding. */
{indent}if ({dst_expr} != NULL && {dst_expr}->virt_addr != NULL)
{indent}{{
{indent}    int exp20_1_fill_size = {dst_expr}->size;
{indent}    if (exp20_1_fill_size <= 0)
{indent}    {{
{indent}        exp20_1_fill_size = get_image_size({dst_expr});
{indent}    }}
{indent}    if (exp20_1_fill_size > 0)
{indent}    {{
{indent}        unsigned char exp20_1_fill_byte = (unsigned char)(color & 0xff);
{indent}        memset({dst_expr}->virt_addr, exp20_1_fill_byte, exp20_1_fill_size);
{indent}        ret = 0;
{indent}    }}
{indent}    else
{indent}    {{
{indent}        {stmt}
{indent}    }}
{indent}}}
{indent}else
{indent}{{
{indent}    {stmt}
{indent}}}
/* {marker_end} */'''

new_text = text[:stmt_start] + replacement + text[stmt_end:]

if "#include <string.h>" not in new_text and "#include <cstring>" not in new_text:
    lines = new_text.splitlines()
    last_inc = -1
    for i, line in enumerate(lines):
        if line.strip().startswith("#include"):
            last_inc = i
    if last_inc >= 0:
        lines.insert(last_inc + 1, "#include <string.h>")
        new_text = "\n".join(lines) + "\n"

ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
backup = out / f"image_utils.c.bak_{ts}"
shutil.copy2(src, backup)
src.write_text(new_text)

restore = out / "restore_real_image_utils_patch.sh"
restore.write_text(f"""#!/usr/bin/env bash
set -e
cp '{backup}' '{src}'
echo 'restored {src} from {backup}'
""")
restore.chmod(0o755)

print("patched:", src)
print("backup :", backup)
print("restore:", restore)
print()
print("replaced statement:")
print(stmt)
print()
print("first arg:", first_arg)
PY

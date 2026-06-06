#!/usr/bin/env bash
set -euo pipefail

cd ~/projects/rk3588_ai_stream

SRC=third_party/lubancat_common_utils/image_utils.c
OUT=output/exp20_1_rga_colorfill_cpu_fallback

mkdir -p "$OUT"

python3 - <<'PY'
from pathlib import Path
import shutil
import datetime

src = Path("third_party/lubancat_common_utils/image_utils.c")
out = Path("output/exp20_1_rga_colorfill_cpu_fallback")
out.mkdir(parents=True, exist_ok=True)

text = src.read_text(errors="ignore")

marker_begin = "EXP20_1_LOCAL_SKIP_RGA_IMFILL_BEGIN"
marker_end = "EXP20_1_LOCAL_SKIP_RGA_IMFILL_END"

if marker_begin in text:
    print("already patched:", src)
    raise SystemExit(0)

old = '''    if (drect.width != dstWidth || drect.height != dstHeight) {
        im_rect dst_whole_rect = {0, 0, dstWidth, dstHeight};
        int imcolor;
        char* p_imcolor = &imcolor;
        p_imcolor[0] = color;
        p_imcolor[1] = color;
        p_imcolor[2] = color;
        p_imcolor[3] = color;
        printf("fill dst image (x y w h)=(%d %d %d %d) with color=0x%x\\n",
            dst_whole_rect.x, dst_whole_rect.y, dst_whole_rect.width, dst_whole_rect.height, imcolor);
        ret_rga = imfill(rga_buf_dst, dst_whole_rect, imcolor);
        if (ret_rga <= 0) {
            if (dst != NULL) {
                size_t dst_size = get_image_size(dst_img);
                memset(dst, color, dst_size);
            } else {
                printf("Warning: Can not fill color on target image\\n");
            }
        }
    }
'''

new = '''    if (drect.width != dstWidth || drect.height != dstHeight) {
        /* EXP20_1_LOCAL_SKIP_RGA_IMFILL_BEGIN:
         * Original code calls RGA imfill first, then falls back to CPU memset
         * after RGA_COLORFILL fails. On RK3588 RGB888 letterbox this fails
         * every frame. Use CPU memset directly for padding, then keep RGA
         * improcess below for resize/copy.
         */
        if (dst != NULL) {
            size_t dst_size = get_image_size(dst_img);
            memset(dst, color, dst_size);
        } else {
            printf("Warning: Can not fill color on target image\\n");
        }
        /* EXP20_1_LOCAL_SKIP_RGA_IMFILL_END */
    }
'''

if old not in text:
    idx = text.find("ret_rga = imfill")
    if idx < 0:
        raise SystemExit("ERROR: ret_rga = imfill not found in local image_utils.c")
    print("ERROR: exact block not matched. Context:")
    print(text[max(0, idx-600):min(len(text), idx+600)])
    raise SystemExit(1)

ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
backup = out / f"local_image_utils.c.bak_{ts}"
shutil.copy2(src, backup)

src.write_text(text.replace(old, new, 1))

restore = out / "restore_local_image_utils_patch.sh"
restore.write_text(f"""#!/usr/bin/env bash
set -e
cp '{backup}' '{src}'
echo 'restored {src} from {backup}'
""")
restore.chmod(0o755)

print("patched:", src)
print("backup :", backup)
print("restore:", restore)
PY

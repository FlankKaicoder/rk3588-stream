#!/usr/bin/env bash
set -u

cd ~/projects/rk3588_ai_stream

OUT=output/exp20_4_audio_only_rtsp/env_bisect
mkdir -p "$OUT"

BASE_ENV=(
  "PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
  "HOME=/tmp"
)

TEST_CMD=(
  timeout 4 arecord
  -D hw:2,0
  -f S16_LE
  -r 48000
  -c 2
  -d 1
)

echo "========== baseline =========="
rm -f "$OUT/base.wav" "$OUT/base.log"
env -i "${BASE_ENV[@]}" "${TEST_CMD[@]}" "$OUT/base.wav" > "$OUT/base.log" 2>&1
BASE_RC=$?
echo "BASE_RC=$BASE_RC"
ls -lh "$OUT/base.wav" 2>/dev/null || true

if [ "$BASE_RC" -ne 0 ]; then
    echo "baseline failed, stop"
    cat "$OUT/base.log"
    exit 1
fi

echo
echo "========== one-variable test =========="

env | sort > "$OUT/current_env.txt"
: > "$OUT/bad_details.log"

while IFS='=' read -r KEY VALUE; do
    [ -n "$KEY" ] || continue

    case "$KEY" in
        PWD|OLDPWD|SHLVL|_|RANDOM|SECONDS|LINENO|BASH*|EUID|UID|PPID|SHELLOPTS|BASHOPTS)
            continue
            ;;
    esac

    SAFE_KEY=$(echo "$KEY" | tr -c 'A-Za-z0-9_' '_')
    WAV="$OUT/test_${SAFE_KEY}.wav"
    LOG="$OUT/test_${SAFE_KEY}.log"

    rm -f "$WAV" "$LOG"

    env -i "${BASE_ENV[@]}" "$KEY=$VALUE" \
      "${TEST_CMD[@]}" "$WAV" \
      > "$LOG" 2>&1

    RC=$?

    if [ "$RC" -ne 0 ]; then
        echo "BAD_OR_TIMEOUT key=$KEY rc=$RC value=$VALUE"
        {
            echo "----- BAD key=$KEY rc=$RC -----"
            echo "value=$VALUE"
            tail -60 "$LOG"
            echo
        } >> "$OUT/bad_details.log"
    else
        echo "OK key=$KEY"
    fi

done < "$OUT/current_env.txt"

echo
echo "========== bad details =========="
cat "$OUT/bad_details.log" 2>/dev/null || echo "no bad variable found"

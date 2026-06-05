#!/usr/bin/env bash  #指定解释器
set -e  #防御性设置

cd ~/projects/rk3588_ai_stream
#定义输出目录和日志文件
OUT_DIR=output/exp18_av_mux_file
LOG="$OUT_DIR/18_av_mux_file.log"
#创建目录清空旧内容
mkdir -p "$OUT_DIR"
: > "$LOG"
#定义默认的输入文件路劲
DEFAULT_VIDEO="output/exp08_4_detect_fifo_mpp_clean/live_detect_clean_300f_1280x720.mp4"
DEFAULT_AUDIO="output/exp17_realtime_audio/live_capture_aac_128k_20s.m4a"
#小巧思：如果传了参数就用没有就用默认值
VIDEO_IN="${1:-$DEFAULT_VIDEO}"
AUDIO_IN="${2:-$DEFAULT_AUDIO}"

MUX_COPY="$OUT_DIR/detect_with_audio_copy.mp4"  #原封不动复制音视频码流的MP4
MUX_REENC_AAC="$OUT_DIR/detect_with_audio_reenc_aac.mp4" #重新对音频进行AAC编码的MP4
MUX_SHORT="$OUT_DIR/detect_with_audio_shortest.mp4"   #裁剪之后的音频

AUDIO_GAIN="$OUT_DIR/audio_gain12db.m4a"   #音频增益
MUX_GAIN="$OUT_DIR/detect_with_audio_gain12db.mp4"   #音频音量放大12dB之后的mp4

echo "========== 18 AV mux file ==========" | tee -a "$LOG"
date | tee -a "$LOG"                              #屏幕上的输出同时追加进日志文件
echo "video input: $VIDEO_IN" | tee -a "$LOG"
echo "audio input: $AUDIO_IN" | tee -a "$LOG"
#不存在就退出并且列出内容
if [ ! -f "$VIDEO_IN" ]; then  
    echo "ERROR: video input not found: $VIDEO_IN" | tee -a "$LOG"
    echo "Available mp4 files:" | tee -a "$LOG"
    find output -maxdepth 4 -type f -name "*.mp4" | sort | tee -a "$LOG" || true
    exit 1
fi

if [ ! -f "$AUDIO_IN" ]; then
    echo "ERROR: audio input not found: $AUDIO_IN" | tee -a "$LOG"
    echo "Available audio files:" | tee -a "$LOG"
    find output -maxdepth 4 -type f \( -name "*.m4a" -o -name "*.aac" -o -name "*.ogg" -o -name "*.wav" \) | sort | tee -a "$LOG" || true
    exit 1
fi
#体检：ffprobe看看音视频详细参数是不是对的上
echo | tee -a "$LOG"
echo "========== input video ffprobe ==========" | tee -a "$LOG"
ffprobe -hide_banner "$VIDEO_IN" 2>&1 | tee "$OUT_DIR/input_video_ffprobe.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== input audio ffprobe ==========" | tee -a "$LOG"
ffprobe -hide_banner "$AUDIO_IN" 2>&1 | tee "$OUT_DIR/input_audio_ffprobe.log" | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== input audio volume ==========" | tee -a "$LOG"
ffmpeg -hide_banner -i "$AUDIO_IN" -af volumedetect -f null - 2>&1 \
    | tee "$OUT_DIR/input_audio_volumedetect.log" \
    | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== 18-1 mux by stream copy ==========" | tee -a "$LOG"
echo "Video copy + Audio copy + shortest." | tee -a "$LOG"
#直接流拷贝合流
ffmpeg -y -hide_banner \
    -i "$VIDEO_IN" \
    -i "$AUDIO_IN" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a copy \
    -shortest \
    -movflags +faststart \
    "$MUX_COPY" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 18-2 mux with AAC re-encode ==========" | tee -a "$LOG"
echo "This is a fallback version if audio container/codec copy has compatibility issues." | tee -a "$LOG"
#音频重编码之后合流
ffmpeg -y -hide_banner \
    -i "$VIDEO_IN" \
    -i "$AUDIO_IN" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a aac \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    -shortest \
    -movflags +faststart \
    "$MUX_REENC_AAC" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 18-3 make +12dB audio then mux ==========" | tee -a "$LOG"
echo "Because the current microphone level is low, this file is only for listening review." | tee -a "$LOG"
#放大音量之后合流
ffmpeg -y -hide_banner \
    -i "$AUDIO_IN" \
    -af "volume=12dB" \
    -c:a aac \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    "$AUDIO_GAIN" 2>&1 | tee -a "$LOG"

ffmpeg -y -hide_banner \
    -i "$VIDEO_IN" \
    -i "$AUDIO_GAIN" \
    -map 0:v:0 \
    -map 1:a:0 \
    -c:v copy \
    -c:a copy \
    -shortest \
    -movflags +faststart \
    "$MUX_GAIN" 2>&1 | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== output ffprobe ==========" | tee -a "$LOG"
#输出检验总结收尾
for f in "$MUX_COPY" "$MUX_REENC_AAC" "$MUX_GAIN"; do
    echo | tee -a "$LOG"
    echo "----- ffprobe: $f -----" | tee -a "$LOG"
    ffprobe -hide_banner "$f" 2>&1 | tee -a "$LOG" || true

    echo | tee -a "$LOG"
    echo "----- streams compact: $f -----" | tee -a "$LOG"
    ffprobe -v error \
        -show_entries stream=index,codec_type,codec_name,width,height,sample_rate,channels,bit_rate,duration \
        -of compact=p=0:nk=1 \
        "$f" 2>&1 | tee -a "$LOG" || true
done

echo | tee -a "$LOG"
echo "========== audio volume in muxed gain file ==========" | tee -a "$LOG"
ffmpeg -hide_banner -i "$MUX_GAIN" -map 0:a:0 -af volumedetect -f null - 2>&1 \
    | tee "$OUT_DIR/mux_gain_audio_volumedetect.log" \
    | tee -a "$LOG" || true

echo | tee -a "$LOG"
echo "========== final files ==========" | tee -a "$LOG"
find "$OUT_DIR" -maxdepth 1 -type f -printf "%f %s bytes\n" | sort | tee "$OUT_DIR/file_sizes.txt" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "========== 18 summary ==========" | tee -a "$LOG"
echo "video_input=$VIDEO_IN" | tee -a "$LOG"
echo "audio_input=$AUDIO_IN" | tee -a "$LOG"
echo "mux_copy=$MUX_COPY" | tee -a "$LOG"
echo "mux_reenc_aac=$MUX_REENC_AAC" | tee -a "$LOG"
echo "mux_gain=$MUX_GAIN" | tee -a "$LOG"
echo "log=$LOG" | tee -a "$LOG"
echo "18 AV mux file finished." | tee -a "$LOG"

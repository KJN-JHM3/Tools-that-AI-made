#!/bin/bash

# ヘルプメッセージ表示関数
show_help() {
    cat << EOF
使用方法: $0 [オプション] <入力動画ファイル>

オプション:
  -r, --resolution <高さ>   解像度の高さをpxで指定 (例: 135, 135p。デフォルト: 135)
  -f, --fps <FPS>           フレームレートを指定 (デフォルト: 30)
  -s, --size <MB>           目標ファイルサイズをMBで指定 (デフォルト: 9.9)
  -a, --audio <kbps>        音声ビットレートをkbpsで指定 (デフォルト: 128)
  -m, --max-attempts <回数> サイズ超過時の最大再試行回数を指定 (デフォルト: 5)
  -o, --output <ファイル名> 出力ファイル名を指定 (デフォルト: <入力ファイル名>_<高さ>p<FPS>fps_hw.mp4)
  -h, --help                このヘルプを表示

例:
  $0 -s 5.0 -r 240p -f 60 -o output.mp4 input.mp4
  $0 input.mp4 --size 9.9 --resolution 135 --fps 30
EOF
}

# --- デフォルト値の設定 ---
RESOLUTION=135
FPS=30
TARGET_MB=9.9
AUDIO_KBPS=128
MAX_ATTEMPTS=10
OUTPUT=""
INPUT=""

# --- 引数のパース ---
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -r|--resolution)
            RESOLUTION="${2%[pP]}"
            shift 2
            ;;
        -f|--fps) FPS="$2"; shift 2 ;;
        -s|--size) TARGET_MB="$2"; shift 2 ;;
        -a|--audio) AUDIO_KBPS="$2"; shift 2 ;;
        -m|--max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
        -o|--output) OUTPUT="$2"; shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        -*) echo "エラー: 不明なオプションです -> $1"; show_help; exit 1 ;;
        *)
            if [ -z "$INPUT" ]; then
                INPUT="$1"
            else
                echo "エラー: 入力ファイルは1つだけ指定してください。"
                exit 1
            fi
            shift ;;
    esac
done

if [ -z "$INPUT" ]; then
    echo "エラー: 入力ファイルが指定されていません。"
    show_help
    exit 1
fi

if [ -z "$OUTPUT" ]; then
    OUTPUT="${INPUT%.*}_${RESOLUTION}p${FPS}fps.mp4"
fi

# --- 1. ハードウェアエンコーダーの自動検出 ---
echo "利用可能なエンコーダーを検索中..."
ENCODERS_LIST=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep "h264")

ENCODER="libx264"
ENCODER_OPTS=""
HWACCEL_OPTS=""

if echo "$ENCODERS_LIST" | grep -q "h264_nvenc"; then
    ENCODER="h264_nvenc"
    ENCODER_OPTS="-rc vbr"
    HWACCEL_OPTS="-hwaccel cuda"
    echo ">> NVIDIA NVENC を検出 (デコードもCUDAを使用)"
elif echo "$ENCODERS_LIST" | grep -q "h264_qsv"; then
    ENCODER="h264_qsv"
    HWACCEL_OPTS="-hwaccel qsv"
    echo ">> Intel QSV を検出"
elif echo "$ENCODERS_LIST" | grep -q "h264_amf"; then
    ENCODER="h264_amf"
    HWACCEL_OPTS="-hwaccel auto"
    echo ">> AMD AMF を検出"
elif echo "$ENCODERS_LIST" | grep -q "h264_videotoolbox"; then
    ENCODER="h264_videotoolbox"
    HWACCEL_OPTS="-hwaccel videotoolbox"
    echo ">> Apple VideoToolbox を検出"
elif echo "$ENCODERS_LIST" | grep -q "h264_vaapi"; then
    ENCODER="h264_vaapi"
    HWACCEL_OPTS="-hwaccel vaapi"
    echo ">> VAAPI を検出"
else
    echo ">> ハードウェアエンコーダーが見つかりませんでした (CPU: libx264 を使用)"
fi

# --- 2. 動画情報の取得 ---
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT")
HAS_AUDIO=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of default=noprint_wrappers=1:nokey=1 "$INPUT" | head -n 1)

if [ -z "$DURATION" ]; then
    echo "エラー: 動画の長さを取得できませんでした。"
    exit 1
fi

if [ "$HAS_AUDIO" = "audio" ]; then
    AUDIO_OPTS="-c:a aac -b:a ${AUDIO_KBPS}k"
else
    AUDIO_OPTS="-an"
fi

# --- 3. 初期ビットレートの計算 ---
# 理論値の1.2倍を初期値とすることで、ハードウェアエンコーダーでのビットレート低下を防ぎ、上限を使い切らせます
INITIAL_VKBPS=$(awk -v dur="$DURATION" -v target="$TARGET_MB" -v audio="$AUDIO_KBPS" 'BEGIN {
    target_bits = target * 1000000 * 8;
    audio_bits = dur * audio * 1000;
    video_bits = target_bits - audio_bits;
    print int(video_bits / dur / 1000 * 1.2);
}')

CURRENT_VKBPS=$INITIAL_VKBPS
ATTEMPT=1

echo "-----------------------------------"
echo "対象: $INPUT"
echo "長さ: ${DURATION}秒"
echo "解像度: 高さ ${RESOLUTION}px / ${FPS} fps"
echo "目標: ${TARGET_MB}MB の 95%〜100% に収める (画質最大化)"
echo "初期映像ビットレート: ${CURRENT_VKBPS} kbps"
echo "出力先: $OUTPUT"
echo "-----------------------------------"

# --- 4. エンコード & 再試行ループ ---
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "試行 ${ATTEMPT}/${MAX_ATTEMPTS}: ビットレート ${CURRENT_VKBPS} kbps / ${FPS} fps でエンコード中..."

    # エンコード実行
    # -maxrate と -bufsize を指定し、ビットレートの上限を使い切らせる
    ffmpeg -y $HWACCEL_OPTS -i "$INPUT" \
        -c:v "$ENCODER" $ENCODER_OPTS \
        -b:v "${CURRENT_VKBPS}k" \
        -maxrate "${CURRENT_VKBPS}k" \
        -bufsize "$((CURRENT_VKBPS * 2))k" \
        -r "${FPS}" \
        $AUDIO_OPTS \
        -vf "scale=-2:${RESOLUTION}" \
        -movflags +faststart \
        "$OUTPUT" 2>/dev/null

    SIZE_BYTES=$(wc -c < "$OUTPUT" | tr -d ' ')
    SIZE_MB=$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.4f", b / 1000 / 1000 }')

    # 判定: 目標サイズの 95%〜100% なら成功
    IS_OK=$(awk -v size="$SIZE_BYTES" -v limit="$TARGET_MB" 'BEGIN {
        limit_bytes = limit * 1000000;
        print (size >= limit_bytes * 0.95 && size <= limit_bytes) ? 1 : 0
    }')

    # 判定: 目標サイズの 95% 未満なら「小さすぎ（画質不足）」
    IS_TOO_SMALL=$(awk -v size="$SIZE_BYTES" -v limit="$TARGET_MB" 'BEGIN {
        limit_bytes = limit * 1000000;
        print (size < limit_bytes * 0.95) ? 1 : 0
    }')

    if [ "$IS_OK" -eq 1 ]; then
        echo "成功！ ファイルサイズ: ${SIZE_MB} MB (目標範囲内: 95%〜100%)"
        break
    elif [ "$IS_TOO_SMALL" -eq 1 ]; then
        echo "ファイルサイズが目標より小さすぎます (${SIZE_MB} MB)。画質を上げるためビットレートを上げて再試行します..."

        if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
            echo "再試行回数の上限に達しました。"
            exit 1
        fi

        # ビットレートを上げる (目標サイズ / 実際のサイズ) の比率をかける
        CURRENT_VKBPS=$(awk -v old="$CURRENT_VKBPS" -v target="$TARGET_MB" -v actual="$SIZE_MB" 'BEGIN {
            ratio = target / actual;
            new_rate = old * ratio;
            print int(new_rate);
        }')
    else
        echo "失敗... ファイルサイズ: ${SIZE_MB} MB (超過)"

        if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
            echo "再試行回数の上限に達しました。"
            exit 1
        fi

        # ビットレートを下げる
        CURRENT_VKBPS=$(awk -v old="$CURRENT_VKBPS" -v target="$TARGET_MB" -v actual="$SIZE_MB" 'BEGIN {
            ratio = target / actual;
            new_rate = old * ratio * 0.95;
            if (new_rate < 10) new_rate = 10;
            print int(new_rate);
        }')
        echo ">> ビットレートを ${CURRENT_VKBPS} kbps に下げて再試行します..."
    fi

    ATTEMPT=$((ATTEMPT + 1))
done

echo "-----------------------------------"
echo "完了: $OUTPUT"
echo "最終サイズ: ${SIZE_MB} MB"
echo "-----------------------------------"

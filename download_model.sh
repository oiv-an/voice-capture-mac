#!/usr/bin/env bash
#
# download_model.sh — скачивает ggml-модель whisper в папку моделей приложения.
#
# Использование:
#   ./download_model.sh            # по умолчанию base
#   ./download_model.sh small      # tiny|base|small|medium|large-v3
#
set -euo pipefail

MODEL="${1:-base}"
MODELS_DIR="$HOME/Library/Application Support/VoiceCapture/Models"
mkdir -p "$MODELS_DIR"

FILE="ggml-${MODEL}.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${FILE}"
DEST="$MODELS_DIR/$FILE"

if [[ -f "$DEST" ]]; then
  echo "Модель уже скачана: $DEST"
  exit 0
fi

echo "==> Скачиваю $FILE"
echo "    из $URL"
echo "    в  $DEST"
curl -L --fail --progress-bar -o "$DEST" "$URL"

echo ""
echo "Готово: $DEST"
echo "Совет: для русского хорошо подходит 'small' или 'medium' (точнее, но медленнее)."

#!/bin/bash
# Быстрый запуск для разработки/отладки (без сборки .app).
# Хоткеи работают сразу, без клика по меню-бару (polling модификаторов).
# Логи пишутся в консоль. Ctrl+C для остановки.
set -e

echo "[dev] Сборка..."
swift build --product VoiceCapture 2>&1 | grep -vE "ld: warning" | grep -iE "error|complete" || true

# Убиваем старый процесс, если завис
pkill -f ".build/debug/VoiceCapture" 2>/dev/null || true
sleep 0.3

echo "[dev] Запуск. Зажми ⌘⌃ и говори. Ctrl+C для выхода."
exec .build/debug/VoiceCapture

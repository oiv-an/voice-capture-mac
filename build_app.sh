#!/usr/bin/env bash
#
# build_app.sh — собирает VoiceCapture.app (macOS application bundle).
#
# Шаги:
#   1) собирает whisper.cpp (если статической библиотеки ещё нет)
#   2) собирает release-бинарник SwiftPM вместе с FluidAudio
#   3) упаковывает VoiceCapture 3.3.0 в dist/VoiceCapture.app
#   4) подписывает bundle стабильной ad-hoc подписью и перезапускает приложение
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="VoiceCapture"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
VERSION="3.4.0"

# 1) whisper.cpp
if [[ ! -f "$ROOT/Vendor/install/lib/libwhisper_combined.a" ]]; then
  echo "==> Building whisper.cpp..."
  bash "$ROOT/build_whisper.sh"
fi

# 2) Swift release build
echo "==> swift build -c release"
swift build -c release

BIN="$ROOT/.build/release/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
  echo "ERROR: бинарник не найден: $BIN"
  exit 1
fi

# 3) Сборка .app bundle
echo "==> Packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>VoiceCapture</string>
    <key>CFBundleIdentifier</key>
    <string>com.ivol.voicecapture</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Меню-бар приложение без иконки в Dock -->
    <key>LSUIElement</key>
    <true/>
    <!-- Доступ к микрофону -->
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceCapture использует микрофон для записи речи и преобразования её в текст.</string>
    <!-- Apple Events (System Events) — для авто-вставки Cmd+V -->
    <key>NSAppleEventsUsageDescription</key>
    <string>VoiceCapture отправляет Cmd+V в активное приложение для авто-вставки распознанного текста.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc подпись со СТАБИЛЬНЫМ идентификатором.
# Без --deep и с явным --identifier — designated requirement привязывается к bundle id,
# поэтому при пересборке TCC-доступ (Accessibility/Микрофон) НЕ слетает.
echo "==> Codesign (ad-hoc, stable identifier)"
# Явный designated requirement по identifier (а не по cdhash),
# чтобы TCC опознавал приложение по bundle id и доступ не слетал при пересборке.
REQ_FILE="$(mktemp)"
cat > "$REQ_FILE" <<REQ
designated => identifier "com.ivol.voicecapture"
REQ
codesign --force --sign - \
  --identifier "com.ivol.voicecapture" \
  -r "$REQ_FILE" \
  "$APP/Contents/MacOS/$APP_NAME" || echo "  (codesign бинаря пропущен)"
codesign --force --sign - \
  --identifier "com.ivol.voicecapture" \
  -r "$REQ_FILE" \
  "$APP" || echo "  (codesign бандла пропущен)"
rm -f "$REQ_FILE"

echo ""
echo "DONE: $APP"

# 4) Перезапуск приложения: убиваем старый процесс и открываем свежий билд.
echo "==> Перезапуск приложения"
pkill -x "$APP_NAME" 2>/dev/null || true
pkill -f "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.5
open "$APP"
echo "Запущено: $APP"

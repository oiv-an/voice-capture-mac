#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP="$ROOT/dist/translation-screening/AppleScreening.app"
mkdir -p "$APP/Contents/MacOS"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  "$ROOT/research/ru-en-translation/apple/main.swift" \
  "$ROOT/Sources/VoiceCapture/AppleTranslationService.swift" \
  -o "$APP/Contents/MacOS/AppleScreening"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AppleScreening</string>
<key>CFBundleIdentifier</key><string>com.ivol.translation-screening</string>
<key>CFBundleExecutable</key><string>AppleScreening</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"

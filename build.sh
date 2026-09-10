#!/usr/bin/env bash
set -euo pipefail

APP_NAME="NotchNotes"
CONFIG="${1:-debug}"
RUN_FLAG="${2:-}"

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="build/$APP_NAME.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_PATH/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist   "$APP_DIR/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"

# ad-hoc подпись: без неё macOS может ругаться и сбрасывать настройки
codesign --force --sign - "$APP_DIR" >/dev/null

echo "✅ $APP_DIR"

if [ "$RUN_FLAG" = "--run" ]; then
  killall "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$APP_DIR"
  echo "🚀 запущено"
fi

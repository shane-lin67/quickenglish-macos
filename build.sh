#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/快译浮窗.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR" "$BUILD_DIR/ModuleCache"

clang \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path="$BUILD_DIR/ModuleCache" \
  -O2 \
  -framework Cocoa \
  -framework WebKit \
  -framework Carbon \
  -framework Security \
  "$PROJECT_DIR/Sources/main.m" \
  -o "$MACOS_DIR/QuickEnglish"

cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/index.html" "$RESOURCES_DIR/index.html"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"

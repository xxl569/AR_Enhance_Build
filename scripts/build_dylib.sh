#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$ROOT_DIR/build_work"
GEN_DIR="$WORK_DIR/intent_gen"
OUT_DIR="$ROOT_DIR/dist"

rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$WORK_DIR" "$GEN_DIR" "$OUT_DIR"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "iPhoneOS SDK: $SDK_PATH"

INTENT_BUILDER="$(xcrun --find intentbuilderc || true)"
echo "intentbuilderc: $INTENT_BUILDER"

if [ -n "$INTENT_BUILDER" ]; then
  "$INTENT_BUILDER" generate \
    -input "$ROOT_DIR/src/ARAutoStart.intentdefinition" \
    -output "$GEN_DIR" \
    -language Objective-C \
    -visibility public \
    -swiftVersion 5.0

  mkdir -p "$GEN_DIR/compiled"
  "$INTENT_BUILDER" compile \
    -input "$ROOT_DIR/src/ARAutoStart.intentdefinition" \
    -output "$GEN_DIR/compiled"
fi

if [ ! -f "$GEN_DIR/EnsureDaemonIntent.h" ]; then
  echo "错误：未生成 EnsureDaemonIntent.h"
  ls -la "$GEN_DIR"
  exit 1
fi

echo "=== 生成文件列表 ==="
find "$GEN_DIR" -maxdepth 3 -ls

echo "=== 编译 ARM64 AREnhance.dylib ==="
xcrun --sdk iphoneos clang++ \
  -arch arm64 \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=14.0 \
  -dynamiclib \
  -fobjc-arc \
  -O2 \
  -Wall -Wno-deprecated-declarations \
  -install_name "@executable_path/AREnhance.dylib" \
  -framework Foundation \
  -framework UIKit \
  -framework AVFoundation \
  -framework CoreFoundation \
  -lobjc \
  "$ROOT_DIR/src/AREnhance.mm" \
  -o "$OUT_DIR/AREnhance.dylib"

file "$OUT_DIR/AREnhance.dylib"
otool -L "$OUT_DIR/AREnhance.dylib"

echo "=== 编译 ARM64 ARAutoStartIntents (.appex 可执行文件) ==="
xcrun --sdk iphoneos clang++ \
  -arch arm64 \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=14.0 \
  -fobjc-arc \
  -fapplication-extension \
  -O2 \
  -Wall -Wno-deprecated-declarations \
  -e _NSExtensionMain \
  -I"$GEN_DIR" \
  -framework Foundation \
  -framework Intents \
  -lobjc \
  "$GEN_DIR/EnsureDaemonIntent.m" \
  "$ROOT_DIR/src/ARAutoStartIntentExtension.mm" \
  -o "$OUT_DIR/ARAutoStartIntents"

file "$OUT_DIR/ARAutoStartIntents"
otool -L "$OUT_DIR/ARAutoStartIntents"
nm -u "$OUT_DIR/ARAutoStartIntents" | grep NSExtensionMain

mkdir -p "$OUT_DIR/intent_resources"
echo "=== intentbuilderc compile 产物清单 ==="
find "$GEN_DIR/compiled" -ls
if [ -d "$GEN_DIR/compiled" ] && [ -n "$(ls -A "$GEN_DIR/compiled" 2>/dev/null || true)" ]; then
  cp -R "$GEN_DIR/compiled/"* "$OUT_DIR/intent_resources/"
else
  echo "警告：compiled 目录为空，回退拷贝原始 intentdefinition"
  cp "$ROOT_DIR/src/ARAutoStart.intentdefinition" "$OUT_DIR/intent_resources/ARAutoStart.intentdefinition"
fi

echo "=== 产物清单 ==="
find "$OUT_DIR" -ls

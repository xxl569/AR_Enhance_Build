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
    -classPrefix AR \
    -visibility public \
    -swiftVersion 5.0

  mkdir -p "$GEN_DIR/compiled"
  "$INTENT_BUILDER" compile \
    -input "$ROOT_DIR/src/ARAutoStart.intentdefinition" \
    -output "$GEN_DIR/compiled"
fi

if [ ! -f "$GEN_DIR/AREnsureDaemonIntent.h" ]; then
  echo "使用内置兼容 Intent 源码..."
  cat > "$GEN_DIR/AREnsureDaemonIntent.h" <<'EOF'
#import <Intents/Intents.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AREnsureDaemonIntentResponseCode) {
    AREnsureDaemonIntentResponseCodeUnspecified = 0,
    AREnsureDaemonIntentResponseCodeReady,
    AREnsureDaemonIntentResponseCodeContinueInApp,
    AREnsureDaemonIntentResponseCodeInProgress,
    AREnsureDaemonIntentResponseCodeSuccess,
    AREnsureDaemonIntentResponseCodeFailure,
    AREnsureDaemonIntentResponseCodeFailureRequiringAppLaunch
};

@interface AREnsureDaemonIntent : INIntent
@end

@interface AREnsureDaemonIntentResponse : INIntentResponse
@property (readwrite, copy, nullable, nonatomic) NSString *statusMessage;
- (instancetype)initWithCode:(AREnsureDaemonIntentResponseCode)code userActivity:(nullable NSUserActivity *)userActivity NS_DESIGNATED_INITIALIZER;
@property (readonly, nonatomic) AREnsureDaemonIntentResponseCode code;
@end

@protocol AREnsureDaemonIntentHandling <NSObject>
@required
- (void)handleEnsureDaemon:(AREnsureDaemonIntent *)intent completion:(void (^)(AREnsureDaemonIntentResponse *response))completion;
@end

NS_ASSUME_NONNULL_END
EOF

  cat > "$GEN_DIR/AREnsureDaemonIntent.m" <<'EOF'
#import "AREnsureDaemonIntent.h"

@implementation AREnsureDaemonIntent
@end

@interface AREnsureDaemonIntentResponse ()
@property (readwrite, nonatomic) AREnsureDaemonIntentResponseCode code;
@end

@implementation AREnsureDaemonIntentResponse
@dynamic statusMessage;
@synthesize code = _code;

- (instancetype)initWithCode:(AREnsureDaemonIntentResponseCode)code userActivity:(nullable NSUserActivity *)userActivity {
    self = [super init];
    if (self) {
        _code = code;
        self.userActivity = userActivity;
    }
    return self;
}
@end
EOF
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
  -I"$GEN_DIR" \
  -install_name "@executable_path/AREnhance.dylib" \
  -framework Foundation \
  -framework UIKit \
  -framework Intents \
  -framework AVFoundation \
  -framework CoreFoundation \
  -lobjc \
  "$GEN_DIR/AREnsureDaemonIntent.m" \
  "$ROOT_DIR/src/AREnhance.mm" \
  -o "$OUT_DIR/AREnhance.dylib"

file "$OUT_DIR/AREnhance.dylib"
otool -L "$OUT_DIR/AREnhance.dylib"

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

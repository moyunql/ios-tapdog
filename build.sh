#!/bin/bash
# 在 macOS 上直接编译出 TrollStore 可装的 ipa（无需 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "SDK: $SDK"

rm -rf build
APP="build/Payload/TapDog.app"
mkdir -p "$APP"

cflags=(
  -arch arm64
  -miphoneos-version-min=15.0
  -fobjc-arc
  -O2
  -Iheaders
  -isysroot "$SDK"
  -Wno-deprecated-declarations
  -Wno-nullability-completeness
  -Wno-unused-variable
)

libs=(
  -framework UIKit
  -framework Foundation
  -framework CoreGraphics
  -framework QuartzCore
  -framework IOSurface
  -framework AVFoundation
  -framework CoreFoundation
  -Wl,-undefined,dynamic_lookup
)

echo "== 编译 =="
xcrun --sdk iphoneos clang "${cflags[@]}" -o "$APP/TapDog" Sources/*.m "${libs[@]}"

cp Sources/Info.plist "$APP/Info.plist"

echo "== ldid 签名（写入 entitlements）=="
LDID="$(command -v ldid || true)"
if [ -z "$LDID" ]; then
  echo "ldid 未安装，尝试 brew install ldid"
  brew install ldid
  LDID="$(command -v ldid)"
fi
"$LDID" -S entitlements.plist "$APP/TapDog"
"$LDID" -S entitlements.plist "$APP" 2>/dev/null || true

echo "== 校验签名里的权限 =="
"$LDID" -e "$APP/TapDog" | grep -E "hid.client.event-dispatch|platform-application|window-hosting" || true

echo "== 打包 ipa =="
( cd build && zip -qry TapDog.ipa Payload )
ls -lh build/TapDog.ipa
echo "完成：build/TapDog.ipa"

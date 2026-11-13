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
  -framework AVFoundation
  -framework CoreFoundation
  -Wl,-undefined,dynamic_lookup
  -Wl,-headerpad_max_install_names
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

# ldid 自带的手写 XML 解析器不认 <!-- 注释 -->，签名前生成一份去掉注释的副本。
python3 - <<'PY'
import re, pathlib
src = pathlib.Path("entitlements.plist").read_text(encoding="utf-8")
plain = re.sub(r"<!--.*?-->", "", src, flags=re.S)
pathlib.Path("build/ent.plist").write_text(plain, encoding="utf-8")
print("entitlements 去注释完成，%d -> %d 字节" % (len(src), len(plain)))
PY

echo "-- 先试 ldid --"
if "$LDID" -S build/ent.plist "$APP/TapDog" 2>build/ldid.err; then
  echo "ldid 签名成功"
else
  echo "ldid 失败（$(cat build/ldid.err)），回退 codesign 临时签名"
  codesign --force --sign - --entitlements build/ent.plist "$APP/TapDog"
  echo "codesign 签名成功"
fi

echo "== 校验签名里的权限 =="
codesign -d --entitlements :- "$APP/TapDog" 2>/dev/null | grep -E "hid.client.event-dispatch|platform-application|accessibility-window-hosting" || true

echo "== 打包 ipa =="
( cd build && zip -qry TapDog.ipa Payload )
ls -lh build/TapDog.ipa
echo "完成：build/TapDog.ipa"

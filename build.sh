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
  -framework MediaPlayer
  -framework PhotosUI
  -framework CoreFoundation
  -Wl,-undefined,dynamic_lookup
  -Wl,-headerpad_max_install_names
)

echo "== 编译 =="
xcrun --sdk iphoneos clang "${cflags[@]}" -o "$APP/TapDog" Sources/*.m "${libs[@]}"

cp Sources/Info.plist "$APP/Info.plist"

# 内置识图模板（点赞 / 评论 / 收藏）一起打进 bundle，
# 由 TDInstallBuiltinTemplates() 在首次启动时拷到 Documents，
# 这样模板库开箱就有三个能直接选的。
if [ -d Resources/tpl ]; then
  mkdir -p "$APP/tpl"
  cp Resources/tpl/*.png "$APP/tpl/"
  echo "内置模板: $(ls "$APP/tpl" | tr '\n' ' ')"
fi

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

echo "-- 用 ldid 签名（假签名，TrollStore 走 CoreTrust 时内核会采纳私有 entitlement）--"
# 注意：ldid 的 -S 只认「紧贴着写」的路径（-S/path/ent.plist）；
# 写成 -S ent.plist 会把 plist 当成待签名二进制去解析，触发 ldid.cpp:852 _assert(false)。
if ! "$LDID" -S"$PWD/build/ent.plist" "$APP/TapDog" 2>build/ldid.err; then
  echo "!! ldid 失败：$(cat build/ldid.err)"
  echo "!! 回退 codesign（注意：ad-hoc 签名下私有 entitlement 可能被内核丢弃）"
  codesign --force --sign - --entitlements build/ent.plist "$APP/TapDog"
fi

echo "== 校验签名里的权限 =="
if "$LDID" -e "$APP/TapDog" > build/ent.out 2>/dev/null; then
  grep -E "hid.client.event-dispatch|platform-application|accessibility-window-hosting" build/ent.out || true
else
  codesign -d --entitlements :- "$APP/TapDog" 2>/dev/null | grep -E "hid.client.event-dispatch|platform-application" || true
fi

# 硬性校验：拿不到 hid.client.event-dispatch 就没必要发包了
if ! grep -q "com.apple.private.hid.client.event-dispatch" build/ent.out 2>/dev/null; then
  echo "!! 错误：签名里没有 HID 注入权限，构建中止"
  exit 1
fi
echo "权限校验通过（HID 注入已嵌入）"

echo "== 打包 ipa =="
( cd build && zip -qry TapDog.ipa Payload )
ls -lh build/TapDog.ipa
echo "完成：build/TapDog.ipa"

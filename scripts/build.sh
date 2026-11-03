#!/bin/bash
# 编译 DeepSeek / DSH 桌宠。
#
# 三个本机坑（沿用上一个挂件项目验证过的结论，都是实测过的）：
#   1. 本机只有 Command Line Tools，没有 Xcode → **不能用 swift build**
#      （CLT 的 BuildServerProtocol.framework 缺符号，swift-package 一跑就崩）。
#      只能用 swiftc 直接编，.app 手工组装。
#   2. swiftc 默认把模块缓存写 /var/folders/...，会被文件沙箱拒绝，
#      表现为 "unable to open output file ... SwiftShims-*.pcm"。
#      必须显式指定 CLANG_MODULE_CACHE_PATH / SWIFT_MODULECACHE_PATH（指到工作区里）。
#   3. SDK 要和本机 macOS 对齐：本机 macOS 26.6 → MacOSX26.5.sdk。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="$(cd "$ROOT/.." && pwd)"
SDK="${DSH_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
export CLANG_MODULE_CACHE_PATH="$WS/.build-cache"
export SWIFT_MODULECACHE_PATH="$WS/.build-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

APP_NAME="DSHAvatar"
BUNDLE_NAME="DeepSeek 桌宠"
BUILD="$ROOT/build"
BUNDLE="$BUILD/${BUNDLE_NAME}.app"
mkdir -p "$BUILD"

SOURCES=$(find "$ROOT/Sources/DSHAvatar" -name '*.swift' | sort)
CORE_SOURCES=$(find "$ROOT/Sources/DSHAvatar" -name '*.swift' ! -name 'App.swift' ! -name 'main.swift' | sort)

echo "==> 编译 ${APP_NAME}（$(echo "$SOURCES" | wc -l | tr -d ' ') 个源文件）"
xcrun swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macos14.0 \
  -swift-version 5 \
  -O \
  -framework AppKit -framework SceneKit \
  -o "$BUILD/$APP_NAME" \
  $SOURCES

echo "==> 组装 .app bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD/$APP_NAME" "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp "$ROOT/scripts/Info.plist" "$BUNDLE/Contents/Info.plist"
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$BUNDLE/Contents/Resources/README.md"

echo "==> ad-hoc 签名（把 designated requirement 钉在 bundle id 上）"
# 为什么必须钉：ad-hoc 默认 requirement 是「整份二进制的哈希」，
# 于是每重编一次系统就当成另一个 App，用户之前给的权限（完全磁盘访问等）直接失效。
codesign --force --deep --sign - \
  --identifier com.example.dshavatar \
  --requirements '=designated => identifier "com.example.dshavatar"' \
  "$BUNDLE" 2>&1 | sed 's/^/    /'
echo "    designated requirement: $(codesign -d -r- "$BUNDLE" 2>&1 | tail -1)"

if [ "${SKIP_TEST_BUILD:-0}" != "1" ]; then
  echo "==> 编译测试（纯逻辑，不带 AppKit 窗口）"
  TEST_SOURCES=$(find "$ROOT/Sources/dsh-avatar-tests" -name '*.swift' | sort)
  if [ -n "$TEST_SOURCES" ]; then
  xcrun swiftc \
    -sdk "$SDK" \
    -target arm64-apple-macos14.0 \
    -swift-version 5 \
    -framework AppKit \
    -o "$BUILD/dsh-avatar-tests" \
    $CORE_SOURCES $TEST_SOURCES
    echo "    测试可执行文件：$BUILD/dsh-avatar-tests"
  fi
fi

echo "==> 完成：$BUNDLE"
echo "    运行：open \"$BUNDLE\"        （或直接跑二进制做自检：$BUILD/$APP_NAME --diag）"

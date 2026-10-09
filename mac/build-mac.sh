#!/bin/bash
# macOS 版构建脚本：纯 swiftc，不依赖 Xcode。
# 产物：mac/build/ZCodeRemote.app（ad-hoc 签名，本机可直接 open 运行）。
# 依赖：Command Line Tools（swiftc / codesign），macOS 14+ SDK。
set -euo pipefail

# 任何一步失败都给出可读的提示（编译器原始输出在上方），不让 set -e 静默退出。
trap 'echo "✗ mac 构建失败（退出码 $?），详见上方输出。排查：swiftc 报错看文件行号；codesign 失败确认本机可写 mac/build。" >&2' ERR

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$MAC_DIR/Sources"
APP_DIR="$MAC_DIR/build/ZCodeRemote.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

# 收集全部源码（模块按目录划分，但编译为单一目标，模块边界靠 CONTRACT.md 约定）。
sources=()
while IFS= read -r -d '' f; do
    sources+=("$f")
done < <(find "$SRC_DIR" -type f -name '*.swift' -print0 | sort -z)

if [ "${#sources[@]}" -eq 0 ]; then
    echo "✗ 未找到任何 .swift：$SRC_DIR 为空，构建中止。" >&2
    exit 1
fi

echo "→ 编译 ${#sources[@]} 个源文件 → $MACOS_DIR/ZCodeRemote"
mkdir -p "$MACOS_DIR"
# -swift-version 5：沿用 iOS 版代码风格（避免 Swift 6 并发检查误伤移植代码）。
swiftc -swift-version 5 -o "$MACOS_DIR/ZCodeRemote" "${sources[@]}"

echo "→ 复制 Info.plist"
cp "$MAC_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

echo "→ 安装图标"
mkdir -p "$CONTENTS_DIR/Resources"
cp "$MAC_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"

echo "→ ad-hoc 签名"
codesign --force --sign - "$APP_DIR"

echo "✓ 构建完成：$APP_DIR"

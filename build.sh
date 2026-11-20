#!/usr/bin/env bash
# 构建 DeskMonitor.app
#   用法: ./build.sh [debug|release]
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="DeskMonitor"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "▸ 编译 ($CONFIG)…"
swift build -c "$CONFIG" --product "$APP_NAME"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

# 为什么要先组装到 /tmp 再签：
# 本仓库所在目录被 File Provider 接管（com.apple.fileprovider.fpfs#P），
# 它会反复给 .app 打上 com.apple.FinderInfo，
# codesign 因此报 "resource fork, Finder information ... not allowed"。
# xattr -cr 刚清完又会被写回，原地签名必然失败。
# 在 /tmp 里签好再拷回来，签名依然有效。
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/$APP_NAME.app"
cleanup() { rm -rf "$STAGE_ROOT"; }
trap cleanup EXIT

echo "▸ 组装 …"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN_PATH/$APP_NAME" "$STAGE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"

# 打包使用说明（PDF），让用户能从右键菜单直接打开
if [ -f "docs/使用说明.pdf" ]; then
    cp "docs/使用说明.pdf" "$STAGE/Contents/Resources/DeskMonitor-Manual.pdf"
    [ -f "docs/使用说明-进阶.pdf" ] && cp "docs/使用说明-进阶.pdf" "$STAGE/Contents/Resources/DeskMonitor-Manual-Advanced.pdf"
    echo "▸ 已打包使用说明（基础 + 进阶）"
fi

xattr -cr "$STAGE" 2>/dev/null || true

echo "▸ 签名 (ad-hoc)…"
codesign --force --sign - "$STAGE"
codesign --verify --deep --strict "$STAGE"

echo "▸ 拷回工作区 …"
rm -rf "$APP"
mkdir -p "$BUILD_DIR"
ditto "$STAGE" "$APP"
codesign --verify --deep --strict "$APP"

echo "✅ 完成: $(pwd)/$APP"

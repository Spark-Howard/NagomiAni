#!/bin/bash
# ============================================================
# NagomiAni 打包脚本（测试版 dmg）
# 用法: ./pack.sh [版本号] [构建号]
#   默认: 版本号 0.1.0  构建号 1
# 输出: dist/NagomiAni-<版本>-beta<构建号>.dmg
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
DMG_NAME="NagomiAni-${VERSION}-beta${BUILD}.dmg"

APP_NAME="NagomiAni"
BUNDLE_ID="com.nagomiani.player"
BUILD_DIR=".build/release"
STAGE=".build/package"
DIST="dist"

echo "▸ 1/5 编译 release（${VERSION} build ${BUILD}）"
swift build -c release

echo "▸ 2/5 组装 ${APP_NAME}.app"
rm -rf "$STAGE" "$DIST"
mkdir -p "$STAGE/${APP_NAME}.app/Contents/MacOS"
mkdir -p "$STAGE/${APP_NAME}.app/Contents/Resources"
mkdir -p "$STAGE/${APP_NAME}.app/Contents/Frameworks"

# Info.plist
cat > "$STAGE/${APP_NAME}.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST

# 二进制 + 图标
cp "$BUILD_DIR/${APP_NAME}" "$STAGE/${APP_NAME}.app/Contents/MacOS/"
cp Assets/AppIcon.icns "$STAGE/${APP_NAME}.app/Contents/Resources/"

# libmpv 依赖闭包（72 个 dylib，IINA 构建，@rpath 互链）
cp Vendor/libmpv/*.dylib "$STAGE/${APP_NAME}.app/Contents/Frameworks/"

# rpath：让二进制与 dylib 都在 app 内找到依赖
# （保留编译时的 rpath 无妨，但加上 app 内 Frameworks 的路径确保独立运行）
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$STAGE/${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "▸ 3/5 签名（测试版 ad-hoc 签名）"
codesign --force --deep --sign - \
    "$STAGE/${APP_NAME}.app"

echo "▸ 4/5 制作 dmg（拖拽安装引导：App 图标 + 应用程序快捷方式）"
mkdir -p "$DIST"
rm -f "$DIST/$DMG_NAME"

# 在 dmg 中放入 /Applications 符号链接作为拖拽安装目标
# （hdiutil 会保留 symlink，Finder 中显示为可拖入的「应用程序」文件夹）
ln -sf /Applications "$STAGE/Applications"

# 源目录含 NagomiAni.app + Applications 链接，一起打包
hdiutil create -volname "NagomiAni" -srcfolder "$STAGE" \
    -ov -format UDZO "$DIST/$DMG_NAME"

echo "▸ 5/5 完成"
echo "──────────────────────────────────────"
echo "  ✔ $DIST/$DMG_NAME"
echo "  ✔ 版本 ${VERSION}（build ${BUILD}）· ad-hoc 签名（仅本机测试，对外分发需 Developer ID + 公证）"
echo "──────────────────────────────────────"

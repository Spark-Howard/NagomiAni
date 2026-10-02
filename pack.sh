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
DMG_NAME="NagomiAni-${VERSION}.dmg"

APP_NAME="NagomiAni"
BUNDLE_ID="com.nagomiani.player"
BUILD_DIR=".build/release"
STAGE=".build/package"
DIST="dist"

echo "▸ 1/5 编译 release（${VERSION} build ${BUILD}）"
# --disable-sandbox：沙箱受限环境（CI/本开发沙箱）需要；普通终端下无副作用
swift build -c release --disable-sandbox

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
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <!-- ATS：打包版 .app 受 ATS 约束，而 swift run 的裸二进制无 bundle 不受 ATS 约束——
         这正是“swift run 封面正常、打包版封面全不显示”的根本差异。
         Bangumi 封面 CDN（lain.bgm.tv）在 API JSON 里返回的是明文 http 地址。
         ⚠ 陷阱：NSAllowsArbitraryLoads 一旦与 NSAllowsArbitraryLoadsInWebContent /
         NSAllowsLocalNetworking 同时出现，前者会被系统【静默忽略】（macOS 10.12+ 文档行为）。
         之前“三个全开”导致任意加载被禁用，http 封面在打包版里仍然全被 ATS 拦掉。
         正确做法：不放全局任意加载，只对 bgm.tv 系图片主机开 http 例外；
         WebContent 例外仅放行内嵌聊天网页（https://bgm.tv 页面内的 http 子资源）。 -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoadsInWebContent</key><true/>
        <key>NSAllowsLocalNetworking</key><true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>lain.bgm.tv</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
                <key>NSIncludesSubdomains</key><true/>
            </dict>
            <key>bgm.tv</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
                <key>NSIncludesSubdomains</key><true/>
            </dict>
        </dict>
    </dict>
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

# 内置弹幕凭据（弹弹play）：从本地 gitignored 的 DanmakuCredentials.private
# （两行：AppId / AppSecret）读取，XOR 0x5A 混淆后写入 bundle Resources。
# ⚠️ 真实值永不进仓库（项目开源）；混淆防普通查看，非加密——泄露则重置密钥重打包。
# 本地没有该文件时跳过：应用回退 UserDefaults，无凭据则弹幕显示"未就绪"。
if [ -f "DanmakuCredentials.private" ]; then
python3 - "$STAGE/${APP_NAME}.app/Contents/Resources" <<'PYEOF'
import sys, os
out_dir = sys.argv[1]
with open("DanmakuCredentials.private", encoding="utf-8") as f:
    lines = [line.strip() for line in f if line.strip()]
assert len(lines) >= 2, "DanmakuCredentials.private 需要 AppId / AppSecret 两行"
payload = (lines[0] + "\n" + lines[1]).encode("utf-8")
with open(os.path.join(out_dir, "danmaku-credentials.bin"), "wb") as f:
    f.write(bytes(b ^ 0x5A for b in payload))
PYEOF
echo "  弹幕凭据已内置（混淆写入 bundle）"
fi

echo "▸ 3/5 签名（测试版 ad-hoc 签名）"
codesign --force --deep --sign - \
    "$STAGE/${APP_NAME}.app"

echo "▸ 4/5 制作 dmg（引导式安装界面，手写 AppleScript 显式设置）"
mkdir -p "$DIST"
rm -f "$DIST/$DMG_NAME"

RW="$DIST/NagomiAni.rw.dmg"
rm -f "$RW"

# 1) 准备源目录：app + Applications 快捷方式 + 引导背景图（.background 隐藏目录）
ln -sf /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp Assets/dmg_bg.png "$STAGE/.background/"
cp Assets/AppIcon.icns "$STAGE/.VolumeIcon.icns"
hdiutil create -volname "NagomiAni" -srcfolder "$STAGE" \
    -ov -format UDRW "$RW" >/dev/null 2>&1

# 2) 挂载
MOUNT="/Volumes/NagomiAni"
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
hdiutil attach "$RW" -nobrowse -mountpoint "$MOUNT" >/dev/null 2>&1
# 用挂载点目录存在性判断成败（$MOUNT 是常量，[ -z ] 永远为假）
if [ ! -d "$MOUNT" ]; then
    echo "  ⚠ 挂载失败"
    exit 1
fi
echo "  挂载于: $MOUNT"

# 3) 引导界面：优先 Finder AppleScript（图形会话里 Finder 亲自写 .DS_Store，
#    箭头/背景必然显示——历史验证的唯一可靠路径）；无 GUI（SSH/CI/沙箱）时
#    AppleScript 直接报错，自动回退 make_dsstore.py（布局数据仍在，箭头可能不显示，
#    见 CONTEXT §5.5 教训）。NO_GUI=1 可强制回退。
LAYOUT_VIA="python"
if [ -z "${NO_GUI:-}" ] && osascript -e 'tell application "Finder" to get name' >/dev/null 2>&1; then
    echo "  检测到图形会话：用 Finder 设置引导界面（箭头可靠显示）"
    open "$MOUNT"
    sleep 1
    if osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "NagomiAni"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 740, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:dmg_bg.png"
        set position of item "NagomiAni.app" of container window to {200, 180}
        set position of item "Applications" of container window to {480, 180}
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT
    then
        LAYOUT_VIA="finder"
        sleep 1
    else
        echo "  ⚠ AppleScript 失败，回退 Python 方案"
    fi
else
    echo "  无图形会话（或 NO_GUI=1）：回退 make_dsstore.py（箭头可能不显示）"
fi
if [ "$LAYOUT_VIA" = "python" ]; then
    python3 make_dsstore.py "$MOUNT" || echo "  ⚠ .DS_Store 生成失败"
fi

hdiutil detach "$MOUNT" >/dev/null 2>&1
hdiutil convert "$RW" -format UDZO -o "$DIST/$DMG_NAME" >/dev/null 2>&1
rm -f "$RW"

echo "▸ 5/5 完成"
echo "──────────────────────────────────────"
echo "  ✔ $DIST/$DMG_NAME"
echo "  ✔ 版本 ${VERSION}（build ${BUILD}）· ad-hoc 签名（仅本机测试，对外分发需 Developer ID + 公证）"
if [ "$LAYOUT_VIA" = "finder" ]; then
    echo "  ✔ 引导界面：Finder 写入（双击 dmg 即见 箭头+背景 拖拽安装）"
else
    echo "  ⚠ 引导界面：Python 回退路径（箭头可能不显示；请在图形界面终端重跑，或 ./interactive_dmg.sh ${VERSION} 修复）"
fi
echo "──────────────────────────────────────"

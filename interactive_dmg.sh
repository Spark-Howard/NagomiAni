#!/bin/bash
# ============================================================
# 交互式 dmg 引导界面（必须在【图形界面】的终端运行）
# 用法: ./interactive_dmg.sh [版本] [构建号]
# 依赖: 先运行 ./pack.sh 生成 .build/package（app + Applications + .background）
# ============================================================
set -e
cd "$(dirname "$0")"

VERSION="${1:-0.1.0}"
BUILD="${2:-14}"
OUT="dist/NagomiAni-${VERSION}.dmg"

if [ ! -d ".build/package/NagomiAni.app" ]; then
    echo "✘ 缺少 .build/package，请先运行: ./pack.sh ${VERSION} ${BUILD}"
    exit 1
fi

echo "▸ 1/4 创建可写 dmg"
rm -f .build/interactive.rw.dmg "$OUT"
hdiutil create -volname "NagomiAni" -srcfolder .build/package -ov -format UDRW .build/interactive.rw.dmg >/dev/null 2>&1

echo "▸ 2/4 挂载并打开窗口（屏幕上应弹出 Finder 窗口）"
MOUNT=$(hdiutil attach .build/interactive.rw.dmg | grep /Volumes | awk '{print $NF}')
open "$MOUNT"
sleep 2

echo "▸ 3/4 运行 AppleScript 设置引导界面（若有报错会直接显示）"
osascript <<'APPLESCRIPT'
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
echo "  ✔ AppleScript 执行完成（无报错）"

echo "▸ 检查 .DS_Store 是否已写入布局数据"
python3 -c "
from ds_store import DSStore
try:
    ds = DSStore.open('$MOUNT/.DS_Store')
    codes = [e.code for e in ds]
    print('  ICVO（背景图）:   ', '✔ 已写入' if b'ICVO' in codes else '✘ 未写入')
    print('  Iloc（图标位置）: ', '✔ 已写入' if any(c == b'Iloc' for c in codes) else '✘ 未写入')
    print('  bwsp（窗口）:     ', '✔ 已写入' if b'bwsp' in codes else '✘ 未写入')
except Exception as ex:
    print('  读取失败:', ex)
"

echo "▸ 4/4 卸载并压缩"
hdiutil detach "$MOUNT" >/dev/null 2>&1
hdiutil convert .build/interactive.rw.dmg -format UDZO -o "$OUT" >/dev/null 2>&1
rm -f .build/interactive.rw.dmg
echo "──────────────────────────────────────"
echo "  ✔ $OUT"
echo "  现在双击打开它，看引导界面（箭头/背景）是否出现"
echo "──────────────────────────────────────"

#!/usr/bin/env python3
"""为 dmg 卷生成带引导界面的 .DS_Store（背景图 + 图标位置 + 窗口），不依赖 Finder。

用法: python3 make_dsstore.py <挂载卷路径>
"""
import os
import plistlib
import struct
import sys

from ds_store import DSStore, DSStoreEntry
from mac_alias import Bookmark


def main(mount_path: str) -> None:
    bg_path = os.path.join(mount_path, ".background", "dmg_bg.png")
    if not os.path.exists(bg_path):
        print(f"✘ 背景图不存在: {bg_path}")
        sys.exit(1)

    # 背景图 bookmark（Finder backgroundImageAlias 需要）
    bookmark = Bookmark.for_file(bg_path)
    bookmark_bytes = bookmark.to_bytes()

    # 图标视图选项（icvp，binary plist）
    icvp = {
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
        "arrangeBy": "none",
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": True,
        "iconSize": 96.0,
        "gridSpacing": 54.0,
        "iconViewSettingsVersion": 1,
        "backgroundType": 2,            # 2 = 图片背景
        "backgroundColorRed": 0.0,
        "backgroundColorGreen": 0.0,
        "backgroundColorBlue": 0.0,
        "backgroundImageAlias": bookmark_bytes,
    }

    # 窗口（bwsp）
    bwsp = {
        "WindowBounds": "{{100, 100}, {640, 400}}",
        "ShowToolbar": False,
        "ShowStatusBar": False,
        "ShowSidebar": False,
    }

    ds_path = os.path.join(mount_path, ".DS_Store")
    if os.path.exists(ds_path):
        os.remove(ds_path)

    # 用 initial_entries 一次性初始化新 .DS_Store（避免 open 后 insert 到空树的兼容问题）
    ds = DSStore.open(ds_path, "w+", initial_entries=[
        DSStoreEntry(".", "bwsp", "blob", plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY)),
        DSStoreEntry("", "ICVO", "blob", plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)),
        DSStoreEntry("NagomiAni.app", "Iloc", "blob",
                     struct.pack(">IIII", 200, 180, 0xFFFFFFFF, 0xFFFF0000)),
        DSStoreEntry("Applications", "Iloc", "blob",
                     struct.pack(">IIII", 480, 180, 0xFFFFFFFF, 0xFFFF0000)),
    ])
    ds.close()
    print("✔ .DS_Store 已写入（背景图 + 图标位置 + 窗口）")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: make_dsstore.py <挂载卷路径>")
        sys.exit(1)
    main(sys.argv[1])

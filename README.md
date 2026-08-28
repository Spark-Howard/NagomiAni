# NagomiAni（なごみあに）

macOS 原生看番播放器：本地播放 + Bangumi 收藏同步。

## 功能

- 🎬 播放内核基于 **libmpv**（IINA 同款方案），支持 MKV / ASS 字幕 / 多音轨 / 硬解（videotoolbox）
- 📺 打开文件、拖拽播放、进度条跳转、空格/点击暂停
- 🐌 **Bangumi 同步**：OAuth2 登录、收藏列表、「标记看过」自动更新进度
- 📜 GPL-3.0 开源

## 构建与运行

需要 macOS 13+ 与 Swift 工具链（Xcode 或 Command Line Tools）。

```bash
swift build
swift run NagomiAni
```

无界面冒烟测试（验证播放内核不崩溃）：

```bash
swift run NagomiAniSmoke /path/to/video.mp4
```

## Bangumi 同步

1. 在 [bgm.tv/dev/app](https://bgm.tv/dev/app) 注册应用，回调地址填 `http://127.0.0.1:8123/callback`
2. 启动 App → 工具栏 Bangumi 图标 → 填入 App ID / App Secret → 登录
3. 授权后自动跳回，显示你的「在看」收藏，可逐条「标记下一集」

Token 存储在系统钥匙串（Keychain），过期自动刷新。

## 第三方组件

- [libmpv](https://github.com/mpv-player/mpv) v0.38.0（GPL-2.0+）及其依赖闭包，来自 IINA 的构建，位于 `Vendor/libmpv/`

## 许可

[GPL-3.0](LICENSE)

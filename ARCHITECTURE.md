# NagomiAni 架构蓝图

> 模式：**GPL（IINA 路线）**——libmpv 内核 · 全开源 · 官网分发 + 公证，不上 Mac App Store

---

## 0. 技术决策总览

| 决策点 | 选择 | 理由 |
|---|---|---|
| 语言 / UI | Swift + SwiftUI（AppKit 桥接 Metal 视图） | 原生、开发快 |
| 播放内核 | 阶段一 **AVPlayer** → 阶段二 **libmpv**（动态链接 dylib） | 先跑通链路，再补齐 MKV/ASS |
| 字幕 | 阶段一：内嵌轨；阶段二：mpv ASS 全支持 | 字幕组资源的硬需求 |
| Bangumi 同步 | OAuth2 + v0 API（收藏 `ep_status`） | 官方标准流程 |
| 许可 | **GPL-3.0**，源码全开源 | 使用 libmpv 的必然选择（IINA 同款） |
| 分发 | 官网下载（GitHub Release）+ Developer ID 公证 | GPL 应用不上 MAS |
| 构建 | Xcode + SwiftPM（`NagomiAniCore` 独立包，可单测） | 核心逻辑与 UI 解耦 |

---

## 1. 目录结构

```
NagomiAni/
├── LICENSE                      # GPL-3.0（官方全文）
├── README.md
├── Package.swift                # SwiftPM（当前为纯 SwiftPM 结构，后续可生成 Xcode 工程）
├── NagomiAni/                   # App target（SwiftUI）
│   ├── App/                     # NagomiAniApp, AppDelegate, 窗口管理
│   ├── UI/
│   │   ├── Player/              # PlayerView, 控件, NowPlaying
│   │   ├── Library/             # 媒体库, 集数列表
│   │   └── Settings/            # 设置, Bangumi 账号
│   └── Resources/               # Assets, Info.plist
├── NagomiAniCore/               # Swift Package：核心逻辑（可独立测试）
│   ├── Playback/
│   │   ├── PlaybackEngine.swift     # ★ 协议（UI/同步只依赖它）
│   │   ├── PlaybackState.swift
│   │   ├── AVPlaybackEngine.swift   # 阶段一实现
│   │   └── MPVPlaybackEngine.swift  # 阶段二实现
│   ├── Sync/
│   │   ├── BangumiClient.swift      # URLSession 网络层
│   │   ├── BangumiAuth.swift        # OAuth2（token 存钥匙串）
│   │   ├── Models/                  # Subject, Collection, Episode, User
│   │   └── HistorySyncService.swift # ★ 进度上报/节流/幂等
│   ├── Library/
│   │   ├── MediaLibrary.swift       # 本地文件扫描
│   │   └── MediaItem.swift
│   └── Support/                     # 扩展、日志
├── Vendor/
│   ├── libmpv/                      # libmpv.dylib + 头文件（GPL 构建）
│   └── Scripts/build-libmpv.sh      # 构建/嵌入脚本（参考 IINA）
└── Tests/
    ├── NagomiAniCoreTests/
    └── SyncTests/                   # Bangumi API mock 测试
```

---

## 2. PlaybackEngine 抽象（核心设计）

UI 和同步模块**只依赖协议**，不关心底层是 AVPlayer 还是 libmpv：

```swift
import Foundation

/// 播放内核抽象
protocol PlaybackEngine: AnyObject {
    var delegate: PlaybackEngineDelegate? { get set }

    // 生命周期
    func load(url: URL, options: PlaybackOptions) async throws
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double, completion: ((Bool) -> Void)?)

    // 状态（进度同步用）
    var duration: Double { get }
    var currentTime: Double { get }
    var isPlaying: Bool { get }
    var rate: Float { get set }

    // 轨道 / 字幕（mpv 强项）
    var videoTracks: [MediaTrack] { get }
    var audioTracks: [MediaTrack] { get }
    var subtitleTracks: [MediaTrack] { get }
    func selectAudioTrack(_ index: Int)
    func selectSubtitleTrack(_ index: Int)

    static var capabilities: PlaybackCapabilities { get } // 能力声明，供 UI 降级
}

protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double)
    func playbackEngine(_ engine: PlaybackEngine, didChangeState state: PlaybackState)
    func playbackEngineDidFinish(_ engine: PlaybackEngine)
    func playbackEngine(_ engine: PlaybackEngine, didFailWith error: Error)
}
```

> 切换内核（M1 → M3）时，UI 与同步代码零改动。

---

## 3. libmpv 集成要点（阶段二）

- **动态链接** `libmpv.dylib`（`@rpath` 指向 App 内 Frameworks），避免 GPL 静态链接争议
- **渲染**：libmpv render API（`mpv_render_context`）→ Metal 纹理 → `CAMetalLayer` 的 NSView，用 `NSViewRepresentable` 桥进 SwiftUI；CVDisplayLink 驱动刷新
- **硬解**：`hwdec=videotoolbox`（Apple Silicon 成熟）；**音频**：`audio=coreaudio`；**字幕**：`sub-ass` 默认开启
- **参考**：IINA 的 [mpv 集成架构](https://deepwiki.com/iina/iina/2.1-mpv-integration)，照其思路简化实现

---

## 4. Bangumi 同步设计

### OAuth2 授权码流程
1. 在 bgm.tv/dev 注册应用，拿 `client_id` / `client_secret`（secret 只存钥匙串）
2. 浏览器打开 `authorize` 端点 → 用户授权 → 回调拿 `code`
3. POST `access_token` 端点换 token → 之后所有请求带 Bearer token

### 数据模型
`User` / `Subject`（subject_type=2 即动画）/ `Collection`（含 `ep_status`：看到第几集）/ `Episode`

### 已实现的 v0 端点（M2）

| 端点 | 用途 | 说明 |
|---|---|---|
| `POST bgm.tv/oauth/access_token` | 换/刷 token | 授权码 + refresh_token |
| `GET /v0/me` | 当前用户 | Bearer |
| `GET /v0/users/{u}/collections` | 收藏列表 | subject_type=2 动画 |
| `POST /v0/users/-/collections/{id}` | 增改收藏 | 动画不可改 ep_status |
| `GET /v0/episodes` | 章节列表 | subject_id 查询 |
| `PATCH /v0/users/-/collections/{id}/episodes` | **批量标记单集** | 动画进度的正确姿势，自动重算完成度 |

> 注意：官方限制动画条目不能直接改 `ep_status`，进度同步必须走"标记单集"接口（M2 已按此实现）。

### 同步策略（重点：节流 + 幂等）
- **触发时机**：暂停、切集、退出播放时上报，不实时轮询
- **阈值判断**：进度差 ≥ 30 秒或跨集才上报，避免抖动刷接口
- **串行队列 + 最小间隔**：请求排入串行队列，相邻请求间隔 ≥ 数秒——bgm.tv 对请求频率敏感（参考 [bangumi/api#206](https://github.com/bangumi/api/issues/206)、[jellyfin-plugin-bangumi#180](https://github.com/kookxiang/jellyfin-plugin-bangumi/issues/180) 的节流实践）
- **幂等**：以 `ep_status` 为准，上报失败可安全重试
- **离线兜底**：本地缓存进度（UserDefaults/SQLite），网络恢复后补报

---

## 5. GPL 合规清单

- [x] 仓库根目录放 `LICENSE`（GPL-3.0）
- [x] 声明第三方组件：libmpv（GPL-2.0+）及依赖闭包
- [x] 全部源码开源（含 UI 层）
- [x] 不上 Mac App Store；Developer ID 签名 + `notarytool` 公证后放 GitHub Release
- [ ] 不使用闭源依赖

### 第三方组件说明（M3 新增）

- `Vendor/libmpv/`：libmpv v0.38.0（arm64/x86_64 universal）及全部动态依赖闭包，来自 IINA 的 GPL 构建（mpv GPL-2.0+）
- `Sources/Cmpv/`：mpv v0.38.0 官方头文件的 C 桥接模块（modulemap）+ `shim.c`（dlsym 解析 GL 函数指针，替代新 SDK 已移除的 CGLGetProcAddress）
- 渲染采用 libmpv 的 OpenGL render API（NSOpenGLView，macOS 已废弃但可用；后续可迁移 Metal）

---

## 6. 里程碑

| 阶段 | 内容 | 验收 | 状态 |
|---|---|---|---|
| M0 | SwiftPM 包结构 + LICENSE（GPL-3.0） | `swift build` 通过 | ✅ 完成 |
| M1 | AVPlaybackEngine + 最小播放 UI（打开/拖拽文件→播放→进度条） | 能播 mp4 | ✅ 基础版完成 |
| M2 | Bangumi OAuth 登录 + 收藏列表 + 手动标记看过 | 收藏可读写 | ✅ 基础版完成（登录/收藏/标记单集） |
| M3 | 接入 libmpv，PlaybackEngine 切换 | MKV/ASS 正常播放 | ✅ 基础版完成（OpenGL 渲染） |
| M4 | 自动进度同步 + 打磨 + 公证发布 | 首个 Release | ⏳ 待做 |

---

## 参考项目

- [IINA](https://github.com/iina/iina)：libmpv + macOS 的完整范例（GPL-3.0）
- [BangumiToday](https://deepwiki.com/BTMuli/BangumiToday/4.1-bangumi-api-client)：Bangumi API 客户端与 [OAuth 流程](https://deepwiki.com/BTMuli/BangumiToday/4.3-oauth-authentication-flow) 参考

# NagomiAni 项目上下文（CONTEXT）

> 用途：供后续开发会话快速恢复上下文。最后更新：2025-08（番库 + 匹配 + 同步功能完成）

## 1. 项目概况

- **macOS 原生看番播放器**：本地播放（libmpv 内核，IINA 同款路线）+ Bangumi 收藏/进度同步
- **GPL-3.0 全开源**，官网分发（Developer ID + 公证），不上 Mac App Store
- 纯 SwiftPM 结构（无 Xcode 工程），macOS 13+，Swift 6 工具链

## 2. 技术栈与架构

| 模块 | 说明 |
|---|---|
| `PlaybackEngine` 协议 | 播放内核抽象；`MPVPlaybackEngine` 为当前实现（libmpv v0.38） |
| `Vendor/libmpv/` + `Sources/Cmpv/` | libmpv 动态依赖闭包（来自 IINA 构建）+ C 桥接（OpenGL 渲染） |
| `BangumiClient` | v0 API 客户端（Bearer + UA），超时/重试/节流 |
| `BangumiAuth` | OAuth2 授权码 + 本地回环回调（127.0.0.1:8123）+ **文件令牌存储** |
| `HistorySyncService` | 同步节流队列（尊重 bgm.tv 频率限制） |
| `MediaLibrary` | 番库：目录管理、递归扫描、JSON 持久化（library.json） |
| `MediaMatching` | 文件名解析：集数 / 季度 / 标签清洗 / 标题推导 |
| `BangumiMatcher` | 匹配评分：相似度 + 集数佐证 + **季度判定**；跨语言翻译扩展 |
| `TitleTranslator` | 免费翻译（谷歌非官方接口），中文名↔英文名搜索扩展 |

## 3. 功能状态

- **M0-M3 完成**：工程骨架 / AVPlayer→libmpv / Bangumi 登录+收藏 / MKV+ASS 播放
- **M4 部分**：✅ 播完自动标记看过（文件→条目关联）已做；⏳ 播放中进度自动上报未做
- **番库 L1-L2 完成**：导入/文件夹聚合/自动匹配候选/手动确认/封面展示；库内点播已通
- **未做**：断点续播、目录监控（FSEvents）、剧场版/OVA 区分、批量确认、上架打包（.app）

## 4. 关键设计决策（改动前必读）

1. **分组以文件夹为单位**（一个文件夹 = 一部番）；**匹配标题来自视频文件名的众数**，目录名仅兜底（用户一般不改文件名）
2. **自动匹配只生成候选，绝不自动绑定**；弹窗先展示自动结果（含相似度%），用户点选确认或手动搜索；**确认后隐藏"建议 N"**，点「更换」才重新匹配
3. **动画进度同步必须走 `PATCH /v0/users/-/collections/{id}/episodes`**（批量标记单集，自动重算完成度）——官方禁止直接改动画条目的 `ep_status`
4. **令牌存文件**（`Application Support/NagomiAni/auth.json`，0600）——`swift run` 无稳定签名，用钥匙串会反复弹窗
5. 搜索接口是**实验性 API**：超时放宽（30s）、网络错误自动重试（2 次退避）、请求节流（1s/条）、搜索"够好即停"
6. **模型全部防御式解码**：字段类型异常降级 nil，绝不因单个字段毁掉整个响应
7. **移动/改名项目文件夹后必须 `rm -rf .build`**（预编译缓存记录旧绝对路径）
8. 季度识别规则：`S1/S02/Season 2/第X季/中文数字/Part 2/末尾罗马数字/末尾0续作`；年份末尾 0 不误判

## 5. 常用命令

```bash
swift build                        # 构建
swift run NagomiAni                # 启动 App
swift run NagomiAniSmoke 视频.mp4  # 无界面播放冒烟测试
swift test                         # 单元测试（35 个用例）
```

> 注意：本环境构建时需 `mkdir -p .build/tmp && TMPDIR="$(pwd)/.build/tmp"` 前缀（沙箱限制，用户终端里不需要）。

## 6. 已知问题 / 待办

- bgm.tv 频率限制敏感：同步/匹配已做节流，失败会在界面提示"重新扫描重试"
- 「更换」时若令牌已过期会静默失败（BangumiSession 已做 refreshIfNeeded，基本覆盖）
- 下一步建议：断点续播（本地播放位置记录）→ 目录监控（FSEvents）→ 上架打包（.app + 公证）

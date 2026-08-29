# NagomiAni（なごみあに）

> 治愈你的每一个追番夜晚 · macOS 原生看番播放器 + Bangumi 同步

**NagomiAni** = 和み（なごみ，治愈） + Anime。一款为班友打造的 macOS 原生看番播放器：本地播放（libmpv 内核，IINA 同款方案）+ 番库管理 + Bangumi 收藏/进度双向同步。

![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)

## ✨ 功能特性

### 🎬 播放
- **libmpv 内核**：MKV / MP4 / WebM / AVI 等全格式，字幕组资源通吃
- **ASS 字幕样式完整还原**、多音轨切换、`videotoolbox` 硬解
- **字幕**：内置字幕轨选择、外挂字幕挂载（菜单或直接拖入文件）、字幕延迟 ±0.5s 调节、自动加载同名字幕
- 进度条拖动不跳变、空格 / 点击画面播放暂停
- **全屏沉浸模式**：隐藏侧边栏与标题栏，画面铺满整个屏幕（鼠标移顶呼出系统控制）
- 控制条自动隐藏：鼠标移入底部呼出进度条，移开自动收回

### 📚 番库
- 导入目录、递归扫描、**按文件夹聚合**（一个文件夹 = 一部番）
- **自动匹配候选 + 手动确认**关联 Bangumi 条目，封面墙展示
- **按 Bangumi 集数列表展示**：本地有的集正常播放，缺的集显示"未找到"占位，一眼看出差哪几集
- **动漫圈命名解析**：`S01E03` / `S2 01` / `E03` / `EP.3` / `第3話` / `#03` / `03v2` 等格式全部识别（防年份/SP 误判）
- 番级操作：单目录重新扫描（补新集/删消失文件）、从库移除

### 🐌 Bangumi 同步
- OAuth2 浏览器授权登录（App ID / Secret 仅首次配置）
- **看完自动标记看过**：自然播放到 85% 即标记（不等播完），EOF 兜底；拖动/短视频防误报
- 播完同步走官方单集标记接口，自动重算完成度

### 🔍 搜索浏览
- 搜索动画词条（服务端类型过滤 + 翻页兜底）
- **剧目详情页**：封面、评分/排名、收藏统计、标签、资料表（infobox）、简介 + 分段切换：**集数 / 角色 / 制作人员 / 讨论 / 评论**
- 讨论帖、评论点击跳转浏览器查看完整内容
- **我的收藏**：搜索结果显示状态徽章（想看/在看/看过/搁置/抛弃），详情页可修改状态或移除收藏，**确认后同步到 Bangumi**

## 🛠 环境要求

- macOS 13+
- Swift 工具链（Xcode 或 Command Line Tools）

## 🚀 构建与运行

```bash
swift build          # 编译
swift run NagomiAni  # 启动应用
```

开发辅助命令：

```bash
swift test                               # 单元测试（39 个用例）
swift run NagomiAniSmoke 视频.mp4         # 无界面播放冒烟测试
swift run NagomiAniSmoke 视频.mp4 --sub 字幕.srt --switch 视频2.mp4   # 含字幕挂载/切集回归
```

## 📖 使用指南

1. **播放器**：拖入视频或点击「选择视频文件…」（`Cmd+O`）；底部控制条：播放/暂停、进度条、音轨、字幕、全屏
2. **番库**：添加目录 → 自动扫描 → 点「关联」选择 Bangumi 条目 → 点任意一集播放，看完自动同步
3. **搜索**：搜动画名 → 进详情看信息/讨论 → 在「收藏状态」区管理收藏
4. **Bangumi**：登录后番库匹配、看完同步、收藏管理全部可用

## 🔑 Bangumi 登录（首次配置）

1. 打开 [bgm.tv/dev/app](https://bgm.tv/dev/app)（需登录 bgm.tv）→ 创建应用
2. **回调地址填**：`http://127.0.0.1:8123/callback`
3. 复制生成的 **App ID** 与 **App Secret**
4. 应用内 Bangumi 页填入 → 点登录 → 浏览器授权 → 自动跳回完成

> 令牌存储在 `Application Support/NagomiAni/auth.json`（0600 权限，仅当前用户可读写），过期自动用 refresh_token 刷新。App ID/Secret 仅存本机，不随项目分发。

## 📦 项目结构

```
Sources/
  NagomiAni/            # App 层（SwiftUI 界面、状态模型）
    PlayerView.swift    # 播放器（控制条/字幕/全屏）
    LibraryPage.swift   # 番库
    SearchPage.swift    # 搜索浏览 + 剧目详情
    BangumiPage.swift   # 账号与收藏
  NagomiAniCore/        # 核心库
    Playback/           # 播放内核（PlaybackEngine 协议 + MPV 实现）
    Library/            # 番库（扫描/匹配/持久化）
    Sync/               # Bangumi API（OAuth/客户端/同步）
  NagomiAniSmoke/       # 无界面冒烟测试工具
  Cmpv/                 # libmpv C 桥接
Vendor/libmpv/          # libmpv 动态库闭包（来自 IINA 构建）
Tests/                  # 单元测试
```

## 🧠 技术设计要点

- **播放内核抽象**：`PlaybackEngine` 协议隔离 UI 与内核，mpv 渲染走 OpenGL render API
- **分组以文件夹为单位**：一个文件夹 = 一部番；匹配标题来自视频文件名的众数（目录名仅兜底）
- **进度同步的正确姿势**：动画条目禁止直接改 `ep_status`，走 `PATCH /v0/users/-/collections/{id}/episodes` 批量标记单集
- **防御式解码**：所有 API 模型字段类型异常降级为 nil，单个字段不毁整个响应
- **节流与重试**：尊重 bgm.tv 频率限制，搜索/匹配节流，网络错误自动退避重试

## 📜 第三方组件与致谢

- [libmpv](https://github.com/mpv-player/mpv) v0.38.0（GPL-2.0+）及其依赖闭包（ffmpeg / libass / libplacebo 等），来自 [IINA](https://github.com/iina/iina) 的构建，位于 `Vendor/libmpv/`
- [Bangumi API](https://github.com/bangumi/api)（v0 + 旧版大条目接口）

## ⚖️ 许可

[GPL-3.0](LICENSE)

本项目基于 GPL 开源，全源码开放；libmpv 及 ffmpeg 等依赖同样以 GPL/LGPL 兼容许可分发。

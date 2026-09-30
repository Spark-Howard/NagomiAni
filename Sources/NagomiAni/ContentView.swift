import AppKit
import SwiftUI
import NagomiAniCore

struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @StateObject private var account = AccountViewModel()
    @StateObject private var library = LibraryViewModel()
    @StateObject private var online = OnlineStore()
    @StateObject private var search = SearchViewModel()
    @StateObject private var contacts = ContactsStore()
    /// 常驻的聊天网页控制器（切板块回来不丢页面/登录态）
    @StateObject private var webChat = WebChatController()
    @State private var selection: SidebarItem? = .player
    /// 统一登录发起来源：登录完成后自动切回该页（nil = 从聊天页发起，不切走）
    @State private var loginReturnTarget: SidebarItem?
    /// 全屏时隐藏侧边栏，让视频占满整个屏幕（无 UI 边框）
    @State private var isFullScreen = false
    /// 已经访问过的页面：只挂载访问过的，之后不再销毁重建
    @State private var visited: Set<SidebarItem> = [.player]
    /// 继续观看区块的刷新标记（切页时 +1，番库页据此重算卡片）
    @State private var continueWatchingRevision = 0

    var body: some View {
        HStack(spacing: 0) {
            if !isFullScreen {
                SidebarView(selection: $selection)
                    .frame(width: 170)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 列表页淡粉底（页面自身透明，底色统一从这里来）
                .background(NagomiTheme.pageBackground)
        }
        .environmentObject(contacts)
        // 全局品牌色：按钮/进度条/滑块/开关等 accent 语义控件自动跟随樱粉
        .tint(NagomiTheme.accent)
        // 全局禁用焦点环（点击/Tab 后按钮周围的蓝色框，用户要求去除）；
        // 键盘导航的视觉指示一并关闭——已获用户确认
        .focusEffectDisabled()
        // 不用窗口工具栏：播放器/番库/Bangumi 三页顶部（标题栏）高度保持一致，
        // 避免切换页面时 UI 上下跳动（"打开文件"按钮已移入播放器顶部栏）
        .onAppear {
            updateWindowTitle()
            // 主题化标题条：标题条透明 + 窗底用主题色（粉色透出为标题条背景）；
            // 不加 .fullSizeContentView——内容不伸入标题条，布局零改动
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.titlebarAppearsTransparent = true
                window.backgroundColor = NagomiTheme.windowNSBackground
            }
            // 自动连播：注入"下一集"解析（本地番库按文件顺序、云端片源按分集号）
            model.nextEpisodeResolver = { context in
                if context.isOnline {
                    return try? await online.nextPlayback(
                        seriesKey: context.seriesKey,
                        afterNumber: context.episodeNumber
                    )
                }
                return library.nextLocalPlayback(after: context.url)
            }
        }
        .onReceive(model.$fileName) { _ in
            updateWindowTitle()
        }
        .onChange(of: selection) { _ in
            updateWindowTitle()
        }
        .onChange(of: selection) { newValue in
            // 切离播放器自动暂停：画面不可见时音频在后台裸放体验差（用户偏好）。
            // 切回保持暂停、不自动续播——开始播放只由明确动作触发（空格/点播放/点集），
            // 避免"只是回来看一眼却被突然出声"。
            if newValue != .player {
                model.pauseForHiddenUI()
            }
            continueWatchingRevision += 1
        }
        .onChange(of: account.isLoggedIn) { loggedIn in
            if loggedIn {
                // 登录成功：补同步离线/未登录期间积压的"看过"记录
                Task { await model.flushPendingWatchedIfPossible() }
            }
            // 统一登录完成后（无论从收藏页还是聊天页发起）：回到发起页并清空待处理目标
            guard loggedIn, let target = loginReturnTarget else { return }
            loginReturnTarget = nil
            webChat.showInbox()
            selection = target
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            // 注意：不用 withAnimation 包裹 —— 全屏过渡期间动画化侧边栏增删会让
            // 窗口在约束更新递归里反复标脏（详见 scheduleApplyFullScreenStyle 注释）
            isFullScreen = true
            scheduleApplyFullScreenStyle(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
            scheduleApplyFullScreenStyle(false)
        }
        // 在线绑定 sheet 统一在根视图呈现：番库页与在线页都常驻挂载（惰性挂载），
        // 若挂在各自页面会因监听同一个 bindTarget 而双弹
        .sheet(
            isPresented: Binding(
                get: { online.bindTarget != nil },
                set: { if !$0 { online.bindTarget = nil } }
            )
        ) {
            if let show = online.bindTarget {
                OnlineBindSheet(model: online, show: show)
            }
        }
    }

    /// 标题栏文字：播放中显示文件名，其余任何时候（番库/Bangumi/空状态）显示 NagomiAni
    private func updateWindowTitle() {
        let title: String
        if selection == .player, let name = model.fileName {
            title = name
        } else {
            title = "NagomiAni"
        }
        NSApp.windows.first(where: { $0.isVisible })?.title = title
    }

    /// 继续观看卡片：resume.json 最近的可续播记录映射为本地/云端混排条目。
    /// **一部番只保留一张卡**（最后一次看的那集）；其余集的进度仍留在 resume.json，
    /// 从番库点播对应集时依然从各自位置续播——这里只是展示层去重。
    private func continueWatchingItems() -> [ContinueWatchingItem] {
        var seenSeries: Set<String> = []
        var items: [ContinueWatchingItem] = []
        // snapshot 已按更新时间降序：每部番第一条即最新观看记录
        for record in model.recentResumes(limit: 60) {
            let progress = record.duration > 0 ? min(record.position / record.duration, 1) : 0

            if record.key.hasPrefix("online:") {
                // 合成键 "online:provider:showID:number" → 云端番
                let parts = record.key.dropFirst("online:".count).split(separator: ":").map(String.init)
                guard parts.count == 3, let number = Int(parts[2]) else { continue }
                // resume 键 = seriesKey + ":集号"，去掉尾部即 seriesKey（一部番一张卡的分组键）
                let seriesKey = String(record.key.dropLast(":\(number)".count))
                guard seenSeries.insert(seriesKey).inserted else { continue }
                // 优先番库收藏（有标题），否则回退到本会话见过的番（搜索结果点播的场景）
                let show = online.knownShow(forSeriesKey: seriesKey)
                    ?? online.libraryEntries.first(where: {
                        $0.providerID == parts[0] && $0.showID == parts[1]
                    })?.asShow
                guard let show else { continue }
                let episode = OnlineEpisode(providerID: show.providerID, showID: show.showID, number: number)
                items.append(ContinueWatchingItem(
                    id: record.key,
                    title: show.title,
                    subtitle: "上次看到第 \(number) 集 · 云端",
                    progress: progress,
                    updatedAt: record.updatedAt,
                    action: .cloud(show: show, episode: episode)
                ))
            } else {
                // 本地文件路径 → 番库系列（seriesKey = 目录路径，同样一部番一张卡）
                let url = URL(fileURLWithPath: record.key)
                guard let series = library.series.first(where: { $0.files.contains { $0.path == url.path } }) else {
                    continue
                }
                guard seenSeries.insert(series.seriesKey).inserted else { continue }
                let file = series.files.first { $0.path == url.path }
                let subtitle = file?.episodeNumber.map { "上次看到第 \($0) 集 · 本地" } ?? "上次看到 · 本地"
                items.append(ContinueWatchingItem(
                    id: record.key,
                    title: series.displayName,
                    subtitle: subtitle,
                    progress: progress,
                    updatedAt: record.updatedAt,
                    action: .local(url)
                ))
            }
            if items.count >= 6 { break } // 最多 6 部
        }
        return items
    }

    /// 全屏样式改动延后到下一 runloop 再执行。
    ///
    /// 崩溃根因：若在 didEnter/didExitFullScreen 通知回调内**同步**修改窗口
    /// styleMask（增删 .fullSizeContentView）或 titlebarAppearsTransparent，
    /// 会改变 contentLayoutRect → SwiftUI 的 NSHostingView 在 AppKit 的
    /// “Update Constraints in Window” 显示周期里反复被标为需要再次更新约束，
    /// 次数随每次进出全屏累积，一旦超过窗口内视图数量 AppKit 即抛异常
    /// （NSGenericException: The window has been marked as needing another
    /// Update Constraints in Window pass …），进程闪退。
    /// 把改动推迟到回调返回之后（独立 runloop tick），不再嵌进该递归里。
    private func scheduleApplyFullScreenStyle(_ full: Bool) {
        // ContentView 是 struct（值语义），闭包捕获视图值本身不产生引用环；
        // applyFullScreenStyle 内部只用 NSApp，不依赖捕获的视图状态
        let apply = applyFullScreenStyle
        DispatchQueue.main.async {
            apply(full)
        }
    }

    /// 全屏时让内容铺满整个屏幕（标题栏与三色按钮交给系统全屏机制：
    /// 鼠标移顶呼出、移开立即收回）。
    /// 标题条透明是**永久状态**（窗口化也透明——透出主题色窗底，标题条随主题）；
    /// 全屏只增删 .fullSizeContentView。
    private func applyFullScreenStyle(_ full: Bool) {
        guard let window = NSApp.keyWindow else { return }
        window.titlebarAppearsTransparent = true
        if full {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
    }

    /// 页面容器：**已访问过的页面全部保留挂载**，只切换显隐（opacity + 命中测试）。
    ///
    /// 为什么不用 `switch`：switch 会销毁/重建整棵页面子树，于是每次切回来
    /// 都要重新走一遍 `onAppear`（重新请求数据）并丢失滚动位置与内部状态，
    /// 表现为"切回 Bangumi 又要重新加载一遍"。
    ///
    /// 惰性挂载：没访问过的页面不挂载，避免启动时就建起聊天页 WebView、
    /// 播放器渲染视图等重资源。`visited` 只增不减。
    private var content: some View {
        ZStack {
            ForEach(SidebarItem.allCases) { item in
                if visited.contains(item) {
                    page(for: item)
                        // 隐藏用 opacity 而非 removeFromHierarchy：视图与状态都保住
                        .opacity(selection == item ? 1 : 0)
                        .allowsHitTesting(selection == item)
                        // 不可见页面不应被辅助功能/键盘遍历到
                        .accessibilityHidden(selection != item)
                        .zIndex(selection == item ? 1 : 0)
                }
            }
        }
        .onChange(of: selection) { newValue in
            if let newValue { visited.insert(newValue) }
        }
    }

    @ViewBuilder
    private func page(for item: SidebarItem) -> some View {
        switch item {
        case .library:
            LibraryPage(
                model: library,
                online: online,
                continueWatchingProvider: { continueWatchingItems() },
                continueWatchingRevision: continueWatchingRevision,
                onPlay: { url in
                // 防御：索引残留了磁盘上已不存在的文件（正常应在"更新"重扫时清掉）——
                // 不再切播放页尝试播放，而是触发该目录重扫并把失效条目清掉
                guard FileManager.default.fileExists(atPath: url.path) else {
                    if let series = library.series.first(where: { $0.files.contains { $0.path == url.path } }) {
                        library.rescanFolder(of: series)
                        library.statusMessage = "本地文件已删除：\(url.lastPathComponent)，已重扫该目录并移除失效条目"
                    }
                    return
                }
                // 从番库点播本地文件：切到播放器页加载；
                // 目录已在番库中关联 → 直接复用绑定，顶部不再提示"关联条目"
                selection = .player
                let series = library.series.first { $0.files.contains { $0.path == url.path } }
                Task {
                    await model.load(
                        url: url,
                        fromLibrary: true,
                        librarySubjectID: series?.subjectID,
                        librarySubject: series.flatMap { library.cover(for: $0) }
                    )
                }
                },
                onPlayOnline: { playback in
                // 从番库点播云端剧集：经对应片源取流后加载（绑定/续播/自动同步与在线页同链路）
                selection = .player
                Task {
                    await model.load(
                        url: playback.url,
                        librarySubjectID: playback.boundSubjectID,
                        librarySubject: playback.boundSubject,
                        displayTitle: playback.displayTitle,
                        resumeKey: playback.resumeKey,
                        mediaOverride: MediaOverride(
                            episodeNumber: playback.episodeNumber,
                            seriesKey: playback.seriesKey
                        ),
                        httpHeaders: playback.httpHeaders,
                        userAgent: playback.userAgent,
                        routes: playback.routes,
                        showTitle: playback.showTitle
                    )
                }
                }
            )
        case .chat:
            ChatPage(account: account, web: webChat)
        case .search:
            // 搜索页 = 内容发现 + 在线观看入口（详情页「在线观看」区按需搜片源）；
            // 「在线」独立模块已并入（2026-09-29 用户决策，减少一个模块）
            SearchPage(model: search, online: online, onPlayOnline: { playOnline($0) })
        case .bangumi:
            BangumiPage(model: account, online: online, onPlayOnline: { playOnline($0) }) {
                startUnifiedLogin(returnTo: .bangumi)
            }
        case .player:
            PlayerView(model: model)
        }
    }

    /// 从搜索页/Bangumi 详情的「在线观看」点播云端剧集（番库云端行同链路）：
    /// 切到播放器页并加载网络流（绑定/续播/自动标记看过走同一套链路）
    private func playOnline(_ playback: OnlinePlayback) {
        selection = .player
        Task {
            await model.load(
                url: playback.url,
                librarySubjectID: playback.boundSubjectID,
                librarySubject: playback.boundSubject,
                displayTitle: playback.displayTitle,
                resumeKey: playback.resumeKey,
                mediaOverride: MediaOverride(
                    episodeNumber: playback.episodeNumber,
                    seriesKey: playback.seriesKey
                ),
                httpHeaders: playback.httpHeaders,
                userAgent: playback.userAgent,
                routes: playback.routes,
                showTitle: playback.showTitle
            )
        }
    }

    /// 统一登录：切到「聊天」页完成登录+授权（不再弹收藏页的独立授权窗）。
    /// - 网页已登录 → 直接出 OAuth 授权页（点「授权」即完成）；
    /// - 网页未登录 → 先切到 bgm 登录页，登录成功后自动续接授权页
    ///   （未登录时直接请求授权页，bgm 登录跳转会把 redirect_uri 弄丢 → invalid_uri）。
    /// 完成后（account.isLoggedIn 变 true）由 onChange 自动回到发起页。
    private func startUnifiedLogin(returnTo: SidebarItem?) {
        guard !account.isLoading else { return }
        loginReturnTarget = returnTo
        selection = .chat
        let accountRef = account
        Task { @MainActor in
            if await webChat.isWebLoggedIn() {
                webChat.startOAuth(account: accountRef)
            } else {
                webChat.showLoginPage()
            }
        }
    }
}

/// 应用左侧固定侧边栏（不可折叠）
struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @State private var hoveredItem: SidebarItem?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarItem.allCases) { item in
                HStack(spacing: 9) {
                    Image(systemName: item.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selection == item ? NagomiTheme.accent : .secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            selection == item ? NagomiTheme.accentSoft : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    Text(item.title)
                        .font(.system(size: 13, weight: selection == item ? .medium : .regular))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                // 用点击手势而非 Button：避免 macOS 焦点环（点击后残留蓝色粗框）
                .background(
                    background(for: item),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .onTapGesture {
                    selection = item
                }
                .onHover { hovering in
                    if hovering {
                        hoveredItem = item
                    } else if hoveredItem == item {
                        hoveredItem = nil
                    }
                }
                .accessibilityAddTraits(.isButton)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NagomiTheme.pageBackground)
    }

    private func background(for item: SidebarItem) -> Color {
        if selection == item {
            return NagomiTheme.accentSoft
        }
        if hoveredItem == item {
            return NagomiTheme.cardHover
        }
        return Color.clear
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case player
    case library
    case search
    case bangumi
    case chat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "播放器"
        case .library: return "番库"
        case .search: return "搜索"
        case .bangumi: return "Bangumi"
        case .chat: return "聊天"
        }
    }

    var icon: String {
        switch self {
        case .player: return "play.rectangle"
        case .library: return "books.vertical"
        case .search: return "magnifyingglass"
        case .bangumi: return "person.crop.circle"
        case .chat: return "message"
        }
    }
}

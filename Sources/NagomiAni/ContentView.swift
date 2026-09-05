import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @StateObject private var account = AccountViewModel()
    @StateObject private var library = LibraryViewModel()
    @StateObject private var search = SearchViewModel()
    @State private var selection: SidebarItem? = .player
    /// 全屏时隐藏侧边栏，让视频占满整个屏幕（无 UI 边框）
    @State private var isFullScreen = false

    var body: some View {
        HStack(spacing: 0) {
            if !isFullScreen {
                SidebarView(selection: $selection)
                    .frame(width: 170)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 不用窗口工具栏：播放器/番库/Bangumi 三页顶部（标题栏）高度保持一致，
        // 避免切换页面时 UI 上下跳动（"打开文件"按钮已移入播放器顶部栏）
        .onAppear {
            updateWindowTitle()
        }
        .onReceive(model.$fileName) { _ in
            updateWindowTitle()
        }
        .onChange(of: selection) { _ in
            updateWindowTitle()
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

    /// 全屏时让内容铺满整个屏幕（标题栏区域透明化、无白框），
    /// 标题栏与三色按钮交给系统全屏机制：鼠标移顶呼出、移开立即收回
    private func applyFullScreenStyle(_ full: Bool) {
        guard let window = NSApp.keyWindow else { return }
        window.titlebarAppearsTransparent = full
        if full {
            window.styleMask.insert(.fullSizeContentView)
        } else {
            window.styleMask.remove(.fullSizeContentView)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .library:
            LibraryPage(model: library) { url in
                // 防御：索引残留了磁盘上已不存在的文件（正常应在"更新"重扫时清掉）——
                // 不再切播放页尝试播放，而是触发该目录重扫并把失效条目清掉
                guard FileManager.default.fileExists(atPath: url.path) else {
                    if let series = library.series.first(where: { $0.files.contains { $0.path == url.path } }) {
                        library.rescanFolder(of: series)
                        library.statusMessage = "本地文件已删除：\(url.lastPathComponent)，已重扫该目录并移除失效条目"
                    }
                    return
                }
                // 从番库点播：切到播放器页并加载文件；
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
            }
        case .bangumi:
            BangumiPage(model: account)
        case .search:
            SearchPage(model: search)
        case .player, nil:
            PlayerView(model: model)
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
                HStack(spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.system(size: 14))
                        .frame(width: 20)
                    Text(item.title)
                        .font(.system(size: 13))
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func background(for item: SidebarItem) -> Color {
        if selection == item {
            return Color.accentColor.opacity(0.2)
        }
        if hoveredItem == item {
            return Color.gray.opacity(0.12)
        }
        return Color.clear
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case player
    case library
    case search
    case bangumi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "播放器"
        case .library: return "番库"
        case .search: return "搜索"
        case .bangumi: return "Bangumi"
        }
    }

    var icon: String {
        switch self {
        case .player: return "play.rectangle"
        case .library: return "books.vertical"
        case .search: return "magnifyingglass"
        case .bangumi: return "person.crop.circle"
        }
    }
}

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
            withAnimation(.easeOut(duration: 0.2)) { isFullScreen = true }
            applyFullScreenStyle(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) { isFullScreen = false }
            applyFullScreenStyle(false)
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

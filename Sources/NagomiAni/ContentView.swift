import SwiftUI

struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @StateObject private var account = AccountViewModel()
    @StateObject private var library = LibraryViewModel()
    @State private var selection: SidebarItem? = .player

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            switch selection {
            case .library:
                LibraryPage(model: library) { url in
                    // 从番库点播：切到播放器页并加载文件
                    selection = .player
                    Task { await model.load(url: url) }
                }
            case .bangumi:
                BangumiPage(model: account)
            case .player, nil:
                playerPage
            }
        }
    }

    private var playerPage: some View {
        PlayerView(model: model)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.openPanel()
                    } label: {
                        Label("打开文件", systemImage: "folder")
                    }
                }
            }
            .navigationTitle(model.fileName ?? "NagomiAni")
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case player
    case library
    case bangumi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "播放器"
        case .library: return "番库"
        case .bangumi: return "Bangumi"
        }
    }

    var icon: String {
        switch self {
        case .player: return "play.rectangle"
        case .library: return "books.vertical"
        case .bangumi: return "person.crop.circle"
        }
    }
}

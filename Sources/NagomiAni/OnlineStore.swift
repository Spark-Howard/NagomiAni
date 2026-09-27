import Foundation
import NagomiAniCore

/// 在线页点播时要交给 PlayerModel.load 的全部参数
struct OnlinePlayback {
    let url: URL
    let displayTitle: String
    let seriesKey: String
    let episodeNumber: Int
    let resumeKey: String
    let httpHeaders: [String: String]
    let userAgent: String?
    /// 已绑定的 Bangumi 条目（nil = 未绑定；经 PlayerModel.bindLocal 复用绑定保证播完自动同步）
    let boundSubjectID: Int?
    let boundSubject: Subject?
}

/// 在线片源页的状态模型：汇总各 Provider 的目录，组装点播参数。
/// 绑定/已看状态在 M2 接入（与 PlayerModel 共用 UserDefaults 绑定表）。
@MainActor
final class OnlineStore: ObservableObject {
    @Published private(set) var shows: [OnlineShow] = []
    /// show.id → 集列表
    @Published private(set) var episodes: [String: [OnlineEpisode]] = [:]
    @Published var statusMessage: String?
    @Published private(set) var isLoadingShows = false
    @Published private(set) var isPreparing = false

    private let providers: [SourceProvider]
    private var showsLoaded = false

    init(providers: [SourceProvider] = [MockProvider()]) {
        self.providers = providers
    }

    // MARK: - 目录

    func loadShowsIfNeeded() async {
        guard !showsLoaded, !isLoadingShows else { return }
        isLoadingShows = true
        defer { isLoadingShows = false }
        var all: [OnlineShow] = []
        for provider in providers {
            do {
                all.append(contentsOf: try await provider.listShows())
            } catch {
                statusMessage = "\(provider.displayName) 加载失败：\(error.localizedDescription)"
            }
        }
        shows = all
        showsLoaded = true
    }

    /// 展开番条目/行出现时加载集列表（幂等）
    func ensureEpisodes(for show: OnlineShow) async {
        guard episodes[show.id] == nil else { return }
        guard let provider = provider(id: show.providerID) else { return }
        do {
            episodes[show.id] = try await provider.episodes(for: show.showID)
        } catch {
            episodes[show.id] = []
            statusMessage = "\(provider.displayName) 集列表加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 点播

    /// 取流 URL 并组装播放参数（mock 首次播放要生成样例视频，可能耗时几十秒）
    func preparePlayback(show: OnlineShow, episode: OnlineEpisode) async throws -> OnlinePlayback {
        guard let provider = provider(id: episode.providerID) else {
            throw OnlineStoreError.unknownProvider
        }
        isPreparing = true
        defer { isPreparing = false }
        statusMessage = "正在准备「\(show.title) 第 \(episode.number) 集」的片源…"
        let source = try await provider.streamURL(for: episode)
        statusMessage = nil
        return OnlinePlayback(
            url: source.url,
            displayTitle: Self.displayTitle(show: show, episode: episode),
            seriesKey: episode.seriesKey,
            episodeNumber: episode.number,
            resumeKey: episode.resumeKey,
            httpHeaders: source.httpHeaders,
            userAgent: source.userAgent,
            boundSubjectID: nil,
            boundSubject: nil
        )
    }

    private func provider(id: String) -> SourceProvider? {
        providers.first { $0.id == id }
    }

    /// 播放器顶部/窗口标题统一显示的标题
    static func displayTitle(show: OnlineShow, episode: OnlineEpisode) -> String {
        "\(show.title) · 第 \(episode.number) 集"
    }
}

enum OnlineStoreError: LocalizedError {
    case unknownProvider

    var errorDescription: String? {
        switch self {
        case .unknownProvider: return "未知的片源提供方"
        }
    }
}

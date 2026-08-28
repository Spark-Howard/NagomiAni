import AppKit
import Foundation
import NagomiAniCore

/// 播放器的 UI 状态模型：桥接 PlaybackEngine 与 SwiftUI
final class PlayerModel: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var fileName: String?
    @Published var isSeeking = false
    @Published var seekValue: Double = 0

    // Bangumi 关联与同步
    @Published private(set) var boundSubject: Subject?
    @Published var syncMessage: String?
    @Published var isBindSheetPresented = false
    @Published var searchResults: [Subject] = []
    @Published var isSearching = false

    let engine = MPVPlaybackEngine()

    private var currentMedia: (episodeNumber: Int?, seriesKey: String)?
    private var sharedClient: BangumiClient?
    private lazy var auth: BangumiAuth? = {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "bangumi.clientID") ?? ""
        let secret = defaults.string(forKey: "bangumi.clientSecret") ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return BangumiAuth(config: BangumiAppConfig(clientID: id, clientSecret: secret))
    }()

    private static let bindingsKey = "bangumi.bindings"       // [seriesKey: subjectID]
    private static let boundNamesKey = "bangumi.boundNames"   // [seriesKey: 显示名]

    init() {
        engine.delegate = self
    }

    // MARK: - 动作

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择一个视频文件"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await load(url: url) }
        }
    }

    func load(url: URL) async {
        fileName = url.lastPathComponent
        currentMedia = MediaMatching.parse(fileName: url.lastPathComponent)
        syncMessage = nil
        restoreBinding()
        do {
            try await engine.load(url: url, options: PlaybackOptions())
        } catch {
            // 引擎已通过 delegate 上报 failed 状态
        }
    }

    func togglePlayPause() {
        if engine.isPlaying {
            engine.pause()
        } else {
            if state == .finished {
                engine.seek(to: 0, completion: nil)
            }
            engine.play()
        }
    }

    func seek(to seconds: Double) {
        engine.seek(to: seconds, completion: nil)
    }

    // MARK: - Bangumi 关联

    func search(keyword: String) async {
        guard let client = await bangumiClient() else {
            syncMessage = "未登录 Bangumi，无法搜索（请先在 Bangumi 页登录）"
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let page = try await client.searchSubjects(keyword: keyword, limit: 20)
            searchResults = page.data
        } catch {
            searchResults = []
            syncMessage = "搜索失败：\(Self.describe(error))"
        }
    }

    func bind(subject: Subject) {
        guard let media = currentMedia else { return }
        var ids = bindingIDs()
        var names = boundNames()
        ids[media.seriesKey] = subject.id
        names[media.seriesKey] = subject.nameCN ?? subject.name ?? "未命名"
        UserDefaults.standard.set(ids, forKey: Self.bindingsKey)
        UserDefaults.standard.set(names, forKey: Self.boundNamesKey)
        boundSubject = subject
        isBindSheetPresented = false
        syncMessage = "已关联「\(names[media.seriesKey] ?? "")」，本集播完自动同步"
    }

    func unbind() {
        guard let media = currentMedia else { return }
        var ids = bindingIDs()
        var names = boundNames()
        ids.removeValue(forKey: media.seriesKey)
        names.removeValue(forKey: media.seriesKey)
        UserDefaults.standard.set(ids, forKey: Self.bindingsKey)
        UserDefaults.standard.set(names, forKey: Self.boundNamesKey)
        boundSubject = nil
        syncMessage = "已解除关联"
    }

    // MARK: - 自动同步（播完标记看过）

    private func autoSyncOnFinish() {
        guard let media = currentMedia,
              let episode = media.episodeNumber,
              let subjectID = bindingID(for: media.seriesKey) else {
            return
        }
        Task {
            do {
                guard let client = await bangumiClient() else {
                    syncMessage = "未登录，本集未能同步到 Bangumi"
                    return
                }
                let eps = try await client.episodes(subjectID: subjectID, type: 0, limit: 300)
                guard let ep = eps.data.first(where: { Int(($0.sort ?? 0).rounded()) == episode }) else {
                    syncMessage = "在 Bangumi 上未找到第 \(episode) 集，跳过同步"
                    return
                }
                try await client.markEpisodes(subjectID: subjectID, episodeIDs: [ep.id], type: .watched)
                syncMessage = "已同步：第 \(episode) 集标记为看过 ✓"
            } catch {
                syncMessage = "同步失败：\(Self.describe(error))"
            }
        }
    }

    // MARK: - 派生状态

    var isLoading: Bool { state == .loading }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var formattedCurrentTime: String { Self.format(currentTime) }
    var formattedDuration: String { Self.format(duration) }

    // MARK: - 私有

    private func bangumiClient() async -> BangumiClient? {
        guard let auth, auth.isLoggedIn else { return nil }
        try? await auth.refreshIfNeeded()
        if sharedClient == nil {
            sharedClient = BangumiClient()
        }
        sharedClient?.accessToken = auth.accessToken
        return sharedClient
    }

    private func restoreBinding() {
        guard let media = currentMedia, let id = bindingID(for: media.seriesKey) else {
            boundSubject = nil
            return
        }
        boundSubject = nil
        Task {
            if let client = await bangumiClient(),
               let subject = try? await client.subject(id: id) {
                boundSubject = subject
            }
        }
    }

    private func bindingID(for seriesKey: String) -> Int? {
        bindingIDs()[seriesKey]
    }

    private func bindingIDs() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: Self.bindingsKey) as? [String: Int] ?? [:]
    }

    private func boundNames() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.boundNamesKey) as? [String: String] ?? [:]
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - PlaybackEngineDelegate

extension PlayerModel: PlaybackEngineDelegate {
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double) {
        if !isSeeking { currentTime = time }
    }

    func playbackEngine(_ engine: PlaybackEngine, didChangeState state: PlaybackState) {
        self.state = state
        if case .ready = state {
            duration = engine.duration
        }
    }

    func playbackEngineDidFinish(_ engine: PlaybackEngine) {
        autoSyncOnFinish()
    }

    func playbackEngine(_ engine: PlaybackEngine, didFailWith error: Error) {}
}

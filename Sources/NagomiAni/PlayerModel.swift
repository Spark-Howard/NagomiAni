import AppKit
import Foundation
import UniformTypeIdentifiers
import NagomiAniCore

/// 播放器的 UI 状态模型：桥接 PlaybackEngine 与 SwiftUI
final class PlayerModel: ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var fileName: String?
    @Published var isSeeking = false
    /// 进度条唯一数据源：播放中跟随引擎时间，拖动时只跟随手指位置
    @Published var sliderValue: Double = 0

    // 音轨 / 字幕
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var subtitleDelay: Double = 0

    // Bangumi 关联与同步
    @Published private(set) var boundSubject: Subject?
    @Published private(set) var hideBindingBar = false
    @Published var syncMessage: String?
    @Published var isBindSheetPresented = false
    @Published var searchResults: [Subject] = []
    @Published var isSearching = false

    let engine = MPVPlaybackEngine()

    private var currentMedia: (episodeNumber: Int?, seriesKey: String)?
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

    func load(
        url: URL,
        fromLibrary: Bool = false,
        librarySubjectID: Int? = nil,
        librarySubject: Subject? = nil
    ) async {
        fileName = url.lastPathComponent
        currentMedia = MediaMatching.parse(fileName: url.lastPathComponent)
        hideBindingBar = fromLibrary
        syncMessage = nil
        if fromLibrary, let id = librarySubjectID {
            // 从番库打开：该目录已在番库中关联，直接复用绑定（保证播完自动同步生效），
            // 顶部不再提示"关联条目"
            bindLocal(subjectID: id, subject: librarySubject)
        } else {
            restoreBinding()
        }
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

    // MARK: - 自动同步（看完标记看过）

    /// 本次运行已标记过的集（"seriesKey:集号"），避免重复请求
    private var markedWatchedKeys: Set<String> = []
    /// 最近一次跳转时间（阈值判定时忽略 seek 后短暂时间，防拖动误报）
    private var lastSeekTime: Date?
    /// 看完判定：播放比例达到该值即算看完（不等 EOF）
    private let watchedRatio: Double = 0.85
    /// 阈值判定要求的最短时长（秒）：低于此不触发，防短视频/测试片误报
    private let watchedMinDuration: Double = 300
    /// seek 后忽略阈值判定的窗口（秒）
    private let seekIgnoreWindow: TimeInterval = 10

    func seek(to seconds: Double) {
        lastSeekTime = Date()
        engine.seek(to: seconds, completion: nil)
    }

    /// 播放中判定：自然播放到 85% 即标记看过（EOF 由 playbackEngineDidFinish 兜底）
    private func checkAutoMarkWatched() {
        guard state == .playing, currentTime > 0, duration >= watchedMinDuration else { return }
        // seek/拖动后短时间内不判定，避免"拖到 90%"被误标
        if let lastSeek = lastSeekTime, Date().timeIntervalSince(lastSeek) < seekIgnoreWindow {
            return
        }
        guard currentTime / duration >= watchedRatio,
              let media = currentMedia,
              let episode = media.episodeNumber,
              bindingID(for: media.seriesKey) != nil else { return }
        let key = "\(media.seriesKey):\(episode)"
        guard !markedWatchedKeys.contains(key) else { return }
        markWatched(episode: episode, seriesKey: media.seriesKey, key: key)
    }

    private func autoSyncOnFinish() {
        guard let media = currentMedia,
              let episode = media.episodeNumber,
              bindingID(for: media.seriesKey) != nil else {
            return
        }
        let key = "\(media.seriesKey):\(episode)"
        guard !markedWatchedKeys.contains(key) else { return }
        markWatched(episode: episode, seriesKey: media.seriesKey, key: key)
    }

    private func markWatched(episode: Int, seriesKey: String, key: String) {
        // 先入集合：同一集本次运行内只触发一次
        markedWatchedKeys.insert(key)
        Task {
            do {
                guard let client = await bangumiClient() else {
                    syncMessage = "未登录，本集未能同步到 Bangumi"
                    return
                }
                guard let subjectID = bindingID(for: seriesKey) else { return }
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

    // MARK: - 音轨 / 字幕

    func selectAudioTrack(_ index: Int) {
        engine.selectAudioTrack(index)
        syncTracks()
    }

    func selectSubtitleTrack(_ index: Int) {
        engine.selectSubtitleTrack(index)
        syncTracks()
    }

    func setSubtitleEnabled(_ enabled: Bool) {
        engine.setSubtitleEnabled(enabled)
        syncTracks()
    }

    func adjustSubtitleDelay(by delta: Double) {
        engine.subtitleDelay += delta
        subtitleDelay = engine.subtitleDelay
    }

    func resetSubtitleDelay() {
        engine.subtitleDelay = 0
        subtitleDelay = 0
    }

    var formattedSubtitleDelay: String {
        subtitleDelay == 0 ? "0s" : String(format: "%+.1fs", subtitleDelay)
    }

    /// 打开面板选择外挂字幕文件（可多选）
    func loadExternalSubtitle() {
        guard fileName != nil else {
            syncMessage = "请先打开视频，再挂载外挂字幕"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择外挂字幕文件"
        panel.message = "选择一个或多个字幕文件（.srt / .ass / .ssa / .vtt / .sub 等）"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.subtitleTypes
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            loadExternalSubtitle(url: url)
        }
    }

    /// 挂载单个外挂字幕文件（面板与拖拽共用）
    func loadExternalSubtitle(url: URL) {
        guard fileName != nil else {
            syncMessage = "请先打开视频，再挂载外挂字幕"
            return
        }
        if engine.addExternalSubtitle(url: url) {
            syncMessage = "已加载外挂字幕：\(url.lastPathComponent)"
        } else {
            syncMessage = "字幕加载失败：\(url.lastPathComponent)"
        }
    }

    private func syncTracks() {
        audioTracks = engine.audioTracks
        subtitleTracks = engine.subtitleTracks
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

    /// 直接写入本地绑定（番库打开时复用已有关联，不弹关联提示）
    private func bindLocal(subjectID: Int, subject: Subject?) {
        guard let media = currentMedia else { return }
        var ids = bindingIDs()
        var names = boundNames()
        ids[media.seriesKey] = subjectID
        if let subject {
            names[media.seriesKey] = subject.nameCN ?? subject.name ?? "未命名"
        }
        UserDefaults.standard.set(ids, forKey: Self.bindingsKey)
        UserDefaults.standard.set(names, forKey: Self.boundNamesKey)
        boundSubject = subject
        if subject == nil {
            // 名称未知时异步补齐（顶栏虽隐藏，但保持状态一致）
            Task {
                if let client = await bangumiClient(),
                   let fetched = try? await client.subject(id: subjectID) {
                    boundSubject = fetched
                }
            }
        }
    }

    // MARK: - 派生状态

    var isLoading: Bool { state == .loading }

    var errorMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var formattedDuration: String { Self.format(duration) }

    /// 拖动中显示手指位置，否则显示播放位置（进度条与时间文本共用）
    var displayTime: Double { isSeeking ? sliderValue : currentTime }
    var formattedDisplayTime: String { Self.format(displayTime) }

    // MARK: - 私有

    /// 常见字幕扩展名（面板与拖拽共用判断）
    static let subtitleExtensions: Set<String> = [
        "srt", "ass", "ssa", "vtt", "sub", "smi", "mpl2", "mks", "sup"
    ]

    static var subtitleTypes: [UTType] {
        var types: [UTType] = subtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        if types.isEmpty {
            types = [.data] // 兜底：允许选择任意文件
        }
        return types
    }

    static func isSubtitleFile(_ url: URL) -> Bool {
        subtitleExtensions.contains(url.pathExtension.lowercased())
    }

    private func bangumiClient() async -> BangumiClient? {
        // 与番库/其他模块共用同一登录判定（auth.json），避免 defaults 域不一致导致的假"未登录"
        await BangumiSession.makeClient()
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
        if !isSeeking {
            currentTime = time
            sliderValue = time
        }
        // 自然播放到阈值即标记看过（EOF 由 playbackEngineDidFinish 兜底）
        checkAutoMarkWatched()
    }

    func playbackEngine(_ engine: PlaybackEngine, didChangeState state: PlaybackState) {
        self.state = state
        if case .ready = state {
            duration = engine.duration
            syncTracks()
        }
    }

    func playbackEngineDidFinish(_ engine: PlaybackEngine) {
        autoSyncOnFinish()
    }

    func playbackEngine(_ engine: PlaybackEngine, didFailWith error: Error) {}

    func playbackEngineDidUpdateTracks(_ engine: PlaybackEngine) {
        syncTracks()
    }
}

import AppKit
import Foundation
import Network
import UniformTypeIdentifiers
import NagomiAniCore

/// 在线片源的媒体信息覆盖：没有文件名可解析，集号与合成 seriesKey 由片源直接给出。
/// 携带它即视为"在线打开"（复用番库的隐藏关联栏/复用绑定行为）。
struct MediaOverride: Equatable {
    let episodeNumber: Int?
    let seriesKey: String
}

/// 自动连播解析"下一集"所需的当前播放上下文
struct AutoNextContext: Equatable {
    let url: URL
    let seriesKey: String
    let episodeNumber: Int
    let isOnline: Bool
}

/// 播放器的 UI 状态模型：桥接 PlaybackEngine 与 SwiftUI。
/// @MainActor：引擎的 delegate 回调本身就在主线程（见 PlaybackEngineDelegate 契约），
/// 显式标注保证所有 @Published 变更与内部 Task 都在主线程——
/// 连播提示/换线/自动下一集等异步链路不得在后台线程发布 UI 状态。
@MainActor
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

    // 自动连播（2026-09-27 由 EOF 自动切换改为征询式：95%/EOF 弹提示，点允许才换）
    /// 接近播完时在屏幕下方弹"看下一集"提示；UserDefaults 键沿用旧开关
    @Published var autoPlayNextEnabled: Bool =
        UserDefaults.standard.object(forKey: "player.autoplayNext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoPlayNextEnabled, forKey: Self.autoPlayNextKey) }
    }
    /// 由 ContentView 注入：解析下一集（本地番库按文件顺序、云端片源按分集号）
    var nextEpisodeResolver: ((AutoNextContext) async -> OnlinePlayback?)?
    private var autoNextContext: AutoNextContext?
    private static let autoPlayNextKey = "player.autoplayNext"

    /// 连播提示条（95% 或 EOF 时解析下一集后弹出；用户点"看下一集"才切换）
    struct NextEpisodeOffer {
        let playback: OnlinePlayback
        var label: String { playback.displayTitle ?? "下一集" }
    }
    @Published private(set) var nextEpisodeOffer: NextEpisodeOffer?
    /// 本集内用户点掉提示后不再弹（换集时重置）
    private var nextOfferDismissed = false
    /// 95% 触发器每集只触发一次（EOF 兜底二次触发）
    private var nextOfferTriggered = false
    private var isResolvingNextOffer = false

    // 多线路（在线源）
    /// 当前线路下标（0 起；单线路时无意义）
    @Published private(set) var routeIndex = 0
    /// 当前媒体可用线路数（>1 时播放器显示切换菜单）
    @Published private(set) var routeCount = 0
    /// 当前在线播放的全部参数（换线/换源复用；本地播放为 nil）
    private var activeOnline: OnlinePlayback?

    let engine = MPVPlaybackEngine()
    /// 弹幕拉取与状态（渲染走独立悬浮层，与字幕共存）
    let danmaku = DanmakuController()

    private var currentMedia: (episodeNumber: Int?, seriesKey: String)?
    // 绑定表与 OnlineStore（在线页）共用：合成 seriesKey "online:…" 存同一张表，
    // 在线播完的 markWatched 自动同步才能找到 subjectID
    static let bindingsKey = "bangumi.bindings"       // [seriesKey: subjectID]
    static let boundNamesKey = "bangumi.boundNames"   // [seriesKey: 显示名]

    // 断点续播（按文件路径记录，resume.json 持久化）
    private let resumeStore = PlaybackResumeStore()
    /// 内存中待落盘的当前文件位置（时间回调更新，按 5s 节流写盘）
    private var pendingResume: (path: String, position: Double, duration: Double)?
    private var lastResumeSaveAt: Date?
    /// 续播目标：mpv 起播瞬间 time-pos 会先报 ~0，到达目标前不允许落盘，
    /// 防止起播瞬间的小位置覆盖旧记录（用户手动 seek 即视为放弃该目标）
    private var pendingResumeTarget: Double?
    private var terminateObserver: NSObjectProtocol?
    /// 网络状态监听：离线积压的"看过"记录在联网恢复时自动补同步
    private let networkMonitor = NWPathMonitor()

    init() {
        engine.delegate = self
        // 退出前把最后位置落盘（播放中强杀进程最多丢 5s，可接受）
        // queue: .main 保证闭包在主线程执行；assumeIsolated 显式声明以满足 @MainActor
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushResume(force: true)
            }
        }

        // 离线待同步队列：启动时冲一次；联网恢复时自动补同步
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                await self?.flushPendingWatchedIfPossible()
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "nagomiani.network.monitor"))
        Task { [weak self] in
            await self?.flushPendingWatchedIfPossible()
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
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
        librarySubject: Subject? = nil,
        displayTitle: String? = nil,
        resumeKey: String? = nil,
        mediaOverride: MediaOverride? = nil,
        httpHeaders: [String: String] = [:],
        userAgent: String? = nil,
        routes: [String]? = nil,
        showTitle: String? = nil
    ) async {
        // 换文件前先把上一个文件的位置落盘
        flushResume(force: true)
        // 在线片源没有文件名可解析，标题与集号/系列键由片源直接给出
        fileName = displayTitle ?? url.lastPathComponent
        if let override = mediaOverride {
            currentMedia = (episodeNumber: override.episodeNumber, seriesKey: override.seriesKey)
        } else {
            currentMedia = MediaMatching.parse(fileName: url.lastPathComponent)
        }
        // 记录连播上下文（EOF 时由 nextEpisodeResolver 解析下一集）
        autoNextContext = AutoNextContext(
            url: url,
            seriesKey: currentMedia?.seriesKey ?? "",
            episodeNumber: currentMedia?.episodeNumber ?? 0,
            isOnline: mediaOverride != nil
        )
        // 新的一集：重置连播提示状态
        nextEpisodeOffer = nil
        nextOfferDismissed = false
        nextOfferTriggered = false
        // 在线片源与番库同样在来源页完成关联，顶部不再提示"关联条目"
        hideBindingBar = fromLibrary || mediaOverride != nil
        syncMessage = nil
        if (fromLibrary || mediaOverride != nil), let id = librarySubjectID {
            // 从番库/在线页打开：该内容已关联，直接复用绑定（保证播完自动同步生效）
            bindLocal(subjectID: id, subject: librarySubject)
        } else {
            restoreBinding()
        }
        // 断点续播：键默认取文件路径；在线源用稳定合成键（"online:provider:show:ep"，跨会话不变）
        let resumePath = resumeKey ?? url.standardizedFileURL.path
        // 弹幕匹配上下文：在线番按剧名+集号搜索，本地番按文件指纹匹配
        let danmakuContext = DanmakuController.Context(
            key: resumePath,
            kind: mediaOverride != nil
                ? .online(showTitle: showTitle ?? displayTitle ?? "", episodeNumber: mediaOverride?.episodeNumber ?? 0)
                : .local(url: url)
        )
        // 弹幕在 load 一开始就切换：换集/加载失败时旧弹幕立即清掉，
        // 不会把上一集的弹幕残留在加载中的画面上（同集重载由同集 guard 保留）
        danmaku.prepare(danmakuContext)
        let resumeAt = resumeStore.entry(forPath: resumePath)
            .flatMap { ResumePolicy.resumePosition(position: $0.position, duration: $0.duration) }
        pendingResume = (path: resumePath, position: resumeAt ?? 0, duration: 0)
        pendingResumeTarget = resumeAt
        lastResumeSaveAt = Date()

        // 在线多线路：记录全部参数供换线/自动换源复用；本地播放清空
        if let override = mediaOverride {
            activeOnline = OnlinePlayback(
                url: url,
                displayTitle: displayTitle,
                seriesKey: override.seriesKey,
                episodeNumber: override.episodeNumber ?? 0,
                resumeKey: resumeKey,
                httpHeaders: httpHeaders,
                userAgent: userAgent,
                boundSubjectID: librarySubjectID,
                boundSubject: librarySubject,
                routes: routes ?? [url.absoluteString]
            )
        } else {
            activeOnline = nil
        }
        routeIndex = 0

        // 线路依次尝试：首选失败自动换下一条（全部失败才放弃）
        var routeURLs: [URL] = [url]
        if mediaOverride != nil, let provided = routes {
            var list = provided.compactMap { URL(string: $0) }
            if list.first != url {
                list.removeAll { $0 == url }
                list.insert(url, at: 0)
            }
            if !list.isEmpty {
                routeURLs = list
            }
        }
        // 菜单项以实际可用的线路数为准（无效 URL 在 compactMap 中被剔除）
        routeCount = mediaOverride != nil ? routeURLs.count : 0
        do {
            for (index, attempt) in routeURLs.enumerated() {
                do {
                    try await engine.load(url: attempt, options: PlaybackOptions(
                        startTime: resumeAt ?? 0,
                        httpHeaders: httpHeaders,
                        userAgent: userAgent
                    ))
                    routeIndex = index
                    break
                } catch {
                    // 还有备用线路：提示并继续；没有则把错误抛给外层（引擎已上报 failed）
                    if index + 1 < routeURLs.count {
                        syncMessage = "线路加载失败，自动切换下一条…"
                        continue
                    }
                    throw error
                }
            }
            if let resumeAt {
                syncMessage = "已从 \(Self.format(resumeAt)) 继续播放"
            }
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

    /// 切离播放器页时调用：正在播放则自动暂停（画面已不可见，音频不应在后台裸放）。
    /// 切回时保持暂停，由用户自行开始——不自动续播，避免"回来只是看一眼却被突然出声"。
    /// 暂停触发 didChangeState(.paused) → 强制落盘续播位置，与断点续播正好衔接。
    func pauseForHiddenUI() {
        guard engine.isPlaying else { return }
        engine.pause()
    }

    // MARK: - 自动同步（看完标记看过）

    /// 本次运行已标记过的集（"seriesKey:集号"），避免重复请求
    private var markedWatchedKeys: Set<String> = []
    /// 最近一次跳转时间（阈值判定时忽略 seek 后短暂时间，防拖动误报）
    private var lastSeekTime: Date?
    /// 看完判定：播放比例达到该值即算看完（不等 EOF）；2026-09-27 用户要求 95%
    private let watchedRatio: Double = 0.95
    /// 阈值判定要求的最短时长（秒）：低于此不触发，防短视频/测试片误报
    private let watchedMinDuration: Double = 300
    /// seek 后忽略阈值判定的窗口（秒）
    private let seekIgnoreWindow: TimeInterval = 10

    func seek(to seconds: Double) {
        lastSeekTime = Date()
        // 用户手动跳转即放弃"等引擎到达续播点"的落盘闸门
        pendingResumeTarget = nil
        engine.seek(to: seconds, completion: nil)
    }

    /// 播放中判定：自然播放到 95% 即标记看过（EOF 由 playbackEngineDidFinish 兜底）
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
        // seek/拖动后短时间内到达 EOF（拖到结尾看一眼）不算自然看完，防误标
        if let lastSeek = lastSeekTime, Date().timeIntervalSince(lastSeek) < seekIgnoreWindow { return }
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
        // 已按"看完"处理：清除续播记录，下次从头播
        clearResume()
        Task {
            // subjectID 是本地绑定表查询，不需要网络——离线也能先入待同步队列
            let subjectID = bindingID(for: seriesKey)
            do {
                guard let client = await bangumiClient() else {
                    // 未登录/离线：入队待同步（登录或联网后自动补同步）
                    if let subjectID {
                        enqueuePendingWatched(subjectID: subjectID, episodeNumber: episode)
                        syncMessage = "暂时无法连接 Bangumi，已记录待同步（待同步 \(Self.loadPendingWatchedMarks().count) 条）"
                    } else {
                        syncMessage = "未登录，本集未能同步到 Bangumi"
                    }
                    return
                }
                guard let subjectID else { return }
                let eps = try await client.allEpisodes(subjectID: subjectID)
                guard let ep = eps.first(where: { Int(($0.sort ?? 0).rounded()) == episode }) else {
                    // 永久性失败（条目里没有该集）：不入队，避免无限重试
                    syncMessage = "在 Bangumi 上未找到第 \(episode) 集，跳过同步"
                    return
                }
                try await client.markEpisodes(subjectID: subjectID, episodeIDs: [ep.id], type: .watched)
                syncMessage = "已同步：第 \(episode) 集标记为看过 ✓"
                // 同步成功顺带冲刷积压的离线记录
                await flushPendingWatchedMarks(client: client)
            } catch {
                // 网络/服务端临时错误：入队待同步，联网后自动补；
                // 永久性失败（条目不存在 404/响应异常）重试也无意义，不入队——
                // 否则死重试会挤占队列容量，把真正待同步的记录淘汰掉
                if let subjectID {
                    if Self.isRetryableSyncError(error) {
                        enqueuePendingWatched(subjectID: subjectID, episodeNumber: episode)
                        syncMessage = "同步失败（已记录待重试，共 \(Self.loadPendingWatchedMarks().count) 条）：\(Self.describe(error))"
                    } else {
                        syncMessage = "同步失败（不再重试）：\(Self.describe(error))"
                    }
                } else {
                    syncMessage = "同步失败：\(Self.describe(error))"
                }
            }
        }
    }

    /// 该错误是否值得入队重试：网络/限频/服务端故障可重试；404（条目不存在）、
    /// 4xx 权限类、响应解析失败都是永久性的
    static func isRetryableSyncError(_ error: Error) -> Bool {
        switch error {
        case BangumiError.network:
            return true
        case BangumiError.unauthorized:
            return true // 令牌刷新后可恢复
        case BangumiError.httpStatus(let code, _):
            return code == 429 || code >= 500
        case is URLError:
            return true
        default:
            return false
        }
    }

    // MARK: - 离线待同步队列

    /// 一条待补同步的"看过"记录
    struct PendingWatchedMark: Codable {
        let subjectID: Int
        let episodeNumber: Int
        let queuedAt: Date
    }

    private static let pendingWatchedKey = "bangumi.pendingWatchedMarks"
    /// 队列容量上限（超出丢弃最旧，防无限膨胀）
    private static let pendingWatchedCapacity = 200

    static func loadPendingWatchedMarks() -> [PendingWatchedMark] {
        guard let data = UserDefaults.standard.data(forKey: pendingWatchedKey),
              let marks = try? JSONDecoder().decode([PendingWatchedMark].self, from: data) else { return [] }
        return marks
    }

    private static func savePendingWatchedMarks(_ marks: [PendingWatchedMark]) {
        let trimmed = marks.suffix(pendingWatchedCapacity)
        if let data = try? JSONEncoder().encode(Array(trimmed)) {
            UserDefaults.standard.set(data, forKey: pendingWatchedKey)
        }
    }

    /// 同一 subject+episode 只保留一条（重复看完不重复入队）
    private func enqueuePendingWatched(subjectID: Int, episodeNumber: Int) {
        var marks = Self.loadPendingWatchedMarks()
        if marks.contains(where: { $0.subjectID == subjectID && $0.episodeNumber == episodeNumber }) {
            return
        }
        marks.append(PendingWatchedMark(subjectID: subjectID, episodeNumber: episodeNumber, queuedAt: Date()))
        Self.savePendingWatchedMarks(marks)
    }

    /// 补同步积压记录：**按番分组**——同番只拉一次集数表，命中的集数一次批量标记
    /// （省请求、尊重 bgm.tv 限频）；仍失败的（网络/权限）保留在队列
    private func flushPendingWatchedMarks(client: BangumiClient) async {
        let pending = Self.loadPendingWatchedMarks()
        guard !pending.isEmpty else { return }
        var remaining: [PendingWatchedMark] = []
        var syncedCount = 0
        for (subjectID, marks) in Dictionary(grouping: pending, by: \.subjectID) {
            do {
                let eps = try await client.allEpisodes(subjectID: subjectID)
                var episodeIDs: [Int] = []
                for mark in marks {
                    if let ep = eps.first(where: { Int(($0.sort ?? 0).rounded()) == mark.episodeNumber }) {
                        episodeIDs.append(ep.id)
                    }
                    // else：条目里没有该集（永久性失败）——丢弃
                }
                if !episodeIDs.isEmpty {
                    try await client.markEpisodes(subjectID: subjectID, episodeIDs: episodeIDs, type: .watched)
                    syncedCount += episodeIDs.count
                }
                // 尊重 bgm.tv 频率限制
                try? await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                // 网络/权限仍失败：留在队列下次再试；永久性失败（404 等）丢弃，
                // 不再无限重试挤占容量
                if Self.isRetryableSyncError(error) {
                    remaining.append(contentsOf: marks)
                }
            }
        }
        // 冲刷期间可能又有新的记录入队（快照已过期）：合并写回，否则会把新记录覆盖丢失
        let fresh = Self.loadPendingWatchedMarks()
        var merged = remaining
        for mark in fresh where !merged.contains(where: { $0.subjectID == mark.subjectID && $0.episodeNumber == mark.episodeNumber }) {
            merged.append(mark)
        }
        Self.savePendingWatchedMarks(merged)
        if syncedCount > 0 {
            syncMessage = "已补同步 \(syncedCount) 条离线观看记录 ✓"
        }
    }

    /// 可同步时冲刷积压（联网恢复 / 登录成功 / 播放同步成功后调用）
    func flushPendingWatchedIfPossible() async {
        guard !Self.loadPendingWatchedMarks().isEmpty,
              let client = await bangumiClient() else { return }
        await flushPendingWatchedMarks(client: client)
    }

    // MARK: - 断点续播

    /// 记录最新播放位置（每个时间回调更新内存，落盘节流见 flushResume）
    private func trackResumePosition(_ time: Double) {
        guard pendingResume != nil else { return }
        pendingResume?.position = time
        pendingResume?.duration = duration
        if let target = pendingResumeTarget {
            // 引擎还没到续播点（起播瞬间 time-pos 先报 ~0），此时不落盘
            guard time >= target - 1 else { return }
            pendingResumeTarget = nil
        }
        flushResume(force: false)
    }

    /// 写入存储。非强制时距上次落盘不足 5s 跳过；续播目标未到达前一律跳过。
    private func flushResume(force: Bool) {
        guard let pending = pendingResume, pending.position > 0 else { return }
        if let target = pendingResumeTarget, pending.position < target - 1 { return }
        if !force, let last = lastResumeSaveAt, Date().timeIntervalSince(last) < 5 {
            return
        }
        lastResumeSaveAt = Date()
        resumeStore.update(path: pending.path, position: pending.position, duration: pending.duration)
    }

    /// 清除当前文件的续播记录（看完即清，下次从头播）
    private func clearResume() {
        if let pending = pendingResume {
            resumeStore.remove(path: pending.path)
        }
        pendingResume = nil
        pendingResumeTarget = nil
    }

    // MARK: - 继续观看（聚合入口用）

    struct ResumeItem {
        let key: String
        let position: Double
        let duration: Double
        let updatedAt: Date
    }

    /// 最近的可续播记录（按更新时间降序；已看完/开头几分钟的记录不算）
    func recentResumes(limit: Int) -> [ResumeItem] {
        resumeStore.snapshot().prefix(limit).compactMap { item in
            guard ResumePolicy.resumePosition(position: item.entry.position, duration: item.entry.duration) != nil else {
                return nil // 看完的/几乎没看的没有"继续"意义
            }
            return ResumeItem(key: item.key, position: item.entry.position,
                              duration: item.entry.duration, updatedAt: item.entry.updatedAt)
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
            syncMessage = "未登录 Bangumi，无法搜索（请先在「聊天」页登录）"
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
        names[media.seriesKey] = subject.displayName.isEmpty ? "未命名" : subject.displayName
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
            names[media.seriesKey] = subject.displayName.isEmpty ? "未命名" : subject.displayName
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

// 引擎保证 delegate 回调在主线程（见 PlaybackEngineDelegate 注释），
// 与 @MainActor 的 PlayerModel 匹配；@preconcurrency 告知编译器该契约
extension PlayerModel: @preconcurrency PlaybackEngineDelegate {
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double) {
        if !isSeeking {
            currentTime = time
            sliderValue = time
        }
        trackResumePosition(time)
        // 自然播放到阈值即标记看过（EOF 由 playbackEngineDidFinish 兜底）
        checkAutoMarkWatched()
        // 接近尾声时弹"看下一集"提示（征询式连播）
        checkNextEpisodeOffer()
    }

    func playbackEngine(_ engine: PlaybackEngine, didChangeState state: PlaybackState) {
        self.state = state
        if case .ready = state {
            // 引擎时长为 0 时不覆盖（duration 属性事件可能晚于 ready 送达，重载时
            // 否则会把上一文件的正确时长清成 0）；晚到的事件走 didUpdateDuration 修正
            applyDuration(engine.duration)
            syncTracks()
        }
        // 暂停/出错等状态切换频率低，强制落盘一次
        flushResume(force: true)
    }

    /// 时长就绪（ready 状态或引擎时长事件）：依赖时长的收尾逻辑收敛到这里。
    /// 加载期被暂停（切页自动暂停）时状态直接进 paused 跳过 ready，
    /// 全靠 didUpdateDuration 把时长补上，否则进度条量程一直是 0:00。
    private func applyDuration(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        duration = value
        pendingResume?.duration = value
        // 记录的续播点超出实际时长（文件被替换/记录损坏）→ 放弃闸门，正常记录
        if let target = pendingResumeTarget, target > value - 1 {
            pendingResumeTarget = nil
        }
    }

    func playbackEngine(_ engine: PlaybackEngine, didUpdateDuration value: Double) {
        applyDuration(value)
    }

    func playbackEngineDidFinish(_ engine: PlaybackEngine) {
        // 播完：清续播记录，下次从头开始
        clearResume()
        autoSyncOnFinish()
        // EOF 兜底：95% 没触发（短视频/跳过片尾）也弹"看下一集"提示
        // （不再自动切换——用户点"允许"才换，2026-09-27 改为征询式）
        nextOfferTriggered = true
        Task { await offerNextEpisodeIfAvailable() }
    }

    /// 手动切换线路：保留当前播放位置重载（播放中途画质/速度差时用）。
    /// 加载中禁止换线：引擎同时只挂一个 load 续接，重入会令首次加载的续接泄漏（永久转圈）。
    func switchRoute(to index: Int) {
        guard state == .playing || state == .paused || state == .ready else { return }
        guard let active = activeOnline, active.routes.indices.contains(index), index != routeIndex else { return }
        guard let target = URL(string: active.routes[index]) else { return }
        let resumeAt = max(currentTime, 0)
        Task { [weak self] in
            guard let self else { return }
            // 换线前把当前位置落盘；重载后从该位置继续（属用户操作，清起播闸门）
            flushResume(force: true)
            pendingResumeTarget = nil
            do {
                try await engine.load(url: target, options: PlaybackOptions(
                    startTime: resumeAt,
                    httpHeaders: active.httpHeaders,
                    userAgent: active.userAgent
                ))
                routeIndex = index
                syncMessage = "已切换到线路 \(index + 1)"
            } catch {
                syncMessage = "线路切换失败"
            }
        }
    }

    /// 播放中接近尾声（95%，与同步阈值一致）准备提示；每集只触发一次
    private func checkNextEpisodeOffer() {
        guard autoPlayNextEnabled, !nextOfferDismissed, nextEpisodeOffer == nil, !nextOfferTriggered else { return }
        guard state == .playing, duration > 0, currentTime / duration >= watchedRatio else { return }
        // seek/拖动后短时间内不触发，避免"拖到结尾"误弹
        if let lastSeek = lastSeekTime, Date().timeIntervalSince(lastSeek) < seekIgnoreWindow { return }
        nextOfferTriggered = true
        Task { await offerNextEpisodeIfAvailable() }
    }

    /// 解析下一集并弹出提示；解析不到（最后一集）自然不弹
    private func offerNextEpisodeIfAvailable() async {
        guard autoPlayNextEnabled, !nextOfferDismissed, nextEpisodeOffer == nil, !isResolvingNextOffer else { return }
        guard let context = autoNextContext, let resolver = nextEpisodeResolver else { return }
        isResolvingNextOffer = true
        defer { isResolvingNextOffer = false }
        // 在线源解析要发网络请求（可能数秒），返回后必须复核：期间用户可能已
        // 换集（autoNextContext 变化）或点了 ×，陈旧结果会把别的剧的下一集盖上来
        let next = await resolver(context)
        guard !Task.isCancelled, autoPlayNextEnabled, !nextOfferDismissed, nextEpisodeOffer == nil,
              autoNextContext == context else { return }
        guard let next else { return }
        nextEpisodeOffer = NextEpisodeOffer(playback: next)
    }

    /// 用户点"看下一集"：切换（与点播同一链路，绑定/续播/同步全部生效）
    func acceptNextEpisode() {
        guard let offer = nextEpisodeOffer else { return }
        nextEpisodeOffer = nil
        let next = offer.playback
        Task {
            if next.isLocal {
                await load(
                    url: next.url,
                    fromLibrary: true,
                    librarySubjectID: next.boundSubjectID,
                    librarySubject: next.boundSubject
                )
            } else {
                await load(
                    url: next.url,
                    librarySubjectID: next.boundSubjectID,
                    librarySubject: next.boundSubject,
                    displayTitle: next.displayTitle,
                    resumeKey: next.resumeKey,
                    mediaOverride: MediaOverride(
                        episodeNumber: next.episodeNumber,
                        seriesKey: next.seriesKey
                    ),
                    httpHeaders: next.httpHeaders,
                    userAgent: next.userAgent,
                    routes: next.routes,
                    showTitle: next.showTitle
                )
            }
        }
    }

    /// 用户点 ×：本集内不再弹（换集重置）
    func dismissNextEpisodeOffer() {
        nextEpisodeOffer = nil
        nextOfferDismissed = true
    }

    func playbackEngine(_ engine: PlaybackEngine, didFailWith error: Error) {}

    func playbackEngineDidUpdateTracks(_ engine: PlaybackEngine) {
        syncTracks()
    }
}

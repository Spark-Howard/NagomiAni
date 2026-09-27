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

/// 在线片源页的状态模型：
/// - 汇总各 Provider 的目录与跨站搜索，组装点播参数
/// - Bangumi 绑定与已看徽章（与 PlayerModel 共用同一张 UserDefaults 绑定表）
/// - 苹果CMS 资源站管理（仓库不内置任何站点，用户自行添加/移除）
@MainActor
final class OnlineStore: ObservableObject {
    @Published private(set) var shows: [OnlineShow] = []
    /// show.id → 集列表
    @Published private(set) var episodes: [String: [OnlineEpisode]] = [:]
    @Published var statusMessage: String?
    @Published private(set) var isLoadingShows = false
    @Published private(set) var isPreparing = false

    private(set) var providers: [SourceProvider] = []
    private var showsLoaded = false

    // MARK: - 资源站管理与跨站搜索

    static let sitesKey = "online.maccms.sites"

    /// 内置默认资源站（2026-09-27 应用户要求内置；均为 senfun.in 等聚合站实际引用的公开上游采集接口，已实测可用：
    /// 量子/极速/爱坤经 senfun 播放页 m3u8 域名反向确认，暴风为额外验证的大型通用站）。
    /// 用户不可移除内置源，但可继续自行添加；id 取域名进合成 seriesKey，勿改地址。
    struct DefaultSite {
        let name: String
        let base: String
    }

    static let defaultSites: [DefaultSite] = [
        DefaultSite(name: "量子资源", base: "https://cj.lziapi.com"),
        DefaultSite(name: "极速资源", base: "https://jszyapi.com"),
        DefaultSite(name: "爱坤资源", base: "https://ikunzyapi.com"),
        DefaultSite(name: "暴风资源", base: "https://bfzyapi.com"),
    ]

    /// 用户添加的苹果CMS 资源站（归一化 API 地址，UserDefaults 持久化）
    @Published private(set) var sites: [String] = []
    /// 非 nil 时列表切换为搜索结果（nil = 浏览默认目录）
    @Published private(set) var onlineSearchResults: [OnlineShow]?
    @Published private(set) var isSearchingOnline = false
    private var searchGeneration = 0

    init() {
        sites = UserDefaults.standard.stringArray(forKey: Self.sitesKey) ?? []
        rebuildProviders()
    }

    /// Mock 样例源永远保留（全链路演示/兜底），后接内置默认源与用户添加的资源站
    private func rebuildProviders() {
        var list: [SourceProvider] = [MockProvider()]
        let defaultProviders = Self.defaultSites.compactMap { site -> SourceProvider? in
            guard let provider = MacCMSProvider(base: site.base) else { return nil }
            return MacCMSProvider(apiBase: provider.apiBase, displayName: site.name)
        }
        list.append(contentsOf: defaultProviders)
        let defaultIDs = Set(defaultProviders.map(\.id))
        for site in sites {
            guard let provider = MacCMSProvider(base: site) else { continue }
            guard !defaultIDs.contains(provider.id) else { continue } // 与内置源重复的跳过
            list.append(provider)
        }
        providers = list
    }

    /// 添加用户自定义资源站（与内置源重复的地址会被拒绝）
    func addSite(_ raw: String) {
        guard let provider = MacCMSProvider(base: raw) else {
            statusMessage = "无法识别的站点地址：\(raw)"
            return
        }
        let normalized = provider.apiBase.absoluteString
        let defaultNormalized = Set(Self.defaultSites.compactMap { MacCMSProvider(base: $0.base)?.apiBase.absoluteString })
        if defaultNormalized.contains(normalized) {
            statusMessage = "该站点已内置为默认片源"
            return
        }
        if sites.contains(normalized) {
            statusMessage = "该站点已添加：\(provider.displayName)"
            return
        }
        sites.append(normalized)
        UserDefaults.standard.set(sites, forKey: Self.sitesKey)
        rebuildProviders()
        statusMessage = "已添加片源：\(provider.displayName)"
        Task { await reloadShows() }
    }

    func removeSite(_ raw: String) {
        sites.removeAll { $0 == raw }
        UserDefaults.standard.set(sites, forKey: Self.sitesKey)
        rebuildProviders()
        statusMessage = "已移除片源"
        Task { await reloadShows() }
    }

    private func reloadShows() async {
        showsLoaded = false
        onlineSearchResults = nil
        await loadShowsIfNeeded()
    }

    /// 跨站搜索：扇出到各 Provider（代际守卫防慢站结果覆盖新搜索）
    func searchOnline(_ keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            onlineSearchResults = nil
            return
        }
        isSearchingOnline = true
        defer { isSearchingOnline = false }
        searchGeneration += 1
        let generation = searchGeneration
        var results: [OnlineShow] = []
        for provider in providers {
            do {
                let found = try await provider.search(keyword: trimmed)
                guard generation == searchGeneration else { return } // 已被新搜索取代
                results.append(contentsOf: found)
                onlineSearchResults = results
            } catch {
                statusMessage = "\(provider.displayName) 搜索失败：\(error.localizedDescription)"
            }
        }
        if generation == searchGeneration, results.isEmpty {
            statusMessage = "没有找到「\(trimmed)」相关内容"
        }
    }

    func clearOnlineSearch() {
        searchGeneration += 1
        onlineSearchResults = nil
    }

    func providerName(for show: OnlineShow) -> String? {
        provider(id: show.providerID)?.displayName
    }

    // MARK: - Bangumi 绑定与已看徽章
    /// 合成 seriesKey（"online:<provider>:<showID>"）直通 PlayerModel 的 markWatched 自动同步
    /// subjectID → Subject（已关联条目的封面/名称展示）
    @Published private(set) var subjects: [Int: Subject] = [:]
    /// seriesKey → 已看集号集合（来自 Bangumi 我的单集收藏）
    @Published private(set) var watchedEpisodes: [String: Set<Int>] = [:]
    @Published private(set) var isLoadingWatched: Set<String> = []
    @Published var searchResults: [Subject] = []
    @Published var isSearching = false
    /// 当前绑定 sheet 的目标番（nil = 关闭）
    @Published var bindTarget: OnlineShow?

    // MARK: - 自动匹配候选（与番库同一套 BangumiMatcher 评分：相似度 + 集数佐证 + 季度判定）

    /// show.id → 自动匹配候选（nil = 还没算过；确认绑定后清空）
    @Published private(set) var bindCandidates: [String: [MatchCandidate]] = [:]
    @Published private(set) var isLoadingCandidates = false

    /// 为指定番计算自动匹配候选（打开绑定 sheet 时触发；有缓存不重复请求）
    func loadBindCandidates(for show: OnlineShow) async {
        if bindCandidates[show.id] != nil { return }
        guard !isLoadingCandidates else { return }
        isLoadingCandidates = true
        defer { isLoadingCandidates = false }
        guard let client = await BangumiSession.makeClient() else {
            statusMessage = "未登录 Bangumi，无法自动匹配（请先在「聊天」页登录）"
            return
        }
        // 集数佐证用片源分集数（列表还没加载过就先拉一次）
        var episodeCount: Int? = episodes[show.id]?.count
        if episodeCount == nil {
            await ensureEpisodes(for: show)
            episodeCount = episodes[show.id]?.count
        }
        // 季号与番库同源：从标题识别（"第二季"/"S2" 等）
        let season = MediaMatching.seasonNumber(from: show.title)
        do {
            let matcher = BangumiMatcher(client: client)
            bindCandidates[show.id] = try await matcher.candidates(
                title: show.title,
                episodeCount: episodeCount,
                season: season,
                limit: 5
            )
        } catch {
            statusMessage = "自动匹配失败：\(error.localizedDescription)"
        }
    }

    func binding(for seriesKey: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: PlayerModel.bindingsKey) as? [String: Int])?[seriesKey]
    }

    func bind(subject: Subject, to show: OnlineShow) {
        let seriesKey = show.seriesKey
        var ids = UserDefaults.standard.dictionary(forKey: PlayerModel.bindingsKey) as? [String: Int] ?? [:]
        var names = UserDefaults.standard.dictionary(forKey: PlayerModel.boundNamesKey) as? [String: String] ?? [:]
        ids[seriesKey] = subject.id
        names[seriesKey] = subject.displayName.isEmpty ? "未命名" : subject.displayName
        UserDefaults.standard.set(ids, forKey: PlayerModel.bindingsKey)
        UserDefaults.standard.set(names, forKey: PlayerModel.boundNamesKey)
        subjects[subject.id] = subject
        bindTarget = nil
        // 已关联不再显示"建议 N"，之后点"更换"会重新匹配（与番库同规则）
        bindCandidates[show.id] = nil
        statusMessage = "已关联「\(names[seriesKey] ?? "")」，本系列播完自动同步"
        Task { await refreshWatched(for: show) }
    }

    func unbind(for show: OnlineShow) {
        let seriesKey = show.seriesKey
        var ids = UserDefaults.standard.dictionary(forKey: PlayerModel.bindingsKey) as? [String: Int] ?? [:]
        var names = UserDefaults.standard.dictionary(forKey: PlayerModel.boundNamesKey) as? [String: String] ?? [:]
        ids.removeValue(forKey: seriesKey)
        names.removeValue(forKey: seriesKey)
        UserDefaults.standard.set(ids, forKey: PlayerModel.bindingsKey)
        UserDefaults.standard.set(names, forKey: PlayerModel.boundNamesKey)
        watchedEpisodes[seriesKey] = nil
        statusMessage = "已解除关联"
    }

    /// 绑定 sheet 的 Bangumi 条目搜索
    func search(keyword: String) async {
        guard let client = await BangumiSession.makeClient() else {
            statusMessage = "未登录 Bangumi，无法搜索（请先在「聊天」页登录）"
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await client.searchSubjects(keyword: keyword, limit: 20).data
        } catch {
            searchResults = []
            statusMessage = "搜索失败：\(error.localizedDescription)"
        }
    }

    /// 已关联条目的封面/名称（未缓存时静默补拉）
    func ensureSubject(for show: OnlineShow) async {
        guard let id = binding(for: show.seriesKey), subjects[id] == nil else { return }
        guard let client = await BangumiSession.makeClient() else { return }
        if let subject = try? await client.subject(id: id) {
            subjects[id] = subject
        }
    }

    /// 拉取该系列的已看集号（Bangumi 我的单集收藏；未登录/失败静默跳过）
    func refreshWatched(for show: OnlineShow) async {
        guard let id = binding(for: show.seriesKey) else { return }
        guard !isLoadingWatched.contains(show.id) else { return }
        isLoadingWatched.insert(show.id)
        defer { isLoadingWatched.remove(show.id) }
        guard let client = await BangumiSession.makeClient() else { return }
        do {
            let page = try await client.myEpisodeCollections(subjectID: id)
            var watched = Set<Int>()
            for item in page.data where item.type == .watched {
                if let sort = item.episode?.sort {
                    watched.insert(Int(sort.rounded()))
                }
            }
            watchedEpisodes[show.seriesKey] = watched
        } catch {
            // 徽章拉取失败不影响播放，静默降级
        }
    }

    func isWatched(_ episode: OnlineEpisode) -> Bool {
        watchedEpisodes[episode.seriesKey]?.contains(episode.number) == true
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

    /// 取流 URL 并组装播放参数。已绑定的番带上 Bangumi 条目，
    /// PlayerModel 经 bindLocal 复用绑定保证播完自动同步。
    func preparePlayback(show: OnlineShow, episode: OnlineEpisode) async throws -> OnlinePlayback {
        guard let provider = provider(id: episode.providerID) else {
            throw OnlineStoreError.unknownProvider
        }
        isPreparing = true
        defer { isPreparing = false }
        statusMessage = "正在准备「\(show.title) 第 \(episode.number) 集」的片源…"
        let source = try await provider.streamURL(for: episode)
        statusMessage = nil
        // 已整体缓存的集直接播本地副本（HLS 为重写的本地 playlist）
        let playURL = cache.cachedMediaURL(for: episode.resumeKey) ?? source.url
        let boundID = binding(for: episode.seriesKey)
        return OnlinePlayback(
            url: playURL,
            displayTitle: Self.displayTitle(show: show, episode: episode),
            seriesKey: episode.seriesKey,
            episodeNumber: episode.number,
            resumeKey: episode.resumeKey,
            httpHeaders: source.httpHeaders,
            userAgent: source.userAgent,
            boundSubjectID: boundID,
            boundSubject: boundID.flatMap { subjects[$0] }
        )
    }

    private func provider(id: String) -> SourceProvider? {
        providers.first { $0.id == id }
    }

    /// 播放器顶部/窗口标题统一显示的标题
    static func displayTitle(show: OnlineShow, episode: OnlineEpisode) -> String {
        "\(show.title) · 第 \(episode.number) 集"
    }

    // MARK: - 本地缓存（StreamCache：HLS 分片 / 单文件）

    private let cache = StreamCache()
    /// 已完整缓存的 resumeKey 集合
    @Published private(set) var cachedKeys: Set<String> = []
    /// 下载中的 resumeKey → 进度（含字节级：已下载/总大小，总大小可能未知）
    @Published private(set) var cacheProgress: [String: StreamCache.Progress] = [:]
    /// 已缓存条目的磁盘占用（resumeKey → 字节）
    @Published private(set) var cacheSizes: [String: Int64] = [:]
    /// 缓存总字节数
    @Published private(set) var cacheTotalBytes: Int64 = 0
    private var cacheTasks: [String: Task<Void, Never>] = [:]

    enum CacheState: Equatable {
        case notCached
        case downloading(StreamCache.Progress)
        case cached
    }

    func cacheState(for episode: OnlineEpisode) -> CacheState {
        if let progress = cacheProgress[episode.resumeKey] {
            return .downloading(progress)
        }
        if cachedKeys.contains(episode.resumeKey) {
            return .cached
        }
        return .notCached
    }

    /// 已缓存条目的磁盘占用
    func cacheSize(for episode: OnlineEpisode) -> Int64? {
        cacheSizes[episode.resumeKey]
    }

    /// 启动时恢复缓存状态展示
    func refreshCacheState() {
        cachedKeys = cache.cachedKeys()
        cacheTotalBytes = cache.totalBytes()
        var sizes: [String: Int64] = [:]
        for key in cachedKeys {
            if let size = cache.sizeBytes(for: key) {
                sizes[key] = size
            }
        }
        cacheSizes = sizes
    }

    /// 手动缓存一集（HLS 走分片下载 + 本地 playlist；渐进式走整文件流式落盘）
    func startCache(show: OnlineShow, episode: OnlineEpisode) {
        let key = episode.resumeKey
        guard cacheTasks[key] == nil, !cachedKeys.contains(key) else { return }
        guard let provider = provider(id: episode.providerID) else { return }
        let cache = cache
        cacheProgress[key] = StreamCache.Progress(downloadedSegments: 0, totalSegments: 0)
        let task = Task {
            defer { cacheTasks[key] = nil }
            do {
                let source = try await provider.streamURL(for: episode)
                let progressHandler: @Sendable (StreamCache.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.cacheProgress[key] = progress
                    }
                }
                if source.isHLS {
                    _ = try await cache.download(
                        playlistURL: source.url,
                        httpHeaders: source.httpHeaders,
                        userAgent: source.userAgent,
                        cacheKey: key,
                        progress: progressHandler
                    )
                } else {
                    _ = try await cache.downloadFile(
                        url: source.url,
                        httpHeaders: source.httpHeaders,
                        userAgent: source.userAgent,
                        cacheKey: key,
                        progress: progressHandler
                    )
                }
                cachedKeys.insert(key)
                cacheProgress[key] = nil
                cacheSizes[key] = cache.sizeBytes(for: key)
                cacheTotalBytes = cache.totalBytes()
                statusMessage = "已缓存「\(show.title) 第 \(episode.number) 集」"
            } catch is CancellationError {
                cacheProgress[key] = nil
            } catch {
                cacheProgress[key] = nil
                statusMessage = "缓存失败：\(error.localizedDescription)"
            }
        }
        cacheTasks[key] = task
    }

    func cancelCache(for episode: OnlineEpisode) {
        cacheTasks[episode.resumeKey]?.cancel()
    }

    func removeCache(for episode: OnlineEpisode) {
        cache.purge(cacheKey: episode.resumeKey)
        cachedKeys.remove(episode.resumeKey)
        cacheSizes[episode.resumeKey] = nil
        cacheTotalBytes = cache.totalBytes()
    }

    func clearAllCache() {
        cache.purgeAll()
        cachedKeys.removeAll()
        cacheSizes.removeAll()
        cacheTotalBytes = 0
        statusMessage = "已清除全部缓存"
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 进度条下的尺寸文本："12.3 MB / 45.6 MB"；总大小未知时只显示已下载
    static func progressBytesLabel(_ progress: StreamCache.Progress) -> String {
        let downloaded = formattedBytes(progress.downloadedBytes)
        if let total = progress.totalBytes {
            return "\(downloaded) / \(formattedBytes(total))"
        }
        return downloaded
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

import Foundation
import NagomiAniCore

/// 弹幕拉取与状态管理（PlayerModel 持有；渲染走独立悬浮层，与字幕共存互不影响）。
@MainActor
final class DanmakuController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case unconfigured
        case matching
        case loading
        case loaded(count: Int)
        case failed(String)
    }

    /// 弹幕匹配上下文（换集时以此判断是否同一集）
    struct Context: Equatable {
        enum Kind: Equatable {
            /// 在线番：按剧名 + 集号在弹弹play 搜索剧集
            case online(showTitle: String, episodeNumber: Int)
            /// 本地番：按文件名 + 头 16MB MD5 指纹匹配
            case local(url: URL)
        }
        let key: String // resumeKey（缓存/去重）
        let kind: Kind
    }

    /// 弹幕显示开关（默认开；关闭即隐藏悬浮层并停止拉取）
    @Published var isEnabled: Bool =
        UserDefaults.standard.object(forKey: "player.danmakuEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "player.danmakuEnabled")
            if isEnabled, let context = currentContext {
                prepare(context)
            } else if !isEnabled {
                // 取消在途拉取，避免"关闭后加载完成又出现弹幕"
                prepareTask?.cancel()
                prepareTask = nil
                clearTrack()
            }
        }
    }
    @Published private(set) var phase: Phase = .idle
    /// 当前集的弹幕（已按时间排序，车道分配由覆盖层按画面尺寸计算）
    @Published private(set) var comments: [DanmakuComment] = []

    static let appIdKey = "danmaku.appId"
    static let appSecretKey = "danmaku.appSecret"
    /// 弹幕 API 服务器地址（默认官方 api.dandanplay.net；第三方兼容服务可改）
    static let baseURLKey = "danmaku.baseURL"

    var baseURLText: String {
        let stored = UserDefaults.standard.string(forKey: Self.baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? "https://api.dandanplay.net" : stored
    }

    private var currentContext: Context?
    private var currentKey: String?
    private var commentsCache: [String: [DanmakuComment]] = [:] // key → 已拉取弹幕（同集切回不重复请求）
    private var prepareTask: Task<Void, Never>?
    /// commentsCache 上限（弹幕体积大，防止连看几十集后无界增长）
    private static let cacheLimit = 10

    func credentials() -> DanmakuCredentials {
        // 优先级：UserDefaults 显式配置（高级用户/开发机逃生口）→ 应用内置（打包版注入）
        let stored = DanmakuCredentials(
            appId: UserDefaults.standard.string(forKey: Self.appIdKey) ?? "",
            appSecret: UserDefaults.standard.string(forKey: Self.appSecretKey) ?? ""
        )
        if stored.isConfigured { return stored }
        return DanmakuEmbeddedCredentials.load() ?? DanmakuCredentials(appId: "", appSecret: "")
    }

    var isConfigured: Bool { credentials().isConfigured }

    // MARK: - 显示设置（弹幕设置面板；UserDefaults 持久化，改动即时生效）

    /// 弹幕颜色模式：跟随弹幕自带颜色 / 全部纯白 / 统一自定义色
    enum DanmakuColorMode: String, CaseIterable, Identifiable {
        case original, white, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "跟随弹幕颜色"
            case .white: return "全部纯白"
            case .custom: return "自定义颜色"
            }
        }
    }

    @Published var fontSize: CGFloat =
        { let v = UserDefaults.standard.double(forKey: "danmaku.fontSize"); return v > 0 ? CGFloat(v) : 22 }()
    { didSet { UserDefaults.standard.set(Double(fontSize), forKey: "danmaku.fontSize") } }

    @Published var colorMode: DanmakuColorMode =
        DanmakuColorMode(rawValue: UserDefaults.standard.string(forKey: "danmaku.colorMode") ?? "") ?? .original
    { didSet { UserDefaults.standard.set(colorMode.rawValue, forKey: "danmaku.colorMode") } }

    /// 自定义颜色（0xRRGGBB）
    @Published var customColor: UInt32 =
        { let v = UserDefaults.standard.integer(forKey: "danmaku.customColor"); return v > 0 ? UInt32(v) : 0xEC6A88 }()
    { didSet { UserDefaults.standard.set(Int(customColor), forKey: "danmaku.customColor") } }

    @Published var opacity: Double =
        { let v = UserDefaults.standard.double(forKey: "danmaku.opacity"); return v > 0 ? v : 1.0 }()
    { didSet { UserDefaults.standard.set(opacity, forKey: "danmaku.opacity") } }

    /// seek 重摆信号：用户拖进度/换集时 +1，弹幕层据此重摆动画时间线
    /// （引擎 time-pos 事件频率不稳定，不能用"时间跳变"推断 seek）
    @Published private(set) var seekRevision = 0
    func markSeeked() { seekRevision += 1 }

    /// 当前状态的人类可读描述（控制条菜单与设置面板共用）
    var statusDescription: String {
        switch phase {
        case .idle: return "未加载弹幕"
        case .unconfigured: return "弹幕服务未就绪"
        case .matching: return "正在匹配剧集…"
        case .loading: return "正在拉取弹幕…"
        case .loaded(let count): return "已加载 \(count) 条弹幕"
        case .failed(let message): return "失败：\(message)"
        }
    }

    /// 换集/首次加载成功后调用（同步、立即返回；拉取在内部 Task 进行）。
    /// 内部判断开关、凭据、同集去重。
    func prepare(_ context: Context) {
        prepareTask?.cancel()
        currentContext = context
        guard isEnabled else {
            clearTrack()
            return
        }
        if currentKey == context.key, case .loaded = phase { return } // 同集已加载
        clearTrack()
        currentKey = context.key
        guard credentials().isConfigured else {
            phase = .unconfigured
            return
        }
        if let cached = commentsCache[context.key] {
            apply(comments: cached)
            return
        }
        if commentsCache.count >= Self.cacheLimit, let evict = commentsCache.keys.first(where: { $0 != context.key }) {
            commentsCache.removeValue(forKey: evict)
        }
        phase = .matching
        prepareTask = Task { [weak self] in
            await self?.runPrepare(context)
        }
    }

    /// 手动重新获取当前集弹幕（忽略内存缓存；清 currentKey 绕过同集 guard，否则 prepare 会直接返回）
    func refetch() {
        guard let context = currentContext else { return }
        commentsCache.removeValue(forKey: context.key)
        currentKey = nil
        prepare(context)
    }

    private func clearTrack() {
        comments = []
        phase = .idle
    }

    private func apply(comments: [DanmakuComment]) {
        self.comments = comments
        phase = .loaded(count: comments.count)
    }

    private func runPrepare(_ context: Context) async {
        let client = DandanplayClient(credentials: credentials(), baseURL: baseURLText)
        do {
            let episodeId: Int
            switch context.kind {
            case .online(let showTitle, let episodeNumber):
                let episodes = try await client.searchEpisodes(anime: showTitle)
                guard !Task.isCancelled, currentContext == context else { return }
                guard let info = Self.pickEpisode(from: episodes, showTitle: showTitle, episodeNumber: episodeNumber) else {
                    phase = .failed("弹幕库未找到对应剧集")
                    return
                }
                episodeId = info.episodeId
            case .local(let url):
                // 16MB 读盘 + MD5 可能耗时（NAS 卷可达秒级），放到后台线程避免卡主线程
                let hash = try await Task.detached(priority: .utility) {
                    try DandanplayClient.fileHash(url: url)
                }.value
                guard !Task.isCancelled, currentContext == context else { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                let info = try await client.match(fileName: url.lastPathComponent, fileHash: hash, fileSize: size)
                guard !Task.isCancelled, currentContext == context else { return }
                episodeId = info.episodeId
            }
            phase = .loading
            let comments = try await client.comments(episodeId: episodeId)
            guard !Task.isCancelled, currentContext == context else { return }
            commentsCache[context.key] = comments
            apply(comments: comments)
        } catch is CancellationError {
            // 换集/关闭：静默
        } catch DanmakuError.notConfigured {
            guard currentContext == context else { return }
            phase = .unconfigured
        } catch {
            guard !Task.isCancelled, currentContext == context else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// 从剧集列表里挑出对应集：番名相近者优先，集标题解析出的集号必须一致
    /// （防同名番/剧场版/特别篇干扰）；找不到一致集号的返回 nil（宁可无弹幕不挂错）
    static func pickEpisode(
        from episodes: [DanmakuEpisodeInfo], showTitle: String, episodeNumber: Int
    ) -> DanmakuEpisodeInfo? {
        let pool = episodes.filter {
            TitleSimilarity.similarity(showTitle, $0.animeTitle) >= 0.35
                || $0.animeTitle.contains(showTitle) || showTitle.contains($0.animeTitle)
        }
        guard !pool.isEmpty else { return nil }
        let numbered = pool.filter {
            MediaMatching.episodeNumber(from: $0.episodeTitle) == episodeNumber
        }
        if numbered.isEmpty { return nil }
        return numbered.max {
            TitleSimilarity.similarity(showTitle, $0.animeTitle)
                < TitleSimilarity.similarity(showTitle, $1.animeTitle)
        }
    }
}

import Foundation
import NagomiAniCore

/// Bangumi 账号与收藏的 UI 状态模型
///
/// 收藏列表（想看/看过/在看/搁置/抛弃）按类型做**内存缓存 + 后台刷新**：
/// 切换类型时先用缓存立刻出内容，再在后台请求最新列表；只有内容真的变了
/// 才更新界面，避免闪烁。同类型重复切换会被去重，不会重复打接口。
@MainActor
final class AccountViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var user: BangumiUser?
    @Published var collections: [UserSubjectCollection] = []
    @Published var isLoading = false
    /// 后台静默刷新中（已有缓存内容时用它显示细进度条，不遮挡列表）
    @Published var isRefreshingInBackground = false
    @Published var errorMessage: String?
    /// 当前类型的缓存写入时间（用于界面显示"更新于 …"）
    @Published var lastUpdated: Date?
    /// 正在同步的条目 ID（预留）
    @Published var collectionType: SubjectCollectionType = .doing {
        didSet {
            guard oldValue != collectionType, isLoggedIn else { return }
            showCachedOrLoad()
        }
    }

    private let client = BangumiClient()
    private var auth: BangumiAuth?
    private var sync: HistorySyncService?

    // MARK: - 缓存

    /// 收藏列表缓存（按类型分页 + 条目详情跨类型共享）
    private var cache = CollectionCache(ttl: 300)
    /// 同类型并发去重：切换过快时复用同一次请求
    private var inFlight: [SubjectCollectionType: Task<[UserSubjectCollection], Error>] = [:]
    /// 正在后台补全详情的类型（避免同类型重复补全）
    private var enriching: Set<SubjectCollectionType> = []

    init() {
        setupAuth()
        if auth?.isLoggedIn == true {
            Task { await refresh() }
        }
    }

    // MARK: - 动作

    func login() async {
        // 凭证已内置在应用里（BangumiCredentials）——开发者注册一次、所有用户共用，
        // 用户只需在浏览器里用自己的账号授权，无需填写 App ID/Secret
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let auth else { return }
            try await auth.login()
            client.accessToken = auth.accessToken
            await refresh()
        } catch BangumiError.loginCancelled {
            // 用户主动取消：静默退出，不当作错误展示
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    /// 在 App 内嵌网页（与聊天共享同一 Cookie 存储）里完成授权登录：
    /// 授权页加载交给 loadURL 处理；登录成功后网页会话 Cookie 与聊天互通
    func loginInEmbeddedWebview(loadURL: @escaping (URL) -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let auth else { return }
            try await auth.login(openURL: loadURL)
            client.accessToken = auth.accessToken
            await refresh()
        } catch BangumiError.loginCancelled {
            // 用户主动取消：静默退出，不当作错误展示
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func logout() {
        auth?.logout()
        client.accessToken = nil
        user = nil
        collections = []
        isLoggedIn = false
        // 丢弃在途请求：不取消的话结果回来后会把旧账号数据写回刚清空的缓存
        for (_, task) in inFlight { task.cancel() }
        inFlight.removeAll()
        clearCache()
    }

    /// 用户在浏览器授权页放弃/关页后点「取消登录」：让等待中的登录流程立刻返回
    func cancelLogin() {
        auth?.cancelLogin()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let auth else { return }
            try await auth.refreshIfNeeded()
            client.accessToken = auth.accessToken

            let me = try await client.currentUser()
            // 换了账号就不能复用旧账号的缓存
            if let previous = user, previous.id != me.id {
                clearCache()
            }
            user = me
            isLoggedIn = true
            await loadCollections(force: true)
        } catch {
            if case BangumiError.unauthorized = error {
                auth?.logout()
                client.accessToken = nil
                isLoggedIn = false
                user = nil
                collections = []
                clearCache()
            }
            errorMessage = Self.describe(error)
        }
    }

    /// 切换收藏类型时调用：有缓存就立刻显示，再按需后台刷新
    func showCachedOrLoad() {
        guard isLoggedIn else { return }

        if let page = cache.page(for: collectionType) {
            // 秒开：先用缓存内容（含已补全的详情）
            collections = page.enriched
            lastUpdated = page.updatedAt
            errorMessage = nil

            // 缓存够新就到此为止；过期则静默刷新，看看有没有新改动
            guard cache.needsRefresh(collectionType) else { return }
            Task { await loadCollections(force: true, silent: true) }
        } else {
            // 该类型还没缓存过
            collections = []
            lastUpdated = nil
            Task { await loadCollections(force: true) }
        }
    }

    /// 主动刷新当前类型（点刷新按钮）
    func refreshCollections() async {
        await loadCollections(force: true)
    }

    /// 拉取指定收藏类型（默认当前类型）；有缓存且未过期时直接返回
    func loadCollections(force: Bool = false, silent: Bool = false) async {
        guard let user else { return }
        let type = collectionType

        // 新鲜缓存直接命中
        if !force, let page = cache.page(for: type), cache.isFresh(type) {
            collections = page.enriched
            lastUpdated = page.updatedAt
            return
        }

        if silent {
            isRefreshingInBackground = true
        } else {
            // 已有内容时不打断（避免清空列表造成闪烁）
            isLoading = collections.isEmpty
        }
        errorMessage = nil
        defer {
            if silent { isRefreshingInBackground = false }
            if !silent { isLoading = false }
        }

        do {
            let list = try await fetchCollections(username: user.username, type: type)

            // 请求期间登出/换账号：结果作废（否则旧账号数据会写回已清空的缓存，
            // 换号登录后还会被当作缓存"秒开"）。user 是请求开始时的快照。
            guard isLoggedIn, let currentUser = self.user, currentUser.username == user.username else { return }

            // 列表已拿到：先用条目缓存补全详情，立刻出内容，再后台补缺的
            let merged = cache.enrich(list)
            let hasCache = cache.page(for: type) != nil
            let changed = !(cache.page(for: type).map { CollectionCache.isEquivalent(merged, $0.raw) } ?? false)

            cache.store(merged, for: type)

            if type == collectionType {
                // 内容没变就不动界面，避免无谓的重绘闪烁
                if changed || !hasCache {
                    collections = merged
                }
                lastUpdated = cache.page(for: type)?.updatedAt
            }

            // 后台补全仍缺详情的条目（有上限 + 节流）
            let missingIDs = cache.missingSubjectIDs(in: merged)
            if !missingIDs.isEmpty, !enriching.contains(type) {
                Task { await enrichMissingDetails(type: type, ids: missingIDs) }
            }
        } catch {
            // 静默刷新失败：保留缓存内容，只在界面提示
            if type == collectionType {
                errorMessage = Self.describe(error)
            }
        }
    }

    // MARK: - 私有

    /// 请求列表，同类型并发去重；按 offset 翻页拉全量
    ///（只拉第一页 100 条的话，收藏超过 100 的用户第 101 条起永远看不到）
    private func fetchCollections(
        username: String,
        type: SubjectCollectionType
    ) async throws -> [UserSubjectCollection] {
        // 同一类型已有请求在飞：直接复用，避免快速来回切换时重复打接口
        if let existing = inFlight[type] {
            return try await existing.value
        }

        let clientRef = client
        let task = Task<[UserSubjectCollection], Error> {
            var all: [UserSubjectCollection] = []
            var offset = 0
            let pageSize = 100
            while true {
                let page = try await clientRef.collections(
                    username: username, type: type, limit: pageSize, offset: offset
                )
                all.append(contentsOf: page.data)
                // 本页不满（或为空）= 到末页；total 只是参考（个别响应缺失时不依赖它）
                if page.data.count < pageSize { break }
                if let total = page.total, all.count >= total { break }
                offset += pageSize
                // 尊重 bgm.tv 频率限制
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return all
        }
        inFlight[type] = task
        defer { inFlight[type] = nil }

        return try await task.value
    }

    /// 后台补全条目详情：写入全局缓存后，再把当前类型的列表刷新一次
    private func enrichMissingDetails(type: SubjectCollectionType, ids: [Int]) async {
        enriching.insert(type)
        defer { enriching.remove(type) }

        var didFetch = false
        for id in ids {
            if let subject = try? await client.subject(id: id) {
                cache.remember(subject)
                didFetch = true
            }
            // 节流，尊重 bgm.tv 频率限制
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard didFetch else { return }

        // 用新拿到的详情回填所有已缓存类型与界面，不再打列表接口
        cache.reEnrichAll()
        if type == collectionType, let page = cache.page(for: type) {
            collections = page.enriched
        }
    }

    /// 局部失效：某条目被改动后，清掉涉及类型的缓存，下次进入会重新拉取
    func invalidateCollections(for types: SubjectCollectionType...) {
        for type in types { cache.invalidate(type) }
    }

    /// 记录刚拉到的条目详情，供其它类型复用
    func cacheSubject(_ subject: Subject) {
        cache.remember(subject)
    }

    private func clearCache() {
        cache.removeAll()
        lastUpdated = nil
    }

    private func setupAuth() {
        let newAuth = BangumiAuth(config: BangumiCredentials.config)
        auth = newAuth
        client.accessToken = newAuth.accessToken
        sync = HistorySyncService(client: client)
        isLoggedIn = newAuth.isLoggedIn
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

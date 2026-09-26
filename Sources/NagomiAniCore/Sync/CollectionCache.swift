import Foundation

/// 收藏列表缓存（按收藏类型分别缓存）。
///
/// 设计目标：从「想看」切到「看过」这类操作**先用缓存秒开**，再在后台核对
/// 是否有新改动。因此缓存不直接暴露可变的内部字典，而是提供三件明确的事：
///
/// 1. `page(for:)` —— 有缓存就直接拿（含是否过期）
/// 2. `enrich(_:)` —— 用跨类型共享的条目详情缓存补全名称/封面，**不打网络**
/// 3. `store(_:for:at:)` —— 接口返回后写回
///
/// 条目详情按 `subjectID` 共享：同一部番会同时出现在「在看」和「看过」，
/// 切类型时不必重复拉取详情。
public struct CollectionCache: Sendable {

    /// 单个收藏类型的缓存页
    public struct Page: Sendable {
        /// 接口返回的原始列表
        public let raw: [UserSubjectCollection]
        /// 已用条目缓存补全过详情的列表（用于秒开）
        public let enriched: [UserSubjectCollection]
        /// 写入时间
        public let updatedAt: Date

        public init(raw: [UserSubjectCollection], enriched: [UserSubjectCollection], updatedAt: Date) {
            self.raw = raw
            self.enriched = enriched
            self.updatedAt = updatedAt
        }
    }

    /// 缓存新鲜期：超过则切回来时也要在后台重新核对
    public let ttl: TimeInterval

    private var pages: [SubjectCollectionType: Page] = [:]
    private var subjects: [Int: Subject] = [:]

    public init(ttl: TimeInterval = 300) {
        self.ttl = ttl
    }

    // MARK: - 读

    /// 取某类型的缓存页
    public func page(for type: SubjectCollectionType) -> Page? {
        pages[type]
    }

    /// 缓存是否存在且仍在新鲜期内
    public func isFresh(_ type: SubjectCollectionType, now: Date = Date()) -> Bool {
        guard let page = pages[type] else { return false }
        return now.timeIntervalSince(page.updatedAt) <= ttl
    }

    /// 是否需要发起刷新：没有缓存，或缓存已过期
    public func needsRefresh(_ type: SubjectCollectionType, now: Date = Date()) -> Bool {
        !isFresh(type, now: now)
    }

    // MARK: - 写

    /// 用条目详情缓存补全列表中缺失的 subject（纯本地计算，无网络请求）
    public func enrich(_ list: [UserSubjectCollection]) -> [UserSubjectCollection] {
        list.map { collection in
            guard collection.subject == nil, let cached = subjects[collection.subjectID] else {
                return collection
            }
            return UserSubjectCollection(collection: collection, subject: cached)
        }
    }

    /// 写入某类型的缓存（自动补全详情）
    public mutating func store(
        _ list: [UserSubjectCollection],
        for type: SubjectCollectionType,
        at date: Date = Date()
    ) {
        pages[type] = Page(raw: list, enriched: enrich(list), updatedAt: date)
    }

    /// 记录条目详情，供所有类型复用
    public mutating func remember(_ subject: Subject) {
        subjects[subject.id] = subject
    }

    /// 需要补条目详情的 id：只补**完全没有 subject** 的条目（名称/封面都缺）。
    ///
    /// 注意**不要**为了 `total_episodes` 去补：收藏列表接口虽然不带该字段，
    /// 但带了等价的 `eps`，`Subject.episodeCount` 已做回退，显示集数无需额外请求。
    /// 每条详情都要单独请求且需节流，为省几个集数数字打几十个请求不划算。
    ///
    /// 带 `limit` 是为了控制请求量，尊重 bgm.tv 的频率限制。
    public func missingSubjectIDs(in list: [UserSubjectCollection], limit: Int = 30) -> [Int] {
        Array(list.filter { $0.subject == nil }.map(\.subjectID).prefix(limit))
    }

    /// 用最新已知详情重新补全所有已缓存类型（后台补完详情后调用）
    public mutating func reEnrichAll() {
        for (type, page) in pages {
            pages[type] = Page(raw: page.raw, enriched: enrich(page.raw), updatedAt: page.updatedAt)
        }
    }

    /// 局部失效：条目被改动后清掉涉及类型，下次进入会重新拉取
    public mutating func invalidate(_ types: SubjectCollectionType...) {
        for type in types {
            pages[type] = nil
        }
    }

    public mutating func removeAll() {
        pages.removeAll()
        subjects.removeAll()
    }

    // MARK: - 比较

    /// 两份列表是否等价：只看会显示在列表上的字段（条目 / 收藏状态 / 进度），
    /// 用来判断后台刷新后是否**真的**有变化，没变就不刷新界面、避免闪烁。
    public static func isEquivalent(
        _ lhs: [UserSubjectCollection],
        _ rhs: [UserSubjectCollection]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.subjectID != b.subjectID { return false }
            if a.type != b.type { return false }
            if a.epStatus != b.epStatus { return false }
        }
        return true
    }
}

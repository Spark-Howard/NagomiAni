import Foundation
import SwiftUI
import NagomiAniCore

/// 浏览/搜索页面的状态模型：搜索词条 → 查看 Bangumi 剧目详情
@MainActor
final class SearchViewModel: ObservableObject {
    @Published var keyword = ""
    @Published var results: [Subject] = []
    @Published var isSearching = false
    @Published var searchMessage: String?

    /// 当前正在查看的条目（nil = 停留在搜索列表）
    @Published var selected: Subject?
    /// 详情：v0 基础信息 + 旧版大条目（集数/讨论/评论/角色/制作）
    @Published var detailSubject: Subject?
    @Published var detailLarge: LegacySubject?
    @Published var isLoadingDetail = false
    @Published var detailError: String?

    /// 是否已登录（登录后才显示/修改收藏状态）
    @Published var isLoggedIn = false
    /// 我的收藏映射：subjectID → 收藏类型（搜索/详情显示状态用）
    @Published var collections: [Int: SubjectCollectionType] = [:]
    @Published var collectionMessage: String?

    private var client: BangumiClient?

    init() {
        Task { await prepareClient() }
    }

    /// 重新初始化客户端并刷新收藏（登录状态可能变化，进入页面时调用）
    func refresh() {
        Task {
            await prepareClient()
            await loadMyCollections()
        }
    }

    private func prepareClient() async {
        // 登录过则用带令牌的客户端（收藏接口需要登录）
        client = await BangumiSession.makeClient()
        isLoggedIn = client != nil
        if client == nil {
            client = BangumiClient()
        }
    }

    // MARK: - 收藏

    /// 拉取我的全部收藏（翻页，建立 subjectID → 类型 映射）
    func loadMyCollections() async {
        guard let client, isLoggedIn else { return }
        do {
            let me = try await client.currentUser()
            var offset = 0
            let pageSize = 100
            while true {
                let page = try await client.collections(
                    username: me.username, subjectType: nil, type: nil,
                    limit: pageSize, offset: offset
                )
                for item in page.data where item.subjectID != 0 {
                    if let type = item.type, type != .unknown {
                        collections[item.subjectID] = type
                    }
                }
                offset += pageSize
                if offset >= (page.total ?? 0) || page.data.count < pageSize { break }
            }
        } catch {
            // 收藏拉取失败不阻塞搜索（仅影响状态显示）
        }
    }

    /// 某条目我的收藏状态（未收藏返回 nil）
    func collectionType(for subjectID: Int) -> SubjectCollectionType? {
        collections[subjectID]
    }

    /// 修改收藏状态并同步到 Bangumi
    func setCollection(subjectID: Int, type: SubjectCollectionType) {
        Task {
            collectionMessage = nil
            do {
                guard let client else {
                    collectionMessage = "未登录，无法修改收藏"
                    return
                }
                try await client.updateCollection(
                    subjectID: subjectID,
                    payload: CollectionModifyPayload(type: type)
                )
                collections[subjectID] = type
                collectionMessage = "已同步：\(Self.collectionName(type))"
            } catch {
                collectionMessage = "同步失败：\(Self.describe(error))"
            }
        }
    }

    /// 移除收藏并同步到 Bangumi
    func removeCollection(subjectID: Int) {
        Task {
            collectionMessage = nil
            do {
                guard let client else {
                    collectionMessage = "未登录，无法移除收藏"
                    return
                }
                try await client.removeCollection(subjectID: subjectID)
                collections[subjectID] = nil
                collectionMessage = "已移除收藏"
            } catch {
                collectionMessage = "同步失败：\(Self.describe(error))"
            }
        }
    }

    static func collectionName(_ type: SubjectCollectionType) -> String {
        switch type {
        case .wish: return "想看"
        case .collected: return "看过"
        case .doing: return "在看"
        case .onHold: return "搁置"
        case .dropped: return "抛弃"
        case .unknown: return "未收藏"
        }
    }

    static func collectionColor(_ type: SubjectCollectionType) -> Color {
        switch type {
        case .wish: return .orange
        case .collected: return .blue
        case .doing: return .green
        case .onHold: return .gray
        case .dropped: return .red
        case .unknown: return .gray
        }
    }

    // MARK: - 搜索

    func search() {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        Task { await performSearch(kw) }
    }

    private func performSearch(_ kw: String) async {
        guard let client else {
            await prepareClient()
            guard let client else {
                searchMessage = "客户端初始化失败"
                return
            }
            self.client = client
            return await performSearch(kw)
        }
        isSearching = true
        searchMessage = nil
        defer { isSearching = false }
        do {
            results = try await searchAnime(keyword: kw)
            if results.isEmpty { searchMessage = "没有找到动画条目，换个关键词试试" }
        } catch {
            results = []
            searchMessage = "搜索失败：\(Self.describe(error))"
        }
    }

    /// 翻页收集动画条目：优先服务端 filter（一次请求即动画，请求量最少）；
    /// 实验性接口的 filter 历史上不稳定（400 过），失败时自动降级为
    /// 无 filter 翻页 + 客户端过滤（动画常排在后页，如 "Initial D" 前 40 条全是原声带）。
    private func searchAnime(keyword: String) async throws -> [Subject] {
        if let filtered = try? await searchWithServerFilter(keyword: keyword) {
            return filtered
        }
        return try await searchWithClientFilter(keyword: keyword)
    }

    private func searchWithServerFilter(keyword: String) async throws -> [Subject] {
        guard let client else { return [] }
        var seen = Set<Int>()
        var collected: [Subject] = []
        let pageSize = 20
        let maxPages = 4
        for page in 0..<maxPages {
            let result = try await client.searchSubjects(
                keyword: keyword, limit: pageSize, offset: page * pageSize, filterType: .anime
            )
            for subject in result.data where seen.insert(subject.id).inserted {
                collected.append(subject)
            }
            if collected.count >= 20 || page * pageSize + result.data.count >= (result.total ?? 0) {
                break
            }
        }
        return Array(collected.prefix(30))
    }

    private func searchWithClientFilter(keyword: String) async throws -> [Subject] {
        guard let client else { return [] }
        var seen = Set<Int>()
        var collected: [Subject] = []
        let pageSize = 20
        let maxPages = 4
        for page in 0..<maxPages {
            let result = try await client.searchSubjects(keyword: keyword, limit: pageSize, offset: page * pageSize)
            for subject in result.data where subject.type == .anime || subject.type == nil {
                if seen.insert(subject.id).inserted {
                    collected.append(subject)
                }
            }
            if collected.count >= 20 || page * pageSize + result.data.count >= (result.total ?? 0) {
                break
            }
        }
        return Array(collected.prefix(30))
    }

    // MARK: - 详情

    func open(subject: Subject) {
        selected = subject
        Task { await loadDetail(id: subject.id) }
    }

    func back() {
        selected = nil
        detailSubject = nil
        detailLarge = nil
        detailError = nil
    }

    private func loadDetail(id: Int) async {
        guard let client else {
            await prepareClient()
            guard let client else {
                detailError = "客户端初始化失败"
                return
            }
            self.client = client
            return await loadDetail(id: id)
        }
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }

        async let v0Task = client.subject(id: id)
        async let legacyTask = client.legacySubjectLarge(id: id)
        let v0 = try? await v0Task
        let legacy = try? await legacyTask
        detailSubject = v0
        detailLarge = legacy
        if v0 == nil && legacy == nil {
            detailError = "详情加载失败，请检查网络后重试"
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

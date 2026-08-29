import Foundation

/// Bangumi API 错误
public enum BangumiError: LocalizedError {
    case invalidURL
    case network
    case decoding(String)
    case unauthorized
    case httpStatus(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "URL 无效"
        case .network: return "网络请求失败"
        case .decoding(let detail): return detail.isEmpty ? "响应解析失败" : "响应解析失败：\(detail)"
        case .unauthorized: return "登录已失效，请重新登录"
        case .httpStatus(let code, let detail):
            if let detail, !detail.isEmpty {
                return "请求失败（HTTP \(code)）：\(detail)"
            }
            return "请求失败（HTTP \(code)）"
        }
    }
}

/// Bangumi v0 API 客户端
public final class BangumiClient: @unchecked Sendable {
    /// 访问令牌（OAuth 登录后设置）
    public var accessToken: String?
    /// User-Agent（官方要求：开发者 ID + 应用名 + 版本 + 项目主页，否则默认 UA 可能被禁用）
    public var userAgent: String = "Spark-Howard/NagomiAni/0.1.0 (macOS) (https://github.com/Spark-Howard/NagomiAni)"

    private let baseURL = URL(string: "https://api.bgm.tv")!
    private let session: URLSession

    public init(accessToken: String? = nil) {
        self.accessToken = accessToken
        let config = URLSessionConfiguration.default
        // 搜索接口较重，超时放宽，避免慢查询被判为失败
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - 公开方法

    /// 当前登录用户（GET /v0/me）
    public func currentUser() async throws -> BangumiUser {
        try await send(get("/v0/me"))
    }

    /// 获取条目详情（GET /v0/subjects/{id}，服务端缓存 300s）
    public func subject(id: Int) async throws -> Subject {
        try await send(get("/v0/subjects/\(id)"))
    }

    /// 旧版大条目（GET /subject/{id}?responseGroup=large）
    /// 一次返回集数列表 / 讨论版 / 评论日志 / 角色 / 制作人员（v0 API 不含这些）
    public func legacySubjectLarge(id: Int) async throws -> LegacySubject {
        try await send(get("/subject/\(id)", query: [
            .init(name: "responseGroup", value: "large")
        ]))
    }

    /// 搜索条目（POST /v0/search/subjects，实验性 API）
    /// 传 filter 可服务端按类型过滤（如 .anime → 只返回动画）；
    /// 若 filter 不稳定（历史上 400 过），调用方应降级为客户端过滤。
    public func searchSubjects(
        keyword: String,
        limit: Int = 20,
        offset: Int = 0,
        filterType: SubjectType? = nil
    ) async throws -> Paged<Subject> {
        var request = try makeRequest("/v0/search/subjects", query: [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset))
        ])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "keyword": keyword,
            "sort": "match",
        ]
        if let filterType {
            body["filter"] = ["type": [filterType.rawValue]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    /// 获取用户收藏（GET /v0/users/{username}/collections）
    public func collections(
        username: String,
        subjectType: SubjectType? = .anime,
        type: SubjectCollectionType? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> Paged<UserSubjectCollection> {
        var query: [URLQueryItem] = []
        if let subjectType { query.append(.init(name: "subject_type", value: String(subjectType.rawValue))) }
        if let type { query.append(.init(name: "type", value: String(type.rawValue))) }
        query.append(.init(name: "limit", value: String(limit)))
        query.append(.init(name: "offset", value: String(offset)))
        return try await send(get("/v0/users/\(username)/collections", query: query))
    }

    /// 我的单个条目收藏（GET /v0/users/-/collections/{subject_id}）
    public func myCollection(subjectID: Int) async throws -> UserSubjectCollection {
        try await send(get("/v0/users/-/collections/\(subjectID)"))
    }

    /// 新增或修改条目收藏（POST /v0/users/-/collections/{subject_id}）
    public func updateCollection(subjectID: Int, payload: CollectionModifyPayload) async throws {
        var request = try makeRequest("/v0/users/-/collections/\(subjectID)")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        try await sendNoContent(request)
    }

    /// 移除条目收藏（POST 空 body 即取消收藏）
    public func removeCollection(subjectID: Int) async throws {
        var request = try makeRequest("/v0/users/-/collections/\(subjectID)")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [String: Any]())
        try await sendNoContent(request)
    }

    /// 获取条目的章节列表（GET /v0/episodes）
    public func episodes(subjectID: Int, type: Int? = 0, limit: Int = 200, offset: Int = 0) async throws -> Paged<Episode> {
        var query = [URLQueryItem(name: "subject_id", value: String(subjectID))]
        if let type { query.append(.init(name: "type", value: String(type))) }
        query.append(.init(name: "limit", value: String(limit)))
        query.append(.init(name: "offset", value: String(offset)))
        return try await send(get("/v0/episodes", query: query))
    }

    /// 批量标记单集收藏（PATCH /v0/users/-/collections/{subject_id}/episodes）
    /// 官方会同时重算条目完成度，这是动画进度同步的正确姿势
    public func markEpisodes(subjectID: Int, episodeIDs: [Int], type: EpisodeCollectionType) async throws {
        var request = try makeRequest("/v0/users/-/collections/\(subjectID)/episodes")
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["episode_id": episodeIDs, "type": type.rawValue]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await sendNoContent(request)
    }

    /// 我的单集收藏（GET /v0/users/-/collections/{subject_id}/episodes）
    public func myEpisodeCollections(subjectID: Int, limit: Int = 1000) async throws -> Paged<UserEpisodeCollection> {
        try await send(get("/v0/users/-/collections/\(subjectID)/episodes", query: [
            .init(name: "limit", value: String(limit))
        ]))
    }

    // MARK: - 私有

    private func get(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        try makeRequest(path, query: query)
    }

    private func makeRequest(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var comps = URLComponents(string: baseURL.absoluteString + path)!
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw BangumiError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// 网络错误时自动重试（指数退避），应对实验性接口偶发断连
    private static let maxRetries = 2

    private func send<T: Decodable>(_ request: URLRequest, attempt: Int = 0) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if attempt < Self.maxRetries {
                let delay = UInt64(1_000_000_000 * Double(attempt + 1))
                try? await Task.sleep(nanoseconds: delay)
                return try await send(request, attempt: attempt + 1)
            }
            throw BangumiError.network
        }
        guard let http = response as? HTTPURLResponse else { throw BangumiError.network }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw BangumiError.unauthorized }
            throw BangumiError.httpStatus(http.statusCode, Self.bodySnippet(data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BangumiError.decoding(Self.bodySnippet(data))
        }
    }

    private func sendNoContent(_ request: URLRequest, attempt: Int = 0) async throws {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if attempt < Self.maxRetries {
                let delay = UInt64(1_000_000_000 * Double(attempt + 1))
                try? await Task.sleep(nanoseconds: delay)
                return try await sendNoContent(request, attempt: attempt + 1)
            }
            throw BangumiError.network
        }
        guard let http = response as? HTTPURLResponse else { throw BangumiError.network }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw BangumiError.unauthorized }
            throw BangumiError.httpStatus(http.statusCode, Self.bodySnippet(data))
        }
    }

    /// 提取响应体前 200 字，便于排查错误原因
    private static func bodySnippet(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        return String(text.prefix(200))
    }
}

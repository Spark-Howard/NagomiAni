import Foundation

/// 苹果CMS V10 采集接口的通用 Provider（国内资源站的事实标准，zyplayer/LibreTV 同款协议）。
///
/// 端点：`{站点}/api.php/provide/vod/?ac=list|detail`
/// - `ac=list&pg=N`：最新/分页列表（简略字段）
/// - `ac=detail&wd=关键词`：搜索（全字段，含播放地址）
/// - `ac=detail&ids=N`：详情（含 `vod_play_url` 分集地址）
///
/// 播放地址格式：`播放源1$$$播放源2`，每组内 `第01集$http://.../01.m3u8#第02集$http://.../02.m3u8`。
/// 仓库不内置任何站点地址，用户在「在线」页自行添加；providerID 取域名（进合成 seriesKey，稳定）。
public final class MacCMSProvider: SourceProvider, @unchecked Sendable {
    public enum MacCMSError: LocalizedError, Equatable {
        case badResponse
        case httpStatus(Int)
        case episodeNotFound

        public var errorDescription: String? {
            switch self {
            case .badResponse: return "资源站返回了无法解析的数据"
            case .httpStatus(let code): return "资源站请求失败（HTTP \(code)）"
            case .episodeNotFound: return "在资源站上未找到该集的播放地址"
            }
        }
    }

    /// 资源站 CDN 常校验 Referer/UA：统一带浏览器 UA + 站点 origin
    public static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    /// 归一化后的完整 API 端点（如 https://host/api.php/provide/vod/）
    public let apiBase: URL
    private let session: URLSession

    /// - Parameter base: 用户粘贴的地址（站点首页 / 任意路径 / 完整 API 地址均可）
    public convenience init?(base raw: String) {
        guard let base = Self.normalizeAPIBase(raw) else { return nil }
        self.init(apiBase: base)
    }

    public init(apiBase: URL) {
        self.apiBase = apiBase
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - SourceProvider

    public var id: String { Self.providerID(for: apiBase) }
    public var displayName: String { apiBase.host ?? "资源站" }

    /// providerID = 域名（进合成 seriesKey，上线后域名变更会丢绑定/续播记录）
    public static func providerID(for base: URL) -> String {
        base.host ?? "maccms"
    }

    public func listShows() async throws -> [OnlineShow] {
        let data = try await fetch(queryItems: [
            URLQueryItem(name: "ac", value: "list"),
            URLQueryItem(name: "pg", value: "1")
        ])
        return try Self.shows(from: data, providerID: id)
    }

    public func search(keyword: String) async throws -> [OnlineShow] {
        let data = try await fetch(queryItems: [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "wd", value: keyword)
        ])
        return try Self.shows(from: data, providerID: id)
    }

    public func episodes(for showID: String) async throws -> [OnlineEpisode] {
        let data = try await fetch(queryItems: [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "ids", value: showID)
        ])
        return try Self.episodes(from: data, providerID: id, showID: showID)
    }

    public func streamURL(for episode: OnlineEpisode) async throws -> StreamSource {
        var urlString = episode.streamHint
        if urlString == nil {
            // 兜底：重新拉详情，按集号（次选标题）匹配
            let episodes = try await episodes(for: episode.showID)
            let match = episodes.first { $0.number == episode.number }
                ?? episodes.first { $0.title == episode.title }
            urlString = match?.streamHint
        }
        guard let urlString, let url = URL(string: urlString), url.scheme != nil else {
            throw MacCMSError.episodeNotFound
        }
        var headers: [String: String] = [:]
        if let origin = Self.origin(of: apiBase) {
            headers["Referer"] = origin
        }
        return StreamSource(
            url: url,
            httpHeaders: headers,
            userAgent: Self.browserUserAgent,
            isHLS: Self.isHLS(url)
        )
    }

    // MARK: - 请求

    private func fetch(queryItems: [URLQueryItem]) async throws -> Data {
        guard var comps = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else {
            throw MacCMSError.badResponse
        }
        var items = comps.queryItems ?? []
        items.append(contentsOf: queryItems)
        comps.queryItems = items
        guard let url = comps.url else { throw MacCMSError.badResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let origin = Self.origin(of: apiBase) {
            request.setValue(origin, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MacCMSError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw MacCMSError.httpStatus(http.statusCode) }
        return data
    }

    // MARK: - 解析（静态可单测）

    /// 列表/详情响应 → OnlineShow
    static func shows(from data: Data, providerID: String) throws -> [OnlineShow] {
        let response = try decodeList(data)
        return response.list.compactMap { video in
            guard let vodID = video.vodID else { return nil }
            var subtitleParts: [String] = []
            if let typeName = video.typeName, !typeName.isEmpty { subtitleParts.append(typeName) }
            if let remarks = video.remarks, !remarks.isEmpty { subtitleParts.append(remarks) }
            return OnlineShow(
                providerID: providerID,
                showID: vodID,
                title: video.name?.isEmpty == false ? video.name! : "未命名",
                subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: " · ")
            )
        }
    }

    /// 详情响应 → OnlineEpisode（带 streamHint，点播免二次请求）
    static func episodes(from data: Data, providerID: String, showID: String) throws -> [OnlineEpisode] {
        let response = try decodeList(data)
        guard let video = response.list.first(where: { $0.vodID == showID }) ?? response.list.first else {
            return []
        }
        let pairs = Self.parsePlayURL(playURL: video.playURL, playFrom: video.playFrom)
        return pairs.enumerated().map { index, pair in
            OnlineEpisode(
                providerID: providerID,
                showID: showID,
                // "第01集/EP01/01" 等动漫圈命名走 MediaMatching；解析不出按出现顺序兜底
                number: MediaMatching.episodeNumber(from: pair.name) ?? index + 1,
                title: pair.name.isEmpty ? nil : pair.name,
                streamHint: pair.url
            )
        }
    }

    /// `播放源A$$$播放源B`，组内 `第01集$url#第02集$url`；优先选播放源名含 m3u8 的组
    static func parsePlayURL(playURL: String?, playFrom: String?) -> [(name: String, url: String)] {
        guard let playURL, !playURL.isEmpty else { return [] }
        let sources = playURL.components(separatedBy: "$$$")
        let froms = (playFrom ?? "").components(separatedBy: "$$$")
        var sourceIndex = 0
        if let m3u8Index = froms.firstIndex(where: { $0.lowercased().contains("m3u8") }),
           sources.indices.contains(m3u8Index) {
            sourceIndex = m3u8Index
        }
        guard sources.indices.contains(sourceIndex) else { return [] }
        return sources[sourceIndex].components(separatedBy: "#").compactMap { chunk in
            let parts = chunk.components(separatedBy: "$")
            guard parts.count >= 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            // URL 里理论上不会再出现 $，但仍以首段之后的全部内容为准，防地址含 $ 被截断
            let url = parts[1...].joined(separator: "$").trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty else { return nil }
            return (name: name, url: url)
        }
    }

    /// 站点地址归一化：缺 scheme 补 https；空路径/根路径拼标准 API 路径；
    /// 已含 provide 的按用户给的完整 API 用；其它路径在其后拼接
    static func normalizeAPIBase(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().contains("://") {
            text = "https://" + text
        }
        guard var comps = URLComponents(string: text), let host = comps.host, !host.isEmpty else {
            return nil
        }
        let path = comps.path
        if path.isEmpty || path == "/" {
            comps.path = "/api.php/provide/vod/"
        } else if !path.lowercased().contains("provide") {
            comps.path = (path.hasSuffix("/") ? path : path + "/") + "api.php/provide/vod/"
        }
        return comps.url
    }

    static func isHLS(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
            || url.absoluteString.lowercased().contains(".m3u8")
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = url.port
        return comps.url?.absoluteString
    }

    // MARK: - 防御式解码（资源站字段类型不统一：vod_id 可能是字符串，字段可能缺失）

    struct MacCMSListResponse: Sendable {
        let page: Int?
        let pageCount: Int?
        let total: Int?
        let list: [MacCMSVideo]
    }

    struct MacCMSVideo: Sendable {
        let vodID: String?
        let name: String?
        let pic: String?
        let remarks: String?
        let typeName: String?
        let playFrom: String?
        let playURL: String?
    }

    static func decodeList(_ data: Data) throws -> MacCMSListResponse {
        let root = try? JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any] else { throw MacCMSError.badResponse }
        let rawList = dict["list"] as? [[String: Any]] ?? []
        return MacCMSListResponse(
            page: dict["page"] as? Int,
            pageCount: dict["pagecount"] as? Int,
            total: dict["total"] as? Int,
            list: rawList.map(Self.video(from:))
        )
    }

    static func video(from dict: [String: Any]) -> MacCMSVideo {
        MacCMSVideo(
            vodID: scalarString(dict["vod_id"]),
            name: dict["vod_name"] as? String,
            pic: dict["vod_pic"] as? String,
            remarks: dict["vod_remarks"] as? String,
            typeName: dict["type_name"] as? String,
            playFrom: dict["vod_play_from"] as? String,
            playURL: dict["vod_play_url"] as? String
        )
    }

    /// 数字/浮点/字符串形式的标量统一转 String
    static func scalarString(_ value: Any?) -> String? {
        switch value {
        case let n as Int: return String(n)
        case let n as Int64: return String(n)
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        case let s as String: return s.isEmpty ? nil : s
        default: return nil
        }
    }
}

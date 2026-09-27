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
    /// 自定义显示名（内置默认源显示"量子资源"等友好名称；nil 用域名）
    public let customName: String?
    private let session: URLSession

    /// - Parameter base: 用户粘贴的地址（站点首页 / 任意路径 / 完整 API 地址均可）
    public convenience init?(base raw: String) {
        guard let base = Self.normalizeAPIBase(raw) else { return nil }
        self.init(apiBase: base)
    }

    public init(apiBase: URL, displayName customName: String? = nil) {
        self.apiBase = apiBase
        self.customName = customName
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - SourceProvider

    public var id: String { Self.providerID(for: apiBase) }
    public var displayName: String { customName ?? (apiBase.host ?? "资源站") }

    /// providerID = 域名（进合成 seriesKey，上线后域名变更会丢绑定/续播记录）
    public static func providerID(for base: URL) -> String {
        base.host ?? "maccms"
    }

    /// 默认目录：先取一页拿分类树锁定动漫类目，再按类目各取最新一页；
    /// 真人电影/剧集/综艺/体育等不纳入（类目过滤 + 标题兜底，见 shows(from:)）
    public func listShows() async throws -> [OnlineShow] {
        let firstPage = try await fetch(queryItems: [
            URLQueryItem(name: "ac", value: "list"),
            URLQueryItem(name: "pg", value: "1")
        ])
        let response = try Self.decodeList(firstPage)
        var shows = try Self.shows(from: firstPage, providerID: id)
        if shows.isEmpty, response.list.isEmpty, Self.animeTypeIDs(from: response.categories).isEmpty {
            return [] // 站点没有动漫类目也没有内容
        }

        // 按动漫类目各拉最新一页（限 4 个类目防请求爆炸）
        let typeIDs = Self.animeTypeIDs(from: response.categories).prefix(4)
        var seen = Set(shows.map(\.showID))
        for typeID in typeIDs {
            let data = try await fetch(queryItems: [
                URLQueryItem(name: "ac", value: "list"),
                URLQueryItem(name: "t", value: typeID),
                URLQueryItem(name: "pg", value: "1")
            ])
            for show in try Self.shows(from: data, providerID: id) where !seen.contains(show.showID) {
                seen.insert(show.showID)
                shows.append(show)
            }
        }
        return shows
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

    /// 列表/详情响应 → OnlineShow。
    /// 只保留动漫类目（type_name 含 动漫/动画/番剧/剧场版），类目下误挂的解说/盘点标题剔除——
    /// 真人电影/剧集/综艺/体育等由此排除（目录与搜索共用此过滤）
    static func shows(from data: Data, providerID: String) throws -> [OnlineShow] {
        let response = try decodeList(data)
        return response.list.compactMap { video in
            guard let vodID = video.vodID else { return nil }
            guard Self.isAnimeCategoryName(video.typeName) else { return nil }
            guard !Self.isJunkTitle(video.name) else { return nil }
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

    /// 详情响应 → OnlineEpisode（带 streamHint 与全部线路，点播免二次请求）
    static func episodes(from data: Data, providerID: String, showID: String) throws -> [OnlineEpisode] {
        let response = try decodeList(data)
        guard let video = response.list.first(where: { $0.vodID == showID }) ?? response.list.first else {
            return []
        }
        let groups = Self.parsePlayGroups(playURL: video.playURL, playFrom: video.playFrom)
        guard let preferredIndex = Self.preferredGroupIndex(groups: groups) else { return [] }
        let preferred = groups[preferredIndex]

        return preferred.episodes.enumerated().map { index, pair in
            // 线路 = 各播放源组在同一序位的地址（首选组在最前，去重保序）；
            // 播放失败自动换源与手动切换线路都吃这个数组
            var routes: [String] = [pair.url]
            for (groupIndex, group) in groups.enumerated() where groupIndex != preferredIndex {
                if group.episodes.indices.contains(index), !routes.contains(group.episodes[index].url) {
                    routes.append(group.episodes[index].url)
                }
            }
            return OnlineEpisode(
                providerID: providerID,
                showID: showID,
                // "第01集/EP01/01" 等动漫圈命名走 MediaMatching；解析不出按出现顺序兜底
                number: MediaMatching.episodeNumber(from: pair.name) ?? index + 1,
                title: pair.name.isEmpty ? nil : pair.name,
                streamHint: pair.url,
                routes: routes.count > 1 ? routes : nil
            )
        }
    }

    /// `播放源A$$$播放源B`，组内 `第01集$url#第02集$url`；返回全部组（组名来自 playFrom）
    static func parsePlayGroups(playURL: String?, playFrom: String?) -> [(from: String?, episodes: [(name: String, url: String)])] {
        guard let playURL, !playURL.isEmpty else { return [] }
        let sources = playURL.components(separatedBy: "$$$")
        let froms = (playFrom ?? "").components(separatedBy: "$$$")
        return sources.enumerated().compactMap { index, source -> (from: String?, episodes: [(name: String, url: String)])? in
            let episodes: [(name: String, url: String)] = source.components(separatedBy: "#").compactMap { chunk -> (name: String, url: String)? in
                let parts = chunk.components(separatedBy: "$")
                guard parts.count >= 2 else { return nil }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                // URL 里理论上不会再出现 $，但仍以首段之后的全部内容为准，防地址含 $ 被截断
                let url = parts[1...].joined(separator: "$").trimmingCharacters(in: .whitespaces)
                guard !url.isEmpty else { return nil }
                return (name: name, url: url)
            }
            guard !episodes.isEmpty else { return nil }
            let from = index < froms.count ? froms[index] : nil
            return (from: from, episodes: episodes)
        }
    }

    /// 首选播放源组：名字含 m3u8 的组优先，否则第一组
    static func preferredGroupIndex(groups: [(from: String?, episodes: [(name: String, url: String)])]) -> Int? {
        guard !groups.isEmpty else { return nil }
        if let m3u8Index = groups.firstIndex(where: { $0.from?.lowercased().contains("m3u8") == true }) {
            return m3u8Index
        }
        return 0
    }

    /// 单组便捷形式（历史 API，内部走 parsePlayGroups 的首选组）
    static func parsePlayURL(playURL: String?, playFrom: String?) -> [(name: String, url: String)] {
        let groups = parsePlayGroups(playURL: playURL, playFrom: playFrom)
        guard let index = preferredGroupIndex(groups: groups) else { return [] }
        return groups[index].episodes
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
        /// 站点的分类树（ac=list 响应的 class 字段）
        let categories: [MacCMSCategory]
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

    struct MacCMSCategory: Sendable {
        let typeID: String?
        let typePID: String?
        let typeName: String?
    }

    // MARK: - 动漫内容过滤（用户决策：只纳入动漫/动漫电影，真人电影/解说/体育等不进搜索与目录）

    /// 纳入的类目关键词（含子类：日本动漫/国产动漫/动画电影/剧场版 等）
    static let animeCategoryKeywords = ["动漫", "动画", "番剧", "剧场版"]
    /// 类目命中但内容实为解说/盘点的标题特征（二次过滤）
    static let junkTitleKeywords = ["解说", "速看", "几分钟", "盘点"]

    static func isAnimeCategoryName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        return animeCategoryKeywords.contains { name.contains($0) }
    }

    static func isJunkTitle(_ title: String?) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return junkTitleKeywords.contains { title.contains($0) }
    }

    /// 从分类树取动漫相关类目 id：自身命中，或父类目命中（如 动漫 → 日本动漫）
    static func animeTypeIDs(from categories: [MacCMSCategory]) -> [String] {
        let nameByID = Dictionary(
            categories.compactMap { c in c.typeID.map { ($0, c.typeName ?? "") } },
            uniquingKeysWith: { first, _ in first }
        )
        return categories.compactMap { category in
            guard let id = category.typeID else { return nil }
            let parentName = category.typePID.flatMap { nameByID[$0] }
            if isAnimeCategoryName(category.typeName) || isAnimeCategoryName(parentName) {
                return id
            }
            return nil
        }
    }

    static func decodeList(_ data: Data) throws -> MacCMSListResponse {
        let root = try? JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any] else { throw MacCMSError.badResponse }
        let rawList = dict["list"] as? [[String: Any]] ?? []
        let rawClasses = dict["class"] as? [[String: Any]] ?? []
        return MacCMSListResponse(
            page: dict["page"] as? Int,
            pageCount: dict["pagecount"] as? Int,
            total: dict["total"] as? Int,
            list: rawList.map(Self.video(from:)),
            categories: rawClasses.map(Self.category(from:))
        )
    }

    static func video(from dict: [String: Any]) -> MacCMSVideo {
        MacCMSVideo(
            vodID: scalarString(dict["vod_id"]),
            // 站点数据带 HTML 实体（&#039; 撇号、&amp;#39; 双重转义都有实测），统一解码：
            // 标题不再显示乱码字符，带 &amp; 的播放地址也得以修复
            name: decodeHTMLEntities(dict["vod_name"] as? String),
            pic: decodeHTMLEntities(dict["vod_pic"] as? String),
            remarks: decodeHTMLEntities(dict["vod_remarks"] as? String),
            typeName: decodeHTMLEntities(dict["type_name"] as? String),
            playFrom: decodeHTMLEntities(dict["vod_play_from"] as? String),
            playURL: decodeHTMLEntities(dict["vod_play_url"] as? String)
        )
    }

    /// 解码 HTML 实体：数字（十进制/十六进制，分号可缺——容忍脏数据）+ 常见命名实体。
    /// 循环最多 3 轮以解掉双重转义（&amp;#39; → &#039; → '）。未知命名实体原样保留。
    /// 注：用 NSRegularExpression 字符串模式——/…/ 正则字面量在 swift-5 模式下与 `&#` 词法冲突。
    static func decodeHTMLEntities(_ text: String?) -> String? {
        guard var result = text, result.contains("&") else { return text }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·",
            "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
        ]
        for _ in 0..<3 {
            let before = result
            result = Self.replaceMatches(
                in: result,
                pattern: "&#(?:x([0-9a-fA-F]+)|([0-9]+));?|&([a-zA-Z]{2,8});"
            ) { groups in
                if let hex = groups[0] { return Self.entityScalar(hex, radix: 16) }
                if let dec = groups[1] { return Self.entityScalar(dec, radix: 10) }
                if let name = groups[2] { return named[name] ?? "&\(name);" }
                return ""
            }
            if result == before { break }
        }
        return result
    }

    /// NSRegularExpression 逐匹配替换（回调拿到各捕获组）
    private static func replaceMatches(
        in text: String,
        pattern: String,
        transform: (_ groups: [String?]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups: [String?] = (1..<max(match.numberOfRanges, 1)).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            out += transform(groups)
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func entityScalar(_ digits: String, radix: Int) -> String {
        guard let value = UInt32(digits, radix: radix),
              let scalar = Unicode.Scalar(value) else { return "" }
        return String(Character(scalar))
    }

    static func category(from dict: [String: Any]) -> MacCMSCategory {
        MacCMSCategory(
            typeID: scalarString(dict["type_id"]),
            typePID: scalarString(dict["type_pid"]),
            typeName: dict["type_name"] as? String
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

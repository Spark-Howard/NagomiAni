import Foundation

/// 在线片源的一「番」
public struct OnlineShow: Identifiable, Codable, Sendable, Hashable {
    /// 所属 Provider 的 id（冗余存储，便于跨 provider 汇总列表）
    public let providerID: String
    /// Provider 内部的番 ID
    public let showID: String
    public let title: String
    /// 可选副标题（季度等）
    public let subtitle: String?

    public var id: String { "\(providerID):\(showID)" }

    public init(providerID: String, showID: String, title: String, subtitle: String? = nil) {
        self.providerID = providerID
        self.showID = showID
        self.title = title
        self.subtitle = subtitle
    }

    /// 与 Bangumi 绑定/续播共用的合成 seriesKey
    /// （直通 PlayerModel 的 markWatched 与 resume 存储，本地番库同一张绑定表）
    public var seriesKey: String { Self.seriesKey(providerID: providerID, showID: showID) }

    public static func seriesKey(providerID: String, showID: String) -> String {
        "online:\(providerID):\(showID)"
    }
}

/// 在线片源的一集
public struct OnlineEpisode: Identifiable, Codable, Sendable, Hashable {
    public let providerID: String
    public let showID: String
    /// 集号（1 起）；markWatched 按 Bangumi 集的 sort 匹配时使用
    public let number: Int
    public let title: String?
    /// Provider 特有的取流提示（如资源站的分片 URL）。点播时 streamURL 优先使用，免二次请求
    public let streamHint: String?

    public var id: String { "\(providerID):\(showID):\(number)" }

    public init(providerID: String, showID: String, number: Int, title: String? = nil, streamHint: String? = nil) {
        self.providerID = providerID
        self.showID = showID
        self.number = number
        self.title = title
        self.streamHint = streamHint
    }

    public var seriesKey: String { OnlineShow.seriesKey(providerID: providerID, showID: showID) }

    /// 断点续播的稳定键（跨会话不变，与本地文件的"路径键"并存于 resume.json）
    public var resumeKey: String { "\(seriesKey):\(number)" }
}

/// 一个可播放的流描述（由 Provider 产出，PlayerModel/引擎消费）
public struct StreamSource: Sendable, Hashable {
    public let url: URL
    /// 附加 HTTP 请求头（防盗链 Referer、鉴权 Cookie 等）
    public let httpHeaders: [String: String]
    public let userAgent: String?
    /// 是否 HLS（m3u8）；M3 的 StreamCache 依赖此标记
    public let isHLS: Bool

    public init(url: URL, httpHeaders: [String: String] = [:], userAgent: String? = nil, isHLS: Bool = false) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.userAgent = userAgent
        self.isHLS = isHLS
    }
}

/// 在线片源抽象：UI 与业务只依赖此协议，不关心底层站点。
/// 当前实现为 MockProvider（样例流）与 MacCMSProvider（苹果CMS V10 采集接口）。
public protocol SourceProvider: Sendable {
    /// 稳定的 provider 标识（进入合成 seriesKey，改了会丢绑定/续播）
    var id: String { get }
    var displayName: String { get }

    /// 默认目录（最新/推荐列表）
    func listShows() async throws -> [OnlineShow]
    /// 关键词搜索；不支持搜索的源返回空（协议扩展默认）
    func search(keyword: String) async throws -> [OnlineShow]
    func episodes(for showID: String) async throws -> [OnlineEpisode]
    /// 取得可播放的流（可能触发本地生成/解析等耗时工作）
    func streamURL(for episode: OnlineEpisode) async throws -> StreamSource
}

public extension SourceProvider {
    /// 默认实现：不支持搜索
    func search(keyword: String) async throws -> [OnlineShow] { [] }
}

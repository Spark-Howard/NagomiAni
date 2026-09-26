import Foundation

// MARK: - 枚举（宽松解析：遇到未知值时回退到 .unknown，避免整个响应解析失败）

/// 条目类型
public enum SubjectType: Int, Codable, Sendable {
    case book = 1
    case anime = 2
    case music = 3
    case game = 4
    case real = 6
    case unknown = 99

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = SubjectType(rawValue: raw) ?? .unknown
    }
}

/// 收藏类型
public enum SubjectCollectionType: Int, Codable, Sendable, CaseIterable {
    case wish = 1      // 想看
    case collected = 2 // 看过
    case doing = 3     // 在看
    case onHold = 4    // 搁置
    case dropped = 5   // 抛弃
    case unknown = 99

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = SubjectCollectionType(rawValue: raw) ?? .unknown
    }
}

/// 单集收藏类型
public enum EpisodeCollectionType: Int, Codable, Sendable {
    case none = 0
    case wish = 1     // 想看
    case watched = 2  // 看过
    case dropped = 3  // 抛弃
    case unknown = 99

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = EpisodeCollectionType(rawValue: raw) ?? .unknown
    }
}

/// 章节类型
public enum EpType: Int, Codable, Sendable {
    case main = 0     // 本篇
    case special = 1  // SP
    case opening = 2  // OP
    case ending = 3   // ED
    case mad = 4
    case other = 5
    case unknown = 99

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = EpType(rawValue: raw) ?? .unknown
    }
}

// MARK: - 解码辅助

private extension KeyedDecodingContainer {
    /// 时间戳容错：可能是 Int64 / String / Double，解析失败返回 nil
    func decodeLenientInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let string = try? decodeIfPresent(String.self, forKey: key),
           let value = Int64(string) {
            return value
        }
        if let double = try? decodeIfPresent(Double.self, forKey: key) {
            return Int64(double)
        }
        return nil
    }
}

// MARK: - 模型

/// 用户信息（GET /v0/me）
public struct BangumiUser: Codable, Sendable {
    public let id: Int
    public let username: String
    public let nickname: String
    public let sign: String?
    public let userGroup: Int?
    public let avatar: BangumiAvatar?

    public struct BangumiAvatar: Codable, Sendable {
        public let large: String?
        public let medium: String?
        public let small: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, username, nickname, sign, avatar
        case userGroup = "user_group"
    }
}

/// 放送日历（GET /calendar）里一天的条目组：
/// weekday.id 1=周一 … 7=周日；items 为该星期在播条目（动画 type=2）
public struct CalendarDay: Codable, Sendable {
    public let weekday: Weekday?
    public let items: [Subject]?

    public struct Weekday: Codable, Sendable {
        public let id: Int?
        public let en: String?
        public let cn: String?
        public let ja: String?
    }

    public init(weekday: Weekday?, items: [Subject]?) {
        self.weekday = weekday
        self.items = items
    }
}

/// 条目（GET /v0/subjects/{id}）
public struct Subject: Codable, Sendable, Identifiable, ChineseNamed {
    public let id: Int
    public let type: SubjectType?
    public let name: String?
    public let nameCN: String?
    public let summary: String?
    public let airDate: String?
    public let eps: Int?
    public let totalEpisodes: Int?
    public let images: SubjectImages?
    public let rating: SubjectRating?
    /// 详细资料表（v0 详情接口，如 中文名/别名/话数/放送开始…）
    public let infobox: [SubjectInfobox]?
    /// 标签（v0 详情接口）
    public let tags: [SubjectTag]?
    /// 收藏统计（v0 详情接口：想看/看过/在看/搁置/抛弃）
    public let collection: CollectionCounts?

    /// 图片地址集（common/large/medium/small/grid 均为完整 URL）
    /// 注意：Bangumi 各 API 返回的图片 URL 是明文 http://lain.bgm.tv/…，
    /// 打包版 .app 受 ATS 约束会拦掉 http（swift run 裸二进制不受 ATS 约束），
    /// 因此解码时统一把 bgm.tv 系图片主机升级为 https（CDN 支持 https 且更稳）。
    public struct SubjectImages: Codable, Sendable {
        public let large: String?
        public let common: String?
        public let medium: String?
        public let small: String?
        public let grid: String?

        enum CodingKeys: String, CodingKey {
            case large, common, medium, small, grid
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            large = Self.httpsUpgraded((try? c.decodeIfPresent(String.self, forKey: .large)) ?? nil)
            common = Self.httpsUpgraded((try? c.decodeIfPresent(String.self, forKey: .common)) ?? nil)
            medium = Self.httpsUpgraded((try? c.decodeIfPresent(String.self, forKey: .medium)) ?? nil)
            small = Self.httpsUpgraded((try? c.decodeIfPresent(String.self, forKey: .small)) ?? nil)
            grid = Self.httpsUpgraded((try? c.decodeIfPresent(String.self, forKey: .grid)) ?? nil)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(large, forKey: .large)
            try c.encodeIfPresent(common, forKey: .common)
            try c.encodeIfPresent(medium, forKey: .medium)
            try c.encodeIfPresent(small, forKey: .small)
            try c.encodeIfPresent(grid, forKey: .grid)
        }

        /// 仅把 bgm.tv 系图片主机的 http 升为 https；其它主机/已是 https 的原样保留
        private static func httpsUpgraded(_ raw: String?) -> String? {
            guard let raw,
                  raw.hasPrefix("http://"),
                  let url = URL(string: raw),
                  let host = url.host?.lowercased(),
                  host == "lain.bgm.tv" || host.hasSuffix(".bgm.tv")
            else { return raw }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = "https"
            return comps?.url?.absoluteString ?? raw
        }

        // MARK: - 按显示尺寸挑分辨率

        /// 各变体的实际像素尺寸（Bangumi CDN 的 `r/N` 缩放规则，实测值）：
        ///
        /// | 变体 | URL | 实际像素 |
        /// |---|---|---|
        /// | grid   | `/r/100/` | 100×142 |
        /// | small  | `/r/200/` | 200×283 |
        /// | common | `/r/400/` | 400×566 |
        /// | medium | `/r/800/` | 800×1132 |
        /// | large  | 无前缀（原图） | 975×1380 |
        ///
        /// 注意 `common` 只有 400px 宽：`112×152pt` 的卡片在 3x 屏上需要 336×456px，
        /// 400px 只是"刚好够"，实际会偏糊；2x 屏（需 224px）也只有 1.8 倍余量。
        private static let variantWidths: [(key: String, width: Int)] = [
            ("grid", 100), ("small", 200), ("common", 400), ("medium", 800), ("large", 975),
        ]

        /// 按目标显示尺寸挑选**够清晰且最省流量**的一档。
        ///
        /// - Parameters:
        ///   - targetHeight: 目标显示高度（pt）
        ///   - aspectRatio: 封面宽高比（默认 Bangumi 封面约 0.71）
        ///   - scale: 屏幕缩放（Retina 取 2 或 3，来自 `@Environment(\.displayScale)`）
        ///   - headroom: 清晰度余量。1.0 = 只要求"刚好够"，调大则要求更多余量、更易升档。
        ///     **实测 1.0 会偏糊**：`common`(400px) 对 3x 的 152pt 卡片（需 324px）
        ///     只多 23%，缩到屏幕尺寸时细节发软，因此默认 1.3。
        ///
        /// 换档靠替换 `large` URL 里的 `/r/N` 缩放段实现，保证是同一张图。
        public func bestURL(
            targetHeight: CGFloat,
            aspectRatio: CGFloat = 0.71,
            scale: CGFloat = 2,
            headroom: CGFloat = 1.3
        ) -> String? {
            let neededWidth = Int((targetHeight * aspectRatio * scale * headroom).rounded(.up))

            let chosen = Self.variantWidths.first { $0.width >= neededWidth } ?? Self.variantWidths.last!
            if chosen.key == "large", let large { return large }

            // 由 large 换档（同一张图，只改 r/N）
            if let rewritten = Self.rewritingScale(of: large, to: chosen.width) { return rewritten }

            // 没有 large 可用：至少给出原有的 common，别返回 nil
            return common ?? value(for: chosen.key)
        }

        private func value(for key: String) -> String? {
            switch key {
            case "grid": return grid
            case "small": return small
            case "common": return common
            case "medium": return medium
            case "large": return large
            default: return nil
            }
        }

        /// 把 `https://lain.bgm.tv/r/800/pic/cover/l/xx/yy/id.jpg` 里的缩放段换成 `r/width`
        ///
        /// 只有当 `large` 与目标同源（去掉 `/r/N` 后路径一致）时才做替换，
        /// 否则返回 nil，由调用方回退到原 URL。
        private static func rewritingScale(of large: String?, to width: Int) -> String? {
            guard let large, let range = large.range(of: "/pic/") else { return nil }
            let prefix = large[large.startIndex..<range.lowerBound]
            let suffix = large[range.lowerBound...]

            // 前缀应形如 https://lain.bgm.tv 或 https://lain.bgm.tv/r/800
            guard let hostEnd = prefix.range(of: "://").map({ $0.upperBound }) else { return nil }
            let afterScheme = prefix[hostEnd...]
            guard let slash = afterScheme.firstIndex(of: "/") else {
                // 纯主机名，没有缩放段
                return "\(prefix)/r/\(width)\(suffix)"
            }
            let host = afterScheme[..<slash]
            let rest = afterScheme[slash...]
            // rest 要么是 "/r/N"，要么就是 "/pic/..." 前面没有缩放段
            let isScaleSegment = rest.hasPrefix("/r/")
            let newPrefix = isScaleSegment ? "\(prefix[..<hostEnd])\(host)/r/\(width)" : "\(prefix[..<hostEnd])\(host)"
            return "\(newPrefix)\(suffix)"
        }
    }

    public struct SubjectRating: Codable, Sendable {
        public let total: Int?
        public let count: [Int]?
        public let score: Double?
        public let rank: Int?
    }

    /// infobox 一行：key + value（value 可能是字符串、字符串数组或 {v} 对象数组）
    public struct SubjectInfobox: Codable, Sendable {
        public let key: String?
        public let value: InfoboxValue?
    }

    public indirect enum InfoboxValue: Codable, Sendable {
        case string(String)
        case strings([String])
        case values([String])
        case none

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            if let arr = try? c.decode([String].self) { self = .strings(arr); return }
            if let objs = try? c.decode([InfoboxValueObject].self) {
                self = .values(objs.compactMap { $0.v })
                return
            }
            self = .none
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .strings(let arr): try c.encode(arr)
            case .values(let arr): try c.encode(arr)
            case .none: try c.encodeNil()
            }
        }

        private struct InfoboxValueObject: Codable {
            let v: String?
        }
    }

    public struct SubjectTag: Codable, Sendable {
        public let name: String?
        public let count: Int?
    }

    /// 收藏统计（v0 详情接口）
    public struct CollectionCounts: Codable, Sendable {
        public let wish: Int?
        public let collect: Int?
        public let doing: Int?
        public let onHold: Int?
        public let dropped: Int?

        enum CodingKeys: String, CodingKey {
            case wish, collect, doing, dropped
            case onHold = "on_hold"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            wish = (try? c.decodeIfPresent(Int.self, forKey: .wish)) ?? nil
            collect = (try? c.decodeIfPresent(Int.self, forKey: .collect)) ?? nil
            doing = (try? c.decodeIfPresent(Int.self, forKey: .doing)) ?? nil
            onHold = (try? c.decodeIfPresent(Int.self, forKey: .onHold)) ?? nil
            dropped = (try? c.decodeIfPresent(Int.self, forKey: .dropped)) ?? nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, summary, eps, images, rating, infobox, tags, collection
        case nameCN = "name_cn"
        case airDate = "air_date"
        case totalEpisodes = "total_episodes"
    }

    public init(
        id: Int,
        type: SubjectType?,
        name: String?,
        nameCN: String?,
        summary: String?,
        airDate: String?,
        eps: Int?,
        totalEpisodes: Int?,
        images: SubjectImages?,
        rating: SubjectRating?,
        infobox: [SubjectInfobox]? = nil,
        tags: [SubjectTag]? = nil,
        collection: CollectionCounts? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.nameCN = nameCN
        self.summary = summary
        self.airDate = airDate
        self.eps = eps
        self.totalEpisodes = totalEpisodes
        self.images = images
        self.rating = rating
        self.infobox = infobox
        self.tags = tags
        self.collection = collection
    }

    /// 防御式解析：任何字段类型异常都降级为 nil/0，不中断整个响应
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        type = (try? c.decodeIfPresent(SubjectType.self, forKey: .type)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        nameCN = (try? c.decodeIfPresent(String.self, forKey: .nameCN)) ?? nil
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        airDate = (try? c.decodeIfPresent(String.self, forKey: .airDate)) ?? nil
        eps = (try? c.decodeIfPresent(Int.self, forKey: .eps)) ?? nil
        totalEpisodes = (try? c.decodeIfPresent(Int.self, forKey: .totalEpisodes)) ?? nil
        images = (try? c.decodeIfPresent(SubjectImages.self, forKey: .images)) ?? nil
        rating = (try? c.decodeIfPresent(SubjectRating.self, forKey: .rating)) ?? nil
        infobox = (try? c.decodeIfPresent([SubjectInfobox].self, forKey: .infobox)) ?? nil
        tags = (try? c.decodeIfPresent([SubjectTag].self, forKey: .tags)) ?? nil
        collection = (try? c.decodeIfPresent(CollectionCounts.self, forKey: .collection)) ?? nil
    }
}

/// 单集（GET /v0/episodes）
public struct Episode: Codable, Sendable, Identifiable, ChineseNamed {
    public let id: Int
    public let type: Int?
    public let sort: Double?
    public let ep: Double?
    public let name: String?
    public let nameCN: String?
    public let airdate: String?

    enum CodingKeys: String, CodingKey {
        case id, type, sort, ep, name, airdate
        case nameCN = "name_cn"
    }

    /// 防御式解析
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        type = (try? c.decodeIfPresent(Int.self, forKey: .type)) ?? nil
        sort = (try? c.decodeIfPresent(Double.self, forKey: .sort)) ?? nil
        ep = (try? c.decodeIfPresent(Double.self, forKey: .ep)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        nameCN = (try? c.decodeIfPresent(String.self, forKey: .nameCN)) ?? nil
        airdate = (try? c.decodeIfPresent(String.self, forKey: .airdate)) ?? nil
    }
}

/// 用户对条目的收藏
public struct UserSubjectCollection: Codable, Sendable, Identifiable {
    public var id: Int { subjectID }

    public let subjectID: Int
    public let subjectType: SubjectType?
    public let rate: Int?
    public let type: SubjectCollectionType?
    public let comment: String?
    public let tags: [String]?
    public let epStatus: Int?
    public let volStatus: Int?
    public let updatedAt: Int64?
    public let isPrivate: Bool?
    /// 收藏列表接口通常不含 subject 详情，需要另行补全
    public let subject: Subject?

    public init(
        subjectID: Int,
        subjectType: SubjectType? = nil,
        rate: Int? = nil,
        type: SubjectCollectionType? = nil,
        comment: String? = nil,
        tags: [String]? = nil,
        epStatus: Int? = nil,
        volStatus: Int? = nil,
        updatedAt: Int64? = nil,
        isPrivate: Bool? = nil,
        subject: Subject? = nil
    ) {
        self.subjectID = subjectID
        self.subjectType = subjectType
        self.rate = rate
        self.type = type
        self.comment = comment
        self.tags = tags
        self.epStatus = epStatus
        self.volStatus = volStatus
        self.updatedAt = updatedAt
        self.isPrivate = isPrivate
        self.subject = subject
    }

    /// 补全条目信息时复制
    public init(collection: UserSubjectCollection, subject: Subject) {
        self.init(
            subjectID: collection.subjectID,
            subjectType: collection.subjectType,
            rate: collection.rate,
            type: collection.type,
            comment: collection.comment,
            tags: collection.tags,
            epStatus: collection.epStatus,
            volStatus: collection.volStatus,
            updatedAt: collection.updatedAt,
            isPrivate: collection.isPrivate,
            subject: subject
        )
    }

    enum CodingKeys: String, CodingKey {
        case rate, type, comment, tags, subject
        case subjectID = "subject_id"
        case subjectType = "subject_type"
        case epStatus = "ep_status"
        case volStatus = "vol_status"
        case updatedAt = "updated_at"
        case isPrivate = "private"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subjectID = try c.decode(Int.self, forKey: .subjectID)
        subjectType = try c.decodeIfPresent(SubjectType.self, forKey: .subjectType)
        rate = try c.decodeIfPresent(Int.self, forKey: .rate)
        type = try c.decodeIfPresent(SubjectCollectionType.self, forKey: .type)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
        epStatus = try c.decodeIfPresent(Int.self, forKey: .epStatus)
        volStatus = try c.decodeIfPresent(Int.self, forKey: .volStatus)
        updatedAt = c.decodeLenientInt64(forKey: .updatedAt)
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate)
        subject = try c.decodeIfPresent(Subject.self, forKey: .subject)
    }
}

/// 用户单集收藏
public struct UserEpisodeCollection: Codable, Sendable {
    public let episode: Episode?
    public let type: EpisodeCollectionType?
    public let updatedAt: Int64?

    public init(episode: Episode?, type: EpisodeCollectionType?, updatedAt: Int64?) {
        self.episode = episode
        self.type = type
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case episode, type
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episode = try c.decodeIfPresent(Episode.self, forKey: .episode)
        type = try c.decodeIfPresent(EpisodeCollectionType.self, forKey: .type)
        updatedAt = c.decodeLenientInt64(forKey: .updatedAt)
    }
}

/// 分页包装
public struct Paged<T: Codable & Sendable>: Codable, Sendable {
    public let total: Int?
    public let limit: Int?
    public let offset: Int?
    public let data: [T]
}

/// 修改收藏的请求体（POST /v0/users/-/collections/{subject_id}）
public struct CollectionModifyPayload: Encodable, Sendable {
    public var type: SubjectCollectionType?
    public var rate: Int?
    public var comment: String?
    public var `private`: Bool?
    public var tags: [String]?
    /// 仅书籍条目可用
    public var epStatus: Int?
    /// 仅书籍条目可用
    public var volStatus: Int?

    public init(
        type: SubjectCollectionType? = nil,
        rate: Int? = nil,
        comment: String? = nil,
        private: Bool? = nil,
        tags: [String]? = nil,
        epStatus: Int? = nil,
        volStatus: Int? = nil
    ) {
        self.type = type
        self.rate = rate
        self.comment = comment
        self.`private` = `private`
        self.tags = tags
        self.epStatus = epStatus
        self.volStatus = volStatus
    }

    enum CodingKeys: String, CodingKey {
        case type, rate, comment, tags
        case `private`
        case epStatus = "ep_status"
        case volStatus = "vol_status"
    }
}

// MARK: - 旧版 API 大条目（讨论版/评论/角色/制作人员）

/// 旧版 API 的用户（讨论/评论作者）
public struct LegacyUser: Codable, Sendable {
    public let id: Int?
    public let nickname: String?
    public let username: String?
    public let avatar: Subject.SubjectImages?
    public let sign: String?
}

/// 旧版单集（含分集简介/评论数）
public struct LegacyEpisode: Codable, Sendable, Identifiable, ChineseNamed {
    public let id: Int
    public let type: Int?
    public let sort: Double?
    public let name: String?
    public let nameCN: String?
    public let airdate: String?
    public let duration: String?
    public let comment: Int?
    public let desc: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id, type, sort, name, airdate, duration, comment, desc, status
        case nameCN = "name_cn"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        type = (try? c.decodeIfPresent(Int.self, forKey: .type)) ?? nil
        // sort 兼容 Int / Double
        if let d = try? c.decodeIfPresent(Double.self, forKey: .sort) {
            sort = d
        } else if let i = try? c.decodeIfPresent(Int.self, forKey: .sort) {
            sort = Double(i)
        } else {
            sort = nil
        }
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        nameCN = (try? c.decodeIfPresent(String.self, forKey: .nameCN)) ?? nil
        airdate = (try? c.decodeIfPresent(String.self, forKey: .airdate)) ?? nil
        duration = (try? c.decodeIfPresent(String.self, forKey: .duration)) ?? nil
        comment = (try? c.decodeIfPresent(Int.self, forKey: .comment)) ?? nil
        desc = (try? c.decodeIfPresent(String.self, forKey: .desc)) ?? nil
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
    }
}

/// 讨论版帖子
public struct LegacyTopic: Codable, Sendable, Identifiable {
    public let id: Int
    public let url: String?
    public let title: String?
    public let mainID: Int?
    public let timestamp: Int64?
    public let lastpost: Int64?
    public let replies: Int?
    public let user: LegacyUser?

    enum CodingKeys: String, CodingKey {
        case id, url, title, timestamp, lastpost, replies, user
        case mainID = "main_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        mainID = (try? c.decodeIfPresent(Int.self, forKey: .mainID)) ?? nil
        timestamp = c.decodeLenientInt64(forKey: .timestamp)
        lastpost = c.decodeLenientInt64(forKey: .lastpost)
        replies = (try? c.decodeIfPresent(Int.self, forKey: .replies)) ?? nil
        user = (try? c.decodeIfPresent(LegacyUser.self, forKey: .user)) ?? nil
    }
}

/// 评论日志（短评/评语）
public struct LegacyBlog: Codable, Sendable, Identifiable {
    public let id: Int
    public let url: String?
    public let title: String?
    public let summary: String?
    public let image: String?
    public let replies: Int?
    public let timestamp: Int64?
    public let dateline: String?
    public let user: LegacyUser?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        image = (try? c.decodeIfPresent(String.self, forKey: .image)) ?? nil
        replies = (try? c.decodeIfPresent(Int.self, forKey: .replies)) ?? nil
        timestamp = c.decodeLenientInt64(forKey: .timestamp)
        dateline = (try? c.decodeIfPresent(String.self, forKey: .dateline)) ?? nil
        user = (try? c.decodeIfPresent(LegacyUser.self, forKey: .user)) ?? nil
    }
}

/// 角色
public struct LegacyCharacter: Codable, Sendable, Identifiable, ChineseNamed {
    public let id: Int
    public let url: String?
    public let name: String?
    public let nameCN: String?
    public let roleName: String?
    public let images: Subject.SubjectImages?

    enum CodingKeys: String, CodingKey {
        case id, url, name, images
        case nameCN = "name_cn"
        case roleName = "role_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        nameCN = (try? c.decodeIfPresent(String.self, forKey: .nameCN)) ?? nil
        roleName = (try? c.decodeIfPresent(String.self, forKey: .roleName)) ?? nil
        images = (try? c.decodeIfPresent(Subject.SubjectImages.self, forKey: .images)) ?? nil
    }
}

/// 制作人员
public struct LegacyStaff: Codable, Sendable, Identifiable, ChineseNamed {
    public let id: Int
    public let url: String?
    public let name: String?
    public let nameCN: String?
    public let roleName: String?
    /// 职位（旧版接口在 jobs 数组里，如 ["导演"]）
    public let jobs: [String]?
    public let images: Subject.SubjectImages?

    enum CodingKeys: String, CodingKey {
        case id, url, name, images, jobs
        case nameCN = "name_cn"
        case roleName = "role_name"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        nameCN = (try? c.decodeIfPresent(String.self, forKey: .nameCN)) ?? nil
        roleName = (try? c.decodeIfPresent(String.self, forKey: .roleName)) ?? nil
        jobs = (try? c.decodeIfPresent([String].self, forKey: .jobs)) ?? nil
        images = (try? c.decodeIfPresent(Subject.SubjectImages.self, forKey: .images)) ?? nil
    }
}

/// 旧版大条目（GET /subject/{id}?responseGroup=large）
/// 一次返回：eps（集数）/ topic（讨论版）/ blog（评论日志）/ crt（角色）/ staff（制作人员）
public struct LegacySubject: Codable, Sendable {
    public let id: Int
    public let type: Int?
    public let name: String?
    public let nameCN: String?
    public let summary: String?
    public let images: Subject.SubjectImages?
    public let rating: LegacyRating?
    public let rank: Int?
    public let collection: Subject.CollectionCounts?
    public let eps: [LegacyEpisode]?
    public let topic: [LegacyTopic]?
    public let blog: [LegacyBlog]?
    public let crt: [LegacyCharacter]?
    public let staff: [LegacyStaff]?

    public struct LegacyRating: Codable, Sendable {
        public let total: Int?
        /// 旧版评分分布是字典（"10": 3059, ...），与 v0 的数组不同
        public let count: [String: Int]?
        public let score: Double?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? nil
            if let dict = try? c.decodeIfPresent([String: Int].self, forKey: .count) {
                count = dict
            } else {
                count = nil
            }
            score = (try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, summary, images, rating, rank, collection, eps, topic, blog, crt, staff
        case nameCN = "name_cn"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        type = (try? c.decodeIfPresent(Int.self, forKey: .type)) ?? nil
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil
        nameCN = (try? c.decodeIfPresent(String.self, forKey: .nameCN)) ?? nil
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? nil
        images = (try? c.decodeIfPresent(Subject.SubjectImages.self, forKey: .images)) ?? nil
        rating = (try? c.decodeIfPresent(LegacyRating.self, forKey: .rating)) ?? nil
        rank = (try? c.decodeIfPresent(Int.self, forKey: .rank)) ?? nil
        collection = (try? c.decodeIfPresent(Subject.CollectionCounts.self, forKey: .collection)) ?? nil
        eps = (try? c.decodeIfPresent([LegacyEpisode].self, forKey: .eps)) ?? nil
        topic = (try? c.decodeIfPresent([LegacyTopic].self, forKey: .topic)) ?? nil
        blog = (try? c.decodeIfPresent([LegacyBlog].self, forKey: .blog)) ?? nil
        crt = (try? c.decodeIfPresent([LegacyCharacter].self, forKey: .crt)) ?? nil
        staff = (try? c.decodeIfPresent([LegacyStaff].self, forKey: .staff)) ?? nil
    }
}

// MARK: - 名称回退（Bangumi 会把 name_cn 返回成空字符串）

/// 去掉首尾空白后仍非空才算有效名称。
/// Bangumi 的 `name_cn` 对尚无中文名的条目会返回 **空字符串 `""`**（不是 nil），
/// 因此 `nameCN ?? name` 这种写法会把空串当成有效值，渲染出空白名称。
public func firstNonEmptyName(_ candidates: String?...) -> String? {
    for candidate in candidates {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { continue }
        return trimmed
    }
    return nil
}

/// 拥有 `name` / `nameCN` 的条目模型：统一的展示名回退规则。
///
/// ⚠️ 一律用 `displayName`，不要写 `nameCN ?? name`。
/// 实测反例：条目 454684「BanG Dream! Ave Mujica」返回
/// `name_cn = ""`、`name = "BanG Dream! Ave Mujica"`，用 `??` 会显示空白。
public protocol ChineseNamed {
    var name: String? { get }
    var nameCN: String? { get }
}

public extension ChineseNamed {
    /// 中文名优先（空串视为缺失），否则原名，都没有则空串
    var displayName: String {
        firstNonEmptyName(nameCN, name) ?? ""
    }
}

public extension Subject {
    /// 用于显示「共 N 集 / 进度 x/N」的总集数。
    ///
    /// ⚠️ **收藏列表接口只有 `eps`，没有 `total_episodes`**（实测：
    /// `/v0/users/{u}/collections` 的 subject 是 `eps=13`、`total_episodes` 缺失；
    /// `/v0/subjects/{id}` 两者都有）。所以只读 `totalEpisodes` 会显示成 0 集。
    /// 这里回退到 `eps`，列表一出来即显示正确集数；详情接口拉到
    /// `total_episodes` 后（见 AccountViewModel 的后台补全）会更新为权威值。
    var episodeCount: Int? {
        totalEpisodes ?? eps
    }
}

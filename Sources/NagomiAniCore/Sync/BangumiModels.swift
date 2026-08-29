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

/// 条目（GET /v0/subjects/{id}）
public struct Subject: Codable, Sendable, Identifiable {
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

    public struct SubjectImages: Codable, Sendable {
        public let large: String?
        public let common: String?
        public let medium: String?
        public let small: String?
        public let grid: String?
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
public struct Episode: Codable, Sendable, Identifiable {
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
public struct LegacyEpisode: Codable, Sendable, Identifiable {
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
public struct LegacyCharacter: Codable, Sendable, Identifiable {
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
public struct LegacyStaff: Codable, Sendable, Identifiable {
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

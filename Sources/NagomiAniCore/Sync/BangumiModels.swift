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

    enum CodingKeys: String, CodingKey {
        case id, type, name, summary, eps, images, rating
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
        rating: SubjectRating?
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

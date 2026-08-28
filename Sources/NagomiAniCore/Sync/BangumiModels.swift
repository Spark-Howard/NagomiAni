import Foundation

// MARK: - 枚举

/// 条目类型
public enum SubjectType: Int, Codable, Sendable {
    case book = 1
    case anime = 2
    case music = 3
    case game = 4
    case real = 6
}

/// 收藏类型
public enum SubjectCollectionType: Int, Codable, Sendable {
    case wish = 1      // 想看
    case collected = 2 // 看过
    case doing = 3     // 在看
    case onHold = 4    // 搁置
    case dropped = 5   // 抛弃
}

/// 单集收藏类型
public enum EpisodeCollectionType: Int, Codable, Sendable {
    case none = 0
    case wish = 1     // 想看
    case watched = 2  // 看过
    case dropped = 3  // 抛弃
}

/// 章节类型
public enum EpType: Int, Codable, Sendable {
    case main = 0     // 本篇
    case special = 1  // SP
    case opening = 2  // OP
    case ending = 3   // ED
    case mad = 4
    case other = 5
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
public struct Subject: Codable, Sendable {
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
    public let subject: Subject?

    enum CodingKeys: String, CodingKey {
        case rate, type, comment, tags, subject
        case subjectID = "subject_id"
        case subjectType = "subject_type"
        case epStatus = "ep_status"
        case volStatus = "vol_status"
        case updatedAt = "updated_at"
        case isPrivate = "private"
    }
}

/// 用户单集收藏
public struct UserEpisodeCollection: Codable, Sendable {
    public let episode: Episode?
    public let type: EpisodeCollectionType?
    public let updatedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case episode, type
        case updatedAt = "updated_at"
    }
}

/// 分页包装
public struct Paged<T: Codable & Sendable>: Codable, Sendable {
    public let total: Int?
    public let limit: Int?
    public let offset: Int?
    public let data: [T]
}

/// 修改收藏的请求体（POST/PATCH /v0/users/-/collections/{subject_id}）
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

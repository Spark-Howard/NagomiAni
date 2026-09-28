import Foundation

/// 放送日历里的一部番（Bangumi 元数据：正题 + 封面）
public struct CalendarSubject: Sendable, Equatable {
    public let id: Int
    public let title: String
    public let coverURL: String?

    public init(id: Int, title: String, coverURL: String? = nil) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
    }
}

/// 放送日历 × 资源站聚合器（纯函数，可单测）。
///
/// 在线页默认目录 = **Bangumi 过去一周放送的番**（不是资源站最新列表的堆砌）：
/// 对日历里的每部番，在"各站最新动漫池"里按标题相似度找一个片源，
/// **每部番只保留一个条目、一个片源**；没找到片源的番不出现（可用搜索兜底）。
/// 展示用 Bangumi 的正题与封面，流地址来自被选中的站点条目。
public enum WeeklyAggregator {
    /// 标题相似度达标才算"找到了片源"
    static let matchThreshold = 0.4
    /// 季度一致的小加分（放送中的番与资源站最近更新的多为同一季）
    static let seasonBonus = 0.05

    /// - Parameters:
    ///   - calendar: 放送日历摊平后的番（已按 subjectID 去重）
    ///   - pool: 各资源站的最新动漫条目（按站点优先级排序）
    /// - Returns: 每部放送中的番一个条目（Bangumi 标题/封面 + 命中站点的流）
    public static func aggregate(calendar: [CalendarSubject], pool: [OnlineShow]) -> [OnlineShow] {
        // 1) 池内去重：归一化标题相同 → 只留第一个（传入顺序即站点优先级）
        var seenTitles: Set<String> = []
        var uniquePool: [OnlineShow] = []
        for show in pool {
            let key = normalize(show.title)
            guard !key.isEmpty, !seenTitles.contains(key) else { continue }
            seenTitles.insert(key)
            uniquePool.append(show)
        }

        // 2) 日历逐部选最佳片源；一个池条目只服务一部番
        var usedPoolIDs: Set<String> = []
        var result: [OnlineShow] = []
        for subject in calendar {
            guard let match = bestMatch(subject, in: uniquePool.filter { !usedPoolIDs.contains($0.id) }) else { continue }
            usedPoolIDs.insert(match.show.id)
            result.append(Self.makeEntry(subject: subject, source: match.show))
        }
        return result
    }

    /// 为一部放送番在候选池里选最佳片源（标题相似度阈值 + 同季加分）；找不到返回 nil
    public static func bestMatch(_ subject: CalendarSubject, in candidates: [OnlineShow]) -> (show: OnlineShow, score: Double)? {
        var best: (show: OnlineShow, score: Double)?
        for candidate in candidates {
            // ⚠️ 相似度比较必须用清洗后的候选标题：资源站标题普遍带
            // [字幕组]/[1080p] 标签，不清洗则永远匹配不上 Bangumi 正题
            var score = TitleSimilarity.similarity(subject.title, normalize(candidate.title))
            if let calendarSeason = MediaMatching.seasonNumber(from: subject.title),
               let poolSeason = MediaMatching.seasonNumber(from: candidate.title),
               calendarSeason == poolSeason {
                score += seasonBonus
            }
            if score >= matchThreshold, score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }
        return best
    }

    /// 聚合条目：Bangumi 正题/封面/subjectID + 命中站点的流
    public static func makeEntry(subject: CalendarSubject, source: OnlineShow) -> OnlineShow {
        OnlineShow(
            providerID: source.providerID,
            showID: source.showID,
            title: subject.title,
            subtitle: source.subtitle,
            coverURL: subject.coverURL,
            bangumiSubjectID: subject.id
        )
    }

    /// 标题归一化：清洗字幕组/画质标签 + 相似度的空白标点归一
    static func normalize(_ title: String) -> String {
        TitleSimilarity.normalize(BangumiMatcher.cleanTitle(title))
    }
}

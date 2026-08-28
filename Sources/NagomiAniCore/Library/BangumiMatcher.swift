import Foundation

// MARK: - 标题相似度（纯函数）

/// 标题相似度计算
public enum TitleSimilarity {

    /// 归一化：小写、去空白与常见标点
    public static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .replacingOccurrences(
                of: "[\\[\\]()（）【】\"'\\-_&:：，,。.!！?？、/\\\\|]",
                with: "",
                options: .regularExpression
            )
    }

    /// 相似度：0~1。完全相等为 1，其次用二元组 Dice 系数；包含关系给高分
    /// （包含加分为防误伤，要求包含串长度 ≥ 4）
    public static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        var score = dice(na, nb)
        let contained = (nb.count >= 4 && na.contains(nb)) || (na.count >= 4 && nb.contains(na))
        if contained {
            score = max(score, 0.85)
        }
        return score
    }

    private static func dice(_ a: String, _ b: String) -> Double {
        let ga = bigrams(a)
        let gb = bigrams(b)
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        let intersection = ga.intersection(gb).count
        return 2.0 * Double(intersection) / Double(ga.count + gb.count)
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count > 1 else { return Set(chars.map(String.init)) }
        return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
    }
}

// MARK: - 匹配结果

/// 候选条目
public struct MatchCandidate: Identifiable, Sendable {
    public var id: Int { subject.id }
    public let subject: Subject
    public let score: Double
}

public enum MatchResult: Sendable {
    case matched(MatchCandidate)
    case pending([MatchCandidate])
    case unmatched
}

// MARK: - 自动匹配器

/// Bangumi 自动匹配：清洗标题 → 搜索 → 评分 → 三态结果
public final class BangumiMatcher: @unchecked Sendable {
    /// 高分自动确认
    public let autoThreshold: Double = 0.55
    /// 中分进入待确认
    public let pendingThreshold: Double = 0.35

    private let client: BangumiClient

    public init(client: BangumiClient) {
        self.client = client
    }

    /// 对一部番执行匹配（基于候选列表做三态判定）
    public func match(series: Series) async throws -> MatchResult {
        let cands = try await candidates(series: series, limit: 5)
        guard let best = cands.first else { return .unmatched }
        if best.score >= autoThreshold {
            return .matched(best)
        }
        if best.score >= pendingThreshold {
            return .pending(cands)
        }
        return .unmatched
    }

    /// 获取按名称搜索出的候选列表（按评分降序，按 subject.id 去重）
    /// 供"导入后根据名字提供关联建议"使用
    public func candidates(series: Series, limit: Int = 5) async throws -> [MatchCandidate] {
        let hint = Self.seriesHint(from: series)
        var titles = Self.searchTitles(series: series)

        // 跨语言扩展：中文名 → 英文 / 英文名 → 中文（借助翻译），提高命中率
        if let primary = titles.first {
            let target = TitleTranslator.containsCJK(primary) ? "en" : "zh-CN"
            if let translated = await TitleTranslator.translate(primary, to: target),
               !titles.contains(translated) {
                titles.insert(translated, at: 1)
            }
        }

        var bestByID: [Int: MatchCandidate] = [:]

        // 本地季号：优先从文件名众数推导，目录名兜底
        let localSeason = hint.season

        for title in titles.prefix(3) {
            let page = try await client.searchSubjects(keyword: title, limit: 20)
            for subject in page.data {
                // 客户端过滤：只看动画（搜索接口不带 type 过滤时可能混入书籍/音乐等）
                guard subject.type == .anime || subject.type == nil else { continue }
                let score = Self.score(
                    subject: subject,
                    against: title,
                    fileCount: series.files.count,
                    localSeason: localSeason
                )
                // 门槛放低：跨语言候选分数天然偏低，先展示出来让用户挑选
                guard score >= 0.1 else { continue }
                let candidate = MatchCandidate(subject: subject, score: score)
                if let existing = bestByID[subject.id] {
                    if score > existing.score {
                        bestByID[subject.id] = candidate
                    }
                } else {
                    bestByID[subject.id] = candidate
                }
            }
            // 当前标题已有够好的候选，不再搜更多关键词（减少请求量）
            if bestByID.values.contains(where: { $0.score >= pendingThreshold }) {
                break
            }
        }

        return bestByID.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// 从系列的视频文件名推导匹配标题与季号（文件名比目录名可靠）：
    /// 取所有文件清洗后标题的众数，季号同样取众数；目录名仅作兜底。
    public static func seriesHint(from series: Series) -> (title: String, season: Int?) {
        var titleCounts: [String: Int] = [:]
        var seasonCounts: [Int: Int] = [:]
        for file in series.files {
            let title = MediaMatching.titleHint(from: file.fileName)
            if !title.isEmpty {
                titleCounts[title, default: 0] += 1
            }
            if let season = MediaMatching.seasonNumber(from: file.fileName) {
                seasonCounts[season, default: 0] += 1
            }
        }
        let title = titleCounts.max { $0.value < $1.value }?.key
            ?? MediaMatching.baseTitle(from: cleanTitle(series.displayName))
        let season = seasonCounts.max { $0.value < $1.value }?.key
            ?? MediaMatching.seasonNumber(from: series.displayName)
        return (title, season)
    }

    /// 生成搜索关键词：
    /// 优先用文件名推导出的标题（去季/集/标签）；目录名仅作兜底；再加去空格变体
    public static func searchTitles(series: Series) -> [String] {
        let hint = seriesHint(from: series)
        var result: [String] = []

        if !hint.title.isEmpty {
            result.append(hint.title)
        }

        let folderBase = MediaMatching.baseTitle(from: cleanTitle(series.displayName))
        if !folderBase.isEmpty, folderBase != hint.title, !result.contains(folderBase) {
            result.append(folderBase)
        }

        let noSpace = hint.title.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        if noSpace != hint.title, !noSpace.isEmpty, !result.contains(noSpace) {
            result.append(noSpace)
        }

        return result
    }

    /// 清洗标题中的 [] 标签与常见画质/编码/语言标签
    public static func cleanTitle(_ raw: String) -> String {
        var t = raw
        t = t.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(
            of: "(?i)(2160p|1080p|720p|480p|4k|x264|x265|h264|h265|hevc|avc|aac|flac|10bit|bdrip|webrip|web-dl|dvdrip|tvrip|bluray|remux|jpn|chs|cht|big5|简日|繁日|简体|繁体|内嵌|外挂|合集)",
            with: "",
            options: .regularExpression
        )
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 评分：标题相似度 + 集数佐证 + 季度判定（纯函数，可测）
    /// localSeason 为本地文件识别出的季号（nil 表示未知）
    public static func score(subject: Subject, against title: String, fileCount: Int, localSeason: Int? = nil) -> Double {
        var score = max(
            TitleSimilarity.similarity(subject.nameCN ?? "", title),
            TitleSimilarity.similarity(subject.name ?? "", title)
        )
        if let total = subject.totalEpisodes, total > 0 {
            if abs(total - fileCount) <= 2 {
                score += 0.12 // 集数吻合，加分
            } else if fileCount > total + 2 {
                score -= 0.2 // 文件比条目集数多太多，很可能是另一部（或另一季）
            }
        }
        // 季度判定：Bangumi 每季是独立条目，S1/S2/0/续 要匹配对应的季
        if let localSeason {
            let subjectName = subject.nameCN ?? subject.name ?? ""
            let subjectSeason = MediaMatching.seasonNumber(from: subjectName)
            if let subjectSeason {
                if subjectSeason == localSeason {
                    score += 0.25
                } else {
                    score -= 0.35
                }
            }
        }
        return min(max(score, 0), 1)
    }
}

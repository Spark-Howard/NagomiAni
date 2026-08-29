import Foundation

/// 从文件名解析"集数"与"系列键"，用于 Bangumi 自动同步
public enum MediaMatching {

    /// 解析结果：集数（可能没有）与系列键（用于记住文件属于哪个条目）
    public static func parse(fileName: String) -> (episodeNumber: Int?, seriesKey: String) {
        let name = (fileName as NSString).deletingPathExtension
        return (episodeNumber(from: name), seriesKey(from: name))
    }

    // MARK: - 集数

    public static func episodeNumber(from name: String) -> Int? {
        // 分层解析（按优先级）：
        // 1) 季集式：S01E03 / S1E3 / S2 01 / S2-01（S 开头、季+集）
        // 2) EP 式：EP03 / EP.3 / ep 12 / E03（单 E）
        // 3) 话数式：第3话 / 第03話 / 第 12 集
        // 4) 符号式：#03 / - 01 [标签] / - 04（结尾）/ [01]
        // 5) 裸数字式：01.mkv / 01 - 标题 / 03v2（v 修正版）
        let patterns = [
            "[Ss]\\d{1,2}\\s*[Ee]\\s*0*(\\d{1,3})\\b",       // S01E03 / S1E3 / S01 E03
            "[Ss]\\d{1,2}\\s*[._-]?\\s*0*(\\d{1,3})(?!\\d)",  // S2 01 / S2.01 / S2-01（季+空格+集）
            "\\b[Ee][Pp]\\.?\\s*0*(\\d{1,3})\\b",             // EP03 / EP.3 / ep 12
            "\\b[Ee]\\s*0*(\\d{1,3})\\b",                     // E03（欧美组单 E 格式）
            "第\\s*0*(\\d{1,3})\\s*[话話集]",                  // 第3话 / 第03話 / 第 12 集
            "#\\s*0*(\\d{1,3})\\b",                           // #03
            "\\s-\\s*0*(\\d{1,3})(?!\\d)(?=\\s*\\[|\\s*$)",   // - 01 [1080p] / - 03.mkv（排除年份）
            "\\[\\s*0*(\\d{1,3})\\s*\\]",                     // [01]
            "^0*(\\d{1,3})(?:v\\d+)?$",                       // 纯数字：01.mkv / 03v2.mkv
            "^0*(\\d{1,2})(?!\\d)\\s*[-.\\s]",                // 数字开头：01 - 标题（排除年份）
            "\\b0*(\\d{1,3})v\\d+(?=\\s*\\[|\\s*$)",          // 03v2 [1080p]（v 修正版）
        ]
        for pattern in patterns {
            if let value = matchGroup1(pattern, in: name) {
                return value
            }
        }
        return nil
    }

    // MARK: - 系列键（去掉集数/标签后的文件名，用于聚合与记忆关联）

    public static func seriesKey(from name: String) -> String {
        var key = name
        let removes = [
            "[Ss]\\d{1,2}\\s*[Ee]\\s*0*\\d{1,3}\\b",
            "[Ss]\\d{1,2}\\s*[._-]?\\s*0*\\d{1,3}(?!\\d)",
            "\\b[Ee][Pp]\\.?\\s*0*\\d{1,3}\\b",
            "\\b[Ee]\\s*0*\\d{1,3}\\b",
            "第\\s*0*\\d{1,3}\\s*[话話集]",
            "#\\s*0*\\d{1,3}\\b",
            "\\s-\\s*0*\\d{1,3}(?!\\d)(?=\\s*\\[|\\s*$)",
            "\\[\\s*0*\\d{1,3}\\s*\\]",
            "\\b0*\\d{1,3}v\\d+(?=\\s*\\[|\\s*$)",
        ]
        for pattern in removes {
            key = key.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        // 去掉所有 [] 标签（字幕组/画质等），使不同字幕组的同一部番能聚合
        key = key.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        // 去掉常见画质/编码/语言标签
        let tags = [
            "2160p", "1080p", "720p", "480p", "4k",
            "x264", "x265", "h264", "h265", "hevc", "avc", "aac", "flac", "10bit",
            "bdrip", "webrip", "web-dl", "dvdrip", "tvrip", "bluray", "remux",
            "jpn", "chs", "cht", "gb", "big5", "简日", "繁日", "简体", "繁体", "内嵌", "外挂", "合集",
        ]
        for tag in tags {
            key = key.replacingOccurrences(
                of: tag,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return key.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 季度识别（Bangumi 每季是独立条目）

    /// 从名称中识别季号（S1 / Season 2 / 第3季 / 第二季 / Part 2 / 末尾罗马数字 / 末尾 0 / 续）
    public static func seasonNumber(from name: String) -> Int? {
        if let v = matchGroup1("[Ss]\\s*0*(\\d{1,2})\\b", in: name) { return v }
        if let v = matchGroup1("(?i)season\\s*0*(\\d{1,2})", in: name) { return v }
        if let v = matchGroup1("第\\s*0*(\\d{1,2})\\s*季", in: name) { return v }
        if let v = matchGroup1("(?i)part\\s*0*(\\d{1,2})", in: name) { return v }
        if let v = chineseNumeralSeason(from: name) { return v }
        if let v = romanNumeralSeason(from: name) { return v }
        // 续作启发式：末尾 0（命运石之门0）或含"续" → 视为第 2 季
        if name.range(of: "(?<=[^0-9])0\\s*$", options: .regularExpression) != nil { return 2 }
        if name.contains("续") { return 2 }
        return nil
    }

    /// 去掉季度标记，得到基础标题（用于搜索：Bangumi 第 1 季条目名通常就是基础名）
    public static func baseTitle(from name: String) -> String {
        var title = name
        let patterns = [
            "\\s*[Ss]\\s*0*\\d{1,2}\\b",
            "(?i)\\s*season\\s*0*\\d{1,2}",
            "\\s*第\\s*0*\\d{1,2}\\s*季",
            "\\s*第[一二三四五六七八九十]+季",
            "(?i)\\s*part\\s*0*\\d{1,2}",
            "\\s*(I{1,3}|IV|V|VI{0,3}|IX|X)$",
            "(?<=[^0-9])0\\s*$",
            "\\s*续",
        ]
        for pattern in patterns {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private static func chineseNumeralSeason(from name: String) -> Int? {
        guard let range = name.range(of: "第[一二三四五六七八九十]+季", options: .regularExpression) else {
            return nil
        }
        let sub = String(name[range])
        let map: [Character: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
        ]
        var total = 0
        for char in sub {
            guard let value = map[char] else { continue }
            if value == 10 {
                total = total == 0 ? 10 : total * 10
            } else {
                total = total >= 10 ? 10 + value : value
            }
        }
        return total == 0 ? nil : total
    }

    private static func romanNumeralSeason(from name: String) -> Int? {
        guard let range = name.range(of: "\\s(I{1,3}|IV|V|VI{0,3}|IX|X)$", options: .regularExpression) else {
            return nil
        }
        let roman = String(name[range]).trimmingCharacters(in: .whitespaces)
        let map: [String: Int] = [
            "I": 1, "II": 2, "III": 3, "IV": 4, "V": 5,
            "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10,
        ]
        return map[roman]
    }

    /// 从单个视频文件名推导匹配用标题（去掉季/集/标签）
    /// 用户一般不改文件名，下载默认名较准确，因此匹配优先用它
    public static func titleHint(from fileName: String) -> String {
        let parsed = parse(fileName: fileName)
        var title = baseTitle(from: parsed.seriesKey)
        // 去除可能残留的集数尾缀（如 "命运石之门 01"、"86 - 01"）
        let tailPatterns = ["\\s*[-—–]\\s*\\d{1,3}\\s*$", "\\s*\\d{1,3}\\s*$"]
        for pattern in tailPatterns {
            let stripped = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            if !stripped.isEmpty {
                title = stripped
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 私有

    private static func matchGroup1(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return Int(ns.substring(with: range))
    }
}

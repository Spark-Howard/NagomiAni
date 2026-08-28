import Foundation

/// 跨语言标题翻译（借助免费翻译服务生成英文/中文搜索词）
///
/// 用途：本地文件夹名是英文（如 "Initial D"）时，Bangumi 条目可能是中文名（头文字D），
/// 直接搜索英文可能命中不了；翻译成中文后再搜一次，提高匹配率。
/// 说明：使用谷歌非官方翻译接口（无密钥），超时短、失败静默降级，不影响主流程。
public enum TitleTranslator {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    /// 文本是否包含中文（用于判断翻译方向）
    public static func containsCJK(_ text: String) -> Bool {
        text.range(of: "\\p{Han}", options: .regularExpression) != nil
    }

    /// 翻译文本到目标语言；失败/无变化返回 nil
    public static func translate(_ text: String, to target: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: trimmed),
        ]
        guard let url = comps.url else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = json.first as? [Any] else {
                return nil
            }
            var result = ""
            for segment in segments {
                if let part = (segment as? [Any])?.first as? String {
                    result += part
                }
            }
            let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !translated.isEmpty, translated.lowercased() != trimmed.lowercased() else {
                return nil
            }
            return translated
        } catch {
            return nil
        }
    }
}

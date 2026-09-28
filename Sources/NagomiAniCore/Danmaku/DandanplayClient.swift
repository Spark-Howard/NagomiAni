import CryptoKit
import Foundation

/// 弹弹play 开放 API 凭据（用户在弹弹play「设置 → 开放平台」免费申请）
public struct DanmakuCredentials: Sendable, Equatable {
    public let appId: String
    public let appSecret: String

    public var isConfigured: Bool { !appId.isEmpty && !appSecret.isEmpty }

    public init(appId: String, appSecret: String) {
        self.appId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appSecret = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 弹弹play 匹配到的一集
public struct DanmakuEpisodeInfo: Sendable, Equatable {
    public let episodeId: Int
    public let animeTitle: String
    public let episodeTitle: String

    public init(episodeId: Int, animeTitle: String, episodeTitle: String) {
        self.episodeId = episodeId
        self.animeTitle = animeTitle
        self.episodeTitle = episodeTitle
    }
}

public enum DanmakuError: LocalizedError, Equatable {
    case notConfigured
    case badResponse
    case notMatched
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置弹弹play 凭据（AppId/AppSecret）"
        case .badResponse: return "弹幕服务器返回了无法解析的数据"
        case .notMatched: return "未在弹幕库中找到匹配的剧集"
        case .httpStatus(let code): return "弹幕服务器请求失败（HTTP \(code)）"
        }
    }
}

/// 弹弹play v2 API 客户端（签名请求 + 剧集匹配 + 弹幕拉取）。
///
/// 签名协议（弹弹play 开放平台官方规范）：
/// `X-Signature = BASE64(SHA256(AppId + Timestamp + Path + AppSecret))`
/// —— 普通 SHA256（非 HMAC），AppSecret 拼在串尾，不含 HTTP Method。
/// 仓库不内置任何凭据，凭据由用户在设置中填入。
public final class DandanplayClient: @unchecked Sendable {
    private let credentials: DanmakuCredentials
    private let session: URLSession
    /// API 端点。官方为 https://api.dandanplay.net；若凭据来自第三方兼容服务，
    /// 构造时传入其地址（协议相同，仅域名不同）
    private let baseURL: String

    public init(credentials: DanmakuCredentials, session: URLSession = URLSession.shared,
                baseURL: String = "https://api.dandanplay.net") {
        self.credentials = credentials
        self.session = session
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\r\t"))
        self.baseURL = trimmed.isEmpty ? "https://api.dandanplay.net" : trimmed
    }

    // MARK: - API

    /// 按剧名搜索剧集（在线番：剧名 → 剧集列表，按集号选 episodeId）
    public func searchEpisodes(anime: String) async throws -> [DanmakuEpisodeInfo] {
        let request = try signedRequest(
            method: "GET", path: "/api/v2/search/episodes",
            query: [("anime", anime)]
        )
        return try Self.parseSearchEpisodes(try await send(request))
    }

    /// 本地文件匹配（文件名 + 头 16MB MD5 + 大小）
    public func match(fileName: String, fileHash: String, fileSize: Int) async throws -> DanmakuEpisodeInfo {
        let request = try signedRequest(
            method: "POST", path: "/api/v2/match",
            json: ["fileName": fileName, "fileHash": fileHash.uppercased(), "fileSize": fileSize]
        )
        return try Self.parseMatch(try await send(request))
    }

    /// 拉取弹幕（withRelated 合并关联集，chConvert=1 简体化）
    public func comments(episodeId: Int) async throws -> [DanmakuComment] {
        let request = try signedRequest(
            method: "GET", path: "/api/v2/comment/\(episodeId)",
            query: [("withRelated", "true"), ("chConvert", "1")]
        )
        return try Self.parseComments(try await send(request))
    }

    // MARK: - 请求与签名

    private func signedRequest(
        method: String, path: String, query: [(String, String)] = [], json: [String: Any]? = nil
    ) throws -> URLRequest {
        guard credentials.isConfigured else { throw DanmakuError.notConfigured }
        guard var comps = URLComponents(string: baseURL + path) else {
            throw DanmakuError.badResponse
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = comps.url else { throw DanmakuError.badResponse }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(credentials.appId, forHTTPHeaderField: "X-AppId")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(
            Self.signature(appId: credentials.appId, appSecret: credentials.appSecret,
                           timestamp: timestamp, path: path),
            forHTTPHeaderField: "X-Signature"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DanmakuError.httpStatus(http.statusCode)
        }
        return data
    }

    /// X-Signature = BASE64(SHA256(AppId + Timestamp + Path + AppSecret))（官方规范）
    public static func signature(
        appId: String, appSecret: String, timestamp: String, path: String
    ) -> String {
        let digest = SHA256.hash(data: Data("\(appId)\(timestamp)\(path)\(appSecret)".utf8))
        return Data(digest).base64EncodedString()
    }

    // MARK: - 解析（静态纯函数，可单测）

    /// {"animes":[{"animeId":..,"animeTitle":"..","episodes":[{"episodeId":..,"episodeTitle":".."}]}]}
    static func parseSearchEpisodes(_ data: Data) throws -> [DanmakuEpisodeInfo] {
        let root = try? JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any],
              let animes = dict["animes"] as? [[String: Any]] else { throw DanmakuError.badResponse }
        var result: [DanmakuEpisodeInfo] = []
        for anime in animes {
            let animeTitle = anime["animeTitle"] as? String ?? ""
            for episode in anime["episodes"] as? [[String: Any]] ?? [] {
                guard let episodeId = scalarInt(episode["episodeId"]) else { continue }
                result.append(DanmakuEpisodeInfo(
                    episodeId: episodeId,
                    animeTitle: animeTitle,
                    episodeTitle: episode["episodeTitle"] as? String ?? ""
                ))
            }
        }
        return result
    }

    /// {"isMatched":true,"matches":[{"episodeId":..,"animeTitle":"..","episodeTitle":".."}]}
    static func parseMatch(_ data: Data) throws -> DanmakuEpisodeInfo {
        let root = try? JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any],
              let matches = dict["matches"] as? [[String: Any]], let first = matches.first else {
            throw DanmakuError.notMatched
        }
        guard let episodeId = scalarInt(first["episodeId"]) else { throw DanmakuError.badResponse }
        return DanmakuEpisodeInfo(
            episodeId: episodeId,
            animeTitle: first["animeTitle"] as? String ?? "",
            episodeTitle: first["episodeTitle"] as? String ?? ""
        )
    }

    /// {"count":N,"comments":[{"cid":..,"p":"12.3,1,16777215,[dandanplay]","m":"文本"}]}
    static func parseComments(_ data: Data) throws -> [DanmakuComment] {
        let root = try? JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any],
              let entries = dict["comments"] as? [[String: Any]] else { throw DanmakuError.badResponse }
        return entries.compactMap { entry in
            guard let p = entry["p"] as? String,
                  let text = entry["m"] as? String, !text.isEmpty else { return nil }
            return comment(fromP: p, text: text)
        }
    }

    /// p 字段："时间秒,模式,颜色,[来源]"；模式 1=滚动 4=底部 5=顶部
    static func comment(fromP p: String, text: String) -> DanmakuComment? {
        let parts = p.split(separator: ",").map(String.init)
        guard parts.count >= 3,
              let time = Double(parts[0]),
              let modeRaw = Int(parts[1]),
              let color = UInt32(parts[2]) else { return nil }
        return DanmakuComment(time: time, mode: DanmakuMode(rawValue: modeRaw) ?? .scroll,
                              color: color, text: text)
    }

    /// 数字/字符串形式的标量统一转 Int
    private static func scalarInt(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as Int64: return Int(n)
        case let d as Double: return d == d.rounded() ? Int(d) : nil
        case let s as String: return Int(s)
        default: return nil
        }
    }

    // MARK: - 本地文件指纹

    /// 本地文件头 16MB 的 MD5（弹弹play 匹配协议）
    public static func fileHash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 16 * 1024 * 1024)
        let digest = Insecure.MD5.hash(data: head)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

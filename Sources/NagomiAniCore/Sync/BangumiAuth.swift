import AppKit
import Foundation
import Network

/// Bangumi 开发者应用配置（在 bgm.tv/dev/app 注册后获得）
public struct BangumiAppConfig: Sendable {
    public var clientID: String
    public var clientSecret: String
    /// 回调地址，需与注册应用时填写的一致；默认使用本地回环端口
    public var redirectURI: String

    public init(clientID: String, clientSecret: String, redirectURI: String = "http://127.0.0.1:8123/callback") {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }
}

/// Bangumi OAuth2 授权码流程 + 令牌管理
///
/// 令牌存储说明：不使用 Keychain——`swift run` 启动的应用没有稳定代码签名，
/// 钥匙串无法记住授权，会反复弹窗要求输入密码。改为存放到
/// Application Support/NagomiAni/auth.json（0600 权限，仅当前用户可读写）。
public final class BangumiAuth: @unchecked Sendable {
    public private(set) var accessToken: String?
    public private(set) var refreshToken: String?
    public private(set) var userID: Int?
    public private(set) var expiresAt: Date?

    public var isLoggedIn: Bool { accessToken != nil }

    private let config: BangumiAppConfig

    public init(config: BangumiAppConfig) {
        self.config = config
        loadTokens()
    }

    // MARK: - 登录

    /// 完整登录流程：打开浏览器授权 → 回环回调收 code → 换 token
    public func login() async throws {
        let state = UUID().uuidString
        let port = Self.callbackPort(from: config.redirectURI)

        var comps = URLComponents(string: "https://bgm.tv/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = comps.url else { throw BangumiError.invalidURL }

        // 打开系统浏览器让用户授权
        NSWorkspace.shared.open(url)

        // 等待本地回调服务器收到 code
        let code = try await waitForCallback(port: port, expectedState: state)

        // 换取 token
        try await exchange(grantType: "authorization_code", code: code, state: state)
    }

    public func logout() {
        accessToken = nil
        refreshToken = nil
        userID = nil
        expiresAt = nil
        clearTokens()
    }

    /// token 过期前自动刷新
    public func refreshIfNeeded() async throws {
        guard let expiresAt else { return }
        if Date().addingTimeInterval(60) > expiresAt {
            try await refresh()
        }
    }

    public func refresh() async throws {
        guard let refreshToken, !refreshToken.isEmpty else {
            throw BangumiError.unauthorized
        }
        try await exchange(grantType: "refresh_token", refreshToken: refreshToken)
    }

    // MARK: - Token 交换

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?
        let tokenType: String?
        let refreshToken: String?
        let userID: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case userID = "user_id"
        }
    }

    private func exchange(grantType: String, code: String? = nil, state: String? = nil, refreshToken: String? = nil) async throws {
        var body = URLComponents()
        var items = [URLQueryItem(name: "grant_type", value: grantType)]
        items.append(.init(name: "client_id", value: config.clientID))
        items.append(.init(name: "client_secret", value: config.clientSecret))
        items.append(.init(name: "redirect_uri", value: config.redirectURI))
        if let code { items.append(.init(name: "code", value: code)) }
        if let state { items.append(.init(name: "state", value: state)) }
        if let refreshToken { items.append(.init(name: "refresh_token", value: refreshToken)) }
        body.queryItems = items

        guard let url = URL(string: "https://bgm.tv/oauth/access_token") else { throw BangumiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Spark-Howard/NagomiAni/0.1.0 (macOS) (https://github.com/Spark-Howard/NagomiAni)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BangumiError.network
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw BangumiError.httpStatus(code, detail)
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw BangumiError.decoding("")
        }

        accessToken = token.accessToken
        self.refreshToken = token.refreshToken
        userID = token.userID
        expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        saveTokens()
    }

    // MARK: - 令牌持久化（文件存储，避免 Keychain 弹窗）

    private struct AuthTokenRecord: Codable {
        var accessToken: String?
        var refreshToken: String?
        var userID: Int?
        var expiresAt: Date?
    }

    private var tokenURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NagomiAni", isDirectory: true)
        return dir.appendingPathComponent("auth.json")
    }

    private func loadTokens() {
        guard let data = try? Data(contentsOf: tokenURL),
              let record = try? JSONDecoder().decode(AuthTokenRecord.self, from: data) else {
            return
        }
        accessToken = record.accessToken
        refreshToken = record.refreshToken
        userID = record.userID
        expiresAt = record.expiresAt
    }

    private func saveTokens() {
        do {
            let url = tokenURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let record = AuthTokenRecord(
                accessToken: accessToken,
                refreshToken: refreshToken,
                userID: userID,
                expiresAt: expiresAt
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
            // 仅当前用户可读写
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("[BangumiAuth] 令牌保存失败: \(error)")
        }
    }

    private func clearTokens() {
        try? FileManager.default.removeItem(at: tokenURL)
    }

    // MARK: - 本地回环回调服务器

    private func waitForCallback(port: UInt16, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let queue = DispatchQueue(label: "nagomiani.oauth.callback")
            let listener: NWListener
            do {
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    cont.resume(throwing: BangumiError.invalidURL)
                    return
                }
                listener = try NWListener(using: .tcp, on: nwPort)
            } catch {
                cont.resume(throwing: error)
                return
            }

            var resolved = false

            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
                    guard let data = data, !data.isEmpty else { return }
                    let requestText = String(decoding: data, as: UTF8.self)
                    // 解析请求行：GET /callback?code=xxx&state=yyy HTTP/1.1
                    let parts = requestText.split(separator: " ").map(String.init)
                    guard parts.count >= 2, let url = URL(string: parts[1]) else {
                        Self.sendResponse(connection, status: 400, body: "bad request")
                        return
                    }

                    guard url.path == "/callback" else {
                        Self.sendResponse(connection, status: 404, body: "not found")
                        return
                    }

                    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let code = items.first { $0.name == "code" }?.value
                    let state = items.first { $0.name == "state" }?.value

                    guard let code, state == expectedState else {
                        Self.sendResponse(connection, status: 400, body: "state 校验失败")
                        return
                    }

                    Self.sendResponse(connection, status: 200, body: """
                    <h1>登录成功，可以关闭此页面</h1>
                    <script>try { window.close(); } catch (e) {}</script>
                    """)
                    listener.cancel()
                    if !resolved {
                        resolved = true
                        cont.resume(returning: code)
                    }
                }
            }

            listener.stateUpdateHandler = { state in
                if case .failed = state, !resolved {
                    resolved = true
                    cont.resume(throwing: BangumiError.network)
                }
            }

            listener.start(queue: queue)
        }
    }

    private static func sendResponse(_ connection: NWConnection, status: Int, body: String) {
        let reason = status == 200 ? "OK" : "Error"
        let text = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func callbackPort(from redirectURI: String) -> UInt16 {
        if let url = URL(string: redirectURI), let port = url.port {
            return UInt16(port)
        }
        return 8123
    }
}

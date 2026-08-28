import AppKit
import Foundation
import Network
import Security

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

/// Bangumi OAuth2 授权码流程 + 令牌管理（Keychain 存储）
public final class BangumiAuth: @unchecked Sendable {
    public private(set) var accessToken: String?
    public private(set) var refreshToken: String?
    public private(set) var userID: Int?
    public private(set) var expiresAt: Date?

    public var isLoggedIn: Bool { accessToken != nil }

    private let config: BangumiAppConfig
    private let keychain = KeychainHelper(service: "com.nagomiani.player")

    public init(config: BangumiAppConfig) {
        self.config = config
        loadFromKeychain()
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
        keychain.delete("access_token")
        keychain.delete("refresh_token")
        keychain.delete("user_id")
        keychain.delete("expires_at")
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
        request.setValue("nagomiani/0.1.0 (macOS) (https://github.com/nagomiani-macos)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body.query?.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BangumiError.network
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw BangumiError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw BangumiError.decoding
        }

        accessToken = token.accessToken
        self.refreshToken = token.refreshToken
        userID = token.userID
        expiresAt = token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        keychain.set(token.accessToken, forKey: "access_token")
        if let refreshToken { keychain.set(refreshToken, forKey: "refresh_token") }
        if let userID { keychain.set(String(userID), forKey: "user_id") }
        if let expiresAt { keychain.set(String(expiresAt.timeIntervalSince1970), forKey: "expires_at") }
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

                    Self.sendResponse(connection, status: 200, body: "<h1>登录成功，可以关闭此页面</h1>")
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

    // MARK: - Keychain

    private func loadFromKeychain() {
        if let token = keychain.get("access_token") {
            accessToken = token
        }
        refreshToken = keychain.get("refresh_token")
        if let id = keychain.get("user_id").flatMap(Int.init) {
            userID = id
        }
        if let exp = keychain.get("expires_at").flatMap(Double.init) {
            expiresAt = Date(timeIntervalSince1970: exp)
        }
    }
}

/// 轻量 Keychain 封装
public final class KeychainHelper {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    @discardableResult
    public func set(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}

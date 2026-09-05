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
    /// 应用凭证（App ID / Secret）：随令牌一并存 auth.json，跨进程/跨启动共享。
    /// 优先取文件里保存的；没有时才回退到构造时传入的 config
    /// （这样 `swift run` 与打包 .app 的 UserDefaults 域不同也不影响）。
    public private(set) var clientID: String?
    public private(set) var clientSecret: String?

    public var isLoggedIn: Bool { accessToken != nil }

    private let config: BangumiAppConfig

    private var effectiveClientID: String { clientID ?? config.clientID }
    private var effectiveClientSecret: String { clientSecret ?? config.clientSecret }

    public init(config: BangumiAppConfig) {
        self.config = config
        loadTokens()
        // 迁移兼容：旧 auth.json 里没有凭证，但本次调用方带上了 config（来自任一
        // UserDefaults 域）→ 补写进文件，之后所有进程都能用它刷新令牌
        if clientID == nil || clientSecret == nil,
           !config.clientID.isEmpty, !config.clientSecret.isEmpty {
            clientID = config.clientID
            clientSecret = config.clientSecret
            saveTokens()
        }
    }

    // MARK: - 登录

    /// 完整登录流程（默认在系统浏览器授权）→ 回环回调收 code → 换 token
    public func login() async throws {
        try await login(openURL: { NSWorkspace.shared.open($0) })
    }

    /// 完整登录流程，但授权页由调用方指定的方式打开
    /// （例如放进与“聊天网页”共享 Cookie 的内嵌 WebView —— 这样授权成功后，
    /// bgm.tv 网页登录会话也写入同一 Cookie 存储，聊天不再需要单独登录）
    public func login(openURL opening: @escaping (URL) -> Void) async throws {
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

        // 按调用方指定的方式打开授权页
        opening(url)

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
        // 同一进程内多个 BangumiAuth 实例可能同时刷新同一个 refresh_token：
        // 服务端轮换会让后刷新者 401 → 用全局 actor 串行化；后到者重读文件直接采用更新结果
        try await AuthRefreshGate.shared.run { [self] in
            if let record = AuthTokenFileStore.load(),
               let fileRefresh = record.refreshToken, !fileRefresh.isEmpty,
               fileRefresh != self.refreshToken,
               let fileAccess = record.accessToken, !fileAccess.isEmpty {
                // 已有其它实例刷新完成：直接采用文件里的新令牌，不再发起重复刷新
                self.adopt(record)
                return
            }
            guard let myRefresh = self.refreshToken, !myRefresh.isEmpty else {
                throw BangumiError.unauthorized
            }
            try await self.exchange(grantType: "refresh_token", refreshToken: myRefresh)
        }
    }

    /// 采用文件里其它实例已刷新好的令牌（避免重复请求 / 轮换冲突）
    private func adopt(_ record: AuthTokenRecord) {
        accessToken = record.accessToken
        refreshToken = record.refreshToken
        userID = record.userID
        expiresAt = record.expiresAt
        if let storedID = record.clientID { clientID = storedID }
        if let storedSecret = record.clientSecret { clientSecret = storedSecret }
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
        items.append(.init(name: "client_id", value: effectiveClientID))
        items.append(.init(name: "client_secret", value: effectiveClientSecret))
        items.append(.init(name: "redirect_uri", value: config.redirectURI))
        if let code { items.append(.init(name: "code", value: code)) }
        if let state { items.append(.init(name: "state", value: state)) }
        if let refreshToken { items.append(.init(name: "refresh_token", value: refreshToken)) }
        body.queryItems = items

        guard let url = URL(string: "https://bgm.tv/oauth/access_token") else { throw BangumiError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Spark-Howard/NagomiAni/1.0.0 (macOS) (https://github.com/Spark-Howard/NagomiAni)", forHTTPHeaderField: "User-Agent")
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

    /// 读写都收敛到 AuthTokenFileStore（全实例共享一条串行队列），避免多实例并发写坏文件
    private func loadTokens() {
        guard let record = AuthTokenFileStore.load() else { return }
        accessToken = record.accessToken
        refreshToken = record.refreshToken
        userID = record.userID
        expiresAt = record.expiresAt
        clientID = record.clientID
        clientSecret = record.clientSecret
    }

    private func saveTokens() {
        AuthTokenFileStore.save(AuthTokenRecord(
            accessToken: accessToken,
            refreshToken: refreshToken,
            userID: userID,
            expiresAt: expiresAt,
            clientID: clientID ?? (config.clientID.isEmpty ? nil : config.clientID),
            clientSecret: clientSecret ?? (config.clientSecret.isEmpty ? nil : config.clientSecret)
        ))
    }

    private func clearTokens() {
        AuthTokenFileStore.clear()
    }

    // MARK: - 本地回环回调服务器（可取消 + 超时兜底）

    /// 登录回调专用串行队列：listener / continuation 等状态只在该队列上访问
    private static let callbackQueue = DispatchQueue(label: "nagomiani.oauth.callback")
    private var callbackListener: NWListener?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var callbackFinished = false
    private var callbackTimeoutWork: DispatchWorkItem?
    /// 等待授权回调的最长时间（秒）：用户关掉浏览器授权页不授权，登录也要能退出
    private let callbackTimeoutSeconds: TimeInterval = 90

    /// 取消当前登录（用户在登录界面点「取消登录」，任意线程可调用）
    public func cancelLogin() {
        Self.callbackQueue.async { [weak self] in
            self?.finishCallback(with: BangumiError.loginCancelled)
        }
    }

    private func waitForCallback(port: UInt16, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            Self.callbackQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: BangumiError.network)
                    return
                }
                self.callbackContinuation = cont
                self.callbackFinished = false
                self.startCallbackServer(port: port, expectedState: expectedState)

                // 超时兜底：没收到回调也能返回，登录按钮不会一直转圈
                let timeout = DispatchWorkItem { [weak self] in
                    self?.finishCallback(with: BangumiError.loginTimeout)
                }
                self.callbackTimeoutWork = timeout
                Self.callbackQueue.asyncAfter(
                    deadline: .now() + self.callbackTimeoutSeconds,
                    execute: timeout
                )
            }
        }
    }

    private func startCallbackServer(port: UInt16, expectedState: String) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            finishCallback(with: BangumiError.invalidURL)
            return
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            finishCallback(with: BangumiError.network)
            return
        }
        callbackListener = listener

        listener.newConnectionHandler = { connection in
            connection.start(queue: Self.callbackQueue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
                guard let self, let data, !data.isEmpty else { return }
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
                self.finishCallback(returning: code)
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Self.callbackQueue.async { self?.finishCallback(with: BangumiError.network) }
            }
        }

        listener.start(queue: Self.callbackQueue)
    }

    /// 收到授权码后收尾（在 callbackQueue 上调用）
    private func finishCallback(returning code: String) {
        resolve(.success(code))
    }

    /// 失败收尾：取消 / 超时 / 监听失败（必须已在 callbackQueue 上调用）
    private func finishCallback(with error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<String, Error>) {
        guard !callbackFinished else { return }
        callbackFinished = true
        callbackTimeoutWork?.cancel()
        callbackTimeoutWork = nil
        callbackListener?.cancel()
        callbackListener = nil
        callbackContinuation?.resume(with: result)
        callbackContinuation = nil
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

// MARK: - 令牌文件存储（跨实例串行化）

/// 串行化进程内 token 刷新：refresh_token 会被服务端轮换，多个实例并发刷新时
/// 只有一个真正发起网络请求，其它实例等待后直接采用文件里已更新的令牌。
private actor AuthRefreshGate {
    static let shared = AuthRefreshGate()

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await body()
    }
}

/// auth.json 的记录结构（文件级共享；多个 BangumiAuth 实例都读写同一份）
private struct AuthTokenRecord: Codable {
    var accessToken: String?
    var refreshToken: String?
    var userID: Int?
    var expiresAt: Date?
    /// 应用凭证随令牌一起保存：`swift run` 与打包 .app 的 UserDefaults 域不同，
    /// 只有放进共享文件才能保证任意入口都能刷新/换 token
    var clientID: String?
    var clientSecret: String?
}

/// 令牌文件的唯一读写入口。
///
/// 修复：登录页 / 番库 / 搜索 / 播放器各自会 new 一个 BangumiAuth，以前各自直接写
/// auth.json，两个实例并发刷新/保存时后写者可能把“过期更早”的旧 token 回写覆盖，
/// 导致偶发 401“登录已失效”。现在：
/// - 所有读写经过同一条串行队列，不会并发写坏文件；
/// - save 前对比文件已有 token：若文件里的是有效期更长（晚 30s+）的更新 token，
///   说明是其它实例更晚刷新的结果，跳过本次覆盖。
private enum AuthTokenFileStore {
    static let queue = DispatchQueue(label: "nagomiani.authfile")

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NagomiAni", isDirectory: true)
        return dir.appendingPathComponent("auth.json")
    }

    static func load() -> AuthTokenRecord? {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(AuthTokenRecord.self, from: data)
        }
    }

    static func save(_ record: AuthTokenRecord) {
        queue.sync {
            // 文件里已有"有效期更长"的 token → 那是更晚刷新的结果，保留它
            if let existing = readCurrent(),
               let existingToken = existing.accessToken,
               existingToken != record.accessToken,
               let existingExpiry = existing.expiresAt,
               let ourExpiry = record.expiresAt,
               existingExpiry > ourExpiry.addingTimeInterval(30) {
                return
            }
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
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
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func readCurrent() -> AuthTokenRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AuthTokenRecord.self, from: data)
    }
}

import Foundation

/// 样例片源：本地生成样例 MP4（MockStreamGenerator）+ 回环 HTTP 服务器出流。
///
/// 用途：在接入真实站点前打通「在线页 → 网络流 → mpv 播放 → 续播 → markWatched」全链路。
/// 目录结构与真实 Provider 一致，后续接入真实站点时 UI/业务零改动。
public final class MockProvider: SourceProvider, @unchecked Sendable {
    public let id = "mock"
    public let displayName = "样例片源（本地生成）"

    /// 样例番的 showID（进入合成 seriesKey，勿改）
    static let sampleShowID = "sample-1"
    static let episodeCount = 3

    private let episodeDuration: TimeInterval
    private let mediaDirectory: URL
    private let lock = NSLock()
    private var server: LoopbackHTTPServer?
    private var serverPort: UInt16 = 0
    private var generating: [String: Task<Void, Error>] = [:]

    /// - Parameters:
    ///   - rootDirectory: 媒体文件目录；默认 `~/Library/Caches/NagomiAni/MockStreams`
    ///   - episodeDuration: 每集时长（秒）。默认 360s ≥ markWatched 的 5 分钟阈值，保证自动同步链路可端到端验证
    public init(rootDirectory: URL? = nil, episodeDuration: TimeInterval = 360) {
        self.episodeDuration = episodeDuration
        if let rootDirectory {
            mediaDirectory = rootDirectory
        } else {
            mediaDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("NagomiAni/MockStreams", isDirectory: true)
        }
    }

    deinit {
        server?.stop()
    }

    // MARK: - SourceProvider

    public func listShows() async throws -> [OnlineShow] {
        [OnlineShow(
            providerID: id,
            showID: Self.sampleShowID,
            title: "Nagomi 样例番组",
            subtitle: "本地生成的测试片源"
        )]
    }

    public func episodes(for showID: String) async throws -> [OnlineEpisode] {
        guard showID == Self.sampleShowID else { return [] }
        return (1...Self.episodeCount).map { number in
            OnlineEpisode(providerID: id, showID: showID, number: number, title: "第 \(number) 话")
        }
    }

    public func streamURL(for episode: OnlineEpisode) async throws -> StreamSource {
        let port = try await ensureServerRunning()
        try await ensureMediaFile(episodeNumber: episode.number)
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(mediaFileName(episodeNumber: episode.number))") else {
            throw NSError(domain: "MockProvider", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法构造样例流 URL"])
        }
        return StreamSource(url: url)
    }

    // MARK: - 服务器与文件

    private func mediaFileName(episodeNumber: Int) -> String {
        "\(Self.sampleShowID)-ep\(episodeNumber).mp4"
    }

    private func ensureServerRunning() async throws -> UInt16 {
        let port = lock.withLock { serverPort }
        if port > 0 { return port }
        let newServer = LoopbackHTTPServer(rootURL: mediaDirectory)
        let newPort = try await newServer.start()
        let finalPort = lock.withLock { () -> UInt16 in
            // 并发场景下别的调用已启动成功：沿用已就绪的端口，弃用本次实例
            if serverPort > 0 { return serverPort }
            server = newServer
            serverPort = newPort
            return newPort
        }
        if finalPort != newPort {
            newServer.stop()
        }
        return finalPort
    }

    /// 同一集的并发生成只跑一次；失败后清引用允许重试
    private func ensureMediaFile(episodeNumber: Int) async throws {
        let outputURL = mediaDirectory.appendingPathComponent(mediaFileName(episodeNumber: episodeNumber))
        if FileManager.default.fileExists(atPath: outputURL.path) { return }

        let key = mediaFileName(episodeNumber: episodeNumber)
        let task: Task<Void, Error> = lock.withLock {
            if let existing = generating[key] { return existing }
            let mediaDirectory = mediaDirectory
            let episodeDuration = episodeDuration
            return Task {
                try await MockStreamGenerator.writeEpisode(
                    episodeNumber: episodeNumber,
                    duration: episodeDuration,
                    outputURL: mediaDirectory.appendingPathComponent("\(Self.sampleShowID)-ep\(episodeNumber).mp4")
                )
            }
        }
        do {
            try await task.value
            lock.withLock { generating[key] = nil }
        } catch {
            lock.withLock { generating[key] = nil }
            throw error
        }
    }
}

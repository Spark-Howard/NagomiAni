import CryptoKit
import Foundation

/// 在线流的本地缓存：
/// - HLS：下载分片到磁盘 + 重写本地 m3u8（相对路径指向本地分片），mpv 直接播本地 playlist
/// - 渐进式（mp4 等单文件）：流式落盘为 media.<ext>
///
/// 目录：`~/Library/Caches/NagomiAni/StreamCache/<SHA256(cacheKey)>/`
/// 完成标记 `complete.json`（CacheMarker）记录原始 key 与本地媒体文件名；
/// 列目录读标记即可恢复"已缓存"集合（cacheKey 含 ":" 不适合做目录名，用哈希）。
/// 超过 byteLimit 按"完成时间最旧先删"淘汰（LRU）。
public final class StreamCache: @unchecked Sendable {
    struct CacheMarker: Codable {
        let key: String
        /// 本地媒体文件名（index.m3u8 或 media.mp4 等）
        let media: String
    }

    public struct Progress: Sendable, Equatable {
        public let downloadedSegments: Int
        public let totalSegments: Int

        public var fraction: Double? {
            totalSegments > 0 ? Double(downloadedSegments) / Double(totalSegments) : nil
        }
    }

    public enum CacheError: LocalizedError {
        case liveStreamNotCacheable
        case unsupportedPlaylist
        case httpStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .liveStreamNotCacheable: return "直播流不支持整体缓存"
            case .unsupportedPlaylist: return "播放列表无法解析为可缓存的媒体流"
            case .httpStatus(let code): return "下载失败（HTTP \(code)）"
            }
        }
    }

    private let rootDirectory: URL
    private let byteLimit: Int64
    private let session: URLSession
    /// 串行化淘汰/清理与活跃下载登记
    private let lock = NSLock()
    private var activeKeys: Set<String> = []

    public init(directory: URL? = nil, byteLimit: Int64 = 2 * 1024 * 1024 * 1024, session: URLSession = URLSession.shared) {
        if let directory {
            rootDirectory = directory
        } else {
            rootDirectory = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("NagomiAni/StreamCache", isDirectory: true)
        }
        self.byteLimit = byteLimit
        self.session = session
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 状态查询

    /// 完整缓存对应的本地播放 URL（未完整缓存返回 nil）
    public func cachedMediaURL(for cacheKey: String) -> URL? {
        let dir = directory(for: cacheKey)
        guard let marker = readMarker(at: dir) else { return nil }
        let url = dir.appendingPathComponent(marker.media)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 已完整缓存的原始 key 集合（启动时恢复 UI 状态）
    public func cachedKeys() -> Set<String> {
        var keys = Set<String>()
        for dir in allCacheDirectories() {
            if let marker = readMarker(at: dir) {
                keys.insert(marker.key)
            }
        }
        return keys
    }

    public func totalBytes() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return totalBytesLocked()
    }

    // MARK: - 下载

    /// 缓存 HLS（master 自动跟随到最高码率的媒体流），返回本地 m3u8 URL
    @discardableResult
    public func download(
        playlistURL: URL,
        httpHeaders: [String: String] = [:],
        userAgent: String? = nil,
        cacheKey: String,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        let dir = try await beginDownload(cacheKey: cacheKey)
        defer { lock.withLock { _ = activeKeys.remove(cacheKey) } }

        let playlist = try await fetchPlaylist(playlistURL, httpHeaders: httpHeaders, userAgent: userAgent)
        let media: HLSPlaylist
        let mediaURL: URL
        if playlist.kind == .master {
            guard let best = HLSParser.bestVariant(in: playlist),
                  let variantURL = HLSParser.resolve(best.uri, against: playlistURL) else {
                throw CacheError.unsupportedPlaylist
            }
            media = try await fetchPlaylist(variantURL, httpHeaders: httpHeaders, userAgent: userAgent)
            mediaURL = variantURL
        } else {
            media = playlist
            mediaURL = playlistURL
        }
        guard media.isVOD else { throw CacheError.liveStreamNotCacheable }

        // fMP4 初始化段
        var initLocalName: String?
        if let initURI = media.initSegmentURI,
           let initURL = HLSParser.resolve(initURI, against: mediaURL) {
            let ext = Self.urlExtension(initURI, fallback: "mp4")
            let localURL = dir.appendingPathComponent("init.\(ext)")
            let data = try await fetchData(initURL, httpHeaders: httpHeaders, userAgent: userAgent)
            try data.write(to: localURL)
            initLocalName = localURL.lastPathComponent
        }

        // 分片并发下载（≤4），已存在的分片跳过（中断重下可续）
        let total = media.segments.count
        let completed = ProgressCounter()
        progress?(Progress(downloadedSegments: 0, totalSegments: total))
        try await withThrowingTaskGroup(of: Void.self) { group in
            let maxConcurrent = 4
            for (index, segment) in media.segments.enumerated() {
                if index >= maxConcurrent { try await group.next() }
                guard let segmentURL = HLSParser.resolve(segment.uri, against: mediaURL) else { continue }
                group.addTask {
                    try Task.checkCancellation()
                    let localURL = dir.appendingPathComponent(
                        "seg-\(String(format: "%04d", index)).\(Self.urlExtension(segment.uri, fallback: "ts"))"
                    )
                    if !FileManager.default.fileExists(atPath: localURL.path) {
                        let data = try await self.fetchData(segmentURL, httpHeaders: httpHeaders, userAgent: userAgent)
                        try data.write(to: localURL)
                    }
                    progress?(Progress(downloadedSegments: completed.increment(), totalSegments: total))
                }
            }
            try await group.waitForAll()
        }

        // 重写本地 playlist
        let segmentNames = media.segments.enumerated().map { index, segment in
            "seg-\(String(format: "%04d", index)).\(Self.urlExtension(segment.uri, fallback: "ts"))"
        }
        let localPlaylistURL = dir.appendingPathComponent("index.m3u8")
        try Self.writeLocalPlaylist(media, segmentNames: segmentNames, initLocalName: initLocalName,
                                    to: localPlaylistURL)
        try writeMarker(at: dir, CacheMarker(key: cacheKey, media: localPlaylistURL.lastPathComponent))
        evictIfNeeded()
        return localPlaylistURL
    }

    /// 缓存渐进式单文件（流式落盘，不整块占内存），返回本地文件 URL
    @discardableResult
    public func downloadFile(
        url: URL,
        httpHeaders: [String: String] = [:],
        userAgent: String? = nil,
        cacheKey: String,
        fileExtension: String? = nil
    ) async throws -> URL {
        let dir = try await beginDownload(cacheKey: cacheKey)
        defer { lock.withLock { _ = activeKeys.remove(cacheKey) } }

        let ext = Self.urlExtension(fileExtension.map { ".\($0)" } ?? url.lastPathComponent, fallback: "mp4")
        let localURL = dir.appendingPathComponent("media.\(ext)")
        let (bytes, response) = try await session.bytes(for: makeRequest(url, httpHeaders: httpHeaders, userAgent: userAgent))
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CacheError.httpStatus(http.statusCode)
        }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: localURL)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try writeMarker(at: dir, CacheMarker(key: cacheKey, media: localURL.lastPathComponent))
        evictIfNeeded()
        return localURL
    }

    // MARK: - 清理

    public func purge(cacheKey: String) {
        lock.withLock { _ = activeKeys.remove(cacheKey) }
        try? FileManager.default.removeItem(at: directory(for: cacheKey))
    }

    public func purgeAll() {
        lock.withLock { activeKeys.removeAll() }
        for dir in allCacheDirectories() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - 私有：下载辅助

    /// 登记活跃下载并准备全新目录（重复下载覆盖重来）
    private func beginDownload(cacheKey: String) async throws -> URL {
        lock.withLock { _ = activeKeys.insert(cacheKey) }
        let dir = directory(for: cacheKey)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRequest(_ url: URL, httpHeaders: [String: String], userAgent: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (key, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private func fetchData(_ url: URL, httpHeaders: [String: String], userAgent: String?) async throws -> Data {
        let (data, response) = try await session.data(
            for: makeRequest(url, httpHeaders: httpHeaders, userAgent: userAgent)
        )
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CacheError.httpStatus(http.statusCode)
        }
        return data
    }

    private func fetchPlaylist(_ url: URL, httpHeaders: [String: String], userAgent: String?) async throws -> HLSPlaylist {
        let text = String(decoding: try await fetchData(url, httpHeaders: httpHeaders, userAgent: userAgent), as: UTF8.self)
        return try HLSParser.parse(text)
    }

    // MARK: - 私有：磁盘布局

    private func directory(for cacheKey: String) -> URL {
        let digest = SHA256.hash(data: Data(cacheKey.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return rootDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func readMarker(at directory: URL) -> CacheMarker? {
        let url = directory.appendingPathComponent("complete.json")
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONDecoder().decode(CacheMarker.self, from: data) else { return nil }
        return marker
    }

    private func writeMarker(at directory: URL, _ marker: CacheMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        try data.write(to: directory.appendingPathComponent("complete.json"))
    }

    private func allCacheDirectories() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ))?.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true } ?? []
    }

    private func totalBytesLocked() -> Int64 {
        var total: Int64 = 0
        for dir in allCacheDirectories() {
            total += directorySize(dir)
        }
        return total
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(Int64(0)) { sum, file in
            sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// LRU 淘汰：超限后按目录 mtime 从旧到新删（跳过活跃下载），直到回到限内
    private func evictIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        var total = totalBytesLocked()
        guard total > byteLimit else { return }
        let dirs = allCacheDirectories().sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        for dir in dirs {
            guard let marker = readMarker(at: dir), !activeKeys.contains(marker.key) else { continue }
            let size = directorySize(dir)
            try? FileManager.default.removeItem(at: dir)
            total -= size
            if total <= byteLimit { break }
        }
    }

    // MARK: - 工具

    /// 从 URI 末段取扩展名（无扩展名时给 fallback）
    static func urlExtension(_ uriOrName: String, fallback: String) -> String {
        let name = uriOrName.split(separator: "?").first.map(String.init) ?? uriOrName
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? fallback : ext
    }

    /// 按解析结果重写本地 playlist（分片/初始化段替换为本地文件名）
    static func writeLocalPlaylist(
        _ media: HLSPlaylist,
        segmentNames: [String],
        initLocalName: String?,
        to url: URL
    ) throws {
        var lines: [String] = ["#EXTM3U", "#EXT-X-VERSION:3"]
        lines.append("#EXT-X-TARGETDURATION:\(Int((media.targetDuration ?? 10).rounded()))")
        if let initLocalName {
            lines.append("#EXT-X-MAP:URI=\"\(initLocalName)\"")
        }
        for (segment, name) in zip(media.segments, segmentNames) {
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append(name)
        }
        lines.append("#EXT-X-ENDLIST")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 线程安全的分片完成计数器
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() -> Int {
            lock.lock()
            count += 1
            let current = count
            lock.unlock()
            return current
        }
    }
}

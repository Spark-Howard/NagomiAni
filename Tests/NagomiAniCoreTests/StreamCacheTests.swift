import CryptoKit
import XCTest
@testable import NagomiAniCore

final class StreamCacheTests: XCTestCase {
    private var tempDir: URL!
    private var originDir: URL! // 模拟"源站"的文件目录（file:// 直接给 URLSession 用）

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NagomiAniStreamCacheTests-\(UUID().uuidString)")
        originDir = tempDir.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: originDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeCache(byteLimit: Int64 = 1 << 30) -> StreamCache {
        StreamCache(directory: tempDir.appendingPathComponent("cache"), byteLimit: byteLimit)
    }

    /// 在"源站"目录里生成 3 分片的测试 playlist，返回 playlist 的 file URL
    private func makeOriginPlaylist(segmentCount: Int = 3) throws -> URL {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2"]
        for i in 0..<segmentCount {
            let name = "seg-\(i).ts"
            try Data("payload-\(i)-\(String(repeating: "x", count: 64))".utf8)
                .write(to: originDir.appendingPathComponent(name))
            lines.append("#EXTINF:2.0,")
            lines.append(name)
        }
        lines.append("#EXT-X-ENDLIST")
        let playlistURL = originDir.appendingPathComponent("index.m3u8")
        try lines.joined(separator: "\n").write(to: playlistURL, atomically: true, encoding: .utf8)
        return playlistURL
    }

    // MARK: - HLS 缓存

    func testHLSDownloadProducesLocalPlaylist() async throws {
        let cache = makeCache()
        let playlistURL = try makeOriginPlaylist()

        let localURL = try await cache.download(playlistURL: playlistURL, cacheKey: "k1")

        // 本地 playlist 存在且被标记为完整缓存
        XCTAssertTrue(FileManager.default.fileExists(atPath: localURL.path))
        XCTAssertEqual(localURL.lastPathComponent, "index.m3u8")
        XCTAssertEqual(cache.cachedMediaURL(for: "k1"), localURL)
        XCTAssertEqual(cache.cachedKeys(), ["k1"])

        // 本地 playlist 内容：分片替换为本地文件名，保留时长与 ENDLIST
        let text = try String(contentsOf: localURL, encoding: .utf8)
        XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
        XCTAssertTrue(text.contains("#EXTINF:2.000,"))
        XCTAssertTrue(text.contains("seg-0000.ts"))
        XCTAssertTrue(text.contains("seg-0002.ts"))
        XCTAssertFalse(text.contains("origin")) // 不再引用源路径

        // 重写的分片文件就在 playlist 旁边
        let seg0 = localURL.deletingLastPathComponent().appendingPathComponent("seg-0000.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: seg0.path))
        let data = try Data(contentsOf: seg0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("payload-0-"))
    }

    func testHLSDownloadReportsProgress() async throws {
        let cache = makeCache()
        let segmentCount = 6
        let playlistURL = try makeOriginPlaylist(segmentCount: segmentCount)

        var lastProgress: StreamCache.Progress?
        let lock = NSLock()
        _ = try await cache.download(playlistURL: playlistURL, cacheKey: "k1") { p in
            lock.lock()
            lastProgress = p
            lock.unlock()
        }
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(lastProgress?.totalSegments, segmentCount)
        XCTAssertEqual(lastProgress?.downloadedSegments, segmentCount)
        XCTAssertEqual(lastProgress?.fraction, 1.0)
        // file:// 分片 HEAD 不适用 → 总大小未知（nil），但已下载字节应准确累加
        XCTAssertNil(lastProgress?.totalBytes)
        let expectedBytes = (0..<segmentCount).map { i in
            Data("payload-\(i)-\(String(repeating: "x", count: 64))".utf8).count
        }.reduce(0, +)
        XCTAssertEqual(lastProgress?.downloadedBytes, Int64(expectedBytes))
    }

    /// 已缓存条目的磁盘占用查询
    func testSizeBytes() async throws {
        let cache = makeCache()
        XCTAssertNil(cache.sizeBytes(for: "s1"))
        let playlistURL = try makeOriginPlaylist()
        _ = try await cache.download(playlistURL: playlistURL, cacheKey: "s1")
        let size = try XCTUnwrap(cache.sizeBytes(for: "s1"))
        XCTAssertGreaterThan(size, 0)
        // 清除后为 nil
        cache.purge(cacheKey: "s1")
        XCTAssertNil(cache.sizeBytes(for: "s1"))
    }

    /// master playlist 自动跟随到唯一变体
    func testHLSMasterFollowsVariant() async throws {
        // 媒体 playlist + 分片
        _ = try makeOriginPlaylist()
        // master 指向它
        let masterURL = originDir.appendingPathComponent("master.m3u8")
        try """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,NAME="480p"
        index.m3u8
        """.write(to: masterURL, atomically: true, encoding: .utf8)

        let cache = makeCache()
        let localURL = try await cache.download(playlistURL: masterURL, cacheKey: "k1")
        let text = try String(contentsOf: localURL, encoding: .utf8)
        XCTAssertTrue(text.contains("seg-0000.ts"))
        XCTAssertEqual(cache.cachedMediaURL(for: "k1"), localURL)
    }

    /// 直播流（无 ENDLIST）拒绝整体缓存
    func testHLSLiveStreamRejected() async throws {
        try """
        #EXTM3U
        #EXT-X-TARGETDURATION:2
        #EXTINF:2.0,
        seg-0.ts
        """.write(to: originDir.appendingPathComponent("live.m3u8"), atomically: true, encoding: .utf8)

        let cache = makeCache()
        do {
            _ = try await cache.download(
                playlistURL: originDir.appendingPathComponent("live.m3u8"), cacheKey: "k1"
            )
            XCTFail("直播流应当拒绝缓存")
        } catch let error as StreamCache.CacheError {
            XCTAssertEqual(error.errorDescription, StreamCache.CacheError.liveStreamNotCacheable.errorDescription)
        }
    }

    // MARK: - 单文件缓存

    func testFileDownload() async throws {
        let cache = makeCache()
        let payload = Data("mp4-payload".utf8)
        let sourceURL = originDir.appendingPathComponent("movie.mp4")
        try payload.write(to: sourceURL)

        let localURL = try await cache.downloadFile(url: sourceURL, cacheKey: "f1")
        XCTAssertTrue(localURL.lastPathComponent.hasPrefix("media."))
        XCTAssertEqual(try Data(contentsOf: localURL), payload)
        XCTAssertEqual(cache.cachedMediaURL(for: "f1"), localURL)

        // 清除后回到未缓存
        cache.purge(cacheKey: "f1")
        XCTAssertNil(cache.cachedMediaURL(for: "f1"))
        XCTAssertTrue(cache.cachedKeys().isEmpty)
    }

    // MARK: - 容量淘汰

    func testLRUEviction() async throws {
        // 每个 key 的目录 ~400 字节（playlist + 3 分片 + 标记）；
        // 限制 1000 → 缓到第 3 个就该淘汰最旧的，最终只剩 {c, d}
        let cache = makeCache(byteLimit: 1000)
        let playlistURL = try makeOriginPlaylist()

        for key in ["a", "b", "c"] {
            _ = try await cache.download(playlistURL: playlistURL, cacheKey: key)
            // 触碰 mtime 保证 LRU 顺序
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()], ofItemAtPath: cacheDirectory(key: key).path
            )
        }
        _ = try await cache.download(playlistURL: playlistURL, cacheKey: "d")

        XCTAssertNil(cache.cachedMediaURL(for: "a"), "最旧的 key 应被淘汰")
        XCTAssertNil(cache.cachedMediaURL(for: "b"), "次旧的 key 应被淘汰")
        XCTAssertNotNil(cache.cachedMediaURL(for: "c"))
        XCTAssertNotNil(cache.cachedMediaURL(for: "d"), "当前活跃 key 不应被淘汰")
        XCTAssertLessThanOrEqual(cache.totalBytes(), 1000)
    }

    /// cacheKey 对应的实际目录（镜像 StreamCache 的 SHA256 哈希命名，root 与 makeCache 一致）
    private func cacheDirectory(key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return tempDir.appendingPathComponent("cache").appendingPathComponent(name)
    }

    // MARK: - 总量统计

    func testTotalBytesCountsFiles() async throws {
        let cache = makeCache()
        let playlistURL = try makeOriginPlaylist()
        _ = try await cache.download(playlistURL: playlistURL, cacheKey: "k1")
        XCTAssertGreaterThan(cache.totalBytes(), 0)
    }
}

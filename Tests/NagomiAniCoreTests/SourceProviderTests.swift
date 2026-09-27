import XCTest
@testable import NagomiAniCore

final class SourceProviderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NagomiAniSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 合成 seriesKey / resumeKey

    func testSeriesKeyFormat() {
        XCTAssertEqual(
            OnlineShow.seriesKey(providerID: "mock", showID: "sample-1"),
            "online:mock:sample-1"
        )
        let show = OnlineShow(providerID: "mock", showID: "sample-1", title: "T")
        XCTAssertEqual(show.seriesKey, "online:mock:sample-1")

        let episode = OnlineEpisode(providerID: "mock", showID: "sample-1", number: 2)
        XCTAssertEqual(episode.seriesKey, "online:mock:sample-1")
        XCTAssertEqual(episode.resumeKey, "online:mock:sample-1:2")
    }

    // MARK: - MockProvider 目录

    func testMockCatalog() async throws {
        let provider = MockProvider(rootDirectory: tempDir, episodeDuration: 3)
        let shows = try await provider.listShows()
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual(shows[0].providerID, "mock")
        XCTAssertEqual(shows[0].showID, MockProvider.sampleShowID)
        XCTAssertFalse(shows[0].title.isEmpty)

        let episodes = try await provider.episodes(for: MockProvider.sampleShowID)
        XCTAssertEqual(episodes.map(\.number), [1, 2, 3])
        XCTAssertTrue(episodes.allSatisfy { $0.title != nil })
    }

    func testMockEpisodesForUnknownShowIsEmpty() async throws {
        let provider = MockProvider(rootDirectory: tempDir, episodeDuration: 3)
        let episodes = try await provider.episodes(for: "no-such-show")
        XCTAssertTrue(episodes.isEmpty)
    }

    // MARK: - MockProvider 出流（生成文件 + HTTP 可达）

    func testStreamURLServesGeneratedFile() async throws {
        let provider = MockProvider(rootDirectory: tempDir, episodeDuration: 3)
        let episodes = try await provider.episodes(for: MockProvider.sampleShowID)

        let source = try await provider.streamURL(for: episodes[0])
        XCTAssertFalse(source.isHLS)
        XCTAssertTrue(source.httpHeaders.isEmpty)
        XCTAssertEqual(source.url.host, "127.0.0.1")

        // 文件已生成在根目录内
        let fileURL = tempDir.appendingPathComponent("\(MockProvider.sampleShowID)-ep1.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // 经 HTTP 拉取 MP4 头部魔数（第 4-7 字节 = "ftyp"），验证服务器与文件真实可用
        var request = URLRequest(url: source.url)
        request.setValue("bytes=4-7", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data.count, 4)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ftyp")
    }

    /// 第二次取流命中磁盘缓存：URL 一致且不需要重新生成
    func testStreamURLCached() async throws {
        let provider = MockProvider(rootDirectory: tempDir, episodeDuration: 3)
        let episodes = try await provider.episodes(for: MockProvider.sampleShowID)

        let first = try await provider.streamURL(for: episodes[0])
        let second = try await provider.streamURL(for: episodes[0])
        XCTAssertEqual(first.url, second.url)
    }
}

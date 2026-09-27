import XCTest
@testable import NagomiAniCore

final class LoopbackHTTPServerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NagomiAniLoopbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 10 字节测试文件
        try Data("0123456789".utf8).write(to: tempDir.appendingPathComponent("sample.mp4"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 启动一个一次性服务器（用完即停）
    private func startServer() async throws -> (LoopbackHTTPServer, UInt16) {
        let server = LoopbackHTTPServer(rootURL: tempDir)
        let port = try await server.start()
        return (server, port)
    }

    func testFullGetReturns200AndBody() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/sample.mp4")!
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data, Data("0123456789".utf8))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "10")
    }

    func testRangeRequestReturns206() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/sample.mp4")!)
        request.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, Data("2345".utf8))
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/10")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Length"), "4")
    }

    func testOpenEndedRange() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/sample.mp4")!)
        request.setValue("bytes=7-", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, Data("789".utf8))
    }

    func testSuffixRange() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/sample.mp4")!)
        request.setValue("bytes=-3", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(data, Data("789".utf8))
    }

    func testMissingFileReturns404() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/missing.mp4")!
        )
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 404)
    }

    /// 路径穿越（../ 或百分号编码的 ..）必须被拒绝，只允许访问根目录内文件
    func testPathTraversalRejected() async throws {
        let (server, port) = try await startServer()
        defer { server.stop() }

        // 目录外再放一个"机密"文件
        let outside = tempDir.deletingLastPathComponent()
            .appendingPathComponent("secret-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        for path in ["/../\(outside.lastPathComponent)", "/%2E%2E/\(outside.lastPathComponent)"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpShouldHandleCookies = false
            let (_, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 404, "path \(path) 应被拒绝")
        }
    }

    func testRangeParsing() {
        XCTAssertEqual(LoopbackHTTPServer.parseRange("bytes=0-9", fileSize: 10)?.start, 0)
        XCTAssertEqual(LoopbackHTTPServer.parseRange("bytes=0-9", fileSize: 10)?.end, 9)
        // end 超出文件大小 → 截断到末尾
        XCTAssertEqual(LoopbackHTTPServer.parseRange("bytes=5-99", fileSize: 10)?.end, 9)
        // 开区间 / 后缀
        XCTAssertEqual(LoopbackHTTPServer.parseRange("bytes=8-", fileSize: 10)?.start, 8)
        XCTAssertEqual(LoopbackHTTPServer.parseRange("bytes=-2", fileSize: 10)?.start, 8)
        // 非法：起点越界 / 非法前缀 / 空文件
        XCTAssertNil(LoopbackHTTPServer.parseRange("bytes=10-20", fileSize: 10))
        XCTAssertNil(LoopbackHTTPServer.parseRange("items=0-1", fileSize: 10))
        XCTAssertNil(LoopbackHTTPServer.parseRange("bytes=0-1", fileSize: 0))
        XCTAssertNil(LoopbackHTTPServer.parseRange(nil, fileSize: 10))
    }
}

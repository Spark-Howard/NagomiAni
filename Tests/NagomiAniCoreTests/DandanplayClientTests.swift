import CryptoKit
import XCTest
@testable import NagomiAniCore

final class DandanplayClientTests: XCTestCase {
    // MARK: - 签名

    /// X-Signature = BASE64(HMAC-SHA256(AppSecret, AppId + Timestamp + Method + Path))
    /// 期望值由独立脚本计算（非被测代码自身）
    func testSignatureVector() {
        let signature = DandanplayClient.signature(
            appId: "testappid", appSecret: "testsecret",
            timestamp: "1700000000", method: "GET", path: "/api/v2/match"
        )
        XCTAssertEqual(signature, "O4q1yCRTv0cb9RrVRMpahzYbOazsU3Cnl4rBeOIRcC8=")
    }

    func testSignatureChangesWithInputs() {
        let base = DandanplayClient.signature(appId: "a", appSecret: "s",
                                              timestamp: "1", method: "GET", path: "/p")
        XCTAssertNotEqual(base, DandanplayClient.signature(appId: "b", appSecret: "s",
                                                           timestamp: "1", method: "GET", path: "/p"))
        XCTAssertNotEqual(base, DandanplayClient.signature(appId: "a", appSecret: "s",
                                                           timestamp: "2", method: "GET", path: "/p"))
        XCTAssertNotEqual(base, DandanplayClient.signature(appId: "a", appSecret: "s",
                                                           timestamp: "1", method: "POST", path: "/p"))
    }

    func testCredentialsConfiguration() {
        XCTAssertTrue(DanmakuCredentials(appId: "a", appSecret: "b").isConfigured)
        XCTAssertFalse(DanmakuCredentials(appId: " ", appSecret: "b").isConfigured)
        XCTAssertFalse(DanmakuCredentials(appId: "a", appSecret: "").isConfigured)
        // 填入时去除首尾空白
        let trimmed = DanmakuCredentials(appId: "  a  ", appSecret: " b ")
        XCTAssertEqual(trimmed.appId, "a")
        XCTAssertEqual(trimmed.appSecret, "b")
    }

    // MARK: - 弹幕注释解析

    func testCommentFromP() throws {
        let scroll = try XCTUnwrap(DandanplayClient.comment(fromP: "12.3,1,16777215,[dandanplay]", text: "滚动弹幕"))
        XCTAssertEqual(scroll.time, 12.3, accuracy: 0.001)
        XCTAssertEqual(scroll.mode, .scroll)
        XCTAssertEqual(scroll.color, 0xFFFFFF)
        XCTAssertEqual(scroll.text, "滚动弹幕")

        let top = try XCTUnwrap(DandanplayClient.comment(fromP: "5.0,5,255,[dandanplay]", text: "顶部"))
        XCTAssertEqual(top.mode, .top)
        XCTAssertEqual(top.color, 0x0000FF)

        let bottom = try XCTUnwrap(DandanplayClient.comment(fromP: "30,4,65280,[dandanplay]", text: "底部"))
        XCTAssertEqual(bottom.mode, .bottom)
        XCTAssertEqual(bottom.color, 0x00FF00)

        // 未知模式 → 回退滚动
        let unknown = try XCTUnwrap(DandanplayClient.comment(fromP: "1,7,0,[x]", text: "?"))
        XCTAssertEqual(unknown.mode, .scroll)

        // 缺字段/非法数字 → nil
        XCTAssertNil(DandanplayClient.comment(fromP: "1,1", text: "x"))
        XCTAssertNil(DandanplayClient.comment(fromP: "a,1,0,[x]", text: "x"))
    }

    func testParseComments() throws {
        let data = Data(#"""
        {"count":2,"comments":[
            {"cid":1,"p":"10.5,1,16777215,[dandanplay]","m":"第一条例子"},
            {"cid":2,"p":"20,5,255,[dandanplay]","m":""},
            {"cid":3,"p":"bad,data"}
        ]}
        """#.utf8)
        let comments = try DandanplayClient.parseComments(data)
        XCTAssertEqual(comments.count, 1, "空文本/非法 p 的条目应被丢弃")
        XCTAssertEqual(comments[0].text, "第一条例子")
        XCTAssertEqual(comments[0].time, 10.5, accuracy: 0.001)
    }

    // MARK: - 剧集搜索与匹配

    func testParseSearchEpisodes() throws {
        let data = Data(#"""
        {"animes":[
            {"animeId":1,"animeTitle":"葬送的芙莉莲","episodes":[
                {"episodeId":101,"episodeTitle":"第1集"},
                {"episodeId":102,"episodeTitle":"第2集"}]},
            {"animeId":2,"animeTitle":"另一部番","episodes":[{"episodeId":"不是数字"}]}
        ]}
        """#.utf8)
        let episodes = try DandanplayClient.parseSearchEpisodes(data)
        XCTAssertEqual(episodes.map(\.episodeId), [101, 102], "episodeId 非数字的条目跳过")
        XCTAssertEqual(episodes[0].animeTitle, "葬送的芙莉莲")
        XCTAssertEqual(episodes[1].episodeTitle, "第2集")
    }

    func testParseMatch() throws {
        let matched = Data(#"""
        {"isMatched":true,"matches":[{"episodeId":555,"animeTitle":"测试番","episodeTitle":"第3集"}]}
        """#.utf8)
        let info = try DandanplayClient.parseMatch(matched)
        XCTAssertEqual(info.episodeId, 555)
        XCTAssertEqual(info.episodeTitle, "第3集")

        XCTAssertThrowsError(try DandanplayClient.parseMatch(Data(#"{"isMatched":false,"matches":[]}"#.utf8))) { error in
            XCTAssertEqual(error as? DanmakuError, .notMatched)
        }
    }

    // MARK: - 本地文件指纹

    func testFileHashIsMD5OfHead() throws {
        // 已知的 MD5("hello") = 5d41402abc4b2a76b9719d911017c592
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("danmaku-hash-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let hash = try DandanplayClient.fileHash(url: url)
        XCTAssertEqual(hash, "5d41402abc4b2a76b9719d911017c592")
    }
}

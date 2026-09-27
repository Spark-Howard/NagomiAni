import XCTest
@testable import NagomiAniCore

final class MacCMSProviderTests: XCTestCase {
    // MARK: - 站点地址归一化

    func testNormalizeAPIBase() {
        // 纯域名 → 补 https + 标准 API 路径
        XCTAssertEqual(MacCMSProvider.normalizeAPIBase("example.com")?.absoluteString,
                       "https://example.com/api.php/provide/vod/")
        // 根路径 → 拼 API 路径
        XCTAssertEqual(MacCMSProvider.normalizeAPIBase("http://example.com/")?.absoluteString,
                       "http://example.com/api.php/provide/vod/")
        // 完整 API（无尾斜杠）→ 原样保留
        XCTAssertEqual(MacCMSProvider.normalizeAPIBase("https://example.com/api.php/provide/vod")?.absoluteString,
                       "https://example.com/api.php/provide/vod")
        // 变体路径（at/json）→ 原样保留
        XCTAssertEqual(MacCMSProvider.normalizeAPIBase("https://example.com/api.php/provide/vod/at/json/")?.absoluteString,
                       "https://example.com/api.php/provide/vod/at/json/")
        // 子路径站点 → 在子路径后拼接
        XCTAssertEqual(MacCMSProvider.normalizeAPIBase("example.com/sub/")?.absoluteString,
                       "https://example.com/sub/api.php/provide/vod/")
        // 非法输入
        XCTAssertNil(MacCMSProvider.normalizeAPIBase(""))
        XCTAssertNil(MacCMSProvider.normalizeAPIBase("   "))
        XCTAssertNil(MacCMSProvider.normalizeAPIBase("not a url"))
    }

    func testProviderIDUsesHost() throws {
        let provider = try XCTUnwrap(MacCMSProvider(base: "https://api.example.com/api.php/provide/vod/"))
        XCTAssertEqual(provider.id, "api.example.com")
        XCTAssertEqual(provider.displayName, "api.example.com")
    }

    func testInitRejectsBadAddress() {
        XCTAssertNil(MacCMSProvider(base: "not a url"))
        XCTAssertNil(MacCMSProvider(base: ""))
    }

    // MARK: - vod_play_url 解析

    func testParsePlayURLSingleSource() {
        let pairs = MacCMSProvider.parsePlayURL(
            playURL: "第01集$http://a/01.m3u8#第02集$http://a/02.m3u8",
            playFrom: "qqm3u8"
        )
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].name, "第01集")
        XCTAssertEqual(pairs[0].url, "http://a/01.m3u8")
        XCTAssertEqual(pairs[1].url, "http://a/02.m3u8")
    }

    /// 多播放源：优先选名字含 m3u8 的组
    func testParsePlayURLPrefersM3U8Source() {
        let pairs = MacCMSProvider.parsePlayURL(
            playURL: "第01集$http://a/x1.swf#第02集$http://a/x2.swf$$$第01集$http://b/1.m3u8#第02集$http://b/2.m3u8",
            playFrom: "xff$$$qqm3u8"
        )
        XCTAssertEqual(pairs.map(\.url), ["http://b/1.m3u8", "http://b/2.m3u8"])
    }

    func testParsePlayURLEmpty() {
        XCTAssertTrue(MacCMSProvider.parsePlayURL(playURL: nil, playFrom: nil).isEmpty)
        XCTAssertTrue(MacCMSProvider.parsePlayURL(playURL: "", playFrom: "").isEmpty)
        // 有名字没地址的项被丢弃
        XCTAssertTrue(MacCMSProvider.parsePlayURL(playURL: "第01集#", playFrom: nil).isEmpty)
    }

    // MARK: - 防御式解码（vod_id 字符串/数字型都可能出现）

    func testDecodeListWithNumericID() throws {
        let data = Data(#"""
        {"page":1,"pagecount":5,"total":120,"list":[
            {"vod_id":12345,"vod_name":"测试番剧","type_name":"国产动漫","vod_remarks":"更新至第12集"},
            {"vod_name":"缺ID的条目"}
        ]}
        """#.utf8)
        let shows = try MacCMSProvider.shows(from: data, providerID: "test.host")
        XCTAssertEqual(shows.count, 1, "缺 vod_id 的条目应被丢弃")
        XCTAssertEqual(shows[0].showID, "12345")
        XCTAssertEqual(shows[0].title, "测试番剧")
        XCTAssertEqual(shows[0].subtitle, "国产动漫 · 更新至第12集")
        XCTAssertEqual(shows[0].seriesKey, "online:test.host:12345")
    }

    func testDecodeListWithStringID() throws {
        // 一些站点的 vod_id 是字符串
        let data = Data(#"""
        {"list":[{"vod_id":"67890","vod_name":"字符串ID番","type_name":"日本动漫","vod_remarks":"HD中字"}]}
        """#.utf8)
        let shows = try MacCMSProvider.shows(from: data, providerID: "test.host")
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual(shows[0].showID, "67890")
        XCTAssertEqual(shows[0].subtitle, "日本动漫 · HD中字")
    }

    // MARK: - 动漫内容过滤（真人电影/解说/体育等不纳入）

    /// 目录与搜索共用 shows(from:)：只保留动漫类目，类目下误挂的解说剔除
    func testShowsFilteredToAnimeCategories() throws {
        let data = Data(#"""
        {"list":[
            {"vod_id":1,"vod_name":"葬送的芙莉莲","type_name":"日本动漫"},
            {"vod_id":2,"vod_name":"速度与激情10","type_name":"动作片"},
            {"vod_id":3,"vod_name":"奔跑吧兄弟","type_name":"综艺"},
            {"vod_id":4,"vod_name":"NBA总决赛集锦","type_name":"体育"},
            {"vod_id":5,"vod_name":"你的名字","type_name":"动画电影"},
            {"vod_id":6,"vod_name":"魔法少女小圆 剧场版","type_name":"剧场版"},
            {"vod_id":7,"vod_name":"葬送的芙莉莲 全网解说","type_name":"日本动漫"},
            {"vod_id":8,"vod_name":"鬼灭之刃 三分钟速看","type_name":"日本动漫"},
            {"vod_id":9,"vod_name":"无类型条目"}
        ]}
        """#.utf8)
        let shows = try MacCMSProvider.shows(from: data, providerID: "test.host")
        // 只剩：1(日本动漫) 5(动画电影) 6(剧场版)；7/8 因标题含解说/速看被剔除；其余类目不符
        XCTAssertEqual(shows.map(\.showID), ["1", "5", "6"])
    }

    /// 分类树 → 动漫相关类目 id（自身命中或父类目命中）
    func testAnimeTypeIDsFromClassTree() {
        let categories = [
            MacCMSProvider.category(from: ["type_id": 1, "type_pid": 0, "type_name": "电影"]),
            MacCMSProvider.category(from: ["type_id": 5, "type_pid": 1, "type_name": "动画电影"]),
            MacCMSProvider.category(from: ["type_id": 2, "type_pid": 0, "type_name": "动漫"]),
            MacCMSProvider.category(from: ["type_id": 21, "type_pid": 2, "type_name": "日本动漫"]),
            MacCMSProvider.category(from: ["type_id": 30, "type_pid": 2, "type_name": "国产动漫"]),
            MacCMSProvider.category(from: ["type_id": 9, "type_pid": 0, "type_name": "体育"]),
        ]
        let ids = MacCMSProvider.animeTypeIDs(from: categories)
        XCTAssertEqual(Set(ids), ["5", "2", "21", "30"])
    }

    func testIsJunkTitle() {
        XCTAssertTrue(MacCMSProvider.isJunkTitle("葬送的芙莉莲 全网解说"))
        XCTAssertTrue(MacCMSProvider.isJunkTitle("鬼灭之刃三分钟速看"))
        XCTAssertFalse(MacCMSProvider.isJunkTitle("葬送的芙莉莲"))
        XCTAssertFalse(MacCMSProvider.isJunkTitle(nil))
    }

    func testDecodeListGarbageThrows() {
        XCTAssertThrowsError(try MacCMSProvider.shows(from: Data("<html>502</html>".utf8), providerID: "x"))
        XCTAssertThrowsError(try MacCMSProvider.shows(from: Data("[]".utf8), providerID: "x"))
    }

    // MARK: - 详情 → 分集

    func testEpisodesFromDetail() throws {
        let data = Data(#"""
        {"list":[{"vod_id":12345,"vod_name":"测试番剧",
                  "vod_play_from":"xff$$$qqm3u8",
                  "vod_play_url":"第01集$http://a/01.swf#第02集$http://a/02.swf$$$第01集$http://b/01.m3u8#第02集$http://b/02.m3u8#番外篇$http://b/sp.m3u8"}]}
        """#.utf8)
        let episodes = try MacCMSProvider.episodes(from: data, providerID: "test.host", showID: "12345")
        // 优先选 m3u8 播放源组
        XCTAssertEqual(episodes.count, 3)
        XCTAssertEqual(episodes[0].number, 1)
        XCTAssertEqual(episodes[0].streamHint, "http://b/01.m3u8")
        XCTAssertEqual(episodes[1].number, 2)
        // 无法解析集号的按出现顺序兜底
        XCTAssertEqual(episodes[2].number, 3)
        XCTAssertEqual(episodes[2].title, "番外篇")
        // 合成键与续播键
        XCTAssertEqual(episodes[0].resumeKey, "online:test.host:12345:1")
    }

    func testEpisodesForEmptyDetail() throws {
        let data = Data(#"{"list":[]}"#.utf8)
        let episodes = try MacCMSProvider.episodes(from: data, providerID: "test.host", showID: "1")
        XCTAssertTrue(episodes.isEmpty)
    }

    // MARK: - 取流（streamHint 在手时无网络请求）

    func testStreamURLUsesHint() async throws {
        let provider = MacCMSProvider(apiBase: URL(string: "https://api.example.com/api.php/provide/vod/")!)
        let episode = OnlineEpisode(providerID: provider.id, showID: "12345", number: 1,
                                    title: "第01集", streamHint: "https://cdn.example.com/01.m3u8?sign=abc")
        let source = try await provider.streamURL(for: episode)
        XCTAssertEqual(source.url.absoluteString, "https://cdn.example.com/01.m3u8?sign=abc")
        XCTAssertTrue(source.isHLS)
        // 防盗链：带站点 Referer 与浏览器 UA
        XCTAssertEqual(source.httpHeaders["Referer"], "https://api.example.com")
        XCTAssertEqual(source.userAgent, MacCMSProvider.browserUserAgent)
    }

    func testStreamURLMP4NotHLS() async throws {
        let provider = MacCMSProvider(apiBase: URL(string: "https://api.example.com/api.php/provide/vod/")!)
        let episode = OnlineEpisode(providerID: provider.id, showID: "1", number: 1,
                                    streamHint: "https://cdn.example.com/video.mp4")
        let source = try await provider.streamURL(for: episode)
        XCTAssertFalse(source.isHLS)
    }

    func testStreamURLWithoutHintAndBadAddressThrows() async throws {
        // 无 streamHint 时的兜底是网络请求；这里用本地不可能成立的地址让它失败即可，
        // 重点验证不崩溃且抛错（真实兜底逻辑见 episodes(for:)）
        let provider = MacCMSProvider(apiBase: URL(string: "https://127.0.0.1:1/api.php/provide/vod/")!)
        let episode = OnlineEpisode(providerID: provider.id, showID: "1", number: 1, streamHint: nil)
        do {
            _ = try await provider.streamURL(for: episode)
            XCTFail("应当失败")
        } catch {
            // 预期：网络错误或 episodeNotFound
        }
    }

    // MARK: - HLS 判定

    func testIsHLS() {
        XCTAssertTrue(MacCMSProvider.isHLS(URL(string: "https://a/x.m3u8")!))
        // 带 query 的 m3u8：pathExtension 仍能取到
        XCTAssertTrue(MacCMSProvider.isHLS(URL(string: "https://a/index.m3u8?token=1")!))
        XCTAssertFalse(MacCMSProvider.isHLS(URL(string: "https://a/video.mp4")!))
    }

    // MARK: - Mock 搜索（协议默认实现为空，Mock 覆盖）

    func testMockSearchFiltersByTitle() async throws {
        let provider = MockProvider(rootDirectory: FileManager.default.temporaryDirectory, episodeDuration: 3)
        let hit = try await provider.search(keyword: "Nagomi")
        XCTAssertEqual(hit.count, 1)
        let miss = try await provider.search(keyword: "不存在的标题")
        XCTAssertTrue(miss.isEmpty)
    }
}

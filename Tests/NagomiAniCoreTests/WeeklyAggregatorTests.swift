import XCTest
@testable import NagomiAniCore

final class WeeklyAggregatorTests: XCTestCase {
    private func poolShow(_ provider: String, _ showID: String, _ title: String,
                          subtitle: String? = nil) -> OnlineShow {
        OnlineShow(providerID: provider, showID: showID, title: title, subtitle: subtitle)
    }

    /// 精确匹配：条目用 Bangumi 正题/封面，流来自命中站点
    func testExactMatchUsesBangumiMetadata() throws {
        let calendar = [CalendarSubject(id: 1, title: "葬送的芙莉莲", coverURL: "https://bgm.tv/cover.jpg")]
        let pool = [
            poolShow("cj.lziapi.com", "9001", "葬送的芙莉莲", subtitle: "日本动漫 · 已完结"),
            poolShow("jszyapi.com", "7002", "葬送的芙莉莲", subtitle: "日本动漫"),
        ]
        let result = WeeklyAggregator.aggregate(calendar: calendar, pool: pool)
        let first = try XCTUnwrap(result.first, "精确匹配不应为空")
        XCTAssertEqual(first.title, "葬送的芙莉莲")
        XCTAssertEqual(first.coverURL, "https://bgm.tv/cover.jpg")
        XCTAssertEqual(first.subtitle, "日本动漫 · 已完结")
        // 站点优先级：先传入的站点胜出
        XCTAssertEqual(first.providerID, "cj.lziapi.com")
        XCTAssertEqual(first.showID, "9001")
        XCTAssertEqual(first.seriesKey, "online:cj.lziapi.com:9001")
    }

    /// 包含关系（续季）也能命中
    func testSeasonContainmentMatches() throws {
        let calendar = [CalendarSubject(id: 1, title: "某番 第二季")]
        let pool = [poolShow("site.a", "1", "某番 第二季")]
        let result = WeeklyAggregator.aggregate(calendar: calendar, pool: pool)
        XCTAssertEqual(try XCTUnwrap(result.first).showID, "1")
    }

    /// 相似度不达标 → 不出现（搜索兜底）
    func testBelowThresholdOmitted() {
        let calendar = [CalendarSubject(id: 1, title: "我独自升级")]
        let pool = [poolShow("site.a", "1", "完全无关的作品名")]
        XCTAssertTrue(WeeklyAggregator.aggregate(calendar: calendar, pool: pool).isEmpty)
    }

    /// 池内同名剧目去重：每个剧目只保留一个条目、一个片源（先传入的站点胜出）。
    /// ⚠️ 带字幕组/画质标签的池标题必须先清洗再匹配（曾因口径不一致导致匹配不上）
    func testPoolDeduplicatedByTitle() throws {
        let calendar = [CalendarSubject(id: 1, title: "芙莉莲")]
        let pool = [
            poolShow("site.a", "1", "[NagomiSub] 芙莉莲 [1080p]"),
            poolShow("site.b", "2", "芙莉莲"),
        ]
        let result = WeeklyAggregator.aggregate(calendar: calendar, pool: pool)
        let first = try XCTUnwrap(result.first, "带标签的池标题清洗后应能匹配")
        XCTAssertEqual(first.providerID, "site.a")
    }

    /// 同一池条目不能服务两部日历番
    func testPoolEntryUsedOnlyOnce() throws {
        let calendar = [
            CalendarSubject(id: 1, title: "某番"),
            CalendarSubject(id: 2, title: "某番 特别篇"),
        ]
        let pool = [poolShow("site.a", "1", "某番")]
        let result = WeeklyAggregator.aggregate(calendar: calendar, pool: pool)
        XCTAssertEqual(result.count, 1, "第二个日历条目没有独立片源就不该出现")
        XCTAssertEqual(try XCTUnwrap(result.first).title, "某番")
    }

    /// 季度一致有加分：放送中的第二季优先命中站里的第二季条目
    func testSeasonBonusPrefersMatchingSeason() throws {
        let calendar = [CalendarSubject(id: 1, title: "某番 第二季")]
        let pool = [
            poolShow("site.a", "10", "某番"),
            poolShow("site.b", "20", "某番 第二季"),
        ]
        let result = WeeklyAggregator.aggregate(calendar: calendar, pool: pool)
        // 两条相似度都不低（包含关系 0.85），季 bonus 让精确同季的胜出
        let first = try XCTUnwrap(result.first)
        XCTAssertEqual(first.showID, "20")
        XCTAssertEqual(first.providerID, "site.b")
    }

    /// 归一化：清洗标签 + 相似度空白标点归一，两级都要生效
    func testNormalize() {
        XCTAssertEqual(WeeklyAggregator.normalize("[NagomiSub] 芙莉莲 [1080p]"), "芙莉莲")
        XCTAssertEqual(WeeklyAggregator.normalize("葬送的芙莉莲"), "葬送的芙莉莲")
        XCTAssertTrue(WeeklyAggregator.normalize("   ").isEmpty)
    }
}

import XCTest
@testable import NagomiAniCore

/// 「最近更新」分组与缓存的行为测试
final class WeekScheduleTests: XCTestCase {

    // MARK: - 构造辅助

    private func makeSubject(id: Int, type: SubjectType? = .anime) -> Subject {
        Subject(
            id: id, type: type, name: "作品\(id)", nameCN: nil, summary: nil,
            airDate: nil, eps: nil, totalEpisodes: nil, images: nil, rating: nil
        )
    }

    /// 构造一份"周一…周日"都齐的日历
    private func makeCalendar(itemsByWeekday: [Int: [Subject]]) -> [CalendarDay] {
        (1...7).map { wd in
            CalendarDay(
                weekday: CalendarDay.Weekday(id: wd, en: nil, cn: nil, ja: nil),
                items: itemsByWeekday[wd]
            )
        }
    }

    /// 固定一个已知日期，避免测试随"今天"变化（2026-09-25 是周五）
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    // MARK: - 分组结构

    /// 必须固定是 7 组（今天 + 前 6 天），空档日也要占位
    func testAlwaysProducesSevenSections() {
        let sections = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [:]), relativeTo: date(2026, 9, 25))
        XCTAssertEqual(sections.count, 7)
    }

    /// 第一组永远是「今天」，其 dateText 为当天月日
    func testFirstSectionIsToday() {
        let sections = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [:]), relativeTo: date(2026, 9, 25))
        XCTAssertEqual(sections[0].title, "今天")
        XCTAssertEqual(sections[0].dateText, "9月25日")
        XCTAssertEqual(sections[0].id, "2026-09-25")
    }

    /// 顺序是倒序：今天 → 昨天 → 前天 …
    func testSectionsAreInReverseChronologicalOrder() {
        let sections = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [:]), relativeTo: date(2026, 9, 25))
        let ids = sections.map(\.id)
        XCTAssertEqual(ids, [
            "2026-09-25", "2026-09-24", "2026-09-23", "2026-09-22",
            "2026-09-21", "2026-09-20", "2026-09-19",
        ])
    }

    /// 2026-09-25 是周五 → 往前依次 周四 周三 周二 周一 周日 周六
    func testWeekdayTitlesFollowChineseWeekOrder() {
        let sections = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [:]), relativeTo: date(2026, 9, 25))
        XCTAssertEqual(sections.map(\.title), ["今天", "周四", "周三", "周二", "周一", "周日", "周六"])
    }

    /// 跨月边界的日期与 id 都要正确
    func testCrossesMonthBoundary() {
        let sections = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [:]), relativeTo: date(2026, 10, 2))
        XCTAssertEqual(sections.map(\.id), [
            "2026-10-02", "2026-10-01", "2026-09-30", "2026-09-29",
            "2026-09-28", "2026-09-27", "2026-09-26",
        ])
        XCTAssertEqual(sections[2].dateText, "9月30日")
    }

    // MARK: - 内容映射

    /// 日历按"周几"组织，必须把正确的 weekday 内容放进对应日期
    func testItemsAreMatchedByWeekday() {
        // 2026-09-25 周五 → weekday 5；2026-09-24 周四 → weekday 4
        let days = makeCalendar(itemsByWeekday: [
            5: [makeSubject(id: 100)],
            4: [makeSubject(id: 200), makeSubject(id: 201)],
        ])
        let sections = WeekSchedule.sections(from: days, relativeTo: date(2026, 9, 25))

        XCTAssertEqual(sections[0].items.map(\.id), [100], "今天(周五)应拿到 weekday 5 的条目")
        XCTAssertEqual(sections[1].items.map(\.id), [200, 201], "昨天(周四)应拿到 weekday 4 的条目")
        XCTAssertTrue(sections[2].items.isEmpty, "没有该 weekday 的条目应为空")
    }

    /// 只保留动画条目，过滤掉游戏/书籍等
    func testOnlyAnimeSubjectsAreKept() {
        let days = makeCalendar(itemsByWeekday: [
            5: [makeSubject(id: 1, type: .anime), makeSubject(id: 2, type: .book), makeSubject(id: 3, type: nil)],
        ])
        let sections = WeekSchedule.sections(from: days, relativeTo: date(2026, 9, 25))
        XCTAssertEqual(sections[0].items.map(\.id), [1, 3], "type 为 nil 的按动画处理，其它类型过滤掉")
    }

    // MARK: - weekday 换算

    func testBangumiWeekdayIDMapping() {
        // 周日 → 7（Bangumi 用 7 表示周日），其余 1..6
        XCTAssertEqual(WeekSchedule.bangumiWeekdayID(for: date(2026, 9, 27)), 7) // 周日
        XCTAssertEqual(WeekSchedule.bangumiWeekdayID(for: date(2026, 9, 28)), 1) // 周一
        XCTAssertEqual(WeekSchedule.bangumiWeekdayID(for: date(2026, 9, 25)), 5) // 周五
    }

    func testDateKeyUsesFixedFormat() {
        XCTAssertEqual(WeekSchedule.dateKey(date(2026, 1, 5)), "2026-01-05")
        XCTAssertEqual(WeekSchedule.dateKey(date(2026, 12, 31)), "2026-12-31")
    }

    // MARK: - 缓存语义

    private func makeCache(fetchedOn: String, items: [Int: [Subject]] = [:]) -> WeekScheduleCache {
        WeekScheduleCache(days: makeCalendar(itemsByWeekday: items), fetchedOn: fetchedOn, updatedAt: Date())
    }

    /// 同一天内：命中缓存，不需要刷新（这就是"秒开、零请求"的依据）
    func testCacheIsFreshOnSameDay() {
        let cache = makeCache(fetchedOn: "2026-09-25")
        XCTAssertFalse(cache.needsRefresh(today: "2026-09-25"))
    }

    /// 跨天：需要后台核对
    func testCacheNeedsRefreshAfterDayChanges() {
        let cache = makeCache(fetchedOn: "2026-09-24")
        XCTAssertTrue(cache.needsRefresh(today: "2026-09-25"))
    }

    /// 缓存里存的是原始日历，所以要能用**新的日期**重建分组：
    /// 昨天写的缓存，今天打开必须把"今天"标在今天上
    func testCacheRebuildsSectionsForCurrentDate() {
        let cache = makeCache(fetchedOn: "2026-09-24", items: [5: [makeSubject(id: 100)]])

        let yesterdayView = cache.sections(now: date(2026, 9, 24))
        let todayView = cache.sections(now: date(2026, 9, 25))

        XCTAssertEqual(yesterdayView[0].id, "2026-09-24")
        XCTAssertEqual(yesterdayView[0].title, "今天")
        XCTAssertEqual(todayView[0].id, "2026-09-25", "跨天后第一组要变成新的今天")
        XCTAssertEqual(todayView[0].title, "今天")
        // 周四(weekday 4)在 09-24 是"今天"，到 09-25 就变成"昨天(周四)"
        XCTAssertEqual(todayView[1].id, "2026-09-24")
        XCTAssertEqual(todayView[1].title, "周四")
    }

    /// 内容未变时判定等价（后台核对后不重绘界面）
    func testSameSectionsDetectsNoChange() {
        let a = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [5: [makeSubject(id: 1)]]), relativeTo: date(2026, 9, 25))
        let b = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [5: [makeSubject(id: 1)]]), relativeTo: date(2026, 9, 25))
        XCTAssertTrue(WeekSchedule.isEquivalent(a, b))
    }

    /// 条目增减/换序要判定为有变化
    func testSameSectionsDetectsItemChange() {
        let a = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [5: [makeSubject(id: 1)]]), relativeTo: date(2026, 9, 25))
        let b = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [5: [makeSubject(id: 2)]]), relativeTo: date(2026, 9, 25))
        XCTAssertFalse(WeekSchedule.isEquivalent(a, b))
    }

    /// 分组数量不同（理论上不会发生）也要判定有变化
    func testSameSectionsDetectsCountMismatch() {
        let a = WeekSchedule.sections(from: makeCalendar(itemsByWeekday: [:]), relativeTo: date(2026, 9, 25))
        XCTAssertFalse(WeekSchedule.isEquivalent(a, Array(a.dropLast())))
    }
}

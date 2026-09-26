import Foundation

/// 搜索页「最近更新（过去一周）」的一天分组（今天在最前，前 6 天依次向后）
public struct WeekUpdateSection: Identifiable, Sendable {
    /// yyyy-MM-dd
    public let id: String
    /// 「今天」或「周一 … 周日」
    public let title: String
    /// 如「9月5日」
    public let dateText: String
    public let items: [Subject]

    public init(id: String, title: String, dateText: String, items: [Subject]) {
        self.id = id
        self.title = title
        self.dateText = dateText
        self.items = items
    }
}

/// 放送日历 → 「今天 → 前 6 天」分组。
///
/// 单独抽出来有两个原因：
/// 1. **可测**：分组/标题/排序/筛选都是纯函数，不依赖网络与界面；
/// 2. **缓存要按天重建**：Bangumi 的 `/calendar` 是按「周几」组织的
///    （`weekday.id` 1=周一…7=周日），同一份日历数据在不同日期对应的
///    「今天」是不同的。所以缓存只存原始 `days`，标题与日期每次按当前时间重建，
///    否则跨零点后会把昨天标成「今天」。
public enum WeekSchedule {

    /// 日历的 `weekday.id`：1=周一 … 7=周日
    public static func bangumiWeekdayID(for date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1=周日 … 7=周六
        return weekday == 1 ? 7 : weekday - 1
    }

    /// yyyy-MM-dd（固定格式，不受语言/地区影响）
    public static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        dateKey(calendar.dateComponents([.year, .month, .day], from: date))
    }

    static func dateKey(_ c: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 把日历整理成「今天 → 前 6 天」共 7 组（含没有更新的空档日）
    public static func sections(
        from days: [CalendarDay],
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WeekUpdateSection] {
        let weekdayCN = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

        return (0...6).compactMap { ago -> WeekUpdateSection? in
            guard let date = calendar.date(byAdding: .day, value: -ago, to: now) else { return nil }
            let weekday = bangumiWeekdayID(for: date, calendar: calendar)
            let items = (days.first { $0.weekday?.id == weekday }?.items ?? [])
                .filter { $0.type == .anime || $0.type == nil }
            let comps = calendar.dateComponents([.month, .day], from: date)
            return WeekUpdateSection(
                id: dateKey(calendar.dateComponents([.year, .month, .day], from: date)),
                title: ago == 0 ? "今天" : weekdayCN[weekday - 1],
                dateText: "\(comps.month ?? 1)月\(comps.day ?? 1)日",
                items: items
            )
        }
    }
}

public extension WeekSchedule {
    /// 两组分组是否等价（逐日按 subjectID 顺序比较）。
    /// 后台核对拿到新日历后用它判断"是否真的变了"，没变就不刷新界面、避免闪烁。
    static func isEquivalent(_ lhs: [WeekUpdateSection], _ rhs: [WeekUpdateSection]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.id != b.id { return false }
            if a.title != b.title { return false }
            if a.items.count != b.items.count { return false }
            if zip(a.items, b.items).contains(where: { $0.id != $1.id }) { return false }
        }
        return true
    }
}

/// 「最近更新」缓存：存**原始日历**（按周几组织），不存已经算好的分组。
///
/// 时间语义与收藏缓存不同：日历内容只在换周（周一）后才可能变，所以
/// `needsRefresh` 看的是**缓存当天是否就是今天**，而不是单纯的 TTL。
/// 这样同一天内反复进出搜索页都是秒开、零请求；跨天后第一次进入会自动核对。
public struct WeekScheduleCache: Sendable {
    /// 原始日历
    public private(set) var days: [CalendarDay]
    /// 该缓存对应的日期（yyyy-MM-dd），即拉取当天
    public private(set) var fetchedOn: String
    /// 拉取时刻
    public private(set) var updatedAt: Date

    public init(days: [CalendarDay], fetchedOn: String, updatedAt: Date) {
        self.days = days
        self.fetchedOn = fetchedOn
        self.updatedAt = updatedAt
    }

    /// 需要重新拉取吗：还没缓存，或已经跨天
    public func needsRefresh(today: String) -> Bool {
        fetchedOn != today
    }

    /// 用当前日期重建分组（保证「今天」永远正确，即便缓存是昨天写的）
    public func sections(now: Date = Date(), calendar: Calendar = .current) -> [WeekUpdateSection] {
        WeekSchedule.sections(from: days, relativeTo: now, calendar: calendar)
    }
}

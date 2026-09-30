import Foundation
import NagomiAniCore

/// 播放参数包：在线页/云端番库点播时交给 PlayerModel.load 的全部内容，
/// 也作为自动连播"下一集"的载体（本地下一集 isLocal=true，seriesKey/resumeKey 留空）
struct OnlinePlayback {
    let url: URL
    let displayTitle: String?
    let seriesKey: String
    let episodeNumber: Int
    let resumeKey: String?
    let httpHeaders: [String: String]
    let userAgent: String?
    /// 已绑定的 Bangumi 条目（nil = 未绑定；经 PlayerModel.bindLocal 复用绑定保证播完自动同步）
    let boundSubjectID: Int?
    let boundSubject: Subject?
    /// 剧名（弹弹play 弹幕按剧名+集号搜索用；本地条目为空串）
    var showTitle: String = ""
    /// 全部可用线路（含当前 url；播放失败自动换源与手动切换线路用）
    var routes: [String] = []
    /// 本地文件（来自番库的连播目标）；false = 在线流
    var isLocal: Bool = false
}

/// 在线片源页的状态模型：
/// - 汇总各 Provider 的目录与跨站搜索，组装点播参数
/// - Bangumi 绑定与已看徽章（与 PlayerModel 共用同一张 UserDefaults 绑定表）
/// - 苹果CMS 资源站管理（仓库不内置任何站点，用户自行添加/移除）
@MainActor
final class OnlineStore: ObservableObject {
    @Published private(set) var shows: [OnlineShow] = []
    /// show.id → 集列表
    @Published private(set) var episodes: [String: [OnlineEpisode]] = [:]
    @Published var statusMessage: String?
    @Published private(set) var isLoadingShows = false
    @Published private(set) var isPreparing = false

    private(set) var providers: [SourceProvider] = []
    private var showsLoaded = false
    /// 会话内见过的番注册表（seriesKey → show）：搜索结果点播后连播/继续观看依赖它
    private var knownShows: [String: OnlineShow] = [:]

    // MARK: - 资源站管理与跨站搜索

    static let sitesKey = "online.maccms.sites"

    /// 内置默认资源站（2026-09-27 应用户要求内置；均为 senfun.in 等聚合站实际引用的公开上游采集接口，已实测可用：
    /// 量子/极速/爱坤经 senfun 播放页 m3u8 域名反向确认，暴风为额外验证的大型通用站）。
    /// 用户不可移除内置源，但可继续自行添加；id 取域名进合成 seriesKey，勿改地址。
    struct DefaultSite {
        let name: String
        let base: String
    }

    static let defaultSites: [DefaultSite] = [
        DefaultSite(name: "量子资源", base: "https://cj.lziapi.com"),
        DefaultSite(name: "极速资源", base: "https://jszyapi.com"),
        DefaultSite(name: "爱坤资源", base: "https://ikunzyapi.com"),
        DefaultSite(name: "暴风资源", base: "https://bfzyapi.com"),
    ]

    /// 用户添加的苹果CMS 资源站（归一化 API 地址，UserDefaults 持久化）
    @Published private(set) var sites: [String] = []
    /// 非 nil 时列表切换为搜索结果（nil = 浏览默认目录）
    @Published private(set) var onlineSearchResults: [OnlineShow]?
    @Published private(set) var isSearchingOnline = false
    private var searchGeneration = 0

    init() {
        sites = UserDefaults.standard.stringArray(forKey: Self.sitesKey) ?? []
        if let data = UserDefaults.standard.data(forKey: Self.libraryEntriesKey),
           let entries = try? JSONDecoder().decode([OnlineLibraryEntry].self, from: data) {
            libraryEntries = entries
        }
        loadKnownShows()
        rebuildProviders()
    }

    // MARK: - 云端番库（在线剧集加入番库）

    static let libraryEntriesKey = "online.library.entries"
    /// 用户加入番库的云端剧集（UserDefaults JSON 持久化；绑定/已看仍在共用绑定表与 Bangumi）
    @Published private(set) var libraryEntries: [OnlineLibraryEntry] = []

    func isInLibrary(_ show: OnlineShow) -> Bool {
        libraryEntries.contains { $0.id == show.id }
    }

    func addToLibrary(_ show: OnlineShow) {
        registerKnownShows([show])
        guard !isInLibrary(show) else { return }
        libraryEntries.append(OnlineLibraryEntry(show: show))
        saveLibraryEntries()
        statusMessage = "已加入番库：\(show.title)"
    }

    func removeFromLibrary(_ show: OnlineShow) {
        libraryEntries.removeAll { $0.id == show.id }
        saveLibraryEntries()
        statusMessage = "已从番库移除：\(show.title)"
    }

    private func saveLibraryEntries() {
        if let data = try? JSONEncoder().encode(libraryEntries) {
            UserDefaults.standard.set(data, forKey: Self.libraryEntriesKey)
        }
    }

    /// Mock 样例源永远保留（全链路演示/兜底），后接内置默认源与用户添加的资源站
    private func rebuildProviders() {
        var list: [SourceProvider] = [MockProvider()]
        let defaultProviders = Self.defaultSites.compactMap { site -> SourceProvider? in
            guard let provider = MacCMSProvider(base: site.base) else { return nil }
            return MacCMSProvider(apiBase: provider.apiBase, displayName: site.name)
        }
        list.append(contentsOf: defaultProviders)
        let defaultIDs = Set(defaultProviders.map(\.id))
        for site in sites {
            guard let provider = MacCMSProvider(base: site) else { continue }
            guard !defaultIDs.contains(provider.id) else { continue } // 与内置源重复的跳过
            list.append(provider)
        }
        providers = list
    }

    /// 添加用户自定义资源站（与内置源重复的地址会被拒绝）
    func addSite(_ raw: String) {
        guard let provider = MacCMSProvider(base: raw) else {
            statusMessage = "无法识别的站点地址：\(raw)"
            return
        }
        let normalized = provider.apiBase.absoluteString
        let defaultNormalized = Set(Self.defaultSites.compactMap { MacCMSProvider(base: $0.base)?.apiBase.absoluteString })
        if defaultNormalized.contains(normalized) {
            statusMessage = "该站点已内置为默认片源"
            return
        }
        if sites.contains(normalized) {
            statusMessage = "该站点已添加：\(provider.displayName)"
            return
        }
        sites.append(normalized)
        UserDefaults.standard.set(sites, forKey: Self.sitesKey)
        rebuildProviders()
        // 站点列表变了：详情页「在线观看」的片源匹配结果作废，重新展开时重搜
        sourceMatches.removeAll()
        sourceMatchMessages.removeAll()
        statusMessage = "已添加片源：\(provider.displayName)"
        Task { await reloadShows() }
    }

    func removeSite(_ raw: String) {
        sites.removeAll { $0 == raw }
        UserDefaults.standard.set(sites, forKey: Self.sitesKey)
        rebuildProviders()
        sourceMatches.removeAll()
        sourceMatchMessages.removeAll()
        statusMessage = "已移除片源"
        Task { await reloadShows() }
    }

    private func reloadShows() async {
        showsLoaded = false
        onlineSearchResults = nil
        await loadShowsIfNeeded()
    }

    /// 跨站搜索：扇出到各 Provider（代际守卫防慢站结果覆盖新搜索）
    func searchOnline(_ keyword: String) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            onlineSearchResults = nil
            return
        }
        isSearchingOnline = true
        searchGeneration += 1
        let generation = searchGeneration
        // spinner 只由最新一次搜索管理：旧搜索的 defer 若无条件关闭，
        // 会把并行进行中的新搜索的 spinner 提前熄灭
        defer {
            if generation == searchGeneration { isSearchingOnline = false }
        }
        var results: [OnlineShow] = []
        for provider in providers {
            do {
                let found = try await provider.search(keyword: trimmed)
                guard generation == searchGeneration else { return } // 已被新搜索取代
                registerKnownShows(found)
                results.append(contentsOf: found)
                onlineSearchResults = results
            } catch {
                // 过期搜索的失败消息同样不得覆盖界面
                guard generation == searchGeneration else { return }
                statusMessage = "\(provider.displayName) 搜索失败：\(error.localizedDescription)"
            }
        }
        if generation == searchGeneration, results.isEmpty {
            statusMessage = "没有找到「\(trimmed)」相关内容"
        }
    }

    func clearOnlineSearch() {
        searchGeneration += 1
        onlineSearchResults = nil
    }

    func providerName(for show: OnlineShow) -> String? {
        provider(id: show.providerID)?.displayName
    }

    // MARK: - Bangumi 绑定与已看徽章
    /// 合成 seriesKey（"online:<provider>:<showID>"）直通 PlayerModel 的 markWatched 自动同步
    /// subjectID → Subject（已关联条目的封面/名称展示）
    @Published private(set) var subjects: [Int: Subject] = [:]
    /// seriesKey → 已看集号集合（来自 Bangumi 我的单集收藏）
    @Published private(set) var watchedEpisodes: [String: Set<Int>] = [:]
    @Published private(set) var isLoadingWatched: Set<String> = []
    @Published var searchResults: [Subject] = []
    @Published var isSearching = false
    /// 当前绑定 sheet 的目标番（nil = 关闭）
    @Published var bindTarget: OnlineShow?

    // MARK: - 自动匹配候选（与番库同一套 BangumiMatcher 评分：相似度 + 集数佐证 + 季度判定）

    /// show.id → 自动匹配候选（nil = 还没算过；确认绑定后清空）
    @Published private(set) var bindCandidates: [String: [MatchCandidate]] = [:]
    @Published private(set) var isLoadingCandidates = false

    /// 为指定番计算自动匹配候选（打开绑定 sheet 时触发；有缓存不重复请求）
    func loadBindCandidates(for show: OnlineShow) async {
        if bindCandidates[show.id] != nil { return }
        guard !isLoadingCandidates else { return }
        isLoadingCandidates = true
        defer { isLoadingCandidates = false }
        guard let client = await BangumiSession.makeClient() else {
            statusMessage = "未登录 Bangumi，无法自动匹配（请先在「聊天」页登录）"
            return
        }
        // 集数佐证用片源分集数（列表还没加载过就先拉一次）
        var episodeCount: Int? = episodes[show.id]?.count
        if episodeCount == nil {
            await ensureEpisodes(for: show)
            episodeCount = episodes[show.id]?.count
        }
        // 季号与番库同源：从标题识别（"第二季"/"S2" 等）
        let season = MediaMatching.seasonNumber(from: show.title)
        do {
            let matcher = BangumiMatcher(client: client)
            bindCandidates[show.id] = try await matcher.candidates(
                title: show.title,
                episodeCount: episodeCount,
                season: season,
                limit: 5
            )
        } catch {
            statusMessage = "自动匹配失败：\(error.localizedDescription)"
        }
    }

    func binding(for seriesKey: String) -> Int? {
        (UserDefaults.standard.dictionary(forKey: PlayerModel.bindingsKey) as? [String: Int])?[seriesKey]
    }

    func bind(subject: Subject, to show: OnlineShow) {
        let seriesKey = show.seriesKey
        var ids = UserDefaults.standard.dictionary(forKey: PlayerModel.bindingsKey) as? [String: Int] ?? [:]
        var names = UserDefaults.standard.dictionary(forKey: PlayerModel.boundNamesKey) as? [String: String] ?? [:]
        ids[seriesKey] = subject.id
        names[seriesKey] = subject.displayName.isEmpty ? "未命名" : subject.displayName
        UserDefaults.standard.set(ids, forKey: PlayerModel.bindingsKey)
        UserDefaults.standard.set(names, forKey: PlayerModel.boundNamesKey)
        subjects[subject.id] = subject
        bindTarget = nil
        // 已关联不再显示"建议 N"，之后点"更换"会重新匹配（与番库同规则）
        bindCandidates[show.id] = nil
        statusMessage = "已关联「\(names[seriesKey] ?? "")」，本系列播完自动同步"
        Task { await refreshWatched(for: show) }
    }

    func unbind(for show: OnlineShow) {
        let seriesKey = show.seriesKey
        var ids = UserDefaults.standard.dictionary(forKey: PlayerModel.bindingsKey) as? [String: Int] ?? [:]
        var names = UserDefaults.standard.dictionary(forKey: PlayerModel.boundNamesKey) as? [String: String] ?? [:]
        ids.removeValue(forKey: seriesKey)
        names.removeValue(forKey: seriesKey)
        UserDefaults.standard.set(ids, forKey: PlayerModel.bindingsKey)
        UserDefaults.standard.set(names, forKey: PlayerModel.boundNamesKey)
        watchedEpisodes[seriesKey] = nil
        statusMessage = "已解除关联"
    }

    /// 绑定 sheet 的 Bangumi 条目搜索
    func search(keyword: String) async {
        guard let client = await BangumiSession.makeClient() else {
            statusMessage = "未登录 Bangumi，无法搜索（请先在「聊天」页登录）"
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await client.searchSubjects(keyword: keyword, limit: 20).data
        } catch {
            searchResults = []
            statusMessage = "搜索失败：\(error.localizedDescription)"
        }
    }

    /// 已关联条目的封面/名称（未缓存时静默补拉）
    func ensureSubject(for show: OnlineShow) async {
        guard let id = binding(for: show.seriesKey), subjects[id] == nil else { return }
        guard let client = await BangumiSession.makeClient() else { return }
        if let subject = try? await client.subject(id: id) {
            subjects[id] = subject
        }
    }

    /// 拉取该系列的已看集号（Bangumi 我的单集收藏；未登录/失败静默跳过）
    func refreshWatched(for show: OnlineShow) async {
        guard let id = binding(for: show.seriesKey) else { return }
        guard !isLoadingWatched.contains(show.id) else { return }
        isLoadingWatched.insert(show.id)
        defer { isLoadingWatched.remove(show.id) }
        guard let client = await BangumiSession.makeClient() else { return }
        do {
            let page = try await client.myEpisodeCollections(subjectID: id)
            var watched = Set<Int>()
            for item in page.data where item.type == .watched {
                if let sort = item.episode?.sort {
                    watched.insert(Int(sort.rounded()))
                }
            }
            watchedEpisodes[show.seriesKey] = watched
        } catch {
            // 徽章拉取失败不影响播放，静默降级
        }
    }

    func isWatched(_ episode: OnlineEpisode) -> Bool {
        watchedEpisodes[episode.seriesKey]?.contains(episode.number) == true
    }

    // MARK: - 目录

    // MARK: - 目录（放送日历聚合：与 Bangumi「最近更新（过去一周）」同一套剧目）

    /// 放送日历聚合结果的一天分组（与搜索页「过去一周」同构）。
    /// totalCount = 该日放送番总数（含尚未匹配到的）；渐进加载时差额渲染为占位卡
    struct WeeklyShowSection: Codable, Identifiable {
        let id: String // yyyy-MM-dd
        let title: String // 今天/周一…
        let dateText: String // 9月28日
        var shows: [OnlineShow]
        var totalCount: Int?
    }

    static let weeklyCacheKey = "online.weekly.cache"

    /// 非 nil 且 isCalendarMode 时，目录按天分组展示
    @Published private(set) var weeklySections: [WeeklyShowSection] = []
    /// true = 目录来自放送日历聚合；false = 回退的站点目录
    @Published private(set) var isCalendarMode = false
    /// 渐进加载进行中：差额位置渲染"匹配中"占位卡
    @Published private(set) var isMatching = false
    /// 详情页当前展示的番（覆盖层导航：返回时目录滚动位置保留）
    @Published private(set) var selectedShow: OnlineShow?

    /// 进入番详情（封面卡片点击）
    func open(_ show: OnlineShow) {
        registerKnownShows([show])
        selectedShow = show
    }

    /// 返回目录
    func back() {
        selectedShow = nil
    }

    func loadShowsIfNeeded() async {
        guard !showsLoaded, !isLoadingShows else { return }
        isLoadingShows = true
        defer { isLoadingShows = false }

        // 当天缓存：放送周内同一天再进页面零请求（与搜索页"过去一周"缓存同语义）
        let today = WeekSchedule.dateKey(Date())
        if let cached = loadWeeklyCache(), cached.fetchedOn == today {
            applyWeeklySections(cached.sections)
            showsLoaded = true
            return
        }

        // 1) 放送日历（/calendar 公开接口，匿名客户端即可）
        let client = await BangumiSession.makeClient() ?? BangumiClient()
        guard let days = try? await client.calendar(), !days.isEmpty else {
            statusMessage = "放送日历加载失败，已回退到站点目录"
            await loadFallbackDirectory()
            showsLoaded = true
            return
        }
        let sections = WeekSchedule.sections(from: days) // 已过滤动画类型
        var sectionMeta: [(id: String, title: String, dateText: String)] = []
        var flatSubjects: [(sectionIndex: Int, subject: CalendarSubject)] = []
        var seenSubjects: Set<Int> = []
        for (index, section) in sections.enumerated() {
            sectionMeta.append((section.id, section.title, section.dateText))
            for subject in section.items where seenSubjects.insert(subject.id).inserted {
                flatSubjects.append((index, CalendarSubject(
                    id: subject.id, title: subject.displayName, coverURL: subject.images?.common
                )))
            }
        }

        // 2) **渐进式**：骨架先发布（按天分组 + 占位卡），用户立刻能看到结构；
        //    flatSubjects 天然按「今天 → 前 6 天」排序，最近的番最先匹配、最先点亮
        var results: [Int: OnlineShow] = [:] // subjectID → 聚合条目
        isMatching = true
        rebuildWeekly(sectionMeta: sectionMeta, flatSubjects: flatSubjects, results: results)

        // 3) 池子先兜（各站最新一页，便宜）：每拉到一个站点就匹配一轮、即时发布
        let maccms = providers.compactMap { $0 as? MacCMSProvider }
        var pool: [OnlineShow] = []
        for provider in maccms {
            pool += (try? await provider.listShows()) ?? []
            for item in flatSubjects where results[item.subject.id] == nil {
                if let match = WeeklyAggregator.bestMatch(item.subject, in: pool) {
                    results[item.subject.id] = WeeklyAggregator.makeEntry(subject: item.subject, source: match.show)
                }
            }
            rebuildWeekly(sectionMeta: sectionMeta, flatSubjects: flatSubjects, results: results)
        }

        // 4) 剩余的按更新时间顺序（日历序）逐番搜索资源站（并发 4，命中即停），
        //    每命中一部就发布一次，用户看着列表逐步补齐
        let unmatched = flatSubjects.filter { results[$0.subject.id] == nil }
        let total = unmatched.count
        if !unmatched.isEmpty {
            var done = 0
            statusMessage = "正在为放送番匹配片源 0/\(total)…"
            await withTaskGroup(of: (Int, OnlineShow?).self) { group in
                var inFlight = 0
                for item in unmatched {
                    if inFlight >= 4 {
                        if let (id, show) = await group.next() {
                            done += 1
                            if let show { results[id] = show }
                            rebuildWeekly(sectionMeta: sectionMeta, flatSubjects: flatSubjects, results: results)
                            statusMessage = "正在为放送番匹配片源 \(done)/\(total)…"
                        }
                        inFlight -= 1
                    }
                    inFlight += 1
                    group.addTask {
                        for provider in maccms { // 站点优先级：内置顺序
                            guard let hits = try? await provider.search(keyword: item.subject.title) else { continue }
                            if let match = WeeklyAggregator.bestMatch(item.subject, in: hits) {
                                return (item.subject.id, WeeklyAggregator.makeEntry(subject: item.subject, source: match.show))
                            }
                        }
                        return (item.subject.id, nil)
                    }
                }
                while let (id, show) = await group.next() {
                    done += 1
                    if let show { results[id] = show }
                    rebuildWeekly(sectionMeta: sectionMeta, flatSubjects: flatSubjects, results: results)
                    statusMessage = "正在为放送番匹配片源 \(done)/\(total)…"
                }
            }
        }

        // 5) 收尾：清除占位 + 当天缓存
        isMatching = false
        rebuildWeekly(sectionMeta: sectionMeta, flatSubjects: flatSubjects, results: results)
        saveWeeklyCache(sections: weeklySections, fetchedOn: today)
        if weeklySections.flatMap(\.shows).isEmpty {
            statusMessage = "放送日历里的番暂未在资源站找到片源，可用上方搜索按剧名查找"
        } else {
            statusMessage = nil
        }
        showsLoaded = true
    }

    /// 用当前匹配结果重建分组并发布（自动关联在每次重建时补写，已绑定的不覆盖）。
    /// 没有放送番的日期不生成空分组（避免页面出现空洞的组头）。
    private func rebuildWeekly(
        sectionMeta: [(id: String, title: String, dateText: String)],
        flatSubjects: [(sectionIndex: Int, subject: CalendarSubject)],
        results: [Int: OnlineShow]
    ) {
        var weekly: [WeeklyShowSection] = []
        for (index, meta) in sectionMeta.enumerated() {
            let sectionSubjects = flatSubjects.filter { $0.sectionIndex == index }
            guard !sectionSubjects.isEmpty else { continue }
            let shows = sectionSubjects.compactMap { results[$0.subject.id] }
            weekly.append(WeeklyShowSection(
                id: meta.id, title: meta.title, dateText: meta.dateText,
                shows: shows, totalCount: sectionSubjects.count
            ))
        }
        applyWeeklySections(weekly)
        autoBindCalendarShows(weekly.flatMap(\.shows))
    }

    /// 放送日历条目自动关联 Bangumi（2026-09-27 用户决策：日历自带精确 subjectID，
    /// 不再要求手动关联）。已有的手动绑定不覆盖；解除后重载也不会再自动绑（除非换番）。
    private func autoBindCalendarShows(_ shows: [OnlineShow]) {
        var ids = UserDefaults.standard.dictionary(forKey: PlayerModel.bindingsKey) as? [String: Int] ?? [:]
        var names = UserDefaults.standard.dictionary(forKey: PlayerModel.boundNamesKey) as? [String: String] ?? [:]
        var changed = false
        for show in shows {
            guard let subjectID = show.bangumiSubjectID else { continue }
            let key = show.seriesKey
            if ids[key] == nil {
                ids[key] = subjectID
                names[key] = show.title
                changed = true
            }
        }
        guard changed else { return }
        UserDefaults.standard.set(ids, forKey: PlayerModel.bindingsKey)
        UserDefaults.standard.set(names, forKey: PlayerModel.boundNamesKey)
    }

    private func applyWeeklySections(_ sections: [WeeklyShowSection]) {
        // 过滤已移除片源的番：当天缓存里可能还留着旧站点的条目，
        // 不滤掉的话点开会永远停在"加载分集…"（provider 查不到）
        let cleaned = sections.compactMap { section -> WeeklyShowSection? in
            let shows = section.shows.filter { provider(id: $0.providerID) != nil }
            guard !shows.isEmpty else { return nil }
            var filtered = section
            filtered.shows = shows
            return filtered
        }
        weeklySections = cleaned
        isCalendarMode = true
        let all = cleaned.flatMap(\.shows)
        shows = all
        registerKnownShows(all)
    }

    /// 日历不可用（无网络/接口失败）→ 回退各站最新目录的旧形态
    private func loadFallbackDirectory() async {
        isCalendarMode = false
        weeklySections = []
        var all: [OnlineShow] = []
        for provider in providers {
            do {
                all += try await provider.listShows()
            } catch {
                statusMessage = "\(provider.displayName) 加载失败：\(error.localizedDescription)"
            }
        }
        shows = all
        registerKnownShows(all)
    }

    private struct WeeklyCache: Codable {
        let fetchedOn: String
        let sections: [WeeklyShowSection]
    }

    private func loadWeeklyCache() -> (fetchedOn: String, sections: [WeeklyShowSection])? {
        guard let data = UserDefaults.standard.data(forKey: Self.weeklyCacheKey),
              let cache = try? JSONDecoder().decode(WeeklyCache.self, from: data) else { return nil }
        return (cache.fetchedOn, cache.sections)
    }

    private func saveWeeklyCache(sections: [WeeklyShowSection], fetchedOn: String) {
        if let data = try? JSONEncoder().encode(WeeklyCache(fetchedOn: fetchedOn, sections: sections)) {
            UserDefaults.standard.set(data, forKey: Self.weeklyCacheKey)
        }
    }

    /// 展开番条目/行出现时加载集列表（幂等）。
    /// 返回 true = 已有分集数据（可直接用）；false = 刚从网络拉取（调用方无需再强刷）
    @discardableResult
    func ensureEpisodes(for show: OnlineShow) async -> Bool {
        if episodes[show.id] != nil { return true }
        guard let provider = provider(id: show.providerID) else {
            // 片源已被移除：落空列表让详情页结束加载态，而不是永远转圈
            episodes[show.id] = []
            statusMessage = "片源「\(show.providerID)」已移除，无法加载分集"
            return true
        }
        registerKnownShows([show])
        do {
            episodes[show.id] = try await provider.episodes(for: show.showID)
        } catch {
            episodes[show.id] = []
            statusMessage = "\(provider.displayName) 集列表加载失败：\(error.localizedDescription)"
        }
        return false
    }

    // MARK: - 点播

    /// 取流 URL 并组装播放参数。已绑定的番带上 Bangumi 条目，
    /// PlayerModel 经 bindLocal 复用绑定保证播完自动同步。
    func preparePlayback(show: OnlineShow, episode: OnlineEpisode) async throws -> OnlinePlayback {
        guard let provider = provider(id: episode.providerID) else {
            throw OnlineStoreError.unknownProvider
        }
        isPreparing = true
        defer { isPreparing = false }
        registerKnownShows([show])
        statusMessage = "正在准备「\(show.title) 第 \(episode.number) 集」的片源…"
        let source = try await provider.streamURL(for: episode)
        statusMessage = nil
        // 已整体缓存的集直接播本地副本（HLS 为重写的本地 playlist）
        let playURL = cache.cachedMediaURL(for: episode.resumeKey) ?? source.url
        let boundID = binding(for: episode.seriesKey)
        return OnlinePlayback(
            url: playURL,
            displayTitle: Self.displayTitle(show: show, episode: episode),
            seriesKey: episode.seriesKey,
            episodeNumber: episode.number,
            resumeKey: episode.resumeKey,
            httpHeaders: source.httpHeaders,
            userAgent: source.userAgent,
            boundSubjectID: boundID,
            boundSubject: boundID.flatMap { subjects[$0] },
            showTitle: show.title,
            routes: Self.routeList(episode: episode, primary: playURL)
        )
    }

    /// 线路列表：当前地址在最前（缓存副本优先），片源给的其余线路去重追加
    static func routeList(episode: OnlineEpisode, primary: URL) -> [String] {
        var list = [primary.absoluteString]
        for route in episode.routes ?? [] where !list.contains(route) {
            list.append(route)
        }
        return list
    }

    private func provider(id: String) -> SourceProvider? {
        providers.first { $0.id == id }
    }

    // MARK: - 搜索详情页「在线观看」：按条目按需搜片源

    /// Bangumi 条目 id → 匹配到的片源番（按标题相似度+季号加成降序）
    @Published private(set) var sourceMatches: [String: [OnlineShow]] = [:]
    @Published private(set) var isLoadingSourceMatches: Set<String> = []
    @Published private(set) var sourceMatchMessages: [String: String] = [:]
    /// 片源搜索代次：切换条目后旧搜索的结果/错误不得覆盖新条目
    private var sourceMatchGeneration = 0

    /// 按条目标题跨站搜片源并评分排序（搜索详情页展开「在线观看」时触发）。
    /// 铁律：相似度比较前双侧过 cleanTitle（与放送日历聚合同一套口径，§4.19）；
    /// 代际守卫防旧条目的慢结果覆盖新条目。
    func searchSources(for subject: Subject) async {
        let subjectKey = String(subject.id)
        if sourceMatches[subjectKey] != nil || isLoadingSourceMatches.contains(subjectKey) { return }
        let title = subject.displayName
        guard !title.isEmpty else {
            sourceMatchMessages[subjectKey] = "该条目没有可用标题，无法搜索片源"
            return
        }
        isLoadingSourceMatches.insert(subjectKey)
        sourceMatchMessages[subjectKey] = nil
        defer { isLoadingSourceMatches.remove(subjectKey) }
        sourceMatchGeneration += 1
        let generation = sourceMatchGeneration

        var pool: [OnlineShow] = []
        for provider in providers {
            do {
                let found = try await provider.search(keyword: title)
                guard generation == sourceMatchGeneration else { return }
                registerKnownShows(found)
                pool.append(contentsOf: found)
            } catch {
                // 单站失败不中断（与跨站搜索同策略），但记录一条提示
                guard generation == sourceMatchGeneration else { return }
                sourceMatchMessages[subjectKey] = "\(provider.displayName) 搜索失败：\(error.localizedDescription)"
            }
        }
        guard generation == sourceMatchGeneration else { return }
        let scored = WeeklyAggregator.score(title, candidates: pool)
        sourceMatches[subjectKey] = scored.map(\.show)
        if scored.isEmpty, sourceMatchMessages[subjectKey] == nil {
            sourceMatchMessages[subjectKey] = "各片源站未找到与「\(title)」对应的资源，可稍后重试或手动添加片源"
        }
    }

    // MARK: - 追番更新提醒（拉取式：展开云端番时刷新分集并对比上次查看数量）

    /// 有新集的数量（当前分集数 - 上次展开查看时的数量）；nil = 无数据或没更新
    func newEpisodeCount(for show: OnlineShow) -> Int? {
        guard let entry = libraryEntries.first(where: { $0.id == show.id }),
              let lastSeen = entry.lastSeenEpisodeCount,
              let count = episodes[show.id]?.count, count > lastSeen else { return nil }
        return count - lastSeen
    }

    /// 标记该番的分集已查看（展开番行时调用）
    func markEpisodesSeen(_ show: OnlineShow) {
        guard let index = libraryEntries.firstIndex(where: { $0.id == show.id }) else { return }
        let count = episodes[show.id]?.count ?? 0
        guard libraryEntries[index].lastSeenEpisodeCount != count else { return }
        libraryEntries[index].lastSeenEpisodeCount = count
        saveLibraryEntries()
    }

    /// 强制重新拉取分集（忽略缓存）——检查资源站是否更新了新集
    func refreshEpisodes(for show: OnlineShow) async {
        guard let provider = provider(id: show.providerID) else { return }
        do {
            episodes[show.id] = try await provider.episodes(for: show.showID)
        } catch {
            statusMessage = "\(provider.displayName) 分集刷新失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 自动连播（云端下一集）

    /// 解析同一片源里的下一集；没有下一集返回 nil（连播自然停止）
    func nextPlayback(seriesKey: String, afterNumber: Int) async throws -> OnlinePlayback? {
        guard let show = show(forSeriesKey: seriesKey) else { return nil }
        await ensureEpisodes(for: show)
        guard let episodes = episodes[show.id],
              let next = episodes.first(where: { $0.number > afterNumber }) else { return nil }
        return try await preparePlayback(show: show, episode: next)
    }

    /// seriesKey 反查番：已知注册表（含搜索结果里出现过的）→ 目录 → 番库收藏。
    /// 搜索结果直接点播的番不在目录列表里，没有注册表的话连播/继续观看会找不到它
    private func show(forSeriesKey seriesKey: String) -> OnlineShow? {
        if let known = knownShows[seriesKey] { return known }
        return (shows + libraryEntries.map(\.asShow)).first { $0.seriesKey == seriesKey }
    }

    /// 本会话内见过的所有番（目录/搜索结果/点播/收藏），seriesKey → OnlineShow
    func knownShow(forSeriesKey seriesKey: String) -> OnlineShow? {
        knownShows[seriesKey]
    }

    private func registerKnownShows(_ newShows: [OnlineShow]) {
        var changed = false
        for show in newShows {
            if knownShows[show.seriesKey] != show {
                knownShows[show.seriesKey] = show
                changed = true
            }
        }
        if changed {
            persistKnownShows()
        }
    }

    // 番注册表持久化（UserDefaults）：重启后缓存区块/继续观看仍能认出
    // "这集缓存属于哪部番"，不依赖当次会话是否浏览过
    private struct KnownShowRecord: Codable {
        let providerID: String
        let showID: String
        let title: String
        let subtitle: String?
        let coverURL: String?
    }

    static let knownShowsKey = "online.known.shows"

    private func persistKnownShows() {
        let records = knownShows.values.map {
            KnownShowRecord(providerID: $0.providerID, showID: $0.showID,
                            title: $0.title, subtitle: $0.subtitle, coverURL: $0.coverURL)
        }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.knownShowsKey)
        }
    }

    private func loadKnownShows() {
        guard let data = UserDefaults.standard.data(forKey: Self.knownShowsKey),
              let records = try? JSONDecoder().decode([KnownShowRecord].self, from: data) else { return }
        for record in records {
            knownShows[OnlineShow.seriesKey(providerID: record.providerID, showID: record.showID)] = OnlineShow(
                providerID: record.providerID, showID: record.showID,
                title: record.title, subtitle: record.subtitle, coverURL: record.coverURL
            )
        }
    }

    /// 播放器顶部/窗口标题统一显示的标题
    static func displayTitle(show: OnlineShow, episode: OnlineEpisode) -> String {
        "\(show.title) · 第 \(episode.number) 集"
    }

    // MARK: - 本地缓存（StreamCache：HLS 分片 / 单文件）

    private let cache = StreamCache()
    /// 已完整缓存的 resumeKey 集合
    @Published private(set) var cachedKeys: Set<String> = []
    /// 「我的缓存」聚合条目（跨番）
    @Published private(set) var cachedItems: [CachedEpisodeItem] = []
    /// 下载中的 resumeKey → 进度（含字节级：已下载/总大小，总大小可能未知）
    @Published private(set) var cacheProgress: [String: StreamCache.Progress] = [:]
    /// 已缓存条目的磁盘占用（resumeKey → 字节）
    @Published private(set) var cacheSizes: [String: Int64] = [:]
    /// 缓存总字节数
    @Published private(set) var cacheTotalBytes: Int64 = 0
    private var cacheTasks: [String: Task<Void, Never>] = [:]
    /// 下载并发上限：同站多路并发会被资源站限流/断连（用户报告"只有部分成功"的根因）
    private let maxConcurrentDownloads = 2
    /// 排队中尚未开始的下载
    private var pendingDownloads: [(show: OnlineShow, episode: OnlineEpisode)] = []
    private var activeDownloadCount = 0
    /// 失败的缓存任务（key → 信息）：面板中展示并可重试/移除
    struct FailedCacheItem: Identifiable {
        let id: String
        let show: OnlineShow
        let episode: OnlineEpisode
        let message: String
    }
    @Published private(set) var failedCaches: [String: FailedCacheItem] = [:]

    enum CacheState: Equatable {
        case notCached
        case downloading(StreamCache.Progress)
        case cached
    }

    func cacheState(for episode: OnlineEpisode) -> CacheState {
        if let progress = cacheProgress[episode.resumeKey] {
            return .downloading(progress)
        }
        if cachedKeys.contains(episode.resumeKey) {
            return .cached
        }
        return .notCached
    }

    /// 已缓存条目的磁盘占用
    func cacheSize(for episode: OnlineEpisode) -> Int64? {
        cacheSizes[episode.resumeKey]
    }

    /// 启动时恢复缓存状态展示
    func refreshCacheState() {
        cachedKeys = cache.cachedKeys()
        cacheTotalBytes = cache.totalBytes()
        var sizes: [String: Int64] = [:]
        for key in cachedKeys {
            if let size = cache.sizeBytes(for: key) {
                sizes[key] = size
            }
        }
        cacheSizes = sizes
        rebuildCachedItems()
    }

    /// 缓存/进度 key（resumeKey）→ 所属番与集（knownShows/番库收藏反查；番未知返回 nil）
    func episodeInfo(forResumeKey key: String) -> (show: OnlineShow, episode: OnlineEpisode)? {
        guard key.hasPrefix("online:") else { return nil }
        let parts = key.dropFirst("online:".count).split(separator: ":").map(String.init)
        guard parts.count == 3, let number = Int(parts[2]) else { return nil }
        let seriesKey = String(key.dropLast(":\(number)".count))
        guard let show = knownShows[seriesKey]
            ?? libraryEntries.first(where: {
                $0.providerID == parts[0] && $0.showID == parts[1]
            })?.asShow else { return nil }
        return (show, OnlineEpisode(providerID: show.providerID, showID: show.showID, number: number))
    }

    /// 从已缓存 key 聚合「我的缓存」条目（按番名+集号排序；番未知的跳过）
    private func rebuildCachedItems() {
        cachedItems = cachedKeys.compactMap { key -> CachedEpisodeItem? in
            guard let info = episodeInfo(forResumeKey: key) else { return nil }
            return CachedEpisodeItem(id: key, show: info.show, episode: info.episode,
                                     sizeBytes: cacheSizes[key] ?? 0)
        }
        .sorted { lhs, rhs in
            if lhs.show.title != rhs.show.title { return lhs.show.title < rhs.show.title }
            return lhs.episode.number < rhs.episode.number
        }
    }

    /// 手动缓存一集（HLS 走分片下载 + 本地 playlist；渐进式走整文件流式落盘）
    /// 手动缓存一集：登记进下载队列（并发 2），失败进 failedCaches 可重试
    func startCache(show: OnlineShow, episode: OnlineEpisode) {
        let key = episode.resumeKey
        guard cacheTasks[key] == nil, !cachedKeys.contains(key),
              failedCaches[key] == nil, cacheProgress[key] == nil,
              !pendingDownloads.contains(where: { $0.episode.resumeKey == key }) else { return }
        guard provider(id: episode.providerID) != nil else {
            statusMessage = "未知的片源提供方"
            return
        }
        failedCaches[key] = nil
        cacheProgress[key] = StreamCache.Progress(downloadedSegments: 0, totalSegments: 0) // 排队占位
        pendingDownloads.append((show: show, episode: episode))
        pumpDownloads()
    }

    /// 下载队列调度：最多 maxConcurrentDownloads 个并行
    private func pumpDownloads() {
        while activeDownloadCount < maxConcurrentDownloads, !pendingDownloads.isEmpty {
            let item = pendingDownloads.removeFirst()
            activeDownloadCount += 1
            let key = item.episode.resumeKey
            let task = Task {
                await runDownload(show: item.show, episode: item.episode)
                activeDownloadCount -= 1
                // 只在正常结束时清句柄：被取消的任务由 cancelCache 清。
                // 否则"取消 → 立即重下"时，旧任务退出会抹掉新任务的句柄，二次取消失效
                if !Task.isCancelled {
                    cacheTasks[key] = nil
                }
                pumpDownloads() // 启动队列中的下一个
            }
            cacheTasks[key] = task
        }
    }

    private func runDownload(show: OnlineShow, episode: OnlineEpisode) async {
        let key = episode.resumeKey
        let cache = cache
        defer { cacheProgress[key] = nil }
        do {
            guard let provider = provider(id: episode.providerID) else {
                throw OnlineStoreError.unknownProvider
            }
            let source = try await provider.streamURL(for: episode)
            let progressHandler: @Sendable (StreamCache.Progress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.cacheProgress[key] = progress
                }
            }
            if source.isHLS {
                _ = try await cache.download(
                    playlistURL: source.url,
                    httpHeaders: source.httpHeaders,
                    userAgent: source.userAgent,
                    cacheKey: key,
                    progress: progressHandler
                )
            } else {
                _ = try await cache.downloadFile(
                    url: source.url,
                    httpHeaders: source.httpHeaders,
                    userAgent: source.userAgent,
                    cacheKey: key,
                    progress: progressHandler
                )
            }
            cachedKeys.insert(key)
            cacheSizes[key] = cache.sizeBytes(for: key)
            cacheTotalBytes = cache.totalBytes()
            rebuildCachedItems()
            failedCaches[key] = nil
            statusMessage = "已缓存「\(show.title) 第 \(episode.number) 集」"
        } catch {
            // 用户取消（Task.isCancelled，或落在最后一轮请求里的 URLError.cancelled）：
            // 不登记为失败——那是用户主动行为，出现"缓存失败 cancelled"只会困惑
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return
            }
            failedCaches[key] = FailedCacheItem(
                id: key, show: show, episode: episode, message: error.localizedDescription
            )
            statusMessage = "缓存失败：「\(show.title) 第 \(episode.number) 集」— \(error.localizedDescription)"
        }
    }

    /// 重试失败的缓存
    func retryCache(for episode: OnlineEpisode) {
        guard let failed = failedCaches[episode.resumeKey] else { return }
        failedCaches[episode.resumeKey] = nil
        startCache(show: failed.show, episode: failed.episode)
    }

    /// 面板中移除失败记录（不重试）
    func dismissCacheFailure(for episode: OnlineEpisode) {
        failedCaches[episode.resumeKey] = nil
    }

    func cancelCache(for episode: OnlineEpisode) {
        let key = episode.resumeKey
        cacheTasks[key]?.cancel()
        cacheTasks[key] = nil
        pendingDownloads.removeAll { $0.episode.resumeKey == key }
        cacheProgress[key] = nil
        failedCaches[key] = nil
    }

    func removeCache(for episode: OnlineEpisode) {
        cache.purge(cacheKey: episode.resumeKey)
        cachedKeys.remove(episode.resumeKey)
        cacheSizes[episode.resumeKey] = nil
        cacheTotalBytes = cache.totalBytes()
        rebuildCachedItems()
    }

    func clearAllCache() {
        cache.purgeAll()
        cachedKeys.removeAll()
        cacheSizes.removeAll()
        failedCaches.removeAll()
        cacheTotalBytes = 0
        statusMessage = "已清除全部缓存"
        rebuildCachedItems()
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// 进度条下的尺寸文本："12.3 MB / 45.6 MB"；总大小未知时只显示已下载
    static func progressBytesLabel(_ progress: StreamCache.Progress) -> String {
        let downloaded = formattedBytes(progress.downloadedBytes)
        if let total = progress.totalBytes {
            return "\(downloaded) / \(formattedBytes(total))"
        }
        return downloaded
    }
}

enum OnlineStoreError: LocalizedError {
    case unknownProvider

    var errorDescription: String? {
        switch self {
        case .unknownProvider: return "未知的片源提供方"
        }
    }
}

/// 云端番库条目：用户从在线页"加入番库"的剧集，与本地番在番库页并列展示。
/// 点击播放时按 providerID 找到对应片源取流（本地文件走 MediaLibrary，云端走这里）。
struct OnlineLibraryEntry: Codable, Identifiable, Equatable {
    let providerID: String
    let showID: String
    let title: String
    let subtitle: String?
    /// 上次展开查看时的分集数（更新提醒的对比基准；nil = 还没看过）
    var lastSeenEpisodeCount: Int?

    var id: String { "\(providerID):\(showID)" }

    init(show: OnlineShow) {
        self.providerID = show.providerID
        self.showID = show.showID
        self.title = show.title
        self.subtitle = show.subtitle
        self.lastSeenEpisodeCount = nil
    }

    /// 还原为 OnlineShow（取流/Bangumi 绑定/已看徽章都需要）
    var asShow: OnlineShow {
        OnlineShow(providerID: providerID, showID: showID, title: title, subtitle: subtitle)
    }
}

/// 「我的缓存」区块条目：跨番聚合的已缓存分集
struct CachedEpisodeItem: Identifiable {
    let id: String // resumeKey
    let show: OnlineShow
    let episode: OnlineEpisode
    let sizeBytes: Int64
}

import AppKit
import Foundation
import NagomiAniCore

/// 番库的 UI 状态模型
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var series: [Series] = []
    @Published var folders: [String] = []
    @Published var isScanning = false
    @Published var isMatching = false
    @Published var statusMessage: String?
    /// subjectID → Subject（用于显示封面与 Bangumi 名称）
    @Published var subjects: [Int: Subject] = [:]
    /// subjectID → 集数列表（番库展开时按 Bangumi 集数序列展示，缺集标记"未找到"）
    @Published var episodesBySubject: [Int: [Episode]] = [:]
    /// 手动绑定的搜索
    @Published var searchResults: [Subject] = []
    @Published var isSearching = false
    /// 自动匹配候选（seriesKey → 候选列表，仅供展示，不自动绑定）
    @Published var candidates: [String: [MatchCandidate]] = [:]
    /// 当前绑定弹窗展示的候选
    @Published var bindCandidates: [MatchCandidate] = []
    @Published var isLoadingCandidates = false
    /// 当前等待绑定的系列键（非 nil 时弹出绑定弹窗）
    @Published var bindTarget: String? {
        didSet {
            guard let key = bindTarget else { return }
            Task { await loadBindCandidates(for: key) }
        }
    }
    /// 等待确认移除的番（非 nil 时弹出确认）
    @Published var seriesToRemove: Series?
    /// 更新后本地文件全部消失、需要用户选择"移动位置 / 已删除"的番（非 nil 时弹窗）
    @Published var vanishedSeries: Series?

    private let library: MediaLibrary
    /// 目录监控（FSEvents）：有监控目录时启用，folders 变化自动重建
    private var monitor: FSEventsDirectoryMonitor?
    /// 监控流当前对应的根目录（判断是否需要重建）
    private var monitoredFolders: [String] = []
    /// 监控事件换算出的待重扫目标（事件到达时累积，单个后台任务串行消费）
    private var pendingMonitorTargets: Set<String> = []
    private var monitorApplyTask: Task<Void, Never>?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NagomiAni", isDirectory: true)
        let storeURL = dir.appendingPathComponent("library.json")
        library = MediaLibrary(storeURL: storeURL)
        reload()
        Task { await ensureSubjects() }
        Task { await ensureEpisodes() }
        Task { await runAutoMatch() }
    }

    deinit {
        monitor?.stop()
    }

    // MARK: - 目录

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "选择动漫目录，将递归扫描其中的视频文件"
        guard panel.runModal() == .OK else { return }

        var added = false
        for url in panel.urls {
            added = library.addFolder(url.path) || added
        }
        if added {
            rescan()
        } else {
            reload()
        }
    }

    func requestRemoveSeries(_ series: Series) {
        seriesToRemove = series
    }

    func cancelRemoveSeries() {
        seriesToRemove = nil
    }

    /// 从番库移除某部番：只删该番自己的索引与关联，磁盘文件不受影响。
    /// ⚠️ 绝不能用 owningFolder + removeFolder——"一个根目录多部番"的典型布局下
    /// owningFolder 是库根，会把根下所有番的索引与关联连带删掉。
    /// 磁盘文件还在，登记忽略避免下次扫描把该番扫回库（重新添加目录时自动解除）。
    func confirmRemoveSeries() {
        guard let series = seriesToRemove else { return }
        library.removeSeries(series.seriesKey, ignoreFutureScans: true)
        subjects = subjects.filter { key, _ in
            library.series.contains { $0.subjectID == key }
        }
        seriesToRemove = nil
        reload()
        statusMessage = "已从番库移除「\(series.displayName)」"
    }

    /// 只重扫某部番所在目录（检测新集补齐 / 文件删除）
    func rescanFolder(of series: Series) {
        guard !isScanning else { return }
        isScanning = true
        statusMessage = nil
        let key = series.seriesKey
        let library = self.library
        Task.detached(priority: .userInitiated) {
            library.rescanFolder(key)
            await MainActor.run {
                self.isScanning = false
                self.reload()
                // 更新后这部番一个本地文件都不剩（已关联的被保留为空条目）
                // → 让用户决定：文件是移动了还是删除了
                if let now = self.library.series.first(where: { $0.seriesKey == key }),
                   now.files.isEmpty, now.subjectID != nil {
                    self.vanishedSeries = now
                }
            }
        }
    }

    // MARK: - 本地文件全部消失后的二选一

    func dismissVanished() {
        vanishedSeries = nil
    }

    /// 用户选「我移动了文件位置」：选新目录并把 Bangumi 关联迁过去
    func relocateVanishedSeries() {
        guard let series = vanishedSeries else { return }
        // alert 按钮回调时弹窗仍在收尾：延后到下一 runloop 再开目录面板，避免模态嵌套
        let displayName = series.displayName
        let oldKey = series.seriesKey
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "选择「\(displayName)」移动后的目录（包含该番视频的文件夹）"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            self.isScanning = true
            let library = self.library
            Task.detached(priority: .userInitiated) {
                let newKey = library.relocateSeries(oldSeriesKey: oldKey, to: url.path)
                await MainActor.run {
                    self.isScanning = false
                    self.vanishedSeries = nil
                    self.reload()
                    if newKey != nil {
                        self.statusMessage = "已在新位置恢复「\(displayName)」，Bangumi 关联已保留"
                    } else {
                        self.statusMessage = "所选目录里没有找到该番的视频（或同时有多部番），请选择该番自己的文件夹后重试"
                    }
                }
            }
        }
    }

    /// 用户选「文件已删除」：直接从番库移除该条目
    func confirmDeleteVanishedSeries() {
        guard let series = vanishedSeries else { return }
        let name = series.displayName
        library.removeSeries(series.seriesKey)
        vanishedSeries = nil
        reload()
        statusMessage = "已从番库移除「\(name)」"
    }

    // MARK: - 扫描与自动匹配

    func rescan() {
        isScanning = true
        statusMessage = nil
        let library = self.library
        Task.detached(priority: .userInitiated) {
            library.rescan()
            await MainActor.run {
                self.reload()
                self.isScanning = false
                Task { await self.runAutoMatch() }
            }
        }
    }

    /// 自动匹配：为未关联的番生成候选（不自动绑定，等待用户确认）。
    /// 单实例运行：三个入口（启动/重扫完成/监控刷新）都可能触发，
    /// 并发重跑会重复打全网搜索且 isMatching 状态互相踩。
    func runAutoMatch() async {
        guard !isMatching else { return }
        let targets = library.series.filter { $0.matchState == .unmatched }
        guard !targets.isEmpty else { return }
        guard let client = await BangumiSession.makeClient() else { return }

        isMatching = true
        statusMessage = "正在自动匹配 \(targets.count) 部番…"
        defer {
            isMatching = false
            reload()
        }

        let matcher = BangumiMatcher(client: client)
        var withSuggestions = 0

        for series in targets {
            do {
                let cands = try await matcher.candidates(series: series, limit: 5)
                if let best = cands.first, !cands.isEmpty {
                    candidates[series.seriesKey] = cands
                    if best.score >= matcher.pendingThreshold {
                        library.markPending(seriesKey: series.seriesKey)
                    }
                    withSuggestions += 1
                }
            } catch {
                // 单个失败不中断整体
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        statusMessage = "自动匹配完成：\(withSuggestions) 部找到了候选，点「关联」确认"
        reload()
    }

    /// 加载某个系列的自动匹配候选（供绑定弹窗展示）
    func loadBindCandidates(for seriesKey: String) async {
        guard let series = library.series.first(where: { $0.seriesKey == seriesKey }) else { return }

        if let cached = candidates[seriesKey], !cached.isEmpty {
            bindCandidates = cached
            return
        }
        guard let client = await BangumiSession.makeClient() else {
            bindCandidates = []
            statusMessage = "未登录 Bangumi，无法匹配（请先在「聊天」页登录）"
            return
        }

        isLoadingCandidates = true
        defer { isLoadingCandidates = false }
        do {
            let cands = try await BangumiMatcher(client: client).candidates(series: series, limit: 5)
            bindCandidates = cands
            candidates[seriesKey] = cands
        } catch {
            bindCandidates = []
            statusMessage = "自动匹配失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 手动绑定

    func seriesName(for seriesKey: String?) -> String {
        guard let seriesKey,
              let series = library.series.first(where: { $0.seriesKey == seriesKey }) else {
            return ""
        }
        return series.displayName
    }

    func searchForBinding(keyword: String) async {
        guard let client = await BangumiSession.makeClient() else {
            statusMessage = "未登录 Bangumi，无法搜索"
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

    func bind(subject: Subject) {
        guard let key = bindTarget else { return }
        bind(subject: subject, to: key)
    }

    /// 将某个条目绑定到指定系列（手动搜索结果或自动候选确认）
    func bind(subject: Subject, to seriesKey: String) {
        library.setBinding(seriesKey: seriesKey, subjectID: subject.id)
        subjects[subject.id] = subject
        // 拉取该条目的集数列表（番库展开按集数显示）
        if episodesBySubject[subject.id] == nil {
            Task { [weak self] in
                guard let self,
                      let client = await BangumiSession.makeClient(),
                      let page = try? await client.episodes(subjectID: subject.id, type: 0, limit: 200) else { return }
                self.episodesBySubject[subject.id] = page.data
            }
        }
        // 清除候选缓存：已关联不再显示"建议 N"，且之后点"更换"会重新匹配
        candidates[seriesKey] = nil
        bindTarget = nil
        statusMessage = "已关联「\(subject.displayName)」"
        reload()
    }

    // MARK: - 自动连播（本地下一集）

    /// 找本地系列的下一集（按番库文件顺序）；没有下一集返回 nil
    func nextLocalPlayback(after url: URL) -> OnlinePlayback? {
        guard let series = library.series.first(where: { $0.files.contains { $0.path == url.path } }) else {
            return nil
        }
        let files = series.sortedFiles
        guard let index = files.firstIndex(where: { $0.path == url.path }),
              index + 1 < files.count else { return nil }
        let next = files[index + 1]
        return OnlinePlayback(
            url: URL(fileURLWithPath: next.path),
            displayTitle: nil,
            seriesKey: "",
            episodeNumber: next.episodeNumber ?? 0,
            resumeKey: nil,
            httpHeaders: [:],
            userAgent: nil,
            boundSubjectID: series.subjectID,
            boundSubject: cover(for: series),
            isLocal: true
        )
    }

    // MARK: - 封面与名称

    func cover(for series: Series) -> Subject? {
        guard let id = series.subjectID else { return nil }
        return subjects[id]
    }

    func ensureSubjects() async {
        guard let client = await BangumiSession.makeClient() else { return }
        let matched = library.series.filter { $0.matchState == .matched && $0.subjectID != nil }
        for series in matched {
            guard let id = series.subjectID, subjects[id] == nil else { continue }
            if let subject = try? await client.subject(id: id) {
                subjects[id] = subject
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - 集数列表（按 Bangumi 集数序列展示）

    /// 启动时预拉取所有已关联条目的集数列表（节流）
    func ensureEpisodes() async {
        guard let client = await BangumiSession.makeClient() else { return }
        let matched = library.series.filter { $0.matchState == .matched && $0.subjectID != nil }
        for series in matched {
            guard let id = series.subjectID, episodesBySubject[id] == nil else { continue }
            if let page = try? await client.episodes(subjectID: id, type: 0, limit: 200) {
                episodesBySubject[id] = page.data
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// 懒加载某部番的集数列表（缓存为空时才请求；未登录/失败静默）
    func ensureEpisodes(for series: Series) async {
        guard let id = series.subjectID, episodesBySubject[id] == nil else { return }
        guard let client = await BangumiSession.makeClient() else { return }
        if let page = try? await client.episodes(subjectID: id, type: 0, limit: 200) {
            episodesBySubject[id] = page.data
        }
    }

    /// 某部番的 Bangumi 集数列表（未关联/未拉取到则为 nil）
    func episodes(for series: Series) -> [Episode]? {
        guard let id = series.subjectID else { return nil }
        return episodesBySubject[id]
    }

    // MARK: - 私有

    private func reload() {
        series = library.series
        folders = library.folders
        startDirectoryMonitoringIfNeeded()
    }

    // MARK: - 目录监控（FSEvents）

    /// folders 变化时重建监控流；没有目录则不监控
    private func startDirectoryMonitoringIfNeeded() {
        let current = library.folders
        if monitor != nil, monitoredFolders == current { return }
        monitor?.stop()
        monitoredFolders = current
        guard !current.isEmpty else {
            monitor = nil
            return
        }
        monitor = FSEventsDirectoryMonitor(roots: current) { [weak self] paths in
            Task { @MainActor [weak self] in
                self?.handleMonitoredChanges(paths)
            }
        }
        monitor?.start()
    }

    /// 监控事件 → 最小重扫目标集 → 后台串行重扫。
    /// 背景路径不弹 vanishedSeries 模态（那是手动重扫的 UI 流程），只更新列表与状态栏。
    private func handleMonitoredChanges(_ paths: [String]) {
        let targets = DirectoryChangePlanner.rescanTargets(
            eventPaths: paths,
            roots: library.folders,
            seriesKeys: library.series.map(\.seriesKey)
        )
        guard !targets.isEmpty else { return }
        pendingMonitorTargets.formUnion(targets)
        guard monitorApplyTask == nil else { return }
        monitorApplyTask = Task.detached(priority: .utility) { [weak self] in
            await self?.applyMonitorTargets()
        }
    }

    /// 串行消费 pendingMonitorTargets：后台重扫 → 主线程刷新。
    /// nonisolated：rescanFolder 是磁盘扫描，不能占住主线程（与 rescanFolder(of:) 同理）。
    nonisolated private func applyMonitorTargets() async {
        let library = self.library
        while true {
            let step: (batch: [String], drained: Bool) = await MainActor.run { [weak self] in
                guard let self else { return ([], true) }
                if self.pendingMonitorTargets.isEmpty {
                    // 与 handleMonitoredChanges 同在主线程：判空和清 task 引用是原子的，
                    // 不会出现"任务已退出但引用还在、新事件只入队无人消费"的竞态
                    self.monitorApplyTask = nil
                    return ([], true)
                }
                let batch = Array(self.pendingMonitorTargets)
                self.pendingMonitorTargets = []
                return (batch, false)
            }
            if step.drained { break }
            for target in step.batch {
                library.rescanFolder(target)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.reload()
                self.statusMessage = "目录监控：检测到文件变化，番库已自动更新"
                // 新入库的未匹配番：后台生成候选（只出候选，不自动绑定）
                let hasNewUnmatched = self.library.series.contains {
                    $0.matchState == .unmatched && (self.candidates[$0.seriesKey] ?? []).isEmpty
                }
                if hasNewUnmatched {
                    Task { await self.runAutoMatch() }
                }
            }
        }
    }
}

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
    /// 等待确认移除的目录
    @Published var folderToRemove: String?

    private let library: MediaLibrary

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NagomiAni", isDirectory: true)
        let storeURL = dir.appendingPathComponent("library.json")
        library = MediaLibrary(storeURL: storeURL)
        reload()
        Task { await ensureSubjects() }
        Task { await runAutoMatch() }
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

    func requestRemoveFolder(_ path: String) {
        folderToRemove = path
    }

    func cancelRemoveFolder() {
        folderToRemove = nil
    }

    func confirmRemoveFolder() {
        guard let folder = folderToRemove else { return }
        library.removeFolder(folder)
        folderToRemove = nil
        subjects = subjects.filter { key, _ in
            library.series.contains { $0.subjectID == key }
        }
        reload()
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

    /// 自动匹配：为未关联的番生成候选（不自动绑定，等待用户确认）
    func runAutoMatch() async {
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
            statusMessage = "未登录 Bangumi，无法匹配（请先在 Bangumi 页登录）"
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
        // 清除候选缓存：已关联不再显示"建议 N"，且之后点"更换"会重新匹配
        candidates[seriesKey] = nil
        bindTarget = nil
        statusMessage = "已关联「\(subject.nameCN ?? subject.name ?? "")」"
        reload()
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

    // MARK: - 私有

    private func reload() {
        series = library.series
        folders = library.folders
    }
}

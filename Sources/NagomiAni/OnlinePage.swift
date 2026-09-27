import SwiftUI
import NagomiAniCore

/// 在线片源页（侧边栏「在线」）
struct OnlinePage: View {
    @ObservedObject var model: OnlineStore
    /// 点击某一集时回调（由外层切换到播放器页并加载在线流）
    var onPlay: (OnlinePlayback) -> Void

    @State private var expandedShows: Set<String> = []
    @State private var preparingEpisodeID: String?
    @State private var showSourceSheet = false
    @State private var searchKeyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchBar
            content
            if let message = model.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("在线")
        .task {
            await model.loadShowsIfNeeded()
            model.refreshCacheState()
        }
        .sheet(isPresented: $showSourceSheet) {
            OnlineSourceSheet(model: model)
        }
        // 绑定 sheet 由 ContentView 根视图统一呈现（番库页也会触发）
    }

    // MARK: - 视图

    private var header: some View {
        HStack {
            Text("在线")
                .font(.title2)
            Spacer()
            Text("缓存 \(OnlineStore.formattedBytes(model.cacheTotalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("清除全部缓存") {
                model.clearAllCache()
            }
            .controlSize(.small)
            .disabled(model.cacheTotalBytes == 0)
            Button {
                showSourceSheet = true
            } label: {
                Label("添加片源", systemImage: "plus.circle")
            }
            .controlSize(.small)
            if model.isPreparing || model.isLoadingShows {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// 跨站搜索（苹果CMS 资源站 + 样例源）
    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("搜索片源（资源站关键词）", text: $searchKeyword)
                .textFieldStyle(.roundedBorder)
                .onSubmit { searchOnline() }
            Button("搜索") {
                searchOnline()
            }
            .disabled(searchKeyword.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearchingOnline)
            if model.isSearchingOnline {
                ProgressView()
                    .controlSize(.small)
            }
            if model.onlineSearchResults != nil {
                Button("返回目录") {
                    model.clearOnlineSearch()
                    searchKeyword = ""
                }
            }
        }
    }

    private func searchOnline() {
        let keyword = searchKeyword
        Task { await model.searchOnline(keyword) }
    }

    @ViewBuilder
    private var content: some View {
        if model.shows.isEmpty {
            emptyState
        } else {
            showList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.tv")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(model.isLoadingShows
                 ? "正在加载片源…"
                 : "没有加载到任何内容\n可在「添加片源」里检查资源站或稍后重试")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(list) { show in
                    showRow(show)
                }
            }
        }
    }

    /// 搜索结果优先，否则浏览默认目录
    private var list: [OnlineShow] {
        model.onlineSearchResults ?? model.shows
    }

    private func showRow(_ show: OnlineShow) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(show)) {
            let eps = model.episodes[show.id] ?? []
            ForEach(eps) { episode in
                episodeRow(show: show, episode: episode)
            }
            if eps.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
        } label: {
            HStack(spacing: 10) {
                coverView(show)
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        bindBadge(show)
                        // 未关联且已有自动匹配结果时提示建议数（与番库同规则：已关联后隐藏）
                        if model.binding(for: show.seriesKey) == nil,
                           let candidates = model.bindCandidates[show.id], !candidates.isEmpty {
                            Text("建议 \(candidates.count)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let subject = boundSubject(show) {
                            Text(subject.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if let subtitle = show.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if show.providerID != "mock", let siteName = model.providerName(for: show) {
                            Text(siteName)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                // 加入/移出番库：加入后与本地番并列显示在番库页（云端标记）
                Button {
                    if model.isInLibrary(show) {
                        model.removeFromLibrary(show)
                    } else {
                        model.addToLibrary(show)
                    }
                } label: {
                    Image(systemName: model.isInLibrary(show) ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isInLibrary(show) ? Color.accentColor : Color.secondary)
                .font(.system(size: 15))
                .help(model.isInLibrary(show) ? "从番库移除" : "加入番库")
                bindButton(for: show)
                if model.binding(for: show.seriesKey) != nil {
                    Button {
                        model.unbind(for: show)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15))
                    .help("解除关联")
                }
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        // 行出现即加载集列表（幂等）
        .task(id: show.id) { await model.ensureEpisodes(for: show) }
        // 行出现时补拉已关联条目的封面/名称
        .task(id: "\(show.id)-subject") { await model.ensureSubject(for: show) }
    }

    /// 已关联显示 Bangumi 封面，否则用占位图标
    @ViewBuilder
    private func coverView(_ show: OnlineShow) -> some View {
        if let subject = boundSubject(show),
           let url = SearchPage.imageURL(subject.images?.common) {
            CoverImageView(url: url, cornerRadius: 4)
                .frame(width: 44, height: 60)
        } else {
            Image(systemName: "play.tv")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 60)
                .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func boundSubject(_ show: OnlineShow) -> Subject? {
        model.binding(for: show.seriesKey).flatMap { model.subjects[$0] }
    }

    @ViewBuilder
    private func bindBadge(_ show: OnlineShow) -> some View {
        if model.binding(for: show.seriesKey) != nil {
            Text("已关联")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Text("未关联")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    private func bindButton(for show: OnlineShow) -> some View {
        Button {
            model.bindTarget = show
        } label: {
            Text(model.binding(for: show.seriesKey) != nil ? "更换" : "关联")
        }
        .controlSize(.small)
    }

    /// 集行：主体是播放按钮（含已看徽章），尾部是独立的缓存控制按钮（不能嵌套进播放按钮）
    private func episodeRow(show: OnlineShow, episode: OnlineEpisode) -> some View {
        HStack(spacing: 8) {
            Button {
                play(show: show, episode: episode)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .foregroundStyle(.tint)
                    Text(episode.title ?? "第 \(episode.number) 集")
                        .font(.callout)
                        .lineLimit(1)
                    if model.isWatched(episode) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text("已看")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if preparingEpisodeID == episode.id {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            cacheControl(show: show, episode: episode)
        }
        .padding(.leading, 54)
        .padding(.vertical, 4)
    }

    /// 集行尾部的缓存控制：未缓存=下载、下载中=进度条+字节数+取消、已缓存=徽章+大小+删除
    @ViewBuilder
    private func cacheControl(show: OnlineShow, episode: OnlineEpisode) -> some View {
        switch model.cacheState(for: episode) {
        case .notCached:
            Button {
                model.startCache(show: show, episode: episode)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 15))
            .help("缓存本集到本地")
        case .downloading(let progress):
            VStack(alignment: .trailing, spacing: 2) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 96)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 96, alignment: .trailing)
                }
                Text(OnlineStore.progressBytesLabel(progress))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                model.cancelCache(for: episode)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
            .help("取消缓存")
        case .cached:
            VStack(alignment: .trailing, spacing: 1) {
                Text("已缓存")
                    .font(.caption2)
                    .foregroundStyle(.green)
                if let size = model.cacheSize(for: episode) {
                    Text(OnlineStore.formattedBytes(size))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                model.removeCache(for: episode)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.system(size: 13))
            .help("删除本地缓存")
        }
    }

    // MARK: - 动作

    private func play(show: OnlineShow, episode: OnlineEpisode) {
        preparingEpisodeID = episode.id
        Task {
            defer { preparingEpisodeID = nil }
            do {
                let target = try await model.preparePlayback(show: show, episode: episode)
                onPlay(target)
            } catch {
                model.statusMessage = "播放失败：\(error.localizedDescription)"
            }
        }
    }

    private func expandedBinding(_ show: OnlineShow) -> Binding<Bool> {
        Binding(
            get: { expandedShows.contains(show.id) },
            set: { expanded in
                if expanded {
                    expandedShows.insert(show.id)
                    // 展开时刷新已看徽章（绑定可能刚在别处同步过）
                    Task { await model.refreshWatched(for: show) }
                } else {
                    expandedShows.remove(show.id)
                }
            }
        )
    }
}

/// 「添加片源」sheet：粘贴苹果CMS 资源站地址（首页或完整 API 地址均可），可管理已添加站点
struct OnlineSourceSheet: View {
    @ObservedObject var model: OnlineStore
    @State private var urlText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加片源（苹果CMS V10 资源站）")
                .font(.headline)

            HStack {
                TextField("https://example.com（站点地址或 API 地址）", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("添加") { add() }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            Text("内置片源（\(OnlineStore.defaultSites.count) 个，不可移除）")
                .font(.caption)
                .foregroundStyle(.secondary)
            List {
                ForEach(OnlineStore.defaultSites, id: \.base) { site in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name)
                                .font(.body)
                            Text(URL(string: site.base)?.host ?? site.base)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("内置")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }

                if !model.sites.isEmpty {
                    Section("手动添加（\(model.sites.count) 个）") {
                        ForEach(model.sites, id: \.self) { site in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(string: site)?.host ?? site)
                                        .font(.body)
                                    Text(site)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    model.removeSite(site)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("移除该站点")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Spacer()

            Text("说明：内置源为公开采集接口的苹果CMS 资源站；也可粘贴其它站点首页地址自动拼接接口路径。内容均来自互联网公开接口，请遵守站点条款与当地法规。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 460, height: 420)
    }

    private func add() {
        let text = urlText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.addSite(text)
        urlText = ""
    }
}

/// 在线番的 Bangumi 绑定 sheet：与番库的 LibraryBindSheet 同构——
/// 打开先跑 BangumiMatcher 自动匹配（相似度+集数佐证+季度判定，点选确认），
/// 也可在下方手动搜索；确认后清除建议缓存
struct OnlineBindSheet: View {
    @ObservedObject var model: OnlineStore
    let show: OnlineShow

    @State private var keyword = ""
    @State private var hasSearched = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("为「\(show.title)」关联 Bangumi 条目")
                .font(.headline)
                .lineLimit(1)

            // 自动匹配结果（与番库同一套评分机制）
            if model.isLoadingCandidates {
                ProgressView("正在自动匹配…")
                    .padding(.vertical, 16)
            } else if let candidates = model.bindCandidates[show.id], !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自动匹配结果（点选确认）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(candidates) { candidate in
                                Button {
                                    model.bind(subject: candidate.subject, to: show)
                                    dismiss()
                                } label: {
                                    candidateRow(candidate)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
            } else if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                Text("没有自动匹配结果，请用下方搜索")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            Divider()

            // 手动搜索
            HStack {
                TextField("搜索其它条目", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("搜索") { search() }
                    .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearching)
            }

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if hasSearched {
                if model.searchResults.isEmpty {
                    Text("没有找到相关条目，换个关键词试试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    List(model.searchResults) { subject in
                        Button {
                            model.bind(subject: subject, to: show)
                            dismiss()
                        } label: {
                            subjectRow(subject)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460, height: 520)
        .onAppear {
            // 打开即按番名自动匹配（与番库一致：只给候选，确认由用户点选）
            keyword = show.title
            Task { await model.loadBindCandidates(for: show) }
        }
    }

    /// 与 LibraryBindSheet.candidateRow 同样式：中文名 + 原名 + 相似度百分比 + 集数
    private func candidateRow(_ candidate: MatchCandidate) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.subject.displayName.isEmpty ? "未命名" : candidate.subject.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(candidate.subject.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(Int(candidate.score * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.orange)
            Text("共 \(candidate.subject.episodeCount ?? 0) 集")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func subjectRow(_ subject: Subject) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(subject.displayName.isEmpty ? "—" : subject.displayName)
                    .font(.body)
                Text(subject.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("共 \(subject.episodeCount ?? 0) 集")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func search() {
        hasSearched = true
        Task { await model.search(keyword: keyword) }
    }
}

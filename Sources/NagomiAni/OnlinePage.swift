import SwiftUI
import NagomiAniCore

/// 在线片源页（侧边栏「在线」）。
/// 排布与搜索页「过去一周」一致：按天分组 + 横向高清封面卡片，
/// 点击卡片进入番详情（覆盖层）查看分集/播放/缓存。
struct OnlinePage: View {
    @ObservedObject var model: OnlineStore
    /// 点击某一集时回调（由外层切换到播放器页并加载在线流）
    var onPlay: (OnlinePlayback) -> Void

    @State private var showSourceSheet = false
    @State private var searchKeyword = ""

    static let coverWidth: CGFloat = 112
    static let coverHeight: CGFloat = 152

    var body: some View {
        ZStack {
            // 目录常驻：进详情以覆盖层展示，返回时滚动位置保留
            directoryView
            if let show = model.selectedShow {
                OnlineShowDetailView(store: model, show: show, onPlay: onPlay)
                    .background(NagomiTheme.pageBackground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - 目录

    private var directoryView: some View {
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
    }

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
            .buttonStyle(NagomiSecondaryButtonStyle())
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
            .buttonStyle(NagomiSecondaryButtonStyle())
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
        if model.shows.isEmpty && model.onlineSearchResults == nil {
            emptyState
        } else if model.isCalendarMode, model.onlineSearchResults == nil {
            weekSectionsView
        } else if let results = model.onlineSearchResults {
            coverGrid(results)
        } else {
            coverGrid(model.shows)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.tv")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(NagomiTheme.accent)
                .frame(width: 92, height: 92)
                .background(NagomiTheme.accentSoft, in: Circle())
            Text(model.isLoadingShows
                 ? "正在加载片源…"
                 : "没有加载到任何内容\n可在「添加片源」里检查资源站或稍后重试")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 放送日历分组（与搜索页「过去一周」同构）

    private var weekSectionsView: some View {
        ScrollView {
            // VStack 非懒加载：嵌套横向滚动时避免懒容器测量出错导致某些天不渲染
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.weeklySections) { section in
                    daySection(section)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func daySection(_ section: OnlineStore.WeeklyShowSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.caption.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        section.title == "今天" ? NagomiTheme.accent.opacity(0.2) : Color.gray.opacity(0.12),
                        in: Capsule()
                    )
                    .foregroundStyle(section.title == "今天" ? NagomiTheme.accent : Color.primary)
                Text(section.dateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(section.shows.count) 部")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(section.shows) { show in
                        coverCard(show)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 6)
    }

    /// 封面卡片（高清图作为按钮）：点击进入番详情
    private func coverCard(_ show: OnlineShow) -> some View {
        Button {
            model.open(show)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                coverImage(show)
                    .frame(width: Self.coverWidth, height: Self.coverHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if let newCount = model.newEpisodeCount(for: show) {
                            NagomiBadge(text: "新集 \(newCount)", foreground: .white,
                                        background: NagomiTheme.accent)
                                .padding(4)
                        }
                    }

                Text(show.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: Self.coverWidth, alignment: .leading)

                NagomiBadge(
                    text: model.binding(for: show.seriesKey) != nil ? "已关联" : "未关联",
                    foreground: model.binding(for: show.seriesKey) != nil ? .green : .secondary,
                    background: model.binding(for: show.seriesKey) != nil
                        ? Color.green.opacity(0.15) : Color.gray.opacity(0.15)
                )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 高清封面：聚合条目带 Bangumi 封面 / 站点条目带图床封面 / 占位芯片
    @ViewBuilder
    private func coverImage(_ show: OnlineShow) -> some View {
        if let url = show.coverURL.flatMap(SearchPage.imageURL) {
            CoverImageView(url: url, cornerRadius: 0)
        } else {
            Image(systemName: "play.tv")
                .font(.system(size: 28))
                .foregroundStyle(NagomiTheme.accent)
                .frame(width: Self.coverWidth, height: Self.coverHeight)
                .background(NagomiTheme.accentSoft)
        }
    }

    /// 竖向封面网格（站点回退目录 / 搜索结果）
    private func coverGrid(_ shows: [OnlineShow]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.coverWidth), spacing: 12)], spacing: 14) {
                ForEach(shows) { show in
                    coverCard(show)
                }
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - 详情（覆盖层）

    /// 番详情：大封面 + 信息 + 分集列表（点封面卡片进入）
    struct OnlineShowDetailView: View {
        @ObservedObject var store: OnlineStore
        let show: OnlineShow
        var onPlay: (OnlinePlayback) -> Void

        @State private var preparingEpisodeID: String?
        @State private var isRefreshing = false

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        store.back()
                    } label: {
                        Label("返回在线", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Text(show.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerSection
                        Divider()
                        episodesSection
                    }
                    .padding(20)
                }
            }
            .task {
                await store.ensureEpisodes(for: show)
                await store.refreshEpisodes(for: show) // 打开详情 = 检查更新（拉取式）
                store.markEpisodesSeen(show)
                await store.refreshWatched(for: show)
            }
        }

        private var headerSection: some View {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let url = show.coverURL.flatMap(SearchPage.imageURL) {
                        CoverImageView(url: url, cornerRadius: 0)
                    } else {
                        Image(systemName: "play.tv")
                            .font(.system(size: 32))
                            .foregroundStyle(NagomiTheme.accent)
                            .frame(width: 132, height: 176)
                            .background(NagomiTheme.accentSoft)
                    }
                }
                .frame(width: 132, height: 176)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Text(show.title)
                        .font(.title3.bold())
                    if let subtitle = show.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if store.binding(for: show.seriesKey) != nil {
                            NagomiBadge(text: "已关联", foreground: .green, background: Color.green.opacity(0.15))
                        } else {
                            NagomiBadge(text: "未关联", foreground: .secondary, background: Color.gray.opacity(0.15))
                        }
                        if let newCount = store.newEpisodeCount(for: show) {
                            NagomiBadge(text: "新集 \(newCount)", foreground: .orange, background: Color.orange.opacity(0.15))
                        }
                    }
                    HStack(spacing: 8) {
                        Button {
                            store.bindTarget = show
                        } label: {
                            Label(store.binding(for: show.seriesKey) != nil ? "更换关联" : "关联 Bangumi",
                                  systemImage: "link")
                        }
                        .buttonStyle(NagomiSecondaryButtonStyle())

                        Button {
                            if store.isInLibrary(show) {
                                store.removeFromLibrary(show)
                            } else {
                                store.addToLibrary(show)
                            }
                        } label: {
                            Label(store.isInLibrary(show) ? "移出番库" : "加入番库",
                                  systemImage: store.isInLibrary(show) ? "bookmark.fill" : "bookmark")
                        }
                        .buttonStyle(NagomiSecondaryButtonStyle())
                    }
                    Text("已关联的番播完会自动同步「看过」到 Bangumi")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }

        private var episodesSection: some View {
            let eps = store.episodes[show.id] ?? []
            return VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("分集")
                        .font(.headline)
                    Text("\(eps.count) 集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task {
                            isRefreshing = true
                            await store.refreshEpisodes(for: show)
                            store.markEpisodesSeen(show)
                            await store.refreshWatched(for: show)
                            isRefreshing = false
                        }
                    } label: {
                        Label("检查更新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .disabled(isRefreshing)
                }
                if eps.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("加载分集…")
                        Spacer()
                    }
                    .padding(.vertical, 20)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(eps) { episode in
                            episodeRow(episode)
                        }
                    }
                }
            }
        }

        private func episodeRow(_ episode: OnlineEpisode) -> some View {
            Button {
                play(episode)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .foregroundStyle(NagomiTheme.accent)
                    Text(episode.title ?? "第 \(episode.number) 集")
                        .font(.callout)
                        .lineLimit(1)
                    if store.isWatched(episode) {
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
                    OnlineCacheControl(store: store, show: show, episode: episode)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .nagomiHoverHighlight(in: RoundedRectangle(cornerRadius: 6))
        }

        private func play(_ episode: OnlineEpisode) {
            guard preparingEpisodeID == nil else { return } // 上一次取流还没完成，忽略连点
            preparingEpisodeID = episode.id
            Task {
                defer { preparingEpisodeID = nil }
                do {
                    let target = try await store.preparePlayback(show: show, episode: episode)
                    onPlay(target)
                } catch {
                    store.statusMessage = "播放失败：\(error.localizedDescription)"
                }
            }
        }
    }

} 

/// 分集行尾部的缓存控制（详情页用）：未缓存=下载、下载中=进度条+字节数+取消、已缓存=徽章+大小+删除
struct OnlineCacheControl: View {
    @ObservedObject var store: OnlineStore
    let show: OnlineShow
    let episode: OnlineEpisode

    var body: some View {
        switch store.cacheState(for: episode) {
        case .notCached:
            Button {
                store.startCache(show: show, episode: episode)
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(NagomiIconButtonStyle())
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
                store.cancelCache(for: episode)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(NagomiIconButtonStyle(size: 22))
            .help("取消缓存")
        case .cached:
            VStack(alignment: .trailing, spacing: 1) {
                Text("已缓存")
                    .font(.caption2)
                    .foregroundStyle(.green)
                if let size = store.cacheSize(for: episode) {
                    Text(OnlineStore.formattedBytes(size))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                store.removeCache(for: episode)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(NagomiIconButtonStyle(size: 22))
            .help("删除本地缓存")
        }
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
                    .buttonStyle(NagomiPrimaryButtonStyle())
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
                        NagomiBadge(text: "内置", foreground: NagomiTheme.accent, background: NagomiTheme.accentSoft)
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
                                .buttonStyle(NagomiIconButtonStyle())
                                .help("移除该站点")
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Spacer()

            Text("说明：内置源为公开采集接口的苹果CMS 资源站；也可粘贴其它站点首页地址自动拼接接口路径 /api.php/provide/vod/。内容均来自互联网公开接口，请遵守站点条款与当地法规。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(NagomiSecondaryButtonStyle())
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
                    .buttonStyle(NagomiPrimaryButtonStyle())
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
        .background(NagomiTheme.accentSoft.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
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

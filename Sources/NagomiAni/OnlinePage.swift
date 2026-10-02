import SwiftUI
import NagomiAniCore

/// 「在线」侧边栏模块已并入搜索页详情的「在线观看」区（2026-09-29 用户决策，
/// 减少一个模块）；本文件保留跨页面共用的组件：
/// 在线缓存控件（番库云端行也在用）/ 添加片源 / 在线绑定 / 我的缓存 四个视图。

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
                RinglessTextField(text: $urlText,
                                  placeholder: "https://example.com（站点地址或 API 地址）",
                                  onSubmit: { add() })
                    .nagomiFieldChrome()
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
            HStack(spacing: 8) {
                Text("为「\(show.title)」关联 Bangumi 条目")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(NagomiIconButtonStyle(size: 22))
                .help("关闭（不关联）")
            }

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
                RinglessTextField(text: $keyword,
                                  placeholder: "搜索其它条目",
                                  onSubmit: { search() })
                    .nagomiFieldChrome()
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

/// 「我的缓存」面板：已缓存按番分组展示 + 正在缓存的队列（进度/取消）
struct OnlineCacheSheet: View {
    @ObservedObject var model: OnlineStore
    var onPlay: (OnlinePlayback) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 正在下载的队列（按 key 排序保持稳定）
    private var inProgress: [(key: String, show: OnlineShow, episode: OnlineEpisode, progress: StreamCache.Progress)] {
        model.cacheProgress.keys.sorted().compactMap { key in
            guard let info = model.episodeInfo(forResumeKey: key),
                  let progress = model.cacheProgress[key] else { return nil }
            return (key, info.show, info.episode, progress)
        }
    }

    /// 失败的缓存任务（key 排序稳定）
    private var failedItems: [OnlineStore.FailedCacheItem] {
        model.failedCaches.values
            .sorted { $0.id < $1.id }
    }

    /// 已完成缓存按番分组（番名排序，组内按集号）
    private var groups: [(show: OnlineShow, items: [CachedEpisodeItem], totalSize: Int64)] {
        Dictionary(grouping: model.cachedItems, by: \.show.id)
            .values
            .map { items in
                let show = items[0].show
                return (show,
                        items.sorted { $0.episode.number < $1.episode.number },
                        items.reduce(Int64(0)) { $0 + $1.sizeBytes })
            }
            .sorted { $0.show.title < $1.show.title }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的缓存")
                    .font(.headline)
                Text("\(model.cachedItems.count) 集 · \(OnlineStore.formattedBytes(model.cacheTotalBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清除全部", role: .destructive) {
                    model.clearAllCache()
                }
                .controlSize(.small)
                .disabled(model.cachedItems.isEmpty && model.cacheProgress.isEmpty && failedItems.isEmpty)
                Button("完成") { dismiss() }
                    .buttonStyle(NagomiSecondaryButtonStyle())
            }

            if model.cachedItems.isEmpty && inProgress.isEmpty && failedItems.isEmpty {
                Text("暂无缓存。在番详情里点分集行的下载按钮即可缓存到本地。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // ---- 失败的缓存（可重试/移除）----
                        if !failedItems.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("缓存失败 \(failedItems.count)", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.orange)
                                ForEach(failedItems) { failed in
                                    HStack(spacing: 10) {
                                        Image(systemName: "exclamationmark.circle")
                                            .foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(failed.show.title)
                                                .font(.callout)
                                                .lineLimit(1)
                                            Text("第 \(failed.episode.number) 集 — \(failed.message)")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                        Button("重试") {
                                            model.retryCache(for: failed.episode)
                                        }
                                        .buttonStyle(NagomiSecondaryButtonStyle())
                                        Button {
                                            model.dismissCacheFailure(for: failed.episode)
                                        } label: {
                                            Image(systemName: "xmark")
                                        }
                                        .buttonStyle(NagomiIconButtonStyle(size: 22))
                                        .help("移除失败记录")
                                    }
                                    .padding(8)
                                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        // ---- 正在缓存的队列 ----
                        if !inProgress.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("正在缓存 \(inProgress.count)", systemImage: "arrow.down.circle")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(NagomiTheme.accent)
                                ForEach(inProgress, id: \.key) { item in
                                    progressRow(item)
                                }
                            }
                        }
                        // ---- 已缓存（按番分组）----
                        if !groups.isEmpty {
                            Label("已缓存", systemImage: "checkmark.seal")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            ForEach(groups, id: \.show.id) { group in
                                groupSection(group)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 500)
    }

    // MARK: - 下载队列行

    private func progressRow(_ item: (key: String, show: OnlineShow, episode: OnlineEpisode, progress: StreamCache.Progress)) -> some View {
        HStack(spacing: 10) {
            Group {
                if let url = item.show.coverURL.flatMap(SearchPage.imageURL) {
                    CoverImageView(url: url, cornerRadius: 3)
                } else {
                    Image(systemName: "play.tv")
                        .font(.system(size: 12))
                        .foregroundStyle(NagomiTheme.accent)
                        .frame(width: 36, height: 48)
                        .background(NagomiTheme.accentSoft)
                }
            }
            .frame(width: 36, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.show.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text("第 \(item.episode.number) 集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(OnlineStore.progressBytesLabel(item.progress))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let fraction = item.progress.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Spacer()
            Button {
                model.cancelCache(for: item.episode)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(NagomiIconButtonStyle(size: 24))
            .help("取消缓存")
        }
        .padding(8)
        .background(NagomiTheme.accentSoft.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 已缓存分组

    private func groupSection(_ group: (show: OnlineShow, items: [CachedEpisodeItem], totalSize: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Group {
                    if let url = group.show.coverURL.flatMap(SearchPage.imageURL) {
                        CoverImageView(url: url, cornerRadius: 3)
                    } else {
                        Image(systemName: "play.tv")
                            .font(.system(size: 12))
                            .foregroundStyle(NagomiTheme.accent)
                            .frame(width: 36, height: 48)
                            .background(NagomiTheme.accentSoft)
                    }
                }
                .frame(width: 36, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 3))

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.show.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text("\(group.items.count) 集 · \(OnlineStore.formattedBytes(group.totalSize))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    group.items.forEach { model.removeCache(for: $0.episode) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(NagomiIconButtonStyle(size: 24))
                .help("删除该剧目的全部缓存")
            }

            ForEach(group.items) { item in
                HStack(spacing: 8) {
                    Text("第 \(item.episode.number) 集")
                        .font(.callout)
                        .padding(.leading, 44)
                    if model.isWatched(item.episode) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Text(OnlineStore.formattedBytes(item.sizeBytes))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            do {
                                let target = try await model.preparePlayback(show: group.show, episode: item.episode)
                                dismiss()
                                onPlay(target)
                            } catch {
                                model.statusMessage = "播放失败：\(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(NagomiTheme.accent)
                    .help("播放（本地副本）")

                    Button {
                        model.removeCache(for: item.episode)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(NagomiIconButtonStyle(size: 22))
                    .help("删除此缓存")
                }
                .padding(.vertical, 3)
            }
        }
        .padding(10)
        .background(NagomiTheme.accentSoft.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

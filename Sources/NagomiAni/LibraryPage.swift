import SwiftUI
import NagomiAniCore

/// 番库页（侧边栏第三页）
struct LibraryPage: View {
    @ObservedObject var model: LibraryViewModel
    /// 点击某一集时回调（由外层切换到播放器页并加载文件）
    var onPlay: (URL) -> Void
    @State private var hoveredFilePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if let message = model.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("番库")
        .sheet(
            isPresented: Binding(
                get: { model.bindTarget != nil },
                set: { if !$0 { model.bindTarget = nil } }
            )
        ) {
            LibraryBindSheet(model: model)
        }
        .alert(
            "移除番库条目",
            isPresented: Binding(
                get: { model.seriesToRemove != nil },
                set: { if !$0 { model.cancelRemoveSeries() } }
            ),
            presenting: model.seriesToRemove
        ) { series in
            Button("移除", role: .destructive) {
                model.confirmRemoveSeries()
            }
            Button("取消", role: .cancel) {
                model.cancelRemoveSeries()
            }
        } message: { series in
            Text("从番库移除「\((series.seriesKey as NSString).lastPathComponent)」吗？该目录下的文件索引会被删除（磁盘文件不受影响）。")
        }
    }

    // MARK: - 视图

    private var header: some View {
        HStack {
            Text("番库")
                .font(.title2)
            Spacer()
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.addFolders()
            } label: {
                Label("添加目录", systemImage: "folder.badge.plus")
            }
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.series.isEmpty {
            emptyState
        } else {
            seriesList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("导入动漫目录后，这里会按「番」聚合显示\n扫描完成后将自动匹配 Bangumi 条目并显示封面")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var seriesList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.series) { series in
                    seriesRow(series)
                }
            }
        }
    }

    private func seriesRow(_ series: Series) -> some View {
        let subject = model.cover(for: series)
        let title = subject?.nameCN ?? subject?.name ?? series.displayName

        return DisclosureGroup {
            if let episodes = model.episodes(for: series), !episodes.isEmpty {
                // 有 Bangumi 集数列表：按集数顺序排列，缺集显示"未找到"占位
                ForEach(episodeRows(episodes, files: series.files)) { row in
                    if row.files.isEmpty {
                        missingRow(row.episode)
                    } else {
                        ForEach(row.files) { file in
                            fileRow(file)
                        }
                    }
                }
                // 本地有、但 Bangumi 列表里没有对应集号的文件（如无集号文件）
                ForEach(series.files.filter { $0.episodeNumber == nil }) { file in
                    fileRow(file)
                }
            } else {
                ForEach(series.sortedFiles) { file in
                    fileRow(file)
                }
            }
        } label: {
            HStack(spacing: 10) {
                coverThumbnail(series, subject: subject)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        matchBadge(series.matchState)
                        // 已关联后不再提示建议数；只有未关联/待确认才显示
                        if series.matchState != .matched,
                           let cands = model.candidates[series.seriesKey], !cands.isEmpty {
                            Text("建议 \(cands.count)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text("\(series.files.count) 集")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                bindButton(for: series)
                // 单番重扫：只关注该番所在目录的新增/删除
                Button {
                    model.rescanFolder(of: series)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 17))
                .help("重新扫描该目录（检测新集 / 文件删除）")
                .disabled(model.isScanning)
                // 从番库移除该番
                Button {
                    model.requestRemoveSeries(series)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 17))
                .help("从番库移除")
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        // 懒加载该番的 Bangumi 集数列表（已缓存则立即返回）
        .onAppear {
            Task { await model.ensureEpisodes(for: series) }
        }
    }

    /// 一行展示数据：某个 Bangumi 集 + 匹配到的本地文件（可为空 = 缺失）
    private struct EpisodeRow: Identifiable {
        let id: Int
        let episode: Episode
        let files: [MediaFile]
    }

    /// 将 Bangumi 集数序列与本地文件按集号配对（按集号升序）
    private func episodeRows(_ episodes: [Episode], files: [MediaFile]) -> [EpisodeRow] {
        let byEp = Dictionary(grouping: files) { $0.episodeNumber }
        return episodes
            .sorted { ($0.sort ?? 0) < ($1.sort ?? 0) }
            .map { ep in
                let sort = Int((ep.sort ?? 0).rounded())
                return EpisodeRow(id: ep.id, episode: ep, files: byEp[sort] ?? [])
            }
    }

    /// 缺失集占位：虚线边框 + 问号图标 + "本地未找到"
    private func missingRow(_ ep: Episode) -> some View {
        let sort = Int((ep.sort ?? 0).rounded())
        let title = ep.nameCN ?? ep.name
        return HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("第 \(sort) 集")
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                HStack(spacing: 6) {
                    if let airdate = ep.airdate, !airdate.isEmpty {
                        Text(airdate)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("本地未找到")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.secondary.opacity(0.35))
        )
        .opacity(0.85)
        .padding(.leading, 12)
        .padding(.trailing, 4)
    }

    /// 单集条目：卡片式样式（播放图标 + 文件名 + 集数徽章/大小 + hover 高亮）
    private func fileRow(_ file: MediaFile) -> some View {
        Button {
            onPlay(URL(fileURLWithPath: file.path))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if let ep = file.episodeNumber {
                            Text("第 \(ep) 集")
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1.5)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        if let size = file.fileSize {
                            Text(Self.formatFileSize(size))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                hoveredFilePath == file.path ? Color.gray.opacity(0.16) : Color.gray.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredFilePath = file.path
            } else if hoveredFilePath == file.path {
                hoveredFilePath = nil
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
    }

    @ViewBuilder
    private func coverThumbnail(_ series: Series, subject: Subject?) -> some View {
        if let urlString = subject?.images?.common, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                placeholderCover
            }
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.18))
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func matchBadge(_ state: MatchState) -> some View {
        switch state {
        case .matched:
            Label("已关联", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .pending:
            Label("待确认", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .unmatched:
            Label("未关联", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bindButton(for series: Series) -> some View {
        Button {
            model.bindTarget = series.seriesKey
        } label: {
            if series.matchState == .matched {
                Label("更换", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("关联", systemImage: "link")
            }
        }
        .controlSize(.regular)
        .help(series.matchState == .matched ? "重新关联到其它 Bangumi 条目" : "查看自动匹配结果并确认，或手动搜索")
    }
}

/// 关联弹窗：先展示自动匹配结果供确认，也可手动搜索其它条目
struct LibraryBindSheet: View {
    @ObservedObject var model: LibraryViewModel
    @State private var keyword = ""
    @State private var hasSearched = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("为「\(model.seriesName(for: model.bindTarget))」关联 Bangumi 条目")
                .font(.headline)
                .lineLimit(1)

            // 自动匹配结果
            if model.isLoadingCandidates {
                ProgressView("正在自动匹配…")
                    .padding(.vertical, 16)
            } else if !model.bindCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自动匹配结果（点选确认）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.bindCandidates) { candidate in
                                Button {
                                    model.bind(subject: candidate.subject)
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
                            model.bind(subject: subject)
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
        .frame(width: 460, height: 500)
    }

    private func candidateRow(_ candidate: MatchCandidate) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.subject.nameCN ?? candidate.subject.name ?? "未命名")
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
            Text("共 \(candidate.subject.totalEpisodes ?? 0) 集")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func subjectRow(_ subject: Subject) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(subject.nameCN ?? "—")
                    .font(.body)
                Text(subject.name ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("共 \(subject.totalEpisodes ?? 0) 集")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func search() {
        hasSearched = true
        Task { await model.searchForBinding(keyword: keyword) }
    }
}

// MARK: - 工具

private extension LibraryPage {
    static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

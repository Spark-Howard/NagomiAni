import SwiftUI
import NagomiAniCore

/// 番库页（侧边栏第三页）
struct LibraryPage: View {
    @ObservedObject var model: LibraryViewModel
    /// 点击某一集时回调（由外层切换到播放器页并加载文件）
    var onPlay: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            foldersBar
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
            "移除目录",
            isPresented: Binding(
                get: { model.folderToRemove != nil },
                set: { if !$0 { model.cancelRemoveFolder() } }
            ),
            presenting: model.folderToRemove
        ) { folder in
            Button("移除", role: .destructive) {
                model.confirmRemoveFolder()
            }
            Button("取消", role: .cancel) {
                model.cancelRemoveFolder()
            }
        } message: { folder in
            Text("确定从番库移除目录「\((folder as NSString).lastPathComponent)」吗？其中的系列、关联与单集列表都会被删除。")
        }
    }

    // MARK: - 视图

    private var header: some View {
        HStack {
            Text("番库")
                .font(.title2)
            Spacer()
            if model.isScanning || model.isMatching {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.rescan()
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.isMatching)
            Button {
                model.addFolders()
            } label: {
                Label("添加目录", systemImage: "folder.badge.plus")
            }
            .controlSize(.large)
        }
    }

    private var foldersBar: some View {
        HStack(spacing: 8) {
            ForEach(model.folders, id: \.self) { folder in
                HStack(spacing: 4) {
                    Text((folder as NSString).lastPathComponent)
                        .font(.caption)
                    Button {
                        model.requestRemoveFolder(folder)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("移除目录：\(folder)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.12), in: Capsule())
            }
            if model.folders.isEmpty {
                Text("还没有目录，点「添加目录」导入你的动漫文件夹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
            ForEach(series.sortedFiles) { file in
                Button {
                    onPlay(URL(fileURLWithPath: file.path))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.circle")
                            .foregroundStyle(.secondary)
                        Text(file.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let ep = file.episodeNumber {
                            Text("第 \(ep) 集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 20)
                }
                .buttonStyle(.plain)
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
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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
        .controlSize(.small)
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

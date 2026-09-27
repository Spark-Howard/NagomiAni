import SwiftUI
import NagomiAniCore

/// 在线片源页（侧边栏「在线」）
struct OnlinePage: View {
    @ObservedObject var model: OnlineStore
    /// 点击某一集时回调（由外层切换到播放器页并加载在线流）
    var onPlay: (OnlinePlayback) -> Void

    @State private var expandedShows: Set<String> = []
    @State private var preparingEpisodeID: String?

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
        .navigationTitle("在线")
        .task { await model.loadShowsIfNeeded() }
    }

    // MARK: - 视图

    private var header: some View {
        HStack {
            Text("在线")
                .font(.title2)
            Spacer()
            if model.isPreparing || model.isLoadingShows {
                ProgressView()
                    .controlSize(.small)
            }
        }
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
            Text(model.isLoadingShows ? "正在加载片源…" : "暂无在线片源\n接入站点后会在这里显示剧集")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.shows) { show in
                    showRow(show)
                }
            }
        }
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
                Image(systemName: "play.tv")
                    .font(.system(size: 20))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 60)
                    .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = show.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        // 行出现即加载集列表（幂等）
        .task(id: show.id) { await model.ensureEpisodes(for: show) }
    }

    private func episodeRow(show: OnlineShow, episode: OnlineEpisode) -> some View {
        Button {
            play(show: show, episode: episode)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.circle")
                    .foregroundStyle(.tint)
                Text(episode.title ?? "第 \(episode.number) 集")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                if preparingEpisodeID == episode.id {
                    ProgressView().controlSize(.mini)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 54)
        .padding(.vertical, 4)
        .disabled(model.isPreparing)
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
                } else {
                    expandedShows.remove(show.id)
                }
            }
        )
    }
}

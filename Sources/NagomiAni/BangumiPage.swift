import SwiftUI
import NagomiAniCore

/// Bangumi 收藏页（侧边栏第二页）
///
/// 点击任意收藏条目（在看/想看/看过/搁置/抛弃）→ 跳转该番剧详情页；
/// 详情页点「返回」→ 回到刚才的 Bangumi 收藏列表。
/// 详情使用独立的 SearchViewModel（不干扰搜索页自身的选中状态）。
///
/// 登录统一在「聊天」页的常驻网页里完成（点击「去聊天页登录」→ 切到聊天 →
/// 右侧网页登录并点「授权」→ 自动回到本页并同步收藏），本页不再弹独立授权窗。
struct BangumiPage: View {
    @ObservedObject var model: AccountViewModel
    /// 统一登录入口（由 ContentView 提供：切到聊天页驱动登录，完成后自动回到本页）
    let onStartLogin: () -> Void
    /// 本模块详情页专用模型（隔离于搜索页的选中/详情状态）
    @StateObject private var detail = SearchViewModel()

    var body: some View {
        Group {
            if let subject = detail.selected {
                SubjectDetailView(model: detail, subject: subject, backLabel: "返回")
            } else {
                accountContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Bangumi")
        .onAppear {
            // 详情里显示收藏状态徽章：登录状态下同步一次我的收藏
            Task { await detail.refreshCollections() }
        }
    }

    // MARK: - 登录面板（App 内嵌授权，与“聊天”共享网页 Cookie）

    // MARK: - 收藏列表

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isLoggedIn {
                userHeader
                typePicker
                collectionsList
            } else {
                loginForm
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
    }

    // MARK: - 未登录

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登录 Bangumi 后即可同步收藏")
                .font(.title3)

            Text("登录已统一到「聊天」页的 Bangumi 网页里：点下方按钮会切到聊天页，在右侧网页登录你的账号并点一次「授权」；完成后会自动回到这里并同步收藏，聊天网页也无需再单独登录。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                onStartLogin()
            } label: {
                Text("去「聊天」页登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isLoading)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    // MARK: - 已登录

    private var userHeader: some View {
        HStack(spacing: 12) {
            if let avatarURL = model.user?.avatar?.large,
               let url = URL(string: avatarURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 48))
            }

            VStack(alignment: .leading) {
                Text(model.user?.nickname ?? "Unknown")
                    .font(.title3)
                Text("@\(model.user?.username ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("退出登录") {
                model.logout()
            }
        }
    }

    private var typePicker: some View {
        Picker("收藏类型", selection: $model.collectionType) {
            ForEach(SubjectCollectionType.allCases.filter { $0 != .unknown }, id: \.self) { type in
                Text(type.displayName)
                    .tag(type)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var collectionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.collectionType.displayName)
                    .font(.subheadline)

                // 缓存时间：让"秒开的是缓存、后台正在核对"这件事对用户可见
                if let updated = model.lastUpdated {
                    Text("更新于 \(Self.timeFormatter.string(from: updated))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // 后台静默刷新：细进度条，不遮挡已有列表
                if model.isRefreshingInBackground {
                    ProgressView()
                        .controlSize(.mini)
                        .help("正在核对最新收藏…")
                }
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await model.refreshCollections() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading || model.isRefreshingInBackground)
                .help("重新拉取当前收藏（跳过缓存）")
            }

            if model.collections.isEmpty {
                Text(model.isLoading ? "加载中…" : "暂无收藏条目")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.collections) { collection in
                            collectionRow(collection)
                        }
                    }
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 进度文案：进度 x/N 集。
    ///
    /// 总集数用 `episodeCount`（`total_episodes` 缺失时回退 `eps`）——收藏列表
    /// 接口不返回 `total_episodes`，直接读它会永远显示 0 集。
    /// 总集数确实未知（如未播完的新番）时显示"进度 x 集"，不显示误导性的 /0。
    private static func progressText(for collection: UserSubjectCollection) -> String {
        let watched = collection.epStatus ?? 0
        guard let total = collection.subject?.episodeCount, total > 0 else {
            return "进度 \(watched) 集"
        }
        return "进度 \(watched)/\(total) 集"
    }

    /// 点击整行 → 打开该条目详情页（返回后仍停留在此 Bangumi 页面）
    private func collectionRow(_ collection: UserSubjectCollection) -> some View {
        Button {
            if let subject = collection.subject {
                detail.open(subject: subject)
            } else {
                // 详情数据不足的兜底：以 id 打开，标题等加载后补全
                let stub = Subject(
                    id: collection.subjectID,
                    type: .anime,
                    name: nil,
                    nameCN: nil,
                    summary: nil,
                    airDate: nil,
                    eps: nil,
                    totalEpisodes: collection.subject?.episodeCount,
                    images: collection.subject?.images,
                    rating: nil
                )
                detail.open(subject: stub)
            }
        } label: {
            HStack(spacing: 10) {
                // 用带缓存的 CoverImageView，而不是无缓存的 AsyncImage ——
                // 切换模块会重建整页，AsyncImage 每次都会重下所有封面（表现为一直灰）
                CoverImageView(
                    url: SearchPage.imageURL(collection.subject?.images?.common),
                    cornerRadius: 4
                )
                .frame(width: 36, height: 48)

                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.subject?.displayName.isEmpty == false ? collection.subject!.displayName : "未知条目")
                        .lineLimit(1)
                    Text(Self.progressText(for: collection))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .nagomiCard(cornerRadius: 8)
.nagomiHoverHighlight(in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension SubjectCollectionType {
    var displayName: String {
        switch self {
        case .wish: return "想看"
        case .collected: return "看过"
        case .doing: return "在看"
        case .onHold: return "搁置"
        case .dropped: return "抛弃"
        case .unknown: return "其他"
        }
    }
}

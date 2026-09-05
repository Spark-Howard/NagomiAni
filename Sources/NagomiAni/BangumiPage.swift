import SwiftUI
import NagomiAniCore

/// Bangumi 收藏页（侧边栏第二页）
///
/// 点击任意收藏条目（在看/想看/看过/搁置/抛弃）→ 跳转该番剧详情页；
/// 详情页点「返回」→ 回到刚才的 Bangumi 收藏列表。
/// 详情使用独立的 SearchViewModel（不干扰搜索页自身的选中状态）。
struct BangumiPage: View {
    @ObservedObject var model: AccountViewModel
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

            Text("点击登录后会在浏览器打开 Bangumi 授权页，用你的 Bangumi 账号登录并点击「授权」即可。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.isLoading {
                HStack(spacing: 12) {
                    Button {
                        model.cancelLogin()
                    } label: {
                        Label("取消登录", systemImage: "xmark.circle")
                    }
                    .controlSize(.large)
                    Text("若浏览器授权页已关闭，点「取消登录」返回")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await model.login() }
                } label: {
                    Text("登录 Bangumi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
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
            HStack {
                Text(model.collectionType.displayName)
                    .font(.subheadline)
                Spacer()
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.collections.isEmpty {
                Text("暂无收藏条目")
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
                    totalEpisodes: collection.subject?.totalEpisodes,
                    images: collection.subject?.images,
                    rating: nil
                )
                detail.open(subject: stub)
            }
        } label: {
            HStack(spacing: 10) {
                if let imageURL = collection.subject?.images?.common,
                   let url = URL(string: imageURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2))
                    }
                    .frame(width: 36, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 36, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.subject?.nameCN ?? collection.subject?.name ?? "未知条目")
                        .lineLimit(1)
                    Text("进度 \(collection.epStatus ?? 0)/\(collection.subject?.totalEpisodes ?? 0) 集")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

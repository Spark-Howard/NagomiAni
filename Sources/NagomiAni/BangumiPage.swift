import SwiftUI
import NagomiAniCore

/// Bangumi 收藏页（侧边栏第二页）
struct BangumiPage: View {
    @ObservedObject var model: AccountViewModel

    var body: some View {
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
        .navigationTitle("Bangumi")
    }

    // MARK: - 未登录

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登录 Bangumi 后即可同步收藏")
                .font(.title3)

            Text("还没有开发者应用？在 bgm.tv/dev/app 注册，回调地址填 http://127.0.0.1:8123/callback")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("App ID (client_id)", text: $model.clientID)
                .textFieldStyle(.roundedBorder)

            SecureField("App Secret (client_secret)", text: $model.clientSecret)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await model.login() }
            } label: {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("登录 Bangumi")
                }
            }
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

    private func collectionRow(_ collection: UserSubjectCollection) -> some View {
        HStack(spacing: 10) {
            if let imageURL = collection.subject?.images?.common,
               let url = URL(string: imageURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
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
        }
        .padding(8)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

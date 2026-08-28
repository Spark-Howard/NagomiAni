import SwiftUI
import NagomiAniCore

/// Bangumi 账号与收藏界面
struct AccountView: View {
    @ObservedObject var model: AccountViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Bangumi 同步")
                    .font(.headline)
                Spacer()
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if model.isLoggedIn {
                userSection
                collectionsSection
            } else {
                loginSection
            }

            if let message = model.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 560)
    }

    // MARK: - 未登录

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("还没有 Bangumi 开发者应用？")
                .font(.subheadline)
            Text("1. 打开 bgm.tv/dev/app 注册应用\n2. 回调地址填写 http://127.0.0.1:8123/callback\n3. 把 App ID / App Secret 填到下面")
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
    }

    // MARK: - 已登录

    private var userSection: some View {
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

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("在看（动画）")
                .font(.subheadline)

            if model.collections.isEmpty {
                Text("暂无在看条目")
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

            if model.busySubjectID == collection.subjectID {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("标记下一集") {
                    Task { await model.markNextWatched(collection) }
                }
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

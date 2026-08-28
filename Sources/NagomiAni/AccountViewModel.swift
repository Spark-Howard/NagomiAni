import Foundation
import NagomiAniCore

/// Bangumi 账号与收藏的 UI 状态模型
@MainActor
final class AccountViewModel: ObservableObject {
    @Published var isLoggedIn = false
    @Published var user: BangumiUser?
    @Published var collections: [UserSubjectCollection] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var clientID: String
    @Published var clientSecret: String
    /// 正在标记"看过"的条目 ID
    @Published var busySubjectID: Int?

    private let defaults = UserDefaults.standard
    private let client = BangumiClient()
    private var auth: BangumiAuth?
    private var sync: HistorySyncService?

    init() {
        clientID = defaults.string(forKey: "bangumi.clientID") ?? ""
        clientSecret = defaults.string(forKey: "bangumi.clientSecret") ?? ""
        setupAuth()
        if auth?.isLoggedIn == true {
            Task { await refresh() }
        }
    }

    // MARK: - 动作

    func login() async {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty,
              !clientSecret.isEmpty else {
            errorMessage = "请先填写 App ID 和 App Secret（在 bgm.tv/dev/app 注册应用获取）"
            return
        }
        defaults.set(clientID, forKey: "bangumi.clientID")
        defaults.set(clientSecret, forKey: "bangumi.clientSecret")
        setupAuth()

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let auth else { return }
            try await auth.login()
            client.accessToken = auth.accessToken
            await refresh()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func logout() {
        auth?.logout()
        client.accessToken = nil
        user = nil
        collections = []
        isLoggedIn = false
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let auth else { return }
            try await auth.refreshIfNeeded()
            client.accessToken = auth.accessToken

            let me = try await client.currentUser()
            user = me

            // 拉取动画"在看"收藏
            let page = try await client.collections(username: me.username, type: .doing, limit: 100)
            collections = page.data
            isLoggedIn = true
        } catch {
            if case BangumiError.unauthorized = error {
                auth?.logout()
                client.accessToken = nil
                isLoggedIn = false
                user = nil
                collections = []
            }
            errorMessage = Self.describe(error)
        }
    }

    /// 把某条目的"下一集"标记为看过（M2 手动同步演示）
    func markNextWatched(_ collection: UserSubjectCollection) async {
        let subjectID = collection.subjectID
        busySubjectID = subjectID
        defer { busySubjectID = nil }

        do {
            let eps = try await client.episodes(subjectID: subjectID, type: 0, limit: 200)
            let currentProgress = collection.epStatus ?? 0
            let next = eps.data
                .filter { ($0.sort ?? 0) > Double(currentProgress) }
                .sorted { ($0.sort ?? 0) < ($1.sort ?? 0) }
                .first

            guard let target = next else {
                errorMessage = "没有更多本篇可标记"
                return
            }

            try await sync?.markWatched(subjectID: subjectID, episodeIDs: [target.id])
            await refresh()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - 私有

    private func setupAuth() {
        let config = BangumiAppConfig(clientID: clientID, clientSecret: clientSecret)
        let newAuth = BangumiAuth(config: config)
        auth = newAuth
        client.accessToken = newAuth.accessToken
        sync = HistorySyncService(client: client)
        isLoggedIn = newAuth.isLoggedIn
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

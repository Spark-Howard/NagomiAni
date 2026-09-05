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
    /// 正在同步的条目 ID（预留）
    @Published var collectionType: SubjectCollectionType = .doing {
        didSet {
            guard oldValue != collectionType, isLoggedIn else { return }
            Task { await loadCollections() }
        }
    }

    private let client = BangumiClient()
    private var auth: BangumiAuth?
    private var sync: HistorySyncService?

    init() {
        setupAuth()
        if auth?.isLoggedIn == true {
            Task { await refresh() }
        }
    }

    // MARK: - 动作

    func login() async {
        // 凭证已内置在应用里（BangumiCredentials）——开发者注册一次、所有用户共用，
        // 用户只需在浏览器里用自己的账号授权，无需填写 App ID/Secret
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

    /// 用户在浏览器授权页放弃/关页后点「取消登录」：让等待中的登录流程立刻返回
    func cancelLogin() {
        auth?.cancelLogin()
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
            isLoggedIn = true
            await loadCollections()
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

    /// 拉取当前收藏类型的列表
    func loadCollections() async {
        guard let user else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await client.collections(username: user.username, type: collectionType, limit: 100)
            // 收藏列表接口不含条目详情，逐条补全（节流 + 最多 30 条）
            collections = await fillMissingSubjects(page.data)
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    // MARK: - 私有

    /// 收藏列表接口不含 subject 详情，逐条补全名称/图片（最多 30 条，间隔 0.3s 节流）
    private func fillMissingSubjects(_ collections: [UserSubjectCollection]) async -> [UserSubjectCollection] {
        var result: [UserSubjectCollection] = []
        for (index, collection) in collections.enumerated() {
            if index >= 30 || collection.subject != nil {
                result.append(collection)
                continue
            }
            do {
                let subject = try await client.subject(id: collection.subjectID)
                result.append(UserSubjectCollection(collection: collection, subject: subject))
            } catch {
                result.append(collection)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return result
    }

    private func setupAuth() {
        let newAuth = BangumiAuth(config: BangumiCredentials.config)
        auth = newAuth
        client.accessToken = newAuth.accessToken
        sync = HistorySyncService(client: client)
        isLoggedIn = newAuth.isLoggedIn
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

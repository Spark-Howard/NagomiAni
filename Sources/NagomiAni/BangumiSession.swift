import Foundation
import NagomiAniCore

/// 共享的 Bangumi 客户端工厂（从 UserDefaults + Keychain 重建会话）
enum BangumiSession {

    /// 创建已登录的 API 客户端；未配置/未登录返回 nil
    static func makeClient() async -> BangumiClient? {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: "bangumi.clientID") ?? ""
        let secret = defaults.string(forKey: "bangumi.clientSecret") ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }

        let auth = BangumiAuth(config: BangumiAppConfig(clientID: id, clientSecret: secret))
        guard auth.isLoggedIn else { return nil }
        try? await auth.refreshIfNeeded()

        let client = BangumiClient()
        client.accessToken = auth.accessToken
        return client
    }
}

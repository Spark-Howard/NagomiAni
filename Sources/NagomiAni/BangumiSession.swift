import Foundation
import NagomiAniCore

/// NagomiAni 在 bgm.tv/dev/app 注册的开发者应用凭证
/// （回调地址见 BangumiAppConfig 默认值：http://127.0.0.1:8123/callback）。
///
/// 说明：桌面/移动端 OAuth2 的 client_secret 打包进二进制后无法真正保密，
/// 它在这里的作用是"标识 NagomiAni 这个应用"，而不是用户的密码。
/// 终端用户登录时用自己的 Bangumi 账号在浏览器授权即可，**不需要也不应该**填写这些凭证。
enum BangumiCredentials {
    static let clientID = "bgm70036a919d2db2f29"
    static let clientSecret = "2b3030f8a03d027754ea30f3424fe8db"

    static var config: BangumiAppConfig {
        BangumiAppConfig(clientID: clientID, clientSecret: clientSecret)
    }
}

/// 共享的 Bangumi 客户端工厂（从 auth.json + 内置凭证重建会话）
enum BangumiSession {

    /// 创建已登录的 API 客户端；未登录返回 nil。
    ///
    /// 登录状态只看 auth.json（令牌与应用凭证随文件跨进程共享）：
    /// 不要用 UserDefaults 里的 clientID/Secret 当"是否登录"的判据——
    /// `swift run`（域 NagomiAni）与打包 .app（域 com.nagomiani.player）的
    /// defaults 域不同，会导致 Bangumi 页显示已登录、番库却报"未登录"。
    static func makeClient() async -> BangumiClient? {
        let auth = BangumiAuth(config: BangumiCredentials.config)
        guard auth.isLoggedIn else { return nil }
        try? await auth.refreshIfNeeded()

        let client = BangumiClient()
        client.accessToken = auth.accessToken
        return client
    }
}

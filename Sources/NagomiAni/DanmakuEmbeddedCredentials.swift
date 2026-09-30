import Foundation
import NagomiAniCore

/// 内置弹幕凭据（弹弹play）：真实值**永不进仓库**（本项目 GPL 开源）。
///
/// 来源链路：开发机仓库根目录的 `DanmakuCredentials.private`（gitignored，两行：
/// 第一行 AppId、第二行 AppSecret）→ `pack.sh` 打包时读取并 XOR 混淆后写入
/// App bundle 的 `Contents/Resources/danmaku-credentials.bin` → 应用启动时在此解码。
/// `swift run`（无 bundle）不读此文件，走 UserDefaults 或保持未配置。
///
/// 混淆只防普通查看，不是加密——若源码/二进制被刻意逆向仍可提取；
/// 泄露时到弹弹play 开放平台重置 AppSecret 并重新打包即可。
/// 设置界面不展示任何凭据内容；高级用户可用 `defaults write <domain>
/// danmaku.appId/appSecret` 覆盖（优先级高于内置值）。
enum DanmakuEmbeddedCredentials {
    private static let mask: UInt8 = 0x5A

    static func load() -> DanmakuCredentials? {
        guard let url = Bundle.main.url(forResource: "danmaku-credentials", withExtension: "bin"),
              let raw = try? Data(contentsOf: url) else { return nil }
        let decoded = raw.map { $0 ^ mask }
        guard let text = String(data: Data(decoded), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2 else { return nil }
        return DanmakuCredentials(appId: lines[0], appSecret: lines[1])
    }
}

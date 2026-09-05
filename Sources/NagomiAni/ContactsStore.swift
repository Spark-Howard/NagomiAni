import Foundation
import SwiftUI
import NagomiAniCore

/// 一个 Bangumi 联系人（相当于 App 内的“好友”，用于在浏览器里给 TA 发私信）
struct BgmContact: Codable, Equatable, Identifiable {
    var id: String { username }
    var username: String
    var nickname: String
    /// 头像（从 v0/users/{username} 拉取后缓存）
    var avatarURL: String?

    init(username: String, nickname: String, avatarURL: String? = nil) {
        self.username = username
        self.nickname = nickname
        self.avatarURL = avatarURL
    }
}

/// Bangumi 联系人/好友存储。
///
/// 说明：官方 API 没有“好友关系/私信”接口，App 把「联系人」当作好友列表展示，
/// 头像/昵称通过公开的 /v0/users/{username} 自动补全；真实好友仍需在网页添加后收录。
@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var contacts: [BgmContact] = []
    /// 网页好友同步结果提示（由常驻 store 持有，避免写已销毁视图的状态）
    @Published var syncMessage: String?

    private static let storageKey = "bangumi.contacts"

    init() {
        load()
    }

    /// 是否已添加该用户名
    func contains(_ username: String) -> Bool {
        contacts.contains { $0.username == username }
    }

    /// 添加联系人（已存在则更新昵称）。返回 true 表示本次是新增
    @discardableResult
    func add(username: String, nickname: String) -> Bool {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        let display = nickname.trimmingCharacters(in: .whitespaces)
        if let index = contacts.firstIndex(where: { $0.username == name }) {
            if !display.isEmpty {
                contacts[index].nickname = display
                save()
            }
            return false
        }
        contacts.append(BgmContact(username: name, nickname: display.isEmpty ? name : display))
        save()
        return true
    }

    /// 用 v0 用户资料补全某联系人的头像/昵称
    func applyProfile(username: String, nickname: String, avatarURL: String?) {
        guard let index = contacts.firstIndex(where: { $0.username == username }) else { return }
        var changed = false
        if contacts[index].nickname == contacts[index].username,
           !nickname.isEmpty {
            contacts[index].nickname = nickname
            changed = true
        }
        if contacts[index].avatarURL != avatarURL, let avatarURL {
            contacts[index].avatarURL = avatarURL
            changed = true
        }
        if changed { save() }
    }

    func remove(username: String) {
        contacts.removeAll { $0.username == username }
        save()
    }

    // MARK: - 网页好友同步（回调收敛在常驻 store 内，避免写已销毁视图的状态）

    /// 处理网页好友页解析结果，然后自动补全头像/昵称
    func ingestFriendEntries(_ entries: [[String: String]]) {
        var added = 0
        for entry in entries {
            let username = entry["u"] ?? ""
            guard !username.isEmpty else { continue }
            let label = entry["label"] ?? username
            if add(username: username, nickname: label) { added += 1 }
            if let avatar = entry["avatar"], !avatar.isEmpty {
                applyProfile(username: username, nickname: label, avatarURL: avatar)
            }
        }
        syncMessage = added > 0 ? "已从网页同步 \(added) 位好友" : "网页上没有抓到新好友"
        Task { await enrichMissingProfiles() }
    }

    /// 用 v0/users/{username} 补全还没有头像、或昵称仍是用户名的好友
    func enrichMissingProfiles() async {
        let client = BangumiClient() // 公开接口，无需登录
        for contact in contacts
        where contact.avatarURL == nil || contact.nickname == contact.username {
            guard let profile = try? await client.userProfile(username: contact.username) else { continue }
            applyProfile(
                username: profile.username,
                nickname: profile.nickname,
                avatarURL: profile.avatar?.medium ?? profile.avatar?.small ?? profile.avatar?.large
            )
        }
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([BgmContact].self, from: data) else { return }
        contacts = decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(contacts) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

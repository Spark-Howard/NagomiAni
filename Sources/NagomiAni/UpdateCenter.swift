import AppKit
import Foundation

/// 应用内更新中心：启动静默检查 GitHub Releases，发现新版本浮出横幅；
/// 用户点「立即更新」→ 应用内下载 DMG（进度可见）→ 去隔离 → 挂载替换 → 自动重启。
///
/// 为什么不用 Sparkle：完整自动更新要求 Developer ID 正式签名 + 公证，本项目为
/// ad-hoc 签名。本实现自己完成「下载→替换→重启」，替换前去掉下载文件的隔离
/// 属性（应用下载的文件由本进程处置，去掉后重启不触发 Gatekeeper），与 ad-hoc
/// 签名兼容；下载/替换失败一律回退「打开下载页」手动安装。
///
/// 静默原则：无新版本、网络失败、开发模式（swift run 非 .app 安装）一律不打扰。
@MainActor
final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()

    enum Phase: Equatable {
        case idle
        case checking
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, progress: Double)
        case installing(ReleaseInfo)
        case failed(ReleaseInfo?, String)
    }

    struct ReleaseInfo: Equatable {
        let version: String // "0.6.0"（tag 去掉 v 前缀）
        let notes: String?
        let dmgURL: URL
    }

    @Published private(set) var phase: Phase = .idle

    /// 下载/安装进行中（横幅不可关闭、不可重复触发）
    var isBusy: Bool {
        if case .downloading = phase { return true }
        if case .installing = phase { return true }
        return false
    }

    private let apiURL = URL(string: "https://api.github.com/repos/Spark-Howard/NagomiAni/releases/latest")!
    private var checkedThisSession = false

    /// 开发模式：swift run 时 Bundle.main 不是安装的 .app（.build 产物），整体跳过
    var isDevBuild: Bool {
        let path = Bundle.main.bundlePath
        return !path.hasSuffix(".app") || path.contains("/.build/")
    }

    /// 当前版本（pack.sh 写入 Info.plist；开发构建为空）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// 启动检查：每次启动至多一次，静默失败
    func startupCheck() async {
        guard !checkedThisSession, !isDevBuild, !currentVersion.isEmpty else { return }
        checkedThisSession = true
        try? await Task.sleep(nanoseconds: 5_000_000_000) // 启动 5s 后再查，不抢首屏
        await check()
    }

    /// 手动/自动检查（失败静默回 idle；有新版本浮横幅）
    func check() async {
        guard !isDevBuild else { return } // 开发构建不查不装（版本号缺失且不可原地替换）
        guard !isBusy else { return }
        if case .available = phase { return }
        phase = .checking
        do {
            let release = try await fetchLatest()
            if Self.isNewerVersion(release.version, than: currentVersion) {
                phase = .available(release)
            } else {
                phase = .idle
            }
        } catch {
            phase = .idle // 检查失败静默（手动检查也不弹错，避免打扰）
        }
    }

    /// 用户点「立即更新」
    func update(to release: ReleaseInfo) {
        guard !isBusy else { return }
        Task { await performUpdate(release) }
    }

    private func performUpdate(_ release: ReleaseInfo) async {
        phase = .downloading(release, progress: 0)
        do {
            let dmgURL = try await download(dmgURL: release.dmgURL, release: release)
            phase = .installing(release)
            try installAndRelaunch(dmgURL: dmgURL)
            // installAndRelaunch 成功即 exit，走不到这里
        } catch {
            phase = .failed(release, error.localizedDescription)
        }
    }

    /// 更新失败时的兜底：打开下载页手动安装
    func openDownloadPage() {
        let page = URL(string: "https://github.com/Spark-Howard/NagomiAni/releases/latest")!
        NSWorkspace.shared.open(page)
    }

    func dismiss() {
        guard !isBusy else { return }
        phase = .idle
    }

    // MARK: - 查询

    private struct GHRelease: Decodable {
        let tagName: String
        let body: String?
        let assets: [GHAsset]

        struct GHAsset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case assets
        }
    }

    private func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(GHRelease.self, from: data)
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") && $0.name.contains("NagomiAni") }),
              let url = URL(string: asset.browserDownloadURL) else {
            throw URLError(.badURL)
        }
        return ReleaseInfo(
            version: release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName,
            notes: release.body,
            dmgURL: url,
        )
    }

    /// 语义化比较："0.6.0" > "0.5.0"
    static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let a = index < candidateParts.count ? candidateParts[index] : 0
            let b = index < currentParts.count ? currentParts[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - 下载

    /// delegate 式下载：AsyncBytes 逐字节遍历 60MB DMG 太慢，用 downloadTask 的
    /// didWriteData 回调拿进度（0~1），落盘到临时目录
    private func download(dmgURL: URL, release: ReleaseInfo) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // 只在仍是本次下载会话时刷新进度（防止用户重试导致串台）
                    if case .downloading = self.phase {
                        self.phase = .downloading(release, progress: fraction)
                    }
                }
            } onFinish: { result in
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            delegate.task = session.downloadTask(with: dmgURL)
            delegate.session = session
            delegate.task.resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: (Double) -> Void
        let onFinish: (Result<URL, Error>) -> Void
        var task: URLSessionDownloadTask!
        weak var session: URLSession?

        init(onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
            self.onProgress = onProgress
            self.onFinish = onFinish
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("NagomiAni-update-\(UUID().uuidString.prefix(6)).dmg")
            do {
                try FileManager.default.moveItem(at: location, to: target)
                onFinish(.success(target))
            } catch {
                onFinish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                onFinish(.failure(error))
            }
        }
    }

    // MARK: - 安装（挂载 → 替换 → 重启）

    private func installAndRelaunch(dmgURL: URL) throws {
        // 1. 去隔离（应用自己下载的文件，去掉后新 app 启动不触发 Gatekeeper）
        try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dmgURL.path])

        // 2. 挂载到确定性挂载点
        let mountPoint = URL(fileURLWithPath: "/tmp/nagomiani-update-\(UUID().uuidString.prefix(6))")
        try runProcess("/usr/bin/hdiutil", [
            "attach", dmgURL.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path,
        ])
        defer {
            try? runProcess("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }

        // 3. 找新 app（DMG 根目录 NagomiAni.app）
        let newApp = mountPoint.appendingPathComponent("NagomiAni.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else {
            throw URLError(.cannotDecodeContentData)
        }

        // 4. 原地替换运行中的 app：先拷到同级 staging，再整目录换名
        //    （旧进程持有 inode 继续跑，重启时打开的已是新 bundle）
        let target = Bundle.main.bundleURL
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent("NagomiAni.update-\(UUID().uuidString.prefix(6)).app")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: newApp, to: staging)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staging, to: target)

        // 5. 重启（新进程起来后老进程退出）
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [target.path]
        try open.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            exit(0)
        }
    }

    @discardableResult
    private func runProcess(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw URLError(.fileDoesNotExist)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

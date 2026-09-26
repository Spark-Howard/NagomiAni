import Foundation

/// 单个文件的续播记录
public struct PlaybackResumeEntry: Codable, Sendable, Equatable {
    /// 上次播放到的位置（秒）
    public var position: Double
    /// 该文件的时长（秒，加载时未知为 0）
    public var duration: Double
    public var updatedAt: Date

    public init(position: Double, duration: Double, updatedAt: Date = Date()) {
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }
}

/// 续播判定：位置值得跳转才返回，否则返回 nil（从头播放）
public enum ResumePolicy {
    /// 记录位置短于该秒数不续播（刚开头就退出，没有续播价值）
    public static let minResumePosition: Double = 15
    /// 距结尾不足该秒数视为已看完：不续播，下次从头开始
    public static let nearEndRemaining: Double = 30

    /// - Parameters:
    ///   - position: 上次播放位置（秒）
    ///   - duration: 上次会话记录的时长（秒；未知为 0，此时只按位置判定）
    public static func resumePosition(position: Double, duration: Double) -> Double? {
        guard position.isFinite, position >= minResumePosition else { return nil }
        guard duration > 0 else { return position }
        // 已越过结尾（记录损坏）或贴近结尾（属"看完"范畴）都从头播
        guard position <= duration - nearEndRemaining else { return nil }
        return position
    }
}

/// 断点续播存储：按文件路径记录播放位置，JSON 持久化到
/// `Application Support/NagomiAni/resume.json`（与 library.json 同目录）。
///
/// 线程安全：所有对 entries 的读写走同一把 NSLock，磁盘写入持锁完成
/// （文件很小，与 MediaLibrary.save() 相同模式）。
/// 调用方（PlayerModel）负责节流——引擎时间回调频率远高于落盘频率。
public final class PlaybackResumeStore: @unchecked Sendable {
    /// 容量上限：超出后按 updatedAt 淘汰最旧记录，防止文件无限膨胀
    public static let capacity = 500

    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: PlaybackResumeEntry]

    /// - Parameter fileURL: 存储文件路径；nil 用默认位置（测试注入临时路径）
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder().decode([String: PlaybackResumeEntry].self, from: data) {
            self.entries = decoded
        } else {
            // 文件缺失/损坏按空库处理，不影响使用
            self.entries = [:]
        }
    }

    public static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NagomiAni", isDirectory: true)
        return dir.appendingPathComponent("resume.json")
    }

    public func entry(forPath path: String) -> PlaybackResumeEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[path]
    }

    public func update(path: String, position: Double, duration: Double, updatedAt: Date = Date()) {
        lock.lock()
        entries[path] = PlaybackResumeEntry(position: position, duration: duration, updatedAt: updatedAt)
        if entries.count > Self.capacity {
            pruneOldestLocked()
        }
        lock.unlock()
        save()
    }

    public func remove(path: String) {
        lock.lock()
        let existed = entries.removeValue(forKey: path) != nil
        lock.unlock()
        guard existed else { return }
        save()
    }

    public func removeAll() {
        lock.lock()
        guard !entries.isEmpty else {
            lock.unlock()
            return
        }
        entries = [:]
        lock.unlock()
        save()
    }

    /// 淘汰最旧记录到容量上限（锁内调用）
    private func pruneOldestLocked() {
        let keep = entries
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.capacity)
            .map { ($0.key, $0.value) }
        entries = Dictionary(uniqueKeysWithValues: keep)
    }

    private func save() {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

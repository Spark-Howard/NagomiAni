import Foundation

/// 历史进度同步服务：串行执行 + 最小间隔节流，尊重 bgm.tv 的频率限制
public final class HistorySyncService: @unchecked Sendable {
    private let client: BangumiClient
    private let queue = DispatchQueue(label: "nagomiani.sync")
    private var lastRequestAt = Date.distantPast
    /// 相邻请求最小间隔（秒）
    public var minInterval: TimeInterval = 2.0

    public init(client: BangumiClient) {
        self.client = client
    }

    /// 标记某条目的一批单集为"看过"（自动重算条目完成度）
    public func markWatched(subjectID: Int, episodeIDs: [Int]) async throws {
        try await throttled {
            try await self.client.markEpisodes(subjectID: subjectID, episodeIDs: episodeIDs, type: .watched)
        }
    }

    /// 将某条目收藏为"在看"
    public func setDoing(subjectID: Int) async throws {
        try await throttled {
            try await self.client.updateCollection(subjectID: subjectID, payload: CollectionModifyPayload(type: .doing))
        }
    }

    // MARK: - 私有

    private func throttled<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                let elapsed = Date().timeIntervalSince(self.lastRequestAt)
                if elapsed < self.minInterval {
                    Thread.sleep(forTimeInterval: self.minInterval - elapsed)
                }
                self.lastRequestAt = Date()
                Task {
                    do {
                        let result = try await operation()
                        cont.resume(returning: result)
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}

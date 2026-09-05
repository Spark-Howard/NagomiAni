import Foundation

/// 本地媒体文件
public struct MediaFile: Codable, Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let episodeNumber: Int?
    public let fileName: String
    public let fileSize: Int64?
    public let modifiedAt: Date?
}

/// 匹配状态
public enum MatchState: String, Codable, Sendable {
    case unmatched // 未关联 Bangumi 条目
    case pending   // 匹配存疑，等待用户确认
    case matched   // 已关联
}

/// 一部番（按 seriesKey 聚合的文件集合）
public struct Series: Codable, Sendable, Identifiable, Equatable {
    public var id: String { seriesKey }
    public let seriesKey: String
    public var displayName: String
    public var files: [MediaFile]
    /// Bangumi 条目关联
    public var subjectID: Int?
    public var matchState: MatchState

    /// 按集数排序（未知集排最后）
    public var sortedFiles: [MediaFile] {
        files.sorted { lhs, rhs in
            let lhsEp = lhs.episodeNumber ?? Int.max
            let rhsEp = rhs.episodeNumber ?? Int.max
            return lhsEp < rhsEp
        }
    }
}

/// 番库持久化结构
public struct LibraryStore: Codable, Sendable {
    public var folders: [String]
    public var series: [Series]

    public init(folders: [String], series: [Series]) {
        self.folders = folders
        self.series = series
    }
}

/// 本地番库：目录管理 + 递归扫描 + 索引持久化
///
/// 线程安全：rescan()/rescanFolder()/relocateSeries() 可能被 LibraryViewModel
/// 放到后台线程执行（Task.detached），而 runAutoMatch/绑定/移除等在主线程直接调用。
/// 以前两者会同时读写 store（无锁 → 崩溃/丢更新），现在所有对 store 的读改写都走
/// 同一把 NSLock；耗时的磁盘扫描在锁外完成，仅合并/落盘持锁，避免长时间卡 UI。
public final class MediaLibrary: @unchecked Sendable {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "webm", "avi", "ts",
        "flv", "wmv", "rmvb", "mpg", "mpeg", "ogv", "3gp",
    ]

    private let storeURL: URL
    private let lock = NSLock()
    private var store: LibraryStore

    public init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(LibraryStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = LibraryStore(folders: [], series: [])
        }
    }

    /// 在锁内执行闭包（所有对 store 的读写都必须经过这里）
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var folders: [String] { withLock { store.folders } }
    public var series: [Series] { withLock { store.series } }

    // MARK: - 目录管理

    /// 路径规范化：逐组件解析符号链接（如 /var → /private/var），
    /// 保证与 FileManager 枚举器返回的真实路径一致。
    /// 注意：URL.resolvingSymlinksInPath() 在此环境下不解析 /var，故手动实现。
    static func canonicalPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        var resolved = ""
        for component in (standardized as NSString).pathComponents {
            if component == "/" {
                resolved = "/"
                continue
            }
            let candidate = (resolved as NSString).appendingPathComponent(component)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                if destination.hasPrefix("/") {
                    resolved = destination
                } else {
                    resolved = ((candidate as NSString).deletingLastPathComponent as NSString)
                        .appendingPathComponent(destination)
                }
            } else {
                resolved = candidate
            }
        }
        return resolved
    }

    @discardableResult
    public func addFolder(_ path: String) -> Bool {
        withLock {
            let standard = Self.canonicalPath(path)
            guard !store.folders.contains(standard) else { return false }
            store.folders.append(standard)
            save()
            return true
        }
    }

    /// 移除目录：同时删除该目录下的文件，并清理空系列（保留其它目录的关联信息）
    public func removeFolder(_ path: String) {
        withLock {
            let standard = Self.canonicalPath(path)
            store.folders.removeAll { $0 == standard }
            store.series = store.series.compactMap { series in
                var series = series
                series.files.removeAll { $0.path.hasPrefix(standard + "/") }
                return series.files.isEmpty ? nil : series
            }
            save()
        }
    }

    // MARK: - 扫描

    /// 全量重扫：以磁盘为准重建文件索引，同时保留旧的 Bangumi 关联（按 seriesKey）
    public func rescan() {
        // 磁盘扫描耗时长，放在锁外；只对「合并 + 落盘」持锁
        let folders = self.folders
        var found: [String: Series] = [:]
        for folder in folders {
            scan(folder: folder, into: &found)
        }

        // 目录重叠时按路径去重
        for key in found.keys {
            var seen = Set<String>()
            found[key]?.files.removeAll { !seen.insert($0.path).inserted }
        }

        withLock {
            // 合并旧关联信息
            let oldByKey = Dictionary(uniqueKeysWithValues: store.series.map { ($0.seriesKey, $0) })
            var merged: [Series] = []
            for key in found.keys.sorted() {
                guard var series = found[key] else { continue }
                if let old = oldByKey[key] {
                    series.subjectID = old.subjectID
                    series.matchState = old.matchState
                }
                merged.append(series)
            }
            store.series = merged
            save()
        }
    }

    /// 只重扫某个目录：以磁盘为准更新该目录下的系列（补新集/删消失文件），
    /// 保留 Bangumi 关联，其他目录的系列不动。
    /// 文件被删空的系列：已关联的保留但清空文件（展开显示"本地未找到"，
    /// 重新下载后再"更新"即恢复）；未关联的移除。
    /// 返回 false 表示目录不存在（目录不存在时仍会执行上述清理）。
    @discardableResult
    public func rescanFolder(_ path: String) -> Bool {
        let standard = Self.canonicalPath(path)
        var isDir: ObjCBool = false
        let folderExists = FileManager.default.fileExists(atPath: standard, isDirectory: &isDir)
            && isDir.boolValue

        var found: [String: Series] = [:]
        if folderExists {
            scan(folder: standard, into: &found)
            for key in found.keys {
                var seen = Set<String>()
                found[key]?.files.removeAll { !seen.insert($0.path).inserted }
            }
        }

        let scannedKeys = Set(found.keys)
        withLock {
            var merged: [Series] = []
            for series in store.series {
                if scannedKeys.contains(series.seriesKey) {
                    // 该目录下的系列：以磁盘为准重建文件，保留 Bangumi 关联
                    guard var fresh = found[series.seriesKey] else { continue }
                    fresh.subjectID = series.subjectID
                    fresh.matchState = series.matchState
                    merged.append(fresh)
                    found[series.seriesKey] = nil
                } else if series.seriesKey == standard || series.seriesKey.hasPrefix(standard + "/") {
                    // 目录（或其子目录）在磁盘上已没有视频文件 —— 之前索引的文件全部被删
                    // （整目录删除、或文件删空目录还在都算）。
                    // 不能残留旧文件：否则列表里仍显示可点击的失效行，点击播放报"文件不存在"。
                    // 已关联的番保留（文件清空）→ 展开后按 Bangumi 集数显示"本地未找到"，
                    // 之后重新下载点"更新"即可按原关联恢复；未关联的空系列没有保留价值，直接移除。
                    if series.subjectID != nil {
                        var emptied = series
                        emptied.files = []
                        merged.append(emptied)
                    }
                } else {
                    merged.append(series)
                }
            }
            // 该目录下新增的系列（此前不在库中）
            for key in found.keys.sorted() {
                guard let series = found[key], !series.files.isEmpty else { continue }
                merged.append(series)
            }

            store.series = merged
            save()
        }
        return folderExists
    }

    /// 某部番所属的根目录：seriesKey 本身是目录则用它，
    /// 否则取 folders 中最近的父目录
    public func owningFolder(of seriesKey: String) -> String? {
        withLock {
            if store.folders.contains(seriesKey) { return seriesKey }
            return store.folders
                .filter { seriesKey.hasPrefix($0 + "/") }
                .max { $0.count < $1.count }
        }
    }

    /// 移除一部番的条目（文件已删除场景）。
    /// 若该番的目录本身是已登记的库目录（此时应已没有视频），把目录登记一并移除，
    /// 避免留下再也扫不到的空目录。
    public func removeSeries(_ seriesKey: String) {
        withLock {
            store.series.removeAll { $0.seriesKey == seriesKey }
            if store.folders.contains(seriesKey) {
                store.folders.removeAll { $0 == seriesKey }
            }
            save()
        }
    }

    /// 把某部番迁移到新目录（文件被移动/重命名场景）：
    /// 登记新目录 → 扫描 → 把旧条目的 Bangumi 关联套到新位置找到的系列上 → 移除旧空条目。
    ///
    /// 目标判定：所选目录里只有一部番（文件直接放在所选目录，或仅扫出一个系列）才迁移；
    /// 若所选目录同时包含多部番则返回 nil（避免把关联绑到错误的番上），由调用方提示用户
    /// 改选该番自己的文件夹。
    /// 成功返回新的 seriesKey。
    public func relocateSeries(oldSeriesKey: String, to newFolderPath: String) -> String? {
        // 先取旧条目快照（判定是否还有旧条目可迁移）
        let oldSnapshot: Series? = withLock {
            store.series.first { $0.seriesKey == oldSeriesKey }
        }
        guard oldSnapshot != nil else { return nil }

        let standard = Self.canonicalPath(newFolderPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standard, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // 磁盘扫描在锁外执行
        var found: [String: Series] = [:]
        scan(folder: standard, into: &found)
        let nonEmpty = found.values.filter { !$0.files.isEmpty }

        // 目标：文件直接放在所选目录里；否则所选目录下恰好只有一部番
        let target: Series?
        if let direct = found[standard], !direct.files.isEmpty {
            target = direct
        } else if nonEmpty.count == 1 {
            target = nonEmpty.first
        } else {
            target = nil
        }
        guard var relocated = target, !relocated.files.isEmpty else { return nil }

        // 合并 + 落盘持锁；期间若旧条目已被并发操作移除则放弃本次迁移
        return withLock {
            guard let old = store.series.first(where: { $0.seriesKey == oldSeriesKey }) else { return nil }
            // 确认迁移目标后再登记新目录，失败时不留下空的目录登记
            if !store.folders.contains(standard) {
                store.folders.append(standard)
            }
            relocated.subjectID = old.subjectID
            relocated.matchState = .matched
            store.series.removeAll { $0.seriesKey == oldSeriesKey }
            store.series.removeAll { $0.seriesKey == relocated.seriesKey }
            store.series.append(relocated)
            // 旧目录若单独登记过（且文件已全部移走）从目录列表移除
            if store.folders.contains(oldSeriesKey) {
                store.folders.removeAll { $0 == oldSeriesKey }
            }
            save()
            return relocated.seriesKey
        }
    }

    private func scan(folder: String, into found: inout [String: Series]) {
        let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard Self.videoExtensions.contains(ext) else { continue }

            let parsed = MediaMatching.parse(fileName: url.lastPathComponent)
            // 分组单位 = 文件所在目录（一个文件夹 = 一部番），
            // 避免不同命名/字幕组的同一部番被拆散
            let seriesDir = url.deletingLastPathComponent().path
            let key = seriesDir
            let folderName = (seriesDir as NSString).lastPathComponent

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let file = MediaFile(
                path: url.path,
                episodeNumber: parsed.episodeNumber,
                fileName: url.lastPathComponent,
                fileSize: (attrs?[.size] as? NSNumber)?.int64Value,
                modifiedAt: attrs?[.modificationDate] as? Date
            )

            if found[key] == nil {
                found[key] = Series(
                    seriesKey: key,
                    displayName: folderName.isEmpty ? key : folderName,
                    files: [],
                    subjectID: nil,
                    matchState: .unmatched
                )
            }
            found[key]?.files.append(file)
        }
    }

    // MARK: - Bangumi 关联（L2 自动匹配会用到）

    /// 设置系列与 Bangumi 条目的关联
    @discardableResult
    public func setBinding(seriesKey: String, subjectID: Int) -> Bool {
        withLock {
            guard let index = store.series.firstIndex(where: { $0.seriesKey == seriesKey }) else { return false }
            store.series[index].subjectID = subjectID
            store.series[index].matchState = .matched
            save()
            return true
        }
    }

    /// 标记为"待确认"（自动匹配存疑，等待用户手动选择）
    @discardableResult
    public func markPending(seriesKey: String) -> Bool {
        withLock {
            guard let index = store.series.firstIndex(where: { $0.seriesKey == seriesKey }) else { return false }
            store.series[index].matchState = .pending
            save()
            return true
        }
    }

    /// 解除系列与 Bangumi 条目的关联
    @discardableResult
    public func unbind(seriesKey: String) -> Bool {
        withLock {
            guard let index = store.series.firstIndex(where: { $0.seriesKey == seriesKey }) else { return false }
            store.series[index].subjectID = nil
            store.series[index].matchState = .unmatched
            save()
            return true
        }
    }

    // MARK: - 持久化

    /// 必须在持锁状态下调用
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(store)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            print("[MediaLibrary] 保存失败: \(error)")
        }
    }
}

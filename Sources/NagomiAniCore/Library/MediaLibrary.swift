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
public final class MediaLibrary: @unchecked Sendable {
    public static let videoExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "webm", "avi", "ts",
        "flv", "wmv", "rmvb", "mpg", "mpeg", "ogv", "3gp",
    ]

    private let storeURL: URL
    public private(set) var store: LibraryStore

    public init(storeURL: URL) {
        self.storeURL = storeURL
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode(LibraryStore.self, from: data) {
            self.store = decoded
        } else {
            self.store = LibraryStore(folders: [], series: [])
        }
    }

    public var folders: [String] { store.folders }
    public var series: [Series] { store.series }

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
        let standard = Self.canonicalPath(path)
        guard !store.folders.contains(standard) else { return false }
        store.folders.append(standard)
        save()
        return true
    }

    /// 移除目录：同时删除该目录下的文件，并清理空系列（保留其它目录的关联信息）
    public func removeFolder(_ path: String) {
        let standard = Self.canonicalPath(path)
        store.folders.removeAll { $0 == standard }
        store.series = store.series.compactMap { series in
            var series = series
            series.files.removeAll { $0.path.hasPrefix(standard + "/") }
            return series.files.isEmpty ? nil : series
        }
        save()
    }

    // MARK: - 扫描

    /// 全量重扫：以磁盘为准重建文件索引，同时保留旧的 Bangumi 关联（按 seriesKey）
    public func rescan() {
        var found: [String: Series] = [:]
        for folder in store.folders {
            scan(folder: folder, into: &found)
        }

        // 目录重叠时按路径去重
        for key in found.keys {
            var seen = Set<String>()
            found[key]?.files.removeAll { !seen.insert($0.path).inserted }
        }

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

    /// 只重扫某个目录：以磁盘为准更新该目录下的系列（补新集/删消失文件），
    /// 保留 Bangumi 关联，其他目录的系列不动。返回 false 表示目录不存在。
    @discardableResult
    public func rescanFolder(_ path: String) -> Bool {
        let standard = Self.canonicalPath(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standard, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        var found: [String: Series] = [:]
        scan(folder: standard, into: &found)
        for key in found.keys {
            var seen = Set<String>()
            found[key]?.files.removeAll { !seen.insert($0.path).inserted }
        }

        let scannedKeys = Set(found.keys)
        var merged: [Series] = []
        for series in store.series {
            if scannedKeys.contains(series.seriesKey) {
                // 该目录下的系列：以磁盘为准重建文件，保留 Bangumi 关联
                guard var fresh = found[series.seriesKey] else { continue }
                fresh.subjectID = series.subjectID
                fresh.matchState = series.matchState
                merged.append(fresh)
                found[series.seriesKey] = nil
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
        return true
    }

    /// 某部番所属的根目录：seriesKey 本身是目录则用它，
    /// 否则取 folders 中最近的父目录
    public func owningFolder(of seriesKey: String) -> String? {
        if store.folders.contains(seriesKey) { return seriesKey }
        return store.folders
            .filter { seriesKey.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
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
        guard let index = store.series.firstIndex(where: { $0.seriesKey == seriesKey }) else { return false }
        store.series[index].subjectID = subjectID
        store.series[index].matchState = .matched
        save()
        return true
    }

    /// 标记为"待确认"（自动匹配存疑，等待用户手动选择）
    @discardableResult
    public func markPending(seriesKey: String) -> Bool {
        guard let index = store.series.firstIndex(where: { $0.seriesKey == seriesKey }) else { return false }
        store.series[index].matchState = .pending
        save()
        return true
    }

    /// 解除系列与 Bangumi 条目的关联
    @discardableResult
    public func unbind(seriesKey: String) -> Bool {
        guard let index = store.series.firstIndex(where: { $0.seriesKey == seriesKey }) else { return false }
        store.series[index].subjectID = nil
        store.series[index].matchState = .unmatched
        save()
        return true
    }

    // MARK: - 持久化

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

import CoreServices
import Foundation

/// 把文件系统事件路径换算成「需要重扫的目录集合」（纯函数，可单测）。
///
/// 输入输出均假定是规范化后的真实路径：FSEvents 返回真实路径；
/// 番库的 folders / seriesKey 在 addFolder / 扫描时已经过 canonicalPath。
///
/// 换算规则（按优先级，命中即止）：
/// - 目录事件：目录本身是某番 → 扫该番；在某番之内 → 扫该番；
///   在库根之下（新番目录 / 整目录移入）→ 扫该目录本身；是库根 → 扫根
/// - 文件事件（含已删除后不存在的路径）：父目录是某番 → 扫该番（最常见：新集下载完）；
///   父目录在某番之内 → 扫该番；父目录在库内 → 扫父目录（会自动建出新系列）
/// - 库外路径（如废纸篓）一律忽略
///
/// 结果做祖先去重：目标 A 在目标 B 之内时丢弃 A（rescanFolder 是递归扫描，扫 B 已覆盖 A）。
public enum DirectoryChangePlanner {
    /// 判断事件路径是否与番库相关：视频文件，或目录（目录可能没有扩展名）。
    /// .nfo/.jpg/下载器临时文件等非视频不触发重扫。
    /// 已不存在的路径（删除事件）：空扩展名可能是被删的目录，保守放行
    /// （交由父目录重扫兜底）；非视频扩展名的必然与番库无关。
    public static func isRelevantPath(
        _ path: String,
        isDirectory: (String) -> Bool
    ) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if MediaLibrary.videoExtensions.contains(ext) { return true }
        if isDirectory(path) { return true }
        return ext.isEmpty
    }

    public static func rescanTargets(
        eventPaths: [String],
        roots: [String],
        seriesKeys: [String],
        isDirectory: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    ) -> Set<String> {
        let rootSet = Set(roots)
        let seriesSet = Set(seriesKeys)

        var targets = Set<String>()
        for path in eventPaths {
            guard isRelevantPath(path, isDirectory: isDirectory) else { continue }

            if isDirectory(path) {
                // 目录事件
                if seriesSet.contains(path) {
                    targets.insert(path)
                    continue
                }
                if let series = seriesSet.first(where: { path.hasPrefix($0 + "/") }) {
                    targets.insert(series)
                    continue
                }
                // 新番目录 / 整目录移入 / 库根本身
                if isWithinRoots(path, rootSet) {
                    targets.insert(path)
                }
                // 库外目录忽略（如废纸篓）
            } else {
                // 文件事件（文件可能已被删除，此时按其父目录处理）
                let parent = (path as NSString).deletingLastPathComponent
                if seriesSet.contains(parent) {
                    targets.insert(parent)
                    continue
                }
                if let series = seriesSet.first(where: { parent.hasPrefix($0 + "/") }) {
                    targets.insert(series)
                    continue
                }
                // 未索引目录里的文件（新番的第一集）；父目录是库根时扫整个根
                if isWithinRoots(parent, rootSet) {
                    targets.insert(parent)
                }
            }
        }

        return pruningDescendants(of: targets)
    }

    private static func isWithinRoots(_ path: String, _ rootSet: Set<String>) -> Bool {
        rootSet.contains(path) || rootSet.contains(where: { path.hasPrefix($0 + "/") })
    }

    /// 目标 A 在目标 B 之内（A != B）时丢弃 A
    private static func pruningDescendants(of targets: Set<String>) -> Set<String> {
        targets.filter { target in
            !targets.contains { other in
                other != target && target.hasPrefix(other + "/")
            }
        }
    }
}

/// FSEvents 封装：监控目录树变化，事件缓冲后合并回调。
///
/// 下载器写一个文件会触发多次事件（创建/写入/关闭/元数据），直接逐条重扫会
/// 频繁扫盘；这里把事件缓冲 1.5s 静默期合并成一次回调。
///
/// 流创建失败时静默降级（等同无监控，不影响手动扫描）。
public final class FSEventsDirectoryMonitor: @unchecked Sendable {
    /// 事件静默期（秒）：此窗口内的事件合并为一次回调
    private static let coalescingInterval: TimeInterval = 1.5
    /// FSEvents 自身的延迟（秒）
    private static let streamLatency: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "nagomiani.dirmonitor")
    private let onEvents: ([String]) -> Void
    private var roots: [String]
    private var stream: FSEventStreamRef?

    /// 仅在 queue 上访问
    private var bufferedPaths: Set<String> = []
    private var flushWork: DispatchWorkItem?

    /// - Parameters:
    ///   - roots: 要监控的目录（应为规范化后的真实路径）
    ///   - onEvents: 事件回调（在内部串行队列上调用，调用方自行跳线程）
    public init(roots: [String], onEvents: @escaping ([String]) -> Void) {
        self.roots = roots
        self.onEvents = onEvents
    }

    deinit {
        stop()
    }

    public func start() {
        guard stream == nil, !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let monitor = Unmanaged<FSEventsDirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
                let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
                let paths = (cfArray as NSArray).compactMap { $0 as? String }
                monitor.enqueue(paths: paths)
            },
            &context,
            roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.streamLatency,
            flags
        ) else {
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    public func stop() {
        queue.sync {
            flushWork?.cancel()
            flushWork = nil
            bufferedPaths = []
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    /// 监控根目录变化时重建流
    public func updateRoots(_ newRoots: [String]) {
        guard newRoots != roots else { return }
        stop()
        roots = newRoots
        start()
    }

    /// 仅在 queue 上调用：缓冲事件，静默期后合并回调
    private func enqueue(paths: [String]) {
        bufferedPaths.formUnion(paths)
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.bufferedPaths)
            self.bufferedPaths = []
            self.flushWork = nil
            guard !paths.isEmpty else { return }
            self.onEvents(paths)
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + Self.coalescingInterval, execute: work)
    }
}

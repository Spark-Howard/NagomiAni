import AppKit
import CryptoKit
import SwiftUI

/// 封面图加载器：内存 + 磁盘两级缓存，并合并同一 URL 的并发请求。
///
/// 存在的理由：SwiftUI 的 `AsyncImage` **不做缓存**——每次视图重建都会重新下载。
/// 本 App 切换模块会重建页面子树，靠缓存才能避免每次切回 Bangumi 都把封面重下一遍。
/// Bangumi CDN 其实给了 `Cache-Control: max-age=691200, immutable`，缓存是安全的。
///
/// 渲染由 `CoverNSView` 自绘完成（见其文档注释，**不要**改回 `layer.contents`
/// 或 `NSImageView`，两者都会被 AppKit 清空导致图片消失）。
final class CoverImageLoader {
    static let shared = CoverImageLoader()

    private let memory = NSCache<NSURL, NSImage>()
    /// 正在下载的同一 URL：合并请求，避免同一张图并发下多次
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let lock = NSLock()

    private let diskDirectory: URL
    /// 磁盘缓存有效期（与 CDN 的 max-age 对齐：8 天）
    private let diskTTL: TimeInterval = 8 * 24 * 60 * 60

    private init() {
        memory.countLimit = 300

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskDirectory = caches
            .appendingPathComponent("NagomiAni", isDirectory: true)
            .appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// 取图：内存 → 磁盘 → 网络。命中缓存时**同步返回**，界面立刻有内容。
    func image(for url: URL) async -> NSImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }

        let task: Task<NSImage?, Never> = lock.withLock {
            if let existing = inFlight[url] { return existing }
            let task = Task<NSImage?, Never> { [weak self] in
                guard let self else { return nil }

                // 磁盘命中
                if let disk = self.loadFromDisk(url) {
                    self.memory.setObject(disk, forKey: url as NSURL)
                    return disk
                }
                // 网络
                guard let image = await self.download(url) else { return nil }
                self.memory.setObject(image, forKey: url as NSURL)
                self.saveToDisk(image, url: url)
                return image
            }
            inFlight[url] = task
            return task
        }

        let image = await task.value
        lock.withLock { inFlight[url] = nil }
        return image
    }

    // MARK: - 网络

    private func download(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // UA 版本从 bundle 读（打包版自动跟随 Info.plist；swift run 无 bundle 回退常量）
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.5.0"
        request.setValue("NagomiAni/\(appVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    // MARK: - 磁盘

    /// 用 URL 的 SHA256 做文件名（避免文件名里的斜杠/问号与超长路径）
    private func diskURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(name)
    }

    private func loadFromDisk(_ url: URL) -> NSImage? {
        let file = diskURL(for: url)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < diskTTL,
              let image = NSImage(contentsOf: file)
        else { return nil }
        return image
    }

    private func saveToDisk(_ image: NSImage, url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return }
        try? data.write(to: diskURL(for: url), options: .atomic)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

/// 确定性渲染远程封面。
///
/// ## 为什么自己 `draw(_:)`，而不用 `NSImageView`
///
/// ⚠️ **不要把绘制方式改回下面两种 —— 它们都会被 AppKit 清空，导致图片"第一次显示不出来"**：
///
/// 1. `layer.contents = cgImage` + `contentsGravity`：页面隐藏再显示后
///    （本 App 切模块就是 `opacity 0/1`），AppKit 会把 `layer.contents` 清成 nil，
///    而 SwiftUI 不会再调 `updateNSView`，图片永久消失。
/// 2. 预渲染位图 + `NSImageView.image`：同样会被清掉。实测在 `apply()` 里刚设好
///    `view.image`，1.8 秒后回查又是 nil，且期间 `viewDidHide/Unhide/MoveToWindow`
///    与 `isHidden/alpha` 都没有变化 —— 属于 `NSImageView` 内部把 image 丢掉了。
///
/// 现在**完全自己绘制**：`draw(_:)` 里按当前 bounds 把原图等比画进去。
/// 绘制是纯函数式的，没有可被 AppKit 清空的状态；SwiftUI 只要让视图重绘，图就回来。
/// 缩放用 `.high` 插值，缩小质量也比交给显示层更好。
///
/// 分辨率档位仍由 `SubjectImages.bestURL` 按显示像素挑选，图片本身走两级缓存。
struct CoverImageView: NSViewRepresentable {
    let url: URL?
    /// 占位底色（默认与系统次要标签同色系的浅灰）
    var placeholderColor: NSColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15)
    /// 圆角（默认 8，与详情页大封面一致）
    var cornerRadius: CGFloat = 8

    func makeNSView(context: Context) -> CoverNSView {
        let view = CoverNSView()
        view.placeholderColor = placeholderColor
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: CoverNSView, context: Context) {
        view.placeholderColor = placeholderColor
        view.cornerRadius = cornerRadius
        view.setImageURL(url)
    }
}

/// 自绘封面视图：把"要显示的图"作为状态，`draw(_:)` 时按 bounds 等比绘制。
///
/// ⚠️ 不要改回 `NSImageView` / `layer.contents`，理由见 `CoverImageView` 的文档注释。
final class CoverNSView: NSView {
    var placeholderColor: NSColor = .quaternaryLabelColor
    var cornerRadius: CGFloat = 8

    /// 已解码的原图（有内存/磁盘缓存，取回很快）
    private var source: NSImage?
    private var currentKey: String?
    /// 视图销毁时取消在途加载
    private var loadTask: Task<Void, Never>?

    override var isFlipped: Bool { false }

    func setImageURL(_ url: URL?) {
        guard let url else {
            currentKey = nil
            source = nil
            loadTask?.cancel()
            needsDisplay = true
            return
        }
        let key = url.absoluteString
        guard currentKey != key else { return }
        currentKey = key
        source = nil
        needsDisplay = true

        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await CoverImageLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.currentKey == key else { return }
                self.source = image
                self.needsDisplay = true
            }
        }
    }

    deinit { loadTask?.cancel() }


    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        placeholderColor.setFill()
        path.fill()

        guard let source, bounds.width >= 1, bounds.height >= 1 else { return }

        path.addClip()
        // 等比缩放进 bounds（居中留边）—— 与"整图可见、不裁切"的既有行为一致
        let imageSize = source.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: drawRect,
                    from: NSRect(origin: .zero, size: imageSize),
                    operation: .sourceOver,
                    fraction: 1.0,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high])
    }
}

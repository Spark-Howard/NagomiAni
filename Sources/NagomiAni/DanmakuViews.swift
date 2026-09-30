import SwiftUI
import NagomiAniCore

/// 弹幕覆盖层：TimelineView + Canvas 逐帧渲染，绘制是 f(当前播放时间) 的纯函数——
/// 暂停冻结（时间停走）、拖动进度自动重排、seek 无需任何状态修正。
/// 车道分配在弹幕加载/画面尺寸变化时预计算一次（Core 纯函数，注入字体实测宽度），
/// 逐帧只做时间窗口过滤 + 位图 blit。
///
/// 性能关键：弹幕文本**预渲染为位图精灵**（懒生成 + 缓存），逐帧只画 CGImage——
/// 旧实现每帧对每条可见弹幕做 SwiftUI Text 排版（字体度量/布局是每帧大头），
/// 弹幕一多就掉帧；位图化后每帧成本是纯贴图，与弹幕数量无关。
/// 不参与命中测试：控制条/顶栏在其上层正常交互。
struct DanmakuOverlayView: View {
    @ObservedObject var controller: DanmakuController
    /// 每帧读取的当前播放时间（引擎 time-pos，事件级更新）
    let currentTime: () -> Double
    /// 是否正在播放（暂停时冻结弹幕）
    let isPlaying: Bool

    @State private var trackItems: [DanmakuTrackItem] = []
    @State private var laneCount = 8
    @State private var canvasSize: CGSize = .zero
    /// 精灵缓存是普通类实例（@State 持引用）：绘制期间写入不触发视图刷新
    @State private var spriteCache = DanmakuSpriteCache()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
                Canvas { context, size in
                    render(context: &context, size: size, time: currentTime())
                }
            }
            .onChange(of: geo.size) { newSize in
                recomputeLanes(size: newSize)
            }
            .onChange(of: controller.comments) { _ in
                recomputeLanes(size: geo.size)
            }
            .onAppear {
                recomputeLanes(size: geo.size)
            }
        }
        .allowsHitTesting(false)
    }

    /// 车道数按画面高度计算（滚动区占上方 75%）；车道分配用字体实测宽度
    private func recomputeLanes(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        canvasSize = size
        laneCount = max(1, Int(size.height * DanmakuLayout.scrollAreaRatio / DanmakuLayout.laneHeight))
        spriteCache.clear() // 新一代弹幕/新尺寸：旧精灵与宽度缓存全部作废
        trackItems = DanmakuLayout.assignLanes(
            comments: controller.comments,
            laneCount: laneCount,
            screenWidth: size.width,
            measure: { spriteCache.measureWidth(text: $0) }
        )
    }

    private func render(context: inout GraphicsContext, size: CGSize, time: Double) {
        let scale = displayScale
        for item in trackItems {
            let elapsed = time - item.comment.time
            switch item.comment.mode {
            case .scroll:
                // 右缘从画面外滑入（与车道分配同一条位移公式）
                guard elapsed >= 0, elapsed <= DanmakuLayout.travelDuration else { continue }
                let y = CGFloat(item.lane) * DanmakuLayout.laneHeight + DanmakuLayout.laneHeight / 2 + 4
                draw(item, at: CGPoint(x: (size.width + item.width) * (1 - elapsed / DanmakuLayout.travelDuration)
                    - item.width / 2, y: y), anchor: .leading, in: &context, scale: scale)
            case .top:
                guard elapsed >= 0, elapsed <= DanmakuLayout.stackDuration else { continue }
                let y = CGFloat(item.lane) * DanmakuLayout.laneHeight + DanmakuLayout.laneHeight / 2 + 4
                draw(item, at: CGPoint(x: size.width / 2, y: y), anchor: .center, in: &context, scale: scale)
            case .bottom:
                guard elapsed >= 0, elapsed <= DanmakuLayout.stackDuration else { continue }
                let y = size.height - CGFloat(item.lane + 1) * DanmakuLayout.laneHeight
                    + DanmakuLayout.laneHeight / 2 - 4
                draw(item, at: CGPoint(x: size.width / 2, y: y), anchor: .center, in: &context, scale: scale)
            }
        }
    }

    /// 画一条弹幕：精灵懒生成（首次可见时渲染一次，此后每帧纯 blit）
    private func draw(
        _ item: DanmakuTrackItem, at point: CGPoint, anchor: HorizontalAnchor,
        in context: inout GraphicsContext, scale: CGFloat
    ) {
        guard let sprite = spriteCache.sprite(text: item.comment.text, color: item.comment.color, scale: scale) else {
            return
        }
        let x: CGFloat
        switch anchor {
        case .leading: x = point.x // 精灵左缘 == 文本左缘，几何与旧实现一致
        case .center: x = point.x - sprite.width / 2
        }
        context.draw(
            context.resolve(sprite.image),
            in: CGRect(x: x, y: point.y - sprite.height / 2, width: sprite.width, height: sprite.height)
        )
    }

    private enum HorizontalAnchor { case leading, center }
}

/// 弹幕文本位图精灵缓存：NSAttributedString 一次性渲染成 hi-dpi CGImage。
/// 普通类（非 ObservableObject）——Canvas 绘制期间写入不触发视图刷新。
private final class DanmakuSpriteCache {
    struct Sprite {
        let image: Image // SwiftUI Image（包裹 CGImage），绘制时 resolve
        let width: CGFloat // 逻辑 pt
        let height: CGFloat
    }

    private var sprites: [String: Sprite] = [:]
    private var widths: [String: CGFloat] = [:]
    /// 上限兜底：超长集弹幕总量大，超出后整代清空（回滚 seek 时按需重渲染，几毫秒级）
    private static let spriteLimit = 600
    private static let font = NSFont.systemFont(ofSize: 22, weight: .medium)

    func clear() {
        sprites.removeAll()
        widths.removeAll()
    }

    /// 真实文本宽度（字体度量，按文本去重缓存）——车道分配与滚动位移都用它
    func measureWidth(text: String) -> CGFloat {
        if let cached = widths[text] { return cached }
        let width = attributedString(for: text, color: 0xFFFFFF).size().width
        widths[text] = width
        return width
    }

    func sprite(text: String, color: UInt32, scale: CGFloat) -> Sprite? {
        let key = "\(color)|\(text)"
        if let cached = sprites[key] { return cached }
        guard let made = makeSprite(text: text, color: color, scale: scale) else { return nil }
        if sprites.count >= Self.spriteLimit { sprites.removeAll() }
        sprites[key] = made
        return made
    }

    private func attributedString(for text: String, color: UInt32) -> NSAttributedString {
        let color = NSColor(
            red: CGFloat((color >> 16) & 0xFF) / 255,
            green: CGFloat((color >> 8) & 0xFF) / 255,
            blue: CGFloat(color & 0xFF) / 255,
            alpha: 1
        )
        return NSAttributedString(string: text, attributes: [
            .font: Self.font,
            .foregroundColor: color,
        ])
    }

    private func makeSprite(text: String, color: UInt32, scale: CGFloat) -> Sprite? {
        let line = attributedString(for: text, color: color)
        let bounds = line.size()
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pixelWidth = max(1, Int(ceil(bounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(bounds.height * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)) // 1:1，缩放自己控制
        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        let cg = ctx.cgContext
        cg.translateBy(x: 0, y: CGFloat(pixelHeight))
        cg.scaleBy(x: scale, y: -scale) // 翻转到顶部原点 + 回到逻辑 pt 坐标
        line.draw(
            with: CGRect(origin: .zero, size: bounds),
            options: [.usesLineFragmentOrigin]
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = rep.cgImage else { return nil }
        // macOS 用 NSImage 包装（size = 逻辑 pt，Canvas 绘制时按 rect 缩放）
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
        return Sprite(
            image: Image(nsImage: nsImage),
            width: bounds.width,
            height: bounds.height
        )
    }
}

/// 控制条弹幕菜单：显示开关 / 状态 / 重新获取 / 设置
struct DanmakuMenu: View {
    @ObservedObject var controller: DanmakuController
    @State private var showSettings = false

    var body: some View {
        Menu {
            Toggle("弹幕显示", isOn: $controller.isEnabled)
            Divider()
            Text(statusText)
                .foregroundStyle(.secondary)
            Button {
                controller.refetch()
            } label: {
                Label("重新获取弹幕", systemImage: "arrow.clockwise")
            }
            .disabled(!controller.isEnabled || !controller.isConfigured)
            Divider()
            Button {
                showSettings = true
            } label: {
                Label("弹幕设置…", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: controller.isEnabled
                  ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .font(.title3)
                .foregroundStyle(controller.isEnabled ? NagomiTheme.accent : .white)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .nagomiHoverHighlight(Color.white.opacity(0.14), in: Circle())
        .help(controller.isEnabled ? "弹幕：开" : "弹幕：关")
        .sheet(isPresented: $showSettings) {
            DanmakuSettingsSheet(controller: controller)
        }
    }

    private var statusText: String {
        controller.statusDescription
    }
}

/// 弹幕服务信息面板：凭据已内置（弹弹play），用户无需也看不到任何配置内容。
/// （旧版曾提供 AppId/AppSecret/服务器地址输入框——凭据改为打包时内置后移除；
/// 高级用户可用 `defaults write` 覆盖，见 DanmakuEmbeddedCredentials 注释）
struct DanmakuSettingsSheet: View {
    @ObservedObject var controller: DanmakuController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("弹幕设置")
                .font(.headline)

            Label("弹幕服务已内置（弹弹play），无需配置", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(NagomiTheme.accent)

            Text("弹幕数据来自弹弹play 开放 API。应用已内置服务凭据并自动匹配剧集：在线番按剧名 + 集号匹配，本地番按文件指纹匹配，找不到匹配的集不显示弹幕（宁缺毋滥）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 6) {
                Text("当前状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.statusDescription)
                    .font(.caption.weight(.medium))
            }

            Text("弹幕以悬浮层渲染，与字幕同时显示互不影响；弹幕数据按剧集缓存在内存，同集切回不重复请求。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Button("好") { dismiss() }
                    .buttonStyle(NagomiPrimaryButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 440, height: 240)
    }
}

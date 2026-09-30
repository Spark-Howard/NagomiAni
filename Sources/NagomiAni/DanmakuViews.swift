import CoreText
import SwiftUI
import NagomiAniCore

/// 弹幕覆盖层：TimelineView + Canvas 逐帧渲染，绘制是 f(当前播放时间) 的纯函数——
/// 暂停冻结（时间停走）、拖动进度自动重排、seek 无需任何状态修正。
/// 车道分配在弹幕加载/画面尺寸变化时预计算一次（Core 纯函数，注入字体实测宽度）。
///
/// 性能关键（两处，缺一就会卡）：
/// 1. 弹幕文本**预渲染为位图精灵**（懒生成 + 缓存），逐帧只走 `context.cgContext`
///    的 `CGContext.draw(CGImage)` 纯 blit——旧实现每帧对每条可见弹幕做 Text 排版，
///    弹幕一多必掉帧；blit 成本与弹幕数量无关。勿改回逐帧 Text/resolve(NSImage) 绘制。
/// 2. 引擎 time-pos 事件约 30Hz，直接驱动 60fps 渲染会让滚动呈台阶状——用
///    `DanmakuTimeSync` 以最近一次引擎时间为锚点、墙钟补齐帧间增量（锚点每次
///    事件刷新，误差不超过一个事件间隔），滚动逐帧平滑。
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
    /// 两个缓存都是普通类实例（@State 持引用）：绘制期间写入不触发视图刷新
    @State private var spriteCache = DanmakuSpriteCache()
    @State private var timeSync = DanmakuTimeSync()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
                Canvas { context, size in
                    render(context: &context, size: size,
                           time: timeSync.smooth(currentTime(), now: timeline.date, playing: isPlaying))
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
        for item in trackItems {
            let elapsed = time - item.comment.time
            switch item.comment.mode {
            case .scroll:
                // 右缘从画面外滑入（与车道分配同一条位移公式）；左缘锚定
                guard elapsed >= 0, elapsed <= DanmakuLayout.travelDuration else { continue }
                let y = CGFloat(item.lane) * DanmakuLayout.laneHeight + DanmakuLayout.laneHeight / 2 + 4
                blit(&context, item,
                     x: (size.width + item.width) * (1 - elapsed / DanmakuLayout.travelDuration) - item.width / 2,
                     y: y)
            case .top:
                guard elapsed >= 0, elapsed <= DanmakuLayout.stackDuration else { continue }
                let y = CGFloat(item.lane) * DanmakuLayout.laneHeight + DanmakuLayout.laneHeight / 2 + 4
                blit(&context, item, x: size.width / 2 - item.width / 2, y: y)
            case .bottom:
                guard elapsed >= 0, elapsed <= DanmakuLayout.stackDuration else { continue }
                let y = size.height - CGFloat(item.lane + 1) * DanmakuLayout.laneHeight
                    + DanmakuLayout.laneHeight / 2 - 4
                blit(&context, item, x: size.width / 2 - item.width / 2, y: y)
            }
        }
    }

    /// 画一条弹幕：精灵懒生成（首次可见时渲染一次，此后每帧只 resolve + 贴图）。
    /// Sprite 的 Image 在精灵创建时已包好 NSImage，这里 resolve 只是轻量包装。
    private func blit(_ context: inout GraphicsContext, _ item: DanmakuTrackItem, x: CGFloat, y: CGFloat) {
        guard let sprite = spriteCache.sprite(text: item.comment.text, color: item.comment.color, scale: displayScale) else {
            return
        }
        context.draw(
            context.resolve(sprite.image),
            in: CGRect(x: x, y: y - sprite.height / 2, width: sprite.width, height: sprite.height)
        )
    }
}

/// 引擎时间 → 渲染时间插值：time-pos 属性事件约 30Hz，直接驱动 60fps 渲染会出现
/// 台阶感。以最近一次引擎时间为锚点，用墙钟补齐帧间增量；锚点随每次事件刷新，
/// 插值误差不会跨事件累积（≤ 一个事件间隔 × 倍速偏差，可忽略）。
/// 普通类（@State 持引用），绘制期间更新不触发视图刷新。
private final class DanmakuTimeSync {
    private var lastEngine: Double = -1
    private var lastWall: Date = .distantPast

    func smooth(_ engine: Double, now: Date, playing: Bool) -> Double {
        if engine != lastEngine {
            lastEngine = engine
            lastWall = now
        }
        guard playing else { return engine }
        return engine + now.timeIntervalSince(lastWall)
    }
}

/// 弹幕文本位图精灵缓存：NSAttributedString 经 CoreText 一次性渲染成 hi-dpi CGImage。
/// CoreText 原生按 y-up 正立绘制字形——**全程不做任何 CTM 翻转**（曾因
/// "手动翻转 CTM + AppKit 文字绘制"双重翻转导致弹幕上下颠倒，勿改回）。
/// 普通类（非 ObservableObject）——Canvas 绘制期间写入不触发视图刷新。
private final class DanmakuSpriteCache {
    struct Sprite {
        let image: Image // SwiftUI Image（NSImage 包装），绘制时 resolve
        let width: CGFloat // 逻辑 pt
        let height: CGFloat
    }

    /// key 用元组（颜色, 文本）：字符串插值 key 会给逐帧查找带来无谓分配
    private var sprites: [Key: Sprite] = [:]
    private var widths: [String: CGFloat] = [:]

    struct Key: Hashable {
        let color: UInt32
        let text: String
    }
    /// 上限兜底：超长集弹幕总量大，超出后整代清空（回滚 seek 时按需重渲染，毫秒级）
    private static let spriteLimit = 600
    private static let font = NSFont.systemFont(ofSize: 22, weight: .medium)

    func clear() {
        sprites.removeAll()
        widths.removeAll()
    }

    /// 真实文本宽度（CoreText 排版度量，按文本去重缓存）——车道分配与滚动位移都用它
    func measureWidth(text: String) -> CGFloat {
        if let cached = widths[text] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: Self.font,
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        widths[text] = width
        return width
    }

    func sprite(text: String, color: UInt32, scale: CGFloat) -> Sprite? {
        let key = Key(color: color, text: text)
        if let cached = sprites[key] { return cached }
        guard let made = makeSprite(text: text, color: color, scale: scale) else { return nil }
        if sprites.count >= Self.spriteLimit { sprites.removeAll() }
        sprites[key] = made
        return made
    }

    private func makeSprite(text: String, color: UInt32, scale: CGFloat) -> Sprite? {
        let line = NSAttributedString(string: text, attributes: [
            .font: Self.font,
        ])
        let ctLine = CTLineCreateWithAttributedString(line)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        let boundsHeight = ascent + descent
        guard textWidth > 0, boundsHeight > 0 else { return nil }
        let pixelWidth = max(1, Int(ceil(textWidth * scale)))
        let pixelHeight = max(1, Int(ceil(boundsHeight * scale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)) // 1:1，缩放自己控制
        NSGraphicsContext.saveGraphicsState()
        guard let bitmapCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = bitmapCtx
        let cg = bitmapCtx.cgContext
        // 保持 CG 原生 y-up（CoreText 在此约定下字形天然正立，无翻转歧义），
        // 仅把像素坐标缩放回逻辑 pt；baseline 抬高 descent 防下伸部（g/y/p）被裁
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(NSColor(
            red: CGFloat((color >> 16) & 0xFF) / 255,
            green: CGFloat((color >> 8) & 0xFF) / 255,
            blue: CGFloat(color & 0xFF) / 255,
            alpha: 1
        ).cgColor)
        cg.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(ctLine, cg)
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = rep.cgImage else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: textWidth, height: boundsHeight))
        return Sprite(image: Image(nsImage: nsImage), width: textWidth, height: boundsHeight)
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

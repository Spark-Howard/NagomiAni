import CoreText
import SwiftUI
import NagomiAniCore

/// 弹幕覆盖层：**Core Animation 图层渲染**（第三轮重构）。
///
/// 帧率问题的演进：
/// ① 原版 Canvas 逐帧 Text 排版——字体度量/布局是每帧大头，掉帧；
/// ② 位图精灵 + Canvas——Canvas 是 CPU 光栅化，每帧重画整块视频区域位图，仍卡；
/// ③ 现在：每条弹幕一个预渲染 CALayer，`CADisplayLink` 每帧只更新位置（赋值坐标），
///    合成全部在 GPU——帧率 = 屏幕刷新率（60/120Hz），CPU 每帧开销趋近于零。
/// 暂停冻结 = displayLink 暂停；拖动/seek = 时间锚点重置后下一帧重排（语义与纯函数一致）。
/// 不参与命中测试：控制条/顶栏在其上层正常交互。
struct DanmakuOverlayView: View {
    @ObservedObject var controller: DanmakuController
    /// 每帧读取的当前播放时间（引擎 time-pos，事件级更新）
    let currentTime: () -> Double
    /// 是否正在播放（暂停时冻结弹幕）
    let isPlaying: Bool

    var body: some View {
        // TimelineView 仅作 vsync 对齐的逐帧驱动器（每 tick 极轻）：
        // 图层位置更新在 updateNSView → host.step()，合成在 GPU
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { _ in
            DanmakuLayerRepresentable(controller: controller, currentTime: currentTime, isPlaying: isPlaying)
                .allowsHitTesting(false)
        }
    }
}

private struct DanmakuLayerRepresentable: NSViewRepresentable {
    @ObservedObject var controller: DanmakuController
    let currentTime: () -> Double
    let isPlaying: Bool

    func makeNSView(context: Context) -> DanmakuHostView {
        let host = DanmakuHostView()
        host.wantsLayer = true
        host.syncFrom(controller: controller, currentTime: currentTime, isPlaying: isPlaying)
        host.step()
        return host
    }

    func updateNSView(_ host: DanmakuHostView, context: Context) {
        host.syncFrom(controller: controller, currentTime: currentTime, isPlaying: isPlaying)
        host.step() // TimelineView 每 tick 驱动一次图层位置更新
    }
}

/// 引擎时间 → 渲染时间插值：time-pos 属性事件约 30Hz，直接驱动逐帧渲染会出现
/// 台阶感。以最近一次引擎时间为锚点，用墙钟补齐帧间增量；锚点随每次事件刷新，
/// 插值误差不会跨事件累积（≤ 一个事件间隔 × 倍速偏差，可忽略）。
@MainActor
private final class DanmakuTimeSync {
    private var lastEngine: Double = -1
    private var lastWall = Date.distantPast

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
/// CoreText 原生按 y-up 正立绘制字形——**全程不做任何 CTM 翻转**（第一版曾因
/// "手动翻转 CTM + AppKit 文字绘制"双重翻转导致弹幕上下颠倒，勿改回）。
@MainActor
private final class DanmakuSpriteCache {
    struct Sprite {
        let image: CGImage
        let width: CGFloat // 逻辑 pt
        let height: CGFloat
    }

    struct Key: Hashable {
        let color: UInt32
        let text: String
    }

    private var sprites: [Key: Sprite] = [:]
    private var widths: [String: CGFloat] = [:]
    /// 上限兜底：超长集弹幕总量大，超出后整代清空（回滚 seek 时按需重渲染，毫秒级）
    private static let spriteLimit = 600

    func clear() {
        sprites.removeAll()
        widths.removeAll()
    }

    /// 真实文本宽度（CoreText 排版度量，按文本+字号去重缓存）——车道分配与滚动位移都用它
    func measureWidth(text: String, fontSize: CGFloat) -> CGFloat {
        let cacheKey = "\(Int(fontSize))|\(text)"
        if let cached = widths[cacheKey] { return cached }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        widths[cacheKey] = width
        return width
    }

    func sprite(text: String, color: UInt32, fontSize: CGFloat, scale: CGFloat) -> Sprite {
        let key = Key(color: color, text: text)
        if let cached = sprites[key] { return cached }
        let made = makeSprite(text: text, color: color, fontSize: fontSize, scale: scale)
        if sprites.count >= Self.spriteLimit { sprites.removeAll() }
        sprites[key] = made
        return made
    }

    private func makeSprite(text: String, color: UInt32, fontSize: CGFloat, scale: CGFloat) -> Sprite {
        let line = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
        ])
        let ctLine = CTLineCreateWithAttributedString(line)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        let boundsHeight = ascent + descent
        let pixelWidth = max(1, Int(ceil(textWidth * scale)))
        let pixelHeight = max(1, Int(ceil(boundsHeight * scale)))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)) // 1:1，缩放自己控制
        NSGraphicsContext.saveGraphicsState()
        let bitmapCtx = NSGraphicsContext(bitmapImageRep: rep)!
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
        return Sprite(image: rep.cgImage!, width: textWidth, height: boundsHeight)
    }
}

/// 弹幕宿主视图：CALayer 池 + CADisplayLink 逐帧位置更新。
@MainActor
final class DanmakuHostView: NSView {
    // 由 Representable 每次刷新同步（内部显式 diff，值变化才触发重建）
    private var comments: [DanmakuComment] = []
    private var fontSize: CGFloat = 22
    private var colorMode: DanmakuController.DanmakuColorMode = .original
    private var customColor: UInt32 = 0xFFFFFF
    private var opacity: Float = 1
    private var isPlaying = false
    var timeProvider: (() -> Double)?

    private var items: [DanmakuTrackItem] = []
    private var spriteCache = DanmakuSpriteCache()
    private var timeSync = DanmakuTimeSync()
    /// index → 弹幕图层（懒创建；离开显示窗口回收入池复用）
    private var activeLayers: [Int: CALayer] = [:]
    private var freeLayers: [CALayer] = []
    private var lastScale: CGFloat = 0

    private var laneHeight: CGFloat { fontSize + 12 }

    override var isFlipped: Bool { true } // 顶部原点 y 向下，与车道公式一致
    // wantsLayer 由 Representable 的 makeNSView 设置

    /// 从控制器同步（Representable 每次刷新调用；显式 diff，值不变零开销）
    func syncFrom(controller: DanmakuController, currentTime: @escaping () -> Double, isPlaying playing: Bool) {
        timeProvider = currentTime
        var needsRebuild = false
        if comments != controller.comments {
            comments = controller.comments
            needsRebuild = true
        }
        if fontSize != controller.fontSize {
            fontSize = controller.fontSize
            needsRebuild = true
        }
        if colorMode != controller.colorMode || customColor != controller.customColor {
            colorMode = controller.colorMode
            customColor = controller.customColor
            spriteCache.clear() // 颜色口径变了：精灵全部重渲染
            clearLayers()
            needsRebuild = true
        }
        let newOpacity = Float(controller.opacity)
        if opacity != newOpacity {
            opacity = newOpacity
            for layer in activeLayers.values { layer.opacity = newOpacity }
        }
        if isPlaying != playing { isPlaying = playing }
        if needsRebuild { rebuild() }
    }

    override func layout() {
        super.layout()
        rebuild() // 尺寸/跨屏变化：车道与图层重建
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0, !comments.isEmpty else {
            items = []
            clearLayers()
            return
        }
        spriteCache.clear() // 字号变了：精灵全部重渲染
        clearLayers()
        laneCountSetup()
        items = DanmakuLayout.assignLanes(
            comments: comments,
            laneCount: laneCount,
            screenWidth: bounds.width,
            fontSize: fontSize,
            measure: { [self] text in spriteCache.measureWidth(text: text, fontSize: fontSize) }
        )
    }

    private var laneCount = 8
    private func laneCountSetup() {
        laneCount = max(1, Int(bounds.height * DanmakuLayout.scrollAreaRatio / laneHeight))
    }

    private func clearLayers() {
        for layer in activeLayers.values { layer.removeFromSuperlayer() }
        activeLayers.removeAll()
        for layer in freeLayers { layer.removeFromSuperlayer() }
        freeLayers.removeAll()
    }

    /// 每帧（TimelineView tick 驱动）：更新可见图层位置；离窗图层回收入池（合成在 GPU）
    func step() {
        guard window != nil, !items.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        if scale != lastScale {
            lastScale = scale
            spriteCache.clear() // 跨屏清晰度变了
            clearLayers()
        }
        let t = timeSync.smooth(timeProvider?() ?? 0, now: Date(), playing: isPlaying)
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 逐帧位置赋值禁用隐式动画（否则拖影）
        for (index, item) in items.enumerated() {
            let elapsed = t - item.comment.time
            let duration: Double
            switch item.comment.mode {
            case .scroll: duration = DanmakuLayout.travelDuration
            case .top, .bottom: duration = DanmakuLayout.stackDuration
            }
            let inWindow = elapsed >= 0 && elapsed <= duration
            if inWindow, activeLayers[index] == nil, freeLayers.isEmpty, activeLayers.count >= 400 {
                continue // 图层池超限：放弃最不重要的新弹幕（极端弹幕洪流兜底）
            }
            if let layer = activeLayers[index] {
                if inWindow {
                    layer.frame = displayFrame(item: item, at: elapsed, in: bounds)
                    layer.isHidden = false
                } else {
                    recycle(index: index, layer: layer)
                }
            } else if inWindow {
                let layer = acquireLayer(index: index, item: item, scale: scale)
                layer.frame = displayFrame(item: item, at: elapsed, in: bounds)
            }
        }
        CATransaction.commit()
    }

    private func recycle(index: Int, layer: CALayer) {
        layer.isHidden = true
        activeLayers.removeValue(forKey: index)
        freeLayers.append(layer)
    }

    private func acquireLayer(index: Int, item: DanmakuTrackItem, scale: CGFloat) -> CALayer {
        let sprite = spriteCache.sprite(
            text: item.comment.text,
            color: effectiveColor(item.comment.color),
            fontSize: fontSize,
            scale: scale
        )
        let layer: CALayer
        if let reused = freeLayers.popLast() {
            layer = reused
        } else {
            layer = CALayer()
            self.layer?.addSublayer(layer)
        }
        layer.contents = sprite.image
        layer.bounds = CGRect(origin: .zero, size: CGSize(width: sprite.width, height: sprite.height))
        layer.contentsGravity = .resize
        layer.opacity = opacity
        layer.isHidden = false
        activeLayers[index] = layer
        return layer
    }

    /// 显示窗口内的 frame（flipped 坐标，与车道公式一致）
    private func displayFrame(item: DanmakuTrackItem, at elapsed: Double, in bounds: CGRect) -> CGRect {
        let y: CGFloat
        let x: CGFloat
        switch item.comment.mode {
        case .scroll:
            y = CGFloat(item.lane) * laneHeight + laneHeight / 2 + 4
            x = (bounds.width + item.width) * (1 - elapsed / DanmakuLayout.travelDuration) - item.width / 2
        case .top:
            y = CGFloat(item.lane) * laneHeight + laneHeight / 2 + 4
            x = bounds.width / 2 - item.width / 2
        case .bottom:
            y = bounds.height - CGFloat(item.lane + 1) * laneHeight + laneHeight / 2 - 4
            x = bounds.width / 2 - item.width / 2
        }
        let sprite = spriteCache.sprite(
            text: item.comment.text,
            color: effectiveColor(item.comment.color),
            fontSize: fontSize,
            scale: window?.backingScaleFactor ?? 2
        )
        return CGRect(x: x, y: y - sprite.height / 2, width: sprite.width, height: sprite.height)
    }

    private func effectiveColor(_ original: UInt32) -> UInt32 {
        switch colorMode {
        case .original: return original
        case .white: return 0xFFFFFF
        case .custom: return customColor
        }
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

/// 弹幕设置面板：显示设置（字号/颜色/不透明度，即时生效）+ 服务状态。
/// 凭据已内置（弹弹play），用户无需也看不到任何凭据内容——旧版的
/// AppId/AppSecret/服务器地址输入框已随凭据内置化移除（高级用户可用
/// `defaults write` 覆盖，见 DanmakuEmbeddedCredentials 注释）。
struct DanmakuSettingsSheet: View {
    @ObservedObject var controller: DanmakuController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("弹幕设置")
                .font(.headline)

            // MARK: 显示设置

            HStack(spacing: 10) {
                Text("字号").frame(width: 52, alignment: .leading)
                Slider(value: $controller.fontSize, in: 16...32, step: 2)
                Text("\(Int(controller.fontSize)) pt")
                    .font(.callout.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text("颜色").frame(width: 52, alignment: .leading)
                Picker("颜色", selection: $controller.colorMode) {
                    ForEach(DanmakuController.DanmakuColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                if controller.colorMode == .custom {
                    ColorPicker("", selection: customColorBinding)
                        .labelsHidden()
                        .fixedSize()
                }
            }

            HStack(spacing: 10) {
                Text("不透明度").frame(width: 52, alignment: .leading)
                Slider(value: $controller.opacity, in: 0.3...1.0)
                Text("\(Int(controller.opacity * 100))%")
                    .font(.callout.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
            }

            Divider()

            // MARK: 服务状态

            Label("弹幕服务已内置（弹弹play），无需配置", systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(NagomiTheme.accent)

            HStack(spacing: 6) {
                Text("当前状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.statusDescription)
                    .font(.caption.weight(.medium))
            }

            Text("在线番按剧名 + 集号自动匹配，本地番按文件指纹匹配，找不到匹配的集不显示弹幕（宁缺毋滥）。弹幕以悬浮层渲染，与字幕同时显示互不影响。")
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
        .frame(width: 440, height: 340)
    }

    /// UInt32 (0xRRGGBB) ↔ SwiftUI Color
    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                let c = controller.customColor
                return Color(
                    red: Double((c >> 16) & 0xFF) / 255,
                    green: Double((c >> 8) & 0xFF) / 255,
                    blue: Double(c & 0xFF) / 255
                )
            },
            set: { color in
                #if canImport(AppKit)
                let ns = NSColor(color).usingColorSpace(.sRGB)
                let r = UInt32(round((ns?.redComponent ?? 0) * 255))
                let g = UInt32(round((ns?.greenComponent ?? 0) * 255))
                let b = UInt32(round((ns?.blueComponent ?? 0) * 255))
                #else
                let r = UInt32(round(color.components.r * 255))
                let g = UInt32(round(color.components.g * 255))
                let b = UInt32(round(color.components.b * 255))
                #endif
                controller.customColor = (r << 16) | (g << 8) | b
            }
        )
    }
}

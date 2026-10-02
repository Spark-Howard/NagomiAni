import CoreText
import SwiftUI
import NagomiAniCore

/// 弹幕覆盖层：常驻逐帧驱动 + 图层直接赋值（第五轮，终局）。
///
/// 历史教训（勿走回头路）：
/// ① Canvas 逐帧 Text 排版——CPU 光栅化，掉帧；
/// ② 位图精灵 + Canvas——光栅化依旧，卡；
/// ③ CALayer + TimelineView tick——SwiftUI 调度抖动，tick 忽快忽慢，卡；
/// ④ CAAnimation 原生动画——模型值/呈现值分离 + speed + beginTime 的组合陷阱：
///    暂停时弹幕消失、进入视频不显示、seek 误判每秒重摆（视频 1fps）。
/// ⑤ 现在：DispatchSourceTimer（主队列 60Hz，独立于 SwiftUI 调度）每帧把可见弹幕
///    的 layer.frame **直接赋值**——没有动画对象、没有 model/呈现二义性：
///    暂停 = 位置不再变化（必然冻结、绝不消失）；seek/拖动 = 下一帧直接重排；
///    引擎时间插值（time-pos ~1Hz → 墙钟补齐）保证滚动逐帧平滑。
/// CPU 每帧 = 可见弹幕数 × 一次坐标赋值（微不足道），合成在 GPU。
/// 不参与命中测试：控制条/顶栏在其上层正常交互。
struct DanmakuOverlayView: View {
    @ObservedObject var controller: DanmakuController
    /// 引擎当前播放时间（每帧读取，插值锚点）
    let currentTime: () -> Double
    /// 是否正在播放（暂停 = 时间停走，画面冻结）
    let isPlaying: Bool

    var body: some View {
        DanmakuLayerRepresentable(controller: controller, currentTime: currentTime, isPlaying: isPlaying)
            .allowsHitTesting(false)
    }
}

private struct DanmakuLayerRepresentable: NSViewRepresentable {
    @ObservedObject var controller: DanmakuController
    let currentTime: () -> Double
    let isPlaying: Bool

    func makeNSView(context: Context) -> DanmakuHostView {
        let host = DanmakuHostView()
        host.wantsLayer = true
        // 子图层默认不裁剪（弹幕起点在画面外会被画到视频区域外）——必须显式裁剪
        host.layer?.masksToBounds = true
        host.syncFrom(controller: controller, isPlaying: isPlaying)
        host.startAnimating()
        return host
    }

    func updateNSView(_ host: DanmakuHostView, context: Context) {
        host.syncFrom(controller: controller, isPlaying: isPlaying)
    }

    static func dismantleNSView(_ host: DanmakuHostView, coordinator: ()) {
        host.stopAnimating()
    }
}

/// 引擎时间 → 渲染时间插值：time-pos 事件频率低且不稳（~1Hz 实测），
/// 直接驱动会出现台阶感——以最近一次引擎时间为锚点、墙钟补齐帧间增量；
/// 锚点随每次事件刷新，误差不跨事件累积（≤ 一个事件间隔，可忽略）。
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
        // ⚠️ 颜色必须用 kCTForegroundColorAttributeName（CGColor）：
        // 走 NSFont 桥接绘制时 CGContext.setFillColor 会被忽略（AppKit 默认黑），
        // 曾导致所有弹幕黑字、任何颜色设置都不生效（离线脚本已验证像素级正确）
        let cgColor = NSColor(
            red: CGFloat((color >> 16) & 0xFF) / 255,
            green: CGFloat((color >> 8) & 0xFF) / 255,
            blue: CGFloat(color & 0xFF) / 255,
            alpha: 1
        ).cgColor
        let line = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor,
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
        cg.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(ctLine, cg)
        NSGraphicsContext.restoreGraphicsState()
        return Sprite(image: rep.cgImage!, width: textWidth, height: boundsHeight)
    }
}

/// 弹幕宿主视图：CALayer 池 + 常驻定时器逐帧赋值（无动画对象，状态唯一）。
@MainActor
final class DanmakuHostView: NSView {
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
    private var timer: DispatchSourceTimer?
    /// index → 弹幕图层（懒创建；离开显示窗口回收入池复用）
    private var activeLayers: [Int: CALayer] = [:]
    private var freeLayers: [CALayer] = []
    private var lastScale: CGFloat = 0
    private var lastRenderedTime: Double = -1

    private var laneHeight: CGFloat { fontSize + 12 }

    override var isFlipped: Bool { true } // 顶部原点 y 向下，与车道公式一致

    /// 从控制器同步（Representable 每次刷新调用；显式 diff，值不变零开销）
    func syncFrom(controller: DanmakuController, isPlaying playing: Bool) {
        var needsRebuild = false
        if comments != controller.comments {
            comments = controller.comments
            needsRebuild = true
        }
        if fontSize != controller.fontSize {
            fontSize = controller.fontSize
            spriteCache.clear() // 精灵 key 不含字号：不清则旧字号位图被复用（大小不变）
            needsRebuild = true
        }
        if colorMode != controller.colorMode || customColor != controller.customColor {
            colorMode = controller.colorMode
            customColor = controller.customColor
            spriteCache.clear() // 颜色口径变了：精灵全部重渲染
            needsRebuild = true
        }
        let newOpacity = Float(controller.opacity)
        if opacity != newOpacity {
            opacity = newOpacity
            for layer in activeLayers.values { layer.opacity = newOpacity }
        }
        isPlaying = playing
        if needsRebuild {
            rebuild()
            step(force: true) // 设置/内容变化立即呈现（暂停时也生效，不等下一 tick）
        }
    }

    func startAnimating() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.step() }
        source.resume()
        timer = source
    }

    func stopAnimating() {
        timer?.cancel()
        timer = nil
    }

    private var lastLayoutSize: CGSize = .zero

    override func layout() {
        super.layout()
        // 只在尺寸真变时重摆：AppKit 会因非尺寸原因触发 layout pass，
        // 暂停期间无谓的 clearLayers+懒重建会造成弹幕闪烁/消失
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            rebuild()
            step(force: true)
        }
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0, !comments.isEmpty else {
            items = []
            clearLayers()
            return
        }
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

    /// 每帧：把可见弹幕的 layer.frame 直接赋值（无动画对象 → 状态唯一、永不二义）。
    /// 暂停时引擎时间停走 → 位置恒定 = 画面冻结（绝不消失）；
    /// seek/拖动 = 引擎时间跳变 → 下一帧直接重排。
    func step(force: Bool = false) {
        guard window != nil, !items.isEmpty else { return }
        let engineTime = timeProvider?() ?? 0
        // 暂停且进度未变：完全冻结——不触碰任何图层（暂停期间的 layout pass /
        // SwiftUI 刷新都不应改变弹幕画面）
        if !force, !isPlaying, engineTime == lastRenderedTime { return }
        let scale = window?.backingScaleFactor ?? 2
        if scale != lastScale {
            lastScale = scale
            spriteCache.clear() // 跨屏清晰度变了：精灵重渲染
            clearLayers()
        }
        let t = timeSync.smooth(engineTime, now: Date(), playing: isPlaying)
        CATransaction.begin()
        CATransaction.setDisableActions(true) // 位置赋值禁用隐式动画（否则拖影）
        lastRenderedTime = t
        for (index, item) in items.enumerated() {
            let elapsed = t - item.comment.time
            let duration: Double
            switch item.comment.mode {
            case .scroll: duration = DanmakuLayout.travelDuration
            case .top, .bottom: duration = DanmakuLayout.stackDuration
            }
            let inWindow = elapsed >= 0 && elapsed <= duration
            if let layer = activeLayers[index] {
                if inWindow {
                    layer.frame = displayFrame(item: item, at: elapsed, in: bounds)
                    layer.isHidden = false
                } else {
                    recycle(index: index, layer: layer)
                }
            } else if inWindow {
                if freeLayers.isEmpty, activeLayers.count >= 400 {
                    continue // 图层池超限：放弃新弹幕（极端弹幕洪流兜底）
                }
                let layer = acquireLayer(index: index, item: item, scale: scale)
                layer.opacity = opacity
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

/// 弹幕控制按钮 + 自绘设置弹层（Nagomi 风格，不用原生 NSMenu——与全应用视觉统一）。
/// 字号/颜色/不透明度以胶囊分段直接平铺，点选即生效（无需二级悬浮）。
/// 凭据已内置（弹弹play），无凭据输入项（见 DanmakuEmbeddedCredentials）。
struct DanmakuMenu: View {
    @ObservedObject var controller: DanmakuController
    @State private var showPanel = false

    var body: some View {
        Button {
            showPanel.toggle()
        } label: {
            Image(systemName: controller.isEnabled
                  ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .font(.title3)
                .foregroundStyle(controller.isEnabled ? NagomiTheme.accent : .white)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .nagomiHoverHighlight(Color.white.opacity(0.14), in: Circle())
        .help(controller.isEnabled ? "弹幕：开" : "弹幕：关")
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            DanmakuSettingsPanel(controller: controller)
        }
    }
}

/// 樱粉分段选择器：胶囊按钮组（选中 = accentSoft 底 + accent 字），不改布局尺寸
struct NagomiSegmented<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? NagomiTheme.accent : .primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            selected ? NagomiTheme.accentSoft : NagomiTheme.cardBackground,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 弹幕设置弹层（自绘）：显示开关 / 字号 / 颜色 / 不透明度 / 状态 / 重新获取。
/// 凭据已内置（弹弹play），无凭据输入项（见 DanmakuEmbeddedCredentials 注释）。
struct DanmakuSettingsPanel: View {
    @ObservedObject var controller: DanmakuController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("弹幕设置")
                    .font(.headline)
                Spacer()
                Toggle("显示", isOn: $controller.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Divider()

            settingRow("字号") {
                NagomiSegmented(
                    options: [CGFloat(18), CGFloat(22), CGFloat(28)],
                    label: { $0 == 18 ? "小" : $0 == 22 ? "标准" : "大" },
                    selection: $controller.fontSize
                )
            }

            settingRow("颜色") {
                VStack(alignment: .leading, spacing: 6) {
                    NagomiSegmented(
                        options: DanmakuController.DanmakuColorMode.allCases,
                        label: { mode in
                            switch mode {
                            case .original: return "跟随弹幕"
                            case .white: return "纯白"
                            case .custom: return "自定义"
                            }
                        },
                        selection: $controller.colorMode
                    )
                    // 自定义色板（弹层内点选即生效）：不用系统取色器——
                    // NSColorPanel 是独立窗口，点它会关闭 popover，选色被打断
                    if controller.colorMode == .custom {
                        HStack(spacing: 8) {
                            ForEach(Self.palette, id: \.self) { c in
                                let selected = controller.customColor == c
                                Button {
                                    controller.customColor = c
                                } label: {
                                    Circle()
                                        .fill(Color(
                                            red: Double((c >> 16) & 0xFF) / 255,
                                            green: Double((c >> 8) & 0xFF) / 255,
                                            blue: Double(c & 0xFF) / 255
                                        ))
                                        .frame(width: 20, height: 20)
                                        .overlay(
                                            Circle().strokeBorder(
                                                selected ? NagomiTheme.accent : Color.white.opacity(0.35),
                                                lineWidth: selected ? 2 : 1
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                                .help("使用该颜色")
                            }
                        }
                    }
                }
            }

            settingRow("不透明度") {
                NagomiSegmented(
                    options: [Double(0.3), Double(0.6), Double(1.0)],
                    label: { "\(Int($0 * 100))%" },
                    selection: $controller.opacity
                )
            }

            Divider()

            HStack(spacing: 6) {
                Text("状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(controller.statusDescription)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Button("重新获取") { controller.refetch() }
                    .buttonStyle(NagomiSecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(!controller.isEnabled || !controller.isConfigured)
            }

            Text("弹幕来自弹弹play（服务已内置）。在线番按剧名+集号、本地番按文件指纹自动匹配，找不到不显示（宁缺毋滥）；与字幕同时显示互不影响。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
        .background(NagomiTheme.pageBackground)
    }

    /// 自定义色板（弹层内点选，无外部窗口）
    static let palette: [UInt32] = [
        0xFFFFFF, 0xEC6A88, 0xFF4D4D, 0xFFA640, 0xFFE14D,
        0x6EE77A, 0x4DD8E7, 0x5B8CFF, 0xB56CFF, 0x2A2A2A,
    ]

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

}

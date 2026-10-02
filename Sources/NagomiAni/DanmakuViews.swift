import CoreText
import SwiftUI
import NagomiAniCore

/// 弹幕覆盖层：**Core Animation 原生动画驱动**（第四轮，终局方案）。
///
/// 帧率问题演进：
/// ① Canvas 逐帧 Text 排版（字体度量掉帧）→ ② 位图精灵 + Canvas（Canvas 是 CPU
/// 光栅化，每帧重画整块区域位图，仍卡）→ ③ CALayer + TimelineView tick 逐帧赋值
/// （SwiftUI 调度抖动使 tick 不稳，仍卡）→ ④ 现在：每条弹幕 layer 挂 `CABasicAnimation`，
/// **插值与合成全部由 Core Animation 在 GPU 完成，CPU 逐帧开销为零**，无任何 tick 驱动。
///
/// 关键机制：
/// - 可见性 = "model 位置在画面外 + `masksToBounds` 裁剪"天然保证（动画未开始/已结束
///   时 layer 回到 model 值即画面外），opacity 动画负责出现/隐没；
/// - 暂停/恢复/倍速 = 宿主 `layer.speed`（0 = 全部动画冻结，含未来动画的 beginTime）；
/// - seek = 引擎时间跳变检测 → 全量重摆（用 layer 本地时钟算未来动画 beginTime，
///   暂停期间 seek 也不迟到）；
/// - 滚动弹幕匀速（linear timing），与同步阈值/连播窗口无耦合。
/// 不参与命中测试：控制条/顶栏在其上层正常交互。
struct DanmakuOverlayView: View {
    @ObservedObject var controller: DanmakuController
    /// 引擎当前播放时间（诊断用；弹幕动画由 Core Animation 自驱，不依赖它逐帧更新）
    let currentTime: () -> Double
    /// 是否正在播放（暂停 = 冻结全部动画）
    let isPlaying: Bool
    /// seek 重摆信号（用户拖进度/换集时递增）
    let seekRevision: Int

    var body: some View {
        DanmakuLayerRepresentable(
            controller: controller, currentTime: currentTime,
            isPlaying: isPlaying, seekRevision: seekRevision
        )
        .allowsHitTesting(false)
    }
}

private struct DanmakuLayerRepresentable: NSViewRepresentable {
    @ObservedObject var controller: DanmakuController
    let currentTime: () -> Double
    let isPlaying: Bool
    let seekRevision: Int

    func makeNSView(context: Context) -> DanmakuHostView {
        let host = DanmakuHostView()
        host.wantsLayer = true
        // 子图层默认不裁剪（弹幕起点在画面外会被画到视频区域外）——必须显式裁剪
        host.layer?.masksToBounds = true
        host.syncFrom(controller: controller, seekRevision: seekRevision, isPlaying: isPlaying)
        return host
    }

    func updateNSView(_ host: DanmakuHostView, context: Context) {
        host.syncFrom(controller: controller, seekRevision: seekRevision, isPlaying: isPlaying)
    }
}

/// 弹幕宿主视图：CALayer 池 + Core Animation 原生动画（无逐帧 CPU 工作）。
@MainActor
final class DanmakuHostView: NSView {
    private var comments: [DanmakuComment] = []
    private var fontSize: CGFloat = 22
    private var colorMode: DanmakuController.DanmakuColorMode = .original
    private var customColor: UInt32 = 0xFFFFFF
    private var opacity: Float = 1
    private var isPlaying = false
    private var seekRevision = 0
    var timeProvider: (() -> Double)?

    private var items: [DanmakuTrackItem] = []
    private var spriteCache = DanmakuSpriteCache()
    /// index → 弹幕图层（全量预布置；已滚出的 isHidden 闲置，seek 重摆复用）
    private var layers: [Int: CALayer] = [:]
    private var lastScale: CGFloat = 0

    private var laneHeight: CGFloat { fontSize + 12 }

    override var isFlipped: Bool { true } // 顶部原点 y 向下，与车道公式一致

    /// 从控制器同步（Representable 每次刷新调用；显式 diff，值不变零开销）
    func syncFrom(controller: DanmakuController, seekRevision newSeekRevision: Int,
                  isPlaying playing: Bool) {
        var needsRelayout = false
        if comments != controller.comments {
            comments = controller.comments
            needsRelayout = true
        }
        if fontSize != controller.fontSize {
            fontSize = controller.fontSize
            needsRelayout = true
        }
        if colorMode != controller.colorMode || customColor != controller.customColor {
            colorMode = controller.colorMode
            customColor = controller.customColor
            spriteCache.clear() // 颜色口径变了：精灵全部重渲染
            needsRelayout = true
        }
        let playingChanged = isPlaying != playing
        isPlaying = playing
        // seek 重摆：显式信号（PlayerModel.seek/load → markSeeked），
        // 与引擎 time-pos 事件频率彻底解耦（低频事件曾致每秒误触发全量重摆）
        if seekRevision != newSeekRevision {
            seekRevision = newSeekRevision
            needsRelayout = true
        }
        // 暂停/恢复：只切 layer.speed（动画时间线冻结/恢复，呈现连续不跳）
        if playingChanged || needsRelayout {
            applySpeedAndLayout(needsRelayout: needsRelayout)
        }
    }

    private var timeSync = DanmakuTimeSync()

    /// host layer speed：0 = 冻结全部动画（暂停），1 = 正常播放
    private func applySpeedAndLayout(needsRelayout: Bool) {
        guard let container = layer else { return }
        container.speed = isPlaying ? 1 : 0
        if needsRelayout { relayout() }
    }

    override func layout() {
        super.layout()
        relayout() // 尺寸/跨屏变化：重摆
    }

    /// 全量布置：为每条弹幕 layer 设 model 状态（画面外起点 + 透明）+ CA 动画。
    /// 之后的一切（滑入/滚出/隐没/到点出现）由 Core Animation 合成器驱动。
    private func relayout() {
        guard window != nil, bounds.width > 0, bounds.height > 0, !comments.isEmpty else {
            items = []
            for layer in layers.values { layer.isHidden = true }
            layers.removeAll()
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        if scale != lastScale {
            lastScale = scale
            spriteCache.clear() // 跨屏清晰度变了：精灵重渲染
        }
        laneCountSetup()
        items = DanmakuLayout.assignLanes(
            comments: comments,
            laneCount: laneCount,
            screenWidth: bounds.width,
            fontSize: fontSize,
            measure: { [self] text in spriteCache.measureWidth(text: text, fontSize: fontSize) }
        )

        guard let container = layer else { return }
        container.speed = isPlaying ? 1 : 0
        // layer 本地时间（已计入 speed/paused）：暂停时冻结，恢复后动画按相对时刻起跑
        let localNow = container.convertTime(CACurrentMediaTime(), from: nil)
        let engineNow = timeProvider?() ?? 0

        for (index, item) in items.enumerated() {
            let layer = acquireLayer(index: index, item: item, scale: scale)
            let elapsed = engineNow - item.comment.time
            let duration: Double
            switch item.comment.mode {
            case .scroll: duration = DanmakuLayout.travelDuration
            case .top, .bottom: duration = DanmakuLayout.stackDuration
            }
            layer.removeAnimation(forKey: "danmaku.pos")
            layer.removeAnimation(forKey: "danmaku.opacity")

            // 已滚出：隐藏闲置（seek 回看时重摆复活）
            if elapsed >= duration {
                layer.isHidden = true
                layer.opacity = 0
                continue
            }
            layer.isHidden = false

            let laneY: CGFloat
            switch item.comment.mode {
            case .scroll, .top:
                laneY = CGFloat(item.lane) * laneHeight + laneHeight / 2 + 4
            case .bottom:
                laneY = bounds.height - CGFloat(item.lane + 1) * laneHeight + laneHeight / 2 - 4
            }

            // 出现/滚动/隐没的时间线（layer 本地时钟；暂停时冻结，恢复不迟到）
            let beginTime = localNow + max(0, -elapsed)
            let animDuration = duration

            let opacityAnim = CABasicAnimation(keyPath: "opacity")
            opacityAnim.fromValue = Float(1)
            opacityAnim.toValue = Float(1)
            opacityAnim.beginTime = beginTime
            opacityAnim.duration = animDuration
            opacityAnim.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(opacityAnim, forKey: "danmaku.opacity")

            switch item.comment.mode {
            case .scroll:
                // model 位置 = 入场起点（画面右外，被 masksToBounds 裁掉 → 未出现时不可见）
                let startX = bounds.width + item.width / 2
                let endX = -item.width / 2
                layer.position = CGPoint(x: startX, y: laneY)
                let posAnim = CABasicAnimation(keyPath: "position.x")
                // from = 当前时刻应在的位置（seek 重摆时 elapsed > 0，起点前推）
                posAnim.fromValue = Float(startX - elapsed / DanmakuLayout.travelDuration * (bounds.width + item.width))
                posAnim.toValue = Float(endX)
                posAnim.beginTime = beginTime
                posAnim.duration = animDuration
                posAnim.timingFunction = CAMediaTimingFunction(name: .linear)
                layer.add(posAnim, forKey: "danmaku.pos")
            case .top, .bottom:
                layer.position = CGPoint(x: bounds.width / 2, y: laneY)
            }
        }
    }

    private var laneCount = 8
    private func laneCountSetup() {
        laneCount = max(1, Int(bounds.height * DanmakuLayout.scrollAreaRatio / laneHeight))
    }

    /// 取（或复用）弹幕图层；model 状态置为入场起点 + 透明（未开始/结束后都被裁剪不可见）
    private func acquireLayer(index: Int, item: DanmakuTrackItem, scale: CGFloat) -> CALayer {
        let sprite = spriteCache.sprite(
            text: item.comment.text,
            color: effectiveColor(item.comment.color),
            fontSize: fontSize,
            scale: scale
        )
        let layer: CALayer
        if let reused = layers[index] {
            layer = reused
        } else {
            layer = CALayer()
            self.layer?.addSublayer(layer)
            layers[index] = layer
        }
        layer.contents = sprite.image
        layer.bounds = CGRect(origin: .zero, size: CGSize(width: sprite.width, height: sprite.height))
        layer.contentsGravity = .resize
        layer.opacity = 0 // model 透明：可见性完全由动画窗口呈现（beginTime 前与结束后隐没）
        layer.isHidden = false
        return layer
    }

    private func effectiveColor(_ original: UInt32) -> UInt32 {
        switch colorMode {
        case .original: return original
        case .white: return 0xFFFFFF
        case .custom: return customColor
        }
    }
}

/// 引擎时间 seek 检测：time-pos 事件驱动，跳变超阈值判定为 seek（触发弹幕重摆）
@MainActor
private final class DanmakuTimeSync {
    private var lastEngine: Double = -1

    func didSeek(to engine: Double) -> Bool {
        let seeked = lastEngine >= 0 && abs(engine - lastEngine) > 0.5
        lastEngine = engine
        return seeked
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

/// 控制条弹幕菜单：显示开关 / 显示设置（字号/颜色/不透明度一级直达）/ 状态 / 重新获取。
/// 用户要求设置项放一级菜单（不走二级 sheet）；颜色选"自定义"时菜单内直接出取色器。
/// 凭据已内置（弹弹play），无凭据输入项（见 DanmakuEmbeddedCredentials）。
struct DanmakuMenu: View {
    @ObservedObject var controller: DanmakuController

    var body: some View {
        Menu {
            Toggle("弹幕显示", isOn: $controller.isEnabled)
            Divider()
            Picker("字号", selection: $controller.fontSize) {
                Text("小（18）").tag(CGFloat(18))
                Text("标准（22）").tag(CGFloat(22))
                Text("大（28）").tag(CGFloat(28))
            }
            Picker("颜色", selection: $controller.colorMode) {
                ForEach(DanmakuController.DanmakuColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if controller.colorMode == .custom {
                ColorPicker("自定义颜色", selection: customColorBinding)
            }
            Picker("不透明度", selection: $controller.opacity) {
                Text("30%").tag(Double(0.3))
                Text("60%").tag(Double(0.6))
                Text("100%").tag(Double(1.0))
            }
            Divider()
            Text(controller.statusDescription)
                .foregroundStyle(.secondary)
            Button {
                controller.refetch()
            } label: {
                Label("重新获取弹幕", systemImage: "arrow.clockwise")
            }
            .disabled(!controller.isEnabled || !controller.isConfigured)
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
                let ns = NSColor(color).usingColorSpace(.sRGB)
                let r = UInt32(round((ns?.redComponent ?? 0) * 255))
                let g = UInt32(round((ns?.greenComponent ?? 0) * 255))
                let b = UInt32(round((ns?.blueComponent ?? 0) * 255))
                controller.customColor = (r << 16) | (g << 8) | b
            }
        )
    }
}

import SwiftUI
import NagomiAniCore

/// 弹幕覆盖层：TimelineView + Canvas 逐帧渲染，绘制是 f(当前播放时间) 的纯函数——
/// 暂停冻结（时间停走）、拖动进度自动重排、seek 无需任何状态修正。
/// 车道分配在弹幕加载/画面尺寸变化时预计算一次（Core 纯函数），逐帧只做二分窗口过滤。
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

    /// 车道数按画面高度计算（滚动区占上方 75%）
    private func recomputeLanes(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        canvasSize = size
        laneCount = max(1, Int(size.height * DanmakuLayout.scrollAreaRatio / DanmakuLayout.laneHeight))
        trackItems = DanmakuLayout.assignLanes(
            comments: controller.comments,
            laneCount: laneCount,
            screenWidth: size.width
        )
    }

    private func render(context: inout GraphicsContext, size: CGSize, time: Double) {
        for item in trackItems {
            let elapsed = time - item.comment.time
            switch item.comment.mode {
            case .scroll:
                // 右缘从画面外滑入：x = (W + w) × (1 - elapsed/T) - w/2（文本中心）
                guard elapsed >= 0, elapsed <= DanmakuLayout.travelDuration else { continue }
                let x = (size.width + item.width) * (1 - CGFloat(elapsed / DanmakuLayout.travelDuration))
                    - item.width / 2
                let y = CGFloat(item.lane) * DanmakuLayout.laneHeight + DanmakuLayout.laneHeight / 2 + 4
                draw(text: item.comment.text, color: item.comment.color,
                     at: CGPoint(x: x, y: y), anchor: .leading, in: &context)
            case .top:
                guard elapsed >= 0, elapsed <= DanmakuLayout.stackDuration else { continue }
                let y = CGFloat(item.lane) * DanmakuLayout.laneHeight + DanmakuLayout.laneHeight / 2 + 4
                draw(text: item.comment.text, color: item.comment.color,
                     at: CGPoint(x: size.width / 2, y: y), anchor: .center, in: &context)
            case .bottom:
                guard elapsed >= 0, elapsed <= DanmakuLayout.stackDuration else { continue }
                let y = size.height - CGFloat(item.lane + 1) * DanmakuLayout.laneHeight
                    + DanmakuLayout.laneHeight / 2 - 4
                draw(text: item.comment.text, color: item.comment.color,
                     at: CGPoint(x: size.width / 2, y: y), anchor: .center, in: &context)
            }
        }
    }

    private func draw(text: String, color: UInt32, at point: CGPoint,
                      anchor: UnitPoint, in context: inout GraphicsContext) {
        let swiftuiColor = Color(
            red: Double((color >> 16) & 0xFF) / 255,
            green: Double((color >> 8) & 0xFF) / 255,
            blue: Double(color & 0xFF) / 255
        )
        let line = Text(text)
            .font(.system(size: 22, weight: .medium))
            .foregroundColor(swiftuiColor)
        context.draw(line, at: point, anchor: anchor)
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
        switch controller.phase {
        case .idle: return "未加载弹幕"
        case .unconfigured: return "未配置弹弹play 凭据（设置里填入）"
        case .matching: return "正在匹配剧集…"
        case .loading: return "正在拉取弹幕…"
        case .loaded(let count): return "已加载 \(count) 条弹幕"
        case .failed(let message): return "失败：\(message)"
        }
    }
}

/// 弹弹play 凭据设置（用户在弹弹play「设置 → 开放平台」免费申请）
struct DanmakuSettingsSheet: View {
    @ObservedObject var controller: DanmakuController
    @State private var appId = UserDefaults.standard.string(forKey: DanmakuController.appIdKey) ?? ""
    @State private var appSecret = UserDefaults.standard.string(forKey: DanmakuController.appSecretKey) ?? ""
    @Environment(\.dismiss) private var dismiss

    private var inputValid: Bool {
        !appId.trimmingCharacters(in: .whitespaces).isEmpty
            && !appSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("弹幕设置")
                .font(.headline)

            Text("弹幕来自弹弹play 开放 API。请先在弹弹play 应用内「设置 → 开放平台」免费申请 AppId 与 AppSecret，填入下方保存后立即生效。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("AppId", text: $appId)
                .textFieldStyle(.roundedBorder)
            SecureField("AppSecret", text: $appSecret)
                .textFieldStyle(.roundedBorder)

            Text("弹幕以悬浮层渲染，与字幕同时显示互不影响；弹幕数据按剧集缓存在内存，同集切回不重复请求。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(NagomiSecondaryButtonStyle())
                Button("保存") {
                    UserDefaults.standard.set(appId, forKey: DanmakuController.appIdKey)
                    UserDefaults.standard.set(appSecret, forKey: DanmakuController.appSecretKey)
                    controller.refreshConfiguration()
                    dismiss()
                }
                .buttonStyle(NagomiPrimaryButtonStyle())
                .disabled(!inputValid)
            }
        }
        .padding(16)
        .frame(width: 440, height: 280)
    }
}

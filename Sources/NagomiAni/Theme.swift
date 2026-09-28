import SwiftUI

/// NagomiAni 全局主题——柔和樱粉（单一色源：整体换肤只改这个文件）。
///
/// 浅色/深色跟随系统外观自动切换；语义状态色（已看绿/新集橙/错误红）不在主题内，
/// 保持状态可辨识性。播放器视频区保持影院黑，粉色只上控件（见 PlayerView）。
enum NagomiTheme {
    /// 品牌主色：按钮/选中/进度条/强调（深色模式提亮一档保证对比）
    static let accent = dynamic(
        light: NSColor(srgbRed: 0.925, green: 0.416, blue: 0.533, alpha: 1), // #EC6A88
        dark: NSColor(srgbRed: 0.949, green: 0.573, blue: 0.667, alpha: 1) // #F292AA
    )

    /// 主色的柔和变体：徽章底/选中态背景/图标占位
    static let accentSoft = dynamic(
        light: NSColor(srgbRed: 0.976, green: 0.835, blue: 0.878, alpha: 1), // #F9D5E0
        dark: NSColor(srgbRed: 0.302, green: 0.180, blue: 0.220, alpha: 1) // #4D2E38
    )

    /// 列表页/侧边栏背景罩层（窗口底色之上的极淡粉）
    static let pageBackground = dynamic(
        light: NSColor(srgbRed: 1.0, green: 0.969, blue: 0.976, alpha: 1), // #FFF7F9
        dark: NSColor(srgbRed: 0.125, green: 0.094, blue: 0.106, alpha: 1) // #20181B
    )

    /// 卡片/行背景（替代原 gray.opacity(0.06)）
    static let cardBackground = dynamic(
        light: NSColor(srgbRed: 0.992, green: 0.941, blue: 0.957, alpha: 1), // #FDF0F4
        dark: NSColor(srgbRed: 0.165, green: 0.125, blue: 0.141, alpha: 1) // #2A2024
    )

    /// 卡片 hover/侧边栏悬浮背景
    static let cardHover = dynamic(
        light: NSColor(srgbRed: 0.988, green: 0.906, blue: 0.929, alpha: 1), // #FCE7ED
        dark: NSColor(srgbRed: 0.208, green: 0.157, blue: 0.176, alpha: 1) // #35282D
    )

    /// 浅/深双色动态颜色（跟随系统外观）
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

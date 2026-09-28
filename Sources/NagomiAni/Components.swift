import SwiftUI

// MARK: - 樱粉组件语言（NagomiAni 全局复用）
//
// 设计约定：
// - 所有样式只改「背景/前景颜色」，不改布局尺寸——保证不遮挡、不挤压、不跳动
// - 语义状态色（已看绿/新集橙/错误红）不在组件内，由调用方传入
// - 播放器（黑底）用 playerHover 变体，列表页用默认柔粉

/// 主操作按钮：实底樱粉胶囊（页面主动作：搜索/添加/看下一集）
struct NagomiPrimaryButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(NagomiTheme.accent.opacity(hovering ? 0.88 : 1), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
    }
}

/// 次要按钮：柔粉底胶囊（关联/更换/完成等次级动作）
struct NagomiSecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(NagomiTheme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(NagomiTheme.accentSoft.opacity(hovering ? 0.65 : 1), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .onHover { hovering = $0 }
    }
}

/// 图标方按钮：圆角小方块底 + 悬浮显色（重扫/移除/书签等行内操作）。
/// 固定尺寸，行内多按钮不会互相挤压。
struct NagomiIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovering ? NagomiTheme.accent : NagomiTheme.accent.opacity(0.8))
            .frame(width: size, height: size)
            .background(hovering ? NagomiTheme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 行/卡片悬浮高亮：只叠加背景色，不改布局（列表行、卡片通用）
    func nagomiHoverHighlight<S: Shape>(
        _ color: Color = NagomiTheme.cardHover,
        in shape: S
    ) -> some View {
        modifier(NagomiHoverHighlight(color: color, shape: shape))
    }

    /// 主题卡片：卡片底色 + 圆角 + 樱粉细描边
    func nagomiCard(cornerRadius: CGFloat = 10) -> some View {
        background(NagomiTheme.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(NagomiTheme.accent.opacity(0.12), lineWidth: 1)
            )
    }
}

struct NagomiHoverHighlight<S: Shape>: ViewModifier {
    let color: Color
    let shape: S
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? color : Color.clear, in: shape)
            .onHover { hovering = $0 }
    }
}

/// 统一徽章：状态/标签小胶囊（字号与内边距全局一致）
struct NagomiBadge: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
            .lineLimit(1)
    }
}

/// 区块标题：樱粉竖条 + 图标 + 标题（番库/在线页分区用）
struct NagomiSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(NagomiTheme.accent)
                .frame(width: 4, height: 16)
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(NagomiTheme.accent)
            Text(title)
                .font(.title3)
            Spacer()
        }
        .padding(.top, 6)
    }
}

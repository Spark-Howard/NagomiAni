import CoreGraphics
import Foundation

/// 弹幕显示模式（与弹弹play/通用弹幕协议对齐）
public enum DanmakuMode: Int, Sendable, Hashable {
    /// 右 → 左滚动
    case scroll = 1
    /// 底部固定
    case bottom = 4
    /// 顶部固定
    case top = 5
}

/// 一条弹幕
public struct DanmakuComment: Sendable, Hashable {
    /// 出现时间（秒）
    public let time: Double
    public let mode: DanmakuMode
    /// 颜色 0xRRGGBB
    public let color: UInt32
    public let text: String

    public init(time: Double, mode: DanmakuMode, color: UInt32, text: String) {
        self.time = time
        self.mode = mode
        self.color = color
        self.text = text
    }
}

/// 车道分配后的可渲染弹幕
public struct DanmakuTrackItem: Sendable, Hashable {
    public let comment: DanmakuComment
    /// 车道下标（滚动/顶部/底部各自独立编号，从 0 起）
    public let lane: Int
    /// 估算的文本宽度（逻辑像素，用于滚动位移）
    public let width: CGFloat

    public init(comment: DanmakuComment, lane: Int, width: CGFloat) {
        self.comment = comment
        self.lane = lane
        self.width = width
    }
}

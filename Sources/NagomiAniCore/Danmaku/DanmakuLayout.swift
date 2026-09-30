import CoreGraphics
import Foundation

/// 弹幕车道分配（纯函数，可单测）。
///
/// - 滚动弹幕：按估算宽度分配车道，新弹幕出发时前一条必须已离开安全距离
///   （否则换下一条车道；全部拥挤时取"最接近可出发"的车道兜底）
/// - 顶部/底部：独立堆叠车道，固定停留 `stackDuration` 秒
/// 输出按出现时间排序的渲染项，渲染层据此逐帧绘制。
public enum DanmakuLayout {
    /// 滚动弹幕横穿屏幕的滞留时长（秒）
    public static let travelDuration: Double = 12
    /// 顶部/底部弹幕的停留时长（秒）
    public static let stackDuration: Double = 5
    /// 每条车道高度（与默认字号 24 匹配）
    public static let laneHeight: CGFloat = 34
    /// 滚动弹幕可占画面高度的比例（下方留白给字幕/控制条）
    public static let scrollAreaRatio: CGFloat = 0.75
    /// 顶部/底部堆叠车道数
    public static let stackLaneCount = 4

    /// 文本宽度估算：CJK 字符按 1.0×字号、ASCII 按 0.55×
    public static func estimateWidth(text: String, fontSize: CGFloat) -> CGFloat {
        var units: CGFloat = 0
        for char in text {
            let isWide = char.unicodeScalars.first.map { $0.value >= 0x2E80 } == true
            units += isWide ? 1.0 : 0.55
        }
        return max(units * fontSize, fontSize)
    }

    /// 车道分配（评论会先按出现时间排序，保证确定性）。
    /// - Parameters:
    ///   - laneCount: 滚动车道数（由渲染层按画面高度计算）
    ///   - screenWidth: 画面逻辑宽（滚动位移基准）
    ///   - fontSize: 默认字号（宽度估算的兜底）
    ///   - measure: 可选的真实文本测宽（渲染层用字体度量注入；
    ///     估算宽度对 emoji/宽字母偏差大，实测能让车道防重叠数学与实际绘制一致）
    public static func assignLanes(
        comments: [DanmakuComment],
        laneCount: Int,
        screenWidth: CGFloat,
        fontSize: CGFloat = 24,
        measure: ((String) -> CGFloat)? = nil
    ) -> [DanmakuTrackItem] {
        let lanes = max(laneCount, 1)
        let sorted = comments.sorted { $0.time < $1.time }

        // 滚动车道：记录每条车道上一条弹幕的出发时间与宽度
        var scrollLanes: [(entryTime: Double, width: CGFloat)] = Array(
            repeating: (entryTime: -1, width: 0), count: lanes
        )
        // 顶部/底部堆叠：记录每条车道的占用结束时间
        var topStack: [Double] = Array(repeating: -1, count: stackLaneCount)
        var bottomStack: [Double] = Array(repeating: -1, count: stackLaneCount)
        var scrollRoundRobin = 0

        var items: [DanmakuTrackItem] = []
        for comment in sorted {
            let width = measure?(comment.text)
                ?? estimateWidth(text: comment.text, fontSize: fontSize)
            switch comment.mode {
            case .scroll:
                let lane = pickScrollLane(
                    at: comment.time, width: width, lanes: &scrollLanes,
                    screenWidth: screenWidth, roundRobin: &scrollRoundRobin
                )
                scrollLanes[lane] = (comment.time, width)
                items.append(DanmakuTrackItem(comment: comment, lane: lane, width: width))
            case .top:
                let lane = pickStackLane(at: comment.time, lanes: &topStack)
                items.append(DanmakuTrackItem(comment: comment, lane: lane, width: width))
            case .bottom:
                let lane = pickStackLane(at: comment.time, lanes: &bottomStack)
                items.append(DanmakuTrackItem(comment: comment, lane: lane, width: width))
            }
        }
        return items
    }

    /// 滚动车道：新弹幕出发时，前一条的右缘须已完全进入画面（不与新弹幕重叠）
    private static func pickScrollLane(
        at time: Double,
        width: CGFloat,
        lanes: inout [(entryTime: Double, width: CGFloat)],
        screenWidth: CGFloat,
        roundRobin: inout Int
    ) -> Int {
        var fallbackLane = -1
        var fallbackDelay = Double.greatestFiniteMagnitude
        for lane in 0..<lanes.count {
            let last = lanes[lane]
            guard last.entryTime >= 0 else { return lane } // 未使用的车道直接用
            // 前一条移动 (width_prev) 距离所需的时间 + 0.2s 安全间距
            let required = travelDuration * (last.width / (screenWidth + last.width)) + 0.2
            let delay = time - last.entryTime - required
            if delay >= 0 { return lane }
            if delay < fallbackDelay {
                fallbackDelay = delay
                fallbackLane = lane
            }
        }
        // 全部拥挤：取延迟最小的车道（重叠最轻），round-robin 兜底打散
        let lane = fallbackLane >= 0 ? fallbackLane : roundRobin % lanes.count
        roundRobin += 1
        return lane
    }

    /// 堆叠车道（顶部/底部）：取占用已结束的车道，全部占用时轮转
    private static func pickStackLane(at time: Double, lanes: inout [Double]) -> Int {
        for lane in 0..<lanes.count where time >= lanes[lane] {
            lanes[lane] = time + stackDuration
            return lane
        }
        let lane = Int(time) % lanes.count
        lanes[lane] = time + stackDuration
        return lane
    }
}

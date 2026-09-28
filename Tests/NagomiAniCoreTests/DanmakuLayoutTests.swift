import XCTest
@testable import NagomiAniCore

final class DanmakuLayoutTests: XCTestCase {
    private func comment(_ time: Double, _ mode: DanmakuMode, _ text: String) -> DanmakuComment {
        DanmakuComment(time: time, mode: mode, color: 0xFFFFFF, text: text)
    }

    /// 时间相距很远的两条滚动弹幕 → 同一条车道（0）
    func testFarApartCommentsShareLane() {
        let items = DanmakuLayout.assignLanes(
            comments: [comment(0, .scroll, "第一条弹幕"), comment(30, .scroll, "第二条弹幕")],
            laneCount: 4, screenWidth: 800
        )
        XCTAssertEqual(items.map(\.lane), [0, 0])
    }

    /// 时间接近的两条滚动弹幕 → 分到不同车道（不重叠）
    func testOverlappingCommentsGetDifferentLanes() {
        let items = DanmakuLayout.assignLanes(
            comments: [comment(10, .scroll, "同时出现的第一条"), comment(10.2, .scroll, "同时出现的第二条")],
            laneCount: 4, screenWidth: 800
        )
        XCTAssertNotEqual(items[0].lane, items[1].lane)
    }

    /// 车道全部拥挤时仍不为 nil（兜底轮转），且输出数量与输入一致
    func testBurstKeepsAllComments() {
        let comments = (0..<10).map { comment(100 + Double($0) * 0.1, .scroll, "密集弹幕\($0)") }
        let items = DanmakuLayout.assignLanes(
            comments: comments, laneCount: 2, screenWidth: 800
        )
        XCTAssertEqual(items.count, comments.count, "拥挤时不丢弃弹幕")
    }

    /// 顶部/底部模式：使用各自的堆叠车道，与滚动车道互不干扰
    func testTopAndBottomStacks() {
        let items = DanmakuLayout.assignLanes(
            comments: [
                comment(0, .top, "顶1"),
                comment(0.5, .top, "顶2"),
                comment(0, .bottom, "底1"),
                comment(0, .scroll, "滚1"),
            ],
            laneCount: 4, screenWidth: 800
        )
        let top = items.filter { $0.comment.mode == .top }
        let bottom = items.filter { $0.comment.mode == .bottom }
        let scroll = items.filter { $0.comment.mode == .scroll }
        XCTAssertNotEqual(top[0].lane, top[1].lane, "顶部堆叠不重叠")
        XCTAssertEqual(bottom[0].lane, 0, "底部与顶部互不影响")
        XCTAssertEqual(scroll[0].lane, 0, "滚动车道独立编号")
    }

    /// 堆叠车道停留 5 秒后复用
    func testStackLaneReusedAfterDuration() {
        let items = DanmakuLayout.assignLanes(
            comments: [comment(0, .top, "先"), comment(DanmakuLayout.stackDuration + 0.5, .top, "后")],
            laneCount: 4, screenWidth: 800
        )
        XCTAssertEqual(items.map(\.lane), [0, 0], "超过停留时长后车道复用")
    }

    /// 输出按时间排序（渲染层二分窗口依赖此前提）
    func testOutputSortedByTime() {
        let comments = [comment(30, .scroll, "C"), comment(1, .scroll, "A"), comment(15, .scroll, "B")]
        let items = DanmakuLayout.assignLanes(comments: comments, laneCount: 3, screenWidth: 800)
        XCTAssertEqual(items.map { $0.comment.time }, [1, 15, 30])
    }

    /// 宽度估算：CJK 明显宽于 ASCII；空文本有最小宽度
    func testEstimateWidth() {
        let cjk = DanmakuLayout.estimateWidth(text: "弹幕", fontSize: 24)
        let ascii = DanmakuLayout.estimateWidth(text: "ab", fontSize: 24)
        XCTAssertEqual(cjk, 48)
        XCTAssertEqual(ascii, 24 * 0.55 * 2, accuracy: 0.001)
        XCTAssertEqual(DanmakuLayout.estimateWidth(text: "", fontSize: 24), 24)
    }

    /// 渲染项按时间窗口可见性的前提：车道分配不改变评论时间
    func testLaneAssignmentPreservesComments() {
        let comments = [
            comment(1, .scroll, "甲"), comment(2, .top, "乙"), comment(3, .bottom, "丙"),
        ]
        let items = DanmakuLayout.assignLanes(comments: comments, laneCount: 4, screenWidth: 800)
        XCTAssertEqual(items.map { $0.comment }, comments.sorted { $0.time < $1.time })
    }
}

import XCTest
@testable import NagomiAniCore

final class DirectoryChangePlannerTests: XCTestCase {
    private let roots = ["/media/anime"]
    private let seriesKeys = ["/media/anime/Show A", "/media/anime/Show B"]
    /// 模拟磁盘上的目录（测试注入，保证判定可复现）
    private var directories: Set<String> = []

    private func plan(_ paths: [String]) -> Set<String> {
        DirectoryChangePlanner.rescanTargets(
            eventPaths: paths,
            roots: roots,
            seriesKeys: seriesKeys,
            isDirectory: { [directories] path in directories.contains(path) }
        )
    }

    override func setUpWithError() throws {
        directories = ["/media/anime", "/media/anime/Show A", "/media/anime/Show B"]
    }

    // MARK: - 文件事件

    func testFileInKnownSeriesRescansThatSeries() {
        // 最常见：新集下载完
        let targets = plan(["/media/anime/Show A/EP05.mkv"])
        XCTAssertEqual(targets, ["/media/anime/Show A"])
    }

    func testFileInSeriesSubdirectoryRescansSeries() {
        let targets = plan(["/media/anime/Show A/Extras/SP01.mkv"])
        XCTAssertEqual(targets, ["/media/anime/Show A"])
    }

    func testFileInUnindexedDirectoryRescansParent() {
        // 新番的第一集：父目录不在系列里但在库根下 → 扫父目录建出新系列
        let targets = plan(["/media/anime/New Show/EP01.mkv"])
        XCTAssertEqual(targets, ["/media/anime/New Show"])
    }

    func testFileDirectlyInRootRescansRoot() {
        let targets = plan(["/media/anime/movie.mkv"])
        XCTAssertEqual(targets, ["/media/anime"])
    }

    func testDeletedFileInSeriesRescansSeries() {
        // 文件已删除（路径不存在）：仍按父目录重扫，rescanFolder 负责清理
        let targets = plan(["/media/anime/Show A/EP03.mkv"])
        XCTAssertEqual(targets, ["/media/anime/Show A"])
    }

    // MARK: - 目录事件

    func testDirectoryEventForNewSeriesRescansItself() {
        // 整目录移入（目录还在）：扫该目录即可，不必扫整个根
        directories.insert("/media/anime/New Show")
        let targets = plan(["/media/anime/New Show"])
        XCTAssertEqual(targets, ["/media/anime/New Show"])
    }

    func testDirectoryEventInsideSeriesRescansSeries() {
        directories.insert("/media/anime/Show A/SPs")
        let targets = plan(["/media/anime/Show A/SPs"])
        XCTAssertEqual(targets, ["/media/anime/Show A"])
    }

    func testDirectoryEventForRootRescansRoot() {
        // MustScanSubDirs 兜底：事件直接落在库根
        let targets = plan(["/media/anime"])
        XCTAssertEqual(targets, ["/media/anime"])
    }

    func testDeletedSeriesDirectoryFallsBackToParent() {
        // 整目录被删（路径已不存在，isDirectory 为 false）：按文件处理 → 扫父目录
        // rescanFolder 对已关联番保留空条目、未关联番移除
        directories.remove("/media/anime/Show A")
        let targets = plan(["/media/anime/Show A"])
        XCTAssertEqual(targets, ["/media/anime"])
    }

    // MARK: - 相关性过滤

    func testNonVideoFilesIgnored() {
        XCTAssertEqual(plan(["/media/anime/Show A/cover.jpg"]), [])
        XCTAssertEqual(plan(["/media/anime/Show A/info.nfo"]), [])
        XCTAssertEqual(plan(["/media/anime/Show A/EP01.mkv.part"]), [])
    }

    func testPathsOutsideRootsIgnored() {
        XCTAssertEqual(plan(["/Users/x/Downloads/EP01.mkv"]), [])
        XCTAssertEqual(plan(["/Users/x/Downloads/Some Show"]), [])
    }

    func testEmptyExtensionNonexistentPathStillRelevant() {
        // 空扩展名且目录已消失（被删目录）：保守放行，交由父目录重扫兜底
        let targets = plan(["/media/anime/Show A/EP01"])
        XCTAssertEqual(targets, ["/media/anime/Show A"])
    }

    // MARK: - 合并与去重

    func testMultipleEventsDeduplicate() {
        let targets = plan([
            "/media/anime/Show A/EP05.mkv",
            "/media/anime/Show A/EP06.mkv",
            "/media/anime/Show A",
        ])
        XCTAssertEqual(targets, ["/media/anime/Show A"])
    }

    func testAncestorTargetPrunesDescendants() {
        // 事件同时落在根与根下的番：扫根已覆盖番，丢弃番级目标
        directories.insert("/media/anime/Show C")
        let targets = plan([
            "/media/anime/Show A/EP01.mkv",
            "/media/anime/Show C/EP01.mkv",
            "/media/anime",
        ])
        XCTAssertEqual(targets, ["/media/anime"])
    }

    func testEmptyEventsYieldNoTargets() {
        XCTAssertEqual(plan([]), [])
    }

    func testMultipleRoots() {
        let targets = DirectoryChangePlanner.rescanTargets(
            eventPaths: ["/media/other/Show X/EP01.mkv"],
            roots: ["/media/anime", "/media/other"],
            seriesKeys: [],
            isDirectory: { _ in false }
        )
        XCTAssertEqual(targets, ["/media/other/Show X"])
    }
}

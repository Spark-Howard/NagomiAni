import XCTest
@testable import NagomiAniCore

final class PlaybackResumeTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NagomiAniTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func storeURL() -> URL {
        tempDir.appendingPathComponent("resume.json")
    }

    // MARK: - ResumePolicy（续播判定）

    func testPolicySkipsShortPositions() {
        // 不足 15s：从头播
        XCTAssertNil(ResumePolicy.resumePosition(position: 0, duration: 1440))
        XCTAssertNil(ResumePolicy.resumePosition(position: 14.9, duration: 1440))
    }

    func testPolicyResumesAtMinBoundary() {
        // 恰好 15s：续播
        XCTAssertEqual(ResumePolicy.resumePosition(position: 15, duration: 1440), 15)
    }

    func testPolicySkipsNearEnd() {
        // 距结尾不足 30s：视为看完，从头播
        XCTAssertNil(ResumePolicy.resumePosition(position: 1440 - 29, duration: 1440))
        // 距结尾恰好 30s：续播（<=）
        XCTAssertEqual(ResumePolicy.resumePosition(position: 1440 - 30, duration: 1440), 1440 - 30)
    }

    func testPolicySkipsPositionBeyondDuration() {
        // 记录损坏（位置越过结尾）：从头播
        XCTAssertNil(ResumePolicy.resumePosition(position: 2000, duration: 1440))
    }

    func testPolicyWithUnknownDuration() {
        // 时长未知（0）：只要位置够大就续播
        XCTAssertEqual(ResumePolicy.resumePosition(position: 600, duration: 0), 600)
        XCTAssertNil(ResumePolicy.resumePosition(position: 5, duration: 0))
    }

    func testPolicyRejectsNonFinitePosition() {
        XCTAssertNil(ResumePolicy.resumePosition(position: .infinity, duration: 1440))
        XCTAssertNil(ResumePolicy.resumePosition(position: .nan, duration: 1440))
    }

    // MARK: - PlaybackResumeStore（持久化）

    func testStorePersistsAcrossInstances() throws {
        let url = storeURL()
        let store = PlaybackResumeStore(fileURL: url)
        store.update(path: "/a/EP01.mkv", position: 600, duration: 1440, updatedAt: Date(timeIntervalSince1970: 100))
        store.update(path: "/b/EP02.mkv", position: 60, duration: 0)

        // 新实例从磁盘恢复
        let reopened = PlaybackResumeStore(fileURL: url)
        XCTAssertEqual(reopened.entry(forPath: "/a/EP01.mkv")?.position, 600)
        XCTAssertEqual(reopened.entry(forPath: "/a/EP01.mkv")?.duration, 1440)
        XCTAssertEqual(reopened.entry(forPath: "/b/EP02.mkv")?.position, 60)
        XCTAssertNil(reopened.entry(forPath: "/missing.mkv"))
    }

    func testUpdateOverwritesSamePath() {
        let store = PlaybackResumeStore(fileURL: storeURL())
        store.update(path: "/a/EP01.mkv", position: 100, duration: 0)
        store.update(path: "/a/EP01.mkv", position: 200, duration: 1440)
        let entry = store.entry(forPath: "/a/EP01.mkv")
        XCTAssertEqual(entry?.position, 200)
        XCTAssertEqual(entry?.duration, 1440)
    }

    func testRemoveAndRemoveAll() throws {
        let url = storeURL()
        let store = PlaybackResumeStore(fileURL: url)
        store.update(path: "/a.mkv", position: 100, duration: 0)
        store.update(path: "/b.mkv", position: 100, duration: 0)
        store.remove(path: "/a.mkv")

        // remove 持久化：新实例读不到
        let afterRemove = PlaybackResumeStore(fileURL: url)
        XCTAssertNil(afterRemove.entry(forPath: "/a.mkv"))
        XCTAssertNotNil(afterRemove.entry(forPath: "/b.mkv"))

        afterRemove.removeAll()
        let afterClear = PlaybackResumeStore(fileURL: url)
        XCTAssertNil(afterClear.entry(forPath: "/b.mkv"))
    }

    func testRemoveNonexistentDoesNotWrite() {
        let url = storeURL()
        let store = PlaybackResumeStore(fileURL: url)
        store.remove(path: "/never-existed.mkv")
        // 没有记录时 remove 不应产生文件
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testCorruptFileTreatedAsEmpty() throws {
        let url = storeURL()
        try Data("not json at all{{{".utf8).write(to: url)
        let store = PlaybackResumeStore(fileURL: url)
        XCTAssertNil(store.entry(forPath: "/a.mkv"))
        // 且能继续正常使用
        store.update(path: "/a.mkv", position: 100, duration: 0)
        XCTAssertEqual(PlaybackResumeStore(fileURL: url).entry(forPath: "/a.mkv")?.position, 100)
    }

    func testCapacityPrunesOldest() {
        let store = PlaybackResumeStore(fileURL: storeURL())
        let capacity = PlaybackResumeStore.capacity
        // 插入 capacity + 10 条，时间戳递增：最旧的被淘汰，最新的保留
        for i in 0..<(capacity + 10) {
            store.update(
                path: "/dir/file\(i).mkv",
                position: 100,
                duration: 0,
                updatedAt: Date(timeIntervalSince1970: Double(i))
            )
        }
        XCTAssertNil(store.entry(forPath: "/dir/file0.mkv"))
        XCTAssertNil(store.entry(forPath: "/dir/file9.mkv"))
        XCTAssertNotNil(store.entry(forPath: "/dir/file10.mkv"))
        XCTAssertNotNil(store.entry(forPath: "/dir/file\(capacity + 9).mkv"))
    }
}

import XCTest
@testable import NagomiAniCore

final class MediaLibraryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NagomiAniTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 写一个空视频文件（扫描只认扩展名）
    private func makeFile(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func testScanGroupsEpisodesIntoOneSeries() throws {
        let animeDir = tempDir.appendingPathComponent("命运石之门")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        for i in 1...3 {
            try makeFile(String(format: "[Demo] 命运石之门 - %02d [1080p].mkv", i), in: animeDir)
        }

        let storeURL = tempDir.appendingPathComponent("lib.json")
        let library = MediaLibrary(storeURL: storeURL)
        XCTAssertTrue(library.addFolder(animeDir.path))
        library.rescan()

        XCTAssertEqual(library.series.count, 1)
        let series = try XCTUnwrap(library.series.first)
        XCTAssertEqual(series.files.count, 3)
        XCTAssertEqual(series.sortedFiles.first?.episodeNumber, 1)
        XCTAssertEqual(series.sortedFiles.last?.episodeNumber, 3)
    }

    func testPersistsAcrossInstances() throws {
        let animeDir = tempDir.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: animeDir)

        let storeURL = tempDir.appendingPathComponent("lib.json")
        let library = MediaLibrary(storeURL: storeURL)
        library.addFolder(animeDir.path)
        library.rescan()
        XCTAssertEqual(library.series.count, 1)

        // 新实例重新加载
        let reloaded = MediaLibrary(storeURL: storeURL)
        XCTAssertEqual(reloaded.folders, [MediaLibrary.canonicalPath(animeDir.path)])
        XCTAssertEqual(reloaded.series.count, 1)
    }

    func testRescanKeepsBindingAndDropsMissingFiles() throws {
        let animeDir = tempDir.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        try makeFile("番B EP01.mkv", in: animeDir)
        try makeFile("番B EP02.mkv", in: animeDir)

        let storeURL = tempDir.appendingPathComponent("lib.json")
        let library = MediaLibrary(storeURL: storeURL)
        library.addFolder(animeDir.path)
        library.rescan()

        // 模拟手动关联（L2 自动匹配会调用 setBinding）
        let key = try XCTUnwrap(library.series.first?.seriesKey)
        XCTAssertTrue(library.setBinding(seriesKey: key, subjectID: 12345))

        // 删除 EP01 后重扫
        try FileManager.default.removeItem(at: animeDir.appendingPathComponent("番B EP01.mkv"))
        library.rescan()

        let after = try XCTUnwrap(library.series.first)
        XCTAssertEqual(after.files.count, 1)
        XCTAssertEqual(after.subjectID, 12345, "重扫不应丢失已关联的条目")
        XCTAssertEqual(after.matchState, .matched)
    }

    func testRemoveFolderCleansSeries() throws {
        let animeDir = tempDir.appendingPathComponent("番C")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        try makeFile("番C EP01.mkv", in: animeDir)

        let storeURL = tempDir.appendingPathComponent("lib.json")
        let library = MediaLibrary(storeURL: storeURL)
        library.addFolder(animeDir.path)
        library.rescan()
        XCTAssertEqual(library.series.count, 1)

        library.removeFolder(animeDir.path)
        XCTAssertTrue(library.folders.isEmpty)
        XCTAssertTrue(library.series.isEmpty)    }

    func testDuplicateFolderAddIsIgnored() throws {
        let animeDir = tempDir.appendingPathComponent("番D")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        XCTAssertTrue(library.addFolder(animeDir.path))
        XCTAssertFalse(library.addFolder(animeDir.path), "重复添加同一目录应被忽略")
        XCTAssertEqual(library.folders.count, 1)
    }

    func testFolderCentricGrouping() throws {
        // 同一文件夹内、命名随意的两集归为一部
        let dirA = tempDir.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try makeFile("01.mkv", in: dirA)
        try makeFile("02.mkv", in: dirA)

        // 不同文件夹 = 不同番
        let dirB = tempDir.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try makeFile("01.mkv", in: dirB)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(tempDir.path)
        library.rescan()

        XCTAssertEqual(library.series.count, 2)
        let seriesA = try XCTUnwrap(library.series.first { $0.displayName == "番A" })
        XCTAssertEqual(seriesA.files.count, 2)
        XCTAssertEqual(seriesA.sortedFiles.first?.episodeNumber, 1)
    }

    // MARK: - 单目录重扫（番级"重新扫描"）

    func testRescanFolderOnlyAffectsThatFolder() throws {
        let dirA = tempDir.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: dirA)

        let dirB = tempDir.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try makeFile("番B EP01.mkv", in: dirB)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(dirA.path)
        library.addFolder(dirB.path)
        library.rescan()
        XCTAssertEqual(library.series.count, 2)

        // 只重扫 A：新增 EP02、删除 EP01
        try makeFile("番A EP02.mkv", in: dirA)
        try FileManager.default.removeItem(at: dirA.appendingPathComponent("番A EP01.mkv"))
        XCTAssertTrue(library.rescanFolder(dirA.path))

        let seriesA = try XCTUnwrap(library.series.first { $0.displayName == "番A" })
        XCTAssertEqual(seriesA.files.count, 1)
        XCTAssertEqual(seriesA.sortedFiles.first?.episodeNumber, 2)

        // B 不受影响
        let seriesB = try XCTUnwrap(library.series.first { $0.displayName == "番B" })
        XCTAssertEqual(seriesB.files.count, 1)
        XCTAssertEqual(seriesB.sortedFiles.first?.episodeNumber, 1)
    }

    func testRescanFolderKeepsBindingAndAddsNewSeries() throws {
        let root = tempDir.appendingPathComponent("库")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let animeDir = root.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: animeDir)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(root.path)
        library.rescan()

        let key = try XCTUnwrap(library.series.first?.seriesKey)
        XCTAssertTrue(library.setBinding(seriesKey: key, subjectID: 999))

        // 单目录重扫：保留关联 + 该目录下新增一部番
        let newDir = root.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeFile("番B EP01.mkv", in: newDir)
        XCTAssertTrue(library.rescanFolder(root.path))

        let seriesA = try XCTUnwrap(library.series.first { $0.displayName == "番A" })
        XCTAssertEqual(seriesA.subjectID, 999, "单目录重扫不应丢失关联")
        XCTAssertEqual(seriesA.matchState, .matched)
        XCTAssertEqual(library.series.count, 2, "该目录下新增的番应被纳入")
    }

    func testOwningFolder() throws {
        let root = tempDir.appendingPathComponent("库")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let animeDir = root.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: animeDir)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(root.path)
        library.rescan()

        let key = try XCTUnwrap(library.series.first?.seriesKey)
        XCTAssertEqual(library.owningFolder(of: key), MediaLibrary.canonicalPath(root.path))
        // seriesKey 本身是已添加目录时直接用
        XCTAssertEqual(library.owningFolder(of: MediaLibrary.canonicalPath(root.path)), MediaLibrary.canonicalPath(root.path))
    }

    // MARK: - 文件全部删除后重扫（修复：失效文件残留导致点击报"播放失败"）

    func testRescanFolderEmptiesMatchedSeriesWhenAllFilesDeleted() throws {
        let animeDir = tempDir.appendingPathComponent("番全删")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        try makeFile("番全删 EP01.mkv", in: animeDir)
        try makeFile("番全删 EP02.mkv", in: animeDir)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(animeDir.path)
        library.rescan()
        let key = try XCTUnwrap(library.series.first?.seriesKey)
        XCTAssertTrue(library.setBinding(seriesKey: key, subjectID: 777))

        // 删除目录里的全部视频（目录本身还在），点"更新"
        try FileManager.default.removeItem(at: animeDir.appendingPathComponent("番全删 EP01.mkv"))
        try FileManager.default.removeItem(at: animeDir.appendingPathComponent("番全删 EP02.mkv"))
        XCTAssertTrue(library.rescanFolder(animeDir.path))

        // 已关联的番保留但文件清空（展开按 Bangumi 集数显示"本地未找到"），
        // 不能残留失效文件；重新下载后再"更新"按原关联恢复
        let after = try XCTUnwrap(library.series.first)
        XCTAssertTrue(after.files.isEmpty, "文件全删后不得残留可点击的失效文件")
        XCTAssertEqual(after.subjectID, 777, "文件清空应保留 Bangumi 关联")
        XCTAssertEqual(after.matchState, .matched)
    }

    func testRescanFolderKeepsMatchedSeriesWhenFolderDeleted() throws {
        let root = tempDir.appendingPathComponent("库")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let animeA = root.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: animeA, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: animeA)
        let animeB = root.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: animeB, withIntermediateDirectories: true)
        try makeFile("番B EP01.mkv", in: animeB)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(root.path)
        library.rescan()
        XCTAssertEqual(library.series.count, 2)
        let keyA = try XCTUnwrap(library.series.first { $0.displayName == "番A" }?.seriesKey)
        XCTAssertTrue(library.setBinding(seriesKey: keyA, subjectID: 888))

        // 整目录删除后重扫该目录：A 文件清空但保留关联；B 不受影响
        try FileManager.default.removeItem(at: animeA)
        XCTAssertFalse(library.rescanFolder(animeA.path), "目录不存在应返回 false")

        XCTAssertEqual(library.series.count, 2)
        let seriesA = try XCTUnwrap(library.series.first { $0.displayName == "番A" })
        XCTAssertTrue(seriesA.files.isEmpty, "被删目录不得残留失效文件")
        XCTAssertEqual(seriesA.subjectID, 888)
        let seriesB = try XCTUnwrap(library.series.first { $0.displayName == "番B" })
        XCTAssertEqual(seriesB.files.count, 1)
    }

    func testRescanFolderRemovesUnmatchedSeriesWhenFilesAllDeleted() throws {
        let animeA = tempDir.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: animeA, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: animeA)
        let animeB = tempDir.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: animeB, withIntermediateDirectories: true)
        try makeFile("番B EP01.mkv", in: animeB)
        try makeFile("番B EP02.mkv", in: animeB)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(animeA.path)
        library.addFolder(animeB.path)
        library.rescan()
        let keyB = try XCTUnwrap(library.series.first { $0.displayName == "番B" }?.seriesKey)
        XCTAssertTrue(library.setBinding(seriesKey: keyB, subjectID: 666))

        // 未关联的 A 文件删空并重扫 A：A 移除；已关联的 B 文件与关联都保留
        try FileManager.default.removeItem(at: animeA.appendingPathComponent("番A EP01.mkv"))
        XCTAssertTrue(library.rescanFolder(animeA.path))

        XCTAssertEqual(library.series.count, 1)
        let seriesB = try XCTUnwrap(library.series.first)
        XCTAssertEqual(seriesB.displayName, "番B")
        XCTAssertEqual(seriesB.files.count, 2)
        XCTAssertEqual(seriesB.subjectID, 666)
    }

    // MARK: - 文件消失后的二选一：删除条目 / 迁移到新目录

    func testRemoveSeriesRemovesEntryAndFolderRegistration() throws {
        let animeDir = tempDir.appendingPathComponent("番移除")
        try FileManager.default.createDirectory(at: animeDir, withIntermediateDirectories: true)
        try makeFile("番移除 EP01.mkv", in: animeDir)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(animeDir.path)
        library.rescan()
        XCTAssertEqual(library.series.count, 1)

        let key = try XCTUnwrap(library.series.first?.seriesKey)
        library.removeSeries(key)
        XCTAssertTrue(library.series.isEmpty, "删除条目后系列应清空")
        XCTAssertTrue(library.folders.isEmpty, "该番目录本身是登记的库目录时，移除条目应一并移除目录登记")
    }

    func testRemoveSeriesKeepsOtherSeriesAndFolders() throws {
        let root = tempDir.appendingPathComponent("库")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let animeA = root.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: animeA, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: animeA)
        let animeB = root.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: animeB, withIntermediateDirectories: true)
        try makeFile("番B EP01.mkv", in: animeB)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(root.path)
        library.rescan()
        XCTAssertEqual(library.series.count, 2)

        // 番A 是根目录下的子目录：只移除 A 的条目，目录登记与 B 都保留
        let keyA = try XCTUnwrap(library.series.first { $0.displayName == "番A" }?.seriesKey)
        library.removeSeries(keyA)
        XCTAssertEqual(library.series.count, 1)
        XCTAssertEqual(library.series.first?.displayName, "番B")
        XCTAssertEqual(library.folders, [MediaLibrary.canonicalPath(root.path)])
    }

    func testRelocateSeriesMovesBindingToNewFolder() throws {
        let oldDir = tempDir.appendingPathComponent("番旧位置")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try makeFile("番 EP01.mkv", in: oldDir)
        let newDir = tempDir.appendingPathComponent("番新位置")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        try makeFile("番 EP01.mkv", in: newDir)
        try makeFile("番 EP02.mkv", in: newDir)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(oldDir.path)
        library.rescan()
        XCTAssertEqual(library.series.count, 1)
        let oldKey = try XCTUnwrap(library.series.first?.seriesKey)
        XCTAssertTrue(library.setBinding(seriesKey: oldKey, subjectID: 555))

        // 文件已移走（旧目录删空），迁移到新目录
        try FileManager.default.removeItem(at: oldDir.appendingPathComponent("番 EP01.mkv"))
        let newKey = try XCTUnwrap(library.relocateSeries(oldSeriesKey: oldKey, to: newDir.path))
        XCTAssertNotEqual(newKey, oldKey)

        XCTAssertEqual(library.series.count, 1)
        let moved = try XCTUnwrap(library.series.first)
        XCTAssertEqual(moved.seriesKey, newKey)
        XCTAssertEqual(moved.files.count, 2)
        XCTAssertEqual(moved.subjectID, 555, "迁移后应保留 Bangumi 关联")
        XCTAssertEqual(moved.matchState, .matched)
        XCTAssertTrue(library.folders.contains(MediaLibrary.canonicalPath(newDir.path)), "新目录应被登记")
        XCTAssertFalse(library.folders.contains(MediaLibrary.canonicalPath(oldDir.path)), "旧目录登记应移除")
    }

    func testRelocateSeriesAmbiguousFolderReturnsNil() throws {
        let oldDir = tempDir.appendingPathComponent("番旧")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try makeFile("旧 EP01.mkv", in: oldDir)

        // 新目录里同时有两部番（两个子文件夹）
        let root = tempDir.appendingPathComponent("多番库")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let subA = root.appendingPathComponent("番A")
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try makeFile("番A EP01.mkv", in: subA)
        let subB = root.appendingPathComponent("番B")
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        try makeFile("番B EP01.mkv", in: subB)

        let library = MediaLibrary(storeURL: tempDir.appendingPathComponent("lib.json"))
        library.addFolder(oldDir.path)
        library.rescan()
        let oldKey = try XCTUnwrap(library.series.first?.seriesKey)

        // 目录里多部番、无法确定目标 → 返回 nil，旧条目与目录登记都不变
        XCTAssertNil(library.relocateSeries(oldSeriesKey: oldKey, to: root.path))
        XCTAssertEqual(library.series.count, 1)
        XCTAssertFalse(library.folders.contains(MediaLibrary.canonicalPath(root.path)),
                       "迁移失败不应留下新目录登记")
    }
}

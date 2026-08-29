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
}

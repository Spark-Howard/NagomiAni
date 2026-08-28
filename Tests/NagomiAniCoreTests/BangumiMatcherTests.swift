import XCTest
@testable import NagomiAniCore

final class BangumiMatcherTests: XCTestCase {

    private func makeSubject(id: Int, name: String, nameCN: String, total: Int?) -> Subject {
        Subject(
            id: id,
            type: .anime,
            name: name,
            nameCN: nameCN,
            summary: nil,
            airDate: nil,
            eps: nil,
            totalEpisodes: total,
            images: nil,
            rating: nil
        )
    }

    // MARK: - 相似度

    func testSimilarityExact() {
        XCTAssertEqual(TitleSimilarity.similarity("命运石之门", "命运石之门"), 1)
    }

    func testSimilarityContainment() {
        XCTAssertGreaterThan(TitleSimilarity.similarity("命运石之门", "命运石之门 0"), 0.8)
    }

    func testSimilarityDifferent() {
        XCTAssertLessThan(TitleSimilarity.similarity("命运石之门", "龙与虎"), 0.5)
    }

    func testSimilarityShortContainmentNoBoost() {
        // 短字符串（<4）包含不该触发 0.85 加分，避免 "D" 匹配到任意含 D 的条目
        XCTAssertLessThan(TitleSimilarity.similarity("D", "Dex"), 0.85)
        XCTAssertLessThan(TitleSimilarity.similarity("D", "魔法师同学"), 0.5)
    }

    // MARK: - 评分

    func testScoreHighForMatchWithEpisodeEvidence() {
        let subject = makeSubject(id: 1, name: "Steins;Gate", nameCN: "命运石之门", total: 25)
        let score = BangumiMatcher.score(subject: subject, against: "命运石之门", fileCount: 24)
        XCTAssertGreaterThan(score, 0.8)
    }

    func testScoreLowForMismatch() {
        let subject = makeSubject(id: 2, name: "Toradora!", nameCN: "龙与虎", total: 25)
        let score = BangumiMatcher.score(subject: subject, against: "命运石之门", fileCount: 24)
        XCTAssertLessThan(score, 0.4)
    }

    // MARK: - 季度评分

    func testSeasonMismatchPenalized() {
        // 本地是第二季，条目是第一季 → 应被扣分
        let subject = makeSubject(id: 1, name: "命运石之门 第一季", nameCN: "命运石之门 第一季", total: 25)
        let withSeason = BangumiMatcher.score(subject: subject, against: "命运石之门", fileCount: 24, localSeason: 2)
        let withoutSeason = BangumiMatcher.score(subject: subject, against: "命运石之门", fileCount: 24, localSeason: nil)
        XCTAssertLessThan(withSeason, withoutSeason)
    }

    func testSeasonMatchBoosted() {
        // 本地是第二季，条目是第二季（0 结尾续作）→ 应被加分
        let subject = makeSubject(id: 2, name: "命运石之门0", nameCN: "命运石之门0", total: 25)
        let match = BangumiMatcher.score(subject: subject, against: "命运石之门", fileCount: 24, localSeason: 2)
        let mismatch = BangumiMatcher.score(subject: subject, against: "命运石之门", fileCount: 24, localSeason: 1)
        XCTAssertGreaterThan(match, mismatch)
    }

    // MARK: - 文件名推导（不依赖目录名）

    func testSeriesHintUsesFileNames() {
        let files = [
            MediaFile(path: "/a/01.mkv", episodeNumber: 1, fileName: "[A组] 命运石之门 - 01 [1080p].mkv", fileSize: nil, modifiedAt: nil),
            MediaFile(path: "/a/02.mkv", episodeNumber: 2, fileName: "[A组] 命运石之门 - 02 [1080p].mkv", fileSize: nil, modifiedAt: nil),
            MediaFile(path: "/a/03.mkv", episodeNumber: 3, fileName: "[A组] 命运石之门 - 03 [1080p].mkv", fileSize: nil, modifiedAt: nil),
        ]
        // 目录名不可靠，但文件名准确
        let series = Series(seriesKey: "/a", displayName: "新建文件夹", files: files, subjectID: nil, matchState: .unmatched)
        let hint = BangumiMatcher.seriesHint(from: series)
        XCTAssertEqual(hint.title, "命运石之门")
        XCTAssertNil(hint.season)
    }

    func testSeriesHintSeasonFromFileNames() {
        let files = [
            MediaFile(path: "/b/01.mkv", episodeNumber: 1, fileName: "命运石之门 S2 01.mkv", fileSize: nil, modifiedAt: nil),
            MediaFile(path: "/b/02.mkv", episodeNumber: 2, fileName: "命运石之门 S2 02.mkv", fileSize: nil, modifiedAt: nil),
        ]
        let series = Series(seriesKey: "/b", displayName: "随便的目录", files: files, subjectID: nil, matchState: .unmatched)
        let hint = BangumiMatcher.seriesHint(from: series)
        XCTAssertEqual(hint.title, "命运石之门")
        XCTAssertEqual(hint.season, 2)
    }

    // MARK: - 搜索词

    func testSearchTitlesCleansTags() {
        let series = Series(
            seriesKey: "/库/番名",
            displayName: "[Demo] 番名 [1080p]",
            files: [],
            subjectID: nil,
            matchState: .unmatched
        )
        let titles = BangumiMatcher.searchTitles(series: series)
        XCTAssertTrue(titles.contains("番名"))
        XCTAssertFalse(titles.contains { $0.contains("1080p") })
        XCTAssertFalse(titles.contains { $0.contains("/") }, "搜索词不应包含文件路径")
    }

    func testSearchTitlesNoSpaceVariant() {
        let series = Series(
            seriesKey: "/库/Initial D",
            displayName: "Initial D",
            files: [],
            subjectID: nil,
            matchState: .unmatched
        )
        let titles = BangumiMatcher.searchTitles(series: series)
        XCTAssertTrue(titles.contains("Initial D"))
        XCTAssertTrue(titles.contains("InitialD"))
    }

    func testContainsCJK() {
        XCTAssertTrue(TitleTranslator.containsCJK("头文字D"))
        XCTAssertTrue(TitleTranslator.containsCJK("命运石之门"))
        XCTAssertFalse(TitleTranslator.containsCJK("Initial D"))
    }
}

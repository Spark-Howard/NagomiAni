import XCTest
@testable import NagomiAniCore

final class MediaMatchingTests: XCTestCase {

    func testEpisodeParsingCommonPatterns() {
        XCTAssertEqual(MediaMatching.parse(fileName: "[Demo] 命运石之门 - 01 [1080p].mkv").episodeNumber, 1)
        XCTAssertEqual(MediaMatching.parse(fileName: "命运石之门 EP12.mkv").episodeNumber, 12)
        XCTAssertEqual(MediaMatching.parse(fileName: "命运石之门 ep 3.mkv").episodeNumber, 3)
        XCTAssertEqual(MediaMatching.parse(fileName: "命运石之门 第5话.mkv").episodeNumber, 5)
        XCTAssertEqual(MediaMatching.parse(fileName: "命运石之门 第 12 集.mkv").episodeNumber, 12)
        XCTAssertEqual(MediaMatching.parse(fileName: "命运石之门 [06].mkv").episodeNumber, 6)
    }

    func testEpisodeParsingZeroPadded() {
        XCTAssertEqual(MediaMatching.parse(fileName: "番名 - 007 [1080p].mkv").episodeNumber, 7)
        XCTAssertEqual(MediaMatching.parse(fileName: "番名 EP001.mkv").episodeNumber, 1)
    }

    func testEpisodeParsingNone() {
        XCTAssertNil(MediaMatching.parse(fileName: "剧场版 命运石之门.mkv").episodeNumber)
        XCTAssertNil(MediaMatching.parse(fileName: "命运石之门 特典.mkv").episodeNumber)
        XCTAssertNil(MediaMatching.parse(fileName: "2024 - 合集.mkv").episodeNumber, "年份不应被当成集数")
    }

    func testEpisodeParsingBareNumbers() {
        XCTAssertEqual(MediaMatching.parse(fileName: "01.mkv").episodeNumber, 1)
        XCTAssertEqual(MediaMatching.parse(fileName: "12.mkv").episodeNumber, 12)
        XCTAssertEqual(MediaMatching.parse(fileName: "01 - 标题.mkv").episodeNumber, 1)
        XCTAssertEqual(MediaMatching.parse(fileName: "01.标题.mkv").episodeNumber, 1)
    }

    // MARK: - 动漫圈常用命名格式

    func testEpisodeParsingAnimeFormats() {
        // SxxExx（季+集）
        XCTAssertEqual(MediaMatching.parse(fileName: "[Sub] 葬送的芙莉莲 S01E01 [1080p].mkv").episodeNumber, 1)
        XCTAssertEqual(MediaMatching.parse(fileName: "[Sub] Show S2E12 [1080p].mkv").episodeNumber, 12)
        XCTAssertEqual(MediaMatching.parse(fileName: "[Sub] Show S01 E03 [1080p].mkv").episodeNumber, 3)
        // 单 E 格式
        XCTAssertEqual(MediaMatching.parse(fileName: "[Sub] Show E03 [1080p].mkv").episodeNumber, 3)
        // EP 点分隔
        XCTAssertEqual(MediaMatching.parse(fileName: "[Sub] Show EP.05 [1080p].mkv").episodeNumber, 5)
        // 日文"話"
        XCTAssertEqual(MediaMatching.parse(fileName: "Show 第3話.mkv").episodeNumber, 3)
        // # 号
        XCTAssertEqual(MediaMatching.parse(fileName: "Show #07.mkv").episodeNumber, 7)
        // v 修正版
        XCTAssertEqual(MediaMatching.parse(fileName: "[Sub] Show - 03v2 [1080p].mkv").episodeNumber, 3)
        XCTAssertEqual(MediaMatching.parse(fileName: "03v2.mkv").episodeNumber, 3)
        // 无标签的 "- 数字"
        XCTAssertEqual(MediaMatching.parse(fileName: "Show - 04.mkv").episodeNumber, 4)
    }

    func testEpisodeParsingAnimeFormatsNoFalsePositive() {
        XCTAssertNil(MediaMatching.parse(fileName: "Show - 2011.mkv").episodeNumber, "年份不应误判为集数")
        XCTAssertNil(MediaMatching.parse(fileName: "Show - 08.5.mkv").episodeNumber, "小数集号（SP）暂不解析为整数集")
        XCTAssertNil(MediaMatching.parse(fileName: "2024 - 合集.mkv").episodeNumber)
    }

    // MARK: - 真实字幕组命名回归

    func testEpisodeParsingRealWorldFiles() {
        // "S2 01"：季号+空格+集号，; 分隔标签、_ 连接标签
        XCTAssertEqual(
            MediaMatching.parse(fileName: "Initial D. TV S2 01; 1080P_BD_H265_FLAC.mkv").episodeNumber,
            1
        )
        XCTAssertEqual(
            MediaMatching.parse(fileName: "Initial D. TV S2 02; 1080P_BD_H265_FLAC.mkv").episodeNumber,
            2
        )
        // S2 01 变体分隔符
        XCTAssertEqual(MediaMatching.parse(fileName: "Show S2-01.mkv").episodeNumber, 1)
        XCTAssertEqual(MediaMatching.parse(fileName: "Show S2.01.mkv").episodeNumber, 1)
        // 季号识别
        XCTAssertEqual(MediaMatching.seasonNumber(from: "Initial D. TV S2 01"), 2)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "Initial D. TV S2 01; 1080P_BD_H265_FLAC"), 2)
        // 常规字幕组格式
        XCTAssertEqual(
            MediaMatching.parse(
                fileName: "[Nekomoe kissaten&LoliHouse] BanG Dream! Ave Mujica - 02 [WebRip 1080p HEVC-10bit AAC ASSx2].mkv"
            ).episodeNumber,
            2
        )
        XCTAssertEqual(
            MediaMatching.parse(
                fileName: "[VCB-Studio] ReLIFE [01][Ma10p_1080p][x265_flac].mkv"
            ).episodeNumber,
            1
        )
        // S2 01 系列的 seriesKey 聚合（不同集 → 同一部番）
        let keyA = MediaMatching.parse(fileName: "Initial D. TV S2 01; 1080P_BD_H265_FLAC.mkv").seriesKey
        let keyB = MediaMatching.parse(fileName: "Initial D. TV S2 02; 1080P_BD_H265_FLAC.mkv").seriesKey
        XCTAssertEqual(keyA, keyB)
    }

    func testSeriesKeyGroupsEpisodes() {
        let key1 = MediaMatching.parse(fileName: "[Demo] 命运石之门 - 01 [1080p].mkv").seriesKey
        let key2 = MediaMatching.parse(fileName: "[Demo] 命运石之门 - 12 [1080p].mkv").seriesKey
        XCTAssertEqual(key1, key2)
        XCTAssertFalse(key1.isEmpty)

        let other = MediaMatching.parse(fileName: "[Demo] 命运石之门0 - 01 [1080p].mkv").seriesKey
        XCTAssertNotEqual(key1, other, "不同作品不应归为一组")
    }

    func testCrossFansubMerge() {
        let key1 = MediaMatching.parse(fileName: "[A字幕组] 番名 - 01 [1080p].mkv").seriesKey
        let key2 = MediaMatching.parse(fileName: "[B字幕组] 番名 - 02 [720p][x265].mkv").seriesKey
        XCTAssertEqual(key1, key2, "不同字幕组/画质的同一部番应聚合")
    }

    func testSeriesKeyStripsTags() {
        let key = MediaMatching.parse(fileName: "[Demo] 番名 - 01 [1080p][x265][简日].mkv").seriesKey
        XCTAssertFalse(key.contains("1080p"))
        XCTAssertFalse(key.contains("x265"))
        XCTAssertFalse(key.contains("简日"))
        XCTAssertFalse(key.contains("["))
    }

    // MARK: - 季度识别

    func testSeasonParsing() {
        XCTAssertEqual(MediaMatching.seasonNumber(from: "命运石之门 S1"), 1)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "Initial D S02"), 2)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "Initial D Season 2"), 2)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "命运石之门 第二季"), 2)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "命运石之门 第3季"), 3)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "XXX Part 2"), 2)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "XXX II"), 2)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "命运石之门0"), 2)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "命运石之门"), nil)
        XCTAssertEqual(MediaMatching.seasonNumber(from: "2020 合集"), nil, "年份末尾 0 不应误判为续作")
    }

    func testBaseTitleStripsSeason() {
        XCTAssertEqual(MediaMatching.baseTitle(from: "命运石之门 第二季"), "命运石之门")
        XCTAssertEqual(MediaMatching.baseTitle(from: "Initial D S2"), "Initial D")
        XCTAssertEqual(MediaMatching.baseTitle(from: "命运石之门0"), "命运石之门")
        XCTAssertEqual(MediaMatching.baseTitle(from: "命运石之门"), "命运石之门")
    }

    // MARK: - 文件名推导标题

    func testTitleHint() {
        XCTAssertEqual(MediaMatching.titleHint(from: "[Demo] 命运石之门 - 01 [1080p].mkv"), "命运石之门")
        XCTAssertEqual(MediaMatching.titleHint(from: "命运石之门 01.mkv"), "命运石之门")
        XCTAssertEqual(MediaMatching.titleHint(from: "86 - 01.mkv"), "86", "纯数字番名不应被剥掉")
        XCTAssertEqual(MediaMatching.titleHint(from: "命运石之门 S2 01.mkv"), "命运石之门")
        XCTAssertEqual(MediaMatching.titleHint(from: "命运石之门 第2季 03.mkv"), "命运石之门")
    }
}

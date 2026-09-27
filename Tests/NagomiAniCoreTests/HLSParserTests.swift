import XCTest
@testable import NagomiAniCore

final class HLSParserTests: XCTestCase {
    func testMediaPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXTINF:9.009,
        seg-0.ts
        #EXTINF:9.509,
        seg-1.ts
        #EXTINF:8.007,
        seg-2.ts
        #EXT-X-ENDLIST
        """
        let playlist = try HLSParser.parse(text)
        XCTAssertEqual(playlist.kind, .media)
        XCTAssertEqual(playlist.segments.count, 3)
        XCTAssertEqual(playlist.segments[0].uri, "seg-0.ts")
        XCTAssertEqual(playlist.segments[0].duration, 9.009, accuracy: 0.0001)
        XCTAssertEqual(playlist.segments[2].duration, 8.007, accuracy: 0.0001)
        XCTAssertEqual(playlist.targetDuration, 10)
        XCTAssertTrue(playlist.isVOD)
        XCTAssertNil(playlist.initSegmentURI)
        XCTAssertTrue(playlist.variants.isEmpty)
    }

    func testMediaPlaylistWithInitSegment() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        chunk-0.m4s
        #EXT-X-ENDLIST
        """
        let playlist = try HLSParser.parse(text)
        XCTAssertEqual(playlist.kind, .media)
        XCTAssertEqual(playlist.initSegmentURI, "init.mp4")
        XCTAssertEqual(playlist.segments.map(\.uri), ["chunk-0.m4s"])
    }

    func testMasterPlaylist() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720,NAME="720p"
        720p/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=512000,RESOLUTION=640x360,NAME="360p"
        360p/index.m3u8
        """
        let playlist = try HLSParser.parse(text)
        XCTAssertEqual(playlist.kind, .master)
        XCTAssertEqual(playlist.variants.count, 2)
        XCTAssertEqual(playlist.variants[0].bandwidth, 1_280_000)
        XCTAssertEqual(playlist.variants[0].width, 1280)
        XCTAssertEqual(playlist.variants[0].height, 720)
        XCTAssertEqual(playlist.variants[0].name, "720p")
        XCTAssertEqual(playlist.variants[1].uri, "360p/index.m3u8")
        // master 不带分片信息
        XCTAssertTrue(playlist.segments.isEmpty)
        XCTAssertNil(playlist.targetDuration)
    }

    func testBestVariantPicksHighestBandwidth() throws {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=512000,NAME="360p"
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1280000,NAME="720p"
        high.m3u8
        """
        let playlist = try HLSParser.parse(text)
        XCTAssertEqual(HLSParser.bestVariant(in: playlist)?.uri, "high.m3u8")
    }

    func testNotAPlaylistThrows() {
        XCTAssertThrowsError(try HLSParser.parse("<html>404</html>")) { error in
            XCTAssertEqual(error as? HLSError, .notAPlaylist)
        }
        XCTAssertThrowsError(try HLSParser.parse(""))
    }

    func testPlaylistWithoutEntriesThrows() {
        XCTAssertThrowsError(try HLSParser.parse("#EXTM3U\n")) { error in
            XCTAssertEqual(error as? HLSError, .emptyPlaylist)
        }
    }

    func testResolveRelativeAndAbsolute() throws {
        let base = URL(string: "https://example.com/vod/ep1/index.m3u8")!
        XCTAssertEqual(HLSParser.resolve("seg-0.ts", against: base)?.absoluteString,
                       "https://example.com/vod/ep1/seg-0.ts")
        XCTAssertEqual(HLSParser.resolve("../shared/init.mp4", against: base)?.absoluteString,
                       "https://example.com/vod/shared/init.mp4")
        XCTAssertEqual(HLSParser.resolve("https://cdn.example.com/a.ts", against: base)?.absoluteString,
                       "https://cdn.example.com/a.ts")
    }

    func testAttributeParsing() {
        let attrs = "BANDWIDTH=1280000,RESOLUTION=1280x720,NAME=\"720p\",CODECS=\"avc1.64001f,mp4a.40.2\""
        XCTAssertEqual(HLSParser.attribute(attrs, name: "BANDWIDTH"), "1280000")
        XCTAssertEqual(HLSParser.attribute(attrs, name: "NAME"), "720p")
        XCTAssertEqual(HLSParser.attribute(attrs, name: "name"), "720p") // 大小写不敏感
        XCTAssertNil(HLSParser.attribute(attrs, name: "SUBTITLES"))
        XCTAssertEqual(HLSParser.resolution(attrs)?.width, 1280)
        XCTAssertEqual(HLSParser.resolution(attrs)?.height, 720)
    }

    func testURLEndingExtensionHelper() {
        XCTAssertEqual(StreamCache.urlExtension("seg-0.ts?token=abc", fallback: "ts"), "ts")
        XCTAssertEqual(StreamCache.urlExtension("chunk-1.m4s", fallback: "ts"), "m4s")
        XCTAssertEqual(StreamCache.urlExtension("noext", fallback: "ts"), "ts")
        XCTAssertEqual(StreamCache.urlExtension("video.MP4", fallback: "ts"), "mp4")
        // 裸 ".MP4"（无主名）按隐藏文件语义拿不到扩展名 → 走 fallback
        XCTAssertEqual(StreamCache.urlExtension(".MP4", fallback: "ts"), "ts")
    }
}

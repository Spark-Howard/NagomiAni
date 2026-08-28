import XCTest
@testable import NagomiAniCore

final class BangumiModelsTests: XCTestCase {

    /// 搜索响应中某个字段类型异常（如 rating.count 是对象）时，不应导致整体解析失败
    func testSubjectLenientDecoding() throws {
        let json = """
        {"data":[{"id":1,"name":"Test","name_cn":null,"type":null,"rating":{"count":{"1":2}},"images":null}],"total":1,"limit":10,"offset":0}
        """
        let page = try JSONDecoder().decode(Paged<Subject>.self, from: Data(json.utf8))
        XCTAssertEqual(page.data.count, 1)
        XCTAssertEqual(page.data.first?.id, 1)
        XCTAssertNil(page.data.first?.rating, "类型异常的 rating 应降级为 nil 而非抛错")
    }

    /// 枚举未知值不崩溃
    func testUnknownEnumValues() throws {
        let json = """
        {"id":5,"type":99,"name":"x","name_cn":"x","eps":null,"total_episodes":null,"images":null,"rating":null}
        """
        let subject = try JSONDecoder().decode(Subject.self, from: Data(json.utf8))
        XCTAssertEqual(subject.type, .unknown)
    }
}

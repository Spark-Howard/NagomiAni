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

    /// 旧版大条目解码（eps/topic/blog/crt/staff/collection，来自真实 API 数据精简）
    func testLegacySubjectDecoding() throws {
        let json = """
        {
          "id": 8, "type": 2,
          "name": "コードギアス 反逆のルルーシュR2",
          "name_cn": "Code Geass 反叛的鲁路修R2",
          "summary": "东京决战一年后……",
          "rank": 85,
          "rating": {"total": 18694, "count": {"10": 3059, "8": 6161}, "score": 8.3},
          "collection": {"wish": 2348, "collect": 29366, "doing": 500, "on_hold": 488, "dropped": 180},
          "images": {"common": "http://x/img.jpg", "large": "http://x/l.jpg"},
          "eps": [
            {"id": 522, "type": 0, "sort": 1, "name": "魔神 が 目覚める 日", "name_cn": "魔王的苏醒之日", "airdate": "2008-04-06", "duration": "24m", "comment": 45, "desc": "……", "status": "Air"},
            {"id": 523, "type": 0, "sort": 2, "name": "日本独立計画", "name_cn": "日本独立计划", "airdate": "2008-04-13"}
          ],
          "topic": [
            {"id": 31228, "url": "http://bgm.tv/subject/topic/31228", "title": "讨论标题", "main_id": 8, "timestamp": 1722409807, "lastpost": 1745668674, "replies": 4,
             "user": {"id": 525910, "nickname": "前原御子", "avatar": {"small": "http://x/a.jpg"}}}
          ],
          "blog": [
            {"id": 373490, "url": "http://bgm.tv/blog/373490", "title": "从困惑、愤怒到和解", "summary": "摘要……", "replies": 0, "timestamp": 1778323419,
             "user": {"nickname": "風"}}
          ],
          "crt": [
            {"id": 1, "name": "ルルーシュ", "name_cn": "鲁路修", "role_name": "主角", "images": {"grid": "http://x/g.jpg"}}
          ],
          "staff": [
            {"id": 185, "name": "谷口悟朗", "name_cn": "谷口悟朗", "role_name": "", "jobs": ["导演"]}
          ]
        }
        """.data(using: .utf8)!

        let legacy = try JSONDecoder().decode(LegacySubject.self, from: json)
        XCTAssertEqual(legacy.id, 8)
        XCTAssertEqual(legacy.eps?.count, 2)
        XCTAssertEqual(legacy.eps?.first?.sort, 1)
        XCTAssertEqual(legacy.eps?.first?.nameCN, "魔王的苏醒之日")
        XCTAssertEqual(legacy.topic?.count, 1)
        XCTAssertEqual(legacy.topic?.first?.title, "讨论标题")
        XCTAssertEqual(legacy.topic?.first?.replies, 4)
        XCTAssertEqual(legacy.blog?.first?.user?.nickname, "風")
        XCTAssertEqual(legacy.crt?.first?.roleName, "主角")
        XCTAssertEqual(legacy.staff?.first?.jobs?.first, "导演")
        XCTAssertEqual(legacy.collection?.collect, 29366)
        XCTAssertEqual(legacy.rating?.count?["10"], 3059)
    }

    /// v0 详情接口的 infobox（value 可能是字符串 / 数组 / {v} 对象数组）
    func testSubjectInfoboxDecoding() throws {
        let json = """
        {"id": 8,
         "infobox": [
           {"key": "中文名", "value": "Code Geass 反叛的鲁路修R2"},
           {"key": "别名", "value": [{"v": "叛逆的鲁路修R2"}, {"v": "コードギアス 反逆のルルーシュR2"}]},
           {"key": "话数", "value": "25"},
           {"key": "放送开始", "value": "2008年4月6日"}
         ],
         "tags": [{"name": "SUNRISE", "count": 2339}],
         "collection": {"wish": 1, "collect": 2, "doing": 3, "on_hold": 4, "dropped": 5}
        }
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertEqual(subject.infobox?.count, 4)
        XCTAssertEqual(subject.infobox?.first?.key, "中文名")
        if case .string(let value)? = subject.infobox?.first?.value {
            XCTAssertEqual(value, "Code Geass 反叛的鲁路修R2")
        } else {
            XCTFail("infobox value 应解析为字符串")
        }
        if case .values(let aliases)? = subject.infobox?[1].value {
            XCTAssertEqual(aliases, ["叛逆的鲁路修R2", "コードギアス 反逆のルルーシュR2"])
        } else {
            XCTFail("别名应解析为 {v} 对象数组")
        }
        XCTAssertEqual(subject.tags?.first?.name, "SUNRISE")
        XCTAssertEqual(subject.collection?.doing, 3)
    }
}

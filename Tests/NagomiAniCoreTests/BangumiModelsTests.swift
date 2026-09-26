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

    /// 图片 URL：bgm.tv 系主机的明文 http 应升为 https（打包版 App 受 ATS 约束，
    /// 若不解码时升级，http 封面在打包版里会全部加载失败）；其它主机原样保留
    func testImageURLsUpgradedToHTTPS() throws {
        let json = """
        {"id": 456080,
         "images": {
            "large": "http://lain.bgm.tv/pic/cover/l/ce/e2/456080_C4q4C.jpg",
            "common": "https://lain.bgm.tv/pic/cover/c/ce/e2/456080_C4q4C.jpg",
            "medium": "http://other.example.com/m.jpg"
         }}
        """.data(using: .utf8)!
        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertEqual(subject.images?.large, "https://lain.bgm.tv/pic/cover/l/ce/e2/456080_C4q4C.jpg")
        XCTAssertEqual(subject.images?.common, "https://lain.bgm.tv/pic/cover/c/ce/e2/456080_C4q4C.jpg", "已是 https 的不应改动")
        XCTAssertEqual(subject.images?.medium, "http://other.example.com/m.jpg", "非 bgm.tv 主机不升级")
        XCTAssertNil(subject.images?.small)
        XCTAssertNil(subject.images?.grid)
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

    // MARK: - 展示名回退（回归：收藏列表"有的条目不显示名称"）

    /// Bangumi 对尚无中文名的条目会返回 `name_cn: ""`（空串而非 null）。
    /// 用 `nameCN ?? name` 会把空串当有效值渲染成空白，必须走 displayName。
    func testDisplayNameFallsBackWhenNameCNIsEmptyString() throws {
        let json = """
        {"id": 454684, "name": "BanG Dream! Ave Mujica", "name_cn": ""}
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertEqual(subject.nameCN, "")
        XCTAssertEqual(subject.displayName, "BanG Dream! Ave Mujica",
                       "name_cn 为空串时必须回退到原名，而不是显示空白")
    }

    /// 仅有空白字符的 name_cn 同样视为缺失
    func testDisplayNameTreatsWhitespaceOnlyAsMissing() throws {
        let json = """
        {"id": 1, "name": "OnlyRomaji", "name_cn": "   "}
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertEqual(subject.displayName, "OnlyRomaji")
    }

    /// 有中文名时优先用中文名（并去掉首尾空白）
    func testDisplayNamePrefersChineseName() throws {
        let json = """
        {"id": 3816, "name": "頭文字D Fourth Stage", "name_cn": " 头文字D Fourth Stage "}
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertEqual(subject.displayName, "头文字D Fourth Stage")
    }

    /// 两个名字都缺失时返回空串（由调用方决定占位文案）
    func testDisplayNameEmptyWhenBothMissing() throws {
        let json = """
        {"id": 2, "name": null, "name_cn": null}
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertEqual(subject.displayName, "")
    }

    /// 收藏接口返回的嵌套 subject 也走同一套回退
    func testCollectionSubjectDisplayNameWithEmptyNameCN() throws {
        let json = """
        {"subject_id": 454684, "type": 3,
         "subject": {"name": "BanG Dream! Ave Mujica", "name_cn": "", "images": {}}}
        """.data(using: .utf8)!

        let collection = try JSONDecoder().decode(UserSubjectCollection.self, from: json)
        XCTAssertEqual(collection.subject?.displayName, "BanG Dream! Ave Mujica")
    }

    /// Episode 等其它条目模型共用同一回退规则
    func testEpisodeDisplayNameWithEmptyNameCN() throws {
        let json = """
        {"id": 1, "name": "第1话 素晴らしい世界", "name_cn": ""}
        """.data(using: .utf8)!

        let episode = try JSONDecoder().decode(Episode.self, from: json)
        XCTAssertEqual(episode.displayName, "第1话 素晴らしい世界")
    }

    // MARK: - 总集数回退（回归：进度显示"总共 0 集"）

    /// 收藏列表接口只给 `eps`，不给 `total_episodes`。
    /// 直接读 totalEpisodes 会得到 nil → 界面显示 0 集。
    func testEpisodeCountFallsBackToEpsWhenTotalEpisodesMissing() throws {
        let json = """
        {"id": 454684, "name": "BanG Dream! Ave Mujica", "eps": 13}
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertNil(subject.totalEpisodes, "收藏列表接口不返回 total_episodes")
        XCTAssertEqual(subject.eps, 13)
        XCTAssertEqual(subject.episodeCount, 13, "必须回退到 eps，否则显示成 0 集")
    }

    /// 详情接口两个字段都有时，以 total_episodes 为准
    func testEpisodeCountPrefersTotalEpisodes() throws {
        let json = """
        {"id": 1, "name": "X", "eps": 13, "total_episodes": 13}
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertEqual(subject.episodeCount, 13)
    }

    /// 两个都没有时返回 nil（界面用"进度 x 集"而不是误导性的 /0）
    func testEpisodeCountNilWhenBothMissing() throws {
        let json = """
        {"id": 2, "name": "未定档新番"}
        """.data(using: .utf8)!

        let subject = try JSONDecoder().decode(Subject.self, from: json)
        XCTAssertNil(subject.episodeCount)
    }

    /// 完整链路：收藏列表返回的真实形态能算出正确集数
    func testCollectionRowEpisodeCountFromRealListShape() throws {
        let json = """
        {"subject_id": 454684, "type": 3, "ep_status": 1,
         "subject": {"id": 454684, "name": "BanG Dream! Ave Mujica", "name_cn": "",
                     "eps": 13, "type": 2, "images": {"common": "https://lain.bgm.tv/x.jpg"}}}
        """.data(using: .utf8)!

        let collection = try JSONDecoder().decode(UserSubjectCollection.self, from: json)
        XCTAssertEqual(collection.epStatus, 1)
        XCTAssertEqual(collection.subject?.episodeCount, 13)
        // 空 name_cn 也要能显示名字（上一轮修复）
        XCTAssertEqual(collection.subject?.displayName, "BanG Dream! Ave Mujica")
    }

    // MARK: - 封面分辨率挑选（回归：缩略图发糊）

    private func decodeImages(_ json: String) throws -> Subject.SubjectImages {
        try JSONDecoder().decode(Subject.SubjectImages.self, from: Data(json.utf8))
    }

    /// 真实 API 形态：large 是原图，其余是 /r/N 缩放版
    private let realImagesJSON = """
    {"large": "https://lain.bgm.tv/pic/cover/l/77/c3/454684_ZH5tU.jpg",
     "common": "https://lain.bgm.tv/r/400/pic/cover/l/77/c3/454684_ZH5tU.jpg",
     "medium": "https://lain.bgm.tv/r/800/pic/cover/l/77/c3/454684_ZH5tU.jpg",
     "small": "https://lain.bgm.tv/r/200/pic/cover/l/77/c3/454684_ZH5tU.jpg",
     "grid": "https://lain.bgm.tv/r/100/pic/cover/l/77/c3/454684_ZH5tU.jpg"}
    """

    /// 3x 屏上的 112×152pt 卡片：原实现只拿 common(400px)，仅比所需 336px 多 19%，会发糊。
    /// 必须升到 medium(800px)。
    func testBestURLUpgradesToMediumFor3xWeekCard() throws {
        let images = try decodeImages(realImagesJSON)
        let url = images.bestURL(targetHeight: 152, scale: 3, headroom: 1.6)
        XCTAssertEqual(url, "https://lain.bgm.tv/r/800/pic/cover/l/77/c3/454684_ZH5tU.jpg")
    }

    /// 默认余量下，2x 屏的 112×152pt 卡片用 common 即可（不必浪费流量上 medium）
    func testBestURLKeepsCommonFor2xWeekCardAtDefaultHeadroom() throws {
        let images = try decodeImages(realImagesJSON)
        let url = images.bestURL(targetHeight: 152, scale: 2)
        XCTAssertEqual(url, "https://lain.bgm.tv/r/400/pic/cover/l/77/c3/454684_ZH5tU.jpg")
    }

    /// 小缩略图（44×60pt）应挑更小的档，不要拉大图
    func testBestURLPicksSmallVariantForTinyThumbnail() throws {
        let images = try decodeImages(realImagesJSON)
        let url = images.bestURL(targetHeight: 60, scale: 2)
        XCTAssertEqual(url, "https://lain.bgm.tv/r/200/pic/cover/l/77/c3/454684_ZH5tU.jpg")
    }

    /// 1x 屏不需要大图
    func testBestURLPicksGridFor1xSmallCard() throws {
        let images = try decodeImages(realImagesJSON)
        let url = images.bestURL(targetHeight: 60, scale: 1, headroom: 1.0)
        XCTAssertEqual(url, "https://lain.bgm.tv/r/100/pic/cover/l/77/c3/454684_ZH5tU.jpg")
    }

    /// 换档必须保持"同一张图"：只改 r/N，路径不变
    func testBestURLKeepsSameImagePathWhenSwitchingVariant() throws {
        let images = try decodeImages(realImagesJSON)
        let url = images.bestURL(targetHeight: 152, scale: 3, headroom: 1.6)
        XCTAssertTrue(url?.contains("/pic/cover/l/77/c3/454684_ZH5tU.jpg") == true,
                      "换档不能把图片路径改掉")
    }

    /// 超大尺寸（超过原图）就回退到 large 原图
    func testBestURLFallsBackToLargeWhenNeeded() throws {
        let images = try decodeImages(realImagesJSON)
        let url = images.bestURL(targetHeight: 600, scale: 3, headroom: 2.0)
        XCTAssertEqual(url, "https://lain.bgm.tv/pic/cover/l/77/c3/454684_ZH5tU.jpg")
    }

    /// 没有 large（无法安全换档）时回退到原 common，不能返回 nil
    func testBestURLFallsBackToCommonWithoutLarge() throws {
        let images = try decodeImages(#"{"common":"https://lain.bgm.tv/r/400/pic/cover/l/1.jpg"}"#)
        XCTAssertEqual(images.bestURL(targetHeight: 152, scale: 3),
                       "https://lain.bgm.tv/r/400/pic/cover/l/1.jpg")
    }

    /// 非 bgm 主机的 URL 不应被拼改
    func testBestURLDoesNotRewriteForeignHost() throws {
        let images = try decodeImages(#"{"large":"https://example.com/a/b.jpg","common":"https://example.com/r/400/a/b.jpg"}"#)
        let url = images.bestURL(targetHeight: 152, scale: 3, headroom: 1.6)
        XCTAssertEqual(url, "https://example.com/r/400/a/b.jpg")
    }

    /// 完全没有图片信息时返回 nil（界面显示占位）
    func testBestURLNilWhenNoImages() throws {
        let images = try decodeImages("{}")
        XCTAssertNil(images.bestURL(targetHeight: 152, scale: 2))
    }
}

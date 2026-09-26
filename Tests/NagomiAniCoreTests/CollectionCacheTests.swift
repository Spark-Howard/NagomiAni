import XCTest
@testable import NagomiAniCore

/// 收藏列表缓存（「想看」↔「看过」切换秒开 + 后台核对）的行为测试
final class CollectionCacheTests: XCTestCase {

    // MARK: - 构造辅助

    private func makeSubject(
        id: Int,
        name: String,
        nameCN: String? = nil,
        totalEpisodes: Int? = 12
    ) -> Subject {
        Subject(
            id: id,
            type: .anime,
            name: name,
            nameCN: nameCN,
            summary: nil,
            airDate: nil,
            eps: nil,
            totalEpisodes: totalEpisodes,
            images: nil,
            rating: nil
        )
    }

    private func makeCollection(
        id: Int,
        type: SubjectCollectionType,
        epStatus: Int? = 0,
        subject: Subject? = nil
    ) -> UserSubjectCollection {
        UserSubjectCollection(
            subjectID: id,
            subjectType: .anime,
            type: type,
            epStatus: epStatus,
            subject: subject
        )
    }

    // MARK: - 秒开

    /// 写入缓存后应能立刻取出，且内容一致
    func testStoreThenPageReturnsCachedList() {
        var cache = CollectionCache()
        let list = [makeCollection(id: 1, type: .wish), makeCollection(id: 2, type: .wish)]

        cache.store(list, for: .wish)

        let page = cache.page(for: .wish)
        XCTAssertEqual(page?.raw.count, 2)
        XCTAssertEqual(page?.enriched.count, 2)
    }

    /// 没有缓存的类型取不到（首次进入应走网络）
    func testPageIsNilWhenNotCached() {
        let cache = CollectionCache()
        XCTAssertNil(cache.page(for: .collected))
        XCTAssertTrue(cache.needsRefresh(.collected))
    }

    /// 不同类型互不干扰：切换类型各自命中自己的缓存
    func testTypesAreCachedIndependently() {
        var cache = CollectionCache()
        cache.store([makeCollection(id: 1, type: .wish)], for: .wish)
        cache.store([makeCollection(id: 2, type: .doing), makeCollection(id: 3, type: .doing)], for: .doing)

        XCTAssertEqual(cache.page(for: .wish)?.raw.count, 1)
        XCTAssertEqual(cache.page(for: .doing)?.raw.count, 2)
        XCTAssertNil(cache.page(for: .collected))
    }

    // MARK: - 新鲜度（决定要不要后台刷新）

    func testFreshCacheDoesNotNeedRefresh() {
        var cache = CollectionCache(ttl: 300)
        let now = Date()
        cache.store([makeCollection(id: 1, type: .wish)], for: .wish, at: now)

        XCTAssertTrue(cache.isFresh(.wish, now: now))
        XCTAssertFalse(cache.needsRefresh(.wish, now: now))
    }

    /// 刚写入的缓存立即判定为"新鲜"——这正是"切回去直接加载、不刷新"的依据
    func testJustStoredCacheIsFresh() {
        var cache = CollectionCache(ttl: 300)
        cache.store([makeCollection(id: 1, type: .wish)], for: .wish)
        XCTAssertFalse(cache.needsRefresh(.wish))
    }

    /// 超过 TTL 的缓存需要后台核对（能发现新改动）
    func testStaleCacheNeedsRefresh() {
        var cache = CollectionCache(ttl: 300)
        let old = Date().addingTimeInterval(-301)
        cache.store([makeCollection(id: 1, type: .wish)], for: .wish, at: old)

        XCTAssertFalse(cache.isFresh(.wish))
        XCTAssertTrue(cache.needsRefresh(.wish))
        // 过期也仍然能秒开：先给内容，再后台刷新
        XCTAssertEqual(cache.page(for: .wish)?.raw.count, 1)
    }

    /// 边界：正好等于 TTL 仍算新鲜
    func testExactlyTTLIsStillFresh() {
        var cache = CollectionCache(ttl: 300)
        let now = Date()
        cache.store([makeCollection(id: 1, type: .wish)], for: .wish, at: now.addingTimeInterval(-300))
        XCTAssertTrue(cache.isFresh(.wish, now: now))
    }

    // MARK: - 条目详情跨类型共享

    /// 同一部番在「在看」缓存过详情后，切到「看过」应能直接补上，无需再请求
    func testSubjectDetailIsSharedAcrossTypes() {
        var cache = CollectionCache()
        let subject = makeSubject(id: 454684, name: "BanG Dream! Ave Mujica")
        cache.remember(subject)

        // 列表接口不返回详情（subject = nil）
        let list = [makeCollection(id: 454684, type: .collected)]
        XCTAssertNil(list[0].subject)

        let enriched = cache.enrich(list)
        XCTAssertEqual(enriched[0].subject?.displayName, "BanG Dream! Ave Mujica")
    }

    /// 详情缺失时不应被补成 nil 之外的东西，原样返回
    func testEnrichLeavesUnknownSubjectUntouched() {
        let cache = CollectionCache()
        let list = [makeCollection(id: 999, type: .wish)]
        let enriched = cache.enrich(list)
        XCTAssertNil(enriched[0].subject)
        XCTAssertEqual(enriched[0].subjectID, 999)
    }

    /// 已经从接口拿到详情的条目不会被缓存覆盖
    func testEnrichDoesNotOverrideEmbeddedSubject() {
        var cache = CollectionCache()
        cache.remember(makeSubject(id: 1, name: "缓存里的名字"))
        let list = [makeCollection(id: 1, type: .wish, subject: makeSubject(id: 1, name: "列表自带的名字"))]

        let enriched = cache.enrich(list)
        XCTAssertEqual(enriched[0].subject?.name, "列表自带的名字")
    }

    /// store 会自动补全，所以 enriched 版应当带详情
    func testStoreEnrichesWithRememberedSubjects() {
        var cache = CollectionCache()
        cache.remember(makeSubject(id: 7, name: "作品七"))
        cache.store([makeCollection(id: 7, type: .doing)], for: .doing)
        XCTAssertEqual(cache.page(for: .doing)?.enriched[0].subject?.name, "作品七")
    }

    /// 已缓存类型都能被重新补全（后台补完详情后调用）
    func testReEnrichAllUpdatesEveryCachedType() {
        var cache = CollectionCache()
        cache.store([makeCollection(id: 5, type: .wish)], for: .wish)
        cache.store([makeCollection(id: 5, type: .collected)], for: .collected)
        XCTAssertNil(cache.page(for: .wish)?.enriched[0].subject)

        cache.remember(makeSubject(id: 5, name: "作品五"))
        cache.reEnrichAll()

        XCTAssertEqual(cache.page(for: .wish)?.enriched[0].subject?.name, "作品五")
        XCTAssertEqual(cache.page(for: .collected)?.enriched[0].subject?.name, "作品五")
    }

    // MARK: - 需要补详情的条目

    /// 只对缺详情的条目发请求，并遵守上限（避免打爆 bgm.tv 频率限制）
    func testMissingSubjectIDsOnlyIncludesThoseWithoutSubject() {
        let cache = CollectionCache()
        let list = [
            makeCollection(id: 1, type: .wish, subject: makeSubject(id: 1, name: "有详情")),
            makeCollection(id: 2, type: .wish),
            makeCollection(id: 3, type: .wish),
        ]
        XCTAssertEqual(cache.missingSubjectIDs(in: list), [2, 3])
    }

    /// 已经有 subject 的条目**不再**补详情 —— 收藏列表虽不带 total_episodes，
    /// 但带了等价的 eps，显示集数不需要额外请求
    func testMissingSubjectIDsSkipsEntriesThatAlreadyHaveSubject() {
        let cache = CollectionCache()
        let list = [
            makeCollection(id: 1, type: .wish, subject: makeSubject(id: 1, name: "有详情", totalEpisodes: 12)),
            makeCollection(id: 2, type: .wish, subject: makeSubject(id: 2, name: "只有eps", totalEpisodes: nil)),
            makeCollection(id: 3, type: .wish),
        ]
        XCTAssertEqual(cache.missingSubjectIDs(in: list), [3])
    }

    func testMissingSubjectIDsRespectsLimit() {
        let cache = CollectionCache()
        let list = (1...40).map { makeCollection(id: $0, type: .wish) }
        XCTAssertEqual(cache.missingSubjectIDs(in: list, limit: 30).count, 30)
    }

    // MARK: - 失效

    /// 条目被改动后清掉对应类型，下次进入会重新拉取
    func testInvalidateRemovesOnlyGivenTypes() {
        var cache = CollectionCache()
        cache.store([makeCollection(id: 1, type: .doing)], for: .doing)
        cache.store([makeCollection(id: 2, type: .wish)], for: .wish)

        cache.invalidate(.doing)

        XCTAssertNil(cache.page(for: .doing))
        XCTAssertNotNil(cache.page(for: .wish), "其它类型的缓存不应被误清")
    }

    func testRemoveAllClearsEverything() {
        var cache = CollectionCache()
        cache.store([makeCollection(id: 1, type: .doing)], for: .doing)
        cache.remember(makeSubject(id: 1, name: "x"))

        cache.removeAll()

        XCTAssertNil(cache.page(for: .doing))
        XCTAssertNil(cache.enrich([makeCollection(id: 1, type: .doing)])[0].subject)
    }

    // MARK: - 变化检测（决定要不要重绘界面）

    /// 内容一致 → 判定没变（后台刷新后不刷新界面，避免闪烁）
    func testEquivalentWhenSameContent() {
        let a = [makeCollection(id: 1, type: .wish, epStatus: 3)]
        let b = [makeCollection(id: 1, type: .wish, epStatus: 3)]
        XCTAssertTrue(CollectionCache.isEquivalent(a, b))
    }

    /// 进度变化 → 判定有变（是新改动，需要刷新界面）
    func testNotEquivalentWhenEpisodeProgressChanged() {
        let a = [makeCollection(id: 1, type: .wish, epStatus: 3)]
        let b = [makeCollection(id: 1, type: .wish, epStatus: 4)]
        XCTAssertFalse(CollectionCache.isEquivalent(a, b))
    }

    /// 收藏状态变化（如「想看」→「看过」）→ 判定有变
    func testNotEquivalentWhenCollectionTypeChanged() {
        let a = [makeCollection(id: 1, type: .wish)]
        let b = [makeCollection(id: 1, type: .collected)]
        XCTAssertFalse(CollectionCache.isEquivalent(a, b))
    }

    /// 新增/删除条目 → 判定有变
    func testNotEquivalentWhenCountDiffers() {
        let a = [makeCollection(id: 1, type: .wish)]
        let b = [makeCollection(id: 1, type: .wish), makeCollection(id: 2, type: .wish)]
        XCTAssertFalse(CollectionCache.isEquivalent(a, b))
    }

    /// 条目顺序变化也算有变（列表顺序由接口决定）
    func testNotEquivalentWhenOrderDiffers() {
        let a = [makeCollection(id: 1, type: .wish), makeCollection(id: 2, type: .wish)]
        let b = [makeCollection(id: 2, type: .wish), makeCollection(id: 1, type: .wish)]
        XCTAssertFalse(CollectionCache.isEquivalent(a, b))
    }
}

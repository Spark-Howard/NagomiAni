import AppKit
import SwiftUI
import NagomiAniCore

/// 浏览页：搜索 Bangumi 词条 → 查看剧目详情（仿 Bangumi 条目页布局）
struct SearchPage: View {
    @ObservedObject var model: SearchViewModel

    var body: some View {
        Group {
            if let subject = model.selected {
                SubjectDetailView(model: model, subject: subject)
            } else {
                searchListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("搜索")
        // 进入页面时刷新登录状态与我的收藏
        .onAppear {
            model.refresh()
        }
    }

    // MARK: - 搜索列表

    private var searchListView: some View {
        VStack(alignment: .leading, spacing: 10) {
            todaySection

            HStack(spacing: 8) {
                TextField("搜索 Bangumi 条目（动画名 / 原名）", text: $model.keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button {
                    model.search()
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .disabled(model.keyword.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearching)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if model.isSearching {
                ProgressView("搜索中…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else if let message = model.searchMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else if model.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("输入动画名称，搜索 Bangumi 上的词条")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                List(model.results) { subject in
                    Button {
                        model.open(subject: subject)
                    } label: {
                        resultRow(subject)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 今日更新

    /// “今日更新”模块：Bangumi 放送日历里今天在播的动画（横向卡片列表）
    @ViewBuilder
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text("今日更新")
                    .font(.headline)
                Text(SearchViewModel.todayTitle())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingToday {
                    ProgressView()
                        .controlSize(.small)
                } else if model.todayMessage != nil {
                    Button("重试") { model.retryToday() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)

            if let message = model.todayMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else if model.todayAnime.isEmpty && !model.isLoadingToday {
                Text("今天暂时没有条目更新")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(model.todayAnime) { subject in
                            todayCard(subject)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }
                .frame(height: 148)
            }
        }
        .padding(.top, 12)
    }

    /// 今日更新卡片：封面 + 标题，点击进入条目详情
    private func todayCard(_ subject: Subject) -> some View {
        Button {
            model.open(subject: subject)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                AsyncImage(url: Self.imageURL(subject.images?.common)) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                }
                .frame(width: 78, height: 106)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(subject.nameCN ?? subject.name ?? "?")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 78, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(subject.nameCN ?? subject.name ?? "")
    }

    private func resultRow(_ subject: Subject) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: Self.imageURL(subject.images?.common)) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Rectangle().fill(Color.gray.opacity(0.15))
                    .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
            }
            .frame(width: 44, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(subject.nameCN ?? subject.name ?? "未命名")
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let name = subject.name, name != subject.nameCN {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let eps = subject.totalEpisodes {
                        Text("共 \(eps) 集")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let score = subject.rating?.score {
                        Text("★ \(Self.formatScore(score))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            // 我的收藏状态徽章
            if let type = model.collectionType(for: subject.id) {
                Text(SearchViewModel.collectionName(type))
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(SearchViewModel.collectionColor(type).opacity(0.15), in: Capsule())
                    .foregroundStyle(SearchViewModel.collectionColor(type))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 工具

    fileprivate static func imageURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string) else { return nil }
        return url
    }

    private static func formatScore(_ score: Double) -> String {
        String(format: "%.1f", score)
    }
}

// MARK: - 详情页

struct SubjectDetailView: View {
    @ObservedObject var model: SearchViewModel
    let subject: Subject
    /// 返回按钮文案（搜索页默认「返回搜索」，Bangumi 收藏页用「返回」）
    var backLabel: String = "返回搜索"
    @State private var tab: DetailTab = .episodes
    /// 待确认的收藏动作（非 nil 时弹出确认框）
    @State private var pendingAction: CollectionAction?
    /// 资料表（infobox）是否展开全部条目（信息多时默认折叠前几条）
    @State private var showAllInfobox = false

    enum CollectionAction {
        case set(SubjectCollectionType)
        case remove
    }

    enum DetailTab: String, CaseIterable, Identifiable {
        case episodes = "集数"
        case characters = "角色"
        case staff = "制作人员"
        case topics = "讨论"
        case comments = "评论"
        var id: String { rawValue }
    }

    /// 主标题：优先用已加载的 v0 详情（Bangumi 收藏打开时传入的条目可能只有 id）
    private var primaryTitle: String {
        model.detailSubject?.nameCN
            ?? model.detailSubject?.name
            ?? subject.nameCN
            ?? subject.name
            ?? ""
    }

    /// 原名（副标题）：与主标题不同才显示
    private var originalName: String? {
        let loaded = model.detailSubject?.name ?? subject.name
        guard let loaded, loaded != primaryTitle else { return nil }
        return loaded
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部返回栏
            HStack(spacing: 8) {
                Button {
                    model.back()
                } label: {
                    Label(backLabel, systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Text(primaryTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerSection
                    if let summary = detailSummary, !summary.isEmpty {
                        summarySection(summary)
                    }
                    Divider()
                    tabPicker
                    tabContent
                }
                .padding(20)
            }
        }
        .overlay {
            if model.isLoadingDetail {
                ProgressView("加载详情…")
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .overlay(alignment: .top) {
            if let error = model.detailError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 50)
            }
        }
    }

    // MARK: - 头部：封面 + 标题 + 评分/收藏 + 标签 + 资料表

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 26) {
            // 封面用 NSImageView 直接渲染（避开 AsyncImage 的布局怪癖），
            // 固定尺寸 + 高 layoutPriority，绝不被右侧信息列压缩
            CoverImageView(url: SearchPage.imageURL(
                model.detailSubject?.images?.large ?? subject.images?.large ?? subject.images?.common
            ))
            .frame(width: 260, height: 368)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .layoutPriority(1)

            VStack(alignment: .leading, spacing: 10) {
                Text(primaryTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                if let name = originalName {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // 评分与排名
                if let rating = model.detailSubject?.rating {
                    ratingRow(score: rating.score, rank: rating.rank, total: rating.total)
                } else if let rating = model.detailLarge?.rating {
                    ratingRow(score: rating.score, rank: model.detailLarge?.rank, total: rating.total)
                }

                // 收藏统计
                if let collection = model.detailSubject?.collection ?? model.detailLarge?.collection {
                    HStack(spacing: 8) {
                        collectionChip("在看", collection.doing, color: .green)
                        collectionChip("看过", collection.collect, color: .blue)
                        collectionChip("想看", collection.wish, color: .orange)
                        collectionChip("搁置", collection.onHold, color: .gray)
                        collectionChip("抛弃", collection.dropped, color: .red)
                    }
                }

                // 我的收藏状态与修改（同步到 Bangumi）
                collectionControl

                // 标签（流式紧凑排列；必须显式占满父级宽度，
                // 否则 FlowLayout 收到无限宽提案会按单行计算，导致标签区超宽、
                // 封面被压缩变小、换行后高度算错与下方内容重叠）
                if let tags = model.detailSubject?.tags, !tags.isEmpty {
                    // LazyVGrid（自适应列）替代自定义 FlowLayout：FlowLayout 在提案宽度为
                    // 无穷大时高度只按一行计算、实际却按窄列换行成多行，导致下方
                    // 简介/资料表按过短高度绘制而互相重叠。Grid 按真实宽度算行高，天然不重叠。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(Array(tags.prefix(12)), id: \.name) { tag in
                            Text(tag.name ?? "")
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gray.opacity(0.12), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 资料表（infobox）
                if let infobox = model.detailSubject?.infobox {
                    let rows = infobox.filter { !($0.key ?? "").isEmpty }
                    if !rows.isEmpty {
                        // 信息多时折叠：默认只显示前几条，超出给「展开全部」，避免把下方角色/制作推得很远
                        let visible = showAllInfobox ? rows : Array(rows.prefix(4))
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(visible, id: \.key) { item in
                                if let key = item.key, !key.isEmpty {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(key)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 72, alignment: .leading)
                                        Text(infoboxText(item.value))
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            // 长值（如一长串别名）在可用宽度内换行，避免撑宽信息列
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.gray.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(alignment: .bottomTrailing) {
                            if !showAllInfobox && rows.count > 4 {
                                expandInfoButton("展开全部 (\(rows.count))")
                            }
                        }
                        if showAllInfobox && rows.count > 4 {
                            expandInfoButton("收起")
                                .padding(.top, 3)
                        }
                    }
                }
            }
            // 右侧详情：占满封面之外的剩余空间（不设固定 maxWidth，
            // 否则比窗口剩余宽时 HStack 压缩逻辑会乱、长 infobox 值把列撑宽、封面被挤小）
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    /// 「展开全部 / 收起」资料表的按钮
    private func expandInfoButton(_ title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showAllInfobox.toggle() }
        } label: {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func ratingRow(score: Double?, rank: Int?, total: Int?) -> some View {
        HStack(spacing: 10) {
            if let score {
                Text("★ \(String(format: "%.1f", score))")
                    .font(.title3.bold())
                    .foregroundStyle(.orange)
            }
            if let rank {
                Text("排名 #\(rank)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let total {
                Text("\(total) 人评分")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func collectionChip(_ label: String, _ count: Int?, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(label) \(count ?? 0)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.gray.opacity(0.10), in: Capsule())
    }

    private var detailSummary: String? {
        model.detailSubject?.summary ?? model.detailLarge?.summary
    }

    /// 我的收藏状态：5 个状态按钮 + 右侧删除按钮，点选弹窗确认后同步到 Bangumi
    @ViewBuilder
    private var collectionControl: some View {
        if model.isLoggedIn {
            VStack(alignment: .leading, spacing: 6) {
                Text("收藏状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // LazyVGrid 替代 FlowLayout：避免无穷宽提案导致高度算错、与下方重叠
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(SubjectCollectionType.allCases.filter { $0 != .unknown }, id: \.self) { type in
                        Button {
                            pendingAction = .set(type)
                        } label: {
                            Text(SearchViewModel.collectionName(type))
                                .font(.title3)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .background(
                                    model.collectionType(for: subject.id) == type
                                        ? SearchViewModel.collectionColor(type).opacity(0.25)
                                        : Color.gray.opacity(0.10),
                                    in: Capsule()
                                )
                                .foregroundStyle(
                                    model.collectionType(for: subject.id) == type
                                        ? SearchViewModel.collectionColor(type)
                                        : Color.primary
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    // 删除收藏（红色，与状态按钮清晰区分）
                    Button {
                        pendingAction = .remove
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .background(Color.red.opacity(0.12), in: Capsule())
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("移除收藏")
                    .disabled(model.collectionType(for: subject.id) == nil)
                }
                if let message = model.collectionMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .alert("修改收藏状态", isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )) {
                Button("确认") {
                    switch pendingAction {
                    case .set(let type):
                        model.setCollection(subjectID: subject.id, type: type)
                    case .remove:
                        model.removeCollection(subjectID: subject.id)
                    case nil:
                        break
                    }
                    pendingAction = nil
                }
                Button("取消", role: .cancel) {
                    pendingAction = nil
                }
            } message: {
                if let action = pendingAction {
                    switch action {
                    case .set(let type):
                        Text("将「\(subject.nameCN ?? subject.name ?? "该条目")」的收藏状态修改为「\(SearchViewModel.collectionName(type))」并同步到 Bangumi？")
                    case .remove:
                        Text("确定将「\(subject.nameCN ?? subject.name ?? "该条目")」从收藏中移除吗？")
                    }
                }
            }
        } else {
            Text("登录 Bangumi 后可在应用内管理收藏状态")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func summarySection(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("简介")
                .font(.headline)
            Text(summary)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.9))
                .lineSpacing(3)
        }
    }

    // MARK: - 分段切换

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(DetailTab.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .episodes: episodeList
        case .characters: characterGrid
        case .staff: staffList
        case .topics: topicList
        case .comments: commentList
        }
    }

    // MARK: - 集数

    private var episodeList: some View {
        let eps = model.detailLarge?.eps ?? []
        return Group {
            if eps.isEmpty {
                emptyHint("暂无集数信息")
            } else {
                LazyVStack(spacing: 5) {
                    ForEach(eps.sorted { ($0.sort ?? 0) < ($1.sort ?? 0) }) { ep in
                        HStack(alignment: .top, spacing: 10) {
                            Text("第 \(Int(ep.sort ?? 0)) 集")
                                .font(.caption.bold())
                                .monospacedDigit()
                                .frame(width: 58, alignment: .trailing)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ep.nameCN ?? ep.name ?? "—")
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                if let name = ep.name, name != ep.nameCN {
                                    Text(name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    if let airdate = ep.airdate {
                                        Text(airdate).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let duration = ep.duration {
                                        Text(duration).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let comment = ep.comment {
                                        Label("\(comment)", systemImage: "bubble.right")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.gray.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }

    // MARK: - 角色

    private var characterGrid: some View {
        let crt = model.detailLarge?.crt ?? []
        return Group {
            if crt.isEmpty {
                emptyHint("暂无角色信息")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14)], spacing: 14) {
                    ForEach(crt) { character in
                        VStack(spacing: 6) {
                            AsyncImage(url: SearchPage.imageURL(character.images?.grid ?? character.images?.medium)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Rectangle().fill(Color.gray.opacity(0.12))
                                    .overlay { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                            }
                            .frame(width: 58, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(character.nameCN ?? character.name ?? "?")
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let role = character.roleName, !role.isEmpty {
                                Text(role)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 制作人员

    private var staffList: some View {
        let staff = model.detailLarge?.staff ?? []
        return Group {
            if staff.isEmpty {
                emptyHint("暂无制作人员信息")
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(staff) { person in
                        HStack(spacing: 8) {
                            Text(person.nameCN ?? person.name ?? "?")
                                .font(.callout)
                                .foregroundStyle(.primary)
                            if let job = person.jobs?.first, !job.isEmpty {
                                Text(job)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let role = person.roleName, !role.isEmpty {
                                Text(role)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
        }
    }

    // MARK: - 讨论

    private var topicList: some View {
        let topics = model.detailLarge?.topic ?? []
        return Group {
            if topics.isEmpty {
                emptyHint("暂无讨论帖")
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(topics) { topic in
                        Button {
                            openURL(topic.url)
                        } label: {
                            HStack(spacing: 10) {
                                avatar(topic.user)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.title ?? "—")
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    HStack(spacing: 10) {
                                        Text(topic.user?.nickname ?? "?")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let replies = topic.replies {
                                            Text("\(replies) 回复")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(formatDate(topic.lastpost))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help("在浏览器中打开讨论帖")
                    }
                }
            }
        }
    }

    // MARK: - 评论

    private var commentList: some View {
        let blogs = model.detailLarge?.blog ?? []
        return Group {
            if blogs.isEmpty {
                emptyHint("暂无评论")
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(blogs) { blog in
                        Button {
                            openURL(blog.url)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                avatar(blog.user)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(blog.title ?? "—")
                                        .font(.body.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if let summary = blog.summary, !summary.isEmpty {
                                        Text(summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                    HStack(spacing: 10) {
                                        Text(blog.user?.nickname ?? "?")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if let replies = blog.replies {
                                            Text("\(replies) 回复")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(formatDate(blog.timestamp))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(10)
                            .background(Color.gray.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .help("在浏览器中打开评论")
                    }
                }
            }
        }
    }

    // MARK: - 工具

    private func avatar(_ user: LegacyUser?) -> some View {
        AsyncImage(url: SearchPage.imageURL(user?.avatar?.small)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 30)
    }

    private func infoboxText(_ value: Subject.InfoboxValue?) -> String {
        guard let value else { return "" }
        switch value {
        case .string(let s): return s
        case .strings(let arr): return arr.joined(separator: " / ")
        case .values(let arr): return arr.joined(separator: " / ")
        case .none: return ""
        }
    }

    private func formatDate(_ timestamp: Int64?) -> String {
        guard let timestamp, timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func openURL(_ string: String?) {
        guard let string, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 流式布局

/// 流式布局：子视图按内容宽度依次排列，超出容器宽度自动换行（标签紧凑排列、不留空隙）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                totalHeight = y
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        if maxWidth.isInfinite {
            return CGSize(width: max(x - spacing, 0), height: totalHeight + rowHeight)
        }
        return CGSize(width: maxWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}


// MARK: - 封面图片（NSImageView 确定性渲染）

/// 用 NSImageView 直接渲染远程封面：完整显示整张图（等比缩放，不裁切中间）。
/// 注意：不要用 `imageScaling = .scaleProportionallyUpOrDown` + `wantsLayer` 的组合——
/// 在 layer-backed 的 NSImageView 上它可能按图片原始尺寸居中绘制、再被 masksToBounds 裁掉四周，
/// 于是只看到中间。改用 layer.contents + contentsGravity = .resizeAspect 可靠地"整图等比放缩进框"。
struct CoverImageView: NSViewRepresentable {
    let url: URL?
    /// 简单内存缓存（同一次运行内避免重复下载）
    private static var cache: [String: NSImage] = [:]

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.15).cgColor
        view.layer?.cornerRadius = 8
        view.layer?.masksToBounds = true
        view.layer?.contentsGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard let url else {
            view.layer?.contents = nil
            return
        }
        if let cached = Self.cache[url.absoluteString] {
            apply(image: cached, to: view)
            return
        }
        Task.detached(priority: .userInitiated) {
            if let image = NSImage(contentsOf: url) {
                await MainActor.run {
                    Self.cache[url.absoluteString] = image
                    apply(image: image, to: view)
                }
            }
        }
    }

    /// 把图片以"整图等比缩放"画进 layer（.resizeAspect = contain，居中，不裁切）
    private func apply(image: NSImage, to view: NSImageView) {
        view.image = nil
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            view.layer?.contents = nil
            return
        }
        view.layer?.contents = cg
        view.layer?.contentsGravity = .resizeAspect
    }
}

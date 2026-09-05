import AppKit
import SwiftUI
import WebKit
import NagomiAniCore

// MARK: - 常驻网页控制器（仅承载聊天相关页面）

/// 持有 WKWebView 的聊天网页控制器：只允许在 WebView 内停留聊天相关页面
/// （私信 /pm、登录、我的好友、发信页），其它 bgm.tv 页面一律在系统浏览器打开，
/// 避免内嵌网页取代 App 的搜索/收藏等原生功能。
/// 使用持久化 Cookie（WKWebsiteDataStore.default），用户在该网页内用 Bangumi 账号
/// 登录一次后，重启仍保持登录。
final class WebChatController: NSObject, ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var pageTitle = "Bangumi 聊天"
    /// 正在“后台”同步网页好友（界面显示遮罩，避免好友页闪现）
    @Published var isSyncingFriends = false

    let webView: WKWebView
    /// 隐藏的“好友抓取”网页：同步好友时在此加载，用户看不到也点不到，
    /// 主网页保持原页、不产生可后退到好友页的历史
    private let friendScraper: WKWebView

    /// 当前登录用户名（用于判断“我的好友”页），由页面层注入
    var selfUsername: String?

    /// 下一次抓取网页（好友页）加载完时解析好友列表
    private var parseFriendsOnNextLoad = false
    /// 解析结果回调：数组元素为 {u:用户名, label:昵称, avatar:头像URL}
    var onFriendsParsed: (([[String: String]]) -> Void)?

    static let inboxURL = URL(string: "https://bgm.tv/pm")!

    init(initialURL: URL = WebChatController.inboxURL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // 持久化登录 Cookie
        // 注入脚本：隐藏 bgm 站点头部导航/页脚等“逛站点”的区域，
        // 让聊天工作台里基本看不到其它入口（与导航白名单互为双保险）
        config.userContentController.addUserScript(WKUserScript(
            source: Self.chromeHideScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        ))
        webView = WKWebView(frame: .zero, configuration: config)
        friendScraper = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        friendScraper.navigationDelegate = self
        // 用 Safari UA，避免 bgm 把内嵌网页当机器人
        webView.customUserAgent = Self.safariUserAgent
        friendScraper.customUserAgent = Self.safariUserAgent
        webView.load(URLRequest(url: initialURL))
    }

    /// 回到私信收件箱
    func showInbox() {
        load("https://bgm.tv/pm")
    }

    /// 打开自己的好友列表页
    func showMyFriends(username: String) {
        load("https://bgm.tv/user/\(username)/friends")
    }

    /// 给某用户发第一条私信（写信页，bgm 实际地址：/pm/compose/{id}.chii）
    func openSend(to username: String) {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        load("https://bgm.tv/pm/compose/\(encoded).chii")
    }

    /// 同步网页好友：在隐藏的抓取网页里加载好友页并解析，
    /// 主聊天网页不跳转、不产生可回退到好友页的历史
    func syncFriends(username: String) {
        isSyncingFriends = true
        parseFriendsOnNextLoad = true
        let url = URL(string: "https://bgm.tv/user/\(username)/friends")!
        friendScraper.load(URLRequest(url: url))
        // 兜底：8 秒内没解析完也结束同步态
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.isSyncingFriends else { return }
            self.isSyncingFriends = false
            self.parseFriendsOnNextLoad = false
        }
    }

    /// 在已加载的好友页里用 JS 提取好友（用户名/昵称/头像）
    static func extractFriendList(from webView: WKWebView, completion: @escaping ([[String: String]]) -> Void) {
        let js = """
        (function () {
          var parts = location.pathname.split('/');
          var me = parts.length >= 3 ? decodeURIComponent(parts[2]) : '';
          var best = {};
          var as = document.querySelectorAll('a[href^="/user/"]');
          for (var i = 0; i < as.length; i++) {
            var h = as[i].getAttribute('href') || '';
            var seg = h.split('/');
            if (seg.length !== 3) continue;
            var u = decodeURIComponent(seg[2]);
            if (!u || u === me || h.indexOf('/friends') >= 0) continue;
            var label = (as[i].textContent || '').trim() || u;
            var img = as[i].querySelector ? as[i].querySelector('img') : null;
            var avatar = img ? (img.getAttribute('src') || '') : '';
            var cur = best[u];
            if (!cur) {
              best[u] = { u: u, label: label, avatar: avatar };
            } else {
              // 同用户出现多次（头像链接/昵称链接）：取昵称更真实、头像优先补上
              if (label !== u && (cur.label === u || label.length > cur.label.length)) { cur.label = label; }
              if (!cur.avatar && avatar) { cur.avatar = avatar; }
            }
          }
          var out = [];
          for (var k in best) { out.push(best[k]); }
          return JSON.stringify(out);
        })();
        """
        webView.evaluateJavaScript(js) { result, _ in
            guard let text = result as? String,
                  let data = text.data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
                completion([])
                return
            }
            completion(array)
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    private func load(_ string: String) {
        guard let url = URL(string: string) else { return }
        webView.load(URLRequest(url: url))
    }

    private static var safariUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    }

    /// 隐藏 bgm 站点级导航/页脚/悬浮条的脚本。
    /// 策略：
    /// 1) 常用类名（头部/页脚/悬浮条）直接隐藏；
    /// 2) 按“主导航链接文字”定位**顶部那一条头栏**（贴顶、占宽、高度小）整条隐藏
    ///    （logo / 动画·书籍…导航 / 搜索框 / 右上头像一起消失）；
    /// 3) 隐藏“固定在底部”的悬浮工具条 / 桌宠挂件。
    /// 只隐藏站点“外壳”，绝不隐藏聊天正文；找不到对应元素时静默跳过。
    private static var chromeHideScript: String {
        """
        (function () {
          var pageCustomDone = false; // 「我的好友」页自定义隐藏只执行一次
          var style = document.createElement('style');
          style.textContent = [
            '.global-nav, .globalNav, #globalNav, #global-nav, #global_nav,',
            '#topNav, #top-nav, .topNav, .top-nav, .site-nav, .siteNav,',
            '.header-nav, .headerNav, .topbar, .top-bar,',
            '.footer, footer, #footer,',
            '.floatBar, #floatBar, .quick-nav, #quickNav, .sideFloat, .float-bar'
          ].join(' ') + '{ display: none !important; }';
          (document.head || document.documentElement).appendChild(style);

          function rect(el) {
            try { return el.getBoundingClientRect(); } catch (e) { return null; }
          }
          function computed(el) {
            try { return window.getComputedStyle(el); } catch (e) { return null; }
          }

          // 兜底 A：定位“顶部头栏”（贴顶全宽、高度不大），只藏这一条，不升到整页
          function hideHeaderByNavLinks() {
            var vw = window.innerWidth || 1;
            var keyText = ['动画', '书籍', '音乐', '游戏', '三次元', '人物', '超展开', '小组', '探索'];
            var anchors = [].slice.call(document.querySelectorAll('a'));
            var hit = anchors.filter(function (a) {
              var t = (a.textContent || '').trim();
              return keyText.indexOf(t) >= 0 && /^https?:/.test(a.href || '');
            });
            if (hit.length < 3) return;
            var a = hit[0];
            var el = a;
            while (el && el !== document.body) {
              var cs = computed(el);
              if (!cs || cs.display === 'none') break;
              var r = rect(el);
              if (r) {
                // 头栏特征：顶部贴边、横向占主宽、高度介于 20~120px、非 fixed（fixed 交给悬浮处理）
                if (r.top >= -2 && r.top <= 6 && r.width > vw * 0.5 && r.height > 20 && r.height < 120
                    && cs.position !== 'fixed' && cs.position !== 'absolute') {
                  el.style.display = 'none';
                  return;
                }
              }
              el = el.parentElement;
            }
            // 回退：隐藏主导航链接所在的最近 ul
            var ul = a.closest('ul');
            if (ul && ul !== document.body) { ul.style.display = 'none'; }
          }

          // 兜底 B：隐藏“固定在底部”的悬浮工具条 / 桌宠挂件（避开含表单/输入区的元素）
          function hideBottomChrome() {
            var vh = window.innerHeight || 1;
            var vw = window.innerWidth || 1;
            var els = document.querySelectorAll('body *');
            for (var i = 0; i < els.length; i++) {
              var el = els[i];
              if (!el || !el.style) continue;
              if (el.style.display === 'none') continue;
              // 含输入/表单的固定条（可能是写信/搜索输入）不能误藏
              if (el.querySelector && (el.querySelector('textarea, input, form, [contenteditable]'))) continue;
              var cs = computed(el);
              if (!cs || cs.position !== 'fixed') continue;
              var r = rect(el);
              if (!r) continue;
              // 贴近底部、宽度不超过屏幕一半、高度不大的悬浮工具条/挂件
              if (r.bottom > vh * 0.85 && r.top < vh * 0.99 &&
                  r.height < vh * 0.30 && r.width < vw * 0.5) {
                el.style.display = 'none';
              }
            }
          }

          // —— 「我的好友」页定制 ——

          // 判断是否“我的好友”页，并取回自己的用户名（路径 /user/{自己}/friends）
          function friendsUsername() {
            var p = location.pathname || '';
            var seg = p.split('/');
            if (seg[1] === 'user' && seg.length >= 4 && seg[3] === 'friends') {
              return decodeURIComponent(seg[2]);
            }
            return null;
          }

          // 是否“好友条目链接”：/user/{非自己}（非 /friends、正好 3 段）
          function isFriendRowLink(h, me) {
            if (h.indexOf('/user/') !== 0 || h.indexOf('/friends') >= 0) return false;
            var seg = h.split('/');
            if (seg.length !== 3) return false;
            return decodeURIComponent(seg[2]) !== me;
          }

          // 容器里是否含“好友条目链接”（用于防误藏好友列表）
          function containsFriendLink(el, me) {
            var as = el.querySelectorAll ? el.querySelectorAll('a') : [];
            for (var i = 0; i < as.length; i++) {
              if (isFriendRowLink(as[i].getAttribute('href') || '', me)) return true;
            }
            return false;
          }

          // 兜底 C：「我的好友」页只留好友列表；只执行一次，避免页面几何变化后误藏列表
          function hideUserProfileAndNavi() {
            if (pageCustomDone) return;
            var me = friendsUsername();
            if (me === null) return;
            pageCustomDone = true;
            var vw = window.innerWidth || 1;

            // 1) 隐藏“头像 + 昵称”资料头：从含 “@自己” 的最内层元素向上找头部块
            var nodes = [].slice.call(document.querySelectorAll('body *'));
            var inner = null;
            for (var i = 0; i < nodes.length; i++) {
              var e = nodes[i];
              if ((e.textContent || '').indexOf('@' + me) >= 0) {
                if (!inner || e.childElementCount < inner.childElementCount) { inner = e; }
              }
            }
            if (inner) {
              var p = inner;
              while (p && p !== document.body) {
                var r = rect(p), cs = computed(p);
                if (r && cs && cs.position !== 'fixed' && r.top >= -2 && r.top < 260
                    && r.height > 18 && r.height < 360 && r.width > vw * 0.3) {
                  // 防误伤：含“好友条目链接”说明是列表区，跳过
                  if (!containsFriendLink(p, me)) { p.style.display = 'none'; }
                  break;
                }
                p = p.parentElement;
              }
            }

            // 2) 隐藏用户子导航条（“时光机/收藏/…/天窗”窄条）
            var tabText = ['时光机', '收藏', '时间胶囊', '人物', '日志', '目录', '小组', '好友', '维基', '天窗'];
            var tabs = [].slice.call(document.querySelectorAll('a')).filter(function (a) {
              var t = (a.textContent || '').trim();
              return tabText.indexOf(t) >= 0;
            });
            if (tabs.length >= 3) {
              var el = tabs[0];
              while (el && el !== document.body) {
                var r2 = rect(el), cs2 = computed(el);
                if (r2 && cs2 && cs2.display !== 'none' && el.querySelectorAll('a').length >= 3
                    && r2.height > 6 && r2.height < 140 && r2.width > vw * 0.3 && cs2.position !== 'fixed') {
                  if (!containsFriendLink(el, me)) { el.style.display = 'none'; }
                  break;
                }
                el = el.parentElement;
              }
            }
          }

          // 兜底 D：点好友条目/头像 → 给 TA 发第一条私信（事件代理，延迟渲染也可用）
          function enableFriendPM() {
            if (document.__pmDelegateBound) return;
            document.__pmDelegateBound = true;
            document.addEventListener('click', function (ev) {
              var me = friendsUsername();
              if (me === null) return;
              var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
              if (!a) return;
              var h = a.getAttribute('href') || '';
              if (!isFriendRowLink(h, me)) return;
              var seg = h.split('/');
              ev.preventDefault();
              ev.stopPropagation();
              window.location.href = 'https://bgm.tv/pm/compose/' + encodeURIComponent(decodeURIComponent(seg[2])) + '.chii';
            }, true);
          }

          function runHide() {
            hideHeaderByNavLinks();
            hideBottomChrome();
            hideUserProfileAndNavi();
            enableFriendPM();
          }

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', runHide);
          } else {
            runHide();
          }
          // bgm 页面有动态渲染/懒加载，稍后再清几次
          setTimeout(runHide, 800);
          setTimeout(runHide, 2000);
          setTimeout(runHide, 4000);
        })();
        """
    }
}

extension WebChatController: WKNavigationDelegate {
    private func isFriendScraper(_ webView: WKWebView) -> Bool {
        webView === friendScraper
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isFriendScraper(webView) else { return } // 抓取网页不影响主页面状态
        isLoading = true
        syncNavState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 隐藏抓取网页：好友页加载完成 → 提取 → 回调（主网页保持原页）
        if isFriendScraper(webView) {
            if parseFriendsOnNextLoad, let path = webView.url?.path, path.contains("/friends") {
                parseFriendsOnNextLoad = false
                Self.extractFriendList(from: webView) { [weak self] entries in
                    guard let self else { return }
                    if !entries.isEmpty { self.onFriendsParsed?(entries) }
                    self.isSyncingFriends = false
                }
            }
            return
        }
        isLoading = false
        pageTitle = webView.title ?? "Bangumi 聊天"
        syncNavState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isFriendScraper(webView) else { return }
        isLoading = false
        syncNavState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isFriendScraper(webView) else { return }
        isLoading = false
        syncNavState()
    }

    private func syncNavState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    // MARK: - 导航白名单：只让“聊天相关”页面留在内嵌网页里

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 非主框架（子框架/资源内嵌）放行
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            return
        }

        if Self.isChatNavigationAllowed(url, selfUsername: selfUsername) {
            decisionHandler(.allow)
        } else {
            // 聊天以外的页面：不让内嵌网页“逛”走，改由系统浏览器打开
            decisionHandler(.cancel)
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// 是否允许在聊天 WebView 内停留
    private static func isChatNavigationAllowed(_ url: URL, selfUsername: String?) -> Bool {
        guard let host = url.host?.lowercased(), host == "bgm.tv" || host.hasSuffix(".bgm.tv") else {
            return false
        }
        let path = url.path.lowercased()

        // 登录/登出/授权过程
        if path == "/" { return true }
        if path.hasPrefix("/login")
            || path.hasPrefix("/logout")
            || path.hasPrefix("/oauth")
            || path.hasPrefix("/demo/oauth") {
            return true
        }
        // 私信：收件箱 / 会话 / 写信页（含发送）
        if path.hasPrefix("/pm") { return true }
        // 好友页：/user/{自己}/friends（及 /user/{任意}/friends 便于查看）
        if path.hasPrefix("/user/") {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 3, parts[2] == "friends" { return true }
            return false
        }
        return false
    }
}

// MARK: - 页面

/// 「聊天」模块：左侧原生 Bangumi 好友/联系人，右侧内嵌网页只用于聊天相关页面
/// （收件箱 / 我的好友 / 给某人发私信）。真正收发在 bgm.tv 网页完成。
struct ChatPage: View {
    /// 当前 Bangumi 账号（用于“我的好友”页的 URL）
    @ObservedObject var account: AccountViewModel
    /// 常驻聊天网页控制器（由外层 ContentView 持有，切换板块不丢页面/登录态）
    @ObservedObject var web: WebChatController
    @EnvironmentObject private var contacts: ContactsStore
    @State private var newUsername = ""
    @State private var addHint: String?
    @State private var isCheckingAdd = false
    @State private var selectedUsername: String?

    var body: some View {
        HStack(spacing: 0) {
            contactsPanel
                .frame(width: 216)
            Divider()
            webArea
        }
        .navigationTitle("聊天")
        .onAppear {
            syncWebUser()
            installFriendsParser()
        }
        .onChange(of: account.user?.username) { _ in
            syncWebUser()
        }
    }

    /// 把当前登录用户名同步给网页控制器（“我的好友”白名单判定用）
    private func syncWebUser() {
        web.selfUsername = account.user?.username
    }

    /// 解析结果直接交给常驻 ContactsStore 处理（不写本视图状态，避免页面销毁后写失效状态）
    private func installFriendsParser() {
        web.onFriendsParsed = { [contacts] entries in
            contacts.ingestFriendEntries(entries)
        }
    }

    /// 点「同步好友」：在隐藏网页里抓取解析，主网页不动
    private func syncMyFriends() {
        guard let me = account.user?.username else { return }
        contacts.syncMessage = nil
        web.syncFriends(username: me)
    }

    // MARK: - 左：联系人/好友

    private var contactsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bangumi 好友")
                .font(.headline)

            if let hint = contacts.syncMessage {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            HStack(spacing: 6) {
                TextField("用户名（非昵称）…", text: $newUsername)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button {
                    add()
                } label: {
                    if isCheckingAdd {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(trimmedName.isEmpty || isCheckingAdd)
            }

            if let hint = addHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider()

            if contacts.contacts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text("从番剧详情的「讨论/评论」作者处\n一键加入，或输入用户名添加")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(contacts.contacts) { contact in
                            contactRow(contact)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text("右侧网页需用 Bangumi 账号登录一次（Cookie 持久化）")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
    }

    private func contactRow(_ contact: BgmContact) -> some View {
        let selected = selectedUsername == contact.username
        return HStack(spacing: 8) {
            Button {
                selectedUsername = contact.username
                web.openSend(to: contact.username)
            } label: {
                HStack(spacing: 8) {
                    avatar(for: contact)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.nickname)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("@\(contact.username)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                contacts.remove(username: contact.username)
                if selectedUsername == contact.username { selectedUsername = nil }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .padding(6)
        .background(
            selected ? Color.accentColor.opacity(0.16) : Color.gray.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    @ViewBuilder
    private func avatar(for contact: BgmContact) -> some View {
        if let avatar = contact.avatarURL, let url = URL(string: avatar) {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        }
    }

    private var trimmedName: String {
        newUsername.trimmingCharacters(in: .whitespaces)
    }

    private func add() {
        let name = trimmedName
        guard !name.isEmpty else { return }
        Task { await addVerified(name) }
    }

    /// 先验证用户名存在再加入（Bangumi 不支持按昵称搜索）
    @MainActor
    private func addVerified(_ name: String) async {
        isCheckingAdd = true
        addHint = nil
        defer { isCheckingAdd = false }
        do {
            let profile = try await BangumiClient().userProfile(username: name)
            contacts.add(username: profile.username, nickname: profile.nickname)
            contacts.applyProfile(
                username: profile.username,
                nickname: profile.nickname,
                avatarURL: profile.avatar?.medium ?? profile.avatar?.small ?? profile.avatar?.large
            )
            newUsername = ""
        } catch BangumiError.httpStatus(let code, _) where code == 404 {
            addHint = "没有找到用户「\(name)」：请输入准确用户名"
        } catch {
            contacts.add(username: name, nickname: "")
            newUsername = ""
            addHint = "联网验证失败，已先加入，稍后自动补全"
        }
    }

    // MARK: - 右：聊天网页

    private var webArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    web.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!web.canGoBack)
                .help("后退")

                Button {
                    web.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!web.canGoForward)
                .help("前进")

                Button {
                    web.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("刷新")

                Button {
                    web.showInbox()
                } label: {
                    Label("私信收件箱", systemImage: "tray.full")
                }
                .help("bgm.tv/pm")

                Button {
                    syncMyFriends()
                } label: {
                    if web.isSyncingFriends {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("同步好友", systemImage: "person.2")
                    }
                }
                .disabled(account.user == nil || web.isSyncingFriends)
                .help(account.user == nil
                      ? "请先在 Bangumi 页登录，才能同步你的网页好友"
                      : "后台抓取 bgm 好友并加入左侧列表（网页不切换）")

                Text(web.pageTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if web.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
            EmbeddedWebView(controller: web)

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("仅聊天相关页面可在内嵌页打开；其他链接会转由系统浏览器打开")
                Spacer()
                Text("网页内需登录一次（Cookie 已持久化）")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - 把 WKWebView 挂进 SwiftUI

private struct EmbeddedWebView: NSViewRepresentable {
    let controller: WebChatController

    func makeNSView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

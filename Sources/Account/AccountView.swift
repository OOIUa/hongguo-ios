// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import WebKit

struct AccountView: View {
    @StateObject private var account = AccountService.shared
    @State private var showLogin = false
    @State private var showImport = false
    @State private var showLogout = false
    @State private var selectedList = 0
    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 48)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(account.nickname.isEmpty ? "个人红果账号" : account.nickname).font(.headline)
                        Text(account.state).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if account.busy { ProgressView() }
                }.padding(.vertical, 8)
                if let message = account.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                Button("在本机打开官网登录", systemImage: "globe") { showLogin = true }.disabled(account.busy)
                if account.hasCredentials {
                    Button("重新验证账号", systemImage: "arrow.clockwise") { Task { await account.verify() } }.disabled(account.busy)
                    Button("退出账号", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { showLogout = true }
                }
            } footer: {
                Text("请在官方页面自行完成短信、扫码或平台验证。官网会话与手机云账号分别验证，只有云账号连接后才能读取账号片单。本机收藏和历史始终独立保存。")
            }
            if account.authenticated {
                Section {
                    Toggle("同步此后观看进度", isOn: $account.progressUploadsEnabled)
                } footer: { Text("默认关闭。开启后，仅同步此后实际播放的集数和位置；本机旧历史不会上传。实际跨设备续播请与官方客户端核对。") }
                Section {
                    Picker("账户片单", selection: $selectedList) {
                        Text("收藏").tag(0); Text("历史").tag(1); Text("预约").tag(2)
                    }.pickerStyle(.segmented)
                    if selectedList == 0 {
                        if account.favorites.isEmpty { empty("暂无已读取的账户收藏") }
                        ForEach(account.favorites) { drama in
                            NavigationLink { DetailView(drama: drama) } label: { AccountDramaRow(drama: drama, subtitle: "账号收藏") }
                        }
                    } else if selectedList == 1 {
                        if account.history.isEmpty { empty("暂无已读取的账户历史") }
                        ForEach(account.history) { entry in
                            NavigationLink { DetailView(drama: entry.drama, resume: entry) } label: {
                                AccountDramaRow(drama: entry.drama, subtitle: "第 \(entry.episodeIndex) 集 · \(Int(entry.position) / 60):\(String(format: "%02d", Int(entry.position) % 60))")
                            }
                        }
                    } else {
                        if account.reservations.isEmpty { empty("暂无已读取的账户预约") }
                        ForEach(account.reservations) { item in
                            if item.online {
                                NavigationLink { DetailView(drama: item.drama) } label: { AccountDramaRow(drama: item.drama, subtitle: "已上线") }
                            } else { AccountDramaRow(drama: item.drama, subtitle: item.publishText.isEmpty ? "待上线" : item.publishText) }
                        }
                    }
                } header: { Text("红果账号片单") } footer: {
                    Text("历史每次读取最近 50 部，历史与收藏各缓存最多 200 部，预约分类各读取 20 部。展示已读取的批次，不代表完整云端备份。")
                }
                ForEach(account.listErrors, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                Section {
                    Button("刷新账号片单", systemImage: "arrow.clockwise") { Task { await account.refresh() } }.disabled(account.busy)
                }
            }
            Section {
                Button("导入本人的登录态", systemImage: "key.horizontal") { showImport = true }.disabled(account.busy)
            } header: { Text("高级选项") } footer: {
                Text("登录态仅加密保存在这台设备。退出账号不会删除本机收藏与历史，也不会操作官方账号的数据。")
            }
        }
        .navigationTitle("账号与云片单").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogin) { OfficialLoginSheet { cookie in
            showLogin = false
            Task { await account.importCookie(cookie) }
        } }
        .sheet(isPresented: $showImport) { CookieImportSheet { cookie, source, device, install in
            showImport = false
            Task { await account.importCookie(cookie, source: source, deviceID: device, installID: install) }
        } }
        .confirmationDialog("退出红果账号？", isPresented: $showLogout, titleVisibility: .visible) {
            Button("退出并清理本机账号缓存", role: .destructive) { account.logout() }
        }
        .task { if account.hasCredentials && !account.authenticated { await account.verify() } }
        .refreshable { if account.authenticated { await account.refresh() } else { await account.verify() } }
    }
    private func empty(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24) }
}

private struct AccountDramaRow: View {
    let drama: Drama
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: drama.coverURL)) { image in image.resizable().scaledToFill() } placeholder: {
                Color.orange.opacity(0.12).overlay { Image(systemName: "play.rectangle").foregroundStyle(.orange) }
            }.frame(width: 54, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(drama.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

private struct CookieImportSheet: View {
    let completed: (String,String,String,String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var source = "WEBSITE"
    @State private var device = ""
    @State private var install = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("登录态来源", selection: $source) { Text("红果官网").tag("WEBSITE"); Text("红果 App").tag("APP") }
                    SecureField("Cookie", text: $cookie).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if source == "APP" {
                        TextField("对应的 device_id", text: $device).keyboardType(.numberPad)
                        TextField("对应的 install_id / iid", text: $install).keyboardType(.numberPad)
                    }
                } footer: { Text("仅导入你本人的登录态。App 登录态需提供它对应的设备标识；所有来源仍需验证业务账号，非空 Cookie 不等于登录成功。") }
                Button("在本机验证并加密保存") { completed(cookie,source,device,install); cookie = "" }
                    .disabled(cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (source == "APP" && (device.isEmpty || install.isEmpty)))
            }.navigationTitle("导入登录态").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

private struct OfficialLoginSheet: View {
    let completed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = OfficialBrowserModel()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("请在官方页面完成登录，再点“完成登录”。验证码仅提交给官方页面。")
                    .font(.footnote).foregroundStyle(.secondary).padding()
                if let message = browser.message { Text(message).font(.footnote).foregroundStyle(.orange).padding(.horizontal) }
                OfficialWebView(browser: browser)
                Button("打开官网登录窗口") { browser.openLogin() }
                    .buttonStyle(.borderedProminent).tint(.orange).padding()
            }
            .navigationTitle("红果官网登录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { browser.close(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成登录") { browser.finish(completed) } }
            }
            .onDisappear { browser.close() }
        }
    }
}

@MainActor
private final class OfficialBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var message: String?
    let webView: WKWebView
    private var closed = false
    private var finishing = false
    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        config.allowsInlineMediaPlayback = true
        config.userContentController.addUserScript(WKUserScript(source: """
        if (location.hostname === 'hongguoduanju.com') {
          var viewport = document.querySelector('meta[name="viewport"]');
          if (!viewport) { viewport = document.createElement('meta'); viewport.name = 'viewport'; document.head.appendChild(viewport); }
          viewport.content = 'width=1280';
        }
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.customUserAgent = AccountService.desktopUA
        webView.load(URLRequest(url: AccountService.website))
    }
    func openLogin() {
        webView.evaluateJavaScript("window.dispatchEvent(new Event('hongguo:pc-open-login'))") { [weak self] _,error in
            if error != nil { self?.message = "页面尚未准备好，请加载完成后再试。" }
        }
    }
    func finish(_ completed: @escaping (String) -> Void) {
        guard !closed, !finishing else { return }
        finishing = true
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.finishing = false
                let now = Date()
                let scoped = cookies.filter {
                    let target = "hongguoduanju.com"
                    return AccountRules.domainMatches(cookieDomain: $0.domain, targetHost: target) &&
                        ($0.expiresDate == nil || $0.expiresDate! > now) && $0.path == "/"
                }
                guard scoped.contains(where: { ["sessionid","sessionid_ss"].contains($0.name) && !$0.value.isEmpty }) else {
                    self.message = "官网尚未下发登录会话，请先完成登录。"; return
                }
                self.closed = true
                completed(scoped.map { "\($0.name)=\($0.value)" }.joined(separator: "; "))
            }
        }
    }
    func close() {
        closed = true
        webView.stopLoading()
        let store = webView.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == false, let url = action.request.url,
           url.scheme == "https" || url.absoluteString == "about:blank" {
            decisionHandler(.allow); return // WebKit keeps verification frames in their own origins.
        }
        guard let url = action.request.url, url.scheme == "https", let host = url.host,
              host == "hongguoduanju.com" || host.hasSuffix(".hongguoduanju.com") else {
            if action.targetFrame?.isMainFrame == true { message = "登录窗口仅允许访问红果官网。" }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme == "https", let host = url.host,
           host == "hongguoduanju.com" || host.hasSuffix(".hongguoduanju.com") { webView.load(action.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { message = "官网页面加载失败，请检查网络后重新打开。" }
    }
}

private struct OfficialWebView: UIViewRepresentable {
    let browser: OfficialBrowserModel
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

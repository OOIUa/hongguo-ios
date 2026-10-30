// SPDX-License-Identifier: GPL-3.0-only
// Protocol behavior adapted from hongguo-android 72d5531 / tsukiyo-zero/hongguoTV.
import Foundation
import Combine
import CryptoKit
import Security

struct CloudReservation: Identifiable, Codable {
    var id: String { drama.id }
    let drama: Drama
    let online: Bool
    let publishText: String
}

struct AccountCredentials: Codable {
    var cookie: String
    var source: String
    var deviceID: String = ""
    var installID: String = ""
    var device: [String: String] = [:]
    var appDeviceCookie: String = ""
}

private struct AccountSnapshot: Codable {
    var credentials: AccountCredentials
    var profileID: String
    var nickname: String
    var avatarURL: String?
    var favorites: [Drama]
    var history: [LibraryEntry]
    var reservations: [CloudReservation]
    var pendingProgress: [CloudProgressUpload]?
}

private struct CloudProgressUpload: Codable {
    let drama: Drama
    let episode: Episode
    let positionMS: Int64
    let durationMS: Int64
    let observedAtMS: Int64
    let revision: UUID?
}

private final class AccountTransport: NSObject, URLSessionTaskDelegate {
    static let shared = AccountTransport()
    lazy var session: URLSession = {
        makeSession()
    }()
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func cancelAndReset() {
        let previous = session
        session = makeSession()
        previous.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Credentials and one-shot writes never follow redirects.
    }
}

private enum AccountVault {
    static let keyService = "com.ooiua.hongguo.ios.account-key"
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hongguo/account-v1.enc")
    }
    static func key(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
                                   kSecAttrService as String:keyService, kSecAttrAccount as String:"encryption-v1"]
        var read = query
        read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecSuccess, let bytes = result as? Data, bytes.count == 32 { return SymmetricKey(data: bytes) }
        guard create, status == errSecItemNotFound else { throw HGError.message("账号安全存储暂不可用") }
        let bytes = HGCrypto.random(32)
        var add = query
        add[kSecValueData as String] = bytes
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw HGError.message("账号加密密钥保存失败") }
        return SymmetricKey(data: bytes)
    }
    static func save(_ snapshot: AccountSnapshot) throws {
        let plaintext = try JSONEncoder().encode(snapshot)
        guard let data = try AES.GCM.seal(plaintext, using: key(create: true)).combined else { throw HGError.message("账号加密失败") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        var file = url; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? file.setResourceValues(values)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func load() throws -> AccountSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw HGError.message("账号缓存文件过大") }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(create: false))
        return try JSONDecoder().decode(AccountSnapshot.self, from: clear)
    }
    static func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
                                  kSecAttrService as String:keyService,kSecAttrAccount as String:"encryption-v1"]
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw HGError.message("账号密钥清理失败") }
    }
}

@MainActor
final class AccountService: ObservableObject {
    static let shared = AccountService()
    static let website = URL(string: "https://hongguoduanju.com")!
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    @Published private(set) var state = "未登录"
    @Published private(set) var nickname = ""
    @Published private(set) var avatarURL = ""
    @Published private(set) var authenticated = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var favorites: [Drama] = []
    @Published private(set) var history: [LibraryEntry] = []
    @Published private(set) var reservations: [CloudReservation] = []
    @Published private(set) var listErrors: [String] = []
    @Published private(set) var pendingFavorites = Set<String>()
    @Published var progressUploadsEnabled = UserDefaults.standard.bool(forKey: "account.progressUploadsEnabled") {
        didSet {
            UserDefaults.standard.set(progressUploadsEnabled, forKey: "account.progressUploadsEnabled")
            if !progressUploadsEnabled { cancelUploads(); pendingProgress = [:]; try? persist() }
        }
    }
    private var credentials: AccountCredentials?
    private var profileID = ""
    private var generation = UUID()
    private var pendingProgress = [String:CloudProgressUpload]()
    private var uploadTask: Task<Void,Never>?
    private var uploadEpoch = UUID()
    private var uploadWaiting = false
    private var forceUploadPending = false
    private var lastUpload = Date.distantPast
    private var session: URLSession { AccountTransport.shared.session }

    private init() {
        do {
            if let snapshot = try AccountVault.load() {
                credentials = snapshot.credentials; profileID = snapshot.profileID; nickname = snapshot.nickname
                avatarURL = snapshot.avatarURL.flatMap(AccountRules.safeImageURL) ?? ""
                favorites = snapshot.favorites; history = snapshot.history; reservations = snapshot.reservations
                if progressUploadsEnabled { for entry in snapshot.pendingProgress ?? [] { pendingProgress[entry.drama.id] = entry } }
                state = "登录态待验证"
            }
        } catch { message = "账号缓存暂时无法读取，可重新登录；本机片单不受影响。" }
    }
    var hasCredentials: Bool { credentials != nil }
    var playbackToken: UUID { generation }

    func importCookie(_ cookie: String, source: String = "WEBSITE", deviceID: String = "", installID: String = "") async {
        guard !busy else { return }
        guard cookie.count <= 131072, !cookie.isEmpty,
              !cookie.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            message = "登录态格式无效"; return
        }
        guard source == "WEBSITE" || (source == "APP" && ProtocolJSON.identifier(deviceID) != nil && ProtocolJSON.identifier(installID) != nil) else {
            message = "App 登录态需提供有效且对应的设备和安装标识。"; return
        }
        do { try AccountVault.clear() } catch { message = "旧账号安全存储无法清理，请稍后重试。"; return }
        AccountTransport.shared.cancelAndReset()
        cancelUploads(); pendingProgress = [:]
        generation = UUID(); authenticated = false
        profileID = ""; nickname = ""; avatarURL = ""; favorites = []; history = []; reservations = []; pendingFavorites = []
        credentials = AccountCredentials(cookie: cookie, source: source, deviceID: deviceID, installID: installID)
        await verify()
    }

    func verify() async {
        guard var candidate = credentials, !busy else { return }
        cancelUploads(); authenticated = false
        let ticket = generation
        busy = true; message = nil; state = "正在验证账号"
        var websiteVerified = false
        var website: (avatar: String?, name: String?) = (nil, nil)
        defer { if ticket == generation { busy = false } }
        do {
            if candidate.source == "WEBSITE" {
                website = try await validateWebsite(candidate)
                guard ticket == generation else { return }
                websiteVerified = true
                // Shown on 我的 even if the cloud account cannot connect yet; the app profile overrides below.
                if nickname.isEmpty, let name = website.name { nickname = name }
                if avatarURL.isEmpty, let avatar = website.avatar { avatarURL = avatar }
                state = "官网已登录，正在连接云账号"
            }
            if ProtocolJSON.identifier(candidate.deviceID) == nil || ProtocolJSON.identifier(candidate.installID) == nil {
                let identity = try await PlaybackRegistration.register(session: session)
                guard ticket == generation else { return }
                candidate.deviceID = identity.deviceID; candidate.installID = identity.installID
                candidate.device = identity.device; candidate.appDeviceCookie = identity.appDeviceCookie
                credentials = candidate
            }
            let (json, response) = try await appJSON(candidate, path: "/reading/user/info/v1/")
            let data = ProtocolJSON.dictionary(json["data"])
            guard let rawID = AccountRules.businessID(data["biz_user_id"]) else { throw HGError.message("账号资料未返回有效的业务身份，请重新验证。") }
            let gateway = response.value(forHTTPHeaderField: "X-Tt-Agw-Login")
            guard rawID != candidate.deviceID, rawID != candidate.installID,
                  ProtocolJSON.identifier(rawID) != nil || gateway == "1" else {
                throw HGError.message("官网会话已确认，但手机云账号未接通。可稍后重新验证。")
            }
            guard ticket == generation else { return }
            if !profileID.isEmpty && profileID != rawID {
                expire(); message = "账号身份发生变化，请重新登录后再读取云片单。"; return
            }
            profileID = rawID; nickname = ProtocolJSON.text(data["user_name"])
            if nickname.isEmpty { nickname = website.name ?? "红果用户" }
            avatarURL = AccountRules.avatarURL(data) ?? website.avatar ?? ""
            credentials = candidate
            try persist()
            authenticated = true; state = "云账号已连接"
            scheduleUploads(force: false)
            busy = false
            await refresh()
        } catch {
            guard ticket == generation else { return }
            authenticated = false
            state = websiteVerified ? "官网已登录，手机云账号未接通" : "登录态待验证"
            message = safeMessage(error)
            if let failure = error as? AccountFailure, failure.expired {
                expire()
            } else if websiteVerified { try? persist() }
        }
    }

    func logout() {
        cancelUploads(); pendingProgress = [:]
        AccountTransport.shared.cancelAndReset()
        generation = UUID(); credentials = nil; profileID = ""; nickname = ""; avatarURL = ""
        authenticated = false; busy = false; state = "未登录"
        favorites = []; history = []; reservations = []; listErrors = []; pendingFavorites = []
        do { try AccountVault.clear(); message = nil } catch { message = "账号已退出，但本机加密缓存清理失败，请重试退出。" }
    }

    func refresh() async {
        guard authenticated, let candidate = credentials, !busy else { return }
        busy = true; let ticket = generation; listErrors = []; message = nil
        defer { if ticket == generation { busy = false } }
        do {
            let result = try await fetchFavorites(candidate)
            guard ticket == generation else { return }
            favorites = result; pendingFavorites.removeAll()
        } catch {
            guard ticket == generation else { return }
            if handleExpired(error) { return }
            listErrors.append("账户收藏：" + safeMessage(error))
        }
        do {
            let result = try await fetchHistory(candidate)
            guard ticket == generation else { return }
            history = result
        } catch {
            guard ticket == generation else { return }
            if handleExpired(error) { return }
            listErrors.append("账户历史：" + safeMessage(error))
        }
        do {
            let online = try await fetchReservations(candidate, online: true)
            let upcoming = try await fetchReservations(candidate, online: false)
            guard ticket == generation else { return }
            reservations = online + upcoming
        } catch {
            guard ticket == generation else { return }
            if handleExpired(error) { return }
            listErrors.append("账户预约：" + safeMessage(error))
        }
        if ticket == generation { try? persist(); scheduleUploads(force: false) }
    }

    /// Whose 猜你喜欢 a new round shows: the verified app account's session, or nil for the anonymous feed.
    var guessOwner: UUID? { authenticated && credentials != nil ? generation : nil }

    /// One 猜你喜欢 batch. A non-nil owner carries that account's cookie and device only while the same login session
    /// is still active, so an old round's pagination never mixes into a new account.
    func guessBatch(owner: UUID?, cursor: String, offset: Int) async throws -> GuessBatch {
        var account: GuessAccount?
        if let owner {
            guard owner == generation, authenticated, let candidate = credentials else { throw HGError.message("账号已变化，请刷新猜你喜欢") }
            account = GuessAccount(cookie: appCookie(candidate), deviceID: candidate.deviceID, installID: candidate.installID, device: candidate.device)
        }
        let request = try GuessFeed.request(account: account, session: cursor, offset: offset)
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if let owner, owner != generation { throw CancellationError() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HGError.message("猜你喜欢暂时不可用（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard !bytes.isEmpty else { throw HGError.message("猜你喜欢返回空响应，请稍后重试") }
        return try GuessFeed.parse(ProtocolJSON.object(bytes))
    }

    func isFavorite(_ drama: Drama) -> Bool { favorites.contains { $0.id == drama.id } }
    func resumePendingUploads() { scheduleUploads(force: false) }
    /// Called only for the current player after a displayed frame; never scans local history.
    func observePlayback(drama: Drama, episode: Episode, position: Double, duration: Double, token: UUID, force: Bool) {
        guard progressUploadsEnabled, authenticated, token == generation, position.isFinite, duration.isFinite,
              position >= 0, duration > 0, position < 1e10, duration < 1e10,
              ProtocolJSON.identifier(drama.id) != nil, ProtocolJSON.identifier(episode.id) != nil else { return }
        pendingProgress[drama.id] = CloudProgressUpload(drama: drama, episode: episode,
            positionMS: Int64(min(position, duration) * 1000), durationMS: Int64(duration * 1000),
            observedAtMS: Int64(Date().timeIntervalSince1970 * 1000), revision: UUID())
        if pendingProgress.count > 200, let oldest = pendingProgress.values.min(by: { $0.observedAtMS < $1.observedAtMS }) {
            pendingProgress.removeValue(forKey: oldest.drama.id)
        }
        try? persist()
        scheduleUploads(force: force)
    }
    private func scheduleUploads(force: Bool) {
        guard progressUploadsEnabled, authenticated, !pendingProgress.isEmpty else { return }
        if force {
            forceUploadPending = true
            if uploadWaiting { cancelUploads(keepForce: true) }
        }
        // Keep one write in flight; a later acknowledgement may not discard newer observed progress.
        guard uploadTask == nil else { return }
        let ticket = generation
        let epoch = UUID(); uploadEpoch = epoch
        let sendNow = forceUploadPending || force
        forceUploadPending = false
        uploadWaiting = !sendNow
        uploadTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            defer {
                if ticket == self.generation && epoch == self.uploadEpoch {
                    self.uploadTask = nil; self.uploadWaiting = false
                    if !failed && !self.pendingProgress.isEmpty { self.scheduleUploads(force: self.forceUploadPending) }
                }
            }
            if !sendNow {
                let delay = max(0, 15 - Date().timeIntervalSince(self.lastUpload))
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
            guard !Task.isCancelled, ticket == self.generation, epoch == self.uploadEpoch, self.authenticated else { return }
            self.uploadWaiting = false
            guard let candidate = self.credentials else { return }
            let entries = self.pendingProgress.values.sorted { $0.observedAtMS < $1.observedAtMS }
            for entry in entries {
                guard !Task.isCancelled, ticket == self.generation, epoch == self.uploadEpoch, self.authenticated, self.progressUploadsEnabled else { return }
                do {
                    let record: [String:Any] = ["book_id":entry.drama.id,"item_id":entry.episode.id,
                        "vid_index":entry.episode.index,"current_play_time":entry.positionMS,"current_total_time":entry.durationMS,
                        "episode_count":entry.drama.episodeCount,"read_timestamp_ms":entry.observedAtMS,"book_type":2,
                        "progress_rate":String(Double(entry.positionMS) / Double(max(1,entry.durationMS))),
                        "player_cumulative_total_duration":entry.positionMS]
                    self.lastUpload = Date()
                    _ = try await self.appJSON(candidate, path:"/reading/bookapi/read_progress/upload/v1/", body:ProtocolJSON.data(["books":[record],"write_mode":1]))
                    guard ticket == self.generation, epoch == self.uploadEpoch, self.authenticated else { return }
                    if self.pendingProgress[entry.drama.id]?.revision == entry.revision { self.pendingProgress.removeValue(forKey: entry.drama.id) }
                    try self.persist()
                } catch {
                    failed = true
                    guard !Task.isCancelled, ticket == self.generation, epoch == self.uploadEpoch else { return }
                    if !self.handleExpired(error) { self.message = "进度已保留，待联网后继续同步。" }
                    return
                }
            }
        }
    }
    private func cancelUploads(keepForce: Bool = false) {
        uploadEpoch = UUID(); uploadTask?.cancel(); uploadTask = nil; uploadWaiting = false
        if !keepForce { forceUploadPending = false }
    }
    func toggleFavorite(_ drama: Drama) async {
        guard authenticated, let candidate = credentials, !busy else { return }
        guard !pendingFavorites.contains(drama.id) else { await refresh(); return }
        let ticket = generation; busy = true; message = nil
        defer { if ticket == generation { busy = false } }
        do {
            let before = try await fetchFavorites(candidate)
            guard ticket == generation else { return }
            let add = !before.contains { $0.id == drama.id }
            var entry: [String:Any] = ["book_id":drama.id,"book_type":2,"modify_time":Int64(Date().timeIntervalSince1970 * 1000),"video_shelf_operate_type":add ? 0 : 1]
            if !add { entry["group_name"] = "" }
            var body: [String:Any] = ["is_cancelled":false,"update_bookshelf_video_list":[entry]]
            if add { body["shark_extra"] = ["enter_from":"MainFragmentActivity","previous_page":"","page_list":"MainFragmentActivity","is_active_behavior":"true","inactive_type":"0"] }
            pendingFavorites.insert(drama.id)
            _ = try await appJSON(candidate, path: "/reading/bookapi/bookshelf/video/update/v1/", body: ProtocolJSON.data(body))
            let confirmed = try await fetchFavorites(candidate)
            guard ticket == generation else { return }
            favorites = confirmed
            guard confirmed.contains(where: { $0.id == drama.id }) == add else {
                throw HGError.message("收藏请求已提交，云片单尚未确认。请刷新核对，不要重复提交。")
            }
            pendingFavorites.remove(drama.id); try persist(); message = add ? "账号收藏已确认" : "账号取消收藏已确认"
        } catch {
            guard ticket == generation else { return }
            if !handleExpired(error) { message = safeMessage(error) }
        }
    }

    /// Returns the website profile's avatar and name, used when the app profile has none.
    private func validateWebsite(_ candidate: AccountCredentials) async throws -> (avatar: String?, name: String?) {
        let ticket = generation
        var components = URLComponents(url: Self.website.appendingPathComponent("passport/account/info/v2/"), resolvingAgainstBaseURL: false)!
        components.queryItems = ["aid":"513755","passport_jssdk_version":"3.4.10","passport_jssdk_type":"normal","account_sdk_source":"web","is_from_ttaccountsdk":"1","language":"zh"].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!); request.httpShouldHandleCookies = false
        request.setValue(candidate.cookie, forHTTPHeaderField: "Cookie")
        request.setValue(Self.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.website.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.website.absoluteString + "/", forHTTPHeaderField: "Referer")
        let cookies = cookiePairs(candidate.cookie)
        request.setValue(cookies["passport_csrf_token"] ?? cookies["passport_csrf_token_default"], forHTTPHeaderField: "x-tt-passport-csrf-token")
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard ticket == generation else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw HGError.message("官网登录验证暂时不可用") }
        let reply = try ProtocolJSON.object(bytes), data = ProtocolJSON.dictionary(reply["data"])
        let code = ProtocolJSON.integer(data["error_code"])
        guard ProtocolJSON.text(reply["message"]) == "success" else { throw AccountFailure(expired: [13,1003].contains(code), code: code) }
        guard AccountRules.websiteAuthenticated(reply) else { throw HGError.message("官网尚未确认登录，请先在官方页面完成验证") }
        return (AccountRules.avatarURL(data), AccountRules.displayName(data))
    }

    private func appJSON(_ candidate: AccountCredentials, path: String, params: [String:String] = [:], body: Data? = nil) async throws -> ([String:Any], HTTPURLResponse) {
        let ticket = generation
        try Task.checkCancellation()
        var device = PlaybackRegistration.deviceProfile.merging(candidate.device) { _,new in new }
        device["device_id"] = candidate.deviceID; device["iid"] = candidate.installID
        for key in ["version_code","manifest_version_code","update_version_code","pv_player"] { device[key] = body == nil ? "72232" : "73932" }
        device["version_name"] = body == nil ? "7.2.2.32" : "7.3.9.32"
        device["ts"] = String(Int64(Date().timeIntervalSince1970))
        let query = device.merging(params) { _,new in new }.sorted { $0.key < $1.key }.map { [$0.key,$0.value] }
        let signed = try await ProtocolSigner.shared.signedRequest(baseURL: "https://api5-normal-sinfonlinea.fqnovel.com" + path, query: query, body: body, device: device)
        try Task.checkCancellation()
        guard ticket == generation, credentials?.cookie == candidate.cookie else { throw CancellationError() }
        var request = URLRequest(url: signed.url); request.httpShouldHandleCookies = false
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        for (key,value) in signed.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(body == nil
            ? "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
            : "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=utf-8,application/x-protobuf", forHTTPHeaderField: "Accept")
        for (key,value) in ["x-tt-request-tag":"t=0;n=0","sdk-version":"2","passport-sdk-version":"50561","x-xs-from-web":"0","x-tt-dt":""] { request.setValue(value,forHTTPHeaderField:key) }
        if body != nil { request.setValue("3.7.2.cn",forHTTPHeaderField:"x-vc-bdturing-sdk-version") }
        request.setValue(appCookie(candidate), forHTTPHeaderField: "Cookie")
        if body != nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        let (bytes,response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard ticket == generation else { throw CancellationError() }
        guard let response = response as? HTTPURLResponse else { throw HGError.message("账号请求未完成") }
        guard response.statusCode == 200 else { throw HGError.message("账号服务暂时不可用（HTTP \(response.statusCode)）") }
        let json = try ProtocolJSON.object(bytes)
        guard json["code"] != nil else { throw HGError.message("账号服务数据格式发生变化") }
        let code = ProtocolJSON.integer(json["code"])
        guard code == 0 else { throw AccountFailure(expired: code == 1003, code: code) }
        return (json,response)
    }

    private func fetchFavorites(_ candidate: AccountCredentials) async throws -> [Drama] {
        let (raw,_) = try await appJSON(candidate, path: "/reading/bookapi/bookshelf/video/info/v1/")
        let data = ProtocolJSON.dictionary(raw["data"])
        guard data["video_shelf_info"] != nil else { throw HGError.message("账户收藏数据格式发生变化") }
        let rows = ProtocolJSON.array(data["video_shelf_info"])
        let result = rows.compactMap { value -> Drama? in
            let row = ProtocolJSON.dictionary(value), video = ProtocolJSON.dictionary(row["video_data"])
            return drama(row: row, video: video)
        }
        guard rows.isEmpty || !result.isEmpty else { throw HGError.message("账户收藏条目格式发生变化") }
        return unique(result)
    }
    private func fetchHistory(_ candidate: AccountCredentials) async throws -> [LibraryEntry] {
        let (raw,_) = try await appJSON(candidate, path: "/reading/bookapi/read_progress/list/v1/", params: ["book_types":"2","limit":"50"])
        let data = ProtocolJSON.dictionary(raw["data"])
        guard let rows = (raw["video_data"] ?? data["video_data"]) as? [[String:Any]] else { throw HGError.message("账户历史数据格式发生变化") }
        var result = rows.compactMap { row -> LibraryEntry? in
            guard let id = ProtocolJSON.identifier(row["series_id"] ?? row["book_id"]), let episode = ProtocolJSON.identifier(row["vid"]) else { return nil }
            var stamp = Double(ProtocolJSON.text(row["last_watch_time"])) ?? 0
            if stamp > 1e11 { stamp /= 1000 }
            let drama = Drama(id: id, title: "剧集", coverURL: "", summary: "", episodeCount: ProtocolJSON.integer(row["episode_count"]))
            return LibraryEntry(drama: drama, episodeID: episode, episodeIndex: max(1, ProtocolJSON.integer(row["vid_index"])), position: max(0, (Double(ProtocolJSON.text(row["current_play_time"])) ?? 0) / 1000), updatedAt: Date(timeIntervalSince1970: stamp))
        }
        guard rows.isEmpty || !result.isEmpty else { throw HGError.message("账户历史条目格式发生变化") }
        if !result.isEmpty {
            let (metadata,_) = try await appJSON(candidate, path: "/reading/bookapi/multi-detail/v1/", params: ["book_id":result.map { $0.id }.joined(separator: ","),"book_type":"2"])
            let items = ProtocolJSON.array(metadata["data"]).map { ProtocolJSON.dictionary($0) }
            var mapped = [String:Drama]()
            for row in items { if let item = drama(row: row, video: row) { mapped[item.id] = item } }
            result = result.map { item in
                LibraryEntry(drama: mapped[item.id] ?? item.drama, episodeID: item.episodeID, episodeIndex: item.episodeIndex, position: item.position, updatedAt: item.updatedAt)
            }
        }
        return Array(result.sorted { $0.updatedAt > $1.updatedAt }.prefix(200))
    }
    private func fetchReservations(_ candidate: AccountCredentials, online: Bool) async throws -> [CloudReservation] {
        let (raw,_) = try await appJSON(candidate, path: "/reading/user/subscribe/list/v0/", params: ["offset":"0","limit":"20","is_online":String(online),"tab_type":"13","subscribe_order_type":"0","swipe_type":"0","need_calendar_schema":"false","subscribe_offset":"0"])
        let data = ProtocolJSON.dictionary(raw["data"])
        guard data["subscribe_items"] != nil else { throw HGError.message("预约数据格式发生变化") }
        return ProtocolJSON.array(data["subscribe_items"]).compactMap { value in
            let row = ProtocolJSON.dictionary(value)
            let video = ProtocolJSON.dictionary(row["subscribe_data"] ?? row["video_data"] ?? row)
            var item = drama(row: row, video: video)
            if item == nil, !online, let id = ProtocolJSON.identifier(row["item_id"]) {
                let title = ProtocolJSON.text(row["name"])
                item = Drama(id: "reservation:" + id, title: title, coverURL: ProtocolJSON.text(row["thumb_url"]), summary: ProtocolJSON.text(row["item_desc"]), episodeCount: 0)
            }
            guard let item, !item.title.isEmpty else { return nil }
            return CloudReservation(drama: item, online: online, publishText: ProtocolJSON.text(row["expected_rec_text"]))
        }
    }

    private func drama(row: [String:Any], video: [String:Any]) -> Drama? {
        func first(_ values: [Any?]) -> String { values.map { ProtocolJSON.text($0) }.first { !$0.isEmpty } ?? "" }
        let id = first([video["series_id"],row["series_id"],row["book_id"]])
        let title = first([row["series_title"],video["title"],row["book_name"],video["book_name"]])
        guard ProtocolJSON.identifier(id) != nil, !title.isEmpty else { return nil }
        let cover = first([row["series_cover_url"],video["cover"],video["cover_url"],video["thumb_url"],row["thumb_url"]]).replacingOccurrences(of: "http://", with: "https://")
        return Drama(id: id, title: title, coverURL: cover, summary: first([row["series_intro"],video["video_desc"],row["abstract"]]), episodeCount: max(ProtocolJSON.integer(video["episode_cnt"]),ProtocolJSON.integer(video["episode_count"]),ProtocolJSON.integer(row["episode_cnt"])))
    }
    private func unique(_ values: [Drama]) -> [Drama] {
        var seen = Set<String>(); return Array(values.filter { seen.insert($0.id).inserted }.prefix(200))
    }
    /// Website session plus the registered app-device cookies; the account's stable iid is authoritative.
    private func appCookie(_ candidate: AccountCredentials) -> String {
        var cookie = cookiePairs(candidate.cookie)
        for (key,value) in cookiePairs(candidate.appDeviceCookie) where ["install_id","ttreq","store-region","store-region-src"].contains(key) { cookie[key] = value }
        cookie["install_id"] = candidate.installID
        return cookie.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }
    private func cookiePairs(_ value: String) -> [String:String] {
        var result = [String:String]()
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty { result[pair[0]] = pair[1] }
        }
        return result
    }
    private func persist() throws {
        guard let credentials else { return }
        try AccountVault.save(AccountSnapshot(credentials: credentials, profileID: profileID, nickname: nickname, avatarURL: avatarURL, favorites: favorites, history: history, reservations: reservations, pendingProgress:Array(pendingProgress.values)))
    }
    private func handleExpired(_ error: Error) -> Bool {
        guard let failure = error as? AccountFailure, failure.expired else { return false }
        expire(); return true
    }
    private func expire() {
        cancelUploads(); pendingProgress = [:]
        generation = UUID(); AccountTransport.shared.cancelAndReset()
        credentials = nil; authenticated = false; busy = false; state = "登录已过期"
        nickname = ""; avatarURL = ""; profileID = ""; favorites = []; history = []; reservations = []; pendingFavorites = []
        message = "登录会话已失效，请重新登录。"
        try? AccountVault.clear()
    }
    private func safeMessage(_ error: Error) -> String {
        if let error = error as? HGError { return error.localizedDescription }
        if let error = error as? AccountFailure { return error.localizedDescription }
        return "账号请求未完成，请检查网络后重试。"
    }
}

private struct AccountFailure: LocalizedError {
    let expired: Bool
    let code: Int
    var errorDescription: String? { expired ? "登录会话已失效，请重新登录。" : "账号验证未完成（错误码 \(code)），请稍后重试。" }
}

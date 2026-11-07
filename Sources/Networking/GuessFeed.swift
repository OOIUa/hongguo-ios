// SPDX-License-Identifier: GPL-3.0-only
// Adapted from hongguo-android 0.7.10 GuessFeed.kt and tsukiyo-zero/hongguoTV kotlin-tv/core
// RecommendationFeed.kt at 97c5b1d15d (2026-10-30); path and card shape referenced there from Xanerix/guoapp.
// Signed-in query and host rotation synchronized from the same file at f22bb3f (2026-11-03, TV 0.1.19).
// Offset stride from hongguoTV PR #59 (open on 2026-11-04), rechecked here with an anonymous request.
// Signed registered identity, 7.4.3.32 context and the bookmall/cell/change continuation synchronized from
// hongguoTV TV 0.1.26, commits 3d319a6 and 62910e0 (2026-11-06), GPL-3.0-only — RecommendationFeed.kt.
import Foundation

/// The single-column continuation the entry declared; protocol identifiers only, never credentials.
struct GuessFlow: Sendable, Equatable {
    let cellID: String
    let planID: String
    let versionTag: String
}

/// Server pagination of one browse round, in memory only. `GuessFeed.batch` advances it by the protocol in use: the
/// entry tab by the rows it served, the cell continuation by the server's own next_offset.
struct GuessCursor: Sendable, Equatable {
    var session = ""
    var offset = 0
    var flow: GuessFlow?
    /// A signed request was answered with an explicit 110: keep the original unsigned form for this round.
    var unsigned = false
    /// Recently shown ids, sent as filter_ids on the cell continuation.
    var filterIDs: [String] = []
    /// The registered identity the server session belongs to; a change reads the entry again.
    var identityID: String?
    var hasProgress: Bool { !session.isEmpty || offset > 0 || flow != nil }
    mutating func restartServer() { session = ""; offset = 0; flow = nil }
}

struct GuessBatch: Sendable {
    let dramas: [Drama]
    /// Server pagination token; kept in memory only.
    let session: String
    /// The server pagination was dropped (rejected, host rotated or identity changed): a new offset-0 round.
    var restarted = false
    /// Rows the server sent before local filtering: the entry's offset is counted in rows, not pages.
    var served = 0
    /// The cursor after this batch.
    var cursor = GuessCursor()
}

/// The account identity a 猜你喜欢 request may carry. nil requests the anonymous feed.
struct GuessAccount: Sendable {
    let cookie: String
    let device: [String: String]
}

/// HTTP 200 with an empty body, the usual shape of a soft block.
struct GuessEmptyResponse: LocalizedError {
    var errorDescription: String? { "猜你喜欢返回空响应，请稍后重试" }
}

/// The registered anonymous identity this process's recommendations share (hongguoTV 0.1.26 62910e0). The server's
/// pagination session belongs to it, so unlike playback it is reused instead of registered per request. A failed
/// registration is reused for 10 seconds and answered with nil, and the caller then sends the original unsigned form.
actor GuessIdentity {
    static let shared = GuessIdentity()
    private var current: RegisteredIdentity?
    private var failedAt: Date?

    func identity(session: URLSession) async throws -> RegisteredIdentity? {
        if let current { return current }
        if let failedAt, Date().timeIntervalSince(failedAt) < 10 { return nil }
        do {
            let registered = try await PlaybackRegistration.register(session: session)
            failedAt = nil
            if current == nil { current = registered }
            return current
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); failedAt = Date(); return nil }
    }

    /// Drops an identity the server soft-blocked; one another task already replaced is left alone.
    func forget(_ identity: RegisteredIdentity) {
        if current?.deviceID == identity.deviceID { current = nil }
    }
}

/// Official App 书城「猜你喜欢」(bookmall tab_type=16). No exposure/click/finish reporting.
///
/// Signed form (hongguoTV 0.1.26): the shared registered identity, the full App signature, version 7.4.3.32 and the
/// registration cookies; signed in, the account's own login cookie replaces them. An explicit 110 on a signed request
/// switches the round back to the original unsigned form, which carries only the account's login cookie (hongguoTV
/// measured on 2026-11-03 that the account's own device_id / iid is answered with 110).
///
/// When the entry declares `bottom_unlimited` with template 7 and a valid cell and plan, later batches use
/// `bookmall/cell/change/v1/` with the server's next_offset, as the official 7.4.3.32 single-column feed does.
enum GuessFeed {
    static let hosts = ["api5-normal-sinfonlinea.fqnovel.com", "api5-normal-hl.fqnovel.com", "api5-normal-lf.fqnovel.com"]
    static let maxOffset = 600
    static let entryPath = "/reading/bookapi/bookmall/tab/v1/", cellPath = "/reading/bookapi/bookmall/cell/change/v1/"
    static let signedVersionCode = "74332", signedVersionName = "7.4.3.32"
    static let signedUserAgent = "com.phoenix.read/74332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
    /// filter_ids stays well inside common URL limits; older ids are still filtered locally.
    static let filterLimit = 120
    private static let deviceKeys: Set<String> = ["channel", "device_platform", "os", "ssmix", "device_type", "device_brand",
        "language", "os_api", "os_version", "resolution", "dpi", "ac"]

    typealias Sign = @Sendable (String, [[String]], [String: String]) async throws -> SignedProtocolRequest
    static let defaultSign: Sign = { base, query, device in
        try await ProtocolSigner.shared.signedRequest(baseURL: base, query: query, body: nil, device: device)
    }

    /// Reads one batch. A non-zero `code` is retried on the next host from offset 0; errors thrown by `fetch` (HTTP,
    /// network) are not retried, except an empty reply to a signed request, which drops that identity first.
    static func batch(account: GuessAccount?, cursor input: GuessCursor,
                      identity: () async throws -> RegisteredIdentity? = { nil },
                      forget: (RegisteredIdentity) async -> Void = { _ in },
                      sign: Sign = defaultSign,
                      fetch: (URLRequest) async throws -> [String: Any]) async throws -> GuessBatch {
        guard (0...maxOffset).contains(input.offset) else { throw HGError.message("猜你喜欢分页超出范围") }
        var cursor = input, restarted = false
        for (attempt, host) in hosts.enumerated() {
            let last = attempt == hosts.count - 1
            if attempt > 0 { cursor.restartServer(); restarted = true }
            let registered = cursor.unsigned ? nil : try await identity()
            if registered?.deviceID != cursor.identityID && cursor.hasProgress { cursor.restartServer(); restarted = true }
            cursor.identityID = registered?.deviceID
            let flow = cursor.flow
            let request: URLRequest
            if let registered {
                request = try await signedRequest(account: account, cursor: cursor, identity: registered, host: host, sign: sign)
            } else {
                request = try self.request(account: account, cursor: cursor, host: host)
            }
            let object: [String: Any]
            do { object = try await fetch(request) }
            catch is GuessEmptyResponse where registered != nil && !last { await forget(registered!); continue }
            let code = ProtocolJSON.integer(object["code"] ?? -1)
            if (object["code"] == nil || code != 0) && !last {
                if registered != nil && code == 110 { cursor.unsigned = true }
                continue
            }
            var batch = try flow == nil ? parse(object) : parseCell(object)
            if flow != nil {
                let next = ProtocolJSON.integer(ProtocolJSON.dictionary(object["data"])["next_offset"] ?? -1)
                guard next > cursor.offset, next <= 1_000_000 else { throw HGError.message("猜你喜欢续页游标未前进，请刷新") }
                cursor.offset = next
            } else if let discovered = cellFlow(object) {
                cursor.flow = discovered; cursor.offset = 0
            } else {
                cursor.offset += max(1, batch.served)
            }
            if !batch.session.isEmpty { cursor.session = batch.session }
            batch.restarted = restarted
            batch.cursor = cursor
            return batch
        }
        throw HGError.message("猜你喜欢暂不可用，请稍后刷新")
    }

    /// Query pairs shared by both forms; the signed form overrides only the version.
    static func query(account: GuessAccount?, cursor: GuessCursor, signed: Bool, rticket: Int64?) -> [(String, String)] {
        var query: [(String, String)] = [("aid","8662"), ("app_name","novelread"), ("channel","update_64"), ("device_platform","android"),
            ("os","android"), ("ssmix","a"), ("device_type","25053RT47C"), ("device_brand","Redmi"), ("language","zh"),
            ("os_api","36"), ("os_version","16"), ("resolution","1280*2772"), ("dpi","520"), ("ac","wifi")]
        func put(_ key: String, _ value: String) {
            if let index = query.firstIndex(where: { $0.0 == key }) { query[index].1 = value } else { query.append((key, value)) }
        }
        if let account {
            for key in account.device.keys.sorted() where deviceKeys.contains(key) { put(key, account.device[key]!) }
        }
        let version = signed ? signedVersionCode : "73532"
        for (key, value) in [("version_code",version), ("version_name",signed ? signedVersionName : "7.3.5.32"), ("manifest_version_code",version),
                             ("update_version_code",version), ("tab_type","16"), ("bottom_tab_type","7"), ("landing_bottom_tab_type","7"),
                             ("offset",String(cursor.offset)), ("client_req_type", cursor.offset == 0 ? "1" : "2")] { put(key, value) }
        if let rticket { put("_rticket", String(rticket)) }
        if !cursor.session.isEmpty { put("session_id", cursor.session) }
        if let flow = cursor.flow {
            for (key, value) in [("cell_id",flow.cellID), ("plan_id",flow.planID), ("version_tag",flow.versionTag), ("client_template","7"),
                                 ("change_type","0"), ("client_req_type","2"),
                                 ("filter_ids",cursor.filterIDs.suffix(filterLimit).joined(separator: ","))] { put(key, value) }
        }
        return query
    }

    static func request(account: GuessAccount?, session: String, offset: Int, host: String = hosts[0], rticket: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> URLRequest {
        var cursor = GuessCursor(); cursor.session = session; cursor.offset = offset
        return try request(account: account, cursor: cursor, host: host, rticket: rticket)
    }

    static func request(account: GuessAccount?, cursor: GuessCursor, host: String = hosts[0], rticket: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> URLRequest {
        guard (0...maxOffset).contains(cursor.offset) else { throw HGError.message("猜你喜欢分页超出范围") }
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = cursor.flow == nil ? entryPath : cellPath
        components.percentEncodedQuery = query(account: account, cursor: cursor, signed: false, rticket: rticket)
            .map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("com.dragon.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("0", forHTTPHeaderField: "X-XS-From-Web")
        request.setValue("2", forHTTPHeaderField: "Sdk-Version")
        if let account { request.setValue(account.cookie, forHTTPHeaderField: "Cookie") }
        return request
    }

    /// The registered identity and device fields go first in the official order, the feed's parameters override them,
    /// and pv_player follows the feed version. The signer appends the jittered `_rticket` it signs.
    static func signedRequest(account: GuessAccount?, cursor: GuessCursor, identity: RegisteredIdentity, host: String, sign: Sign) async throws -> URLRequest {
        let device = identity.device.merging(["version_code":signedVersionCode, "manifest_version_code":signedVersionCode,
            "update_version_code":signedVersionCode, "pv_player":signedVersionCode, "version_name":signedVersionName]) { $1 }
        var pairs = DramaAPI.playbackQuery(device)
        for (key, value) in query(account: account, cursor: cursor, signed: true, rticket: nil) {
            if let index = pairs.firstIndex(where: { $0[0] == key }) { pairs[index][1] = value } else { pairs.append([key, value]) }
        }
        let signed = try await sign("https://\(host)\(cursor.flow == nil ? entryPath : cellPath)", pairs, device)
        var request = URLRequest(url: signed.url, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        for (name, value) in signed.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(signedUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=utf-8,application/x-protobuf", forHTTPHeaderField: "Accept")
        request.setValue("0", forHTTPHeaderField: "x-xs-from-web")
        request.setValue("2", forHTTPHeaderField: "sdk-version")
        let cookie = account?.cookie ?? identity.appDeviceCookie
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        return request
    }

    private static func recommendTab(_ object: [String: Any]) -> [String: Any]? {
        ProtocolJSON.array(ProtocolJSON.dictionary(object["data"])["tab_item"]).map(ProtocolJSON.dictionary)
            .first(where: { ProtocolJSON.text($0["tab_type"]) == "16" })
    }

    /// Only an explicitly enabled single-column continuation with complete identifiers is used.
    static func cellFlow(_ object: [String: Any]) -> GuessFlow? {
        guard let tab = recommendTab(object), (tab["bottom_unlimited"] as? Bool) == true || ProtocolJSON.text(tab["bottom_unlimited"]) == "1",
              ProtocolJSON.integer(tab["client_template"] ?? -1) == 7 else { return nil }
        let cell = ProtocolJSON.dictionary(ProtocolJSON.array(tab["cell_data"]).first)
        let cellID = first(cell["cell_id_str"], cell["cell_id"]), planID = first(tab["bookstore_id"])
        let version = ProtocolJSON.text(tab["version_tag"])
        func numeric(_ value: String) -> Bool { value.count <= 30 && value.first != "0" && !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber } }
        guard numeric(cellID), numeric(planID), version.count <= 4096,
              !version.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return GuessFlow(cellID: cellID, planID: planID, versionTag: version)
    }

    /// Normalizes a cell continuation reply into the entry shape so parsing stays the same. Its has_more=false still
    /// brings new works; the pager's request cap and dedupe end the round.
    static func parseCell(_ object: [String: Any]) throws -> GuessBatch {
        let code = ProtocolJSON.integer(object["code"] ?? -1)
        guard object["code"] != nil, code == 0 else { throw HGError.message("猜你喜欢续刷暂不可用（错误码 \(code)），请稍后刷新") }
        let data = ProtocolJSON.dictionary(object["data"])
        guard let view = data["cell_view"] as? [String: Any] else { throw HGError.message("猜你喜欢续刷单元缺失") }
        let cell: [String: Any] = view["cell_data"] != nil ? view : ["cell_data": [view]]
        let tab: [String: Any] = ["tab_type": 16, "session_id": ProtocolJSON.text(data["session_id"]), "cell_data": [cell]]
        return try parse(["code": 0, "data": ["tab_item": [tab]]])
    }

    static func parse(_ object: [String: Any]) throws -> GuessBatch {
        let code = ProtocolJSON.integer(object["code"] ?? -1)
        guard object["code"] != nil, code == 0 else { throw HGError.message("猜你喜欢暂不可用（错误码 \(code)），请稍后刷新") }
        guard let tab = recommendTab(object) else { throw HGError.message("猜你喜欢数据格式已变化") }
        let session = ProtocolJSON.text(tab["session_id"])
        guard session.count <= 4096, !session.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw HGError.message("猜你喜欢分页标记无效")
        }
        // No 30-card cap: a large batch keeps every valid work after the thirtieth (hongguoTV 3d319a6).
        var seen = Set<String>(), dramas = [Drama](), served = 0
        for cell in ProtocolJSON.array(tab["cell_data"]).map(ProtocolJSON.dictionary) {
            for card in ProtocolJSON.array(cell["cell_data"]).map(ProtocolJSON.dictionary) {
                for value in ProtocolJSON.array(card["video_data"]) {
                    served += 1
                    let raw = ProtocolJSON.dictionary(value), detail = ProtocolJSON.dictionary(raw["video_detail"])
                    let row = detail.isEmpty ? raw : detail
                    let id = first(row["series_id"], row["book_id"]), title = first(row["series_title"], row["book_name"], row["title"])
                    guard id.count <= 24, ProtocolJSON.identifier(id) != nil, !title.isEmpty, seen.insert(id).inserted else { continue }
                    dramas.append(Drama(id: id, title: title, coverURL: clean(first(row["series_cover"], row["cover"])),
                        summary: first(row["series_intro"], row["video_desc"]), episodeCount: max(0, ProtocolJSON.integer(row["episode_cnt"]))))
                }
            }
        }
        return GuessBatch(dramas: dramas, session: session, served: served)
    }

    private static func first(_ values: Any?...) -> String {
        values.map { ProtocolJSON.text($0).trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
    }
    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&").replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? ""
    }
}

/// One browse round of 猜你喜欢 for one owner. The feed gives a few cards per batch and its has_more flags are
/// unreliable, so a page reads up to 3 batches until 6 new cards arrive; a page with nothing new ends the round.
/// `GuessFeed.batch` advances the server cursor (rows served on the entry, next_offset on the cell continuation).
///
/// A refresh by the same owner keeps the last 540 shown ids (hongguoTV 3d319a6): a rebuilt server session that only
/// returns old works is reported as such instead of replaying them as new recommendations.
actor GuessPager {
    nonisolated let owner: UUID?
    private let fetch: @Sendable (GuessCursor) async throws -> GuessBatch
    private var cursor = GuessCursor()
    private var seen = [String]()
    private var inherit: GuessPager?
    private var batches = 0

    init(owner: UUID?, previous: GuessPager? = nil, fetch: @escaping @Sendable (GuessCursor) async throws -> GuessBatch) {
        self.owner = owner; self.fetch = fetch
        inherit = previous?.owner == owner ? previous : nil
    }

    var seenIDs: [String] { seen }

    func next() async throws -> DramaPage {
        if let previous = inherit { inherit = nil; seen = await previous.seenIDs }
        let firstPage = batches == 0
        var dramas = [Drama](), requests = 0
        while dramas.count < 6 && requests < 3 && cursor.offset <= GuessFeed.maxOffset {
            var request = cursor
            request.filterIDs = seen
            let batch = try await fetch(request)
            requests += 1; batches += 1
            cursor = batch.cursor
            for drama in batch.dramas where !seen.contains(drama.id) { seen.append(drama.id); dramas.append(drama) }
            if seen.count > 540 { seen.removeFirst(seen.count - 540) }
        }
        if firstPage && dramas.isEmpty && !seen.isEmpty {
            throw HGError.message("推荐接口暂未返回新作品（最近已去重 \(seen.count) 部），可稍后刷新，或切换其他分类继续发现。")
        }
        return DramaPage(dramas: dramas, hasMore: !dramas.isEmpty && cursor.offset <= GuessFeed.maxOffset, nextOffset: batches)
    }
}

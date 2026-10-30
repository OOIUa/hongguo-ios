// SPDX-License-Identifier: GPL-3.0-only
// Adapted from hongguo-android 0.7.10 GuessFeed.kt and tsukiyo-zero/hongguoTV kotlin-tv/core
// RecommendationFeed.kt at 97c5b1d15d (2026-10-30); path and card shape referenced there from Xanerix/guoapp.
import Foundation

struct GuessBatch: Sendable {
    let dramas: [Drama]
    /// Server pagination token; kept in memory only.
    let session: String
}

/// The account identity a 猜你喜欢 request may carry. nil requests the anonymous feed.
struct GuessAccount: Sendable {
    let cookie: String
    let deviceID: String
    let installID: String
    let device: [String: String]
}

/// Official App 书城「猜你喜欢」(bookmall tab_type=16). Unsigned GET; no exposure/click/finish reporting.
enum GuessFeed {
    static let url = URL(string: "https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/bookmall/tab/v1/")!
    static let maxOffset = 100
    private static let deviceKeys: Set<String> = ["channel", "device_platform", "os", "ssmix", "device_type", "device_brand",
        "language", "os_api", "os_version", "resolution", "dpi", "ac"]

    static func request(account: GuessAccount?, session: String, offset: Int, rticket: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> URLRequest {
        guard (0...maxOffset).contains(offset) else { throw HGError.message("猜你喜欢分页超出范围") }
        if let account, ProtocolJSON.identifier(account.deviceID) == nil || ProtocolJSON.identifier(account.installID) == nil {
            throw HGError.message("账号设备身份无效，请重新登录")
        }
        var query: [(String, String)] = [("aid","8662"), ("app_name","novelread"), ("channel","update_64"), ("device_platform","android"),
            ("os","android"), ("ssmix","a"), ("device_type","25053RT47C"), ("device_brand","Redmi"), ("language","zh"),
            ("os_api","36"), ("os_version","16"), ("resolution","1280*2772"), ("dpi","520"), ("ac","wifi")]
        func put(_ key: String, _ value: String) {
            if let index = query.firstIndex(where: { $0.0 == key }) { query[index].1 = value } else { query.append((key, value)) }
        }
        if let account {
            for key in account.device.keys.sorted() where deviceKeys.contains(key) { put(key, account.device[key]!) }
            put("device_id", account.deviceID); put("iid", account.installID)
        }
        for (key, value) in [("version_code","73532"), ("version_name","7.3.5.32"), ("manifest_version_code","73532"),
                             ("update_version_code","73532"), ("tab_type","16"), ("bottom_tab_type","7"), ("landing_bottom_tab_type","7"),
                             ("offset",String(offset)), ("client_req_type", offset == 0 ? "1" : "2"), ("_rticket",String(rticket))] { put(key, value) }
        if !session.isEmpty { put("session_id", session) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = query.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("com.dragon.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("0", forHTTPHeaderField: "X-XS-From-Web")
        request.setValue("2", forHTTPHeaderField: "Sdk-Version")
        if let account { request.setValue(account.cookie, forHTTPHeaderField: "Cookie") }
        return request
    }

    static func parse(_ object: [String: Any]) throws -> GuessBatch {
        let code = ProtocolJSON.integer(object["code"] ?? -1)
        guard object["code"] != nil, code == 0 else { throw HGError.message("猜你喜欢暂不可用（错误码 \(code)），请稍后刷新") }
        guard let tab = ProtocolJSON.array(ProtocolJSON.dictionary(object["data"])["tab_item"]).map(ProtocolJSON.dictionary)
            .first(where: { ProtocolJSON.text($0["tab_type"]) == "16" }) else { throw HGError.message("猜你喜欢数据格式已变化") }
        let session = ProtocolJSON.text(tab["session_id"])
        guard session.count <= 4096, !session.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw HGError.message("猜你喜欢分页标记无效")
        }
        var seen = Set<String>(), dramas = [Drama]()
        for cell in ProtocolJSON.array(tab["cell_data"]).map(ProtocolJSON.dictionary) {
            for card in ProtocolJSON.array(cell["cell_data"]).map(ProtocolJSON.dictionary) {
                for value in ProtocolJSON.array(card["video_data"]) {
                    let raw = ProtocolJSON.dictionary(value), detail = ProtocolJSON.dictionary(raw["video_detail"])
                    let row = detail.isEmpty ? raw : detail
                    let id = first(row["series_id"], row["book_id"]), title = first(row["series_title"], row["book_name"], row["title"])
                    guard id.count <= 24, ProtocolJSON.identifier(id) != nil, !title.isEmpty, seen.insert(id).inserted, dramas.count < 30 else { continue }
                    dramas.append(Drama(id: id, title: title, coverURL: clean(first(row["series_cover"], row["cover"])),
                        summary: first(row["series_intro"], row["video_desc"]), episodeCount: max(0, ProtocolJSON.integer(row["episode_cnt"]))))
                }
            }
        }
        return GuessBatch(dramas: dramas, session: session)
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
actor GuessPager {
    let owner: UUID?
    private let fetch: @Sendable (String, Int) async throws -> GuessBatch
    private var session = ""
    private var offset = 0
    private var seen = [String]()

    init(owner: UUID?, fetch: @escaping @Sendable (String, Int) async throws -> GuessBatch) { self.owner = owner; self.fetch = fetch }

    func next() async throws -> DramaPage {
        var dramas = [Drama](), requests = 0
        while dramas.count < 6 && requests < 3 && offset <= GuessFeed.maxOffset {
            let batch = try await fetch(session, offset)
            requests += 1
            if !batch.session.isEmpty { session = batch.session }
            offset += 1
            for drama in batch.dramas where !seen.contains(drama.id) { seen.append(drama.id); dramas.append(drama) }
            if seen.count > 540 { seen.removeFirst(seen.count - 540) }
        }
        return DramaPage(dramas: dramas, hasMore: !dramas.isEmpty && offset <= GuessFeed.maxOffset, nextOffset: offset)
    }
}

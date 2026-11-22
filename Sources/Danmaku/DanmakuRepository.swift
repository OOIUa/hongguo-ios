// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android 0.7.32 (PR #13, GPL-3.0-only), danmaku/DanmakuRepository.kt;
// endpoint, payload and risk-control handling are unchanged. Signing uses this app's own
// ProtocolSigner (app 形态完整签名头) 与 v5 player 形态，请求设备身份与播放保持一致。
import Foundation

/// One official bullet comment, anchored to a playback offset within its episode.
struct Danmaku: Equatable, Sendable {
    let id: String
    let offsetMs: Int64
    let text: String
    let diggCount: Int
}

/// 评论接口的地址与请求体字段集中在这里。接口本身变化（路径、字段、主机）时只改这一个枚举，
/// 渲染、加载与缓存逻辑都不用动。
enum CommentProtocol {
    /// 评论列表路径模板。
    static let pathTemplate = "/novel/commentapi/comment/list/%@/v1/"

    /// 历史可用主机；与播放共用同一网关，主程序换域时优先跟随它。
    static let primaryHost = "https://api5-normal-sinfonlinea.fqnovel.com"
    static let fallbackHost = "https://api5-normal-hl.fqnovel.com"

    static let commentSource = 601
    static let serverChannel = 1000
    static let groupType = 30
    static let commentType = 20
    static let sort = 1
    static let count = 90
    static let aid = 8662
    static let complianceStatus = 0

    static func path(_ vid: String) -> String { String(format: pathTemplate, vid) }

    /// 依次尝试的主机：历史主域在前，随后是播放当前使用的主域，最后是历史备用域。
    static func hosts() -> [String] {
        [primaryHost, "https://" + DramaAPI.playbackHost, fallbackHost].deduplicated()
    }
}

private extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

/// 请求签名形态：App 形态（完整签名头）与播放器形态（v5 三头）。
enum DanmakuSignatureMode: CaseIterable, Sendable {
    case app
    case player
}

/// 评论窗口：一页评论加服务端建议的下一窗口起点。
struct DanmakuWindow: Sendable {
    let comments: [Danmaku]
    let nextStartMs: Int64
}

/// Pulls the platform's official time-anchored comments (弹幕) for one episode, one 30-second
/// window per request. Requests are serialized and throttled because the endpoint is
/// gateway-policed; a risk-control reply carries a server-dictated cooldown that is honored
/// before retrying. Empty or censored replies degrade to an empty window instead of failing.
///
/// 主机与签名形态会在失败或空正文时自动轮换：上游只改其中一维（换域或换签名族）时，
/// 弹幕不需要改代码就能继续工作。
actor DanmakuRepository {
    static let windowMs: Int64 = 30_000

    private let signer: ProtocolSigner
    /// 评论是匿名面，用每进程固定的随机安装身份，不用播放身份；查询与 medusa 必须一致。
    private let device: [String: String]
    /// 当前使用的主机与签名形态；成功后保持不变，失败或空正文时轮换。
    private var hostIndex = 0
    private var modeIndex = 0
    /// Negative means "no request yet": the first call must not sleep.
    private var lastRequestAt: TimeInterval = -1
    private let clock: @Sendable () -> TimeInterval
    private let nowMs: @Sendable () -> Int64
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    init(signer: ProtocolSigner = .shared, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         nowMs: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.signer = signer
        self.clock = clock
        self.nowMs = nowMs
        self.sleeper = sleeper
        // Anonymous comment identity: the platform bans identities it sees abused, so comments get
        // fresh install ids once per process instead of the playback identity.
        var profile = PlaybackRegistration.deviceProfile
        profile["version_code"] = "71332"; profile["manifest_version_code"] = "71332"
        profile["update_version_code"] = "71332"; profile["version_name"] = "7.1.3.32"
        profile["device_id"] = Self.randomInstallID()
        profile["iid"] = Self.randomInstallID()
        profile["cdid"] = UUID().uuidString.lowercased()
        self.device = profile
    }

    /// Fetches the window starting at startMs, following in-window pagination (bounded).
    func window(seriesID: String, vid: String, durationMs: Int64, startMs: Int64) async throws -> DanmakuWindow {
        var comments: [Danmaku] = []
        var cursor = ""
        var nextStart: Int64 = -1
        var pages = 0
        while true {
            let page = try await fetchWithRetry(seriesID: seriesID, vid: vid, durationMs: durationMs, startMs: startMs, cursor: cursor)
            comments += page.comments
            if nextStart < 0 { nextStart = page.nextStartMs }
            cursor = page.cursor
            pages += 1
            if !page.hasMore || cursor.isEmpty || pages >= Self.maxPagesPerWindow { break }
        }
        let start = nextStart > startMs ? nextStart : startMs + Self.windowMs
        return DanmakuWindow(comments: Self.dedupe(comments), nextStartMs: start)
    }

    private func fetchWithRetry(seriesID: String, vid: String, durationMs: Int64, startMs: Int64, cursor: String) async throws -> DanmakuPage {
        var attempt = 0
        while true {
            do {
                let raw = try await post(vid: vid, body: try Self.body(seriesID: seriesID, vid: vid, durationMs: durationMs, startMs: startMs, cursor: cursor))
                return try parse(raw, startMs: startMs)
            } catch let cooldown as Cooldown {
                guard attempt < Self.maxCooldownRetries else { throw HGError.message("弹幕接口风控中，请稍后再试") }
                attempt += 1
                try await sleeper(cooldown.seconds + Double(Int.random(in: 0..<1000)) / 1000)
            }
        }
    }

    private struct DanmakuPage {
        let comments: [Danmaku]
        let nextStartMs: Int64
        let cursor: String
        let hasMore: Bool
    }

    private struct Cooldown: Error { let seconds: TimeInterval }

    private static func body(seriesID: String, vid: String, durationMs: Int64, startMs: Int64, cursor: String) throws -> Data {
        let business: [String: Any] = ["book_id": seriesID, "start_offset_time": max(0, startMs),
            "playlet_item_duration": max(0, durationMs), "need_danmaku_guide_type": [1, 3, 4, 2]]
        let payload: [String: Any] = ["comment_source": CommentProtocol.commentSource, "server_channel": CommentProtocol.serverChannel,
            "group_id": vid, "group_type": CommentProtocol.groupType, "comment_type": CommentProtocol.commentType,
            "sort": CommentProtocol.sort, "business_param": business, "count": CommentProtocol.count,
            "cursor": cursor, "aid": CommentProtocol.aid, "compliance_status": CommentProtocol.complianceStatus]
        return try ProtocolJSON.data(payload)
    }

    /// 取一页评论。先用当前主机与签名形态；遇到空正文（网关软拦截的固定表现）或传输失败时，
    /// 轮换到下一个主机／签名形态再试一次——上游只改其中一维时无需改代码即可自愈。
    private func post(vid: String, body: Data) async throws -> String {
        try await throttle()
        var firstFailure: Error?
        for _ in 0..<Self.maxTransportTries {
            do {
                let text = try await send(vid: vid, body: body)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
            advanceTransport()
        }
        if let firstFailure { throw firstFailure }
        return ""
    }

    private func send(vid: String, body: Data) async throws -> String {
        let hosts = CommentProtocol.hosts()
        let base = hosts[hostIndex % hosts.count] + CommentProtocol.path(vid)
        let query = device.keys.sorted().map { [$0, device[$0]!] }
        let now = nowMs()
        let signed: SignedProtocolRequest
        switch DanmakuSignatureMode.allCases[modeIndex % DanmakuSignatureMode.allCases.count] {
        case .app:
            signed = try await signer.signedRequest(baseURL: base, query: query, body: body, device: device)
        case .player:
            // v5 三头形态（x-khronos / x-helios / x-medusa），对齐播放的 signPlaybackV5。
            signed = try await signer.signedPlaybackV5(baseURL: base, query: query, body: body, device: device, now: now)
        }
        var headers = signed.headers
        headers["User-Agent"] = PlaybackRegistration.userAgent
        headers["comment-source"] = String(CommentProtocol.commentSource)
        headers["server-channel"] = String(CommentProtocol.serverChannel)
        if headers["Content-Type"] == nil { headers["Content-Type"] = "application/json; charset=utf-8" }
        var request = URLRequest(url: signed.url, timeoutInterval: 30)
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data = try await DramaAPI.responseData(for: request, playback: false) { attempt in
            try await Self.session.data(for: attempt)
        }
        guard data.count <= Self.maxBytes else { throw HGError.message("弹幕响应过大") }
        return String(decoding: data, as: UTF8.self)
    }

    /// 主机用完再换签名形态：两个维度都轮换，任一维度变化都能自愈。
    private func advanceTransport() {
        hostIndex += 1
        if hostIndex >= CommentProtocol.hosts().count {
            hostIndex = 0
            modeIndex = (modeIndex + 1) % DanmakuSignatureMode.allCases.count
        }
    }

    private func throttle() async throws {
        let now = clock()
        if lastRequestAt >= 0 {
            let wait = Self.throttleSeconds + Double(Int.random(in: 0..<240)) / 1000 - (now - lastRequestAt)
            if wait > 0 { try await sleeper(wait) }
        }
        lastRequestAt = clock()
    }

    private func parse(_ raw: String, startMs: Int64) throws -> DanmakuPage {
        let deadWindow = DanmakuPage(comments: [], nextStartMs: startMs + Self.windowMs, cursor: "", hasMore: false)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return deadWindow }
        // Risk-control interceptions sometimes answer plain text; treat them as a dead window.
        guard let payload = try? ProtocolJSON.object(Data(trimmed.utf8)) else { return deadWindow }
        if ProtocolJSON.integer(payload["code"]) != 0 {
            let cooldown = Self.cooldownSeconds(ProtocolJSON.text(payload["message"] ?? payload["msg"]))
            if cooldown > 0 { throw Cooldown(seconds: cooldown) }
            throw HGError.message("弹幕接口暂不可用")
        }
        guard let data = ProtocolJSON.dictionary(payload["data"]) as [String: Any]? else { return deadWindow }
        let rows = ProtocolJSON.array(data["data_list"])
        let comments: [Danmaku] = rows.compactMap { item in
            let row = ProtocolJSON.dictionary(item)
            let comment = ProtocolJSON.dictionary(row["comment"])
            guard !comment.isEmpty else { return nil }
            let common = ProtocolJSON.dictionary(comment["common"])
            let text = ProtocolJSON.text(ProtocolJSON.dictionary(common["content"])["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let offset = ProtocolJSON.integer(ProtocolJSON.dictionary(comment["expand"])["offset_time"])
            guard !text.isEmpty, offset > 0 else { return nil }
            let digg = ProtocolJSON.integer(ProtocolJSON.dictionary(ProtocolJSON.dictionary(comment["stat"])["digg_count"])["value"])
            return Danmaku(id: ProtocolJSON.text(comment["comment_id"]), offsetMs: Int64(max(0, offset)), text: text, diggCount: max(0, digg))
        }
        let listInfo = ProtocolJSON.dictionary(data["common_list_info"])
        var nextStart = Int64(ProtocolJSON.integer(ProtocolJSON.dictionary(data["extra"])["next_query_danmaku_list_time"]))
        if nextStart == 0 { nextStart = -1 }
        if nextStart <= startMs { nextStart = startMs + Self.windowMs }
        return DanmakuPage(comments: comments, nextStartMs: nextStart, cursor: ProtocolJSON.text(listInfo["cursor"]),
                           hasMore: ProtocolJSON.integer(listInfo["has_more"]) != 0)
    }

    // MARK: - Shared helpers

    static func dedupe(_ rows: [Danmaku]) -> [Danmaku] {
        var seen = [String: Danmaku]()
        for row in rows { seen[row.id.isEmpty ? "anonymous:\(row.offsetMs):\(row.text)" : "id:\(row.id)"] = row }
        return seen.values.sorted { ($0.offsetMs, $0.id, $0.text) < ($1.offsetMs, $1.id, $1.text) }
    }

    /// The risk-control reply message embeds a JSON payload with ban seconds.
    static func cooldownSeconds(_ message: String) -> TimeInterval {
        guard let detail = try? ProtocolJSON.object(Data(message.utf8)) else { return 0 }
        let minSeconds = ProtocolJSON.integer(detail["min_ban_time"])
        let maxSeconds = ProtocolJSON.integer(detail["max_ban_time"])
        let seconds = minSeconds > 0 ? minSeconds : maxSeconds
        return TimeInterval(max(0, seconds))
    }

    static func randomInstallID() -> String {
        "1" + String((0..<15).map { _ in Character(String(Int.random(in: 0...9))) })
    }

    private static let maxTransportTries = 2
    private static let maxPagesPerWindow = 3
    private static let maxCooldownRetries = 2
    private static let throttleSeconds: TimeInterval = 0.18
    private static let maxBytes = 2 * 1024 * 1024

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}

/// One shared repository for every episode the player opens.
enum DanmakuAPI {
    static let repository = DanmakuRepository()
}

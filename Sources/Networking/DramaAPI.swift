// SPDX-License-Identifier: GPL-3.0-only
// Adapted from OOIUa/hongguo-android Client/WebSource/AppSource and their attributed upstreams.
import Foundation

private final class ProtocolSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

actor DramaAPI {
    static let shared = DramaAPI()
    private let session: URLSession
    private let delegate = ProtocolSessionDelegate()
    private let signer: ProtocolSigner
    private let deviceID: String
    private var nextRequestAt = Date.distantPast
    private var detailCache: [String: DramaDetail] = [:]
    private var detailExpiry: [String: Date] = [:]
    private var detailOrder: [String] = []
    private var seenByDiscovery: [String: [String]] = [:]
    private var searchCursors: [String: SearchCursor] = [:]
    private(set) var lastPlaybackTrace = ""
    private var registrationFailedAt: Date?
    private var relatedCache: [String: [RelatedWork]] = [:]
    private var releaseCache: [String: String] = [:]
    private let suggestionWebID = UUID().uuidString.lowercased()
    private var filterCache: [String: [FilterGroup]] = [:]

    private struct SearchCursor { var upstreamOffset = 0; var passback = ""; var searchID = ""; var results = [Drama](); var hasMore = true; var fetchedAt = Date() }

    init(resourceDirectory: URL? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 18; config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 3
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        signer = resourceDirectory.map { ProtocolSigner(resourceDirectory: $0) } ?? .shared
        let bytes = HGCrypto.random(7)
        let value = bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        deviceID = String(1_000_000_000_000_000 + value % 9_000_000_000_000_000)
    }

    func home(feed: String, offset: Int) async throws -> DramaPage {
        switch feed {
        case "comic": return try await rank(offset: offset)
        case "latest": return try await browse(genre: "short_play", filters: ["sort":"online_time"], offset: offset)
        default: return try await browse(genre: "short_play", filters: ["sort":"hot_score"], offset: offset)
        }
    }

    func browse(genre: String, filters: [String: String], offset: Int) async throws -> DramaPage {
        let genre = ["short_play", "comic_series", "ai_series"].contains(genre) ? genre : "short_play"
        let start = max(0, offset)
        let key = genre + "|" + filters.keys.sorted().map { "\($0)=\(filters[$0] ?? "")" }.joined(separator: "&")
        if start == 0 {
            if seenByDiscovery[key] == nil, seenByDiscovery.count >= 32, let oldest = seenByDiscovery.keys.first { seenByDiscovery.removeValue(forKey: oldest) }
            seenByDiscovery[key] = []
        }
        var seen = seenByDiscovery[key] ?? []
        var cursor = start, dramas = [Drama](), more = false
        let selected = selection(genre: genre, filters: filters)
        // A bounded continuation fills sparse pages without turning a single gesture into an unbounded crawl.
        for _ in 0..<3 {
            let body: [String: Any] = ["filter_ids":seen.suffix(180).joined(separator: ","), "req_scene":genre == "short_play" ? "default" : genre,
                "offset":cursor, "need_selector_panel":false, "limit":18 - dramas.count, "select_items":selected,
                "session_id":"", "req_type":"only_content", "client_req_type":3]
            let response = try await api(path: "/reading/distribution/category/landpage/v", body: body)
            let data = ProtocolJSON.dictionary(response["data"]), raw = ProtocolJSON.array(data["video_data"])
            guard !raw.isEmpty else { more = false; break }
            var known = Set(seen)
            for item in raw {
                if let drama = parseDrama(ProtocolJSON.dictionary(item)), known.insert(drama.id).inserted { dramas.append(drama); seen.append(drama.id) }
            }
            let declared = ProtocolJSON.integer(data["next_offset"])
            let next = declared > cursor ? declared : cursor + raw.count
            more = ProtocolJSON.bool(data["has_more"], default: true) && next > cursor
            cursor = next
            if !more || dramas.count >= 18 { break }
        }
        seenByDiscovery[key] = Array(seen.suffix(180))
        return DramaPage(dramas: dramas, hasMore: more && !dramas.isEmpty, nextOffset: cursor)
    }

    func filters(genre: String) async throws -> [FilterGroup] {
        let genre = ["short_play", "comic_series", "ai_series"].contains(genre) ? genre : "short_play"
        if let cached = filterCache[genre] { return cached }
        let body: [String: Any] = ["filter_ids":"", "req_scene":genre == "short_play" ? "default" : genre, "offset":0, "limit":1,
            "need_selector_panel":true, "req_type":"default", "client_req_type":3, "select_items":selection(genre: genre, filters: [:]), "session_id":""]
        let response = try await api(path: "/reading/distribution/category/landpage/v", body: body)
        let rows = ProtocolJSON.array(ProtocolJSON.dictionary(response["data"])["selector_rows"])
        let groups: [FilterGroup] = rows.compactMap { value in
            let row = ProtocolJSON.dictionary(value), id = ProtocolJSON.text(row["type"])
            guard !id.isEmpty, id != "genre" else { return nil }
            let options: [FilterOption] = ProtocolJSON.array(row["items"]).compactMap { value in
                let item = ProtocolJSON.dictionary(value), id = ProtocolJSON.text(item["selector_item_id"]), name = ProtocolJSON.text(item["show_name"])
                return name.isEmpty ? nil : FilterOption(id: id, name: name)
            }
            return options.isEmpty ? nil : FilterGroup(id: id, name: ProtocolJSON.text(row["row_name"]), options: options)
        }
        if !groups.isEmpty { filterCache[genre] = groups }
        return groups
    }

    /// The expected release of an upcoming work. The related plan only says 预告 and how many reserved; searching the full
    /// title answers a reservation card (`subscribe_items`) with the official `sub_info` (such as 预计11月21日上线) and a
    /// `schedule_publish_time` in seconds (observed 2026-11-10, Android issue #3). Only a card with the same id counts.
    func upcomingRelease(id: String, title: String) async throws -> String {
        let query = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard ProtocolJSON.identifier(id) != nil, !query.isEmpty else { return "" }
        if let cached = releaseCache[id] { return cached }
        let response = try await api(path: "/reading/bookapi/search/tab/v", extra: [["query",query],["tab_name","feed"],["search_source","1"],
            ["offset","0"],["count","10"],["use_correct","true"]])
        guard let release = Self.upcomingRelease(response, id: id) else { return "" }
        let label = releaseLabel(release.text, publishAtMs: release.publishAtMs)
        if !label.isEmpty { releaseCache[id] = label }
        return label
    }

    /// The reservation card with id `id` in a search response: its official text and its time in milliseconds (0 if absent).
    static func upcomingRelease(_ response: [String: Any], id: String) -> (text: String, publishAtMs: Int64)? {
        for tab in ProtocolJSON.array(response["search_tabs"]) {
            for cell in ProtocolJSON.array(ProtocolJSON.dictionary(tab)["data"]) {
                for value in ProtocolJSON.array(ProtocolJSON.dictionary(cell)["subscribe_items"]) {
                    let row = ProtocolJSON.dictionary(value)
                    let itemID = ProtocolJSON.text(row["item_id_str"]).isEmpty ? ProtocolJSON.text(row["item_id"]) : ProtocolJSON.text(row["item_id_str"])
                    guard itemID.trimmingCharacters(in: .whitespaces) == id else { continue }
                    let text = String(ProtocolJSON.text(row["sub_info"]).split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40))
                    let stamp = publishMilliseconds(row["schedule_publish_time"])
                    return text.isEmpty && stamp == 0 ? nil : (text, stamp)
                }
            }
        }
        return nil
    }

    /// A platform publish time given in seconds or milliseconds, as milliseconds; 0 when absent.
    static func publishMilliseconds(_ value: Any?) -> Int64 {
        let raw = max(0, Int64(ProtocolJSON.text(value)) ?? Int64(ProtocolJSON.integer(value)))
        return raw > 0 && raw <= 9_999_999_999 ? raw * 1000 : raw
    }

    func search(query: String, offset: Int) async throws -> DramaPage {
        let keyword = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), start = max(0, offset)
        guard !keyword.isEmpty else { return DramaPage(dramas: [], hasMore: false, nextOffset: start) }
        do {
            searchCursors = searchCursors.filter { Date().timeIntervalSince($0.value.fetchedAt) <= 600 }
            if searchCursors[keyword] == nil, searchCursors.count >= 16, let oldest = searchCursors.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key { searchCursors.removeValue(forKey: oldest) }
            var cursor = searchCursors[keyword] ?? SearchCursor()
            if Date().timeIntervalSince(cursor.fetchedAt) > 600 { cursor = SearchCursor() }
            var known = Set(cursor.results.map(\.id))
            for _ in 0..<8 {
                if cursor.results.count >= start + 20 || !cursor.hasMore { break }
                var extra = [["query",keyword],["tab_name","feed"],["search_source","1"],["offset",String(cursor.upstreamOffset)],["count","10"],["use_correct","true"]]
                if !cursor.passback.isEmpty { extra.append(["passback",cursor.passback]) }
                if !cursor.searchID.isEmpty { extra.append(["search_id",cursor.searchID]) }
                let response = try await api(path: "/reading/bookapi/search/tab/v", extra: extra)
                let tab = ProtocolJSON.dictionary(ProtocolJSON.array(response["search_tabs"]).first)
                let raw = ProtocolJSON.array(tab["data"])
                for value in raw { if let drama = parseSearch(ProtocolJSON.dictionary(value)), known.insert(drama.id).inserted { cursor.results.append(drama) } }
                let next = ProtocolJSON.integer(tab["next_offset"])
                let advance = next > cursor.upstreamOffset ? next : cursor.upstreamOffset + raw.count
                cursor.hasMore = ProtocolJSON.bool(tab["has_more"]) && !raw.isEmpty && advance > cursor.upstreamOffset
                cursor.upstreamOffset = advance
                let passback = ProtocolJSON.text(tab["passback"]), searchID = ProtocolJSON.text(tab["search_id"])
                if !passback.isEmpty { cursor.passback = passback }; if !searchID.isEmpty { cursor.searchID = searchID }
            }
            searchCursors[keyword] = cursor
            let page = Array(cursor.results.dropFirst(start).prefix(20))
            if !page.isEmpty { return DramaPage(dramas: page, hasMore: start + page.count < cursor.results.count || cursor.hasMore, nextOffset: start + page.count) }
            return try await webSearch(keyword, offset: start)
        } catch {
            try Task.checkCancellation()
            let fallback = try? await webSearch(keyword, offset: start)
            if let fallback, !fallback.dramas.isEmpty { return fallback }
            throw error
        }
    }

    func detail(drama: Drama) async throws -> DramaDetail {
        guard ProtocolJSON.identifier(drama.id) != nil else { throw HGError.message("剧集编号无效") }
        if let cached = detailCache[drama.id], (detailExpiry[drama.id] ?? .distantPast) > Date() { return cached }
        do {
            let biz: [String: Any] = ["detail_page_version":0, "disable_digg_stat":false,
                "image_shrink_datas_str":"W3siaW1hZ2VfdHlwZSI6MywiaW1hZ2Vfd2lkdGgiOjkwMCwic2hyaW5rX3R5cGUiOjN9LHsiaW1hZ2VfdHlwZSI6NCwiaW1hZ2Vfd2lkdGgiOjU0LCJzaHJpbmtfdHlwZSI6NH1d",
                "need_all_video_definition":false, "need_mp4_align":false, "screen_width_px":"900", "source":7, "use_os_player":false, "use_server_dns":false]
            let response = try await api(path: "/novel/player/multi_video_detail/preload/v1", body: ["biz_param":biz, "dr_scene":"preload", "series_id":drama.id])
            let data = ProtocolJSON.dictionary(response["data"]), entry = ProtocolJSON.dictionary(data[drama.id]), video = ProtocolJSON.dictionary(entry["video_data"])
            let intro = ProtocolJSON.text(video["series_intro"])
            let episodes: [Episode] = ProtocolJSON.array(video["video_list"]).compactMap { value in
                let row = ProtocolJSON.dictionary(value)
                guard let id = ProtocolJSON.identifier(row["vid"]) else { return nil }
                let index = max(1, ProtocolJSON.integer(row["vid_index"]))
                let rawTitle = ProtocolJSON.text(row["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let title = rawTitle.isEmpty || (!intro.isEmpty && intro.contains(rawTitle)) ? "第\(index)集" : String(rawTitle.prefix(30))
                return Episode(id: id, index: index, title: title)
            }.sorted { $0.index < $1.index }
            guard !episodes.isEmpty else { throw HGError.message("暂未取得分集列表") }
            let updated = Drama(id: drama.id, title: firstText(video["series_title"], drama.title), coverURL: cleanURL(firstText(video["series_cover"], drama.coverURL)), summary: intro.isEmpty ? drama.summary : intro, episodeCount: max(episodes.count, ProtocolJSON.integer(video["episode_cnt"])))
            let result = DramaDetail(drama: updated, episodes: episodes); cacheDetail(result); return result
        } catch {
            try Task.checkCancellation()
            if let result = try? await webDetail(drama) { cacheDetail(result); return result }
            throw error
        }
    }

    func rank(board: RankBoard, page: Int) async throws -> RankPage {
        guard (1...100).contains(page) else { throw HGError.message("榜单页码无效") }
        let data = try await fetch(url: WebsiteCatalog.rankURL(board, page: page), headers: ["User-Agent":WebsiteCatalog.userAgent, "Accept":"text/html,*/*"])
        return try WebsiteCatalog.parseRank(String(decoding: data, as: UTF8.self), board: board, page: page)
    }

    func suggestions(query: String) async throws -> [String] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80, let url = WebsiteCatalog.suggestionURL(query: clean, webID: suggestionWebID) else { return [] }
        return WebsiteCatalog.parseSuggestions(try await request(url: url, body: nil, headers: ["User-Agent":WebsiteCatalog.userAgent, "Accept":"application/json"]))
    }

    func related(id: String) async throws -> [RelatedWork] {
        guard ProtocolJSON.identifier(id) != nil else { throw HGError.message("作品编号无效") }
        if let cached = relatedCache[id] { return cached }
        var failure: Error = HGError.message("相关作品暂不可用")
        for host in RelatedWorks.hosts {
            try Task.checkCancellation()
            do {
                let device = RelatedWorks.device()
                let signed = try await signer.signedRequest(baseURL: "https://" + host + RelatedWorks.path, query: RelatedWorks.query(id: id, device: device), body: nil, device: device)
                var headers = signed.headers
                headers["User-Agent"] = "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
                headers["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
                headers["x-tt-request-tag"] = "t=0;n=0"; headers["sdk-version"] = "2"; headers["passport-sdk-version"] = "50561"; headers["x-xs-from-web"] = "0"
                let works = try RelatedWorks.parse(try await request(url: signed.url, body: nil, headers: headers), currentID: id)
                if relatedCache.count >= 8, let oldest = relatedCache.keys.first { relatedCache.removeValue(forKey: oldest) }
                relatedCache[id] = works
                return works
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        throw failure
    }

    func track(episodeID: String) async throws -> VideoTrack {
        guard ProtocolJSON.identifier(episodeID) != nil else { throw HGError.message("分集编号无效") }
        // device_level=3 makes the server ship some episodes' 360P–720P as undecodable bytevc2, leaving only
        // 1080P; level 1 serves normal episodes the same ladder (synchronized from hongguoTV 0.1.12).
        let biz: [String: Any] = ["detail_page_version":0,"device_level":1,"disable_digg_stat":false,"need_all_video_definition":true,
            "need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024]
        let body = try ProtocolJSON.data(["biz_param":biz,"mixed_video_id_map":["1004":[episodeID]]])
        return try await playbackTrack(
            identity: { [self] in try await freshPlaybackIdentity() },
            single: { [self] identity in try await readSinglePlayback(episodeID: episodeID, identity: identity) },
            read: { [self] route, identity in try await readPlaybackRoute(route, episodeID: episodeID, body: body, identity: identity) },
            use: { [self] model in
                guard !model.isEmpty else { throw HGError.message("服务暂未返回当前分集片源") }
                return try await modelTrack(model)
            })
    }

    /// Picks a track from a playback model. Inline rows with neither a key nor a declared encryption state may use the
    /// model's fallback_api, whose answer must separately match id, full duration, quality and encryption
    /// (synchronized from hongguo-drama 5.5).
    func modelTrack(_ model: [String: Any], readFallback: (@Sendable (String) async throws -> [String: Any])? = nil) async throws -> VideoTrack {
        let read: @Sendable (String) async throws -> [String: Any] = readFallback ?? { [self] in try await request(url: try await checkedFallback($0), body: nil, headers: ["User-Agent":PlaybackRegistration.userAgent]) }
        let address = fallbackURL(model["fallback_api"])
        let inlineRows = (model["video_list"] as? [Any])?.count ?? (model["video_list"] as? [String: Any])?.count ?? 0
        guard inlineRows > 0 else {
            return try await fallbackTrack(try fallbackInfo(try await read(address)), address: address, read: read)
        }
        do {
            return try selectTrack(model, requireEncryption: true, minimumPixels: 0)
        } catch let onlyByteVC2 as ByteVC2Only {
            // Inline rows are all ByteVC2: the fallback model, and its compatibility request, may still carry HEVC.
            guard !address.isEmpty else { throw onlyByteVC2 }
            let info = try fallbackInfo(try await read(address))
            try Self.confirmSameVideo(model, info)
            return try await fallbackTrack(info, address: address, read: read)
        } catch let incomplete as IncompleteEncryption {
            do {
                return try await verifiedFallback(model, address: address, incomplete: incomplete, read: read)
            } catch is CancellationError { throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // 2026-11-09 (Android issue #3, season 2 episodes 14, 18, …): the server leaves encrypt_info out entirely
                // for episodes whose media is plain hvc1. When no fallback confirms a source, those undeclared rows play as
                // plain; ProgressiveSource and MP4Processor.validate(requirePlain:) refuse an index with encv/enca/sinf/senc.
                // Rows that declare encryption but lack spade_a are still refused.
                if let plain = try? selectTrack(model, requireEncryption: true, minimumPixels: 0, acceptUndeclared: true) { return plain }
                throw error
            }
        }
    }

    /// A fallback for inline rows without encryption metadata must match the model's id, full duration and quality.
    private func verifiedFallback(_ model: [String: Any], address: String, incomplete: IncompleteEncryption,
                                  read: @Sendable (String) async throws -> [String: Any]) async throws -> VideoTrack {
        let id = ProtocolJSON.text(model["video_id"]).trimmingCharacters(in: .whitespacesAndNewlines), duration = Double(ProtocolJSON.text(model["video_duration"])) ?? 0
        guard !id.isEmpty, duration > 0, incomplete.minimumPixels > 0, !address.isEmpty else { throw incomplete }
        let info = try fallbackInfo(try await read(address)), other = Double(ProtocolJSON.text(info["video_duration"])) ?? 0
        guard ProtocolJSON.text(info["video_id"]) == id, other > 0, abs(other - duration) <= 0.5 else {
            throw HGError.message("备用片源编号或完整时长无法确认，已停止取址")
        }
        return try selectTrack(info, requireEncryption: true, minimumPixels: incomplete.minimumPixels)
    }

    private func checkedFallback(_ address: String) throws -> URL { try checkedURL(address, domains: ["fqnovel.com","snssdk.com"]) }

    /// Codec parameters for the fallback address, tried in order. 2026-11-10 (Android issue #3, 《谁让这个文盲修仙的第六季》
    /// episode 58): the original address carries `codec_type=4` and every row is ByteVC2; `codec_type=1` answers h265 for
    /// every quality while the older `codec_type=0&force_codec=h264` still answers ByteVC2. The older pair stays second for
    /// episodes it used to serve HEVC for (hongguoTV 0.1.20, issue #56, `265472f`).
    static let compatibleCodecQueries: [[URLQueryItem]] = [
        [URLQueryItem(name: "codec_type", value: "1")],
        [URLQueryItem(name: "codec_type", value: "0"), URLQueryItem(name: "force_codec", value: "h264")],
    ]

    /// Selects from a fallback model. When every row is ByteVC2, reads the same address again with each compatibility
    /// codec parameter in turn. The parameter names do not guarantee a codec, so each answer is still filtered by its
    /// actual codec and must name the same video and full duration.
    private func fallbackTrack(_ info: [String: Any], address: String, read: @Sendable (String) async throws -> [String: Any]) async throws -> VideoTrack {
        do {
            return try selectTrack(info, requireEncryption: false, minimumPixels: 0)
        } catch let onlyByteVC2 as ByteVC2Only {
            for query in Self.compatibleCodecQueries {
                guard let compatible = compatibleFallback(address, codec: query) else { break }
                do {
                    let other = try fallbackInfo(try await read(compatible))
                    try Self.confirmSameVideo(info, other)
                    return try selectTrack(other, requireEncryption: false, minimumPixels: 0)
                } catch is CancellationError { throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                }
            }
            throw onlyByteVC2
        }
    }

    func compatibleFallback(_ address: String, codec: [URLQueryItem] = DramaAPI.compatibleCodecQueries[0]) -> String? {
        // Keep the other parameters byte-for-byte: decoding and re-encoding could turn a signed "%2B" into "+".
        guard var parts = URLComponents(string: cleanURL(address)) else { return nil }
        var items = (parts.percentEncodedQueryItems ?? []).filter { $0.name != "codec_type" && $0.name != "force_codec" }
        items += codec
        parts.percentEncodedQueryItems = items
        return parts.string
    }

    /// A replacement model must not name another video or another full duration where both sides declare them.
    private static func confirmSameVideo(_ reference: [String: Any], _ other: [String: Any]) throws {
        let id = ProtocolJSON.text(reference["video_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let otherID = ProtocolJSON.text(other["video_id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = Double(ProtocolJSON.text(reference["video_duration"])) ?? 0, otherDuration = Double(ProtocolJSON.text(other["video_duration"])) ?? 0
        if (!id.isEmpty && !otherID.isEmpty && id != otherID) || (duration > 0 && otherDuration > 0 && abs(duration - otherDuration) > 0.5) {
            throw HGError.message("备用片源编号或完整时长无法确认，已停止取址")
        }
    }

    /// Every offered row is ByteVC2, which AVPlayer cannot decode.
    private struct ByteVC2Only: LocalizedError {
        var errorDescription: String? { "本集仅提供播放器不支持的 ByteVC2 编码，当前无法播放，请在官方 App 观看" }
    }

    private func fallbackInfo(_ outer: [String: Any]) throws -> [String: Any] {
        let outerInfo = ProtocolJSON.dictionary(outer["video_info"])
        guard ProtocolJSON.integer(outer["Code"] ?? outer["code"]) == 0, ProtocolJSON.integer(outerInfo["Code"]) == 0 else { throw HGError.message("当前分集暂时无法播放") }
        return ProtocolJSON.dictionary(outerInfo["data"])
    }

    /// The selected inline rows lack encryption metadata; the caller may try the verified fallback.
    private struct IncompleteEncryption: LocalizedError {
        let minimumPixels: Int
        var errorDescription: String? { "当前分集的播放地址或解密信息暂时不可用" }
    }

    /// `acceptUndeclared`: rows whose encrypt_info carries no encrypt flag at all are taken as plain; the media index
    /// is checked separately before playback.
    private func selectTrack(_ info: [String: Any], requireEncryption: Bool, minimumPixels: Int, acceptUndeclared: Bool = false) throws -> VideoTrack {
        let rawList = info["video_list"]
        let items = (rawList as? [Any] ?? Array(ProtocolJSON.dictionary(rawList).values)).map { ProtocolJSON.dictionary($0) }
        let compatible = items.compactMap { item -> (item: [String: Any], rank: Int, pixels: Int, shortSide: Int, quality: String)? in
            let meta = ProtocolJSON.dictionary(item["video_meta"]), codec = firstText(item["codec_type"],meta["codec_type"]).lowercased()
            let rank = ["h264","avc","avc1"].contains(codec) ? 0 : ["hevc","h265","hvc1","hev1","bytevc1"].contains(codec) ? 1 : 2
            guard rank < 2 else { return nil }
            let quality = firstText(item["quality_desc"],item["definition"],meta["definition"],item["height"],item["vheight"])
            let width = ProtocolJSON.integer(item["vwidth"] ?? item["width"] ?? meta["width"]), height = ProtocolJSON.integer(item["vheight"] ?? item["height"] ?? meta["height"])
            let shortSide = width > 0 && height > 0 ? min(width,height) : 0
            let pixels = shortSide > 0 ? shortSide : Int(quality.filter(\.isNumber)) ?? 0
            return (item,rank,pixels,shortSide,quality)
        }.sorted { $0.rank == $1.rank ? $0.pixels > $1.pixels : $0.rank < $1.rank }
        // Only the fallback compatibility requests have been seen to change the codec (see fallbackTrack).
        if compatible.isEmpty, items.contains(where: { ["bytevc2","bvc2"].contains(firstText($0["codec_type"],ProtocolJSON.dictionary($0["video_meta"])["codec_type"]).lowercased()) }) {
            throw ByteVC2Only()
        }
        let rows = compatible.filter { minimumPixels == 0 || $0.shortSide >= minimumPixels }
        var incomplete = false
        let seedText = ProtocolJSON.text(info["key_seed"]), seed = Self.base64(seedText)
        for row in rows {
            let encryptInfo = ProtocolJSON.dictionary(row.item["encrypt_info"]), spade = firstText(row.item["spade_a"],encryptInfo["spade_a"])
            if requireEncryption && spade.isEmpty && !["false","0"].contains(ProtocolJSON.text(encryptInfo["encrypt"]).lowercased())
                && !(acceptUndeclared && encryptInfo["encrypt"] == nil) {
                if encryptInfo["encrypt"] == nil { incomplete = true }
                continue
            }
            if !spade.isEmpty && (try? SpadeKey.decode(spade)) == nil { continue }
            let candidates = [row.item["main_url"],row.item["backup_url"]].compactMap { $0 as? String } + (row.item["backup_url_list"] as? [String] ?? [])
            for candidate in candidates where !candidate.isEmpty {
                do {
                    let address = seedText.isEmpty ? cleanURL(candidate) : try decryptURL(candidate, seed: seed)
                    let url = try checkedURL(address, domains: ["qznovelvod.com","fqnovelvod.com","douyinvod.com"])
                    return VideoTrack(url: url, spadeA: spade, encrypted: !spade.isEmpty, definition: row.quality)
                } catch { continue }
            }
        }
        if incomplete, let best = rows.first { throw IncompleteEncryption(minimumPixels: best.shortSide) }
        throw HGError.message("当前分集的播放地址或解密信息暂时不可用")
    }

    private func cacheDetail(_ result: DramaDetail) {
        let id = result.drama.id
        detailOrder.removeAll { $0 == id }; detailOrder.append(id)
        detailCache[id] = result; detailExpiry[id] = Date().addingTimeInterval(6 * 3600)
        while detailOrder.count > 80 { let oldest = detailOrder.removeFirst(); detailCache.removeValue(forKey: oldest); detailExpiry.removeValue(forKey: oldest) }
    }

    /// Registers a new anonymous identity. Identities may be single-use, so every model request gets its own
    /// (synchronized from hongguo-drama 5.5). A failure is reused for 10 seconds to prevent a registration storm.
    private func freshPlaybackIdentity() async throws -> RegisteredIdentity {
        if let failed = registrationFailedAt, Date().timeIntervalSince(failed) < 10 { throw HGError.message("匿名播放设备注册失败，请稍后重试") }
        do { let identity = try await PlaybackRegistration.register(session: session); registrationFailedAt = nil; return identity }
        catch { if !(error is CancellationError) { registrationFailedAt = Date() }; throw error }
    }

    static let playbackHost = "api5-normal-sinfonlineb.fqnovel.com", playbackRetryHost = "api5-normal-hl.fqnovel.com"
    private static let tabVideoPath = "/reading/bookapi/video_tab/multi_video_model/v1/", postVideoPath = "/novel/player/multi_video_model/v1/"

    /// The model endpoints answer an unsigned request with 0 bytes since 2026-11-05, and a signed POST without the
    /// registration cookie or x-ss-stub is rejected too (hongguoTV 0.1.22-0.1.25). A signed read still comes back empty
    /// now and then depending on identity and path, and a new identity usually recovers, so the plan is: the official
    /// GET, then POST, then a new identity on GET and on the alternate host. The whole read is bounded.
    /// Identities and routes do not always answer with the same model (2026-11-09: GET sometimes gave only keyless inline
    /// rows for an episode whose POST gave a full 1080P), so a model that yields no track moves on to the next route too.
    /// Only after every route fails is the model error reported, ahead of HTTP or empty-response errors.
    /// Since 2026-11-11 every multi-episode route answers 0 bytes, so the fully signed single-episode endpoint
    /// (`single`) goes first with the same identity; the old routes follow in their usual order when it fails.
    func playbackTrack(routes: [PlaybackRoute] = DramaAPI.playbackRoutes, budget: TimeInterval = 20,
                       identity newIdentity: @Sendable () async throws -> RegisteredIdentity,
                       single: (@Sendable (RegisteredIdentity) async throws -> PlaybackRead)? = nil,
                       read: @Sendable (PlaybackRoute, RegisteredIdentity) async throws -> PlaybackRead,
                       use: @Sendable ([String: Any]) async throws -> VideoTrack) async throws -> VideoTrack {
        var identity = try await newIdentity()
        var trace: [String] = []
        var failure: Error?, modelFailure: Error?
        var onlyEmpty = true
        let started = Date()
        defer { lastPlaybackTrace = trace.joined(separator: " ") }
        if let single {
            var model: [String: Any]?
            do {
                switch try await single(identity) {
                case .empty: trace.append("S=0B")
                case .invalid: trace.append("S=invalid"); onlyEmpty = false
                case .model(let value): model = value
                }
            } catch is CancellationError { throw CancellationError()
            } catch { trace.append("S=failed"); onlyEmpty = false; failure = error }
            if let model {
                onlyEmpty = false
                do {
                    let track = try await use(model)
                    trace.append("S=ok")
                    return track
                } catch is CancellationError { throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    trace.append("S=unusable")
                    modelFailure = error
                }
            }
        }
        for route in routes {
            guard Date().timeIntervalSince(started) < budget else { break }
            try Task.checkCancellation()
            if route.renewsIdentity, let renewed = try? await newIdentity() { identity = renewed; trace.append("new") }
            let label = (route.post ? "P:" : "G:") + (route.host == Self.playbackHost ? "b" : "hl")
            let model: [String: Any]
            do {
                switch try await read(route, identity) {
                case .empty: trace.append(label + "=0B"); continue
                case .invalid: trace.append(label + "=invalid"); onlyEmpty = false; continue
                case .model(let value): model = value
                }
            } catch is CancellationError { throw CancellationError()
            } catch let error as HGError {
                if case .message(let text) = error, text == Self.rejectedPlayback { trace.append(label + "=rejected"); throw error }
                trace.append(label + "=failed"); onlyEmpty = false; failure = error; continue
            } catch { trace.append(label + "=failed"); onlyEmpty = false; failure = error; continue }
            onlyEmpty = false
            do {
                let track = try await use(model)
                trace.append(label + "=ok")
                return track
            } catch is CancellationError { throw CancellationError()
            } catch {
                try Task.checkCancellation()
                trace.append(label + "=unusable")
                if modelFailure == nil { modelFailure = error }
            }
        }
        if let modelFailure { throw modelFailure }
        if onlyEmpty { throw HGError.message("播放服务返回空响应，疑似播放设备身份被拒，请稍后重试") }
        throw failure ?? HGError.message("服务暂未返回当前分集片源")
    }

    /// One route's answer: a model, 0 bytes, or a body that is not a usable model response.
    enum PlaybackRead { case model([String: Any]), empty, invalid }
    private static let rejectedPlayback = "当前分集暂未提供播放信息"

    private func readPlaybackRoute(_ route: PlaybackRoute, episodeID: String, body: Data, identity: RegisteredIdentity) async throws -> PlaybackRead {
        let signed = try await signedPlaybackRequest(route: route, episodeID: episodeID, body: body, identity: identity)
        let data = try await fetch(url: signed.url, body: route.post ? body : nil, headers: signed.headers, timeout: 8)
        guard !data.isEmpty else { return .empty }
        if !route.post { return Self.tabVideoModel(data, episodeID: episodeID).map { .model($0) } ?? .invalid }
        guard let response = try? ProtocolJSON.object(data) else { return .invalid }
        guard ProtocolJSON.integer(response["code"] ?? response["Code"]) == 0 else { throw HGError.message(Self.rejectedPlayback) }
        return .model(ProtocolJSON.dictionary(ProtocolJSON.dictionary(ProtocolJSON.dictionary(response["data"])[episodeID])["video_model"]))
    }

    // MARK: Single-episode endpoint (2026-11-11)
    // Synchronized from LiuWQ0809/hongguo-android commits 675f895, 10bda56 and 1765bfa (2026-11-11, GPL-3.0-only).

    static let singleVideoPath = "/novel/player/video_model/v1/"
    static let singleUserAgent = "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; "
        + "Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

    private func readSinglePlayback(episodeID: String, identity: RegisteredIdentity) async throws -> PlaybackRead {
        let body = try Self.singleBody(episodeID: episodeID)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let query = Self.singleQuery(identity, nowMs: now)
        guard let url = URL(string: "https://\(Self.playbackHost)\(Self.singleVideoPath)?\(query)") else { throw HGError.message("播放地址无效") }
        var headers = ["User-Agent":Self.singleUserAgent, "Accept":"application/json", "Content-Type":"application/json; charset=utf-8",
                       "x-xs-from-web":"0", "sdk-version":"2"]
        headers.merge(try PlayerSign.headers(query: query, body: body, nowMs: now, deviceID: identity.deviceID)) { $1 }
        let data = try await fetch(url: url, body: body, headers: headers, timeout: 8)
        guard !data.isEmpty else { return .empty }
        return Self.singleVideoModel(data).map { .model($0) } ?? .invalid
    }

    static func singleBody(episodeID: String) throws -> Data {
        try ProtocolJSON.data(["video_id":episodeID, "content_type":1, "biz_param":["need_all_video_definition":true, "video_platform":3]])
    }

    /// The 7.3.5.32 player profile with keys sorted; the signature covers exactly this query string.
    static func singleQuery(_ identity: RegisteredIdentity, nowMs: Int64) -> String {
        var q = PlaybackRegistration.deviceProfile
        for name in ["host_abi", "dragon_device_type", "pv_player", "compliance_status", "need_personal_recommend", "player_so_load", "is_android_pad_screen"] {
            q.removeValue(forKey: name)
        }
        for name in ["version_code", "manifest_version_code", "update_version_code"] { q[name] = "73532" }
        q["version_name"] = "7.3.5.32"
        q["device_id"] = identity.deviceID; q["iid"] = identity.installID; q["_rticket"] = String(nowMs)
        return q.keys.sorted().map { "\(formEncode($0))=\(formEncode(q[$0]!))" }.joined(separator: "&")
    }

    /// Java URLEncoder plus the %20 / !'()~ rewrites the Android client applies, so both send the same bytes.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: ".-*_!'()~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// `data.video_model` as an object, a JSON string or Base64 JSON, when `code` is 0; else nil.
    static func singleVideoModel(_ data: Data) -> [String: Any]? {
        guard let root = try? ProtocolJSON.object(data), ProtocolJSON.integer(root["code"] ?? root["Code"] ?? -1) == 0 else { return nil }
        var raw = ProtocolJSON.dictionary(root["data"])["video_model"]
        if let text = raw as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let json = trimmed.hasPrefix("{") ? Data(trimmed.utf8) : Data(base64Encoded: trimmed)
            raw = json.flatMap { try? ProtocolJSON.object($0) }
        }
        let model = ProtocolJSON.dictionary(raw)
        return model.isEmpty ? nil : model
    }

    struct PlaybackRoute: Sendable, Equatable { let post: Bool; let host: String; let renewsIdentity: Bool }
    static let playbackRoutes = [PlaybackRoute(post: false, host: playbackHost, renewsIdentity: false), PlaybackRoute(post: true, host: playbackHost, renewsIdentity: false),
                                 PlaybackRoute(post: false, host: playbackHost, renewsIdentity: true), PlaybackRoute(post: true, host: playbackRetryHost, renewsIdentity: false)]

    /// The identity goes into both the query and the signature, and the signature covers the exact final query.
    private func signedPlaybackRequest(route: PlaybackRoute, episodeID: String, body: Data, identity: RegisteredIdentity) async throws -> SignedProtocolRequest {
        let device = Self.playbackDevice(identity)
        let extra = route.post ? [] : Self.tabVideoQuery(episodeID: episodeID)
        let signed = try await signer.signedRequest(baseURL: "https://\(route.host)\(route.post ? Self.postVideoPath : Self.tabVideoPath)",
            query: Self.playbackQuery(device) + extra, body: route.post ? body : nil, device: device)
        return SignedProtocolRequest(url: signed.url, headers: signed.headers.merging(Self.playbackHeaders(identity, post: route.post)) { $1 })
    }

    /// The official player's version, in the query and in the signature alike.
    static func playbackDevice(_ identity: RegisteredIdentity) -> [String: String] {
        identity.device.merging(["version_code":"73932", "manifest_version_code":"73932", "update_version_code":"73932", "pv_player":"73932", "version_name":"7.3.9.32"]) { $1 }
    }

    static func playbackQuery(_ device: [String: String]) -> [[String]] {
        let order = ["iid", "device_id", "ac", "channel", "aid", "app_name", "version_code", "version_name", "device_platform", "os", "ssmix", "device_type",
                     "device_brand", "language", "os_api", "os_version", "manifest_version_code", "resolution", "dpi", "update_version_code", "host_abi",
                     "dragon_device_type", "pv_player", "compliance_status", "need_personal_recommend", "player_so_load", "is_android_pad_screen", "cdid"]
        return order.compactMap { name in device[name].map { [name, $0] } }
    }

    /// Every GetVideoModelRequest field is required; a missing one is answered with 100103 PARAM_INVALID.
    static func tabVideoQuery(episodeID: String) -> [[String]] {
        [["video_id",episodeID],["video_id_type","0"],["device_level","1"],["need_all_video_definition","1"],["need_mp4_align","0"],
         ["use_os_player","0"],["video_platform","1024"],["source","0"],["from_video_id",""]]
    }

    static func playbackHeaders(_ identity: RegisteredIdentity, post: Bool) -> [String: String] {
        var headers = ["User-Agent":PlaybackRegistration.userAgent, "Accept":"application/json; charset=utf-8,application/x-protobuf", "sdk-version":"2", "x-xs-from-web":"0"]
        if post { headers["Content-Type"] = "application/json; charset=utf-8" }
        if !identity.appDeviceCookie.isEmpty { headers["Cookie"] = identity.appDeviceCookie }
        return headers
    }

    /// `data.video_model_data[id].video_model` (object or JSON string) with a non-empty `video_list`, else nil.
    static func tabVideoModel(_ data: Data, episodeID: String) -> [String: Any]? {
        guard let root = try? ProtocolJSON.object(data), ProtocolJSON.integer(root["code"] ?? root["Code"] ?? -1) == 0 else { return nil }
        let rows = ProtocolJSON.dictionary(ProtocolJSON.dictionary(root["data"])["video_model_data"])
        let model = ProtocolJSON.dictionary(ProtocolJSON.dictionary(rows[episodeID])["video_model"])
        return ProtocolJSON.array(model["video_list"]).isEmpty ? nil : model
    }

    private func rank(offset: Int) async throws -> DramaPage {
        let extra = [["cell_id","7470092475068071998"],["tab_type","26"],["client_req_type","2"],["client_template","2"],
            ["screen_width_px","1350"],["selected_items","comic_series_rank"],["sub_selected_items","comic_series_hot_rank"],
            ["session_uuid",UUID().uuidString.lowercased()],["offset",String(max(0,offset))]]
        let response = try await api(path: "/reading/bookapi/bookmall/cell/change/v", extra: extra)
        let cell = ProtocolJSON.dictionary(ProtocolJSON.dictionary(response["data"])["cell_view"]), raw = ProtocolJSON.array(cell["cell_data"])
        let dramas = raw.compactMap { item -> Drama? in
            let row = ProtocolJSON.dictionary(item), value = row["video_data"]
            return parseDrama(ProtocolJSON.dictionary((value as? [Any])?.first ?? value))
        }
        let declared = ProtocolJSON.integer(cell["next_offset"]), next = declared > offset ? declared : offset + raw.count
        return DramaPage(dramas: dramas, hasMore: ProtocolJSON.bool(cell["has_more"]) && !raw.isEmpty && next > offset, nextOffset: next)
    }

    private func api(path: String, body: [String: Any]? = nil, extra: [[String]] = []) async throws -> [String: Any] {
        try Task.checkCancellation()
        let base: [[String]] = [["aid","8662"],["app_name","novelread"],["version_code","72232"],["version_name","7.2.2.32"],
            ["channel","audit"],["device_platform","android"],["device_type","audit-windows"],["os_version","12"],
            ["update_version_code","72232"],["device_id",deviceID],["iid","0"]]
        let bytes = try body.map { try ProtocolJSON.data($0) }
        let signed = try await signer.signedRequest(baseURL: "https://api5-normal-sinfonlinea.fqnovel.com" + path,
            query: base + extra, body: bytes, device: ["device_id":deviceID,"version_name":"7.2.2.32"])
        var headers = signed.headers
        headers["User-Agent"] = "hongguo-web/1.0"; headers["x-tt-store-region"] = "cn-sh"; headers["x-tt-store-region-src"] = "uid"
        headers["passport-sdk-version"] = "5051452"; headers["sdk-version"] = "2"; headers["Accept"] = "application/json"
        headers["Content-Type"] = "application/json; charset=utf-8"
        let response = try await request(url: signed.url, body: bytes, headers: headers)
        let code = ProtocolJSON.integer(response["code"] ?? response["Code"])
        guard code == 0 else {
            if [1003,401].contains(code) { throw HGError.message("内容服务要求重新验证，请稍后重试") }
            if [110001,110002].contains(code) { throw HGError.message("内容服务暂时限制访问，请稍后重试") }
            throw HGError.message("内容服务暂不可用（\(code)）")
        }
        return response
    }

    private func request(url: URL, body: Data?, headers: [String: String]) async throws -> [String: Any] {
        let data = try await fetch(url: url, body: body, headers: headers)
        guard !data.isEmpty else { throw HGError.message("服务返回空响应，请稍后重试") }
        do { return try ProtocolJSON.object(data) } catch { throw HGError.message("服务数据格式发生变化，请稍后重试") }
    }
    private func fetch(url: URL, body: Data? = nil, headers: [String: String], timeout: TimeInterval = 18) async throws -> Data {
        try Task.checkCancellation()
        let scheduled = max(Date(), nextRequestAt); nextRequestAt = scheduled.addingTimeInterval(0.26)
        let wait = scheduled.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        for (name,value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data,response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw HGError.message("服务连接失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard data.count <= 8 * 1024 * 1024 else { throw HGError.message("服务返回的数据过大") }
        return data
    }

    private func selection(genre: String, filters: [String: String]) -> [String: [String]] {
        var selected: [String: [String]] = ["genre":[genre],"category_dim_theme":[],"category_dim_role":[],"category_dim_epoch":[],
            "sort":["online_time"],"gender":[],"creation_status":[],"online_time":[]]
        let aliases = ["theme":"category_dim_theme","setting":"category_dim_role","background":"category_dim_epoch","status":"creation_status","days":"online_time"]
        for (key,value) in filters where !value.isEmpty { selected[aliases[key] ?? key] = value.split(separator: ",").map(String.init) }
        return selected
    }
    private func parseDrama(_ row: [String: Any]) -> Drama? {
        guard let id = ProtocolJSON.identifier(row["series_id"] ?? row["book_id"]) else { return nil }
        let title = stripHTML(firstText(row["title"],row["series_title"],row["book_name"]))
        guard !title.isEmpty else { return nil }
        return Drama(id: id, title: title, coverURL: cleanURL(firstText(row["cover"],row["series_cover"],row["thumb_url"])),
            summary: stripHTML(firstText(row["video_desc"],row["series_intro"],row["abstract"])), episodeCount: ProtocolJSON.integer(row["episode_cnt"] ?? row["episode_count"]))
    }
    private func parseSearch(_ cell: [String: Any]) -> Drama? {
        let vd = ProtocolJSON.dictionary(cell["video_detail"]), value = cell["video_data"]
        let vdata = ProtocolJSON.dictionary((value as? [Any])?.first ?? value), inner = ProtocolJSON.dictionary(vdata["video_detail"])
        let count = max(ProtocolJSON.integer(vd["episode_cnt"]),ProtocolJSON.integer(vdata["episode_cnt"]),ProtocolJSON.integer(inner["episode_cnt"]))
        guard count > 0 else { return nil }
        let highlight = ProtocolJSON.dictionary(ProtocolJSON.dictionary(cell["search_high_light"])["title"])
        return parseDrama(["series_id":firstText(cell["book_id"],cell["search_result_id"],cell["series_id"]),
            "title":firstText(highlight["text"],vd["series_title"],vdata["title"],inner["series_title"]),"episode_cnt":count,
            "cover":firstText(vdata["cover"],inner["series_cover"]),"series_intro":firstText(inner["series_intro"],vd["series_intro"])])
    }
    private func firstText(_ values: Any?...) -> String { values.map { ProtocolJSON.text($0) }.first { !$0.isEmpty } ?? "" }
    private func stripHTML(_ text: String) -> String { text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
    private func cleanURL(_ value: String) -> String { value.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u002F", with: "/").replacingOccurrences(of: "\\u0026", with: "&").replacingOccurrences(of: "&amp;", with: "&") }
    private static func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? "" }
    private static func base64(_ value: String) -> Data? {
        guard !value.isEmpty else { return nil }
        let input = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: input + String(repeating: "=", count: (4 - input.count % 4) % 4))
    }
    private func checkedURL(_ value: String, domains: [String]) throws -> URL {
        guard let url = URL(string: cleanURL(value)), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(), domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw HGError.message("服务返回的地址不受支持")
        }
        return url
    }
    private func fallbackURL(_ value: Any?) -> String {
        if let text = value as? String { return firstText(ProtocolJSON.dictionary(text)["fallback_api"],text) }
        if let array = value as? [Any] { return ProtocolJSON.text(array.first) }
        return ProtocolJSON.text(ProtocolJSON.dictionary(value)["fallback_api"])
    }
    private func decryptURL(_ value: String, seed: Data?) throws -> String {
        guard let seed, let raw = Self.base64(value), raw.count >= 20 else { throw HGError.message("片源地址格式无效") }
        let bytes = [UInt8](raw)
        guard bytes[0] == 0xa8, bytes[2] == 1, bytes[3] == 0 else { throw HGError.message("片源地址格式无效") }
        let length = ((raw.count - 4) / 16) * 16, derived = HGCrypto.sha512(HGCrypto.sha512(seed) + PlaybackRegistration.salt)
        var plaintext = try HGCrypto.aesCBCDecrypt(raw.subdata(in: 4..<(4 + length)), key: Data(derived.prefix(16)), iv: Data(derived.dropFirst(16).prefix(16)), padding: false)
        if let last = plaintext.last, last >= 1 && last <= 16, Int(last) <= plaintext.count { plaintext.removeLast(Int(last)) }
        while plaintext.last == 0 { plaintext.removeLast() }
        guard let address = String(data: plaintext, encoding: .utf8) else { throw HGError.message("片源地址解密失败") }
        return address
    }

    private var webHeaders: [String: String] { ["User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36", "Referer":"https://hongguoduanju.com/", "Accept":"text/html,application/xhtml+xml", "Accept-Language":"zh-CN,zh;q=0.9"] }
    private func webSearch(_ query: String, offset: Int) async throws -> DramaPage {
        let url = URL(string: "https://hongguoduanju.com/search/" + Self.encode(query))!
        let data = try await fetch(url: url, headers: webHeaders), html = String(decoding: data, as: UTF8.self)
        guard let text = embeddedJSON(html, key: "searchList", opening: 91, closing: 93), let bytes = text.data(using: .utf8),
              let wrapper = try? ProtocolJSON.object(Data("{\"rows\":".utf8) + bytes + Data("}".utf8)) else { return DramaPage(dramas: [], hasMore: false, nextOffset: offset) }
        var seen = Set<String>()
        let all = ProtocolJSON.array(wrapper["rows"]).compactMap { value -> Drama? in
            let cell = ProtocolJSON.dictionary(value), inner = ProtocolJSON.dictionary(cell["video_data"])
            let row = inner.isEmpty ? cell : inner
            guard let drama = parseDrama(row), seen.insert(drama.id).inserted else { return nil }
            return drama
        }
        let page = Array(all.dropFirst(offset).prefix(20))
        return DramaPage(dramas: page, hasMore: offset + page.count < all.count, nextOffset: offset + page.count)
    }
    private func webDetail(_ drama: Drama) async throws -> DramaDetail {
        let data = try await fetch(url: URL(string: "https://hongguoduanju.com/player/" + drama.id)!, headers: webHeaders)
        let html = String(decoding: data, as: UTF8.self)
        guard let text = embeddedJSON(html, key: "vid_list", opening: 91, closing: 93), let bytes = text.data(using: .utf8),
              let wrapper = try? ProtocolJSON.object(Data("{\"rows\":".utf8) + bytes + Data("}".utf8)) else { throw HGError.message("官网暂未提供分集列表") }
        let episodes = ProtocolJSON.array(wrapper["rows"]).enumerated().compactMap { index,value -> Episode? in
            guard let id = ProtocolJSON.identifier(value) else { return nil }
            return Episode(id: id, index: index + 1, title: "第\(index + 1)集")
        }
        guard !episodes.isEmpty else { throw HGError.message("官网暂未提供分集列表") }
        let updated = Drama(id: drama.id, title: jsonString(html,key:"series_name") ?? drama.title, coverURL: cleanURL(jsonString(html,key:"series_cover") ?? drama.coverURL), summary: drama.summary, episodeCount: episodes.count)
        return DramaDetail(drama: updated, episodes: episodes)
    }
    private func jsonString(_ text: String, key: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"" + NSRegularExpression.escapedPattern(for: key) + "\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")"),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) else { return nil }
        let source = "{\"value\":" + text[range] + "}"
        return (try? ProtocolJSON.object(Data(source.utf8)))?["value"] as? String
    }
    private func embeddedJSON(_ text: String, key: String, opening: UInt8, closing: UInt8) -> String? {
        guard let marker = text.range(of: "\"" + key + "\"") else { return nil }
        let bytes = Array(text[marker.upperBound...].utf8)
        guard let start = bytes.firstIndex(of: opening) else { return nil }
        var depth = 0, inString = false, escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString { if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { inString = false }; continue }
            if byte == 34 { inString = true; continue }
            if byte == opening { depth += 1 }; if byte == closing { depth -= 1; if depth == 0 { return String(decoding: bytes[start...index], as: UTF8.self) } }
        }
        return nil
    }
}

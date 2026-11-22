// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Counters of the signed-in account; nil when the platform does not report one.
struct AccountStats: Sendable {
    var follows: Int?
    var fans: Int?
    var likes: Int?
}

enum AccountRules {
    /// Account lists may contain only IDs/progress. Detail rows may also be incomplete.
    static func metadataDrama(row: [String: Any], video: [String: Any]) -> Drama? {
        func first(_ values: Any?...) -> String {
            values.map { ProtocolJSON.text($0).trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        }
        let id = first(video["series_id"], row["series_id"], row["book_id"], video["book_id"])
        guard ProtocolJSON.identifier(id) != nil else { return nil }
        let title = first(row["book_name"], row["series_title"], video["series_title"], video["book_name"], video["title"], row["title"])
        let urls = [row["thumb_url"], row["series_cover_url"], row["series_cover"], video["series_cover_url"], video["series_cover"], video["cover"], video["cover_url"], video["thumb_url"]]
        let cover = urls.compactMap { ($0 as? String).map { $0.replacingOccurrences(of: "\\/", with: "/") } }.compactMap(safeImageURL).first ?? ""
        let count = [row["episode_cnt"], row["episode_count"], video["episode_cnt"], video["episode_count"]].map { ProtocolJSON.integer($0) }.first { $0 > 0 } ?? 0
        return Drama(id: id, title: title, coverURL: cover,
                     summary: first(row["abstract"], row["series_intro"], video["series_intro"], video["video_desc"]), episodeCount: count)
    }

    /// Merge fields separately: a title-only detail row must not erase a known poster.
    static func mergingMetadata(_ fallback: Drama, update: Drama?) -> Drama {
        guard let update, update.id == fallback.id else { return fallback }
        func usefulTitle(_ title: String) -> Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title != "剧集" && title != "剧集 \(fallback.id)"
        }
        func cover(_ value: String) -> String { safeImageURL(value.replacingOccurrences(of: "\\/", with: "/")) ?? "" }
        return Drama(id: fallback.id, title: usefulTitle(update.title) ? update.title : fallback.title,
                     coverURL: cover(update.coverURL).isEmpty ? cover(fallback.coverURL) : cover(update.coverURL),
                     summary: update.summary.isEmpty ? fallback.summary : update.summary,
                     episodeCount: update.episodeCount > 0 ? update.episodeCount : fallback.episodeCount)
    }

    /// Retain only the current list's IDs and order. Never resurrect removed rows from cached metadata.
    static func enrichDramas(_ values: [Drama], previous: [Drama],
                             load: ([String]) async throws -> [String: Any]) async throws -> [Drama] {
        var known = [String: Drama]()
        for drama in previous {
            known[drama.id] = known[drama.id].map { mergingMetadata(drama, update: $0) } ?? drama
        }
        var result = values.map { mergingMetadata(known[$0.id] ?? $0, update: $0) }
        var seen = Set<String>()
        let ids = values.map(\.id).filter { ProtocolJSON.identifier($0) != nil && seen.insert($0).inserted }
        for start in stride(from: 0, to: ids.count, by: 50) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 50, ids.count)]), requested = Set(batch)
            let raw = try await load(batch)
            try Task.checkCancellation()
            for value in ProtocolJSON.array(raw["data"]) {
                let row = ProtocolJSON.dictionary(value)
                let video = ProtocolJSON.dictionary(row["video_data"] ?? row)
                guard let drama = metadataDrama(row: row, video: video), requested.contains(drama.id) else { continue }
                for index in result.indices where result[index].id == drama.id {
                    result[index] = mergingMetadata(result[index], update: drama)
                }
            }
        }
        return result
    }

    /// Progress timestamps choose the resume point; older read records can still supply missing metadata.
    static func mergingHistory(_ values: [LibraryEntry]) -> [LibraryEntry] {
        var byID = [String: LibraryEntry](), order = [String]()
        for entry in values {
            guard let old = byID[entry.id] else { byID[entry.id] = entry; order.append(entry.id); continue }
            let latest = entry.updatedAt > old.updatedAt ? entry : old
            let other = entry.updatedAt > old.updatedAt ? old : entry
            let drama = mergingMetadata(other.drama, update: latest.drama)
            byID[entry.id] = LibraryEntry(drama: drama, episodeID: latest.episodeID, episodeIndex: latest.episodeIndex,
                                         position: latest.position, updatedAt: latest.updatedAt)
        }
        return Array(order.compactMap { byID[$0] }.sorted { $0.updatedAt > $1.updatedAt }.prefix(200))
    }

    /// Light `bookshelf/video/list` shelf: ids and times only, newest first. Accounts on this logic get
    /// `data: null` from the older `video/info` read (Android issue #6, 2026-11-11).
    static func favoriteList(_ raw: [String: Any]) throws -> [String] {
        guard let data = raw["data"] as? [String: Any] else { throw HGError.message("账户收藏数据格式发生变化") }
        guard let value = data["video_shelf_info"] else { throw HGError.message("账户收藏列表格式发生变化") }
        if value is NSNull { return [] }
        guard let rows = value as? [Any] else { throw HGError.message("账户收藏列表格式发生变化") }
        var seen = Set<String>(), result = [(id: String, at: Int64)]()
        for value in rows {
            let row = ProtocolJSON.dictionary(value)
            let id = ProtocolJSON.text(row["series_id"]).isEmpty ? ProtocolJSON.text(row["book_id"]) : ProtocolJSON.text(row["series_id"])
            guard ProtocolJSON.identifier(id) != nil, seen.insert(id).inserted else { continue }
            let collected = Int64(ProtocolJSON.text(row["collect_time"])) ?? 0
            result.append((id, collected > 0 ? collected : Int64(ProtocolJSON.text(row["last_operate_time"])) ?? 0))
        }
        guard rows.isEmpty || !result.isEmpty else { throw HGError.message("账户收藏条目格式发生变化") }
        return result.enumerated().sorted { $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.offset < $1.offset }.map(\.element.id)
    }

    /// A non-zero business code is a definite refusal of the write, not an unknown outcome (Android issue #7).
    static func reserveRefusal(code: Int) -> String {
        code == 101144 ? "红果风控拒绝了本次预约（错误码 101144），未写入账号；可稍后重试或在官方 App 预约"
            : "红果拒绝了本次预约（错误码 \(code)），未写入账号"
    }

    /// Protocol reference: charlie901208/HGTV AccountParser.likes.
    static func likes(_ raw: [String: Any]) -> [Drama] {
        var seen = Set<String>(), rows = [(drama: Drama, at: Int64)]()
        for value in ProtocolJSON.array(ProtocolJSON.dictionary(raw["data"])["mixed_data_list"]) {
            let row = ProtocolJSON.dictionary(value)
            let video = ProtocolJSON.dictionary(row["video_data"] ?? row["book_data"])
            func first(_ values: Any?...) -> String { values.map { ProtocolJSON.text($0) }.first { !$0.isEmpty } ?? "" }
            let id = first(video["series_id"], row["series_id"], row["book_id"]), title = first(row["series_title"], video["title"], row["book_name"])
            guard !video.isEmpty, ProtocolJSON.identifier(id) != nil, !title.isEmpty, seen.insert(id).inserted else { continue }
            let count = [video["episode_cnt"], video["episode_count"], row["episode_cnt"]].map { ProtocolJSON.integer($0) }.first { $0 > 0 } ?? 0
            let liked = Int64(ProtocolJSON.integer(video["user_digg_timestamp_ms"]))
            let drama = Drama(id: id, title: title, coverURL: first(row["series_cover_url"], video["cover"], video["cover_url"], video["thumb_url"]).replacingOccurrences(of: "\\/", with: "/"),
                              summary: first(row["series_intro"], video["video_desc"]), episodeCount: count)
            rows.append((drama, liked > 0 ? liked : Int64(ProtocolJSON.integer(video["create_time"])) * 1000))
        }
        return rows.sorted { $0.at > $1.at }.map(\.drama)
    }

    /// Watch records, newest per work. Upstream reference: jackotom/hongguo-drama 5.6 account-session.js parseHistory.
    static func readHistory(_ raw: [String: Any]) throws -> [LibraryEntry] {
        guard let rows = (ProtocolJSON.dictionary(raw["data"])["data_list"] ?? raw["data_list"]) as? [Any] else { throw HGError.message("账户观看记录格式发生变化") }
        var newest = [String: LibraryEntry]()
        for value in rows {
            let row = ProtocolJSON.dictionary(value)
            func first(_ values: Any?...) -> String { values.map { ProtocolJSON.text($0) }.first { !$0.isEmpty } ?? "" }
            let id = first(row["book_id_str"], row["book_id"], row["series_id"]), episode = first(row["vid"], row["item_id"])
            guard !ProtocolJSON.bool(row["is_delete"]), ProtocolJSON.identifier(id) != nil, ProtocolJSON.identifier(episode) != nil else { continue }
            var stamp = Double(first(row["read_timestamp_ms"], row["last_watch_time"])) ?? 0
            if stamp > 1e10 { stamp /= 1000 }
            let title = first(row["series_title"], row["book_name"]), position = max(0, Double(first(row["current_play_position"], row["current_play_time"])) ?? 0) / 1000
            let drama = Drama(id: id, title: title.isEmpty ? "剧集" : title, coverURL: first(row["series_cover_url"], row["thumb_url"], row["cover"]).replacingOccurrences(of: "\\/", with: "/"),
                              summary: "", episodeCount: max(0, [row["episode_cnt"], row["episode_count"]].map { ProtocolJSON.integer($0) }.first { $0 > 0 } ?? 0))
            let entry = LibraryEntry(drama: drama, episodeID: episode, episodeIndex: max(1, ProtocolJSON.integer(row["vid_index"])), position: position, updatedAt: Date(timeIntervalSince1970: stamp))
            if let current = newest[id], current.updatedAt >= entry.updatedAt { continue }
            newest[id] = entry
        }
        return Array(newest.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(50))
    }

    /// Protocol reference: charlie901208/HGTV AccountParser.profile.
    static func stats(_ raw: [String: Any]) -> AccountStats {
        let data = ProtocolJSON.dictionary(raw["data"])
        func count(_ key: String) -> Int? { data[key] == nil || data[key] is NSNull ? nil : max(0, ProtocolJSON.integer(data[key])) }
        return AccountStats(follows: count("follow_user_num"), fans: count("fans_num"), likes: count("recv_digg_num"))
    }

    static func businessID(_ raw: Any?) -> String? {
        // A boolean/number must never become an authenticated identity through string conversion.
        guard let value = raw as? String, !value.isEmpty, value.count <= 1024,
              !["0","null","undefined","none"].contains(value.lowercased()),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        return value
    }
    static func websiteAuthenticated(_ reply: [String:Any]) -> Bool {
        guard ProtocolJSON.text(reply["message"]) == "success" else { return false }
        let data = ProtocolJSON.dictionary(reply["data"])
        let nodes = [reply, data, ProtocolJSON.dictionary(data["user_info"]), ProtocolJSON.dictionary(data["user"])]
        for node in nodes {
            if let flag = node["has_login"], !ProtocolJSON.bool(flag) { return false }
        }
        return nodes.contains { row in
            ProtocolJSON.bool(row["has_login"]) || ["user_id","user_id_str","uid","uid_str","id","biz_user_id"].contains {
                businessID(row[$0]) != nil
            }
        }
    }
    /// First usable avatar in a profile reply: a plain URL string or a `{url_list: [...]}` image object.
    /// Only https (upgraded from http or scheme-relative) so ATS never blocks it and nothing else is fetched.
    static func avatarURL(_ data: [String:Any]) -> String? {
        let nodes = [data, ProtocolJSON.dictionary(data["user"]), ProtocolJSON.dictionary(data["user_info"])]
        let keys = ["avatar_url", "avatar_large_url", "avatar_large", "avatar_medium", "avatar_thumb", "avatar"]
        for node in nodes {
            for key in keys {
                let value = node[key]
                let candidates: [Any] = (value as? String).map { [$0] } ?? ProtocolJSON.array(ProtocolJSON.dictionary(value)["url_list"])
                for candidate in candidates { if let url = safeImageURL(candidate) { return url } }
            }
        }
        return nil
    }
    /// Display name from a website profile reply (`screen_name` and friends), trimmed and bounded.
    static func displayName(_ data: [String:Any]) -> String? {
        let nodes = [data, ProtocolJSON.dictionary(data["user"]), ProtocolJSON.dictionary(data["user_info"])]
        for node in nodes {
            for key in ["screen_name", "nickname", "user_name", "name"] {
                guard let raw = node[key] as? String else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, value.count <= 64, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return value }
            }
        }
        return nil
    }
    static func safeImageURL(_ raw: Any?) -> String? {
        guard var value = raw as? String, value.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        else if value.lowercased().hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil else { return nil }
        return url.absoluteString
    }
    static func domainMatches(cookieDomain: String, targetHost: String) -> Bool {
        let domain = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let target = targetHost.lowercased()
        return !domain.isEmpty && (target == domain || target.hasSuffix("." + domain))
    }
}

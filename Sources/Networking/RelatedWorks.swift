// SPDX-License-Identifier: GPL-3.0-only
// Adapted from tsukiyo-zero/hongguoTV kotlin-tv/core RelatedWorks.kt and ContentRepository.kt at f22bb3f (2026-11-03)
// through hongguo-android.
import Foundation

/// Another season or same-IP work. `seasonNumber` is N when the platform labels it 第N季, otherwise 0 (such as 同IP).
struct RelatedWork: Identifiable, Sendable {
    var id: String { drama.id }
    let drama: Drama
    let season: String
    let upcoming: Bool
    let seasonNumber: Int
    /// Expected release of an upcoming work, such as 预计11月21日上线; empty until known.
    var releaseText = ""
}

/// The expected release of an upcoming work, as the official app words it ("预计11月21日上线"). The platform's own text
/// wins; otherwise `publishAtMs` is formatted in Beijing time, with the year only when it differs from `now`'s.
/// Empty when neither is known.
func releaseLabel(_ text: String, publishAtMs: Int64, now: Date = Date()) -> String {
    let clean = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(40))
    if !clean.isEmpty { return clean }
    guard publishAtMs > 0 else { return "" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let at = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(publishAtMs) / 1000))
    let year = at.year != calendar.component(.year, from: now) ? "\(at.year ?? 0)年" : ""
    return "预计\(year)\(at.month ?? 0)月\(at.day ?? 0)日上线"
}

/// The 相关作品 cell of the reading plan. Anonymous, signed and read-only.
enum RelatedWorks {
    static let hosts = ["api5-normal-sinfonlinec.fqnovel.com", "api5-normal-hl.fqnovel.com", "api5-normal-lf.fqnovel.com"]
    static let path = "/reading/bookapi/plan/v:version/"
    /// Observed on 2026-11-04: 1004/1007 and 1/1002 are the on-line/upcoming pairs of the two playable drama families.
    private static let onlineTypes: Set<Int> = [1, 1004], upcomingTypes: Set<Int> = [1002, 1007]
    private static let parameters = ["scene":"10", "from":"detail_page_more_related", "new_search_middle_page":"false", "bookstore_tab_type":"0",
        "query_history_removed":"false", "user_is_login":"0", "bookstore_tab":"0", "search_middle_page_version":"0", "pad_column_detail":"0",
        "hot_word_exchange":"false", "device_level":"3", "limit":"0", "offset":"0", "is_horizontal_screen":"false", "reader_single_col_from_ip_strategy":"false"]

    static func device() -> [String: String] {
        var device = PlaybackRegistration.deviceProfile
        device["device_id"] = "1905892595378490"; device["iid"] = "1905892595382586"
        for key in ["version_code", "manifest_version_code", "update_version_code", "pv_player"] { device[key] = "72232" }
        device["version_name"] = "7.2.2.32"
        device["ts"] = String(Int64(Date().timeIntervalSince1970))
        return device
    }

    static func query(id: String, device: [String: String]) -> [[String]] {
        device.merging(parameters) { _, new in new }.merging(["book_id": id]) { _, new in new }.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
    }

    static func parse(_ object: [String: Any], currentID: String) throws -> [RelatedWork] {
        guard object["code"] != nil, ProtocolJSON.integer(object["code"]) == 0 else { throw HGError.message("相关作品暂不可用") }
        guard let cells = object["data"] as? [Any] else { throw HGError.message("相关作品数据格式已变化") }
        var seen = Set<String>(), works = [RelatedWork]()
        for cell in cells.map(ProtocolJSON.dictionary) where ProtocolJSON.integer(cell["show_type"]) == 547 || ProtocolJSON.text(cell["cell_name"]) == "相关作品" {
            for value in ProtocolJSON.array(cell["video_data"]) {
                let row = ProtocolJSON.dictionary(value)
                let id = ProtocolJSON.text(row["series_id"]), title = ProtocolJSON.text(row["title"]), type = ProtocolJSON.integer(row["content_type"])
                let upcoming = upcomingTypes.contains(type), episodes = max(0, ProtocolJSON.integer(row["episode_cnt"]))
                guard id != currentID, ProtocolJSON.identifier(id) != nil, !title.isEmpty else { continue }
                guard upcoming || (onlineTypes.contains(type) && !ProtocolJSON.bool(row["disable_play"]) && episodes > 0) else { continue }
                guard works.count < 30, seen.insert(id).inserted else { continue }
                let tag = ProtocolJSON.text(ProtocolJSON.dictionary(row["tag_info"])["text"]), index = ProtocolJSON.integer(row["season_index"])
                let season = !tag.isEmpty ? tag : index > 0 ? "第\(index)季" : ""
                works.append(RelatedWork(drama: Drama(id: id, title: title, coverURL: ProtocolJSON.text(row["cover"]).replacingOccurrences(of: "\\/", with: "/"),
                    summary: ProtocolJSON.text(row["video_desc"]), episodeCount: episodes), season: season, upcoming: upcoming, seasonNumber: number(season)))
            }
        }
        return works
    }

    private static func number(_ season: String) -> Int {
        guard let range = season.range(of: "^第[0-9]{1,3}季$", options: .regularExpression) else { return 0 }
        return Int(season[range].filter(\.isNumber)) ?? 0
    }

    /// The season after the current work. The plan lists every season except the current one, so the current season is
    /// the single gap in the numbering. No gap means the current work is the newest; several gaps return nil instead of guessing.
    static func nextSeason(_ works: [RelatedWork]) -> RelatedWork? {
        let seasons = Dictionary(works.filter { $0.seasonNumber > 0 }.map { ($0.seasonNumber, $0) }) { first, _ in first }
        guard let newest = seasons.keys.max() else { return nil }
        let gaps = (1...newest).filter { seasons[$0] == nil }
        guard gaps.count == 1 else { return nil }
        return seasons[gaps[0] + 1]
    }
}

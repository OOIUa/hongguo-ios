// SPDX-License-Identifier: GPL-3.0-only
// Rank boards and search suggestions adapted from tsukiyo-zero/hongguoTV kotlin-tv/core RankBrowser.kt, ComicRank.kt and
// ContentRepository.kt at f22bb3f (2026-11-03) through hongguo-android. Only the page's serialized data is read; no script runs.
import Foundation

enum RankBoard: String, CaseIterable, Identifiable, Sendable {
    case all = "hot-drama", real = "hot-real-drama", comic = "hot-comic-drama", ai = "hot-ai-drama"
    var id: String { rawValue }
    var label: String { switch self { case .all: return "综合"; case .real: return "真人剧"; case .comic: return "漫剧"; case .ai: return "AI 剧" } }
    var loader: String { "rank_\(rawValue)/page" }
}

struct RankEntry: Identifiable, Sendable {
    var id: String { drama.id }
    let drama: Drama
    let rank: Int
    let heat: String
}

struct RankPage: Sendable {
    let entries: [RankEntry]
    let page: Int
    let totalPages: Int
}

/// Public website data. Anonymous: no account cookie is ever sent here.
enum WebsiteCatalog {
    static let base = "https://hongguoduanju.com"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    /// The site answers ?page=1 with a redirect to the bare address, and redirects are not followed here.
    static func rankURL(_ board: RankBoard, page: Int) -> URL { URL(string: "\(base)/rank/\(board.rawValue)" + (page > 1 ? "?page=\(page)" : ""))! }

    static func suggestionURL(query: String, webID: String) -> URL? {
        var components = URLComponents(string: base + "/incent_resource/suggestion")
        components?.queryItems = [URLQueryItem(name: "app_id", value: "8662"), URLQueryItem(name: "web_id", value: webID), URLQueryItem(name: "query", value: query)]
        return components?.url
    }

    static func parseRank(_ html: String, board: RankBoard, page: Int) throws -> RankPage {
        for pattern in ["data-fn-args='([^']*)'", "data-fn-args=\"([^\"]*)\""] {
            let expression = try NSRegularExpression(pattern: pattern)
            for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range(at: 1), in: html), let data = decodeEntities(String(html[range])).data(using: .utf8),
                      let args = (try? JSONSerialization.jsonObject(with: data)) as? [Any], args.count >= 3,
                      args[0] as? String == board.loader, args[1] as? String == "content" else { continue }
                let payload: [String: Any]
                if let object = args[2] as? [String: Any] { payload = object }
                else if let text = args[2] as? String, let object = try? ProtocolJSON.object(Data(text.utf8)) { payload = object }
                else { continue }
                guard ProtocolJSON.bool(payload["isSuccess"]) else { throw HGError.message("榜单暂不可用") }
                guard let rows = payload["rankList"] as? [Any] else { throw HGError.message("榜单格式已变化") }
                let paging = ProtocolJSON.dictionary(payload["pagination"]), total = ProtocolJSON.integer(paging["totalPages"])
                guard total >= 1, paging["pageNum"] == nil || ProtocolJSON.integer(paging["pageNum"]) == page else { throw HGError.message("榜单分页信息异常") }
                var seen = Set<String>(), entries = [RankEntry]()
                for value in rows {
                    let row = ProtocolJSON.dictionary(value), series = ProtocolJSON.text(row["seriesId"]), id = series.isEmpty ? ProtocolJSON.text(row["id"]) : series
                    let title = ProtocolJSON.text(row["title"])
                    guard ProtocolJSON.identifier(id) != nil, !title.isEmpty, seen.insert(id).inserted else { continue }
                    let count = row["episodeCount"] != nil ? ProtocolJSON.integer(row["episodeCount"]) : ProtocolJSON.array(row["episodeVids"]).count
                    entries.append(RankEntry(drama: Drama(id: id, title: title, coverURL: ProtocolJSON.text(row["cover"]), summary: ProtocolJSON.text(row["description"]), episodeCount: max(0, count)),
                                             rank: max(0, ProtocolJSON.integer(row["rank"])), heat: ProtocolJSON.text(row["heatText"])))
                }
                return RankPage(entries: entries, page: page, totalPages: min(total, 100))
            }
        }
        throw HGError.message("榜单格式已变化")
    }

    static func parseSuggestions(_ object: [String: Any]) -> [String] {
        var seen = Set<String>(), result = [String]()
        for value in ProtocolJSON.array(object["suggest_list"]) {
            let row = ProtocolJSON.dictionary(value), name = ProtocolJSON.text(row["name"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let text = name.isEmpty ? ProtocolJSON.text(ProtocolJSON.array(row["display_words"]).first).trimmingCharacters(in: .whitespacesAndNewlines) : name
            guard !text.isEmpty, text.count <= 80, seen.insert(text).inserted, result.count < 8 else { continue }
            result.append(text)
        }
        return result
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}

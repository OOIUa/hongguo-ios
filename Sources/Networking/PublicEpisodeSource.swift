// SPDX-License-Identifier: GPL-3.0-only
// Guest player fallback adapted from jackotom/hongguo-drama v8.0 (8d14d07), src/native/hongguo.js.
import Foundation

enum PublicEpisodeSource {
    enum Failure: LocalizedError {
        case unavailable, rateLimited, invalidResponse, http(Int)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "官网暂未向访客提供本集完整片源"
            case .rateLimited: return "官网请求过于频繁，请稍后再试"
            case .invalidResponse: return "官网未返回有效的分集播放信息"
            case .http(let status): return "官网片源请求失败（HTTP \(status)）"
            }
        }
    }

    struct EpisodeInfo {
        let duration: WebEpisodeDuration
        let definition: String
    }

    static func track(seriesID: String, episodeID: String, session: URLSession) async throws -> VideoTrack {
        guard ProtocolJSON.identifier(seriesID) != nil, ProtocolJSON.identifier(episodeID) != nil else { throw Failure.invalidResponse }
        let page = URL(string: "\(WebsiteCatalog.base)/player/\(seriesID)/\(episodeID)")!
        let html = try await load(URLRequest(url: page), session: session, limit: 4 * 1024 * 1024)
        let info = try episodeInfo(html: String(decoding: html, as: UTF8.self), seriesID: seriesID, episodeID: episodeID)

        var request = URLRequest(url: URL(string: WebsiteCatalog.base + "/api/video/protected/fallback-play-info")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try ProtocolJSON.data(["item_id": episodeID])
        let data = try await load(request, session: session, limit: 64 * 1024)
        return try track(response: data, info: info)
    }

    static func episodeInfo(html: String, seriesID: String, episodeID: String) throws -> EpisodeInfo {
        guard let page = WebsiteCatalog.inlineLoader(html, select: { $0["player_(series_id)/(vid)/page"] as? [String: Any] }),
              page["isSuccess"] as? Bool == true,
              ProtocolJSON.identifier(page["series_id"]) == seriesID, ProtocolJSON.identifier(page["vid"]) == episodeID,
              let series = page["seriesDetail"] as? [String: Any], ProtocolJSON.identifier(series["series_id"]) == seriesID
        else { throw Failure.invalidResponse }

        let access = ProtocolJSON.dictionary(page["req"])
        let ids = ProtocolJSON.array(series["vid_list"])
        guard access["pcLoginRequired"] as? Bool == false, access["pcAuthenticatedPlayback"] as? Bool == false,
              let index = ids.firstIndex(where: { ProtocolJSON.identifier($0) == episodeID }),
              index < ProtocolJSON.integer(series["accessible_episode_cnt"])
        else { throw Failure.unavailable }

        // Many guest-playable episodes omit SEO metadata. When present, the page duration is for the whole
        // episode even though its embedded SEO video may be a ten-second trailer.
        let metadata = ProtocolJSON.dictionary(page["publicVideoSeo"])
        guard metadata["available"] as? Bool == true else {
            return EpisodeInfo(duration: .unlisted, definition: "网页片源")
        }
        guard ProtocolJSON.identifier(metadata["seriesId"]) == seriesID, ProtocolJSON.identifier(metadata["itemId"]) == episodeID,
              let duration = Double(ProtocolJSON.text(metadata["durationSeconds"])), duration.isFinite, duration > 0
        else { throw Failure.invalidResponse }
        let pixels = min(ProtocolJSON.integer(metadata["width"]), ProtocolJSON.integer(metadata["height"]))
        return EpisodeInfo(duration: .declared(duration), definition: pixels > 0 ? "网页 \(pixels)P" : "网页片源")
    }

    static func track(response: Data, info: EpisodeInfo, now: Date = Date()) throws -> VideoTrack {
        guard let json = try? ProtocolJSON.object(response),
              ProtocolJSON.text(ProtocolJSON.dictionary(json["base_resp"])["StatusCode"] ?? json["code"]) == "0",
              let rawURL = json["main_url"] as? String, let url = URL(string: rawURL),
              VideoTrack.allowsMediaURL(url) else { throw Failure.invalidResponse }
        if let value = json["url_expire"] {
            guard let expiry = Double(ProtocolJSON.text(value)), expiry.isFinite,
                  expiry > now.timeIntervalSince1970 + 5 else { throw Failure.invalidResponse }
        }
        return VideoTrack(url: url, spadeA: "", encrypted: false, definition: info.definition, expectedDuration: info.duration)
    }

    private static func load(_ input: URLRequest, session: URLSession, limit: Int) async throws -> Data {
        try Task.checkCancellation()
        var request = input
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 6
        let (bytes, response) = try await session.bytes(for: DramaAPI.boundedRequest(request, until: DramaAPI.playbackDeadline),
                                                        delegate: ProtocolSessionDelegate())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, response.url == input.url else { throw Failure.unavailable }
        if let delay = http.value(forHTTPHeaderField: "Retry-After"), !delay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure.rateLimited
        }
        switch http.statusCode {
        case 200: break
        case 300..<400, 401, 403, 404: throw Failure.unavailable
        case 429: throw Failure.rateLimited
        default: throw Failure.http(http.statusCode)
        }
        guard response.expectedContentLength <= limit else { throw Failure.invalidResponse }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw Failure.invalidResponse }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}

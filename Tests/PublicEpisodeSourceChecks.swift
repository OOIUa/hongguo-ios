// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func checkPublicEpisodes() throws {
    let series = "7000000000000000001", first = "7000000000000000002", locked = "7000000000000000003"
    func page(vid: String = first, login: Bool = false, metadataID: String = first, seo: Bool = true) throws -> String {
        var loader: [String: Any] = [
            "isSuccess": true, "series_id": series, "vid": vid,
            "req": ["pcLoginRequired": login, "pcAuthenticatedPlayback": false],
            "seriesDetail": ["series_id": series, "accessible_episode_cnt": 1, "vid_list": [first, locked]],
            "publicVideoSeo": ["available": true, "seriesId": series, "itemId": metadataID,
                               "durationSeconds": 125.14, "width": 360, "height": 640]
        ]
        if !seo { loader.removeValue(forKey: "publicVideoSeo") }
        let bytes = try ProtocolJSON.data(["loaderData": ["player_(series_id)/(vid)/page": loader]])
        return "<script>_ROUTER_DATA = " + String(decoding: bytes, as: UTF8.self) + ";</script>"
    }
    func rejected<T>(_ reason: String, _ operation: () throws -> T) {
        do { _ = try operation(); preconditionFailure(reason) }
        catch { precondition(error is PublicEpisodeSource.Failure, reason) }
    }

    let info = try PublicEpisodeSource.episodeInfo(html: page(), seriesID: series, episodeID: first)
    precondition(info.duration == .declared(125.14) && info.definition.contains("360"))
    let unlisted = try PublicEpisodeSource.episodeInfo(html: page(seo: false), seriesID: series, episodeID: first)
    precondition(unlisted.duration == .unlisted)
    rejected("Page redirected to a different episode") {
        try PublicEpisodeSource.episodeInfo(html: page(), seriesID: series, episodeID: locked)
    }
    rejected("Series metadata advertises an inaccessible episode") {
        try PublicEpisodeSource.episodeInfo(html: page(vid: locked, metadataID: locked), seriesID: series, episodeID: locked)
    }
    rejected("Sign-in required") { try PublicEpisodeSource.episodeInfo(html: page(login: true), seriesID: series, episodeID: first) }
    rejected("Preview metadata is for a different episode") {
        try PublicEpisodeSource.episodeInfo(html: page(metadataID: locked), seriesID: series, episodeID: first)
    }

    let media = "https://v3-hgweb.qznovelvod.com/example.mp4"
    func read(_ url: String, expiry: Int = 1010, code: Int = 0) throws -> VideoTrack {
        let bytes = try ProtocolJSON.data(["base_resp": ["StatusCode": code], "main_url": url, "url_expire": expiry])
        return try PublicEpisodeSource.track(response: bytes, info: info, now: Date(timeIntervalSince1970: 1000))
    }
    let track = try read(media)
    precondition(track.url.absoluteString == media && track.expectedDuration == info.duration && !track.encrypted)
    rejected("Stale media URL") { try read(media, expiry: 995) }
    rejected("Nonzero guest status") { try read(media, code: 1) }
    for invalid in ["https://qznovelvod.com.example/video.mp4", "http://v3.qznovelvod.com/video.mp4",
                    "https://name@fqnovelvod.com/video.mp4", "https://127.0.0.1/video.mp4"] {
        rejected("Unexpected media origin") { try read(invalid) }
    }
}

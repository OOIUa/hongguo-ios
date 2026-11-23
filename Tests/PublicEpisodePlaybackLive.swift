// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import CoreVideo
import Foundation

// Only the official guest website can reach the network through this session. The media
// loader uses its own session after the public resolver has selected a CDN rendition.
private class EmptyAppReplies: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, url.scheme == "https", url.host == "hongguoduanju.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return true }
        let isPublicPage = request.httpMethod == "GET" && url.path.hasPrefix("/player/")
        let isGuestLookup = request.httpMethod == "POST" && url.path == "/api/video/protected/fallback-play-info"
        return !(isPublicPage || isGuestLookup)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = url.path.contains("/device_register")
            ? Data(#"{"code":0,"device_id_str":"1111111111111111","install_id_str":"2222222222222222"}"#.utf8)
            : Data()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MixedAppReplies: EmptyAppReplies, @unchecked Sendable {
    override func startLoading() {
        if request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == DramaAPI.singleVideoPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else {
            super.startLoading()
        }
    }
}

@main struct PublicEpisodePlaybackLive {
    private struct Sample {
        let label: String
        let seriesID: String
        let episodeID: String
        var acceptsGuestLimit = false
        var mixedAppReplies = false
    }

    // The official listings exposed the first three episodes to guests on 2026-11-23.
    private static let samples = [
        Sample(label: "铁血信使 1", seriesID: "7696083096164125721", episodeID: "7696085244503411774"),
        Sample(label: "铁血信使 2", seriesID: "7696083096164125721", episodeID: "7696085113104239678"),
        Sample(label: "持械入宋：第七季 1", seriesID: "7690112243203050521", episodeID: "7690125606729550872"),
        Sample(label: "分家住破屋，我赶山带妻女吃肉 1", seriesID: "7706488837177887768", episodeID: "7706488843343498264", mixedAppReplies: true),
        Sample(label: "装穷提亲，娶到全家嫌弃的她 1", seriesID: "7701328280862854168", episodeID: "7701328426518465561"),
        Sample(label: "灾荒之年，我能往返两界 1", seriesID: "7704961272428645401", episodeID: "7704961301620984856", mixedAppReplies: true),
        Sample(label: "分家住破屋，我赶山带妻女吃肉 31", seriesID: "7706488837177887768", episodeID: "7706488855305653272", acceptsGuestLimit: true)
    ]

    static func main() async {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live" else {
            print("Pass --live to test guest playback.")
            exit(2)
        }
        let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-guest-" + UUID().uuidString)
        let cache = ProgressiveCache(root: directory)
        print("DramaAPI.track uses fixture App HTTP replies. Guest lookup, CDN ranges and AVPlayer are live.")
        var failures = 0
        for sample in samples {
            let config = URLSessionConfiguration.ephemeral
            config.urlCredentialStorage = nil
            config.protocolClasses = [sample.mixedAppReplies ? MixedAppReplies.self : EmptyAppReplies.self]
            let api = DramaAPI(resourceDirectory: resources, configuration: config)
            var stage = "track"
            do {
                let track = try await api.track(episodeID: sample.episodeID, seriesID: sample.seriesID)
                let trace = await api.lastPlaybackTrace
                guard trace.contains("=0B"), trace.contains("W=ok"),
                      !sample.mixedAppReplies || trace.contains("=failed"), !track.encrypted, track.spadeA.isEmpty else {
                    throw HGError.message("Unexpected public media selection")
                }
                stage = "progressive-source"
                let source = try await ProgressiveSource.open(track: track, episodeID: sample.episodeID, cache: cache)
                stage = "playback"
                let stream = await ProgressivePlayback.make(source: source)
                defer { stream.close() }
                let result = try await play(asset: stream.asset)
                print("PASS \(sample.label) \(result) trace=\(await api.lastPlaybackTrace)")
            } catch PublicEpisodeSource.Failure.unavailable where sample.acceptsGuestLimit && stage == "track" {
                let trace = await api.lastPlaybackTrace
                if trace.contains("=0B"), trace.contains("W=failed") {
                    print("PASS \(sample.label) public source unavailable, no media requested trace=\(trace)")
                } else {
                    failures += 1
                    print("FAIL \(sample.label) fixture or guest route did not run trace=\(trace)")
                }
            } catch {
                failures += 1
                let detail: String
                if error is PublicEpisodeSource.Failure || error is HGError || error is MediaError {
                    detail = error.localizedDescription
                } else {
                    detail = (error as NSError).domain + "/" + String((error as NSError).code)
                }
                let trace = await api.lastPlaybackTrace
                if stage == "track" {
                    stage = trace.contains("W=failed") ? "guest-source" : "app-lookup"
                }
                print("FAIL \(sample.label) stage=\(stage) error=\(detail) trace=\(trace)")
            }
            fflush(stdout)
        }
        try? FileManager.default.removeItem(at: directory)
        print("Guest playback checks: \(samples.count - failures)/\(samples.count) matched expectations")
        if failures > 0 { exit(1) }
    }

    @MainActor private static func play(asset: AVAsset) async throws -> String {
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.playImmediately(atRate: 1)
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        var deadline = ContinuousClock.now + .seconds(35)
        var frames = 0
        var sequentialTime: Double?
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            guard item.status != .failed else { throw item.error ?? MediaError.unavailable }
            let time = item.currentTime()
            var displayed = CMTime.invalid
            if output.hasNewPixelBuffer(forItemTime: time),
               let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) {
                frames += 1
                let duration = item.duration.seconds
                if let sequentialTime {
                    if displayed.seconds >= duration - 3.5 {
                        return String(format: "%dx%d played=%.2fs near_end_frame=%.2fs duration=%.2fs decoded_samples=%d",
                                      CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame), sequentialTime, displayed.seconds, duration, frames)
                    }
                } else if displayed.seconds >= 11, frames > 1, duration.isFinite {
                    sequentialTime = displayed.seconds
                    deadline = ContinuousClock.now + .seconds(20)
                    let target = CMTime(seconds: max(0, duration - 3), preferredTimescale: 600)
                    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
                }
            }
        }
        throw HGError.message(sequentialTime == nil ? "No decoded frame past 11 seconds" : "No decoded frame near the end")
    }
}

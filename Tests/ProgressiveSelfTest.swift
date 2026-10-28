// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation
import CoreVideo
import QuartzCore

private actor FixtureServer {
    let data: Data
    var requests: [Range<Int>] = []
    var delay: UInt64
    let delayAfterFirst: Bool
    init(_ data: Data, delay: UInt64 = 0, delayAfterFirst: Bool = false) { self.data = data; self.delay = delay; self.delayAfterFirst = delayAfterFirst }
    func fetch(_ range: Range<Int>) async throws -> MediaRangeReply {
        requests.append(range)
        if delay > 0 && (!delayAfterFirst || requests.count > 1) { try await Task.sleep(nanoseconds: delay) }
        try Task.checkCancellation()
        guard range.lowerBound < data.count else { throw MediaError.invalidMedia }
        return MediaRangeReply(data: data.subdata(in: range.lowerBound..<min(range.upperBound, data.count)), total: data.count)
    }
    func requested() -> [Range<Int>] { requests }
    func setDelay(_ value: UInt64) { delay = value }
}

private func check(_ condition: Bool, _ label: String) throws {
    if !condition { throw NSError(domain: "ProgressiveSelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
}

@main struct ProgressiveSelfTest {
    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-progressive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fixture = try await ProgressiveFixture.make()
        try await progressiveTransportChecks(root: base.appendingPathComponent("cache-checks"))
        try check(fixture.encrypted.count > 1024 * 1024, "Fixture must contain over 1 MB of actual video")
        print("fixture_bytes=\(fixture.encrypted.count)")
        let cache = ProgressiveCache(root: base.appendingPathComponent("cache"))
        let track = VideoTrack(url: URL(string: "https://test.qznovelvod.com/video.mp4")!, spadeA: fixture.spade, encrypted: true, definition: "test")
        let server = FixtureServer(fixture.encrypted, delay: 80_000_000)
        let source = try await ProgressiveSource.open(track: track, episodeID: "test", cache: cache, fetch: { try await server.fetch($0) })
        let opened = await source.metrics()
        try check(opened.networkBytes < opened.length / 2, "Opening fetched half or more of the movie")
        let playback = await ProgressivePlayback.make(source: source)
        let asset = playback.asset
        let playable = try await asset.load(.isPlayable)
        try check(playable, "Virtual clear MP4 is not playable")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output)
        try check(reader.startReading(), "Reader could not start")
        let frame = output.copyNextSampleBuffer()
        try check(frame != nil && CMSampleBufferGetImageBuffer(frame!) != nil, "First real H.264 frame was not decoded")
        let firstFrame = await source.metrics()
        try check(firstFrame.networkBytes < firstFrame.length, "First frame waited for the entire movie")
        print("PASS first decoded frame: \(firstFrame.networkBytes)/\(firstFrame.length) network bytes (\(Int(Double(firstFrame.networkBytes) / Double(firstFrame.length) * 100))%)")
        reader.cancelReading()

        // Read out of order, across AES sample and HTTP block boundaries, plus repaired tail moov.
        for offset in [fixture.offsets[0] + 3, fixture.offsets[90] + 7, fixture.offsets[179], ProgressiveCache.blockSize - 17, fixture.encrypted.count - 200] {
            let count = min(61_013, fixture.encrypted.count - offset)
            let actual = try await source.read(at: offset, count: count)
            try check(actual == fixture.clear.subdata(in: offset..<(offset + count)), "Random-range output differs from independently full-decrypted reference")
        }
        print("PASS arbitrary seeks, sample/block boundaries, and tail-moov repair match complete-file oracle")

        await source.setPaused(true)
        let cancelledRead = Task { try await source.read(at: fixture.offsets[120], count: 64) }
        let beforePause = await server.requested().count
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterPause = await server.requested().count
        try check(beforePause == afterPause, "Pause continued requesting new ranges")
        cancelledRead.cancel()
        do { _ = try await cancelledRead.value; throw NSError(domain: "CancelledReadAccepted", code: 1) } catch is CancellationError { }
        await source.setPaused(false)
        let resumed = try await source.read(at: fixture.offsets[120], count: 64)
        try check(resumed == fixture.clear.subdata(in: fixture.offsets[120]..<(fixture.offsets[120] + 64)), "Resume returned wrong data")
        playback.close(); await source.close()

        try await playerChecks(fixture: fixture, track: track, cache: cache)

        // A new owner must reuse verified disk blocks, without relying on the previous actor's memory.
        let server2 = FixtureServer(fixture.encrypted)
        let reopened = try await ProgressiveSource.open(track: track, episodeID: "test", cache: cache, fetch: { try await server2.fetch($0) })
        let countBefore = await server2.requested().count
        _ = try await reopened.read(at: fixture.offsets[90] + 7, count: 100)
        let countAfter = await server2.requested().count
        try check(countBefore == countAfter, "Verified cached ranges were downloaded again")
        await reopened.close()
        print("PASS pause/resume, cancelled waiting read, new-owner disk cache reuse")

        let server8 = FixtureServer(fixture.encrypted8)
        let source8 = try await ProgressiveSource.open(track: track, episodeID: "test8", cache: cache, fetch: { try await server8.fetch($0) })
        let offset8 = fixture.offsets[80] + 13
        let actual8 = try await source8.read(at: offset8, count: 40_001)
        try check(actual8 == fixture.clear8.subdata(in: offset8..<(offset8 + 40_001)), "8-byte IV range mismatch")
        await source8.close()
        let plainTrack = VideoTrack(url: track.url, spadeA: "", encrypted: false, definition: "plain")
        let plainServer = FixtureServer(fixture.plain)
        let plain = try await ProgressiveSource.open(track: plainTrack, episodeID: "plain", cache: cache, fetch: { try await plainServer.fetch($0) })
        let plainBytes = try await plain.read(at: 500_003, count: 32_001)
        try check(plainBytes == fixture.plain.subdata(in: 500_003..<532_004), "Plain MP4 range mismatch")
        await plain.close()

        let slow = FixtureServer(fixture.encrypted)
        let closing = try await ProgressiveSource.open(track: track, episodeID: "cancel", cache: cache, fetch: { try await slow.fetch($0) })
        await slow.setDelay(30_000_000_000)
        let previousRequests = await slow.requested().count
        let inFlight = Task { try await closing.read(at: fixture.offsets[100], count: 100) }
        for _ in 0..<50 {
            if await slow.requested().count > previousRequests { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancelledAt = Date()
        await closing.close()
        do { _ = try await inFlight.value; throw NSError(domain: "CloseDidNotCancel", code: 1) } catch is CancellationError { }
        try check(Date().timeIntervalSince(cancelledAt) < 1, "Owner close waited for a slow network range")
        print("PASS owner close cancels an in-flight 30-second range immediately")

        let slowIndex = FixtureServer(fixture.encrypted, delay: 30_000_000_000, delayAfterFirst: true)
        let opening = Task { try await ProgressiveSource.open(track: track, episodeID: "cancel-opening", cache: cache, fetch: { try await slowIndex.fetch($0) }) }
        for _ in 0..<50 {
            if await slowIndex.requested().count > 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let openingCancelledAt = Date(); opening.cancel()
        do { _ = try await opening.value; throw NSError(domain: "OpenDidNotCancel", code: 1) } catch is CancellationError { }
        try check(Date().timeIntervalSince(openingCancelledAt) < 1, "Opening did not cancel its slow metadata request")
        print("PASS cancelling during index preparation immediately cancels its range")

        // Clearing must preserve an active player's files, but remove them once its lease ends.
        let filesBefore = (FileManager.default.enumerator(at: base.appendingPathComponent("cache"), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        try check(filesBefore.contains { $0.pathExtension == "chunk" }, "No ranges were persisted")
        try await cache.clear()
        let filesAfter = (FileManager.default.enumerator(at: base.appendingPathComponent("cache"), includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        try check(!filesAfter.contains { $0.pathExtension == "chunk" }, "Closed cache could not be cleared")
        print("PASS 8/16-byte IVs, plain MP4, cache cleanup; no external network used")
    }

    @MainActor private static func playerChecks(fixture: ProgressiveFixture, track: VideoTrack, cache: ProgressiveCache) async throws {
        let server = FixtureServer(fixture.encrypted, delay: 100_000_000)
        let source = try await ProgressiveSource.open(track: track, episodeID: "player", cache: cache, fetch: { try await server.fetch($0) })
        let playback = await ProgressivePlayback.make(source: source)
        let item = AVPlayerItem(asset: playback.asset)
        item.preferredForwardBufferDuration = 1
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.playImmediately(atRate: 1)
        var rendered = false
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let frame = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) {
                rendered = CVPixelBufferGetWidth(frame) > 0; break
            }
            if item.status == .failed { break }
        }
        try check(rendered, "Actual AVPlayer did not render a frame")
        let firstFrame = await source.metrics()
        try check(firstFrame.networkBytes < firstFrame.length, "Actual AVPlayer waited for the whole movie")
        print("PASS actual AVPlayer first frame: \(firstFrame.networkBytes)/\(firstFrame.length) network bytes")
        let sought = await player.seek(to: CMTime(seconds: 6, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try check(sought, "AVPlayer seek into an uncached range failed")
        player.playImmediately(atRate: 1)
        var afterSeek = false
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if item.currentTime().seconds >= 6, output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil) != nil { afterSeek = true; break }
        }
        try check(afterSeek, "AVPlayer did not render after seeking")
        player.pause(); player.replaceCurrentItem(with: nil); playback.close(); await source.close()
        print("PASS actual AVPlayer seeks to an uncached later position and renders")
    }
}

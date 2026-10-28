// SPDX-License-Identifier: GPL-3.0-only
// Explicit public-media smoke test. Never prints playback URLs, identities, cookies or keys.
import Foundation
import AVFoundation
import CoreVideo

@main struct LiveProgressiveSmoke {
    static func main() async {
        var stage = "initializing"
        var playback: ProgressivePlayback?
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-progressive-live-" + UUID().uuidString)
        defer { playback?.close(); try? FileManager.default.removeItem(at: cacheRoot) }
        do {
            guard CommandLine.arguments.contains("--live"), CommandLine.arguments.count >= 3 else { return }
            let resources = URL(fileURLWithPath: CommandLine.arguments.last!, isDirectory: true)
            let api = DramaAPI(resourceDirectory: resources)
            stage = "track"
            let page = try await api.home(feed: "hot", offset: 0)
            guard let drama = page.dramas.first else { throw MediaError.unavailable }
            let detail = try await api.detail(drama: drama)
            guard let episode = detail.episodes.first else { throw MediaError.unavailable }
            let track = try await api.track(episodeID: episode.id)
            stage = "range-index"
            let source = try await ProgressiveSource.open(track: track, episodeID: episode.id, cache: ProgressiveCache(root: cacheRoot))
            playback = await ProgressivePlayback.make(source: source)
            guard let playback else { throw MediaError.unavailable }
            let initial = await source.metrics()
            print("encrypted=\(track.encrypted) total_bytes=\(initial.length) index_network_bytes=\(initial.networkBytes)")
            stage = "decode"
            let tracks = try await playback.asset.load(.tracks)
            let reader = try AVAssetReader(asset: playback.asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
            var video: AVAssetReaderTrackOutput?, audio: AVAssetReaderTrackOutput?
            for item in tracks {
                if item.mediaType == .video && video == nil {
                    let output = AVAssetReaderTrackOutput(track: item, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                    reader.add(output); video = output
                } else if item.mediaType == .audio && audio == nil {
                    let output = AVAssetReaderTrackOutput(track: item, outputSettings: [AVFormatIDKey:kAudioFormatLinearPCM])
                    reader.add(output); audio = output
                }
            }
            guard let video, reader.startReading(), let first = video.copyNextSampleBuffer(), CMSampleBufferGetImageBuffer(first) != nil else { throw MediaError.unavailable }
            let firstFrame = await source.metrics()
            print("first_frame_network_bytes=\(firstFrame.networkBytes) fraction=\(Double(firstFrame.networkBytes) / Double(firstFrame.length))")
            guard firstFrame.networkBytes < firstFrame.length else { throw MediaError.invalidMedia }
            var frames = 1, buffers = 0, videoDone = false, audioDone = audio == nil
            while !videoDone || !audioDone {
                if !videoDone { if video.copyNextSampleBuffer() != nil { frames += 1 } else { videoDone = true } }
                if !audioDone { if audio?.copyNextSampleBuffer() != nil { buffers += 1 } else { audioDone = true } }
            }
            guard reader.status == .completed, frames > 1, audio == nil || buffers > 0 else { throw MediaError.unavailable }
            playback.close(); await source.close()
            print("PASS live progressive: first frame before complete download, video_frames=\(frames), audio_buffers=\(buffers)")
        } catch {
            print("FAIL progressive: stage=\(stage) kind=\(String(reflecting: type(of: error)))")
            exit(1)
        }
    }
}

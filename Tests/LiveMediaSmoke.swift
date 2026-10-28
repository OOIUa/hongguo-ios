// SPDX-License-Identifier: GPL-3.0-only
// Explicit opt-in smoke test. Never prints source URLs, content keys, cookies or identities.
import Foundation
import AVFoundation
import CoreVideo

@main struct LiveMediaSmoke {
    static func main() async {
        var stage = "initializing"
        do {
            guard CommandLine.arguments.contains("--live"), CommandLine.arguments.count >= 3 else {
                print("Usage: live-media-smoke --live <networking-resource-directory>"); return
            }
            let resources = URL(fileURLWithPath: CommandLine.arguments.last!, isDirectory: true)
            let api = DramaAPI(resourceDirectory: resources)
            stage = "home"
            let page = try await api.home(feed: "hot", offset: 0)
            guard let drama = page.dramas.first else { throw HGError.message("首页为空") }
            print("home_items=\(page.dramas.count)")
            stage = "details"
            let detail = try await api.detail(drama: drama)
            guard let episode = detail.episodes.first else { throw HGError.message("分集为空") }
            print("episodes=\(detail.episodes.count)")
            stage = "track"
            let track = try await api.track(episodeID: episode.id)
            print("track_encrypted=\(track.encrypted) definition=\(track.definition)")
            stage = "prepare"
            let url = try await MediaPreparer.shared.prepare(track: track, episodeID: episode.id, progress: { _, _ in })
            await MediaPreparer.shared.pin(url)
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            print("prepared_bytes=\(bytes)")
            let secondURL = try await MediaPreparer.shared.prepare(track: track, episodeID: episode.id) { stage, _ in
                if stage == "已读取缓存" { print("cache_reuse=true") }
            }
            guard secondURL == url else { throw MediaError.invalidMedia }
            stage = "decode"
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.load(.tracks)
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3, preferredTimescale: 600))
            var videoOutput: AVAssetReaderTrackOutput?, audioOutput: AVAssetReaderTrackOutput?
            for item in tracks {
                if item.mediaType == .video && videoOutput == nil {
                    let output = AVAssetReaderTrackOutput(track: item, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    reader.add(output); videoOutput = output
                } else if item.mediaType == .audio && audioOutput == nil {
                    let output = AVAssetReaderTrackOutput(track: item, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    reader.add(output); audioOutput = output
                }
            }
            guard videoOutput != nil, reader.startReading() else { throw MediaError.unavailable }
            var videoFrames = 0, audioBuffers = 0, videoDone = false, audioDone = audioOutput == nil
            while !videoDone || !audioDone {
                if !videoDone { if videoOutput?.copyNextSampleBuffer() != nil { videoFrames += 1 } else { videoDone = true } }
                if !audioDone { if audioOutput?.copyNextSampleBuffer() != nil { audioBuffers += 1 } else { audioDone = true } }
            }
            await MediaPreparer.shared.unpin(url)
            guard reader.status == .completed, videoFrames > 0, audioOutput == nil || audioBuffers > 0 else { throw MediaError.unavailable }
            print("PASS: anonymous API -> episode -> CDN download -> CENC processing -> AVFoundation decoded video_frames=\(videoFrames) audio_buffers=\(audioBuffers)")
        } catch {
            print("FAIL: stage=\(stage) kind=\(String(reflecting: type(of: error)))")
            exit(1)
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Player-scoped resource loader; the owner retains this object for the lifetime of AVPlayerItem.
final class ProgressivePlayback: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    let source: ProgressiveSource
    private let length: Int
    private let queue = DispatchQueue(label: "com.ooiua.hongguo.progressive-loader")
    private var requests: [ObjectIdentifier: (AVAssetResourceLoadingRequest, Task<Void, Never>)] = [:]
    private var closed = false

    private init(source: ProgressiveSource, length: Int) {
        self.source = source; self.length = length
        asset = AVURLAsset(url: URL(string: "hongguo-media://\(UUID().uuidString)/video.mp4")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }
    static func open(track: VideoTrack, episodeID: String,
                     progress: @Sendable @escaping (String, Double) -> Void = { _, _ in }) async throws -> ProgressivePlayback {
        let source = try await ProgressiveSource.open(track: track, episodeID: episodeID, progress: progress)
        do {
            try Task.checkCancellation()
            return await make(source: source)
        } catch { await source.close(); throw error }
    }
    static func make(source: ProgressiveSource) async -> ProgressivePlayback {
        let metrics = await source.metrics()
        return ProgressivePlayback(source: source, length: metrics.length)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed, request.request.url == asset.url else { request.finishLoading(with: CancellationError()); return true }
        if let info = request.contentInformationRequest {
            info.contentType = UTType.mpeg4Movie.identifier
            info.contentLength = Int64(length)
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { request.finishLoading(); return true }
        let current = max(data.currentOffset, data.requestedOffset)
        guard current >= 0, current <= Int64(length), data.requestedLength >= 0,
              data.requestedOffset >= 0, data.requestedOffset <= Int64(length) else {
            request.finishLoading(with: MediaError.invalidMedia); return true
        }
        let start = Int(current)
        let end: Int
        if data.requestsAllDataToEndOfResource { end = length }
        else {
            let requestedStart = Int(data.requestedOffset)
            end = requestedStart + min(data.requestedLength, length - requestedStart)
        }
        guard start <= end else { request.finishLoading(with: MediaError.invalidMedia); return true }
        let identifier = ObjectIdentifier(request)
        let task = Task { [weak self, source] in
            var position = start
            do {
                while position < end {
                    try Task.checkCancellation()
                    let bytes = try await source.read(at: position, count: min(64 * 1024, end - position))
                    try Task.checkCancellation()
                    guard let self else { return }
                    let accepted = await self.deliver(bytes, to: request, identifier: identifier)
                    guard accepted else { return }
                    position += bytes.count
                }
                self?.finish(request, identifier: identifier, error: nil)
            } catch {
                self?.finish(request, identifier: identifier,
                             error: error is CancellationError ? CancellationError() : ((error as? MediaError) ?? .transport))
            }
        }
        requests[identifier] = (request, task)
        return true
    }
    private func deliver(_ bytes: Data, to request: AVAssetResourceLoadingRequest, identifier: ObjectIdentifier) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !closed, requests[identifier] != nil, !request.isCancelled, !request.isFinished else {
                    continuation.resume(returning: false); return
                }
                request.dataRequest?.respond(with: bytes)
                continuation.resume(returning: true)
            }
        }
    }
    private func finish(_ request: AVAssetResourceLoadingRequest, identifier: ObjectIdentifier, error: Error?) {
        queue.async { [self] in
            guard requests.removeValue(forKey: identifier) != nil, !request.isCancelled, !request.isFinished else { return }
            if let error { request.finishLoading(with: error) } else { request.finishLoading() }
        }
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        requests.removeValue(forKey: ObjectIdentifier(request))?.1.cancel()
    }
    func pause() { Task { await source.setPaused(true) } }
    func resume() { Task { await source.setPaused(false) } }
    func close() {
        queue.async { [self] in
            guard !closed else { return }; closed = true
            for (request, task) in requests.values {
                task.cancel()
                if !request.isFinished && !request.isCancelled { request.finishLoading(with: CancellationError()) }
            }
            requests.removeAll()
            Task { await source.close() }
        }
    }
}

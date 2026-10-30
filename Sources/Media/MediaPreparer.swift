// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation
import CryptoKit

/// Complete-file preparation is retained for optional next-episode preloading and legacy caches.
/// A final file is visible only after download, CENC processing and validation succeed.
actor MediaPreparer {
    static let shared = MediaPreparer()
    private let fm = FileManager.default
    private var active: Set<UUID> = []
    private var pins: [URL: Int] = [:]
    private var initialized = false
    private let limit = MP4Processor.maximumBytes

    private var root: URL {
        fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PreparedMedia-v1", isDirectory: true)
    }
    private struct CacheRecord: Codable { let bytes: Int; let sha256: String }

    func cachedPlayback(track: VideoTrack, episodeID: String) throws -> URL? {
        try Task.checkCancellation()
        let key = HGCrypto.sha256(Data((episodeID + ":" + track.definition).utf8)).map { String(format: "%02x", $0) }.joined()
        let movie = root.appendingPathComponent(key + ".mp4"), record = root.appendingPathComponent(key + ".json")
        guard fm.fileExists(atPath: record.path) else { return nil }
        do { return try cachedFile(movie, record: record) }
        catch { try Task.checkCancellation(); return nil }
    }

    func prepare(track: VideoTrack, episodeID: String, progress: @Sendable @escaping (String, Double) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard !episodeID.isEmpty, episodeID.count <= 64,
              track.url.scheme?.lowercased() == "https", track.url.user == nil, track.url.password == nil,
              MediaDownload.allowed(track.url) else { throw MediaError.unavailable }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if !initialized {
            initialized = true
            for abandoned in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where abandoned.pathExtension == "part" {
                try? fm.removeItem(at: abandoned)
            }
        }
        let identifier = UUID(); active.insert(identifier)
        defer { active.remove(identifier) }
        let key = HGCrypto.sha256(Data((episodeID + ":" + track.definition).utf8)).map { String(format: "%02x", $0) }.joined()
        let finalURL = root.appendingPathComponent(key + ".mp4")
        let recordURL = root.appendingPathComponent(key + ".json")
        if let cached = try? cachedFile(finalURL, record: recordURL) {
            progress("已读取缓存", 1); return cached
        }
        // Cancellation during hashing is not evidence of corruption: preserve the valid cache.
        try Task.checkCancellation()
        // A missing/malformed sidecar is an uncommitted cache entry, never a cache hit.
        if pins[finalURL, default: 0] == 0 {
            try? fm.removeItem(at: finalURL); try? fm.removeItem(at: recordURL)
        }
        // AVURLAsset also consults the file extension: keep .mp4 inside an unpublished folder.
        let working = root.appendingPathComponent(identifier.uuidString + ".part", isDirectory: true)
        try fm.createDirectory(at: working, withIntermediateDirectories: true)
        let staging = working.appendingPathComponent("video.mp4")
        defer { try? fm.removeItem(at: working) }
        progress("正在下载视频", 0)
        do {
            try await MediaDownload.fetch(track.url, to: staging, limit: limit, progress: progress)
            try Task.checkCancellation()
            // Work is detached so file IO and cryptography never block the UI executor.
            let work = Task.detached(priority: .userInitiated) {
                if track.encrypted {
                    try MP4Processor.decrypt(url: staging, spade: track.spadeA, progress: progress)
                } else { try MP4Processor.validate(url: staging) }
            }
            try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            try Task.checkCancellation()
            let asset = AVURLAsset(url: staging)
            guard try await asset.load(.isPlayable) else { throw MediaError.unavailable }
            let size = try fileSize(staging)
            guard size > 0, size <= limit else { throw MediaError.tooLarge }
            let digest = try Self.hashFile(staging)
            let record = try JSONEncoder().encode(CacheRecord(bytes: size, sha256: digest))
            try Task.checkCancellation()
            // Clear-cache invalidates completed work that was already in flight.
            guard active.contains(identifier) else { throw CancellationError() }
            // Another request for the same episode may have completed while we downloaded.
            if let cached = try? cachedFile(finalURL, record: recordURL) {
                progress("已读取缓存", 1); return cached
            }
            try Task.checkCancellation()
            try pruneCache(reserving: size, protected: [finalURL])
            if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
            try fm.moveItem(at: staging, to: finalURL)
            do { try record.write(to: recordURL, options: .atomic) }
            catch { try? fm.removeItem(at: finalURL); throw error }
            progress("视频已就绪", 1)
            return finalURL
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let media = error as? MediaError { throw media }
            if (error as? CocoaError)?.code == .fileWriteOutOfSpace { throw error }
            // Upstream signed URLs and provider error bodies must never escape into the UI/logs.
            throw MediaError.transport
        }
    }

    /// UI may pin an item during playback to prevent cache eviction.
    func pin(_ url: URL) { pins[url, default: 0] += 1 }
    func unpin(_ url: URL) {
        let count = pins[url, default: 0] - 1
        if count <= 0 { pins.removeValue(forKey: url) } else { pins[url] = count }
    }

    /// Bytes on disk in both playback caches (prepared episodes and progressive chunks).
    func cacheSize() -> Int64 {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var total: Int64 = 0
        for folder in [root, caches.appendingPathComponent("ProgressiveMedia-v1", isDirectory: true)] {
            guard let files = fm.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { continue }
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
        }
        return total
    }

    func clearCache() async throws {
        active.removeAll()
        try await ProgressiveCache.shared.clear()
        guard fm.fileExists(atPath: root.path) else { return }
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension != "part" {
            let movie = file.deletingPathExtension().appendingPathExtension("mp4")
            if pins[movie, default: 0] == 0 { try? fm.removeItem(at: file) }
        }
    }

    private func cachedFile(_ url: URL, record: URL) throws -> URL {
        let metadata = try JSONDecoder().decode(CacheRecord.self, from: Data(contentsOf: record))
        guard metadata.bytes > 0, metadata.bytes <= limit, try fileSize(url) == metadata.bytes,
              try Self.hashFile(url) == metadata.sha256 else {
            try? fm.removeItem(at: url); try? fm.removeItem(at: record); throw MediaError.invalidMedia
        }
        try MP4Processor.validate(url: url)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    private func pruneCache(reserving bytes: Int, protected: Set<URL>) throws {
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "mp4" }
        let sizes = try files.map { ($0, try fileSize($0), (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        var total = sizes.reduce(0) { $0 + $1.1 }
        for (url, size, _) in sizes.sorted(by: { $0.2 < $1.2 }) where total + bytes > limit {
            guard pins[url, default: 0] == 0, !protected.contains(url) else { continue }
            try fm.removeItem(at: url); try? fm.removeItem(at: url.deletingPathExtension().appendingPathExtension("json")); total -= size
        }
        guard total + bytes <= limit else { throw MediaError.tooLarge }
    }
    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw MediaError.invalidMedia }; return size.intValue
    }
    private nonisolated static func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession owns the temporary download file; every error/cancellation deletes the staging file.
private final class MediaDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL, limit: Int, progress: @Sendable (String, Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var terminalError: Error?
    private var cancelled = false
    private var completedFile = false
    private var lastProgress = Date.distantPast

    private init(destination: URL, limit: Int, progress: @Sendable @escaping (String, Double) -> Void) {
        self.destination = destination; self.limit = limit; self.progress = progress
    }
    static func allowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else { return false }
        return ["qznovelvod.com", "fqnovelvod.com", "douyinvod.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func fetch(_ url: URL, to destination: URL, limit: Int, progress: @Sendable @escaping (String, Double) -> Void) async throws {
        let delegate = MediaDownload(destination: destination, limit: limit, progress: progress)
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in delegate.start(url, continuation: continuation) }
        }, onCancel: { delegate.cancel() })
    }
    private func start(_ url: URL, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request); self.task = task
        lock.unlock(); task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowed(url) else {
            terminalError = MediaError.transport; completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Int64(limit) || totalBytesExpectedToWrite > Int64(limit) {
            terminalError = MediaError.tooLarge; downloadTask.cancel(); return
        }
        if Date().timeIntervalSince(lastProgress) >= 0.2 {
            lastProgress = Date()
            let fraction = totalBytesExpectedToWrite > 0 ? min(0.99, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0
            progress("正在下载视频", fraction)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let finalURL = response.url, Self.allowed(finalURL) else { throw MediaError.transport }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size <= limit else { throw size > limit ? MediaError.tooLarge : MediaError.invalidMedia }
            if response.expectedContentLength >= 0 && response.expectedContentLength != Int64(size) { throw MediaError.invalidMedia }
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { throw CancellationError() }
            try FileManager.default.moveItem(at: location, to: destination); completedFile = true
        } catch { terminalError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; self.task = nil; let wasCancelled = cancelled; lock.unlock()
        let failure = wasCancelled ? CancellationError() : terminalError ?? error
        if let failure { try? FileManager.default.removeItem(at: destination); continuation?.resume(throwing: failure) }
        else if completedFile { continuation?.resume() }
        else { continuation?.resume(throwing: MediaError.transport) }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

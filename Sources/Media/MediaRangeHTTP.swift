// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct MediaRangeReply: Sendable { let data: Data; let total: Int }

/// Bounded HTTP 206 reads. Never downloads a whole response from a server ignoring Range.
final class MediaRangeHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let range: Range<Int>
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MediaRangeReply, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var failure: Error?
    private var bytes = Data()
    private var total = 0
    private var expected = 0

    private init(range: Range<Int>) { self.range = range }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), url.port == nil || url.port == 443 else { return false }
        return ["qznovelvod.com", "fqnovelvod.com", "douyinvod.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func fetch(_ url: URL, range: Range<Int>, configuration: URLSessionConfiguration? = nil) async throws -> MediaRangeReply {
        guard allowed(url), range.lowerBound >= 0, !range.isEmpty, range.count <= 32 * 1024 * 1024,
              range.upperBound <= MP4Processor.maximumBytes else { throw MediaError.invalidMedia }
        let transfer = MediaRangeHTTP(range: range)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { transfer.start(url, configuration: configuration, continuation: $0) }
        }, onCancel: { transfer.cancel() })
    }
    private func start(_ url: URL, configuration supplied: URLSessionConfiguration?, continuation: CheckedContinuation<MediaRangeReply, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let configuration = supplied ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 60
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request); self.task = task
        lock.unlock(); task.resume()
    }
    private func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowed(url) else { failure = MediaError.transport; completionHandler(nil); return }
        var safe = request; safe.httpShouldHandleCookies = false
        safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        completionHandler(safe)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let address = http.url, Self.allowed(address),
              let header = http.value(forHTTPHeaderField: "Content-Range"),
              let parsed = Self.contentRange(header), parsed.start == range.lowerBound,
              parsed.total > 0, parsed.total <= MP4Processor.maximumBytes,
              parsed.end == min(range.upperBound, parsed.total) - 1,
              parsed.end >= parsed.start else {
            failure = MediaError.transport; completionHandler(.cancel); return
        }
        total = parsed.total; expected = parsed.end - parsed.start + 1
        guard response.expectedContentLength < 0 || response.expectedContentLength == Int64(expected),
              http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true else {
            failure = MediaError.invalidMedia; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    static func contentRange(_ text: String) -> (start: Int, end: Int, total: Int)? {
        guard text.hasPrefix("bytes "), text.count <= 100 else { return nil }
        let parts = text.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int(parts[1]) else { return nil }
        let limits = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard limits.count == 2, let start = Int(limits[0]), let end = Int(limits[1]), start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= expected - bytes.count else { failure = MediaError.invalidMedia; dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let completion = continuation; continuation = nil; let wasCancelled = cancelled; self.task = nil; lock.unlock()
        if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let failure { completion?.resume(throwing: failure) }
        else if error != nil { completion?.resume(throwing: MediaError.transport) }
        else if total > 0, bytes.count == expected { completion?.resume(returning: MediaRangeReply(data: bytes, total: total)) }
        else { completion?.resume(throwing: MediaError.invalidMedia) }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

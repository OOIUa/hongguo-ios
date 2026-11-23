// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct MediaRangeReply: Sendable {
    let data: Data
    let total: Int
    var representationDigests: [String: Data] = [:]
}

/// One session per selected rendition. After the first read, a mirror must identify
/// the same complete representation. A digest of the current 206 body is insufficient.
actor MediaRangeSession {
    private let urls: [URL]
    private let configuration: URLSessionConfiguration?
    private var preferred = 0
    private var total: Int?
    private var origin = 0
    private var digests: [String: Data] = [:]
    private var stopped = false

    init(url: URL, backups: [URL] = [], configuration: URLSessionConfiguration? = nil) {
        self.urls = [url] + backups.filter(MediaRangeHTTP.allowed).prefix(2)
        self.configuration = configuration
    }

    func read(_ range: Range<Int>, attempts: Int = 5) async throws -> MediaRangeReply {
        var index = preferred
        var delay: UInt64 = 400_000_000
        for attempt in 1...max(1, attempts) {
            try Task.checkCancellation()
            guard !stopped else { throw MediaError.unavailable }
            let reply: MediaRangeReply
            do {
                reply = try await MediaRangeHTTP.fetch(urls[index], range: range, configuration: configuration)
            } catch MediaError.unavailable {
                stopped = true
                throw MediaError.unavailable
            } catch let error as MediaError {
                guard attempt < attempts, [.transport, .invalidMedia, .temporaryCDNFailure].contains(error) else { throw error }
                if error == .temporaryCDNFailure && urls.count > 1 && (total == nil || !digests.isEmpty) {
                    index = (index + 1) % urls.count
                }
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 4_000_000_000)
                continue
            }
            try Task.checkCancellation()
            guard !stopped else { throw MediaError.unavailable }
            if let total {
                guard reply.total == total else { throw MediaError.invalidMedia }
                if urls.count > 1 && (index != origin || (!digests.isEmpty && !reply.representationDigests.isEmpty)) {
                    let common = digests.keys.filter { reply.representationDigests[$0] != nil }
                    guard !common.isEmpty, common.allSatisfy({ digests[$0] == reply.representationDigests[$0] }) else {
                        throw MediaError.invalidMedia
                    }
                }
            } else {
                total = reply.total
                origin = index
                digests = reply.representationDigests
            }
            preferred = index
            return reply
        }
        throw MediaError.transport
    }
}

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
    private var representationDigests: [String: Data] = [:]

    private init(range: Range<Int>) { self.range = range }
    static func allowed(_ url: URL) -> Bool {
        VideoTrack.allowsMediaURL(url)
    }
    /// An allowed media host may answer 302 to another CDN for load balancing. Seen so far: *.vegslb.com, *.bdcgslb.com
    /// (2026-11-06), *.idouyinvod.com and *.smtcdns.com (2026-11-08). The set changes without notice and rejecting an
    /// unlisted CDN made episodes fail at random, so any public HTTPS host name is followed. The first URL must still be
    /// allowed(); credentials are never forwarded, and every reply is checked for an exact 206 range and the same total.
    static func allowedAfterRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), url.port == nil || url.port == 443 else { return false }
        if allowed(url) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), host.count <= 253,
              !host.contains(":"), !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let top = labels.last, top.contains(where: \.isLetter) else { return false }
        return !["localhost", "local", "internal", "lan", "home", "arpa"].contains(String(top))
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
        guard response.value(forHTTPHeaderField: "Retry-After") == nil,
              let url = request.url, Self.allowedAfterRedirect(url) else {
            failure = MediaError.unavailable; completionHandler(nil); return
        }
        var safe = request; safe.httpShouldHandleCookies = false
        safe.setValue(nil, forHTTPHeaderField: "Cookie"); safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        completionHandler(safe)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil else { completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, let address = http.url, Self.allowedAfterRedirect(address) else {
            failure = MediaError.unavailable; completionHandler(.cancel); return
        }
        if http.value(forHTTPHeaderField: "Retry-After") != nil || (400..<500).contains(http.statusCode) {
            failure = MediaError.unavailable; completionHandler(.cancel); return
        }
        if [500, 502, 503, 504].contains(http.statusCode) {
            failure = MediaError.temporaryCDNFailure; completionHandler(.cancel); return
        }
        guard http.statusCode == 206,
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
        representationDigests = Self.fullDigests(http.value(forHTTPHeaderField: "Repr-Digest"))
        completionHandler(.allow)
    }
    /// RFC 9530 Repr-Digest covers the full representation, including on a partial response.
    private static func fullDigests(_ header: String?) -> [String: Data] {
        guard let header, header.utf8.count <= 4096 else { return [:] }
        var digests: [String: Data] = [:]
        for item in header.split(separator: ",") {
            let pair = item.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            guard let raw = pair.first, raw == "sha-256" || raw == "sha-512" else { continue }
            let algorithm = String(raw)
            guard pair.count == 2, pair[1].first == ":", pair[1].last == ":", pair[1].count > 2,
                  let value = Data(base64Encoded: String(pair[1].dropFirst().dropLast())),
                  value.count == (algorithm == "sha-256" ? 32 : 64), digests[algorithm] == nil else { return [:] }
            digests[algorithm] = value
        }
        return digests
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
        else if let error {
            let code = (error as? URLError)?.code
            if code == .cancelled { completion?.resume(throwing: CancellationError()) }
            else if code == .notConnectedToInternet { completion?.resume(throwing: MediaError.transport) }
            else if let code, [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(code) {
                completion?.resume(throwing: MediaError.temporaryCDNFailure)
            } else { completion?.resume(throwing: MediaError.unavailable) }
        }
        else if total > 0, bytes.count == expected {
            completion?.resume(returning: MediaRangeReply(data: bytes, total: total, representationDigests: representationDigests))
        }
        else { completion?.resume(throwing: MediaError.invalidMedia) }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

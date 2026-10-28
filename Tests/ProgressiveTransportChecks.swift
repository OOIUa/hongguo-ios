// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private final class RangeProbeProtocol: URLProtocol {
    static var mode = "valid"
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let mode = Self.mode
        var headers = ["Content-Range":"bytes 0-1023/4096"]
        if mode == "wrong-range" { headers["Content-Range"] = "bytes 1-1024/4096" }
        if mode == "bad-total" { headers["Content-Range"] = "bytes 0-1023/512" }
        let response = HTTPURLResponse(url: request.url!, statusCode: mode == "ignore-range" ? 200 : 206,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "hang" { return }
        let count = mode == "truncated" ? 1023 : (mode == "overflow" ? 1025 : 1024)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

func progressiveTransportChecks(root: URL) async throws {
    let url = URL(string: "https://test.qznovelvod.com/movie.mp4")!
    func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [RangeProbeProtocol.self]; return value
    }
    let good = try await MediaRangeHTTP.fetch(url, range: 0..<1024, configuration: configuration())
    guard good.total == 4096, good.data == Data(repeating: 7, count: 1024),
          RangeProbeProtocol.lastRequest?.value(forHTTPHeaderField: "Range") == "bytes=0-1023",
          RangeProbeProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie") == nil,
          RangeProbeProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil else { throw MediaError.invalidMedia }
    for mode in ["ignore-range", "wrong-range", "bad-total", "truncated", "overflow"] {
        RangeProbeProtocol.mode = mode
        do { _ = try await MediaRangeHTTP.fetch(url, range: 0..<1024, configuration: configuration()); throw NSError(domain: "InvalidRangeAccepted-" + mode, code: 1) }
        catch is MediaError { }
    }
    RangeProbeProtocol.mode = "hang"
    let hanging = Task { try await MediaRangeHTTP.fetch(url, range: 0..<1024, configuration: configuration()) }
    try await Task.sleep(nanoseconds: 30_000_000); hanging.cancel()
    do { _ = try await hanging.value; throw NSError(domain: "RangeCancellationIgnored", code: 1) } catch is CancellationError { }
    for invalid in ["http://test.qznovelvod.com/movie", "https://test.qznovelvod.com.evil.example/movie", "https://user:pass@test.qznovelvod.com/movie", "https://test.qznovelvod.com:8443/movie"] {
        guard !MediaRangeHTTP.allowed(URL(string: invalid)!) else { throw MediaError.invalidMedia }
    }
    for invalid in ["bytes 0-100/*", "bytes 0-100/50", "bytes -1-50/100", "bytes 0-2/9999999999999999999999999999"] {
        guard MediaRangeHTTP.contentRange(invalid) == nil else { throw MediaError.invalidMedia }
    }
    print("PASS production HTTP ranges: exact 206/body/total, ignored Range rejected, malformed/short/oversized data, cancellation, URL policy")

    let cache = ProgressiveCache(root: root, limit: 700)
    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64), c = String(repeating: "c", count: 64)
    let bytes = Data(repeating: 8, count: 256)
    await cache.acquire(a)
    try await cache.store(bytes, key: a, block: 0)
    try await cache.clear()
    guard await cache.read(key: a, block: 0, expected: 256) == bytes else { throw MediaError.invalidMedia }
    try await cache.store(bytes, key: b, block: 0)
    try await cache.store(bytes, key: c, block: 0)
    guard await cache.read(key: a, block: 0, expected: 256) == bytes,
          await cache.read(key: b, block: 0, expected: 256) == nil else { throw MediaError.invalidMedia }
    let corrupt = root.appendingPathComponent(c).appendingPathComponent("0.chunk")
    var envelope = try Data(contentsOf: corrupt); envelope[40] ^= 1; try envelope.write(to: corrupt)
    guard await cache.read(key: c, block: 0, expected: 256) == nil,
          !FileManager.default.fileExists(atPath: corrupt.path) else { throw MediaError.invalidMedia }
    await cache.release(a); try await cache.clear()
    guard await cache.read(key: a, block: 0, expected: 256) == nil else { throw MediaError.invalidMedia }
    print("PASS cache hash corruption rejection, active leases, eviction quota and clear")
}

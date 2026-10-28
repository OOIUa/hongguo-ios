// SPDX-License-Identifier: GPL-3.0-only
// Offline updater trust, schema, comparison, and file-integrity rules. No networking.
import Foundation
import CryptoKit

@main struct UpdateRulesProbe {
    static func main() async throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "UpdateRulesProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "FAIL: " + label]) }
            count += 1
        }
        let asset = "https://github.com/OOIUa/hongguo-ios/releases/download/v0.2.0/Hongguo-iOS-0.2.0-unsigned.ipa"
        let base: [String: Any] = ["version":"0.2.0", "build":2, "minimumOSVersion":"17.0", "releaseNotes":["更新检查与安装包校验"],
            "publishedAt":"2026-10-28T10:00:00Z", "downloadURL":asset, "sha256":String(repeating: "a", count: 64), "size":4,
            "mirrors":["gh-proxy":"https://gh-proxy.com/" + asset, "ghfast":"https://ghfast.top/" + asset]]
        func decode(_ changes: [String: Any] = [:]) throws -> UpdateManifest {
            try UpdateRules.decode(JSONSerialization.data(withJSONObject: base.merging(changes) { _, replacement in replacement }))
        }
        func rejected(_ changes: [String: Any], _ label: String) throws {
            do { _ = try decode(changes) } catch { count += 1; return }
            throw NSError(domain: "UpdateRulesProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "FAIL: accepted " + label])
        }
        let manifest = try decode()
        try check(manifest.build == 2 && manifest.version == "0.2.0", "valid manifest")
        try check(UpdateRules.compareVersions("1.10.0", "1.9.9") == .orderedDescending, "numeric version components")
        try check(UpdateRules.compareVersions("1.2", "1.2.0.0") == .orderedSame, "zero-padded components")
        try check(UpdateRules.isNewer(version:"1.2.0",build:3,currentVersion:"1.2",currentBuild:2), "same version newer build")
        try check(!UpdateRules.isNewer(version:"1.1",build:999,currentVersion:"1.2",currentBuild:1), "older version higher build")
        try check(!UpdateRules.isNewer(version:"1.2",build:2,currentVersion:"1.2",currentBuild:2), "equal build")
        try check(UpdateRules.supports("17.0", systemVersion:"17.0.1"), "compatible OS")
        try check(!UpdateRules.supports("18.0", systemVersion:"17.9"), "incompatible OS")
        for invalid in ["", "1..2", "-1.2", "1.2-beta", "1.2.3.4.5", "1.99999999999999999999999"] {
            try check(UpdateRules.versionParts(invalid) == nil, "reject invalid version")
        }
        try rejected(["build":true], "boolean build")
        try rejected(["build":0], "zero build")
        try rejected(["size":0], "empty IPA")
        try rejected(["size":UpdateRules.maximumIPABytes + 1], "oversized IPA")
        try rejected(["sha256":String(repeating:"g",count:64)], "invalid SHA characters")
        try rejected(["sha256":"abc"], "short SHA")
        try rejected(["publishedAt":"yesterday"], "invalid publication date")
        try rejected(["minimumOSVersion":"unknown"], "invalid minimum OS")
        try rejected(["releaseNotes":[String(repeating:"x",count:1201)]], "oversized notes")
        for bad in [asset.replacingOccurrences(of:"https:",with:"http:"), asset.replacingOccurrences(of:"github.com",with:"github.com.evil.example"),
            asset.replacingOccurrences(of:"OOIUa",with:"someone-else"), asset.replacingOccurrences(of:"hongguo-ios",with:"hongguo-android"),
            asset.replacingOccurrences(of:"https://",with:"https://user:password@"), asset + "#fragment", asset + "?download=1",
            asset.replacingOccurrences(of:"github.com/",with:"github.com:8443/"), asset.replacingOccurrences(of:"v0.2.0/",with:"%2e%2e/"),
            asset.replacingOccurrences(of:".ipa",with:".zip")] {
            try rejected(["downloadURL":bad], "untrusted release asset")
        }
        try rejected(["mirrors":["gh-proxy":"https://gh-proxy.com/" + asset.replacingOccurrences(of:"v0.2.0",with:"v0.1.0")]], "mirror asset mismatch")
        try rejected(["mirrors":["other":"https://example.com/file.ipa"]], "unknown proxy")
        try rejected(["mirrors":["ghfast":"https://ghfast.top.evil.example/" + asset]], "proxy host lookalike")
        try check(manifest.assetURL(for:.ghProxy).absoluteString == "https://gh-proxy.com/" + asset, "gh-proxy asset route")
        try check(manifest.assetURL(for:.ghfast).absoluteString == "https://ghfast.top/" + asset, "ghfast asset route")
        try check(UpdateRoute.automatic.candidates == [.github,.ghProxy,.ghfast] && UpdateRoute.ghfast.candidates == [.ghfast], "fallback order and manual route")
        try check(UpdateRoute.ghProxy.sourceURL.absoluteString.hasSuffix("/distribution/source-cn.json"), "primary proxy source")
        try check(UpdateRoute.ghfast.sourceURL.absoluteString.hasSuffix("/distribution/source-cn-backup.json"), "backup proxy source")
        let official = URL(string:asset)!
        try check(UpdateRules.allowsAssetRedirect(URL(string:"https://release-assets.githubusercontent.com/signed-file?token=synthetic")!,initial:official,official:official), "GitHub signed CDN redirect")
        try check(!UpdateRules.allowsAssetRedirect(URL(string:"https://evil.example/file.ipa")!,initial:official,official:official), "external redirect")
        try check(!UpdateRules.allowsAssetRedirect(URL(string:"http://release-assets.githubusercontent.com/file")!,initial:official,official:official), "HTTP CDN redirect")
        try check(!UpdateRules.allowsAssetRedirect(URL(string:"https://release-assets.githubusercontent.com/file")!,initial:URL(string:"https://evil.example/start")!,official:official), "untrusted initial transfer")
        try check(UpdateRules.allowsManifestRedirect(UpdateRoute.github.manifestURL,initial:UpdateRoute.github.manifestURL), "exact manifest redirect")
        try check(!UpdateRules.allowsManifestRedirect(URL(string:"https://evil.example/update.json")!,initial:UpdateRoute.github.manifestURL), "manifest redirect blocked")
        try check(UpdateRules.hasZIPHeader(Data([0x50,0x4b,0x03,0x04,0])), "IPA ZIP header")
        try check(!UpdateRules.hasZIPHeader(Data("<html>".utf8)), "HTML response rejected")
        do { _ = try UpdateRules.decode(Data(repeating:32,count:UpdateRules.maximumManifestBytes + 1)); throw NSError(domain:"expected-too-large",code:3) }
        catch UpdateError.manifestTooLarge { count += 1 }
        try await transferChecks()
        print("PASS update rules: \(count) offline cases (versions/builds, schema/size/SHA, repo URLs, proxies, redirects and source URLs).")
    }
}


private final class UpdateProbeProtocol: URLProtocol {
    static var payload = Data()
    static var chunked = false
    static var pauseAfterFirstChunk = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let payload = Self.payload
        let headers = Self.chunked ? [:] : ["Content-Length":String(payload.count)]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.pauseAfterFirstChunk { client?.urlProtocol(self, didLoad: payload.prefix(64 * 1024)); return }
        for offset in stride(from: 0, to: payload.count, by: 4096) { client?.urlProtocol(self, didLoad: payload.subdata(in: offset..<min(offset+4096,payload.count))) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private func transferChecks() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-update-probe-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UpdateProbeProtocol.self]
    let official = URL(string:"https://github.com/OOIUa/hongguo-ios/releases/download/v0.2.0/test.ipa")!
    let payload = Data([0x50,0x4b,0x03,0x04]) + Data("synthetic test IPA bytes".utf8)
    let hash = SHA256.hash(data:payload).map { String(format:"%02x",$0) }.joined()
    UpdateProbeProtocol.payload = payload
    let valid = folder.appendingPathComponent("valid.ipa")
    let good = UpdateTransfer(address:official,target:.ipa(destination:valid,official:official,size:payload.count,sha256:hash),configuration:configuration)
    guard case .ipa(let file) = try await good.run(), try Data(contentsOf:file) == payload else { fatalError("Verified IPA transfer failed") }
    let wrongHash = folder.appendingPathComponent("wrong-hash.ipa")
    do { _ = try await UpdateTransfer(address:official,target:.ipa(destination:wrongHash,official:official,size:payload.count,sha256:String(repeating:"0",count:64)),configuration:configuration).run(); fatalError("Wrong digest accepted") }
    catch UpdateError.wrongDigest { precondition(!FileManager.default.fileExists(atPath:wrongHash.path)) }
    let wrongSize = folder.appendingPathComponent("wrong-size.ipa")
    do { _ = try await UpdateTransfer(address:official,target:.ipa(destination:wrongSize,official:official,size:payload.count+1,sha256:hash),configuration:configuration).run(); fatalError("Wrong size accepted") }
    catch UpdateError.wrongSize { precondition(!FileManager.default.fileExists(atPath:wrongSize.path)) }
    UpdateProbeProtocol.payload = Data(repeating:32,count:UpdateRules.maximumManifestBytes+1); UpdateProbeProtocol.chunked = true
    do { _ = try await UpdateTransfer(address:UpdateRules.manifestURL,target:.manifest,configuration:configuration).run(); fatalError("Oversized manifest accepted") }
    catch UpdateError.manifestTooLarge { }
    let cancelledFile = folder.appendingPathComponent("cancelled.ipa")
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await UpdateTransfer(address:official,target:.ipa(destination:cancelledFile,official:official,size:payload.count,sha256:hash),configuration:configuration).run()
    }
    do { _ = try await cancelled.value; fatalError("Cancelled download accepted") } catch is CancellationError { precondition(!FileManager.default.fileExists(atPath:cancelledFile.path)) }
    let inflightPayload = Data([0x50,0x4b,0x03,0x04]) + Data(repeating: 123, count: 128 * 1024)
    let inflightHash = SHA256.hash(data: inflightPayload).map { String(format:"%02x",$0) }.joined()
    UpdateProbeProtocol.payload = inflightPayload; UpdateProbeProtocol.chunked = false; UpdateProbeProtocol.pauseAfterFirstChunk = true
    let partial = folder.appendingPathComponent("inflight-cancel.ipa")
    let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let inflight = Task {
        try await UpdateTransfer(address:official,target:.ipa(destination:partial,official:official,size:inflightPayload.count,sha256:inflightHash),configuration:configuration) { received, _ in
            if received > 0 { signal.continuation.yield(()) }
        }.run()
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { for await _ in signal.stream { return }; throw NSError(domain:"update-cancel-signal",code:1) }
        group.addTask { try await Task.sleep(nanoseconds:5_000_000_000); throw NSError(domain:"update-cancel-timeout",code:1) }
        _ = try await group.next(); group.cancelAll()
    }
    precondition(FileManager.default.fileExists(atPath:partial.path), "Partial file was not written before cancellation")
    inflight.cancel(); signal.continuation.finish()
    do { _ = try await inflight.value; fatalError("In-flight cancellation accepted a file") }
    catch is CancellationError { precondition(!FileManager.default.fileExists(atPath:partial.path), "Cancelled partial file was retained") }
    UpdateProbeProtocol.pauseAfterFirstChunk = false
    print("PASS update transfer: 6 mocked offline cases (valid file, SHA mismatch cleanup, size mismatch cleanup, streaming manifest cap, preflight and in-flight cancellation cleanup).")
}

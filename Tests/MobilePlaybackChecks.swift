// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import JavaScriptCore

func checkMobilePlayback(context: JSContext, root: URL) async throws {
    try await checkPlaybackHTTPResponses()
    context.evaluateScript(try String(contentsOf: root.appendingPathComponent("Sources/Networking/PlayerSignV5.js"), encoding: .utf8))
    precondition(context.exception == nil, "v5 runtime initialization")
    for kind in ["carrier", "f13"] {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/signing-v5-\(kind).json"))) as! [[String: Any]]
        for row in rows {
            let args: [Any] = [kind, row["key"] ?? row["query"]!, row["source"] ?? row["body"]!, row["iv"] ?? "", row["ts"]!]
            let actual = context.objectForKeyedSubscript("hgV5Fixture")!.call(withArguments: args)!.toString()!
            precondition(context.exception == nil)
            precondition(kind == "carrier" ? actual == row["encrypted"] as! String : String(actual.prefix(32)) == row["digest"] as! String, "Independent v5 vector mismatch")
        }
    }
    let identity = RegisteredIdentity(deviceID: "1234567890123456789", installID: "9876543210987654321", cdid: "synthetic", appDeviceCookie: "never-forward")
    let device = DramaAPI.mobileDevice(identity), body = try DramaAPI.mobileBody(episodeID: "1234")
    precondition(body.starts(with: [31,139]), "Model request must be gzip")
    let signer = ProtocolSigner(resourceDirectory: root.appendingPathComponent("Sources/Networking"))
    let signed = try await signer.signedPlaybackV5(baseURL: "https://example.test/model", query: device.keys.sorted().map { [$0, device[$0]!] }, body: body, device: device, now: 1_800_000_000_000)
    let values = URLComponents(url: signed.url, resolvingAgainstBaseURL: false)!.queryItems!
    precondition(values.first { $0.name == "device_id" }?.value == identity.deviceID)
    precondition(values.first { $0.name == "iid" }?.value == identity.installID)
    precondition(values.first { $0.name == "ts" } == nil)
    precondition(signed.headers["x-khronos"] == "1800000000" && signed.headers["x-medusa"] != nil && signed.headers["x-helios"] != nil)
    precondition(signed.headers["x-ss-stub"] == HGCrypto.md5(body).hexString.uppercased())
    precondition(signed.headers["Cookie"] == nil && signed.headers["x-argus"] == nil && signed.headers["x-ladon"] == nil)
    let model: [String: Any] = ["video_list":[["main_url":"https://example.test/video", "codec_type":"h264"]]]
    for entries: [String: Any] in [["1234":["video_model":model]], ["1004":["1234":["video_model":model]]]] {
        let bytes = try ProtocolJSON.data(["code":0,"data":entries])
        let exact = try DramaAPI.mobileVideoModel(bytes, episodeID: "1234")
        let unrelated = try DramaAPI.mobileVideoModel(bytes, episodeID: "5678")
        precondition(exact != nil && unrelated == nil)
    }
    do { _ = try DramaAPI.mobileVideoModel(Data(#"{"code":101144}"#.utf8), episodeID: "1234"); preconditionFailure("Business refusal accepted") }
    catch is DramaAPI.PlaybackRefusal { }
    do { _ = try DramaAPI.mobileVideoModel(Data(repeating: 0, count: 2 * 1024 * 1024 + 1), episodeID: "1234"); preconditionFailure("Oversized model accepted") }
    catch is HGError { }
    print("PASS mobile v5: 32 independent digest vectors, 4 carriers, exact gzip/identity binding, both model maps, refusal and size limits")
}

private func checkPlaybackHTTPResponses() async throws {
    let url = URL(string: "https://example.test/episodes/2?quality=hd")!
    var request = URLRequest(url: url, timeoutInterval: 1)
    request.httpShouldHandleCookies = false
    request.setValue("episode-2", forHTTPHeaderField: "X-Request-ID")
    let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
    let payload = Data("second episode".utf8)

    for code in [URLError.Code.cannotConnectToHost, .networkConnectionLost] {
        var calls = 0
        let recovered = try await DramaAPI.responseData(for: request, playback: true) { attempt in
            calls += 1
            precondition(attempt.url == request.url && attempt.httpMethod == "GET" && attempt.httpBody == nil)
            precondition(attempt.allHTTPHeaderFields == request.allHTTPHeaderFields && !attempt.httpShouldHandleCookies)
            if calls == 1 { throw URLError(code) }
            precondition(attempt.timeoutInterval > 0 && attempt.timeoutInterval <= request.timeoutInterval)
            return (payload, ok)
        }
        precondition(recovered == payload && calls == 2)
    }

    func expectTransportFailure(_ attempt: URLRequest, playback: Bool, code: URLError.Code,
                                expectedCalls: Int, delay: UInt64 = 0, retryDeadline: TimeInterval? = nil,
                                expectedCode: URLError.Code? = nil) async throws {
        var calls = 0
        do {
            _ = try await DramaAPI.$playbackDeadline.withValue(retryDeadline) {
                try await DramaAPI.responseData(for: attempt, playback: playback) { _ in
                    calls += 1
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    throw URLError(code)
                }
            }
            preconditionFailure("Transport failure accepted")
        } catch is CancellationError { precondition(code == .cancelled && calls == expectedCalls) }
        catch let error as URLError { precondition(error.code == (expectedCode ?? code) && calls == expectedCalls) }
    }
    try await expectTransportFailure(request, playback: true, code: .cannotConnectToHost, expectedCalls: 2)
    try await expectTransportFailure(request, playback: true, code: .cannotDecodeRawData, expectedCalls: 1)
    try await expectTransportFailure(request, playback: true, code: .cancelled, expectedCalls: 1)
    try await expectTransportFailure(request, playback: true, code: .timedOut, expectedCalls: 1)
    try await expectTransportFailure(request, playback: false, code: .networkConnectionLost, expectedCalls: 1)
    var post = request
    post.httpMethod = "POST"
    post.httpBody = payload
    try await expectTransportFailure(post, playback: true, code: .networkConnectionLost, expectedCalls: 1)
    var expiring = request
    expiring.timeoutInterval = 0.001
    try await expectTransportFailure(expiring, playback: true, code: .cannotConnectToHost,
                                     expectedCalls: 1, delay: 10_000_000, expectedCode: .timedOut)
    // The episode lookup can run out of time while the individual GET still has most of its second left.
    try await expectTransportFailure(request, playback: true, code: .cannotConnectToHost, expectedCalls: 1,
                                     delay: 10_000_000, retryDeadline: ProcessInfo.processInfo.systemUptime + 0.001,
                                     expectedCode: .timedOut)

    for initial in [request, post] {
        _ = try await DramaAPI.withPlaybackBudget(0.25) {
            try await DramaAPI.responseData(for: initial, playback: true) { attempt in
                precondition(attempt.timeoutInterval > 0 && attempt.timeoutInterval <= 0.25)
                return (payload, ok)
            }
        }
        try await expectTransportFailure(initial, playback: true, code: .timedOut, expectedCalls: 0,
                                         retryDeadline: ProcessInfo.processInfo.systemUptime - 1)
    }
    // The request can stay active longer than its timeout interval when data arrives in small chunks.
    do {
        try await DramaAPI.withPlaybackBudget(0.03) {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { precondition(Task.isCancelled); throw error }
            preconditionFailure("The active request outlived the episode deadline")
        } as Void
        preconditionFailure("A late response was accepted")
    } catch let error as URLError { precondition(error.code == .timedOut) }

    let cancelled = Task {
        var calls = 0
        do {
            _ = try await DramaAPI.responseData(for: request, playback: true) { _ in
                calls += 1
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.networkConnectionLost)
            }
            preconditionFailure("Cancelled GET continued")
        } catch is CancellationError { precondition(calls == 1) }
    }
    try await cancelled.value

    for (status, headers) in [(200, ["Retry-After": "5"]), (503, ["Retry-After": "5"]),
                              (502, ["Retry-After": "5"]), (401, [:]), (403, [:]), (429, [:])] {
        let reply = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        var calls = 0
        do {
            _ = try await DramaAPI.responseData(for: request, playback: true) { _ in calls += 1; return (payload, reply) }
            preconditionFailure("Server backoff or refusal accepted")
        } catch is DramaAPI.PlaybackRefusal { precondition(calls == 1) }
    }
    let gzip = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                               headerFields: ["Content-Length": "0", "Content-Encoding": "gzip"])!
    let empty = try await DramaAPI.responseData(for: request, playback: true) { _ in (Data(), gzip) }
    precondition(empty.isEmpty)
    print("PASS playback HTTP: bounded same-request GET retry, cancellation, timeout, gzip, server backoff and POST protection")
}

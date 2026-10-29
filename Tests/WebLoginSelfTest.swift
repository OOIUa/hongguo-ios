// SPDX-License-Identifier: GPL-3.0-only
// Offline only: mirrors hongguo-android AccountProtocolTest WebLogin cases with a scripted URLProtocol.
import Foundation

final class ScriptedProtocol: URLProtocol {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var body = "" }
    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [String] = []
    static func reset(_ next: [Reply]) { replies = next; requests = []; bodies = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        Self.bodies.append(String(decoding: body, as: UTF8.self))
        guard !Self.replies.isEmpty else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let reply = Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct WebLoginSelfTest {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw HGError.message("FAIL " + name) }
    }
    static func fails(_ name: String, containing text: String = "", _ body: () async throws -> Void) async throws {
        do { try await body() } catch { try check(text.isEmpty || error.localizedDescription.contains(text), name + " message: " + error.localizedDescription); return }
        throw HGError.message("FAIL " + name + " did not throw")
    }
    static let base = URL(string: "https://login.test/")!
    static func json(_ body: String, _ headers: [String: String] = [:]) -> ScriptedProtocol.Reply {
        ScriptedProtocol.Reply(headers: headers.merging(["Content-Type": "application/json"]) { $1 }, body: body)
    }
    static let qr = json(#"{"message":"success","data":{"token":"offline-qr","qrcode":"data:image/png;base64,aW1hZ2U=","expire_time":180}}"#,
                         ["Set-Cookie": "passport_csrf_token=offline-csrf; Path=/; HttpOnly"])
    @MainActor static func login() -> WebLogin {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        return WebLogin(base: base, configuration: configuration)
    }

    @MainActor static func main() async throws {
        var cases = 0
        func pass() { cases += 1 }

        // Rules
        let mainland = try WebLoginRules.phone("138 0013-8000"); try check(mainland == "+86 13800138000", "mainland-phone"); pass()
        let international = try WebLoginRules.phone("+852 9123 4567"); try check(international == "+852 91234567", "international-phone"); pass()
        try await fails("short-phone-rejected", containing: "有效手机号") { _ = try WebLoginRules.phone("12345") }; pass()
        try check(WebLoginRules.masked("+86 13800138000") == "138****8000", "masked-phone"); pass()
        try check(WebLoginRules.mix("+86 1") == "2e3d332534", "mix-hex"); pass()
        try check(WebLoginRules.mix("\u{5}") == "0", "mix-unpadded-like-kotlin"); pass()
        try check(WebLoginRules.failure(code: 1102, needsVerification: false).contains("验证码有误"), "code-1102"); pass()
        try check(WebLoginRules.failure(code: 1003, needsVerification: false).contains("会话已失效"), "code-1003"); pass()
        try check(WebLoginRules.failure(code: 1, needsVerification: true).contains("滑块验证"), "verify-center"); pass()
        try check(WebLoginRules.qrLifetime(nil) == 180 && WebLoginRules.qrLifetime(9999) == 600, "qr-lifetime-clamped"); pass()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try check(WebLoginRules.qrLifetime(1_800_000_120, now: now) == 120, "qr-lifetime-timestamp"); pass()
        let unpadded = try WebLoginRules.qrImage("aW1hZ2U"); try check(unpadded == Data("image".utf8), "qr-unpadded-base64"); pass()
        try await fails("qr-too-large", containing: "过大") { _ = try WebLoginRules.qrImage(String(repeating: "A", count: WebLoginRules.maximumQRCharacters + 1)) }; pass()
        try check(WebLoginRules.qrStatus(["status": "3", "redirect_url": "/x"]) == .confirmed(redirect: "/x"), "status-confirmed"); pass()
        try check(WebLoginRules.qrStatus(["status": "expired"]) == .expired && WebLoginRules.qrStatus(["status": "1"]) == .waiting, "status-other"); pass()

        // QR completes a same-origin redirect and validates the website session before exposing cookies.
        ScriptedProtocol.reset([qr,
            json(#"{"message":"success","data":{"status":"3","redirect_url":"/auth/complete"}}"#),
            ScriptedProtocol.Reply(body: "ok").with(["Set-Cookie": "sessionid=offline-test; Path=/; HttpOnly"]),
            json(#"{"message":"success","has_login":true,"data":{"user":{"nickname":"官网测试"}}}"#)])
        var session = login()
        let image = try await session.qr().image; try check(image == Data("image".utf8), "qr-image"); pass()
        let confirmed = try await session.poll(); try check(confirmed, "qr-confirmed"); pass()
        let cookie = try await session.credentials()
        try check(cookie.contains("sessionid=offline-test"), "qr-cookie"); pass()
        let paths = ScriptedProtocol.requests.map { $0.url!.path }
        try check(paths == ["/passport/web/get_qrcode", "/passport/web/check_qrconnect", "/auth/complete", "/passport/account/info/v2"], "qr-request-order \(paths)"); pass()
        let infoRequest = ScriptedProtocol.requests[3]
        try check(infoRequest.value(forHTTPHeaderField: "x-tt-passport-csrf-token") == "offline-csrf", "csrf-header"); pass()
        try check(infoRequest.value(forHTTPHeaderField: "Cookie")?.contains("sessionid=offline-test") == true, "session-cookie-sent"); pass()

        // A cross-origin confirmation redirect is refused before anything is sent there.
        ScriptedProtocol.reset([qr, json(#"{"message":"success","data":{"status":"confirmed","redirect_url":"https://elsewhere.test/steal"}}"#)])
        session = login()
        _ = try await session.qr()
        try await fails("cross-origin-redirect", containing: "不支持") { _ = try await session.poll() }; pass()
        try check(!ScriptedProtocol.requests.contains { $0.url?.host == "elsewhere.test" }, "no-cross-origin-request"); pass()

        // SMS reuses the CSRF session, never replays a submitted code, and hides raw provider text.
        ScriptedProtocol.reset([qr, json(#"{"message":"success","data":{"retry_time":60}}"#),
            json(#"{"message":"error","data":{"error_code":1102,"description":"provider-raw-secret"}}"#)])
        session = login()
        let sent = try await session.send("13800138000"); try check(sent.masked == "138****8000", "sms-masked"); pass()
        try await fails("sms-wrong-code", containing: "验证码有误") { _ = try await session.verify("123456") }; pass()
        try await fails("sms-no-replay", containing: "重新获取验证码") { _ = try await session.verify("123456") }; pass()
        try await fails("sms-cooldown", containing: "冷却") { _ = try await session.send("13800138000") }; pass()
        try check(ScriptedProtocol.requests.count == 3, "sms-request-count"); pass()
        try check(ScriptedProtocol.requests[1].httpMethod == "POST" && ScriptedProtocol.bodies[1].contains("mobile=\(WebLoginRules.mix("+86 13800138000"))"), "sms-form"); pass()
        try check(ScriptedProtocol.requests[1].value(forHTTPHeaderField: "x-tt-passport-csrf-token") == "offline-csrf", "sms-csrf"); pass()
        try check(ScriptedProtocol.requests[2].url!.path == "/passport/web/sms_login", "sms-login-path"); pass()

        // Expired SMS session surfaces an actionable message without raw text.
        ScriptedProtocol.reset([qr, json(#"{"message":"error","data":{"error_code":1003,"description":"raw-secret"}}"#)])
        session = login()
        try await fails("sms-expired", containing: "会话已失效") { _ = try await session.send("13800138000") }; pass()

        print("PASS web login: \(cases) offline cases (phone rules, mix encoding, error codes, QR decode/expiry, redirects, CSRF, one-shot SMS codes)")
    }
}

private extension ScriptedProtocol.Reply {
    func with(_ headers: [String: String]) -> Self { var copy = self; copy.headers.merge(headers) { $1 }; return copy }
}

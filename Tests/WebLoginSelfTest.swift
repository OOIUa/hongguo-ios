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
        try check(WebLoginRules.failure(code: 1, needsVerification: true).contains("官网"), "verify-center-points-to-website"); pass()
        try check(WebLoginRules.phoneDigits("+86 138-0013-8000") == "13800138000" && WebLoginRules.phoneDigits("138001380009") == "13800138000" && WebLoginRules.phoneDigits("86") == "86", "phone-digits"); pass()
        try check(WebLoginRules.validMainlandPhone("13800138000") && !WebLoginRules.validMainlandPhone("12800138000"), "valid-phone"); pass()
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
            json(#"{"message":"error","data":{"error_code":1102,"description":"provider-raw-secret"}}"#),
            json(#"{"message":"error","data":{"error_code":1103}}"#)])
        session = login()
        let sent = try await session.send("13800138000"); try check(sent.masked == "138****8000", "sms-masked"); pass()
        try await fails("sms-wrong-code", containing: "验证码有误") { _ = try await session.verify("123456") }; pass()
        try await fails("sms-same-code-not-replayed", containing: "已提交过") { _ = try await session.verify("123456") }; pass()
        try await fails("sms-other-code-once", containing: "已失效") { _ = try await session.verify("654321") }; pass()
        try await fails("sms-ended-session", containing: "重新获取验证码") { _ = try await session.verify("111111") }; pass()
        try await fails("sms-cooldown", containing: "冷却") { _ = try await session.send("13800138000") }; pass()
        try check(ScriptedProtocol.requests.count == 4, "sms-request-count"); pass()
        try check(ScriptedProtocol.requests[1].httpMethod == "POST" && ScriptedProtocol.bodies[1].contains("mobile=\(WebLoginRules.mix("+86 13800138000"))"), "sms-form"); pass()
        try check(ScriptedProtocol.requests[1].value(forHTTPHeaderField: "x-tt-passport-csrf-token") == "offline-csrf", "sms-csrf"); pass()
        try check(ScriptedProtocol.requests[2].url!.path == "/passport/web/sms_login", "sms-login-path"); pass()

        // Expired SMS session surfaces an actionable message without raw text.
        ScriptedProtocol.reset([qr, json(#"{"message":"error","data":{"error_code":1003,"description":"raw-secret"}}"#)])
        session = login()
        try await fails("sms-expired", containing: "会话已失效") { _ = try await session.send("13800138000") }; pass()

        // App passport SMS channel.
        func appLogin() -> AppPhoneLogin {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ScriptedProtocol.self]
            return AppPhoneLogin(base: URL(string: "https://passport.test/")!, profile: ["device_type": "OfflinePhone"], configuration: configuration) { base, query, body, device in
                precondition(device["device_id"] == AppPhoneLogin.deviceID && device["iid"] == AppPhoneLogin.installID && device["version_code"] == "73932")
                var components = URLComponents(string: base)!
                components.queryItems = query.map { URLQueryItem(name: $0[0], value: $0[1]) }
                return (components.url!, ["x-gorgon": "signed"])
            }
        }
        let codeSent = json(#"{"message":"success","data":{"mobile":"138******00","retry_time":45,"mobile_ticket":"tk1"}}"#, ["Set-Cookie": "passport_csrf_token=x; Path=/"])
        let error = { (code: Int) in json("{\"message\":\"error\",\"data\":{\"error_code\":\(code),\"description\":\"raw-secret\"}}") }
        ScriptedProtocol.reset([codeSent, json(#"{"message":"success","data":{}}"#, ["Set-Cookie": "sessionid=abc; Path=/"])])
        var phone = appLogin()
        let phoneSent = try await phone.send("138 0013-8000")
        try check(phoneSent.masked == "138****8000" && phoneSent.retry == 45, "passport-sent"); pass()
        let sendItems = URLComponents(url: ScriptedProtocol.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        func item(_ items: [URLQueryItem], _ name: String) -> String? { items.first { $0.name == name }?.value }
        try check(ScriptedProtocol.requests[0].httpMethod == "GET" && ScriptedProtocol.requests[0].url!.path == "/passport/mobile/send_code/v1", "passport-send-path"); pass()
        try check(item(sendItems, "mobile") == "13800138000" && item(sendItems, "type") == "24", "passport-mainland-number"); pass()
        try check(item(sendItems, "device_id") == nil && item(sendItems, "iid") == nil, "passport-no-device-in-query"); pass()
        try await fails("passport-cooldown", containing: "冷却") { _ = try await phone.send("13800138000") }; pass()
        let phoneCredentials = try await phone.verify("123456")
        try check(phoneCredentials.cookie.contains("sessionid=abc") && phoneCredentials.deviceID == AppPhoneLogin.deviceID && phoneCredentials.installID == AppPhoneLogin.installID, "passport-credentials"); pass()
        try check(ScriptedProtocol.requests.count == 2 && ScriptedProtocol.requests[1].httpMethod == "POST" && ScriptedProtocol.requests[1].url!.path == "/passport/mobile/sms_login", "passport-first-endpoint"); pass()
        try check(ScriptedProtocol.bodies[1].contains("code=123456") && ScriptedProtocol.bodies[1].contains("mobile_ticket=tk1"), "passport-form"); pass()
        try check(ScriptedProtocol.requests[1].value(forHTTPHeaderField: "Cookie") == nil, "passport-no-cookie-replay"); pass()
        try check(ScriptedProtocol.requests[1].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/x-www-form-urlencoded") == true, "passport-form-type"); pass()
        // A slider request points to the official page and never shows raw provider text.
        ScriptedProtocol.reset([json(#"{"message":"error","data":{"error_code":1105,"verify_center_decision_conf":"{}","description":"raw-secret"}}"#)])
        phone = appLogin()
        do { _ = try await phone.send("13800138000"); throw HGError.message("slider-not-reported") }
        catch let failure as WebLoginFailure { try check(failure.needsWebsite && !failure.canRetryCode && failure.message.contains("滑块") && !failure.message.contains("raw-secret"), "passport-slider"); pass() }
        ScriptedProtocol.reset([json(#"{"message":"error","data":{"error_code":1101,"captcha":"image-data"}}"#)])
        phone = appLogin()
        do { _ = try await phone.send("13800138000"); throw HGError.message("captcha-not-reported") }
        catch let failure as WebLoginFailure { try check(failure.needsWebsite && !failure.message.contains("image-data"), "passport-captcha"); pass() }
        // error_code 1 moves on with the latest ticket; all endpoints expired ends the attempt.
        ScriptedProtocol.reset([codeSent, json(#"{"message":"error","data":{"error_code":1,"mobile_ticket":"tk2"}}"#), json(#"{"message":"success","data":{}}"#, ["Set-Cookie": "sessionid=abc; Path=/"])])
        phone = appLogin(); _ = try await phone.send("13800138000"); _ = try await phone.verify("123456")
        try check(ScriptedProtocol.requests[2].url!.path == "/passport/mobile/sms_login_only" && ScriptedProtocol.bodies[2].contains("mobile_ticket=tk2"), "passport-next-endpoint-latest-ticket"); pass()
        ScriptedProtocol.reset([codeSent, error(1), error(1), error(1), error(1), error(1)])
        phone = appLogin(); _ = try await phone.send("13800138000")
        try await fails("passport-all-expired", containing: "会话已失效") { _ = try await phone.verify("123456") }; pass()
        try check(ScriptedProtocol.requests.count == 6, "passport-five-endpoints"); pass()
        try await fails("passport-attempt-ended", containing: "重新获取") { _ = try await phone.verify("654321") }; pass()
        // A wrong code stops at once, allows only a different code; 1203 ends the attempt.
        ScriptedProtocol.reset([codeSent, error(1202), json(#"{"message":"success","data":{}}"#, ["Set-Cookie": "sessionid=abc; Path=/"])])
        phone = appLogin(); _ = try await phone.send("13800138000")
        try await fails("passport-wrong-code", containing: "验证码有误") { _ = try await phone.verify("123456") }; pass()
        try check(ScriptedProtocol.requests.count == 2, "passport-wrong-code-stops"); pass()
        try await fails("passport-same-code", containing: "已提交过") { _ = try await phone.verify("123456") }; pass()
        _ = try await phone.verify("654321"); pass()
        ScriptedProtocol.reset([codeSent, error(1203)])
        phone = appLogin(); _ = try await phone.send("13800138000")
        try await fails("passport-too-many", containing: "错误次数过多") { _ = try await phone.verify("123456") }; pass()
        try await fails("passport-too-many-ended", containing: "重新获取") { _ = try await phone.verify("654321") }; pass()
        // A redirect carrying the code is not followed.
        ScriptedProtocol.reset([codeSent, ScriptedProtocol.Reply(status: 302, headers: ["Location": "https://elsewhere.test/steal"], body: "")])
        phone = appLogin(); _ = try await phone.send("13800138000")
        try await fails("passport-redirect", containing: "HTTP 302") { _ = try await phone.verify("123456") }; pass()
        try check(!ScriptedProtocol.requests.contains { $0.url?.host == "elsewhere.test" }, "passport-no-redirect-request"); pass()

        print("PASS web login: \(cases) offline cases (phone rules, mix encoding, error codes, QR decode/expiry, redirects, CSRF, one-shot SMS codes, App passport channel)")
    }
}

private extension ScriptedProtocol.Reply {
    func with(_ headers: [String: String]) -> Self { var copy = self; copy.headers.merge(headers) { $1 }; return copy }
}

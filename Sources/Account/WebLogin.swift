// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android WebLogin.kt / PhoneLogin.kt (adapted from tsukiyo-zero/hongguoTV 34c7930).
import Foundation

/// Pure rules shared by QR and SMS login; kept separate so they run in offline tests.
enum WebLoginRules {
    static let maximumQRCharacters = 1024 * 1024

    /// Accepts mainland numbers or `+country number`; returns the official `+86 138…` form.
    static func phone(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "[()\\-]", with: "", options: .regularExpression)
        if value.hasPrefix("+") {
            let parts = value.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else { throw HGError.message("国际手机号请使用 +区号 手机号 格式") }
            return try format(country: String(parts[0]), number: String(parts[1]))
        }
        let number = value.filter { !$0.isWhitespace }
        guard number.range(of: "^1[3-9][0-9]{9}$", options: .regularExpression) != nil else { throw HGError.message("请输入有效手机号") }
        return try format(country: "86", number: number)
    }
    static func format(country: String, number: String) throws -> String {
        let code = country.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        let digits = number.filter { !$0.isWhitespace && $0 != "-" }
        guard code.range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil,
              digits.range(of: "^[0-9]{5,15}$", options: .regularExpression) != nil else { throw HGError.message("请输入有效手机号") }
        return "+\(code) \(digits)"
    }
    static func masked(_ mobile: String) -> String {
        let digits = mobile.split(separator: " ", maxSplits: 1).last.map(String.init) ?? ""
        return digits.count >= 7 ? String(digits.prefix(3)) + "****" + String(digits.suffix(4)) : "你的手机"
    }
    /// The website's `mix_mode` obfuscation: each UTF-8 byte XOR 5, as unpadded lowercase hex (matches Kotlin `toString(16)`).
    static func mix(_ value: String) -> String { value.utf8.map { String($0 ^ 5, radix: 16) }.joined() }

    static func failure(code: Int, needsVerification: Bool) -> String {
        let message: String
        if needsVerification { message = "红果要求完成滑块验证，请改用扫码登录" }
        else {
            switch code {
            case 13, 1003: message = "登录会话已失效，请重新扫码或重新获取验证码"
            case 1102: message = "验证码有误，请重新获取后再试"
            case 1103, 1104: message = "验证码已失效，请重新获取后再试"
            case 1105: message = "红果要求额外验证，请改用扫码登录"
            case 1106, 1107: message = "请求过于频繁，请稍后再试"
            default: message = "官网登录失败，请稍后重试"
            }
        }
        return "\(message)（错误码 \(code)）"
    }
    static func qrImage(_ field: String) throws -> Data {
        let encoded = field.components(separatedBy: "base64,").last ?? ""
        guard encoded.count <= maximumQRCharacters else { throw HGError.message("登录二维码过大") }
        var normalized = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard normalized.count % 4 != 1 else { throw HGError.message("登录二维码格式无效") }
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        guard let image = Data(base64Encoded: normalized) else { throw HGError.message("登录二维码格式无效") }
        guard !image.isEmpty else { throw HGError.message("登录二维码为空") }
        return image
    }
    /// `expire_time` is either a lifetime in seconds or a Unix timestamp.
    static func qrLifetime(_ raw: Any?, now: Date = Date()) -> Int {
        let value = raw == nil ? 180 : Int64(ProtocolJSON.integer(raw))
        let seconds = value > 1_000_000_000 ? value - Int64(now.timeIntervalSince1970) : value
        return Int(min(max(seconds, 0), 600))
    }
    enum QRStatus: Equatable { case waiting, confirmed(redirect: String), expired }
    static func qrStatus(_ data: [String: Any]) -> QRStatus {
        switch ProtocolJSON.text(data["status"]) {
        case "5", "expired": return .expired
        case "3", "confirmed": return .confirmed(redirect: ProtocolJSON.text(data["redirect_url"]))
        default: return .waiting
        }
    }
}

/// One official-website authorization session (QR or SMS). Cookies stay in memory and never leave the website origin.
@MainActor
final class WebLogin {
    nonisolated static let base = URL(string: "https://hongguoduanju.com/")!
    private let base: URL
    private let session: URLSession
    private var cookies: [HTTPCookie] = []
    private var cancelled = false
    private var token = ""
    private var mobile = ""
    private var codeSent = false
    private var nextSMSAt = Date.distantPast

    init(base: URL = WebLogin.base, configuration: URLSessionConfiguration = .ephemeral) {
        self.base = base
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func cancel() { cancelled = true; codeSent = false; session.invalidateAndCancel() }

    // MARK: QR

    func qr() async throws -> (image: Data, lifetime: Int) {
        let data = try checked(await call("passport/web/get_qrcode/", params: ["next": base.absoluteString]))
        token = ProtocolJSON.text(data["token"])
        guard !token.isEmpty else { throw HGError.message("登录二维码信息缺失") }
        return (try WebLoginRules.qrImage(ProtocolJSON.text(data["qrcode"])), WebLoginRules.qrLifetime(data["expire_time"]))
    }
    /// True once the scan is confirmed and the website has issued a session.
    func poll() async throws -> Bool {
        guard !token.isEmpty else { throw HGError.message("请先获取二维码") }
        let data = try checked(await call("passport/web/check_qrconnect/", params: ["next": base.absoluteString, "token": token]))
        switch WebLoginRules.qrStatus(data) {
        case .expired: throw HGError.message("二维码已过期，请重新获取")
        case .waiting: return false
        case .confirmed(let redirect):
            if !redirect.isEmpty { try await finishRedirect(redirect) }
            return hasSession
        }
    }
    private func finishRedirect(_ value: String) async throws {
        guard var url = URL(string: value, relativeTo: base)?.absoluteURL else { throw HGError.message("登录确认地址无效") }
        for _ in 0..<5 {
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
            guard let next = try await execute(request).redirect else { return }
            url = next
        }
        throw HGError.message("登录确认跳转次数过多")
    }

    // MARK: SMS

    func send(_ number: String) async throws -> (masked: String, retry: Int) {
        guard Date() >= nextSMSAt else { throw HGError.message("请等待短信冷却后再试") }
        mobile = try WebLoginRules.phone(number)
        codeSent = false
        if !cookies.contains(where: { $0.name == "passport_csrf_token" && live($0) }) { _ = try await qr() }
        let data = try checked(await call("passport/web/send_code/", form: ["mobile": WebLoginRules.mix(mobile), "type": WebLoginRules.mix("24"), "mix_mode": "1", "fixed_mix_mode": "1"]))
        let retry = min(max(ProtocolJSON.integer(data["retry_time"]) == 0 ? 60 : ProtocolJSON.integer(data["retry_time"]), 1), 3600)
        nextSMSAt = Date().addingTimeInterval(TimeInterval(retry))
        codeSent = true
        return (WebLoginRules.masked(mobile), retry)
    }
    func verify(_ code: String) async throws -> String {
        guard codeSent else { throw HGError.message("请先重新获取验证码") }
        guard code.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil else { throw HGError.message("请输入 4—8 位验证码") }
        // A submitted code is consumed locally even if the response is lost. Never replay it automatically.
        codeSent = false
        _ = try checked(await call("passport/web/sms_login/", form: ["mobile": WebLoginRules.mix(mobile), "code": WebLoginRules.mix(code), "login_only": "true", "mix_mode": "1", "fixed_mix_mode": "1"]))
        return try await credentials()
    }

    // MARK: Session

    /// Confirms the website session before handing out the cookie header.
    func credentials() async throws -> String {
        guard hasSession else { throw HGError.message("官网尚未下发登录态，请先在手机确认登录") }
        let reply = try await call("passport/account/info/v2/")
        if ProtocolJSON.text(reply["message"]) != "success" { _ = try checked(reply) }
        guard AccountRules.websiteAuthenticated(reply) else { throw HGError.message("官网尚未确认登录，请重新扫码或获取验证码") }
        return header(for: base)
    }

    private var hasSession: Bool { cookies.contains { ["sessionid", "sessionid_ss"].contains($0.name) && !$0.value.isEmpty && matches($0, base) } }
    private func live(_ cookie: HTTPCookie) -> Bool { cookie.expiresDate.map { $0 > Date() } ?? true }
    private func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard live(cookie), let host = url.host else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return AccountRules.domainMatches(cookieDomain: cookie.domain, targetHost: host) && path.hasPrefix(cookie.path)
    }
    private func header(for url: URL) -> String { cookies.filter { matches($0, url) }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
    private func sameOrigin(_ url: URL) -> Bool { url.scheme == base.scheme && url.host == base.host && url.port == base.port }

    private func call(_ path: String, form: [String: String]? = nil, params: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let common = ["aid": "513755", "passport_jssdk_version": "3.4.10", "passport_jssdk_type": "normal",
                      "account_sdk_source": "web", "is_from_ttaccountsdk": "1", "language": "zh"]
        components.queryItems = common.merging(params) { $1 }.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(base.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(String(base.absoluteString.dropLast(base.absoluteString.hasSuffix("/") ? 1 : 0)), forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        let pairs = cookies.filter { matches($0, components.url!) }.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        if let csrf = pairs["passport_csrf_token"] ?? pairs["passport_csrf_token_default"] { request.setValue(csrf, forHTTPHeaderField: "x-tt-passport-csrf-token") }
        if let form {
            var body = URLComponents(); body.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)
        }
        let result = try await execute(request)
        guard result.redirect == nil else { throw HGError.message("登录接口返回了意外跳转") }
        return try ProtocolJSON.object(result.body)
    }
    private func execute(_ original: URLRequest) async throws -> (body: Data, redirect: URL?) {
        guard !cancelled else { throw CancellationError() }
        guard let url = original.url, sameOrigin(url) else { throw HGError.message("不支持的登录地址") }
        var request = original
        request.httpShouldHandleCookies = false
        let cookie = header(for: url)
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (body, response) = try await session.data(for: request)
        guard !cancelled else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw HGError.message("官网登录返回格式异常") }
        store(http, for: url)
        if (300...399).contains(http.statusCode) {
            guard let location = http.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                throw HGError.message("登录确认地址无效")
            }
            guard sameOrigin(next) else { throw HGError.message("登录确认跳转到不支持的站点") }
            return (Data(), next)
        }
        guard (200...299).contains(http.statusCode) else { throw HGError.message("账号请求失败（HTTP \(http.statusCode)）") }
        guard body.count <= 2 * 1024 * 1024 else { throw HGError.message("账号接口响应过大") }
        return (body, nil)
    }
    private func store(_ response: HTTPURLResponse, for url: URL) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let key = item.key as? String, let value = item.value as? String { result[key] = value }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if live(cookie) { cookies.append(cookie) }
        }
    }
    private func checked(_ reply: [String: Any]) throws -> [String: Any] {
        guard let data = reply["data"] as? [String: Any] else { throw HGError.message("官网登录返回格式异常") }
        guard ProtocolJSON.text(reply["message"]) == "success" else {
            let code = data["error_code"] == nil ? -1 : ProtocolJSON.integer(data["error_code"])
            throw HGError.message(WebLoginRules.failure(code: code, needsVerification: data["verify_center_decision_conf"] != nil))
        }
        return data
    }

    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
}

/// Redirects are inspected by `WebLogin` so cookies are captured and cross-origin hops are refused.
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

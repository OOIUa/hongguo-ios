// SPDX-License-Identifier: GPL-3.0-only
// Adapted from hongguo-android PlaybackDevice.java; tsukiyo-zero/hongguoTV 3889318,
// jackotom/hongguo-drama 5febca2, sunnysky123/hongguo-web 79babdf.
import Foundation

struct RegisteredIdentity: Sendable, Equatable {
    let deviceID: String
    let installID: String
    let cdid: String
    let appDeviceCookie: String
    /// 注册响应下发的 `klink_egdi`（不透明设备标识）；官方播放 query 会带。可能为空。
    var egdi: String = ""
    var device: [String: String] {
        var profile = PlaybackRegistration.deviceProfile
        profile["device_id"] = deviceID; profile["iid"] = installID; profile["cdid"] = cdid
        return profile
    }
}

enum PlaybackRegistration {
    static let salt = Data(hex: "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!
    static let deviceProfile: [String: String] = [
        "ac":"wifi", "channel":"update_64", "aid":"8662", "app_name":"novelread", "version_code":"71332",
        "version_name":"7.1.3.32", "device_platform":"android", "os":"android", "ssmix":"a", "device_type":"25053RT47C",
        "device_brand":"Redmi", "language":"zh", "os_api":"36", "os_version":"16", "manifest_version_code":"71332",
        "resolution":"1280*2772", "dpi":"520", "update_version_code":"71332", "host_abi":"arm64-v8a",
        "dragon_device_type":"phone", "pv_player":"71332", "compliance_status":"0", "need_personal_recommend":"1",
        "player_so_load":"1", "is_android_pad_screen":"0"
    ]
    static let userAgent = "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)"
    /// 匿名设备激活（`app_alert_check`）：官方客户端注册后必走一次。未激活的匿名设备在播放接口上会被当作
    /// 低质量设备，返回 HTTP 200 + 0 字节。同步自 hongguo-android c0821c6（2026-11-24）。
    static let activateURL = "https://log5-applog-lf.fqnovel.com/service/2/app_alert_check/"
    /// 激活是尽力而为的旁路请求，超时要比注册短，避免拖慢起播。
    static let activateTimeout: TimeInterval = 3

    static func register(session: URLSession) async throws -> RegisteredIdentity {
        try Task.checkCancellation()
        let now = Int64(Date().timeIntervalSince1970 * 1000), cdid = UUID().uuidString.lowercased()
        let random = HGCrypto.random(32)
        let compressed = try HGCrypto.gzip(ProtocolJSON.data(payload(now: now, cdid: cdid)))
        let derived = HGCrypto.sha512(HGCrypto.sha512(random) + salt)
        let encrypted = try HGCrypto.aesCBCEncrypt(HGCrypto.sha512(compressed) + compressed, key: Data(derived.prefix(16)), iv: Data(derived.dropFirst(16).prefix(16)))
        let body = Data(hex: "746305100000")! + random + encrypted
        let url = URL(string: "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1")!
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        let headers = ["User-Agent":"com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)",
                       "Accept":"application/json", "Content-Type":"application/octet-stream;tt-data=a", "log-encode-type":"gzip",
                       "x-ss-dp":"8662", "x-ss-req-ticket":String(now), "x-vc-bdturing-sdk-version":"4.0.3.cn", "lc":"101",
                       "sdk-version":"2", "passport-sdk-version":"5051452", "x-neptune":"-8|50:51:59:30:40:47:49:39",
                       "x-ss-stub":HGCrypto.md5(body).hexString.uppercased()]
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let deadline = DramaAPI.playbackDeadline
        let (data, response) = try await session.data(for: DramaAPI.boundedRequest(request, until: deadline))
        try Task.checkCancellation()
        if deadline != nil, let http = response as? HTTPURLResponse {
            try DramaAPI.checkPlaybackHTTP(http)
            try DramaAPI.checkPlaybackBusinessRejection(data)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw HGError.message("匿名设备注册暂时不可用") }
        let object: [String: Any]
        do { object = try ProtocolJSON.object(data) } catch { throw HGError.message("匿名设备注册响应无效") }
        guard ProtocolJSON.integer(object["code"] ?? object["Code"]) == 0,
              let deviceID = ProtocolJSON.identifier(object["device_id_str"] ?? object["device_id"]),
              let installID = ProtocolJSON.identifier(object["install_id_str"] ?? object["install_id"]) else {
            throw HGError.message("匿名设备注册未成功，请稍后重试")
        }
        var responseHeaders = [String: String]()
        for (key, value) in http.allHeaderFields { responseHeaders[String(describing: key)] = String(describing: value) }
        let allowed = Set(["install_id", "ttreq", "store-region", "store-region-src"])
        let cookieList = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url).filter {
            let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            let target = "api5-normal-sinfonlinea.fqnovel.com"
            return allowed.contains($0.name) && $0.path == "/" && ($0.expiresDate == nil || $0.expiresDate! > Date()) && (target == domain || target.hasSuffix("." + domain))
        }
        let cookies = cookieList.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let identity = RegisteredIdentity(deviceID: deviceID, installID: installID, cdid: cdid, appDeviceCookie: cookies,
                                          egdi: responseEgdi(object))
        await activate(identity, session: session)
        return identity
    }

    /// 注册响应里的 `klink_egdi`：不透明字符串，可能直接给，也可能包在 `data` 里。
    static func responseEgdi(_ object: [String: Any]) -> String {
        let candidates = [object["klink_egdi"], ProtocolJSON.dictionary(object["data"])["klink_egdi"]]
        return candidates.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// 注册后立刻做一次 `app_alert_check` 激活。失败不阻断取流：只记一行诊断，签名照常进行。
    static func activate(_ identity: RegisteredIdentity, session: URLSession) async {
        guard !identity.deviceID.isEmpty, !identity.installID.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let url = URL(string: "\(activateURL)?aid=8662&app_name=novelread&channel=update_64&device_id=\(identity.deviceID)"
            + "&iid=\(identity.installID)&device_platform=android&os=android&version_code=73932&version_name=7.3.9.32&_rticket=\(now)")!
        var request = URLRequest(url: url, timeoutInterval: activateTimeout)
        request.httpMethod = "GET"; request.httpShouldHandleCookies = false
        request.setValue("com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await session.data(for: request)
            print("app_alert_check -> \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        } catch {
            print("app_alert_check -> failed \((error as? URLError)?.code ?? .unknown)")
        }
    }

    private static func payload(now: Int64, cdid: String) -> [String: Any] {
        let header: [String: Any] = [
            "display_name":"红果免费短剧", "update_version_code":73932, "manifest_version_code":73932, "app_version_minor":"7.3.9.32",
            "aid":8662, "channel":"update_64", "package":"com.phoenix.read", "app_version":"7.3.9.32", "version_code":73932,
            "sdk_version":"3.7.0-rc.34-fanqie-xiaoshuo", "sdk_target_version":29, "git_hash":"3a88f4e", "os":"Android",
            "os_version":"16", "os_api":36, "device_model":"25053RT47C", "device_brand":"Redmi", "device_manufacturer":"Redmi",
            "cpu_abi":"arm64-v8a", "release_build":"b5e187f", "density_dpi":520, "display_density":"mdpi", "resolution":"1280x2772",
            "language":"zh", "timezone":8, "access":"wifi", "not_request_sender":0, "carrier":"CHINA MOBILE", "mcc_mnc":"46000",
            "rom":"eng.root.20231116.160340", "rom_version":"W528JS release-keys", "cdid":cdid, "sig_hash":"56a962410c494bbaf0b58dba20cae56f",
            "openudid":HGCrypto.random(8).hexString, "clientudid":UUID().uuidString.lowercased(), "ipv6_list":[String](), "region":"CN",
            "tz_name":"Asia/Shanghai", "tz_offset":28800, "sim_region":"cn", "sim_serial_number":[String](), "oaid_may_support":false,
            "req_id":UUID().uuidString.lowercased(), "device_platform":"android", "custom":["account_region_src":"fallback", "account_region":"cn", "host_bit":64, "dragon_device_type":"phone"],
            "pre_installed_channel":"", "apk_first_install_time":now, "is_system_app":0, "sdk_flavor":"china", "guest_mode":0
        ]
        return ["magic_tag":"ss_app_log", "header":header, "_gen_time":now]
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Protocol algorithm: jackotom/hongguo-drama 5febca2; see PureSign.js notices.
import Foundation
import JavaScriptCore

struct SignedProtocolRequest: Sendable {
    let url: URL
    let headers: [String: String]
}

/// JavaScriptCore executes the bundled, local signing code. It never loads a web page or sends traffic.
actor ProtocolSigner {
    static let shared = ProtocolSigner()
    private var context: JSContext?
    private let resourceDirectory: URL?

    init(resourceDirectory: URL? = nil) { self.resourceDirectory = resourceDirectory }

    private func runtime() throws -> JSContext {
        if let context { return context }
        guard let runtime = JSContext() else { throw HGError.message("无法初始化本机协议") }
        let hash: @convention(block) (String, String) -> String = { algorithm, hex in
            guard let bytes = Data(hex: hex) else { return "" }
            switch algorithm.lowercased() {
            case "md5": return HGCrypto.md5(bytes).hexString
            case "sha512": return HGCrypto.sha512(bytes).hexString
            case "sha256": return HGCrypto.sha256(bytes).hexString
            default: return ""
            }
        }
        let random: @convention(block) (Int) -> String = { HGCrypto.random(min(4096, max(0, $0))).hexString }
        runtime.setObject(hash, forKeyedSubscript: "__hgHash" as NSString)
        runtime.setObject(random, forKeyedSubscript: "__hgRandom" as NSString)
        for name in ["BufferRuntime", "PureSign"] {
            let path = resourceDirectory?.appendingPathComponent(name + ".js") ?? Bundle.main.url(forResource: name, withExtension: "js")
            guard let path, let script = try? String(contentsOf: path, encoding: .utf8) else {
                throw HGError.message("本机协议资源缺失，请重新安装")
            }
            runtime.evaluateScript(script, withSourceURL: path)
            guard runtime.exception == nil else { throw HGError.message("本机协议初始化失败") }
        }
        guard let text = runtime.objectForKeyedSubscript("hgRuntimeSelfTest")?.call(withArguments: [])?.toString(),
              let data = text.data(using: .utf8), let test = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              test["sm3"] == "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0",
              test["md5"] == "900150983CD24FB0D6963F7D28E17F72",
              test["base64"] == "57qi5p6cIGlPUw==", test["bigEndian"] == "807060504030201" else {
            throw HGError.message("本机协议自检失败")
        }
        context = runtime
        return runtime
    }

    private func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    func signedRequest(baseURL: String, query: [[String]], body: Data?, device: [String: String]) throws -> SignedProtocolRequest {
        try Task.checkCancellation()
        let runtime = try runtime()
        runtime.exception = nil
        let arguments: [Any] = [baseURL, try jsonString(query), body?.base64EncodedString() as Any? ?? NSNull(), try jsonString(device)]
        guard let text = runtime.objectForKeyedSubscript("hgSignedRequest")?.call(withArguments: arguments)?.toString(),
              runtime.exception == nil,
              let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let address = object["url"] as? String, let url = URL(string: address),
              let headers = object["headers"] as? [String: String] else { throw HGError.message("无法生成本机请求签名") }
        return SignedProtocolRequest(url: url, headers: headers)
    }

    func sign(url: String, body: Data?, device: [String: String]) throws -> [String: String] {
        try Task.checkCancellation()
        let runtime = try runtime()
        runtime.exception = nil
        let arguments: [Any] = [url, body?.base64EncodedString() as Any? ?? NSNull(), try jsonString(device)]
        guard let text = runtime.objectForKeyedSubscript("hgSignExact")?.call(withArguments: arguments)?.toString(), runtime.exception == nil,
              let data = text.data(using: .utf8), let headers = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw HGError.message("无法生成本机请求签名")
        }
        return headers
    }

    func branch(url: String, body: Data?) throws -> Int {
        try Task.checkCancellation()
        let runtime = try runtime()
        runtime.exception = nil
        let result = runtime.objectForKeyedSubscript("hgBranch")?.call(withArguments: [url, body?.base64EncodedString() as Any? ?? NSNull()])
        guard runtime.exception == nil, let result else { throw HGError.message("本机协议检查失败") }
        return Int(result.toInt32())
    }
}

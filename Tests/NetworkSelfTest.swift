// SPDX-License-Identifier: GPL-3.0-only
// Offline protocol tests. All inputs are synthetic and no network request is dispatched.
import Foundation
import JavaScriptCore

@main struct NetworkSelfTest {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = root.appendingPathComponent("Sources/Networking")
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/SigningOracle.json"))) as! [[String: Any]]
        for fixture in fixtures {
            let timestamp = (fixture["timestamp"] as! NSNumber).int64Value
            let context = JSContext()!
            let hash: @convention(block) (String, String) -> String = { algorithm, hex in
                let bytes = Data(hex: hex)!
                switch algorithm {
                case "md5": return HGCrypto.md5(bytes).hexString
                case "sha512": return HGCrypto.sha512(bytes).hexString
                default: return HGCrypto.sha256(bytes).hexString
                }
            }
            let random: @convention(block) (Int) -> String = { String(repeating: "11", count: $0) }
            context.setObject(hash, forKeyedSubscript: "__hgHash" as NSString)
            context.setObject(random, forKeyedSubscript: "__hgRandom" as NSString)
            context.evaluateScript(try String(contentsOf: resources.appendingPathComponent("BufferRuntime.js"), encoding: .utf8))
            context.evaluateScript("Date.now=()=>\(timestamp);Math.random=()=>0.123456789;")
            context.evaluateScript(try String(contentsOf: resources.appendingPathComponent("PureSign.js"), encoding: .utf8))
            let source = "let body=Buffer.from('{\"test\":\"短剧\"}');let url='https://example.com/api?q=test';JSON.stringify([xGorgon('q=test',body,\(timestamp / 1000),42131),helios(\(timestamp / 1000)),buildMedusa(url,body,\(timestamp / 1000),{device_id:'1000000000000001',version_name:'7.2.2.32'})]);"
            let actual = context.evaluateScript(source)?.toString() ?? ""
            precondition(context.exception == nil, "JavaScript runtime failed")
            precondition(HGCrypto.sha256(Data(actual.utf8)).hexString == fixture["sha256"] as! String, "Node signing oracle mismatch")
        }
        let precise = try ProtocolJSON.object(Data(#"{"id":18446744073709551615,"larger":123456789012345678901234567890,"text":"12345678901234567890","fraction":1234567890123456.5,"exponent":1234567890123456e2}"#.utf8))
        precondition(precise["id"] as? String == "18446744073709551615")
        precondition(precise["larger"] as? String == "123456789012345678901234567890")
        precondition(precise["text"] as? String == "12345678901234567890")
        precondition(precise["fraction"] is NSNumber && precise["exponent"] is NSNumber)
        precondition(ProtocolJSON.identifier("000000") == nil && ProtocolJSON.identifier("1234\n") == nil)

        let signer = ProtocolSigner(resourceDirectory: resources)
        let binary = Data([0, 255, 128, 1, 13, 10]) + (try HGCrypto.gzip(Data("synthetic binary payload".utf8)))
        let signed = try await signer.signedRequest(baseURL: "https://example.com/api", query: [["query", "短剧 !'()* "]], body: binary,
            device: ["device_id":"1000000000000001", "version_name":"7.2.2.32"])
        precondition(signed.headers["x-ss-stub"] == HGCrypto.md5(binary).hexString.uppercased(), "Binary request body changed before signing")
        precondition(signed.url.absoluteString.contains("%20"), "URL query space encoding changed")
        let exact = try await signer.sign(url: signed.url.absoluteString, body: binary, device: ["device_id":"1000000000000001", "version_name":"7.2.2.32"])
        precondition(exact["x-ss-stub"] == signed.headers["x-ss-stub"])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DramaAPI(resourceDirectory: resources).home(feed: "recommend", offset: 0)
        }
        do { _ = try await cancelled.value; fatalError("Cancelled request was accepted") } catch is CancellationError { }
        print("PASS: 4 original Node signing vectors; exact 20/30-digit IDs; numeric-token parsing; binary/gzip body digest; URL spaces; cancelled query rejects before HTTP.")
    }
}

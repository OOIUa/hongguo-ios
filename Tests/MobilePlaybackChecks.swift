// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import JavaScriptCore

func checkMobilePlayback(context: JSContext, root: URL) async throws {
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

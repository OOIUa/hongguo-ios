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
        // 猜你喜欢: request shape for anonymous and signed-in rounds, parsing, and pager batching.
        let anonymous = try GuessFeed.request(account: nil, session: "", offset: 0, rticket: 1)
        let anonymousQuery = URLComponents(url: anonymous.url!, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ items: [URLQueryItem], _ name: String) -> String? { items.first { $0.name == name }?.value }
        precondition(anonymous.url!.absoluteString.hasPrefix("https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/bookmall/tab/v1/?") && anonymous.httpMethod == "GET")
        precondition(anonymous.value(forHTTPHeaderField: "Cookie") == nil && value(anonymousQuery, "device_id") == nil)
        precondition(value(anonymousQuery, "tab_type") == "16" && value(anonymousQuery, "client_req_type") == "1" && value(anonymousQuery, "session_id") == nil)
        let account = GuessAccount(cookie: "sessionid=offline; install_id=9999999999999999998", deviceID: "9999999999999999999",
                                   installID: "9999999999999999998", device: ["device_type": "OfflinePhone", "cdid": "not-forwarded"])
        let signedIn = try GuessFeed.request(account: account, session: "srv", offset: 2, rticket: 1)
        let signedQuery = URLComponents(url: signedIn.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(signedIn.value(forHTTPHeaderField: "Cookie") == account.cookie && signedIn.value(forHTTPHeaderField: "X-Gorgon") == nil)
        precondition(value(signedQuery, "device_id") == "9999999999999999999" && value(signedQuery, "iid") == "9999999999999999998")
        precondition(value(signedQuery, "device_type") == "OfflinePhone" && value(signedQuery, "cdid") == nil)
        precondition(value(signedQuery, "session_id") == "srv" && value(signedQuery, "offset") == "2" && value(signedQuery, "client_req_type") == "2")
        precondition((try? GuessFeed.request(account: GuessAccount(cookie: "sessionid=x", deviceID: "", installID: "", device: [:]), session: "", offset: 0)) == nil)
        let feed = try GuessFeed.parse(ProtocolJSON.object(Data(#"{"code":0,"data":{"tab_item":[{"tab_type":3},{"tab_type":16,"session_id":"srv","cell_data":[{"cell_name":"猜你喜欢","cell_data":[{"video_data":[{"video_detail":{"series_id":7698294694886788121,"series_title":"测试甲","series_cover":"https:\/\/p3.example.invalid\/a.jpg","series_intro":"简介","episode_cnt":80}},{"book_id":"7697622096326708286","book_name":"测试乙","cover":"https://p3.example.invalid/b.jpg"},{"series_id":"7698294694886788121","series_title":"重复"},{"series_id":"bad","series_title":"无效"}]}]}]}]}}"#.utf8)))
        precondition(feed.dramas.map(\.id) == ["7698294694886788121", "7697622096326708286"] && feed.session == "srv")
        precondition(feed.dramas[0].coverURL == "https://p3.example.invalid/a.jpg" && feed.dramas[0].episodeCount == 80)
        precondition((try? GuessFeed.parse(["code": 1])) == nil)
        precondition((try? GuessFeed.parse(["code": 0, "data": ["tab_item": [["tab_type": 16, "session_id": "a\nb"]]]])) == nil)
        final class Calls: @unchecked Sendable { var values = [(String, Int)]() }
        let calls = Calls()
        let pager = GuessPager(owner: nil) { cursor, offset in
            calls.values.append((cursor, offset))
            return GuessBatch(dramas: (0..<3).map { Drama(id: "73000000000000\(offset * 3 + $0)", title: "剧", coverURL: "", summary: "", episodeCount: 1) },
                              session: offset == 0 ? "srv" : "")
        }
        let first = try await pager.next()
        precondition(first.dramas.count == 6 && first.nextOffset == 2 && first.hasMore)
        precondition(calls.values.map(\.0) == ["", "srv"] && calls.values.map(\.1) == [0, 1])
        _ = try await pager.next()
        precondition(calls.values.last?.0 == "srv", "an empty session must not overwrite the server session")
        let repeating = GuessPager(owner: nil) { _, _ in GuessBatch(dramas: [Drama(id: "7300000000000000001", title: "剧", coverURL: "", summary: "", episodeCount: 1)], session: "") }
        let once = try await repeating.next(); precondition(once.dramas.count == 1)
        let ended = try await repeating.next()
        precondition(ended.dramas.isEmpty && !ended.hasMore)
        print("PASS: 猜你喜欢 anonymous/signed-in request, parsing and pager batching.")
        print("PASS: 4 original Node signing vectors; exact 20/30-digit IDs; numeric-token parsing; binary/gzip body digest; URL spaces; cancelled query rejects before HTTP.")
    }
}

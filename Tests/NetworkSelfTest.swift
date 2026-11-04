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
        let account = GuessAccount(cookie: "sessionid=offline", device: ["device_type": "OfflinePhone", "cdid": "not-forwarded"])
        let signedIn = try GuessFeed.request(account: account, session: "srv", offset: 2, rticket: 1)
        let signedQuery = URLComponents(url: signedIn.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(signedIn.value(forHTTPHeaderField: "Cookie") == account.cookie && signedIn.value(forHTTPHeaderField: "X-Gorgon") == nil)
        precondition(value(signedQuery, "device_id") == nil && value(signedQuery, "iid") == nil, "device_id/iid with an account cookie is answered with 110")
        precondition(value(signedQuery, "device_type") == "OfflinePhone" && value(signedQuery, "cdid") == nil)
        precondition(value(signedQuery, "session_id") == "srv" && value(signedQuery, "offset") == "2" && value(signedQuery, "client_req_type") == "2")
        let feed = try GuessFeed.parse(ProtocolJSON.object(Data(#"{"code":0,"data":{"tab_item":[{"tab_type":3},{"tab_type":16,"session_id":"srv","cell_data":[{"cell_name":"猜你喜欢","cell_data":[{"video_data":[{"video_detail":{"series_id":7698294694886788121,"series_title":"测试甲","series_cover":"https:\/\/p3.example.invalid\/a.jpg","series_intro":"简介","episode_cnt":80}},{"book_id":"7697622096326708286","book_name":"测试乙","cover":"https://p3.example.invalid/b.jpg"},{"series_id":"7698294694886788121","series_title":"重复"},{"series_id":"bad","series_title":"无效"}]}]}]}]}}"#.utf8)))
        precondition(feed.dramas.map(\.id) == ["7698294694886788121", "7697622096326708286"] && feed.session == "srv")
        precondition(feed.served >= feed.dramas.count && feed.served > 0)
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
        // A non-zero code moves to the next host from the start; an error thrown by the fetch does not move at all.
        let feedObject = try ProtocolJSON.object(Data(#"{"code":0,"data":{"tab_item":[{"tab_type":16,"session_id":"fresh"}]}}"#.utf8))
        var attempts = [URLRequest]()
        let recovered = try await GuessFeed.batch(account: account, session: "stale", offset: 3) { request in
            attempts.append(request)
            return attempts.count < 3 ? ["code": 110] : feedObject
        }
        precondition(recovered.restarted && recovered.session == "fresh")
        precondition(attempts.map { $0.url!.host! } == GuessFeed.hosts && Set(GuessFeed.hosts).count == 3)
        let staleQuery = URLComponents(url: attempts[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(value(staleQuery, "session_id") == "stale" && value(staleQuery, "offset") == "3")
        let retryQuery = URLComponents(url: attempts[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(value(retryQuery, "session_id") == nil && value(retryQuery, "offset") == "0" && value(retryQuery, "client_req_type") == "1")
        precondition(attempts[1].value(forHTTPHeaderField: "Cookie") == account.cookie)
        let direct = try await GuessFeed.batch(account: nil, session: "srv", offset: 1) { _ in feedObject }
        precondition(!direct.restarted)
        var exhausted = 0
        do {
            _ = try await GuessFeed.batch(account: nil, session: "", offset: 0) { _ in exhausted += 1; return ["code": 110] }
            fatalError("Every host answering 110 must be reported")
        } catch let error as HGError { precondition(exhausted == 3 && error.localizedDescription.contains("110")) }
        var failures = 0
        do {
            _ = try await GuessFeed.batch(account: nil, session: "", offset: 0) { _ in failures += 1; throw HGError.message("HTTP 500") }
            fatalError("A fetch failure must be reported")
        } catch is HGError { precondition(failures == 1) }
        // The server's offset counts rows, so a batch advances it by the rows served.
        let strideCalls = Calls()
        let striding = GuessPager(owner: nil) { cursor, offset in
            strideCalls.values.append((cursor, offset))
            return GuessBatch(dramas: (0..<3).map { Drama(id: "7400000000000\(offset)\($0)", title: "剧", coverURL: "", summary: "", episodeCount: 1) },
                              session: "srv", served: offset == 0 ? 3 : 6)
        }
        let stridePage = try await striding.next()
        precondition(strideCalls.values.map(\.1) == [0, 3] && stridePage.nextOffset == 9)
        // A restarted batch replaces the rejected pagination and shown cards stay filtered out.
        let restartCalls = Calls()
        let drama = { (id: Int) in Drama(id: "73000000000000\(id)", title: "剧", coverURL: "", summary: "", episodeCount: 1) }
        let restarting = GuessPager(owner: nil) { cursor, offset in
            restartCalls.values.append((cursor, offset))
            switch restartCalls.values.count {
            case 1: return GuessBatch(dramas: (0..<6).map(drama), session: "old")
            case 2: return GuessBatch(dramas: [0, 6, 7, 8, 9, 10, 11].map(drama), session: "", restarted: true)
            default: return GuessBatch(dramas: [drama(12)], session: "new")
            }
        }
        _ = try await restarting.next()
        let afterRestart = try await restarting.next()
        precondition(afterRestart.dramas.count == 6 && afterRestart.nextOffset == 1)
        _ = try await restarting.next()
        precondition(restartCalls.values.prefix(3).map(\.0) == ["", "old", ""] && restartCalls.values.prefix(3).map(\.1) == [0, 1, 1])
        print("PASS: 猜你喜欢 anonymous/signed-in request, parsing, pager batching and host rotation.")
        // video_tab playback model: full GetVideoModelRequest query, object/string model, rejection of unusable replies.
        let identity = RegisteredIdentity(deviceID: "9999999999999999999", installID: "9999999999999999998", cdid: "offline", appDeviceCookie: "")
        let tabURL = DramaAPI.tabVideoURL(identity, episodeID: "7600000000000000001", rticket: 1)
        let tabQuery = URLComponents(url: tabURL, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(tabURL.absoluteString.hasPrefix("https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/?"))
        for (name, expected) in [("video_id","7600000000000000001"),("video_id_type","0"),("device_level","1"),("need_all_video_definition","1"),
                                 ("need_mp4_align","0"),("use_os_player","0"),("video_platform","1024"),("source","0"),("from_video_id",""),
                                 ("device_id","9999999999999999999"),("iid","9999999999999999998")] {
            precondition(value(tabQuery, name) == expected, "video_tab query \(name)")
        }
        let tabObject = DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000001":{"video_model":{"video_list":[{"codec_type":"bytevc1"}]}}}}}"#.utf8), episodeID: "7600000000000000001")
        precondition(ProtocolJSON.array(tabObject?["video_list"]).count == 1)
        let tabString = DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000001":{"video_model":"{\"video_list\":[{\"codec_type\":\"h264\"}]}"}}}}"#.utf8), episodeID: "7600000000000000001")
        precondition(tabString != nil)
        precondition(DramaAPI.tabVideoModel(Data(#"{"code":100103,"message":"PARAM_INVALID"}"#.utf8), episodeID: "7600000000000000001") == nil)
        precondition(DramaAPI.tabVideoModel(Data(), episodeID: "7600000000000000001") == nil)
        precondition(DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000999":{"video_model":{"video_list":[{}]}}}}}"#.utf8), episodeID: "7600000000000000001") == nil)
        precondition(DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000001":{"video_model":{"video_list":[]}}}}}"#.utf8), episodeID: "7600000000000000001") == nil)
        precondition(DramaAPI.playbackURL(identity, host: DramaAPI.playbackRetryHost, rticket: 1).absoluteString.hasPrefix("https://api5-normal-hl.fqnovel.com/novel/player/multi_video_model/v1/?"))
        // ByteVC2-only episodes say so; inline rows without encryption metadata may use a fully verified fallback.
        let trackAPI = DramaAPI(resourceDirectory: resources)
        let videoRow = { (codec: String, url: String, side: Int) -> [String: Any] in ["codec_type":codec,"vwidth":side,"vheight":side * 16 / 9,"definition":"\(side)p","main_url":url] }
        do {
            _ = try await trackAPI.modelTrack(["video_list":[videoRow("bytevc2","https://v1.qznovelvod.com/a.mp4",1080)]])
            fatalError("A ByteVC2-only episode has no playable track")
        } catch { precondition(error.localizedDescription.contains("ByteVC2")) }
        let incompleteModel: [String: Any] = ["video_list":[videoRow("h264","https://v1.qznovelvod.com/nokey.mp4",1080)],"video_id":"v0abc","video_duration":60.0,"fallback_api":"https://vod.snssdk.com/video/fallback"]
        let spadeSample = "k7wd8lO6G/dhixnESLgG9k2BCvxFtxX+Xrkl8my/EvVBugmCgg=="
        @Sendable func fallbackReply(_ id: String, _ duration: Double, _ side: Int) -> [String: Any] {
            var row: [String: Any] = ["codec_type":"h264","vwidth":side,"vheight":side * 16 / 9,"definition":"\(side)p","main_url":"https://v1.qznovelvod.com/keyed.mp4"]
            row["spade_a"] = spadeSample
            return ["video_info":["data":["video_id":id,"video_duration":duration,"video_list":["video_1":row]]]]
        }
        let verified = try await trackAPI.modelTrack(incompleteModel) { _ in fallbackReply("v0abc", 60.2, 1080) }
        precondition(verified.url.absoluteString == "https://v1.qznovelvod.com/keyed.mp4" && verified.encrypted)
        for reply in [fallbackReply("v0other", 60, 1080), fallbackReply("v0abc", 30, 1080), fallbackReply("v0abc", 60, 720)] {
            let unverified = try? await trackAPI.modelTrack(incompleteModel) { _ in reply }
            precondition(unverified == nil, "A fallback that fails id, duration or quality must not be used")
        }
        var declared = incompleteModel
        declared["video_list"] = [videoRow("h264","https://v1.qznovelvod.com/nokey.mp4",1080).merging(["encrypt_info":["encrypt":true]]) { $1 }]
        let declaredTrack = try? await trackAPI.modelTrack(declared) { _ in fatalError("A declared-encrypted row must not read the fallback") }
        precondition(declaredTrack == nil)
        print("PASS: video_tab playback model request and parsing.")
        print("PASS: 4 original Node signing vectors; exact 20/30-digit IDs; numeric-token parsing; binary/gzip body digest; URL spaces; cancelled query rejects before HTTP.")
    }
}

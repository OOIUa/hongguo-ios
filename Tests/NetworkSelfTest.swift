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
        final class Calls: @unchecked Sendable { var values = [GuessCursor]() }
        let drama = { (id: Int) in Drama(id: "73000000000000\(id)", title: "剧", coverURL: "", summary: "", episodeCount: 1) }
        let calls = Calls()
        let pager = GuessPager(owner: nil) { cursor in
            calls.values.append(cursor)
            var next = cursor; next.offset += 3; next.session = "srv"
            return GuessBatch(dramas: (0..<3).map { drama(cursor.offset + $0) }, session: "srv", served: 3, cursor: next)
        }
        let first = try await pager.next()
        precondition(first.dramas.count == 6 && first.nextOffset == 2 && first.hasMore)
        precondition(calls.values.map(\.offset) == [0, 3] && calls.values[1].session == "srv" && calls.values[1].filterIDs.count == 3)
        let second = try await pager.next()
        precondition(second.nextOffset > first.nextOffset)
        let repeating = GuessPager(owner: nil) { cursor in
            var next = cursor; next.offset += 1
            return GuessBatch(dramas: [drama(1)], session: "", cursor: next)
        }
        let once = try await repeating.next(); precondition(once.dramas.count == 1)
        let ended = try await repeating.next()
        precondition(ended.dramas.isEmpty && !ended.hasMore)
        // A refresh by the same owner keeps dedupe and reports that nothing new arrived; another owner starts clean.
        let refreshed = GuessPager(owner: nil, previous: repeating) { cursor in GuessBatch(dramas: [drama(1)], session: "", cursor: cursor) }
        do { _ = try await refreshed.next(); fatalError("Replaying old works must be reported") }
        catch let error as HGError { precondition(error.localizedDescription.contains("最近已去重 1 部")) }
        let other = GuessPager(owner: UUID(), previous: repeating) { cursor in GuessBatch(dramas: [drama(1)], session: "", cursor: cursor) }
        let otherPage = try await other.next(); precondition(otherPage.dramas.count == 1)
        // A non-zero code moves to the next host from the start; an error thrown by the fetch does not move at all.
        let feedObject = try ProtocolJSON.object(Data(#"{"code":0,"data":{"tab_item":[{"tab_type":16,"session_id":"fresh"}]}}"#.utf8))
        func cursor(_ session: String, _ offset: Int) -> GuessCursor { var c = GuessCursor(); c.session = session; c.offset = offset; return c }
        var attempts = [URLRequest]()
        let recovered = try await GuessFeed.batch(account: account, cursor: cursor("stale", 3)) { request in
            attempts.append(request)
            return attempts.count < 3 ? ["code": 110] : feedObject
        }
        precondition(recovered.restarted && recovered.session == "fresh" && recovered.cursor.session == "fresh" && recovered.cursor.offset == 1)
        precondition(attempts.map { $0.url!.host! } == GuessFeed.hosts && Set(GuessFeed.hosts).count == 3)
        let staleQuery = URLComponents(url: attempts[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(value(staleQuery, "session_id") == "stale" && value(staleQuery, "offset") == "3")
        let retryQuery = URLComponents(url: attempts[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(value(retryQuery, "session_id") == nil && value(retryQuery, "offset") == "0" && value(retryQuery, "client_req_type") == "1")
        precondition(attempts[1].value(forHTTPHeaderField: "Cookie") == account.cookie)
        let direct = try await GuessFeed.batch(account: nil, cursor: cursor("srv", 1)) { _ in feedObject }
        precondition(!direct.restarted)
        var exhausted = 0
        do {
            _ = try await GuessFeed.batch(account: nil, cursor: GuessCursor()) { _ in exhausted += 1; return ["code": 110] }
            fatalError("Every host answering 110 must be reported")
        } catch let error as HGError { precondition(exhausted == 3 && error.localizedDescription.contains("110")) }
        var failures = 0
        do {
            _ = try await GuessFeed.batch(account: nil, cursor: GuessCursor()) { _ in failures += 1; throw HGError.message("HTTP 500") }
            fatalError("A fetch failure must be reported")
        } catch is HGError { precondition(failures == 1) }
        // No 30-card cap; the entry's offset advances by the rows served.
        let rows = (0..<45).map { #"{"series_id":"\#(7600000000000000000 + $0)","series_title":"作品\#($0)"}"# }.joined(separator: ",")
        let large = try ProtocolJSON.object(Data(#"{"code":0,"data":{"tab_item":[{"tab_type":16,"cell_data":[{"cell_data":[{"video_data":[\#(rows)]}]}]}]}}"#.utf8))
        let largeBatch = try await GuessFeed.batch(account: nil, cursor: GuessCursor()) { _ in large }
        precondition(largeBatch.dramas.count == 45 && largeBatch.cursor.offset == 45)
        // Signed form: shared registered identity, 7.4.3.32, registration cookie; signed in, the account cookie.
        let registered = RegisteredIdentity(deviceID: "3333333333333333", installID: "4444444444444444", cdid: "cdid-test", appDeviceCookie: "install_id=4444444444444444")
        final class Signs: @unchecked Sendable { var values = [(String, [[String]], [String: String])]() }
        let signs = Signs()
        let fakeSign: GuessFeed.Sign = { base, query, device in
            signs.values.append((base, query, device))
            let text = base + "?" + query.map { $0[0] + "=" + $0[1].addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }.joined(separator: "&") + "&_rticket=1"
            return SignedProtocolRequest(url: URL(string: text)!, headers: ["x-medusa": "signed", "x-ss-req-ticket": "1"])
        }
        var signedRequests = [URLRequest]()
        let infinite = try ProtocolJSON.object(Data(#"{"code":0,"data":{"tab_item":[{"tab_type":16,"session_id":"srv","bottom_unlimited":true,"client_template":7,"bookstore_id":"8001","version_tag":"fixture-v7","cell_data":[{"cell_id":"9001","cell_data":[{"video_data":[{"series_id":"7600000000000000101","series_title":"甲"}]}]}]}]}}"#.utf8))
        let entry = try await GuessFeed.batch(account: nil, cursor: GuessCursor(), identity: { registered }, sign: fakeSign) { request in
            signedRequests.append(request); return infinite
        }
        precondition(entry.cursor.flow == GuessFlow(cellID: "9001", planID: "8001", versionTag: "fixture-v7") && entry.cursor.offset == 0)
        precondition(entry.cursor.identityID == registered.deviceID)
        let signedQuery0 = URLComponents(url: signedRequests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(signedRequests[0].url!.absoluteString.contains(GuessFeed.entryPath + "?") && signedRequests[0].value(forHTTPHeaderField: "x-medusa") == "signed")
        precondition(value(signedQuery0, "device_id") == registered.deviceID && value(signedQuery0, "iid") == registered.installID)
        precondition(value(signedQuery0, "version_code") == "74332" && value(signedQuery0, "version_name") == "7.4.3.32" && value(signedQuery0, "pv_player") == "74332")
        precondition(signedQuery0.filter { $0.name == "_rticket" }.count == 1 && signs.values[0].2["version_name"] == "7.4.3.32")
        precondition(signedRequests[0].value(forHTTPHeaderField: "User-Agent")!.hasPrefix("com.phoenix.read/74332"))
        precondition(signedRequests[0].value(forHTTPHeaderField: "Cookie") == registered.appDeviceCookie)
        // The cell continuation uses the server cursor and filter_ids.
        var continued = entry.cursor; continued.filterIDs = ["7600000000000000101"]
        let cellObject = try ProtocolJSON.object(Data(#"{"code":0,"data":{"next_offset":6,"session_id":"cell-session","has_more":false,"cell_view":{"cell_data":[{"video_data":[{"series_id":"7600000000000000102","series_title":"乙"}]}]}}}"#.utf8))
        let cell = try await GuessFeed.batch(account: account, cursor: continued, identity: { registered }, sign: fakeSign) { request in
            signedRequests.append(request); return cellObject
        }
        precondition(cell.dramas.map(\.id) == ["7600000000000000102"] && cell.cursor.offset == 6 && cell.cursor.session == "cell-session")
        let cellQuery = URLComponents(url: signedRequests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(signedRequests[1].url!.absoluteString.contains(GuessFeed.cellPath + "?") && value(cellQuery, "cell_id") == "9001" && value(cellQuery, "plan_id") == "8001")
        precondition(value(cellQuery, "version_tag") == "fixture-v7" && value(cellQuery, "client_template") == "7" && value(cellQuery, "change_type") == "0")
        precondition(value(cellQuery, "client_req_type") == "2" && value(cellQuery, "filter_ids") == "7600000000000000101" && value(cellQuery, "offset") == "0")
        precondition(signedRequests[1].value(forHTTPHeaderField: "Cookie") == account.cookie && value(cellQuery, "device_id") == registered.deviceID)
        let stalled = try ProtocolJSON.object(Data(#"{"code":0,"data":{"next_offset":0,"cell_view":{"cell_data":[]}}}"#.utf8))
        do { _ = try await GuessFeed.batch(account: nil, cursor: entry.cursor, identity: { registered }, sign: fakeSign) { _ in stalled }; fatalError("A stalled cursor must be reported") }
        catch let error as HGError { precondition(error.localizedDescription.contains("游标未前进")) }
        // A changed identity reads the entry again.
        let renewed = RegisteredIdentity(deviceID: "5555555555555555", installID: "6666666666666666", cdid: "cdid-2", appDeviceCookie: "")
        var reread: URLRequest?
        let afterChange = try await GuessFeed.batch(account: nil, cursor: cell.cursor, identity: { renewed }, sign: fakeSign) { request in reread = request; return feedObject }
        precondition(afterChange.restarted && reread!.url!.absoluteString.contains(GuessFeed.entryPath + "?") && value(URLComponents(url: reread!.url!, resolvingAgainstBaseURL: false)!.queryItems!, "offset") == "0")
        // An explicit 110 on a signed request falls back to the unsigned form for the round.
        var fallback = [URLRequest]()
        let unsignedBatch = try await GuessFeed.batch(account: account, cursor: GuessCursor(), identity: { registered }, sign: fakeSign) { request in
            fallback.append(request); return fallback.count == 1 ? ["code": 110] : feedObject
        }
        precondition(unsignedBatch.cursor.unsigned && fallback[1].value(forHTTPHeaderField: "x-medusa") == nil)
        precondition(value(URLComponents(url: fallback[1].url!, resolvingAgainstBaseURL: false)!.queryItems!, "device_id") == nil)
        precondition(fallback[1].value(forHTTPHeaderField: "Cookie") == account.cookie)
        // An empty reply to a signed request drops that identity and rereads the entry on the next host.
        var forgotten = [String](), emptyCalls = 0
        let afterEmpty = try await GuessFeed.batch(account: nil, cursor: cursor("stale", 3), identity: { registered },
                                                   forget: { forgotten.append($0.deviceID) }, sign: fakeSign) { _ in
            emptyCalls += 1; if emptyCalls == 1 { throw GuessEmptyResponse() }; return feedObject
        }
        precondition(afterEmpty.restarted && forgotten == [registered.deviceID])
        // An entry without a complete context keeps tab paging.
        let partial = try ProtocolJSON.object(Data(#"{"code":0,"data":{"tab_item":[{"tab_type":16,"bottom_unlimited":true,"client_template":7,"bookstore_id":"bad","cell_data":[{"cell_id":"9001","cell_data":[{"video_data":[{"series_id":"7600000000000000101","series_title":"甲"}]}]}]}]}}"#.utf8))
        precondition(GuessFeed.cellFlow(partial) == nil && GuessFeed.cellFlow(infinite) != nil)
        // The real signer produces the official header set for this query shape.
        let realSigned = try await GuessFeed.signedRequest(account: nil, cursor: GuessCursor(), identity: registered, host: GuessFeed.hosts[0],
                                                           sign: { base, query, device in try await ProtocolSigner(resourceDirectory: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Sources/Networking")).signedRequest(baseURL: base, query: query, body: nil, device: device) })
        for header in ["x-gorgon", "x-khronos", "x-medusa", "x-helios", "x-ss-req-ticket"] { precondition(realSigned.value(forHTTPHeaderField: header) != nil, header) }
        print("PASS: 猜你喜欢 unsigned/signed request, cell continuation, fallback, parsing, pager batching and host rotation.")
        // Related works: playable types only, season numbering, and the next season after the gap.
        func relatedRow(_ id: String, _ type: Int, _ tag: String, episodes: Int = 80, extra: String = "") -> String {
            #"{"series_id":"\#(id)","title":"作品\#(id)","content_type":\#(type),"episode_cnt":\#(episodes),"cover":"https:\/\/p.example.invalid\/\#(id).jpg","video_desc":"简介","tag_info":{"text":"\#(tag)"}\#(extra)}"#
        }
        let plan = "{\"code\":0,\"data\":[{\"cell_name\":\"相关作品\",\"show_type\":547,\"video_data\":[" + [relatedRow("1",1004,"第1季"), relatedRow("2",1,"第2季"), relatedRow("3",1007,"第4季",episodes:0), relatedRow("4",1002,"第5季",episodes:0), relatedRow("5",1004,"同IP"), relatedRow("100",1004,"第3季"), relatedRow("6",5,"小说"), relatedRow("7",1004,"第6季",episodes:0), relatedRow("8",1004,"第7季",extra:#","disable_play":true"#)].joined(separator: ",") + "]},{\"cell_name\":\"猜你喜欢\",\"show_type\":506,\"video_data\":[" + relatedRow("9",1004,"") + "]}]}"
        let works = try RelatedWorks.parse(ProtocolJSON.object(Data(plan.utf8)), currentID: "100")
        precondition(works.map(\.id) == ["1","2","3","4","5"] && works.map(\.seasonNumber) == [1,2,4,5,0] && works.map(\.upcoming) == [false,false,true,true,false])
        precondition(works[0].drama.coverURL == "https://p.example.invalid/1.jpg" && works[0].drama.episodeCount == 80)
        precondition((try? RelatedWorks.parse(["code":1], currentID: "1")) == nil && (try? RelatedWorks.parse(["code":0], currentID: "1")) == nil)
        let season = { (n: Int, upcoming: Bool) in RelatedWork(drama: Drama(id: "7\(n)", title: "第\(n)", coverURL: "", summary: "", episodeCount: 1), season: "第\(n)季", upcoming: upcoming, seasonNumber: n) }
        precondition(RelatedWorks.nextSeason([season(1,false),season(3,false),season(4,false)])?.seasonNumber == 3)
        precondition(RelatedWorks.nextSeason([season(2,false)])?.seasonNumber == 2)
        precondition(RelatedWorks.nextSeason([season(1,false),season(2,false),season(3,true),season(5,true)])?.seasonNumber == 5)
        precondition(RelatedWorks.nextSeason([season(1,false),season(2,false)]) == nil && RelatedWorks.nextSeason([season(1,false),season(4,false)]) == nil && RelatedWorks.nextSeason([]) == nil)
        let relatedQuery = RelatedWorks.query(id: "123", device: RelatedWorks.device())
        precondition(relatedQuery.contains(["book_id","123"]) && relatedQuery.contains(["scene","10"]) && RelatedWorks.path == "/reading/bookapi/plan/v:version/")
        print("PASS: related works parsing and next season.")
        // Website boards: escaped router payload, page checks, and suggestion limits.
        func rankPage(_ route: String, number: Int = 1, success: Bool = true) -> String {
            let json = #"["rank_\#(route)/page","content",{"isSuccess":\#(success),"rankList":[{"id":"701","seriesId":"701","rank":21,"title":"甲&乙","cover":"https://p.example.invalid/1.jpg","heatText":"9万热度","description":"it's","episodeCount":80},{"seriesId":"702","rank":22,"title":"丙","episodeVids":["1","2"]},{"seriesId":"bad","title":"无效"},{"seriesId":"701","title":"重复"}],"pagination":{"pageNum":\#(number),"totalPages":5}}]"#
            let escaped = json.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#x27;")
            return "<html><script data-fn-name=\"r\" data-fn-args='\(escaped)'></script></html>"
        }
        let boardPage = try WebsiteCatalog.parseRank(rankPage("hot-drama"), board: .all, page: 1)
        precondition(boardPage.entries.map(\.id) == ["701","702"] && boardPage.entries[0].drama.title == "甲&乙" && boardPage.entries[0].drama.summary == "it's")
        precondition(boardPage.entries[0].rank == 21 && boardPage.entries[0].drama.episodeCount == 80 && boardPage.entries[1].drama.episodeCount == 2 && boardPage.totalPages == 5)
        precondition((try? WebsiteCatalog.parseRank(rankPage("hot-ai-drama"), board: .all, page: 1)) == nil)
        precondition((try? WebsiteCatalog.parseRank(rankPage("hot-drama", success: false), board: .all, page: 1)) == nil)
        precondition((try? WebsiteCatalog.parseRank(rankPage("hot-drama", number: 3), board: .all, page: 1)) == nil)
        precondition((try? WebsiteCatalog.parseRank("<html></html>", board: .all, page: 1)) == nil)
        precondition(WebsiteCatalog.rankURL(.real, page: 2).absoluteString == "https://hongguoduanju.com/rank/hot-real-drama?page=2")
        precondition(WebsiteCatalog.rankURL(.all, page: 1).absoluteString == "https://hongguoduanju.com/rank/hot-drama")
        precondition(WebsiteCatalog.parseSuggestions(["suggest_list": (1...12).map { ["name": "剧\($0)"] }]).count == 8)
        precondition(WebsiteCatalog.parseSuggestions(["suggest_list": [["name":"甲"],["display_words":["乙"]],["name":"甲"],["name":" "]]]) == ["甲","乙"])
        print("PASS: website boards and suggestions.")
        // Signed playback: the full GetVideoModelRequest query, the registered identity in the query and the official
        // player's version and headers; object/string model, rejection of unusable replies.
        let identity = RegisteredIdentity(deviceID: "9999999999999999999", installID: "9999999999999999998", cdid: "offline", appDeviceCookie: "install_id=1; ttreq=2")
        let playbackDevice = DramaAPI.playbackDevice(identity)
        let playbackQuery = DramaAPI.playbackQuery(playbackDevice)
        precondition(Dictionary(uniqueKeysWithValues: playbackQuery.map { ($0[0], $0[1]) }) == playbackDevice, "playback query carries every device field")
        precondition(playbackQuery.first == ["iid","9999999999999999998"] && playbackQuery[1] == ["device_id","9999999999999999999"])
        precondition(playbackDevice["version_name"] == "7.3.9.32" && playbackDevice["version_code"] == "73932" && playbackDevice["pv_player"] == "73932")
        let tabQuery = DramaAPI.tabVideoQuery(episodeID: "7600000000000000001").map { URLQueryItem(name: $0[0], value: $0[1]) }
        for (name, expected) in [("video_id","7600000000000000001"),("video_id_type","0"),("device_level","1"),("need_all_video_definition","1"),
                                 ("need_mp4_align","0"),("use_os_player","0"),("video_platform","1024"),("source","0"),("from_video_id","")] {
            precondition(value(tabQuery, name) == expected, "video_tab query \(name)")
        }
        let postHeaders = DramaAPI.playbackHeaders(identity, post: true), getHeaders = DramaAPI.playbackHeaders(identity, post: false)
        precondition(postHeaders["Cookie"] == "install_id=1; ttreq=2" && getHeaders["Cookie"] == "install_id=1; ttreq=2")
        precondition(postHeaders["Content-Type"] == "application/json; charset=utf-8" && getHeaders["Content-Type"] == nil)
        precondition(DramaAPI.playbackRoutes.map(\.post) == [false, true, false, true] && DramaAPI.playbackRoutes.map(\.renewsIdentity) == [false, false, true, false])
        precondition(DramaAPI.playbackRoutes.last?.host == DramaAPI.playbackRetryHost)
        let playbackSignature = try await ProtocolSigner(resourceDirectory: resources).signedRequest(baseURL: "https://\(DramaAPI.playbackHost)/reading/bookapi/video_tab/multi_video_model/v1/",
            query: playbackQuery + DramaAPI.tabVideoQuery(episodeID: "7600000000000000001"), body: nil, device: playbackDevice)
        for name in ["x-gorgon","x-khronos","x-ladon","x-argus","x-helios","x-medusa","x-ss-req-ticket"] { precondition(playbackSignature.headers[name]?.isEmpty == false, "signed playback header \(name)") }
        precondition(playbackSignature.url.absoluteString.contains("from_video_id=&_rticket="))
        let tabObject = DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000001":{"video_model":{"video_list":[{"codec_type":"bytevc1"}]}}}}}"#.utf8), episodeID: "7600000000000000001")
        precondition(ProtocolJSON.array(tabObject?["video_list"]).count == 1)
        let tabString = DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000001":{"video_model":"{\"video_list\":[{\"codec_type\":\"h264\"}]}"}}}}"#.utf8), episodeID: "7600000000000000001")
        precondition(tabString != nil)
        precondition(DramaAPI.tabVideoModel(Data(#"{"code":100103,"message":"PARAM_INVALID"}"#.utf8), episodeID: "7600000000000000001") == nil)
        precondition(DramaAPI.tabVideoModel(Data(), episodeID: "7600000000000000001") == nil)
        precondition(DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000999":{"video_model":{"video_list":[{}]}}}}}"#.utf8), episodeID: "7600000000000000001") == nil)
        precondition(DramaAPI.tabVideoModel(Data(#"{"code":0,"data":{"video_model_data":{"7600000000000000001":{"video_model":{"video_list":[]}}}}}"#.utf8), episodeID: "7600000000000000001") == nil)
        // ByteVC2-only episodes say so; inline rows without encryption metadata may use a fully verified fallback.
        let trackAPI = DramaAPI(resourceDirectory: resources)
        let videoRow = { (codec: String, url: String, side: Int) -> [String: Any] in ["codec_type":codec,"vwidth":side,"vheight":side * 16 / 9,"definition":"\(side)p","main_url":url] }
        do {
            _ = try await trackAPI.modelTrack(["video_list":[videoRow("bytevc2","https://v1.qznovelvod.com/a.mp4",1080)]])
            fatalError("A ByteVC2-only episode has no playable track")
        } catch { precondition(error.localizedDescription.contains("ByteVC2")) }
        // All-ByteVC2 episodes read the fallback, then codec_type=1 (h265, 2026-11-10 issue #3), then the older
        // codec_type=0&force_codec=h264 (hongguoTV 0.1.20).
        final class Reads: @unchecked Sendable { var urls = [String]() }
        @Sendable func codecReply(_ codec: String, id: String = "v0vc2", duration: Double = 60) -> [String: Any] {
            ["video_info":["data":["video_id":id,"video_duration":duration,"video_list":["video_1":videoRow(codec,"https://v1.qznovelvod.com/\(codec).mp4",720)]]]]
        }
        let vc2Model: [String: Any] = ["video_list":[videoRow("bytevc2","https://v1.qznovelvod.com/a.mp4",1080)],"video_id":"v0vc2","video_duration":60.0,
                                       "fallback_api":"https://vod.snssdk.com/video/fallback?sig=a%2Bb&codec_type=3"]
        let reads = Reads()
        let swapped = try await trackAPI.modelTrack(vc2Model) { url in
            reads.urls.append(url); return codecReply(url.hasSuffix("&codec_type=1") ? "h265" : "bvc2")
        }
        precondition(swapped.url.absoluteString == "https://v1.qznovelvod.com/h265.mp4" && reads.urls.count == 2, reads.urls.description)
        precondition(reads.urls[0] == "https://vod.snssdk.com/video/fallback?sig=a%2Bb&codec_type=3")
        precondition(reads.urls[1] == "https://vod.snssdk.com/video/fallback?sig=a%2Bb&codec_type=1", reads.urls[1])
        let older = Reads()
        let legacy = try await trackAPI.modelTrack(vc2Model) { url in
            older.urls.append(url); return codecReply(url.contains("force_codec") ? "hevc" : "bytevc2")
        }
        precondition(legacy.url.absoluteString == "https://v1.qznovelvod.com/hevc.mp4" && older.urls.count == 3, older.urls.description)
        precondition(older.urls[2] == "https://vod.snssdk.com/video/fallback?sig=a%2Bb&codec_type=0&force_codec=h264", older.urls[2])
        // A failed first compatibility read still moves on to the next parameters.
        let afterFailure = try await trackAPI.modelTrack(vc2Model) { url in
            if url.hasSuffix("&codec_type=1") { throw URLError(.networkConnectionLost) }
            return codecReply(url.contains("force_codec") ? "h264" : "bytevc2")
        }
        precondition(afterFailure.url.absoluteString == "https://v1.qznovelvod.com/h264.mp4")
        let bareModel: [String: Any] = ["fallback_api":"https://vod.snssdk.com/video/fallback"]
        let bare = try await trackAPI.modelTrack(bareModel) { url in codecReply(url.hasSuffix("?codec_type=1") ? "h265" : "bytevc2") }
        precondition(bare.url.absoluteString == "https://v1.qznovelvod.com/h265.mp4")
        for compat in [codecReply("bytevc2"), codecReply("hevc", id: "v0other"), codecReply("hevc", duration: 30)] {
            let refused = try? await trackAPI.modelTrack(vc2Model) { url in url.hasSuffix("&codec_type=3") ? codecReply("bytevc2") : compat }
            precondition(refused == nil, "A compatibility answer that is still ByteVC2 or names another video must not play")
        }
        do {
            _ = try await trackAPI.modelTrack(vc2Model) { _ in codecReply("bytevc2") }
            fatalError("A compatibility answer that stays ByteVC2 must be reported")
        } catch { precondition(error.localizedDescription.contains("ByteVC2")) }
        // Upcoming works: the search reservation card with the same id gives the official text and a time in seconds.
        let releaseSearch = try ProtocolJSON.object(Data(#"{"search_tabs":[{"data":[{"video_data":[{}]},{"subscribe_items":[{"item_id_str":"7704905932207049999","sub_info":"预计12月1日上线","schedule_publish_time":1796054400},{"item_id":7704905932207049752,"item_id_str":"7704905932207049752","sub_info":" 预计11月21日上线 ","schedule_publish_time":1795190400}]}]}]}"#.utf8))
        let release = DramaAPI.upcomingRelease(releaseSearch, id: "7704905932207049752")
        precondition(release?.text == "预计11月21日上线" && release?.publishAtMs == 1_795_190_400_000, String(describing: release))
        precondition(DramaAPI.upcomingRelease(releaseSearch, id: "7704905932207040000") == nil, "Only the card with the same id counts")
        let timeOnly = try ProtocolJSON.object(Data(#"{"search_tabs":[{"data":[{"subscribe_items":[{"item_id":7704905932207049752,"schedule_publish_time":1795190400000}]}]}]}"#.utf8))
        precondition(DramaAPI.upcomingRelease(timeOnly, id: "7704905932207049752").map { $0.text.isEmpty && $0.publishAtMs == 1_795_190_400_000 } == true)
        let bareCard = try ProtocolJSON.object(Data(#"{"search_tabs":[{"data":[{"subscribe_items":[{"item_id":7704905932207049752}]}]}]}"#.utf8))
        precondition(DramaAPI.upcomingRelease(bareCard, id: "7704905932207049752") == nil)
        let releaseNow = Date(timeIntervalSince1970: 1_794_300_000) // 2026-11-10 Beijing
        precondition(releaseLabel(" 预计11月21日上线 ", publishAtMs: 0, now: releaseNow) == "预计11月21日上线")
        precondition(releaseLabel("", publishAtMs: 1_795_190_400_000, now: releaseNow) == "预计11月21日上线")
        precondition(releaseLabel("", publishAtMs: 1_798_819_200_000, now: releaseNow) == "预计2027年1月2日上线")
        precondition(releaseLabel("  ", publishAtMs: 0, now: releaseNow).isEmpty)
        precondition(DramaAPI.publishMilliseconds(1_795_190_400) == 1_795_190_400_000 && DramaAPI.publishMilliseconds("1795190400000") == 1_795_190_400_000
                     && DramaAPI.publishMilliseconds(nil) == 0)
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
            // The fallback that fails id, duration or quality is not used; the undeclared inline row plays as plain,
            // and its media index is checked separately (MP4Processor.validate(requirePlain:), ProgressiveSource).
            let plain = try await trackAPI.modelTrack(incompleteModel) { _ in reply }
            precondition(plain.url.absoluteString == "https://v1.qznovelvod.com/nokey.mp4" && !plain.encrypted && plain.spadeA.isEmpty,
                          "A fallback that fails id, duration or quality must not be used")
        }
        // 2026-11-09 (Android issue #3): plain episodes leave encrypt_info out entirely and may have no fallback at all.
        let noFallback = try await trackAPI.modelTrack(["video_list":[videoRow("bytevc1","https://v1.qznovelvod.com/plain.mp4",720)]]) { _ in
            fatalError("A model without fallback_api must not read one")
        }
        precondition(noFallback.url.absoluteString == "https://v1.qznovelvod.com/plain.mp4" && !noFallback.encrypted && noFallback.spadeA.isEmpty)
        let failedRead = try await trackAPI.modelTrack(incompleteModel) { _ in throw URLError(.timedOut) }
        precondition(failedRead.url.absoluteString == "https://v1.qznovelvod.com/nokey.mp4" && !failedRead.encrypted)
        // A keyed row still wins over an undeclared one of the same rank and size.
        var mixed = incompleteModel
        mixed["video_list"] = [videoRow("h264","https://v1.qznovelvod.com/nokey.mp4",1080), videoRow("h264","https://v1.qznovelvod.com/keyed.mp4",720).merging(["spade_a":spadeSample]) { $1 }]
        let keyedFirst = try await trackAPI.modelTrack(mixed) { _ in fallbackReply("v0abc", 60, 1080) }
        precondition(keyedFirst.url.absoluteString == "https://v1.qznovelvod.com/keyed.mp4" && keyedFirst.encrypted)
        var declared = incompleteModel
        declared["video_list"] = [videoRow("h264","https://v1.qznovelvod.com/nokey.mp4",1080).merging(["encrypt_info":["encrypt":true]]) { $1 }]
        let declaredTrack = try? await trackAPI.modelTrack(declared) { _ in fatalError("A declared-encrypted row must not read the fallback") }
        precondition(declaredTrack == nil)
        for flag in [true, "true", 1] as [Any] {
            var keyless = incompleteModel
            keyless["video_list"] = [videoRow("h264","https://v1.qznovelvod.com/nokey.mp4",1080).merging(["encrypt_info":["encrypt":flag]]) { $1 }]
            let refused = try? await trackAPI.modelTrack(keyless) { _ in fallbackReply("v0other", 60, 1080) }
            precondition(refused == nil, "A row that declares encryption without spade_a must never play as plain")
        }
        // A model that yields no track on one route moves on to the next route (2026-11-09: GET gave keyless rows, POST a full model).
        final class RouteCalls: @unchecked Sendable { var routes = [DramaAPI.PlaybackRoute](); var identities = 0 }
        let routeIdentity = RegisteredIdentity(deviceID: "7777777777777777", installID: "8888888888888888", cdid: "cdid-route", appDeviceCookie: "")
        let keylessModel: [String: Any] = ["video_list":[videoRow("h264","https://v1.qznovelvod.com/nokey.mp4",1080).merging(["encrypt_info":["encrypt":true]]) { $1 }]]
        let keyedModel: [String: Any] = ["video_list":[videoRow("h264","https://v1.qznovelvod.com/keyed.mp4",1080).merging(["spade_a":spadeSample]) { $1 }]]
        let routeCalls = RouteCalls()
        let routeRecovered = try await trackAPI.playbackTrack(identity: { routeCalls.identities += 1; return routeIdentity },
            read: { route, _ in routeCalls.routes.append(route); return .model(route.post ? keyedModel : keylessModel) },
            use: { try await trackAPI.modelTrack($0) })
        precondition(routeRecovered.url.absoluteString == "https://v1.qznovelvod.com/keyed.mp4" && routeCalls.routes == Array(DramaAPI.playbackRoutes.prefix(2)))
        let routeTrace = await trackAPI.lastPlaybackTrace
        precondition(routeTrace == "G:b=unusable P:b=ok", routeTrace)
        // Every route failing: the model error is reported ahead of HTTP and empty-response errors.
        let allCalls = RouteCalls()
        do {
            _ = try await trackAPI.playbackTrack(identity: { allCalls.identities += 1; return routeIdentity },
                read: { route, _ in
                    allCalls.routes.append(route)
                    if route.post { if route.host == DramaAPI.playbackHost { return .empty }; throw URLError(.timedOut) }
                    return .model(keylessModel)
                }, use: { try await trackAPI.modelTrack($0) })
            fatalError("Keyless encrypted rows on every route must not play")
        } catch {
            precondition(error.localizedDescription == "当前分集的播放地址或解密信息暂时不可用", error.localizedDescription)
            precondition(!(error is URLError))
        }
        precondition(allCalls.routes == DramaAPI.playbackRoutes && allCalls.identities == 2)
        // Single-episode endpoint (2026-11-11): signatures match the GPL reference byte for byte (LiuWQ0809/hongguo-android e73ed41).
        let signQuery = "aid=8662&device_id=123456789", signBody = Data("{\"video_id\":\"123\"}".utf8), signNonce = Data((0...10).map { UInt8($0) })
        precondition(PlayerSign.gorgon(query: signQuery, body: signBody, timestamp: 1700000000) == "8404401c0000f27a76e6957ca1b97022103fad22c9d970977ebb")
        precondition(PlayerSign.ladon(timestamp: 1700000000, prefix: signNonce.subdata(in: 2..<6)) == "AgMEBVbVr6bCGXEl3RbL1aAkpFHJpdxRfjTl94yWLoz6K/SQ")
        let signArgus = try PlayerSign.argus(query: signQuery, body: signBody, timestamp: 1700000000, deviceID: "123456789", nonce: signNonce)
        precondition(signArgus == "PMw3qMRaFflguIKYlC2mdpV2IWcBCwn1Koj5IoaLq5b3ZXfATS3iituUmnt2HJFxDCWIpwc/xgRjqtkv5n4uLADEdr1fboupPgZ/Kabe2EMEaQ3/o7oMc8hY3WR/n/piCdIOxKzo9jPh8pSH+K+pvGX42LJEU1ciK+i5QxX7TOyhmIHS+K9t673Uc5uPBA18ECoTk5nn361Gl9LORhAI2E5sgtZNeEdG0ZiGxg8C5aL1iFWeyfmPcEQPxdTh/1DX2LE5dW23fo7nBJN4BnwtNwMYQKz+Lx6nN1D5KGt2wQ9f+w==")
        precondition(Data(SM3.hash(Array("abc".utf8))).hexString == "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")
        let signHeaders = try PlayerSign.headers(query: "a=1", body: Data("{}".utf8), nowMs: 1700000000123, deviceID: "42")
        precondition(signHeaders["x-khronos"] == "1700000000" && signHeaders["x-ss-req-ticket"] == "1700000000123" && signHeaders["x-ss-stub"]?.count == 32)
        precondition((try? PlayerSign.headers(query: "a=1", body: Data(), nowMs: 0, deviceID: "abc")) == nil)
        let singleQuery = DramaAPI.singleQuery(routeIdentity, nowMs: 1700000000123)
        precondition(singleQuery.hasPrefix("_rticket=1700000000123&ac=wifi&aid=8662&"), singleQuery)
        precondition(singleQuery.contains("&device_id=7777777777777777&") && singleQuery.contains("&iid=8888888888888888&")
            && singleQuery.contains("&resolution=1280*2772&") && singleQuery.hasSuffix("&version_code=73532&version_name=7.3.5.32"))
        precondition(!singleQuery.contains("pv_player") && !singleQuery.contains("cdid") && !singleQuery.contains("host_abi"))
        let singleModelJSON = "{\"video_id\":\"v1\",\"video_list\":[]}"
        for value in [try ProtocolJSON.object(Data(singleModelJSON.utf8)), singleModelJSON, Data(singleModelJSON.utf8).base64EncodedString()] as [Any] {
            let reply = try ProtocolJSON.data(["code":0, "data":["video_model":value]])
            precondition(DramaAPI.singleVideoModel(reply)?["video_id"] as? String == "v1")
        }
        precondition(DramaAPI.singleVideoModel(Data("{\"code\":0,\"data\":{}}".utf8)) == nil)
        precondition(DramaAPI.singleVideoModel(Data("{\"code\":100103,\"data\":{\"video_model\":{\"a\":1}}}".utf8)) == nil)
        // An inline video_list may also be an object map.
        let mapModel: [String: Any] = ["video_list":["video_1":videoRow("h264","https://v1.qznovelvod.com/map.mp4",1080).merging(["spade_a":spadeSample]) { $1 }]]
        let mapTrack = try await trackAPI.modelTrack(mapModel)
        precondition(mapTrack.url.absoluteString == "https://v1.qznovelvod.com/map.mp4")
        // The single endpoint goes first with the route identity; a usable model ends the fetch without old routes.
        let singleCalls = RouteCalls()
        let singleTrack = try await trackAPI.playbackTrack(identity: { singleCalls.identities += 1; return routeIdentity },
            single: { identity in precondition(identity.deviceID == routeIdentity.deviceID); return .model(keyedModel) },
            read: { route, _ in singleCalls.routes.append(route); return .empty }, use: { try await trackAPI.modelTrack($0) })
        precondition(singleTrack.url.absoluteString == "https://v1.qznovelvod.com/keyed.mp4" && singleCalls.routes.isEmpty && singleCalls.identities == 1)
        let singleTrace = await trackAPI.lastPlaybackTrace
        precondition(singleTrace == "S=ok", singleTrace)
        // An empty single answer falls through to the old routes in their usual order.
        let fallCalls = RouteCalls()
        let fellBack = try await trackAPI.playbackTrack(identity: { routeIdentity }, single: { _ in .empty },
            read: { route, _ in fallCalls.routes.append(route); return .model(route.post ? keyedModel : keylessModel) },
            use: { try await trackAPI.modelTrack($0) })
        precondition(fellBack.url.absoluteString == "https://v1.qznovelvod.com/keyed.mp4" && fallCalls.routes == Array(DramaAPI.playbackRoutes.prefix(2)))
        let fallTrace = await trackAPI.lastPlaybackTrace
        precondition(fallTrace == "S=0B G:b=unusable P:b=ok", fallTrace)
        // A single model that yields no track is reported ahead of empty old routes.
        do {
            _ = try await trackAPI.playbackTrack(identity: { routeIdentity }, single: { _ in .model(keylessModel) },
                read: { _, _ in .empty }, use: { try await trackAPI.modelTrack($0) })
            fatalError("Keyless single model with empty routes must not play")
        } catch { precondition(error.localizedDescription == "当前分集的播放地址或解密信息暂时不可用", error.localizedDescription) }
        // Without any model the earlier errors keep their meaning.
        do {
            _ = try await trackAPI.playbackTrack(identity: { routeIdentity }, read: { _, _ in .empty }, use: { _ in fatalError("No model") })
            fatalError("Empty answers must fail")
        } catch { precondition(error.localizedDescription.contains("空响应")) }
        do {
            _ = try await trackAPI.playbackTrack(identity: { routeIdentity }, read: { route, _ in if route.post { throw URLError(.timedOut) }; return .empty }, use: { _ in fatalError("No model") })
            fatalError("Failed reads must fail")
        } catch { precondition(error is URLError) }
        // A server rejection still ends the fetch at once.
        let rejectCalls = RouteCalls()
        do {
            _ = try await trackAPI.playbackTrack(identity: { routeIdentity }, read: { route, _ in rejectCalls.routes.append(route); throw HGError.message("当前分集暂未提供播放信息") }, use: { _ in fatalError("No model") })
            fatalError("Rejected episodes must fail")
        } catch { precondition(error.localizedDescription == "当前分集暂未提供播放信息" && rejectCalls.routes.count == 1) }
        print("PASS: video_tab playback model request and parsing.")
        print("PASS: 4 original Node signing vectors; exact 20/30-digit IDs; numeric-token parsing; binary/gzip body digest; URL spaces; cancelled query rejects before HTTP.")
    }
}

import Foundation

@main
struct AccountRulesSelfTest {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else { throw HGError.message("FAIL " + name) }
        }
        func shelf(_ json: String) throws -> [String] { try AccountRules.favoriteList(ProtocolJSON.object(Data(json.utf8))) }
        let lightShelf = try shelf(#"{"code":0,"data":{"max_bookshelf_cnt":10000,"video_shelf_info":[{"series_id":7702763145030290457,"collect_time":1762000000},{"series_id":"7702000000000000002","collect_time":1763000000},{"series_id":"bad"},{"series_id":"7702000000000000002","collect_time":1}]}}"#)
        try check(lightShelf == ["7702000000000000002","7702763145030290457"], "light-shelf-newest-first")
        let nullShelf = try shelf(#"{"code":0,"data":{"video_shelf_info":null}}"#)
        try check(nullShelf.isEmpty, "light-shelf-null-is-empty")
        try check((try? shelf(#"{"code":0,"data":null}"#)) == nil, "light-shelf-null-data-rejected")
        try check((try? shelf(#"{"code":0,"data":{"video_shelf_info":[{"series_id":"bad"}]}}"#)) == nil, "light-shelf-bad-rows-rejected")
        try check(AccountRules.reserveRefusal(code: 101144).contains("风控") && AccountRules.reserveRefusal(code: 4).contains("错误码 4"), "reserve-refusal-text")
        try check(AccountRules.businessID(true) == nil, "boolean-is-not-identity")
        try check(AccountRules.businessID(NSNumber(value: true)) == nil, "boxed-boolean-is-not-identity")
        try check(AccountRules.businessID(123.5) == nil, "float-is-not-identity")
        try check(AccountRules.businessID(["id":"123"]) == nil, "object-is-not-identity")
        try check(AccountRules.businessID("00000123") == "00000123", "leading-zero-preserved")
        try check(AccountRules.businessID("Aa+_-中123") == "Aa+_-中123", "opaque-case-preserved")
        try check(AccountRules.businessID("123\n") == nil, "control-rejected")
        try check(AccountRules.businessID(" ") == nil, "blank-rejected")
        try check(AccountRules.businessID("null") == nil, "sentinel-rejected")
        try check(!AccountRules.websiteAuthenticated(["message":"success","data":["has_login":false,"user_id":"123"]]), "anonymous-flag-veto")
        try check(!AccountRules.websiteAuthenticated(["message":"success","data":["has_login":"0","user_info":["user_id":"123"]]]), "nested-identity-anonymous-veto")
        try check(AccountRules.websiteAuthenticated(["message":"success","data":["has_login":true]]), "explicit-website-login")
        try check(AccountRules.websiteAuthenticated(["message":"success","data":["user_info":["uid_str":"000123"]]]), "nested-website-identity")
        try check(!AccountRules.websiteAuthenticated(["message":"success","data":["code":0,"device_id":"123"]]), "device-is-not-account")
        try check(!AccountRules.websiteAuthenticated(["message":"error","data":["has_login":true]]), "error-is-not-login")
        try check(AccountRules.domainMatches(cookieDomain:".hongguoduanju.com",targetHost:"hongguoduanju.com"), "domain-cookie")
        try check(!AccountRules.domainMatches(cookieDomain:"login.hongguoduanju.com",targetHost:"hongguoduanju.com"), "subdomain-cookie-stays-subdomain")
        try check(!AccountRules.domainMatches(cookieDomain:"evilhongguoduanju.com",targetHost:"hongguoduanju.com"), "suffix-confusion-rejected")
        try check(!AccountRules.domainMatches(cookieDomain:"hongguoduanju.com.evil.example",targetHost:"hongguoduanju.com"), "lookalike-host-rejected")
        try check(AccountRules.avatarURL(["avatar_url":"https://p3.example/a.jpeg"]) == "https://p3.example/a.jpeg", "avatar-plain")
        try check(AccountRules.avatarURL(["user":["avatar_thumb":["url_list":["", "http://p6.example/t.webp"]]]]) == "https://p6.example/t.webp", "avatar-url-list-upgraded")
        try check(AccountRules.avatarURL(["user_info":["avatar":"//p9.example/x.png"]]) == "https://p9.example/x.png", "avatar-scheme-relative")
        try check(AccountRules.avatarURL(["avatar_url":"javascript:alert(1)", "avatar":"file:///etc/passwd"]) == nil, "avatar-unsafe-scheme")
        try check(AccountRules.avatarURL(["avatar_url":"https://user@p3.example/a.jpeg"]) == nil, "avatar-userinfo-rejected")
        try check(AccountRules.avatarURL(["avatar_url":"https://p3.example/a b.jpeg"]) == nil && AccountRules.avatarURL(["avatar_url":true]) == nil, "avatar-malformed")
        try check(AccountRules.avatarURL(["user_name":"红果用户"]) == nil, "avatar-missing")
        try check(AccountRules.displayName(["user":["screen_name":"  果果  "]]) == "果果", "name-trimmed")
        try check(AccountRules.displayName(["name":"a\u{0}b", "user_info":["nickname":"备用"]]) == "备用", "name-control-skipped")
        try check(AccountRules.displayName(["screen_name":"", "name":123]) == nil, "name-missing")
        let liked = AccountRules.likes(["data":["mixed_data_list":[
            ["video_data":["series_id":"701","title":"甲","cover":"https:\\/\\/p\\/1.jpg","episode_cnt":80,"user_digg_timestamp_ms":2000]],
            ["video_data":["series_id":"702","title":"乙","create_time":3]],
            ["video_data":["series_id":"bad","title":"无效"]], ["other":1]]]])
        try check(liked.map(\.id) == ["702","701"] && liked[1].episodeCount == 80 && liked[1].coverURL == "https://p/1.jpg", "likes-parsed")
        let records = try AccountRules.readHistory(["data":["data_list":[
            ["book_id":"701","vid":"801","vid_index":3,"series_title":"甲","current_play_position":5000,"read_timestamp_ms":1700000000000,"episode_cnt":80],
            ["book_id":"701","vid":"800","vid_index":2,"series_title":"甲","read_timestamp_ms":1600000000000],
            ["series_id":"702","item_id":"802","vid_index":1,"last_watch_time":1700000001],
            ["book_id":"703","vid":"803","is_delete":true], ["book_id":"bad","vid":"804"]]]])
        try check(records.map(\.id) == ["702","701"] && records[1].episodeID == "801" && records[1].episodeIndex == 3 && records[1].position == 5, "read-history-newest-per-work")
        try check(records[0].updatedAt.timeIntervalSince1970 == 1700000001 && records[0].drama.title == "剧集", "read-history-seconds-and-fallback-title")
        try check((try? AccountRules.readHistory([:])) == nil, "read-history-format-rejected")
        let accountStats = AccountRules.stats(["data":["follow_user_num":1,"fans_num":2,"recv_digg_num":3]])
        try check(accountStats.follows == 1 && accountStats.fans == 2 && accountStats.likes == 3, "stats-parsed")
        try check(AccountRules.stats(["data":[:]]).follows == nil, "stats-missing")
        print("PASS account identity, website authentication, cookie scope, avatar URLs and names: 34 cases")
    }
}

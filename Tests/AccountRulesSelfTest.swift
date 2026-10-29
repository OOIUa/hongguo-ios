import Foundation

@main
struct AccountRulesSelfTest {
    static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else { throw HGError.message("FAIL " + name) }
        }
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
        print("PASS account identity, website authentication, cookie scope, avatar URLs and names: 29 cases")
    }
}

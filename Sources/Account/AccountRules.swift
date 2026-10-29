// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum AccountRules {
    static func businessID(_ raw: Any?) -> String? {
        // A boolean/number must never become an authenticated identity through string conversion.
        guard let value = raw as? String, !value.isEmpty, value.count <= 1024,
              !["0","null","undefined","none"].contains(value.lowercased()),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        return value
    }
    static func websiteAuthenticated(_ reply: [String:Any]) -> Bool {
        guard ProtocolJSON.text(reply["message"]) == "success" else { return false }
        let data = ProtocolJSON.dictionary(reply["data"])
        let nodes = [reply, data, ProtocolJSON.dictionary(data["user_info"]), ProtocolJSON.dictionary(data["user"])]
        for node in nodes {
            if let flag = node["has_login"], !ProtocolJSON.bool(flag) { return false }
        }
        return nodes.contains { row in
            ProtocolJSON.bool(row["has_login"]) || ["user_id","user_id_str","uid","uid_str","id","biz_user_id"].contains {
                businessID(row[$0]) != nil
            }
        }
    }
    /// First usable avatar in a profile reply: a plain URL string or a `{url_list: [...]}` image object.
    /// Only https (upgraded from http or scheme-relative) so ATS never blocks it and nothing else is fetched.
    static func avatarURL(_ data: [String:Any]) -> String? {
        let nodes = [data, ProtocolJSON.dictionary(data["user"]), ProtocolJSON.dictionary(data["user_info"])]
        let keys = ["avatar_url", "avatar_large_url", "avatar_large", "avatar_medium", "avatar_thumb", "avatar"]
        for node in nodes {
            for key in keys {
                let value = node[key]
                let candidates: [Any] = (value as? String).map { [$0] } ?? ProtocolJSON.array(ProtocolJSON.dictionary(value)["url_list"])
                for candidate in candidates { if let url = safeImageURL(candidate) { return url } }
            }
        }
        return nil
    }
    /// Display name from a website profile reply (`screen_name` and friends), trimmed and bounded.
    static func displayName(_ data: [String:Any]) -> String? {
        let nodes = [data, ProtocolJSON.dictionary(data["user"]), ProtocolJSON.dictionary(data["user_info"])]
        for node in nodes {
            for key in ["screen_name", "nickname", "user_name", "name"] {
                guard let raw = node[key] as? String else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, value.count <= 64, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return value }
            }
        }
        return nil
    }
    static func safeImageURL(_ raw: Any?) -> String? {
        guard var value = raw as? String, value.count <= 2048,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        else if value.lowercased().hasPrefix("http://") { value = "https://" + value.dropFirst(7) }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil else { return nil }
        return url.absoluteString
    }
    static func domainMatches(cookieDomain: String, targetHost: String) -> Bool {
        let domain = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let target = targetHost.lowercased()
        return !domain.isEmpty && (target == domain || target.hasSuffix("." + domain))
    }
}

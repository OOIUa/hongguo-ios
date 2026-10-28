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
    static func domainMatches(cookieDomain: String, targetHost: String) -> Bool {
        let domain = cookieDomain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let target = targetHost.lowercased()
        return !domain.isEmpty && (target == domain || target.hasSuffix("." + domain))
    }
}

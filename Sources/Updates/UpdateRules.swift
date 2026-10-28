// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum UpdateRoute: String, CaseIterable, Identifiable, Sendable {
    case automatic, github, ghProxy = "gh-proxy", ghfast
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "自动"; case .github: return "官方 GitHub"; case .ghProxy: return "gh-proxy"; case .ghfast: return "ghfast" }
    }
    var candidates: [UpdateRoute] { self == .automatic ? [.github, .ghProxy, .ghfast] : [self] }
    var prefix: String {
        switch self { case .ghProxy: return "https://gh-proxy.com/"; case .ghfast: return "https://ghfast.top/"; default: return "" }
    }
    var manifestURL: URL { URL(string: prefix + UpdateRules.manifestURL.absoluteString)! }
    var sourceURL: URL {
        let filename: String
        switch self { case .ghProxy: filename = "source-cn.json"; case .ghfast: filename = "source-cn-backup.json"; default: filename = "source.json" }
        return URL(string: prefix + "https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/" + filename)!
    }
}

struct UpdateManifest: Decodable, Sendable {
    let version: String
    let build: Int
    let minimumOSVersion: String
    let releaseNotes: [String]
    let publishedAt: String
    let downloadURL: String
    let sha256: String
    let size: Int
    let mirrors: [String: String]
    var officialURL: URL { URL(string: downloadURL)! } // Constructed only by UpdateRules.decode.
    func assetURL(for route: UpdateRoute) -> URL {
        if let mirror = mirrors[route.rawValue], let url = URL(string: mirror) { return url }
        return URL(string: route.prefix + downloadURL)!
    }
}

enum UpdateError: LocalizedError {
    case invalidManifest, manifestTooLarge, invalidAddress, incompatibleOS, noRelease
    case http(Int), network, tooLarge, wrongSize, wrongDigest, invalidIPA, storage
    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "更新说明格式无效，请稍后重新检查。"
        case .manifestTooLarge: return "更新说明超过大小限制，已停止读取。"
        case .invalidAddress: return "更新地址未通过校验，请使用官方更新说明。"
        case .incompatibleOS: return "这次更新需要更高版本的 iOS。"
        case .noRelease: return "请先检查并选择可用更新。"
        case .http(let status): return "更新服务暂不可用（HTTP \(status)）。"
        case .network: return "更新服务连接失败，请检查网络或切换线路后重试。"
        case .tooLarge: return "安装包超过下载大小限制，已停止下载。"
        case .wrongSize: return "安装包大小与更新说明不一致，已删除文件，请重试。"
        case .wrongDigest: return "安装包 SHA-256 校验未通过，已删除文件，请切换线路重试。"
        case .invalidIPA: return "下载内容不是有效的 IPA 文件，已删除文件。"
        case .storage: return "无法保存更新文件，请检查本机剩余空间后重试。"
        }
    }
}

enum UpdateRules {
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/OOIUa/hongguo-ios/main/distribution/update.json")!
    static let maximumManifestBytes = 64 * 1024
    static let maximumIPABytes = 512 * 1024 * 1024

    static func versionParts(_ value: String) -> [Int]? {
        guard !value.isEmpty, value.utf8.count <= 48, value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var result = [Int]()
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 12, let number = Int(piece), number >= 0 else { return nil }
            result.append(number)
        }
        return result
    }
    static func compareVersions(_ left: String, _ right: String) -> ComparisonResult? {
        guard let a = versionParts(left), let b = versionParts(right) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }
    static func isNewer(version: String, build: Int, currentVersion: String, currentBuild: Int) -> Bool {
        guard let comparison = compareVersions(version, currentVersion) else { return false }
        return comparison == .orderedDescending || (comparison == .orderedSame && build > currentBuild)
    }
    static func supports(_ minimum: String, systemVersion: String) -> Bool {
        guard let comparison = compareVersions(systemVersion, minimum) else { return false }
        return comparison != .orderedAscending
    }
    static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
    static func secureURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8192, let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443, components.fragment == nil, let host = components.host, !host.isEmpty else { return nil }
        return url
    }
    static func officialAsset(_ value: String) -> URL? {
        guard let url = secureURL(value), url.host?.lowercased() == "github.com", url.query == nil else { return nil }
        let path = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 7, path[0].isEmpty, path[1].lowercased() == "ooiua", path[2] == "hongguo-ios", path[3] == "releases", path[4] == "download",
              safeComponent(String(path[5]), maximum: 128), safeComponent(String(path[6]), maximum: 200), path[6].lowercased().hasSuffix(".ipa") else { return nil }
        return url
    }
    private static func safeComponent(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.count <= maximum && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [UInt8(45), 46, 95].contains($0)
        }
    }
    static func decode(_ bytes: Data) throws -> UpdateManifest {
        guard bytes.count <= maximumManifestBytes else { throw UpdateError.manifestTooLarge }
        let manifest: UpdateManifest
        do { manifest = try JSONDecoder().decode(UpdateManifest.self, from: bytes) } catch { throw UpdateError.invalidManifest }
        guard versionParts(manifest.version) != nil, versionParts(manifest.minimumOSVersion) != nil,
              manifest.build > 0, manifest.build <= 2_147_483_647, manifest.size > 0, manifest.size <= maximumIPABytes,
              validSHA256(manifest.sha256), manifest.releaseNotes.count <= 40,
              manifest.releaseNotes.allSatisfy({ $0.count <= 1200 }), manifest.releaseNotes.reduce(0, { $0 + $1.count }) <= 12_000,
              publicationDate(manifest.publishedAt) != nil else { throw UpdateError.invalidManifest }
        guard officialAsset(manifest.downloadURL) != nil else { throw UpdateError.invalidAddress }
        for (key, value) in manifest.mirrors {
            guard let route = UpdateRoute(rawValue: key), [.ghProxy, .ghfast].contains(route),
                  secureURL(value) != nil, value == route.prefix + manifest.downloadURL else { throw UpdateError.invalidAddress }
        }
        return manifest
    }
    static func publicationDate(_ value: String) -> Date? {
        guard value.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func allowsManifestRedirect(_ target: URL, initial: URL) -> Bool {
        secureURL(target.absoluteString) != nil && [UpdateRoute.github, .ghProxy, .ghfast].contains(where: { $0.manifestURL.absoluteString == initial.absoluteString }) && target.absoluteString == initial.absoluteString
    }
    static func allowsAssetRedirect(_ target: URL, initial: URL, official: URL) -> Bool {
        guard secureURL(target.absoluteString) != nil, officialAsset(official.absoluteString) != nil,
              [UpdateRoute.github, .ghProxy, .ghfast].contains(where: { $0.prefix + official.absoluteString == initial.absoluteString }) else { return false }
        if target.absoluteString == initial.absoluteString || target.absoluteString == official.absoluteString { return true }
        // GitHub release downloads redirect to its signed asset CDN; only a trusted original asset may begin this transfer.
        return ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(target.host?.lowercased() ?? "")
    }
    static func hasZIPHeader(_ bytes: Data) -> Bool { bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) }
}

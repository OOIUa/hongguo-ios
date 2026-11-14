// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only recent series IDs and hashed owner keys are stored; no cookies, profiles or server sessions.
actor RecommendationHistory {
    static let shared = RecommendationHistory()
    static let limit = 540
    private struct Record: Codable { var ids: [String]; var updatedAt: Date }
    private var records: [String: Record] = [:]
    private let file: URL
    private var writable = true

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hongguo", isDirectory: true)
        file = root.appendingPathComponent("recommendations-v1.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 2 * 1024 * 1024 else { throw HGError.message("推荐记录过大") }
            records = try JSONDecoder().decode([String: Record].self, from: bytes)
        } catch { writable = false } // An unreadable cache must not overwrite its original file.
    }

    func recent(for owner: String) -> [String] { Self.normalized(records[key(owner)]?.ids ?? []) }

    func remember(_ ids: [String], for owner: String) {
        let ownerKey = key(owner)
        records[ownerKey] = Record(ids: Self.normalized((records[ownerKey]?.ids ?? []) + ids), updatedAt: Date())
        if records.count > 8 {
            let keep = Set(records.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(8).map(\.key))
            records = records.filter { keep.contains($0.key) }
        }
        guard writable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: file, options: .atomic)
            var location = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? location.setResourceValues(values)
        } catch { } // Recommendations still work when this optional recent-ID cache cannot be saved.
    }

    private func key(_ owner: String) -> String { HGCrypto.sha256(Data(owner.utf8)).hexString }
    static func normalized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return Array(ids.reversed().filter { ProtocolJSON.identifier($0) != nil && seen.insert($0).inserted }
            .prefix(limit).reversed())
    }
}

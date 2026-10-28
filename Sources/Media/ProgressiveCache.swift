// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// Verified, reusable encrypted ranges. A partial movie is never mistaken for a complete MP4.
actor ProgressiveCache {
    static let shared = ProgressiveCache()
    static let blockSize = 256 * 1024
    private let root: URL
    private let limit: Int
    private var leases: [String: Int] = [:]
    private let fm = FileManager.default

    init(root: URL? = nil, limit: Int = MP4Processor.maximumBytes) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProgressiveMedia-v1", isDirectory: true)
        self.limit = limit
    }
    func acquire(_ key: String) { leases[key, default: 0] += 1 }
    func release(_ key: String) {
        let value = leases[key, default: 0] - 1
        if value <= 0 { leases.removeValue(forKey: key) } else { leases[key] = value }
    }
    func read(key: String, block: Int, expected: Int) -> Data? {
        guard valid(key), block >= 0, expected > 0, expected <= Self.blockSize else { return nil }
        let folder = root.appendingPathComponent(key), file = folder.appendingPathComponent("\(block).chunk")
        guard let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
              size.intValue == expected + 32, let envelope = try? Data(contentsOf: file),
              envelope.count == expected + 32 else { try? fm.removeItem(at: file); return nil }
        let bytes = Data(envelope.dropFirst(32))
        guard Data(SHA256.hash(data: bytes)) == envelope.prefix(32) else { try? fm.removeItem(at: file); return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
        return bytes
    }
    func store(_ bytes: Data, key: String, block: Int) throws {
        guard valid(key), block >= 0, !bytes.isEmpty, bytes.count <= Self.blockSize else { throw MediaError.invalidMedia }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(block).chunk")
        let directories = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        var used = 0
        var sizes: [(URL, Int, Date)] = []
        for directory in directories {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let size = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            used += size
            sizes.append((directory, size, (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        let existing = ((try? fm.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue ?? 0
        let needed = bytes.count + 32 - existing
        for (directory, size, _) in sizes.sorted(by: { $0.2 < $1.2 }) where used + needed > limit {
            guard directory != folder, leases[directory.lastPathComponent, default: 0] == 0 else { continue }
            try fm.removeItem(at: directory); used -= size
        }
        // Streaming can continue from memory when every cache directory is in use.
        guard used + needed <= limit else { return }
        try (Data(SHA256.hash(data: bytes)) + bytes).write(to: file, options: .atomic)
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
    }
    func clear() throws {
        guard fm.fileExists(atPath: root.path) else { return }
        for folder in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where leases[folder.lastPathComponent, default: 0] == 0 {
            try fm.removeItem(at: folder)
        }
    }
    private func valid(_ key: String) -> Bool { key.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

// SPDX-License-Identifier: GPL-3.0-only
// Offline tests use isolated temporary directories and synthetic identities/content only.
import Foundation
import zlib

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}
private func expect(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    if !condition() { throw TestFailure(description: description) }
}
private func fixtureDrama(_ number: Int) -> Drama {
    Drama(id: "18446744073709\(String(format: "%06d", number))", title: "合成剧集 \(number)",
          coverURL: "https://example.invalid/cover-\(number)", summary: "离线测试简介", episodeCount: 12)
}
private func fixtureEpisode(_ number: Int = 1) -> Episode {
    Episode(id: "18446744073700\(String(format: "%06d", number))", index: number, title: "第 \(number) 集")
}

@main struct LibrarySelfTest {
    @MainActor static func main() {
        do {
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--read-persistence" {
                try checkChildPersistence(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
                return
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-library-selftest-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try persistenceAndRealProgress(root.appendingPathComponent("persistence"))
            try listIndependenceAndLateCallbacks(root.appendingPathComponent("independence"))
            try boundedLists(root.appendingPathComponent("bounded"))
            try corruptFiles(root.appendingPathComponent("corrupt"))
            try cryptoVectorsAndRoundTrips()
            print("PASS: LibraryStore record/update and cross-process persistence; deleted/cleared history and favorites stay deleted after stale position callbacks; independent lists; 200-item bounds; corrupt files remain intact without crash; NIST AES-CTR/CBC vectors; CBC and gzip round trips.")
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor private static func persistenceAndRealProgress(_ root: URL) throws {
        let store = LibraryStore(directory: root), drama = fixtureDrama(1), episode = fixtureEpisode(3)
        try expect(store.favorites.isEmpty && store.history.isEmpty && store.storageError == nil, "New library should be empty")
        store.toggleFavorite(drama)
        try expect(store.isFavorite(drama) && store.history.isEmpty, "Favoriting must not invent playback history")
        store.record(drama: drama, episode: episode, position: 1.5)
        store.updatePosition(dramaID: drama.id, episodeID: episode.id, position: 47.25)
        store.flush()
        try expect(store.history.count == 1 && store.favorites.count == 1, "Record updates both existing favorite and history")
        try expect(store.history[0].position == 47.25 && store.favorites[0].position == 47.25, "Latest real playback position must reach both lists")
        try expect(store.history[0].episodeID == episode.id && store.history[0].episodeIndex == 3, "Episode ID/index must be exact")
        let restarted = LibraryStore(directory: root)
        try expect(restarted.storageError == nil, "Reload should succeed")
        try expect(restarted.favorites == store.favorites && restarted.history == store.history, "Recreated store must preserve complete records and large string IDs")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--read-persistence", root.path]
        try child.run(); child.waitUntilExit()
        try expect(child.terminationStatus == 0, "Separate process could not read persisted library")
        // A delayed update from a former episode must not change the newly selected episode.
        let next = fixtureEpisode(4)
        store.record(drama: drama, episode: next, position: 9)
        store.updatePosition(dramaID: drama.id, episodeID: episode.id, position: 999)
        try expect(store.history[0].episodeID == next.id && store.history[0].position == 9, "Stale previous-episode position callback changed active history")
        try expect(store.favorites[0].episodeID == next.id && store.favorites[0].position == 9, "Stale previous-episode callback changed favorite progress")
        store.updatePosition(dramaID: drama.id, episodeID: next.id, position: .nan)
        store.updatePosition(dramaID: drama.id, episodeID: next.id, position: .infinity)
        store.updatePosition(dramaID: drama.id, episodeID: next.id, position: -1)
        try expect(store.history[0].position == 9, "Non-finite and negative positions must be rejected")
        store.flush()
    }

    @MainActor private static func checkChildPersistence(directory: URL) throws {
        let store = LibraryStore(directory: directory), drama = fixtureDrama(1), episode = fixtureEpisode(3)
        try expect(store.storageError == nil && store.history.count == 1 && store.favorites.count == 1, "Child must load both lists")
        try expect(store.history[0].drama == drama && store.history[0].episodeID == episode.id && store.history[0].position == 47.25,
                   "Child must preserve IDs, metadata, episode and latest playback position")
        try expect(store.favorites[0] == store.history[0], "Favorite and history must carry matching persisted progress")
    }

    @MainActor private static func listIndependenceAndLateCallbacks(_ root: URL) throws {
        let store = LibraryStore(directory: root), a = fixtureDrama(10), b = fixtureDrama(11), episode = fixtureEpisode(2)
        store.toggleFavorite(a); store.record(drama: a, episode: episode, position: 10)
        store.removeHistory(id: a.id)
        store.updatePosition(dramaID: a.id, episodeID: episode.id, position: 20)
        try expect(store.history.isEmpty, "Removed history must not be resurrected by a late position callback")
        try expect(store.isFavorite(a) && store.favorites[0].position == 20, "History deletion must preserve independent favorite progress")
        store.record(drama: a, episode: episode, position: 30); store.removeFavorite(id: a.id)
        store.updatePosition(dramaID: a.id, episodeID: episode.id, position: 40)
        try expect(store.favorites.isEmpty && store.history[0].position == 40, "Removed favorite must stay removed while history advances")
        store.toggleFavorite(a); store.toggleFavorite(b); store.record(drama: b, episode: episode, position: 50)
        store.clearHistory()
        store.updatePosition(dramaID: a.id, episodeID: episode.id, position: 60)
        store.updatePosition(dramaID: b.id, episodeID: episode.id, position: 70)
        try expect(store.history.isEmpty && store.favorites.count == 2, "Clear history must not clear favorites or permit stale insertion")
        store.record(drama: a, episode: episode, position: 80)
        store.clearFavorites()
        store.updatePosition(dramaID: a.id, episodeID: episode.id, position: 90)
        try expect(store.favorites.isEmpty && store.history.count == 1 && store.history[0].position == 90,
                   "Clear favorites must preserve independent history and reject stale favorite insertion")
        store.clearHistory()
        store.updatePosition(dramaID: a.id, episodeID: episode.id, position: 100)
        store.updatePosition(dramaID: b.id, episodeID: episode.id, position: 110)
        store.flush()
        let restarted = LibraryStore(directory: root)
        try expect(restarted.history.isEmpty && restarted.favorites.isEmpty, "Cleared lists must remain empty after callbacks, flush and restart")
        try expect(restarted.progress(for: a.id) == nil, "Removed entry must not be available through progress fallback")
    }

    @MainActor private static func boundedLists(_ root: URL) throws {
        let store = LibraryStore(directory: root), episode = fixtureEpisode()
        for i in 0..<215 {
            let drama = fixtureDrama(1000 + i)
            store.toggleFavorite(drama)
            store.record(drama: drama, episode: episode, position: Double(i))
        }
        store.flush()
        try expect(store.favorites.count == 200 && store.history.count == 200, "Both lists must cap at 200")
        try expect(!store.favorites.contains { $0.id == fixtureDrama(1000).id } && !store.history.contains { $0.id == fixtureDrama(1000).id }, "Oldest records must be evicted")
        try expect(store.history.first?.id == fixtureDrama(1214).id && store.favorites.first?.id == fixtureDrama(1214).id, "Newest records must survive eviction")
        let newest = fixtureDrama(1214)
        store.record(drama: newest, episode: fixtureEpisode(5), position: 123)
        try expect(store.history.filter { $0.id == newest.id }.count == 1, "Recording an existing series must not duplicate it")
        store.toggleFavorite(newest); store.toggleFavorite(newest); store.flush()
        try expect(store.favorites.filter { $0.id == newest.id }.count == 1 && store.favorites.count == 200, "Favorite toggles must remain unique and bounded")
        let restarted = LibraryStore(directory: root)
        try expect(restarted.favorites.count == 200 && restarted.history.count == 200 && restarted.progress(for: newest.id)?.position == 123,
                   "Restart must preserve bounded normalized lists and most recent progress")
    }

    @MainActor private static func corruptFiles(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library-v1.json")
        for bytes in [Data("{broken-json".utf8), Data("{\"version\":1,\"favorites\":null,\"history\":[]}".utf8), Data(repeating: 65, count: 4 * 1024 * 1024 + 1)] {
            try bytes.write(to: url)
            let store = LibraryStore(directory: root)
            try expect(store.favorites.isEmpty && store.history.isEmpty && store.storageError != nil, "Corrupt or oversized library should fail closed without a crash")
            let preserved = try Data(contentsOf: url)
            try expect(preserved == bytes, "Original corrupt file must remain available for recovery")
        }
        // Exercise normalization of duplicate IDs and invalid negative positions on load.
        let valid = LibraryEntry(drama: fixtureDrama(4000), episodeID: fixtureEpisode().id, episodeIndex: 1, position: 3, updatedAt: Date(timeIntervalSince1970: 30))
        var duplicate = valid; duplicate.position = 1; duplicate.updatedAt = Date(timeIntervalSince1970: 10)
        var negative = LibraryEntry(drama: fixtureDrama(4001), episodeID: fixtureEpisode().id, episodeIndex: 1, position: -1, updatedAt: Date())
        negative.position = -1
        struct Snapshot: Encodable { let version = 1; let favorites: [LibraryEntry]; let history: [LibraryEntry] }
        try JSONEncoder().encode(Snapshot(favorites: [duplicate, negative, valid], history: [duplicate, valid])).write(to: url)
        let normalized = LibraryStore(directory: root)
        try expect(normalized.storageError == nil && normalized.favorites.count == 1 && normalized.history.count == 1 && normalized.history[0].position == 3,
                   "Persisted duplicate/invalid entries must normalize to the latest valid record")
    }

    private static func cryptoVectorsAndRoundTrips() throws {
        // NIST SP 800-38A, F.5.1 AES-128 CTR (all four blocks).
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!
        let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")!
        let plain = Data(hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")!
        let expected = Data(hex: "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee")!
        let cipher = try HGCrypto.aesCTR(plain, key: key, iv: iv)
        try expect(cipher == expected, "AES-CTR must match all four NIST blocks")
        let restored = try HGCrypto.aesCTR(cipher, key: key, iv: iv)
        try expect(restored == plain, "CTR decrypt must restore plaintext")
        // NIST SP 800-38A F.2.1 first AES-128 CBC block, with padding explicitly disabled.
        let cbcIV = Data(hex: "000102030405060708090a0b0c0d0e0f")!
        let cbc = try HGCrypto.aesCBCEncrypt(Data(plain.prefix(16)), key: key, iv: cbcIV, padding: false)
        try expect(cbc.hexString == "7649abac8119b246cee98e9b12e9197d", "AES-CBC must match NIST")
        for length in [0, 1, 15, 16, 17, 257] {
            let input = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 37) })
            let encrypted = try HGCrypto.aesCBCEncrypt(input, key: key, iv: cbcIV)
            let decrypted = try HGCrypto.aesCBCDecrypt(encrypted, key: key, iv: cbcIV)
            try expect(decrypted == input && encrypted.count % 16 == 0 && !encrypted.isEmpty, "CBC PKCS7 round trip failed at length \(length)")
        }
        do { _ = try HGCrypto.aesCTR(plain, key: Data(repeating: 0, count: 15), iv: iv); throw TestFailure(description: "Invalid CTR key was accepted") }
        catch is HGError { }
        for input in [Data(), Data("红果离线 gzip 回归测试".utf8), Data(repeating: 42, count: 100_000)] {
            let compressed = try HGCrypto.gzip(input)
            try expect(Array(compressed.prefix(2)) == [0x1f, 0x8b], "gzip header missing")
            let uncompressed = try gunzip(compressed)
            try expect(uncompressed == input, "gzip round trip changed payload")
        }
    }

    private static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TestFailure(description: "Test gzip decoder initialization failed")
        }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var status: Int32 = Z_OK
            repeat {
                status = buffer.withUnsafeMutableBytes { chunk in
                    stream.next_out = chunk.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunk.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw TestFailure(description: "Test gzip decoder rejected compressed payload") }
                output.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                guard output.count <= 1024 * 1024 else { throw TestFailure(description: "Test gzip fixture unexpectedly exceeded limit") }
            } while status != Z_STREAM_END
            return output
        }
    }
}

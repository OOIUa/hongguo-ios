// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()
    @Published private(set) var favorites: [LibraryEntry] = []
    @Published private(set) var history: [LibraryEntry] = []
    @Published private(set) var storageError: String?
    private let fileURL: URL
    private var lastWrite = Date.distantPast

    private struct Snapshot: Codable {
        var version: Int = 1
        var favorites: [LibraryEntry]
        var history: [LibraryEntry]
    }

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hongguo", isDirectory: true)
        fileURL = root.appendingPathComponent("library-v1.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                guard data.count <= 4 * 1024 * 1024 else { throw HGError.message("本机片单文件过大") }
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                favorites = normalized(snapshot.favorites)
                history = normalized(snapshot.history)
            }
        } catch {
            storageError = "本机片单读取失败，原文件已保留。"
        }
    }

    func isFavorite(_ drama: Drama) -> Bool { favorites.contains { $0.id == drama.id } }

    func toggleFavorite(_ drama: Drama) {
        if isFavorite(drama) { favorites.removeAll { $0.id == drama.id } }
        else {
            let old = progress(for: drama.id)
            favorites.insert(LibraryEntry(drama: drama, episodeID: old?.episodeID ?? "", episodeIndex: old?.episodeIndex ?? 1,
                                          position: old?.position ?? 0, updatedAt: Date()), at: 0)
            favorites = normalized(favorites)
        }
        save()
    }

    /// Called only after the playback view confirms a rendered frame.
    func record(drama: Drama, episode: Episode, position: Double) {
        guard !drama.id.isEmpty, !episode.id.isEmpty, position.isFinite else { return }
        let entry = LibraryEntry(drama: drama, episodeID: episode.id, episodeIndex: episode.index,
                                 position: max(0, position), updatedAt: Date())
        history.removeAll { $0.id == drama.id }
        history.insert(entry, at: 0)
        history = normalized(history)
        if let index = favorites.firstIndex(where: { $0.id == drama.id }) { favorites[index] = entry }
        if Date().timeIntervalSince(lastWrite) >= 2 { save() }
    }

    func progress(for dramaID: String) -> LibraryEntry? {
        history.first { $0.id == dramaID } ?? favorites.first { $0.id == dramaID }
    }
    func updatePosition(dramaID: String, episodeID: String, position: Double) {
        guard position.isFinite, position >= 0 else { return }
        if let index = history.firstIndex(where: { $0.id == dramaID && $0.episodeID == episodeID }) {
            history[index].position = position
        }
        if let index = favorites.firstIndex(where: { $0.id == dramaID && $0.episodeID == episodeID }) {
            favorites[index].position = position
        }
        if Date().timeIntervalSince(lastWrite) >= 2 { save() }
    }
    func removeHistory(id: String) { history.removeAll { $0.id == id }; save() }
    func removeFavorite(id: String) { favorites.removeAll { $0.id == id }; save() }
    func clearHistory() { history.removeAll(); save() }
    func clearFavorites() { favorites.removeAll(); save() }
    func flush() { save() }

    private func normalized(_ values: [LibraryEntry]) -> [LibraryEntry] {
        var seen = Set<String>()
        return Array(values.sorted { $0.updatedAt > $1.updatedAt }.filter {
            !$0.id.isEmpty && $0.id.count <= 128 && $0.position.isFinite && $0.position >= 0 && seen.insert($0.id).inserted
        }.prefix(200))
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Snapshot(favorites: favorites, history: history))
            try data.write(to: fileURL, options: .atomic)
            lastWrite = Date()
            storageError = nil
        } catch { storageError = "本机记录暂未保存，请检查剩余存储空间。" }
    }
}

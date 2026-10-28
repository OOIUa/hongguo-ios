// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct Drama: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let coverURL: String
    let summary: String
    let episodeCount: Int
}

struct Episode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let index: Int
    let title: String
}

struct DramaDetail: Sendable {
    let drama: Drama
    let episodes: [Episode]
}

struct DramaPage: Sendable {
    let dramas: [Drama]
    let hasMore: Bool
    let nextOffset: Int
}

struct VideoTrack: Sendable {
    let url: URL
    let spadeA: String
    let encrypted: Bool
    let definition: String
}

struct FilterOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct FilterGroup: Identifiable, Sendable {
    let id: String
    let name: String
    let options: [FilterOption]
}

enum HGError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

struct LibraryEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { drama.id }
    let drama: Drama
    var episodeID: String
    var episodeIndex: Int
    var position: Double
    var updatedAt: Date
}

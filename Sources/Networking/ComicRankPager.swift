// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct ComicRankBatch: Sendable { let dramas: [Drama]; let hasMore: Bool }

/// cell/change ignores offset. Continue with filter_ids and keep a bounded, deduplicated round.
/// Adapted from sunnysky123/hongguo-web 1b00f06 (2026-11-13, MIT).
actor ComicRankPager {
    private let fetch: @Sendable ([String]) async throws -> ComicRankBatch
    private var rows: [Drama] = []
    private var hasMore = true

    init(fetch: @escaping @Sendable ([String]) async throws -> ComicRankBatch) { self.fetch = fetch }

    func page(offset: Int) async throws -> DramaPage {
        guard (0...600).contains(offset), offset <= rows.count else { throw HGError.message("漫剧榜单分页已变化，请刷新") }
        let target = offset + 18
        for _ in 0..<3 {
            if rows.count >= target || !hasMore { break }
            try Task.checkCancellation()
            let batch = try await fetch(Array(rows.suffix(200).map(\.id)))
            try Task.checkCancellation()
            var known = Set(rows.map(\.id))
            let fresh = batch.dramas.filter { known.insert($0.id).inserted }
            rows += fresh
            hasMore = batch.hasMore && !fresh.isEmpty && rows.count <= 600
        }
        let result = Array(rows.dropFirst(offset).prefix(18)), next = offset + result.count
        return DramaPage(dramas: result, hasMore: next < rows.count || hasMore, nextOffset: next)
    }
}

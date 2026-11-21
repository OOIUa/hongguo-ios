// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android 0.7.32 (PR #13), danmaku/DanmakuLoader.kt.
import Foundation

/// Buffers official comments for one episode ahead of the playback position. Call loadUpTo from a
/// background task as playback advances (it is cheap and re-entrant); read visible comments with
/// between(fromMs:toMs:) from the UI. Failures back off silently — comments are a decoration and
/// must never interrupt playback.
final class DanmakuLoader: @unchecked Sendable {
    private let repository: DanmakuRepository
    private let seriesID: String
    private let vid: String
    private let leadMs: Int64
    private let clock: @Sendable () -> TimeInterval
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var comments: [Danmaku] = []
    private var seen = Set<String>()
    private var loading = false
    private var frontier: Int64 = 0
    private var exhausted = false
    private var failures = 0
    private var retryAfter: TimeInterval = 0
    /// Set from the host whenever the episode duration becomes known.
    var durationMs: Int64

    init(repository: DanmakuRepository, seriesID: String, vid: String, durationMs: Int64,
         leadMs: Int64 = 60_000, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         onFailure: @escaping @Sendable (Error) -> Void = { _ in }) {
        self.repository = repository
        self.seriesID = seriesID
        self.vid = vid
        self.durationMs = durationMs
        self.leadMs = leadMs
        self.clock = clock
        self.sleeper = sleeper
        self.onFailure = onFailure
    }

    /// Fetch windows until buffered past positionMs + lead. No-op while another load runs.
    func loadUpTo(_ positionMs: Int64) async {
        guard durationMs > 0 else { return }
        lock.lock()
        if loading { lock.unlock(); return }
        loading = true
        lock.unlock()
        defer { lock.lock(); loading = false; lock.unlock() }
        while true {
            let start = lock.withLock { () -> Int64? in
                if exhausted || clock() < retryAfter { return nil }
                if frontier >= durationMs { exhausted = true; return nil }
                if positionMs > frontier {
                    // A forward seek skips windows that will never be watched.
                    frontier = positionMs / DanmakuRepository.windowMs * DanmakuRepository.windowMs
                    if frontier > positionMs + leadMs { return nil }
                } else if frontier > positionMs + leadMs { return nil }
                return frontier
            }
            guard let start else { return }
            let window: DanmakuWindow
            do {
                window = try await repository.window(seriesID: seriesID, vid: vid, durationMs: durationMs, startMs: start)
            } catch {
                lock.withLock {
                    failures += 1
                    // Back off instead of retrying in a tight loop: the first request can trip
                    // risk control and a retry a second later usually goes through. Ten consecutive
                    // failures mean something is really wrong, so stop instead of hammering the API.
                    retryAfter = clock() + Self.backoffSeconds(failures)
                    if failures >= Self.maxFailures { exhausted = true }
                }
                onFailure(error)
                return
            }
            lock.withLock {
                failures = 0
                for comment in window.comments {
                    let key = comment.id.isEmpty ? "anonymous:\(comment.offsetMs):\(comment.text)" : "id:\(comment.id)"
                    if seen.insert(key).inserted { comments.append(comment) }
                }
                // Windows normally arrive in order; a forward seek can interleave offsets.
                if comments.count > 1, comments[comments.count - 2].offsetMs > comments[comments.count - 1].offsetMs {
                    comments.sort { $0.offsetMs < $1.offsetMs }
                }
                frontier = window.nextStartMs > start ? window.nextStartMs : start + DanmakuRepository.windowMs
                if frontier >= durationMs { exhausted = true }
            }
        }
    }

    /// Comments anchored in [fromMs, toMs); the list is sorted by offset. Callable from any thread.
    func between(fromMs: Int64, toMs: Int64) -> [Danmaku] {
        lock.withLock {
            guard fromMs < toMs, !comments.isEmpty else { return [] }
            return comments.filter { $0.offsetMs >= fromMs && $0.offsetMs < toMs }
        }
    }

    /// Total distinct comments buffered so far; mainly for diagnostics and tests.
    var buffered: Int { lock.withLock { comments.count } }

    private static let maxFailures = 10
    /// 1 s, 4 s, then 15 s for every further consecutive failure.
    static func backoffSeconds(_ failures: Int) -> TimeInterval {
        switch failures { case ...1: return 1; case 2: return 4; default: return 15 }
    }
}

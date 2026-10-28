// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit

/// A random-access clear MP4 view over verified encrypted HTTP ranges.
actor ProgressiveSource {
    typealias Fetch = @Sendable (Range<Int>) async throws -> MediaRangeReply
    struct Metrics: Sendable { let length: Int; let networkBytes: Int; let availableBytes: Int }
    private struct Pending { let id: UUID; let task: Task<Data, Error> }
    private let fetch: Fetch
    private let cache: ProgressiveCache
    private let progress: @Sendable (String, Double) -> Void
    private var cacheKey: String?
    private var plan: MP4Processor.StreamPlan?
    private var memory: [Int: Data] = [:]
    private var order: [Int] = []
    private var pending: [Int: Pending] = [:]
    private var available: Set<Int> = []
    private var sampleMemory: [Int: Data] = [:]
    private var sampleOrder: [Int] = []
    private var paused = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var closed = false
    private var length = 0
    private var networkBytes = 0

    private init(cache: ProgressiveCache, fetch: @escaping Fetch, progress: @Sendable @escaping (String, Double) -> Void) {
        self.cache = cache; self.fetch = fetch; self.progress = progress
    }
    static func open(track: VideoTrack, episodeID: String, cache: ProgressiveCache = .shared,
                     fetch: Fetch? = nil, progress: @Sendable @escaping (String, Double) -> Void = { _, _ in }) async throws -> ProgressiveSource {
        guard !episodeID.isEmpty, episodeID.count <= 64, MediaRangeHTTP.allowed(track.url) else { throw MediaError.unavailable }
        let provider: Fetch = fetch ?? { range in try await MediaRangeHTTP.fetch(track.url, range: range) }
        let source = ProgressiveSource(cache: cache, fetch: provider, progress: progress)
        return try await withTaskCancellationHandler(operation: {
            do {
                try await source.initialize(track: track, episodeID: episodeID)
                try Task.checkCancellation()
                return source
            } catch { await source.close(); throw error }
        }, onCancel: { Task { await source.close() } })
    }
    private func initialize(track: VideoTrack, episodeID: String) async throws {
        progress("正在读取视频索引", 0)
        let first = try await fetch(0..<ProgressiveCache.blockSize)
        try Task.checkCancellation()
        guard first.total >= 16, first.total <= MP4Processor.maximumBytes,
              first.data.count == min(first.total, ProgressiveCache.blockSize) else { throw MediaError.invalidMedia }
        length = first.total; networkBytes = first.data.count
        remember(first.data, block: 0); available.insert(0)
        var at = 0, count = 0, moovOffset: Int?, moov = Data(), media: [Range<Int>] = [], pssh: [Int] = []
        while at < length {
            try Task.checkCancellation(); count += 1
            guard count <= 4096, length - at >= 8 else { throw MediaError.invalidMedia }
            let header = try await raw(at: at, count: min(16, length - at))
            var size = try integer(header, at: 0, width: 4), width = 8
            if size == 1 { size = try integer(header, at: 8, width: 8); width = 16 }
            else if size == 0 { size = length - at }
            guard size >= width, size <= length - at else { throw MediaError.invalidMedia }
            let type = String(data: header.subdata(in: 4..<8), encoding: .isoLatin1) ?? ""
            if at == 0 && type != "ftyp" { throw MediaError.invalidMedia }
            if ["moof", "mfra", "sidx"].contains(type) { throw MediaError.unsupported }
            if type == "moov" {
                guard moovOffset == nil, size <= 32 * 1024 * 1024 else { throw MediaError.invalidMedia }
                moovOffset = at; moov = try await raw(at: at, count: size)
            } else if type == "mdat" { media.append((at + width)..<(at + size)) }
            else if type == "pssh" { pssh.append(at) }
            at += size
        }
        guard let moovOffset else { throw MediaError.invalidMedia }
        let descriptor = try MP4Processor.streamPlan(length: length, moovOffset: moovOffset, moov: moov,
            media: media, psshOffsets: pssh, encrypted: track.encrypted, spade: track.spadeA)
        let identity = Data((episodeID + ":" + track.definition + ":" + String(length) + ":" + track.spadeA).utf8) + moov + Data(SHA256.hash(data: first.data))
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        await cache.acquire(key)
        guard !closed else { await cache.release(key); throw CancellationError() }
        cacheKey = key
        try Task.checkCancellation()
        for (index, bytes) in memory { try? await cache.store(bytes, key: key, block: index) }
        plan = descriptor
        if let probe = descriptor.probe, let key = descriptor.key {
            let cipher = try await raw(at: probe.offset, count: probe.size)
            let plain = try HGCrypto.aesCTR(cipher, key: key, iv: probe.iv)
            try MP4Processor.validateStreamProbe(plain, plan: descriptor)
        }
        report()
    }
    func metrics() -> Metrics {
        let bytes = available.reduce(0) { $0 + min(ProgressiveCache.blockSize, length - $1 * ProgressiveCache.blockSize) }
        return Metrics(length: length, networkBytes: networkBytes, availableBytes: bytes)
    }
    func read(at offset: Int, count: Int) async throws -> Data {
        try await waitUntilResumed()
        guard !closed, let plan, offset >= 0, count >= 0, count <= ProgressiveCache.blockSize,
              offset <= length, count <= length - offset else { throw MediaError.invalidMedia }
        if count == 0 { return Data() }
        var output = try await raw(at: offset, count: count)
        let end = offset + count
        if let key = plan.key {
            var low = 0, high = plan.samples.count
            while low < high {
                let middle = (low + high) / 2, sample = plan.samples[middle]
                if sample.offset + sample.size <= offset { low = middle + 1 } else { high = middle }
            }
            var index = low
            while index < plan.samples.count && plan.samples[index].offset < end {
                try Task.checkCancellation()
                let sample = plan.samples[index]
                let plain: Data
                if let cached = sampleMemory[sample.offset] { plain = cached }
                else {
                    let cipher = try await raw(at: sample.offset, count: sample.size)
                    plain = try HGCrypto.aesCTR(cipher, key: key, iv: sample.iv)
                    sampleMemory[sample.offset] = plain; sampleOrder.append(sample.offset)
                    var used = sampleMemory.values.reduce(0) { $0 + $1.count }
                    while used > 8 * 1024 * 1024 && sampleOrder.count > 1 {
                        let oldest = sampleOrder.removeFirst(); used -= sampleMemory.removeValue(forKey: oldest)?.count ?? 0
                    }
                }
                let start = max(offset, sample.offset), stop = min(end, sample.offset + sample.size)
                output.replaceSubrange((start - offset)..<(stop - offset), with: plain.subdata(in: (start - sample.offset)..<(stop - sample.offset)))
                index += 1
            }
        }
        for patch in plan.patches {
            let start = max(offset, patch.offset), stop = min(end, patch.offset + patch.data.count)
            if start < stop {
                output.replaceSubrange((start - offset)..<(stop - offset), with: patch.data.subdata(in: (start - patch.offset)..<(stop - patch.offset)))
            }
        }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return output
    }
    private func raw(at offset: Int, count: Int) async throws -> Data {
        guard offset >= 0, count >= 0, offset <= length, count <= length - offset else { throw MediaError.invalidMedia }
        var output = Data(); output.reserveCapacity(count)
        var position = offset
        while position < offset + count {
            try await waitUntilResumed()
            let index = position / ProgressiveCache.blockSize
            let bytes = try await block(index)
            let local = position % ProgressiveCache.blockSize, amount = min(bytes.count - local, offset + count - position)
            guard amount > 0 else { throw MediaError.invalidMedia }
            output.append(bytes.subdata(in: local..<(local + amount))); position += amount
        }
        return output
    }
    private func block(_ index: Int) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let data = memory[index] { return data }
        let start = index * ProgressiveCache.blockSize, end = min(start + ProgressiveCache.blockSize, length)
        guard start >= 0, start < end else { throw MediaError.invalidMedia }
        if let key = cacheKey, let data = await cache.read(key: key, block: index, expected: end - start) {
            guard !closed else { throw CancellationError() }
            remember(data, block: index); available.insert(index); report(); return data
        }
        let loading: Pending
        if let existing = pending[index] { loading = existing }
        else {
            let provider = fetch, expectedLength = length
            let identifier = UUID()
            let task = Task {
                do {
                    let reply = try await provider(start..<end)
                    try Task.checkCancellation()
                    guard reply.total == expectedLength, reply.data.count == end - start else { throw MediaError.invalidMedia }
                    try await self.completed(reply.data, block: index, identifier: identifier)
                    return reply.data
                } catch {
                    if self.pending[index]?.id == identifier { self.pending.removeValue(forKey: index) }
                    throw error
                }
            }
            loading = Pending(id: identifier, task: task); pending[index] = loading
        }
        let data = try await loading.task.value
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return data
    }
    private func completed(_ data: Data, block: Int, identifier: UUID) async throws {
        guard !closed, pending[block]?.id == identifier else { throw CancellationError() }
        pending.removeValue(forKey: block); networkBytes += data.count
        remember(data, block: block); available.insert(block); report()
        if let key = cacheKey { try? await cache.store(data, key: key, block: block) }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }
    private func remember(_ data: Data, block: Int) {
        memory[block] = data; order.removeAll { $0 == block }; order.append(block)
        while order.count > 16 { memory.removeValue(forKey: order.removeFirst()) }
    }
    private func report() { let value = metrics(); progress("边下边播", min(1, Double(value.availableBytes) / Double(max(1, length)))) }
    private func integer(_ bytes: Data, at: Int, width: Int) throws -> Int {
        guard at >= 0, width <= bytes.count - at else { throw MediaError.invalidMedia }
        var value: UInt64 = 0
        for byte in bytes.subdata(in: at..<(at + width)) { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int.max) else { throw MediaError.invalidMedia }; return Int(value)
    }
    func setPaused(_ value: Bool) {
        paused = value
        if !value { let values = waiters.values; waiters.removeAll(); for waiter in values { waiter.resume() } }
    }
    private func waitUntilResumed() async throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard paused else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled || closed { continuation.resume(throwing: CancellationError()) }
                else if !paused { continuation.resume() }
                else { waiters[id] = continuation }
            }
        }, onCancel: { Task { await self.cancelWaiter(id) } })
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }
    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func close() async {
        guard !closed else { return }
        closed = true
        let values = waiters.values; waiters.removeAll(); for waiter in values { waiter.resume(throwing: CancellationError()) }
        for value in pending.values { value.task.cancel() }; pending.removeAll()
        memory.removeAll(); sampleMemory.removeAll()
        if let key = cacheKey { cacheKey = nil; await cache.release(key) }
    }
}

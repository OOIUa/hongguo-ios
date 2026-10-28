// SPDX-License-Identifier: GPL-3.0-only
// Protocol and CENC layout ported from hongguo-android's Spade/Mp4/Mp4Progressive.
import Foundation

enum MediaError: LocalizedError {
    case invalidMedia, unsupported, invalidKey, tooLarge, transport, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidMedia: return "视频文件不完整或格式损坏，请重试。"
        case .unsupported: return "此视频的封装或加密格式暂不支持。"
        case .invalidKey: return "暂时无法解析本集播放信息，请尝试其他剧集。"
        case .tooLarge: return "本集视频超过 512 MB 缓存限制。"
        case .transport: return "视频下载失败，请检查网络后重试。"
        case .unavailable: return "此视频暂时无法播放。"
        }
    }
}

enum SpadeKey {
    static func decode(_ base64: String) throws -> Data {
        guard let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), bytes.count <= 4096 else { throw MediaError.invalidKey }
        for flag in [0, 1] {
            if let key = unwrap(Array(bytes), flag: flag) { return key }
        }
        throw MediaError.invalidKey
    }

    static func unwrap(_ source: [UInt8], flag: Int) -> Data? {
        let length = source.count
        guard length >= 3 else { return nil }
        let marker = Int(source[0] ^ source[1] ^ source[2])
        let typeLength = marker - 0x30
        let count = length - marker + 0x2f
        guard typeLength > 0, typeLength <= length - 2, count > 0, count + 1 <= length else { return nil }
        let salt = source[length - typeLength - 2] ^ source[length - typeLength - 1]
        let type = source[(length - typeLength)...].map { $0 ^ salt }
        func cPrefix(_ value: String) -> Bool {
            let other = Array(value.utf8)
            for i in 0..<typeLength {
                let a = type[i], b = i < other.count ? other[i] : 0
                if a != b { return false }; if a == 0 { return true }
            }
            return true
        }
        guard !cPrefix("app_v2"), !cPrefix("web_v2") else { return nil }
        var output = Array(source[1...count]); var cur14 = 0x55, cur16 = 0xfa
        for i in 0..<count {
            let byte = Int(output[i]); var b3 = byte, b7 = cur14
            if i & 1 != 0 { b3 = cur16; b7 = byte; cur16 = cur14 }
            let adjustment = flag == 0 ? -0x15 - i.nonzeroBitCount : i.nonzeroBitCount + 0x15
            output[i] = UInt8(truncatingIfNeeded: adjustment + (cur16 ^ byte))
            cur14 = b7; cur16 = b3
        }
        let start = Int(output[0]); let trim: Int
        if (0x30...0x39).contains(start) { trim = start - 0x30 }
        else if (0x61...0x7a).contains(start) { trim = start - 0x57 }
        else { return nil }
        let end = count - trim
        guard end >= 2, end <= count, end - 1 == 32 else { return nil }
        let hex = Array(output[1..<end]); var key = Data()
        func digit(_ c: UInt8) -> UInt8? {
            if (48...57).contains(c) { return c - 48 }
            if (97...102).contains(c) { return c - 87 }; return nil
        }
        for i in stride(from: 0, to: 32, by: 2) {
            guard let a = digit(hex[i]), let b = digit(hex[i + 1]) else { return nil }
            key.append(a * 16 + b)
        }
        return key
    }
}

/// Bounded, same-offset CENC processing. File samples are never loaded as one whole movie.
enum MP4Processor {
    static let maximumBytes = 512 * 1024 * 1024
    private static let maxSamples = 250_000
    private static let maxSampleBytes = 32 * 1024 * 1024
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "sinf", "schi"]
    private static let visual: Set<String> = ["encv", "avc1", "avc3", "hvc1", "hev1", "av01", "mp4v", "vp08", "vp09", "dvav", "dva1"]
    private static let audio: Set<String> = ["enca", "mp4a", "ac-3", "ec-3", "Opus", "fLaC", "samr", "sawb"]

    private final class Box {
        let start: Int, payload: Int, end: Int, type: String
        var children: [Box] = []
        init(start: Int, payload: Int, end: Int, type: String) { self.start = start; self.payload = payload; self.end = end; self.type = type }
        func child(_ name: String) throws -> Box? {
            let matches = children.filter { $0.type == name }
            guard matches.count <= 1 else { throw MediaError.invalidMedia }; return matches.first
        }
        func require(_ name: String) throws -> Box {
            guard let value = try child(name) else { throw MediaError.invalidMedia }; return value
        }
    }
    private struct FileLayout { let length: Int; let moovOffset: Int; let moov: Data; let media: [Range<Int>]; let psshOffsets: [Int] }
    private struct Sample { let offset: Int, size: Int; let iv: Data }
    private struct Track { let handler: String, codec: String; let samples: [Sample]; let nalLengthBytes: Int }

    static func validate(url: URL) throws {
        let layout = try inspectFile(url)
        var count = 0
        let roots = try parse(Array(layout.moov), start: 0, end: layout.moov.count, depth: 0, count: &count)
        guard roots.count == 1, roots[0].type == "moov", roots[0].children.contains(where: { $0.type == "trak" }) else { throw MediaError.invalidMedia }
    }

    static func decrypt(url: URL, spade: String, progress: @Sendable (String, Double) -> Void) throws {
        try Task.checkCancellation()
        let key = try SpadeKey.decode(spade)
        let layout = try inspectFile(url)
        var bytes = Array(layout.moov); var count = 0
        let roots = try parse(bytes, start: 0, end: bytes.count, depth: 0, count: &count)
        guard roots.count == 1 else { throw MediaError.invalidMedia }
        let tracks = try readTracks(bytes, moov: roots[0], layout: layout)
        guard !tracks.isEmpty, let video = tracks.first(where: { $0.handler == "vide" }) else { throw MediaError.unsupported }
        let file = try FileHandle(forUpdating: url); defer { try? file.close() }
        let probes = Set([0, 1, 2, video.samples.count / 4, video.samples.count / 2, video.samples.count - 1]).sorted()
        var tested = 0
        for i in probes where video.samples.indices.contains(i) && video.samples[i].size >= 8 {
            try Task.checkCancellation()
            let sample = video.samples[i]
            let cipher = try read(file, at: sample.offset, count: sample.size)
            let plain = try HGCrypto.aesCTR(cipher, key: key, iv: sample.iv)
            guard nalChainValid(plain, lengthBytes: video.nalLengthBytes) else { throw MediaError.invalidKey }
            tested += 1
        }
        guard tested > 0 else { throw MediaError.invalidMedia }
        let all = tracks.flatMap(\.samples).filter { $0.size > 0 }.sorted { $0.offset < $1.offset }
        var previousEnd = -1
        for sample in all {
            guard sample.offset >= previousEnd else { throw MediaError.invalidMedia }
            previousEnd = sample.offset + sample.size
        }
        for (i, sample) in all.enumerated() {
            try Task.checkCancellation()
            let cipher = try read(file, at: sample.offset, count: sample.size)
            let plain = try HGCrypto.aesCTR(cipher, key: key, iv: sample.iv)
            guard plain.count == sample.size else { throw MediaError.invalidMedia }
            try file.seek(toOffset: UInt64(sample.offset)); try file.write(contentsOf: plain)
            if i % 128 == 0 || i + 1 == all.count { progress("正在处理视频", Double(i + 1) / Double(all.count)) }
        }
        try repair(&bytes, boxes: roots)
        try file.seek(toOffset: UInt64(layout.moovOffset)); try file.write(contentsOf: Data(bytes))
        for offset in layout.psshOffsets {
            try file.seek(toOffset: UInt64(offset + 4)); try file.write(contentsOf: Data("free".utf8))
        }
        try file.synchronize()
        try Task.checkCancellation()
        try validate(url: url)
    }

    private static func inspectFile(_ url: URL) throws -> FileLayout {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let length64 = try file.seekToEnd()
        guard length64 >= 16, length64 <= UInt64(maximumBytes) else { throw length64 > UInt64(maximumBytes) ? MediaError.tooLarge : MediaError.invalidMedia }
        let length = Int(length64); var offset = 0, boxCount = 0, moovOffset: Int?, moov = Data(), media: [Range<Int>] = [], pssh: [Int] = []
        while offset < length {
            try Task.checkCancellation(); boxCount += 1
            guard boxCount <= 4096, length - offset >= 8 else { throw MediaError.invalidMedia }
            let head = Array(try read(file, at: offset, count: min(16, length - offset)))
            var size = try u32(head, 0), header = 8
            if size == 1 { size = try u64(head, 8); header = 16 }
            else if size == 0 { size = length - offset }
            guard size >= header, size <= length - offset else { throw MediaError.invalidMedia }
            let type = try text(head, 4)
            if offset == 0 && type != "ftyp" { throw MediaError.invalidMedia }
            if ["moof", "mfra", "sidx"].contains(type) { throw MediaError.unsupported }
            if type == "moov" {
                guard moovOffset == nil, size <= 32 * 1024 * 1024 else { throw MediaError.invalidMedia }
                moovOffset = offset; moov = try read(file, at: offset, count: size)
            } else if type == "mdat" { media.append((offset + header)..<(offset + size)) }
            else if type == "pssh" { pssh.append(offset) }
            offset += size
        }
        guard let found = moovOffset, !media.isEmpty else { throw MediaError.invalidMedia }
        return FileLayout(length: length, moovOffset: found, moov: moov, media: media, psshOffsets: pssh)
    }

    private static func parse(_ bytes: [UInt8], start: Int, end: Int, depth: Int, count: inout Int) throws -> [Box] {
        guard depth <= 16, start >= 0, end <= bytes.count, start <= end else { throw MediaError.invalidMedia }
        var boxes: [Box] = [], at = start
        while at < end {
            count += 1
            guard count <= 100_000, end - at >= 8 else { throw MediaError.invalidMedia }
            var size = try u32(bytes, at), header = 8
            if size == 1 { size = try u64(bytes, at + 8); header = 16 }
            else if size == 0 { size = end - at }
            guard size >= header, size <= end - at else { throw MediaError.invalidMedia }
            let type = try text(bytes, at + 4)
            let box = Box(start: at, payload: at + header, end: at + size, type: type)
            if ["moof", "mvex", "uuid"].contains(type) { throw MediaError.unsupported }
            var childStart: Int?
            if containers.contains(type) { childStart = box.payload }
            else if type == "stsd" { try require(box, 8); childStart = box.payload + 8 }
            else if visual.contains(type) { try require(box, 78); childStart = box.payload + 78 }
            else if audio.contains(type) {
                try require(box, 28)
                guard bytes[box.payload + 8] == 0, bytes[box.payload + 9] == 0 else { throw MediaError.unsupported }
                childStart = box.payload + 28
            }
            if let childStart { box.children = try parse(bytes, start: childStart, end: box.end, depth: depth + 1, count: &count) }
            if type == "sgpd" || type == "sbgp" {
                try require(box, 8)
                guard ["roll", "prol"].contains(try text(bytes, box.payload + 4)) else { throw MediaError.unsupported }
            }
            boxes.append(box); at = box.end
        }
        return boxes
    }

    private static func readTracks(_ bytes: [UInt8], moov: Box, layout: FileLayout) throws -> [Track] {
        var tracks: [Track] = [], totalSamples = 0
        let traks = moov.children.filter { $0.type == "trak" }
        guard traks.count <= 8 else { throw MediaError.invalidMedia }
        for trak in traks {
            let mdia = try trak.require("mdia"), hdlr = try mdia.require("hdlr")
            try require(hdlr, 12)
            let handler = try text(bytes, hdlr.payload + 8)
            guard ["vide", "soun"].contains(handler) else { throw MediaError.unsupported }
            let stbl = try mdia.require("minf").require("stbl"), stsd = try stbl.require("stsd")
            try require(stsd, 8)
            guard try u32(bytes, stsd.payload + 4) == 1, stsd.children.count == 1 else { throw MediaError.unsupported }
            let entry = stsd.children[0]
            let encrypted = entry.type == "encv" || entry.type == "enca"
            // Plain tracks may coexist with CENC video, and must remain untouched.
            if !encrypted {
                guard try entry.child("sinf") == nil, try stbl.child("senc") == nil else { throw MediaError.invalidMedia }
                continue
            }
            let sinf = try entry.require("sinf"), schm = try sinf.require("schm"), frma = try sinf.require("frma")
            try require(schm, 8); try require(frma, 4)
            guard try text(bytes, schm.payload + 4) == "cenc" else { throw MediaError.unsupported }
            let codec = try text(bytes, frma.payload)
            guard (handler == "vide" ? visual : audio).contains(codec), codec != "encv", codec != "enca" else { throw MediaError.unsupported }
            let stsz = try stbl.require("stsz"); try require(stsz, 12)
            let uniform = try u32(bytes, stsz.payload + 4), sampleCount = try u32(bytes, stsz.payload + 8)
            totalSamples += sampleCount
            guard sampleCount > 0, totalSamples <= maxSamples, uniform <= maxSampleBytes else { throw MediaError.invalidMedia }
            guard stsz.end - stsz.payload == 12 + (uniform == 0 ? sampleCount * 4 : 0) else { throw MediaError.invalidMedia }
            var sizes = [Int](); sizes.reserveCapacity(sampleCount)
            for i in 0..<sampleCount {
                let size = uniform == 0 ? try u32(bytes, stsz.payload + 12 + i * 4) : uniform
                guard size <= maxSampleBytes else { throw MediaError.invalidMedia }; sizes.append(size)
            }
            let stco = try stbl.child("stco"), co64 = try stbl.child("co64")
            guard (stco == nil) != (co64 == nil), let chunkBox = stco ?? co64 else { throw MediaError.invalidMedia }
            try require(chunkBox, 8)
            let width = stco == nil ? 8 : 4, chunkCount = try u32(bytes, chunkBox.payload + 4)
            guard chunkCount > 0, chunkCount <= sampleCount, chunkBox.end - chunkBox.payload == 8 + chunkCount * width else { throw MediaError.invalidMedia }
            var chunks = [Int](); chunks.reserveCapacity(chunkCount)
            for i in 0..<chunkCount { chunks.append(try width == 4 ? u32(bytes, chunkBox.payload + 8 + i * width) : u64(bytes, chunkBox.payload + 8 + i * width)) }
            let stsc = try stbl.require("stsc"); try require(stsc, 8)
            let mappingCount = try u32(bytes, stsc.payload + 4)
            guard mappingCount > 0, mappingCount <= chunkCount, stsc.end - stsc.payload == 8 + mappingCount * 12 else { throw MediaError.invalidMedia }
            var mappings: [(Int, Int)] = []
            for i in 0..<mappingCount {
                let p = stsc.payload + 8 + i * 12, first = try u32(bytes, p), perChunk = try u32(bytes, p + 4)
                guard first >= 1, first <= chunkCount, perChunk >= 1, perChunk <= sampleCount, try u32(bytes, p + 8) == 1,
                      (i == 0 ? first == 1 : first > mappings[i - 1].0) else { throw MediaError.invalidMedia }
                mappings.append((first, perChunk))
            }
            let senc = try stbl.require("senc"); try require(senc, 8)
            guard try u32(bytes, senc.payload) == 0, try u32(bytes, senc.payload + 4) == sampleCount else { throw MediaError.unsupported }
            let ivBytes = senc.end - senc.payload - 8
            guard ivBytes == sampleCount * 8 || ivBytes == sampleCount * 16 else { throw MediaError.unsupported }
            let ivWidth = ivBytes / sampleCount
            var samples: [Sample] = []; samples.reserveCapacity(sampleCount)
            var mapping = 0
            for (chunkIndex, chunkOffset) in chunks.enumerated() {
                while mapping + 1 < mappings.count && mappings[mapping + 1].0 <= chunkIndex + 1 { mapping += 1 }
                var offset = chunkOffset
                for _ in 0..<mappings[mapping].1 {
                    guard samples.count < sampleCount else { throw MediaError.invalidMedia }
                    let i = samples.count, size = sizes[i]
                    guard offset >= 0, offset <= layout.length - size,
                          size == 0 || layout.media.contains(where: { offset >= $0.lowerBound && offset + size <= $0.upperBound }) else { throw MediaError.invalidMedia }
                    let ivStart = senc.payload + 8 + i * ivWidth
                    var iv = Data(bytes[ivStart..<(ivStart + ivWidth)])
                    if ivWidth == 8 { iv.append(Data(repeating: 0, count: 8)) }
                    samples.append(Sample(offset: offset, size: size, iv: iv)); offset += size
                }
            }
            guard samples.count == sampleCount else { throw MediaError.invalidMedia }
            var nalLength = 4
            if handler == "vide" {
                guard ["avc1", "avc3", "hvc1", "hev1"].contains(codec) else { throw MediaError.unsupported }
                if let avc = try entry.child("avcC") { try require(avc, 5); nalLength = Int(bytes[avc.payload + 4] & 3) + 1 }
                else if let hevc = try entry.child("hvcC") { try require(hevc, 22); nalLength = Int(bytes[hevc.payload + 21] & 3) + 1 }
            }
            tracks.append(Track(handler: handler, codec: codec, samples: samples, nalLengthBytes: nalLength))
        }
        return tracks
    }

    private static func repair(_ bytes: inout [UInt8], boxes: [Box]) throws {
        for box in boxes {
            if box.type == "encv" || box.type == "enca" {
                let original = try box.require("sinf").require("frma")
                try require(original, 4)
                let type = Array(bytes[original.payload..<(original.payload + 4)])
                bytes.replaceSubrange((box.start + 4)..<(box.start + 8), with: type)
            }
            if ["sinf", "senc", "saiz", "saio", "pssh"].contains(box.type) {
                bytes.replaceSubrange((box.start + 4)..<(box.start + 8), with: Array("free".utf8))
            } else { try repair(&bytes, boxes: box.children) }
        }
    }

    private static func nalChainValid(_ data: Data, lengthBytes: Int) -> Bool {
        let b = Array(data); guard b.count >= 5, (1...4).contains(lengthBytes) else { return false }
        if b[0] == 0 && b[1] == 0 && (b[2] == 1 || (b[2] == 0 && b[3] == 1)) { return true }
        var offset = 0, count = 0
        while offset + lengthBytes < b.count {
            var length = 0
            for i in 0..<lengthBytes { length = (length << 8) | Int(b[offset + i]) }
            guard length > 0, length <= b.count - offset - lengthBytes, b[offset + lengthBytes] & 0x80 == 0 else { return false }
            offset += lengthBytes + length; count += 1
            if count > 1024 { return false }
        }
        return count > 0 && (offset == b.count || b.count - offset <= 3)
    }
    private static func require(_ box: Box, _ count: Int) throws { guard box.end - box.payload >= count else { throw MediaError.invalidMedia } }
    private static func read(_ file: FileHandle, at: Int, count: Int) throws -> Data {
        guard at >= 0, count >= 0 else { throw MediaError.invalidMedia }
        try file.seek(toOffset: UInt64(at))
        guard let data = try file.read(upToCount: count), data.count == count else { throw MediaError.invalidMedia }; return data
    }
    private static func u32(_ b: [UInt8], _ at: Int) throws -> Int {
        guard at >= 0, at <= b.count - 4 else { throw MediaError.invalidMedia }
        return (0..<4).reduce(0) { ($0 << 8) | Int(b[at + $1]) }
    }
    private static func u64(_ b: [UInt8], _ at: Int) throws -> Int {
        guard at >= 0, at <= b.count - 8 else { throw MediaError.invalidMedia }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(b[at + i]) }
        guard value <= UInt64(Int.max) else { throw MediaError.invalidMedia }; return Int(value)
    }
    private static func text(_ b: [UInt8], _ at: Int) throws -> String {
        guard at >= 0, at <= b.count - 4 else { throw MediaError.invalidMedia }
        return String(bytes: b[at..<(at + 4)], encoding: .isoLatin1) ?? ""
    }
}

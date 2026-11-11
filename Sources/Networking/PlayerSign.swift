// SPDX-License-Identifier: GPL-3.0-only
// Single-episode player signature (x-gorgon, x-argus, x-ladon) for /novel/player/video_model/v1/.
// Synchronized from LiuWQ0809/hongguo-android `PlayerSign.java` (commit 3eaf813, 2026-11-11, GPL-3.0-only),
// whose algorithm cites Xanerix/guoapp ad8dc125 (GPL-3.0). Since 2026-11-11 the model endpoints answer the
// placeholder argus/ladon of PureSign.js with 200 and an empty body.
import Foundation

enum PlayerSign {
    static func headers(query: String, body: Data, nowMs: Int64, deviceID: String) throws -> [String: String] {
        guard !deviceID.isEmpty, deviceID.count <= 30, deviceID.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw HGError.message("播放器签名参数无效")
        }
        let timestamp = nowMs / 1000
        let nonce = HGCrypto.random(11)
        return ["x-khronos": String(timestamp), "x-ss-req-ticket": String(nowMs),
                "x-ss-stub": HGCrypto.md5(body).hexString.uppercased(),
                "x-gorgon": gorgon(query: query, body: body, timestamp: timestamp),
                "x-argus": try argus(query: query, body: body, timestamp: timestamp, deviceID: deviceID, nonce: nonce),
                "x-ladon": ladon(timestamp: timestamp, prefix: nonce.subdata(in: nonce.startIndex + 2 ..< nonce.startIndex + 6))]
    }

    // MARK: Gorgon

    static func gorgon(query: String, body: Data?, timestamp: Int64) -> String {
        var data = [UInt8](repeating: 0, count: 20)
        data.replaceSubrange(0..<4, with: HGCrypto.md5(Data(query.utf8)).prefix(4))
        if let body { data.replaceSubrange(4..<8, with: HGCrypto.md5(body).prefix(4)) }
        data.replaceSubrange(12..<16, with: [0, 6, 11, 28])
        let t = UInt32(truncatingIfNeeded: timestamp)
        data.replaceSubrange(16..<20, with: [UInt8(t >> 24 & 255), UInt8(t >> 16 & 255), UInt8(t >> 8 & 255), UInt8(t & 255)])
        let key = [UInt8](Data(hex: "44b9b9d9a4aef9fca493aa757ca3c2c4a496938f")!)
        for i in 0..<data.count { data[i] ^= key[i] }
        for i in 0..<data.count {
            let current = data[i]
            var mixed = (current << 4) | (current >> 4)
            mixed ^= data[(i + 1) % data.count]
            data[i] = reverseBits(mixed) ^ 255 ^ UInt8(data.count)
        }
        return "8404401c0000" + Data(data).hexString
    }

    private static func reverseBits(_ value: UInt8) -> UInt8 {
        var v = value, r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (v & 1); v >>= 1 }
        return r
    }

    // MARK: Ladon

    static func ladon(timestamp: Int64, prefix: Data) -> String {
        let digest = [UInt8](HGCrypto.md5(prefix + Data("8662".utf8)).hexString.utf8)
        var left = le64(digest, 0), right = le64(digest, 8)
        var queue = [UInt64](repeating: 0, count: 36), keys = [UInt64](repeating: 0, count: 34)
        queue[0] = le64(digest, 16); queue[1] = le64(digest, 24)
        for i in 0..<keys.count {
            keys[i] = left
            let mixed = (rotr(right, 8) &+ left) ^ UInt64(i)
            queue[i + 2] = mixed
            left = mixed ^ rotl(left, 3)
            right = queue[i]
        }
        var data = pad([UInt8]("\(timestamp)-1611921764-8662".utf8))
        for offset in stride(from: 0, to: data.count, by: 16) {
            var l = le64(data, offset), r = le64(data, offset + 8)
            for key in keys {
                r = key ^ (l &+ rotr(r, 8))
                l = r ^ rotl(l, 3)
            }
            putLE64(&data, offset, l); putLE64(&data, offset + 8, r)
        }
        return (prefix + Data(data)).base64EncodedString()
    }

    // MARK: Argus

    static func argus(query: String, body: Data?, timestamp: Int64, deviceID: String, nonce: Data) throws -> String {
        let key = [UInt8](Data(hex: "ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")!)
        let xor = [UInt8](Data(hex: "d04ffdffd04ffdff")!)
        var data = argusTransform(argusMessage(query: query, body: body, timestamp: timestamp, deviceID: deviceID, nonce: [UInt8](nonce)), key: key)
        for i in 0..<data.count { data[i] ^= xor[i % xor.count] }
        data = Array((xor + data).reversed())
        let container = pad([UInt8](Data(hex: "a6e783ee7001100918")!) + data + [0x56, 0x7b])
        let cipher = try HGCrypto.aesCBCEncrypt(Data(container), key: HGCrypto.md5(Data(key[0..<16])),
                                                iv: HGCrypto.md5(Data(key[16..<32])), padding: false)
        return (Data([0x3c, 0xcc]) + cipher).base64EncodedString()
    }

    private static func argusMessage(query: String, body: Data?, timestamp: Int64, deviceID: String, nonce: [UInt8]) -> [UInt8] {
        let bodyHash = SM3.hash(body.map { [UInt8](HGCrypto.md5($0)) } ?? [UInt8](repeating: 0, count: 16))
        let queryHash = SM3.hash([UInt8](query.utf8))
        let counters = number(1, 1) + number(2, 1) + number(3, 1) + number(7, 3348294860)
        let environment = text(1, "25053RT47C") + text(2, "16") + text(3, "update_64") + number(4, 2147483648)
        let nonceValue = UInt64(UInt32(nonce[6]) | UInt32(nonce[7]) << 8 | UInt32(nonce[8]) << 16 | UInt32(nonce[9]) << 24) & 0x7fffffff
        var out = number(1, 0x20200929 * 2) + number(2, 2) + number(3, nonceValue)
        out += text(4, "8662") + text(5, deviceID) + text(6, "1611921764") + text(7, "7.3.5.32") + text(8, "v04.07.01-ml-android")
        out += number(9, 135135744) + field(10, [UInt8](repeating: 0, count: 8)) + number(11, 0) + number(12, UInt64(timestamp) * 2)
        out += field(13, Array(bodyHash.prefix(6))) + field(14, Array(queryHash.prefix(6))) + field(15, counters) + field(16, [])
        out += text(20, "none") + number(21, 738) + field(23, environment) + number(25, 2)
        return out
    }

    private static func argusTransform(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let derived = SM3.hash(key + [0x3c, 0xcc, 0x56, 0x7b] + key)
        var rounds = [UInt64](repeating: 0, count: 72)
        for i in 0..<4 { rounds[i] = le64(derived, i * 8) }
        let constant: UInt64 = 0x3dc94c3a046d678b
        for i in 4..<rounds.count {
            var mixed = rotr(rounds[i - 1], 3) ^ rounds[i - 3]
            mixed ^= rotr(mixed, 1)
            rounds[i] = ~rounds[i - 4] ^ mixed ^ ((constant >> UInt64((i - 4) % 62)) & 1) ^ 3
        }
        var data = pad(message)
        for offset in stride(from: 0, to: data.count, by: 16) {
            var left = le64(data, offset), right = le64(data, offset + 8)
            for round in rounds {
                let next = left ^ (rotl(right, 1) & rotl(right, 8)) ^ rotl(right, 2) ^ round
                left = right; right = next
            }
            putLE64(&data, offset, left); putLE64(&data, offset + 8, right)
        }
        return data
    }

    // MARK: Protobuf and byte helpers

    private static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        while v & ~127 != 0 { out.append(UInt8(v & 127) | 128); v >>= 7 }
        out.append(UInt8(v))
        return out
    }
    private static func number(_ field: UInt64, _ value: UInt64) -> [UInt8] { varint(field * 8) + varint(value) }
    private static func field(_ field: UInt64, _ value: [UInt8]) -> [UInt8] { varint(field * 8 + 2) + varint(UInt64(value.count)) + value }
    private static func text(_ field: UInt64, _ value: String) -> [UInt8] { self.field(field, [UInt8](value.utf8)) }

    private static func pad(_ data: [UInt8]) -> [UInt8] {
        let n = 16 - data.count % 16
        return data + [UInt8](repeating: UInt8(n), count: n)
    }
    private static func rotl(_ v: UInt64, _ n: UInt64) -> UInt64 { (v << n) | (v >> (64 - n)) }
    private static func rotr(_ v: UInt64, _ n: UInt64) -> UInt64 { (v >> n) | (v << (64 - n)) }
    private static func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }
    private static func putLE64(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i))) }
    }
}

/// SM3 (GB/T 32905-2016).
enum SM3 {
    private static let iv: [UInt32] = [0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600, 0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e]

    static func hash(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(input.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }
        var v = iv
        var w = [UInt32](repeating: 0, count: 68), w1 = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: message.count, by: 64) {
            for j in 0..<16 {
                let o = block + j * 4
                w[j] = UInt32(message[o]) << 24 | UInt32(message[o + 1]) << 16 | UInt32(message[o + 2]) << 8 | UInt32(message[o + 3])
            }
            for j in 16..<68 {
                w[j] = p1(w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) ^ rotl(w[j - 13], 7) ^ w[j - 6]
            }
            for j in 0..<64 { w1[j] = w[j] ^ w[j + 4] }
            var a = v[0], b = v[1], c = v[2], d = v[3], e = v[4], f = v[5], g = v[6], h = v[7]
            for j in 0..<64 {
                let t: UInt32 = j < 16 ? 0x79cc4519 : 0x7a879d8a
                let ss1 = rotl(rotl(a, 12) &+ e &+ rotl(t, UInt32(j % 32)), 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let ff = j < 16 ? a ^ b ^ c : (a & b) | (a & c) | (b & c)
                let gg = j < 16 ? e ^ f ^ g : (e & f) | (~e & g)
                let tt1 = ff &+ d &+ ss2 &+ w1[j]
                let tt2 = gg &+ h &+ ss1 &+ w[j]
                d = c; c = rotl(b, 9); b = a; a = tt1
                h = g; g = rotl(f, 19); f = e; e = p0(tt2)
            }
            v[0] ^= a; v[1] ^= b; v[2] ^= c; v[3] ^= d; v[4] ^= e; v[5] ^= f; v[6] ^= g; v[7] ^= h
        }
        return v.flatMap { [UInt8($0 >> 24 & 255), UInt8($0 >> 16 & 255), UInt8($0 >> 8 & 255), UInt8($0 & 255)] }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { n == 0 ? x : (x << n) | (x >> (32 - n)) }
    private static func p0(_ x: UInt32) -> UInt32 { x ^ rotl(x, 9) ^ rotl(x, 17) }
    private static func p1(_ x: UInt32) -> UInt32 { x ^ rotl(x, 15) ^ rotl(x, 23) }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CommonCrypto
import Security
import zlib

enum HGCrypto {
    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(0, count))
        if !bytes.isEmpty && SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        }
        return Data(bytes)
    }
    static func md5(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }
    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }
    static func sha512(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA512($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }
    static func aesCBCEncrypt(_ data: Data, key: Data, iv: Data, padding: Bool = true) throws -> Data {
        try cbc(data, key: key, iv: iv, operation: CCOperation(kCCEncrypt), padding: padding)
    }
    static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data, padding: Bool = true) throws -> Data {
        try cbc(data, key: key, iv: iv, operation: CCOperation(kCCDecrypt), padding: padding)
    }
    private static func cbc(_ data: Data, key: Data, iv: Data, operation: CCOperation, padding: Bool) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else { throw HGError.message("加密参数无效") }
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let result = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in data.withUnsafeBytes { input in
            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), padding ? CCOptions(kCCOptionPKCS7Padding) : 0,
                    k.baseAddress, key.count, v.baseAddress, input.baseAddress, data.count, &output, capacity, &written)
        } } }
        guard result == kCCSuccess else { throw HGError.message("媒体或协议加密处理失败") }
        return Data(output.prefix(written))
    }
    static func aesCTR(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw HGError.message("媒体密钥格式无效") }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                   CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count,
                                   nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        } }
        guard created == kCCSuccess, let cryptor else { throw HGError.message("无法初始化媒体处理") }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: data.count + 16)
        let capacity = output.count
        var written = 0
        let result = data.withUnsafeBytes {
            CCCryptorUpdate(cryptor, $0.baseAddress, data.count, &output, capacity, &written)
        }
        guard result == kCCSuccess else { throw HGError.message("媒体处理失败") }
        return Data(output.prefix(written))
    }
    static func gzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw HGError.message("压缩初始化失败")
        }
        defer { deflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var status: Int32 = Z_OK
            repeat {
                let amount = buffer.count
                status = buffer.withUnsafeMutableBytes {
                    stream.next_out = $0.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(amount)
                    return deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw HGError.message("压缩请求失败") }
                output.append(contentsOf: buffer.prefix(amount - Int(stream.avail_out)))
            } while status != Z_STREAM_END
            return output
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum ProtocolJSON {
    /// Quote long integer tokens before Foundation parsing; content IDs must never pass through Double.
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 8 * 1024 * 1024 else { throw HGError.message("服务返回的数据过大") }
        let source = Array(data)
        var result = [UInt8](); result.reserveCapacity(source.count)
        var i = 0, inString = false
        while i < source.count {
            let byte = source[i]
            if inString {
                result.append(byte); i += 1
                if byte == 92, i < source.count { result.append(source[i]); i += 1 }
                else if byte == 34 { inString = false }
                continue
            }
            if byte == 34 { inString = true; result.append(byte); i += 1; continue }
            if (48...57).contains(byte) || byte == 45 {
                let start = i
                if source[i] == 45 { i += 1 }
                while i < source.count, (48...57).contains(source[i]) { i += 1 }
                let end = i
                let isFloating = i < source.count && [UInt8(46), 69, 101].contains(source[i])
                if !isFloating, end - start >= 16 {
                    result.append(34); result.append(contentsOf: source[start..<end]); result.append(34)
                } else {
                    result.append(contentsOf: source[start..<end])
                    if isFloating {
                        while i < source.count, (48...57).contains(source[i]) || [UInt8(46), 69, 101, 43, 45].contains(source[i]) { result.append(source[i]); i += 1 }
                    }
                }
                continue
            }
            result.append(byte); i += 1
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(result)) as? [String: Any] else {
            throw HGError.message("服务数据格式发生变化")
        }
        return object
    }
    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func dictionary(_ value: Any?) -> [String: Any] {
        if let value = value as? [String: Any] { return value }
        if let text = value as? String, let bytes = text.data(using: .utf8), let object = try? object(bytes) { return object }
        return [:]
    }
    static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    static func text(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
    static func integer(_ value: Any?) -> Int { Int(text(value)) ?? 0 }
    static func bool(_ value: Any?, default fallback: Bool = false) -> Bool {
        if let boolean = value as? Bool { return boolean }
        switch text(value).lowercased() { case "true", "1": return true; case "false", "0": return false; default: return fallback }
    }
    static func identifier(_ value: Any?) -> String? {
        let value = text(value)
        return !value.isEmpty && value.count <= 30 && value.utf8.allSatisfy { (48...57).contains($0) } && value.contains(where: { $0 != "0" }) ? value : nil
    }
}

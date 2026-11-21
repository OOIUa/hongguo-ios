// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android 0.7.32 (PR #13), danmaku/DanmakuEmoji.kt.
import Foundation

/// The platform embeds its own emoji codes in bullet-comment text, e.g. "[爱慕]". Drawing the raw
/// text shows literal brackets instead of the picture the official app renders, so the overlay must
/// expand known codes to Unicode emoji first. Unknown codes are left untouched so nothing is lost.
/// The text also carries U+FFFC wherever the official app draws one of its own picture stickers;
/// those cannot be reconstructed from the payload, so the placeholder is dropped rather than left
/// to render as a missing-glyph box.
enum DanmakuEmoji {
    /// Codes are stored without brackets; keys are lower-cased so lookups stay case-insensitive.
    private static let table: [String: String] = [
        "大笑": "😄", "捂脸": "🤦", "爱慕": "😍", "赞": "👍", "笑哭": "😂",
        "狗头": "🐶", "doge": "🐶", "666": "🙌", "灵光一闪": "💡", "滑稽": "🤪",
        "看": "👀", "what": "😲", "星星眼": "🤩", "打脸": "🤚", "思考": "🤔",
        "疑问": "❓", "憨笑": "😁", "奸笑": "😏", "酷拽": "😎", "黑脸": "🌚",
        "呲牙": "😁", "偷笑": "🤭", "得意": "😌", "小鼓掌": "👏", "鼓掌": "👏",
        "比心": "🫰", "爱心": "❤️", "生气": "😠", "发怒": "😡", "咒骂": "🤬",
        "流泪": "😢", "泣不成声": "😭", "泪奔": "😭", "大哭": "😭", "晕": "😵",
        "困": "😪", "衰": "😩", "擦汗": "😓", "抠鼻": "😤", "抓狂": "😫",
        "震惊": "😱", "惊讶": "😮", "ok": "👌", "耶": "✌️", "酷": "😎",
        "微笑": "🙂", "害羞": "😊", "抱抱": "🤗", "白眼": "🙄", "笑": "😄",
        "鲜花": "🌹", "玫瑰": "🌹", "加油": "💪", "胜利": "✌️", "厉害": "👍",
        "无语": "😑", "叹气": "😮‍💨", "吃瓜": "🍉", "柠檬": "🍋", "尴尬": "😅",
        "绝望": "😩", "暗中观察": "🕵️", "心碎": "💔", "礼物": "🎁", "可爱": "🥰",
        "拜托": "🙏", "厉害了我的哥": "😲",
        // Codes observed in live bullet-comment traffic that the initial guess set missed.
        "哭": "😭", "爽": "😆", "怒": "😠", "送花": "🌹", "盯": "👀",
    ]

    private static let sticker: Character = "\u{FFFC}"

    /// Expands every recognized "[code]" to its emoji, leaving the rest of text and unknown codes as-is.
    static func display(_ text: String) -> String {
        let hasCode = text.contains("[")
        let hasSticker = text.contains(sticker)
        // Budget the common case: literal text needs no work at all.
        if !hasCode && !hasSticker { return text }
        var clean = text
        if hasSticker { clean = clean.replacingOccurrences(of: String(sticker), with: "") }
        if !hasCode { return clean }
        var out = String(); out.reserveCapacity(clean.count)
        var index = clean.startIndex
        while index < clean.endIndex {
            guard let open = clean[index...].firstIndex(of: "[") else { out += clean[index...]; break }
            out += clean[index..<open]
            guard let close = clean[clean.index(after: open)...].firstIndex(of: "]") else { out += clean[open...]; break }
            let code = String(clean[clean.index(after: open)..<close]).lowercased()
            if let emoji = table[code] { out += emoji } else { out += clean[open...close] }
            index = clean.index(after: close)
        }
        return out
    }

    /// Ranges of color-emoji clusters inside text, as String indices [start, end).
    ///
    /// 黑边 mode draws the comment twice — a stroke pass for the black edge and a fill pass on top.
    /// A stroke attributes only outlines real glyphs; a color-emoji glyph is a bitmap that Core Text
    /// blits whole, so drawing it in both passes composites it twice (75% ends up near 94% and looks
    /// opaque). The overlay therefore skips the stroke pass over these ranges.
    static func emojiRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            let code = text.unicodeScalars[index].value
            var step = 1
            // Surge past the remaining scalars of this grapheme cluster as needed below.
            if !isEmojiBase(code) {
                index = text.index(after: index)
                continue
            }
            let start = index
            index = text.index(after: index)
            // Pull in variation selectors, skin-tone modifiers, ZWJ sequences and keycaps so a
            // composite emoji (👨‍👩‍👧, ❤️, 1️⃣) is treated as one cluster.
            while index < text.endIndex, let next = optionalScalar(at: index, in: text, step: &step) {
                if !isEmojiTail(next.value) { break }
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    private static func optionalScalar(at index: String.Index, in text: String, step: inout Int) -> Unicode.Scalar? {
        step += 1
        return index < text.endIndex ? text.unicodeScalars[index] : nil
    }

    private static func isEmojiBase(_ code: UInt32) -> Bool {
        (0x1F000...0x1FAFF).contains(code) || (0x2600...0x27BF).contains(code) || (0x2B00...0x2BFF).contains(code)
    }

    private static func isEmojiTail(_ code: UInt32) -> Bool {
        code == 0xFE0F || code == 0xFE0E || code == 0x200D || code == 0x20E3 ||
            (0x1F3FB...0x1F3FF).contains(code) || isEmojiBase(code)
    }
}

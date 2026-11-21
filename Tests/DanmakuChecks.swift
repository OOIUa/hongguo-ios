// SPDX-License-Identifier: GPL-3.0-only
// Offline checks for the danmaku port's pure logic: emoji expansion, dedupe order, risk-control
// cooldown parsing and the loader's backoff ladder. Network shapes are covered by the repository's
// actor through the live suites; rendering is verified on device.
import Foundation

func checkDanmakuLogic() {
    // Emoji expansion: known codes, unknown codes kept, stickers dropped, plain text untouched.
    precondition(DanmakuEmoji.display("哈哈[大笑]") == "哈哈😄")
    precondition(DanmakuEmoji.display("[doge][666]") == "🐶🙌")
    precondition(DanmakuEmoji.display("[没见过的]") == "[没见过的]", "Unknown codes stay literal")
    precondition(DanmakuEmoji.display("前面\u{FFFC}贴纸") == "前面贴纸", "U+FFFC placeholders are dropped")
    precondition(DanmakuEmoji.display("普通文本不改") == "普通文本不改")
    precondition(DanmakuEmoji.display("[OPEN") == "[OPEN", "Unclosed bracket stays")
    precondition(DanmakuEmoji.display("[大笑") == "[大笑", "Missing close stays")
    // Case-insensitive lookup.
    precondition(DanmakuEmoji.display("[DOGE]") == "🐶")
    // Emoji cluster ranges: composite sequences stay one cluster for the stroke pass.
    let composite = DanmakuEmoji.display("[爱心]")
    let ranges = DanmakuEmoji.emojiRanges(in: composite)
    precondition(ranges.count == 1, "❤️ plus VS16 is one cluster")

    // Dedupe keeps the last of duplicate ids, sorts by offset.
    let duplicated = [
        Danmaku(id: "a", offsetMs: 3000, text: "first", diggCount: 0),
        Danmaku(id: "a", offsetMs: 3000, text: "second", diggCount: 1),
        Danmaku(id: "b", offsetMs: 1000, text: "early", diggCount: 0),
        Danmaku(id: "", offsetMs: 2000, text: "anon", diggCount: 0),
        Danmaku(id: "", offsetMs: 2000, text: "anon", diggCount: 0),
    ]
    let deduped = DanmakuRepository.dedupe(duplicated)
    precondition(deduped.count == 3, "Duplicate ids and anonymous rows collapse")
    precondition(deduped.first?.text == "early", "Sorted by offset")
    precondition(deduped.last?.text == "second", "Last write wins for a repeated id")

    // Risk-control cooldown: server JSON inside the message carries ban seconds (top-level keys).
    let cooldown = DanmakuRepository.cooldownSeconds("{\"min_ban_time\":7,\"max_ban_time\":30}")
    precondition(cooldown == 7, "min_ban_time wins when positive")
    precondition(DanmakuRepository.cooldownSeconds("plain text refusal") == 0, "Non-JSON message means no cooldown")
    precondition(DanmakuRepository.cooldownSeconds("{\"min_ban_time\":0,\"max_ban_time\":9}") == 9, "max used when min is zero")

    // Loader backoff ladder.
    precondition(DanmakuLoader.backoffSeconds(1) == 1)
    precondition(DanmakuLoader.backoffSeconds(2) == 4)
    precondition(DanmakuLoader.backoffSeconds(10) == 15)
    precondition(DanmakuRepository.randomInstallID().count == 16 && DanmakuRepository.randomInstallID().hasPrefix("1"))

    // Settings normalization clamps arbitrary integers from older stores.
    let clamped = DanmakuSettings(enabled: false, coverage: 99, font: -3, opacity: 80, effect: 7, speed: 2).normalized()
    precondition(clamped.coverage == DanmakuPrefs.coverageLabels.count - 1 && clamped.font == 0)
    precondition(clamped.opacity == 75, "80 snaps to the 75 step")
    precondition(clamped.effect == DanmakuPrefs.effectLabels.count - 1 && clamped.speed == 2)
    precondition(DanmakuPrefs.coveragePermille(DanmakuPrefs.coverageDefault) == 200, "1/4 stores as 200 permille")
    precondition(DanmakuPrefs.coverageFromPermille(133) == 0, "133 permille snaps back to 1/6")

    print("PASS danmaku logic: emoji expansion and clusters, dedupe order, cooldown parsing, backoff ladder, settings clamps, permille round trip")
}

// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android 0.7.32 (PR #13), danmaku/DanmakuPrefs.kt.
import Foundation

/// 弹幕的显示参数。除了开关，用户只调四件事：占据屏幕多少高度、字号、透明度、滚动速度。
/// 具体的行数不再单独设置——弹幕层按屏占比拿到高度后，自己用「层高 ÷ 当前字号的行高」
/// 算出能排几行，所以同一个屏占比下，字越大行越少，字越小行越多。
enum DanmakuPrefs {
    /// 透明度只给四档，滑杆在播放过程中既难对准也没必要。
    static let opacitySteps = [25, 50, 75, 100]
    static let opacityDefault = 75
    static var opacityLabels: [String] { opacitySteps.map { "\($0)%" } }

    /// 屏占比五档：占播放区域的 1/6、1/4、1/3、1/2 或全部高度。
    static let coverageLabels = ["1/6", "1/4", "1/3", "1/2", "全屏"]
    static let coverageDefault = 1
    /// 实际占屏比例比档位名小一档左右：行数用四舍五入排满整块带之后，同样比例看上去会偏
    /// 高一点，这里整体再压一压，1/4 的观感才回到四分之一的画面，1/6 则落在六分之一上下。
    static let coverageFractions: [Double] = [0.133, 0.2, 0.25, 0.4, 1]
    /// 落盘用千分数而不是下标：档位数量以后再变，也不会把用户已经选好的比例读歪。
    static var coveragePermilleValues: [Int] { coverageFractions.map { Int($0 * 1000) } }

    /// 字号五档。相对基准的倍数拉开到 0.5～1.55，最小值足够小、最大值足够醒目。
    static let fontLabels = ["极小", "小", "标准", "大", "特大"]
    static let fontDefault = 2
    static let fontScales: [Double] = [0.5, 0.72, 0.95, 1.22, 1.55]

    /// 速度五档。最快的跨屏时间压到基准的 0.42 倍，最慢拉到 1.9 倍。
    static let speedLabels = ["很慢", "慢", "标准", "快", "很快"]
    static let speedDefault = 2
    static let speedScales: [Double] = [1.9, 1.45, 1, 0.62, 0.42]

    /// 文字效果三档：纯白字、细黑边、黑阴影，默认用黑边。
    static let effectLabels = ["白字", "黑边", "阴影"]
    static let effectDefault = 1
    static let effectWhite = 0
    static let effectStroke = 1
    static let effectShadow = 2

    static func opacity(_ value: Int) -> Int {
        opacitySteps.min(by: { abs($0 - value) < abs($1 - value) }) ?? opacityDefault
    }
    /// 透明度落在第几个候选按钮上；面板靠它决定哪一格高亮。
    static func opacityIndex(_ value: Int) -> Int {
        max(0, opacitySteps.firstIndex(of: opacity(value)) ?? 0)
    }
    static func font(_ value: Int) -> Int { min(max(value, 0), fontLabels.count - 1) }
    static func speed(_ value: Int) -> Int { min(max(value, 0), speedLabels.count - 1) }
    static func coverage(_ value: Int) -> Int { min(max(value, 0), coverageLabels.count - 1) }
    static func effect(_ value: Int) -> Int { min(max(value, 0), effectLabels.count - 1) }

    /// 当前档位对应的落盘值（千分数）。
    static func coveragePermille(_ value: Int) -> Int { coveragePermilleValues[coverage(value)] }
    /// 千分数吸附到最接近的一档，读盘时不必要求数值完全相等。
    static func coverageFromPermille(_ value: Int) -> Int {
        let values = coveragePermilleValues
        let index = values.indices.min(by: { abs(values[$0] - value) < abs(values[$1] - value) }) ?? coverageDefault
        return index
    }
    static func coverageFraction(_ value: Int) -> Double { coverageFractions[coverage(value)] }
    /// 字号倍数，乘在画布基准字号上。
    static func fontScale(_ value: Int) -> Double { fontScales[font(value)] }
    /// 跨屏时长倍数；数字越大滚得越慢。
    static func speedScale(_ value: Int) -> Double { speedScales[speed(value)] }
}

/// 一次完整的弹幕参数快照，随 AppModel 在进程内流转并落盘。
struct DanmakuSettings: Equatable, Sendable {
    var enabled: Bool = true
    var coverage: Int = DanmakuPrefs.coverageDefault
    var font: Int = DanmakuPrefs.fontDefault
    var opacity: Int = DanmakuPrefs.opacityDefault
    var effect: Int = DanmakuPrefs.effectDefault
    var speed: Int = DanmakuPrefs.speedDefault

    /// 把每一项夹回支持的档位；持久化里可能有旧版本写入的任意整数。
    func normalized() -> DanmakuSettings {
        DanmakuSettings(enabled: enabled, coverage: DanmakuPrefs.coverage(coverage), font: DanmakuPrefs.font(font),
                        opacity: DanmakuPrefs.opacity(opacity), effect: DanmakuPrefs.effect(effect), speed: DanmakuPrefs.speed(speed))
    }
}

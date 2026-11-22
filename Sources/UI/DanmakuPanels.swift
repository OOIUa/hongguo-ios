// SPDX-License-Identifier: GPL-3.0-only
// Ported from hongguo-android 0.7.32 (PR #13), DanmakuPanels.kt — the danmaku entry buttons in the
// player's bottom bar and the settings sheet. 参数面板：开关独占最上一行，往下每行「左边名称、
// 右边一整条分段按钮」；屏占比决定弹幕层的高度，行数由字号和这块高度自动换算。
import SwiftUI

/// 弹幕开关与设置的图标入口，尺寸贴在倍速左边，横竖屏一致。
struct DanmakuControl: View {
    let enabled: Bool
    let onToggle: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                DanmakuGlyph(enabled: enabled, tint: enabled ? Color(hex: 0xF08058) : .white.opacity(0.6))
                    .frame(width: 34, height: 44)
                    .background(enabled ? Color(hex: 0xF08058).opacity(0.22) : .white.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9))
            }
            .accessibilityLabel(enabled ? "关闭弹幕" : "开启弹幕")
            .accessibilityIdentifier("player.danmaku")
            Button(action: onSettings) {
                DanmakuGlyph(enabled: true, tint: .white.opacity(0.82), settings: true)
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("弹幕设置")
            .accessibilityIdentifier("player.danmakuSettings")
        }.buttonStyle(.plain)
    }
}

/// 参数面板。开关独占最上一行，往下五行都是「左边名称、右边一整条分段按钮」，
/// 整个面板内容一屏放得下，不用滚动也不用滑杆。
struct DanmakuSettingsPanel: View {
    @ObservedObject var model: AppModel
    private var settings: DanmakuSettings { model.danmaku }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("弹幕").font(.headline).foregroundStyle(.white)
                Spacer()
                Toggle("", isOn: Binding(get: { settings.enabled }, set: { model.setDanmaku(settings.copy(enabled: $0)) }))
                    .labelsHidden().tint(Color(hex: 0xF08058))
                    .fixedSize()
            }
            DanmakuChoiceRow(label: "屏幕占比", labels: DanmakuPrefs.coverageLabels, selected: settings.coverage, enabled: settings.enabled) {
                model.setDanmaku(settings.copy(coverage: $0))
            }
            DanmakuChoiceRow(label: "字体大小", labels: DanmakuPrefs.fontLabels, selected: settings.font, enabled: settings.enabled) {
                model.setDanmaku(settings.copy(font: $0))
            }
            // 存的是百分比，按钮按下标排，这里把两者对上，才不会出现「一格都不亮」的情况。
            DanmakuChoiceRow(label: "不透明度", labels: DanmakuPrefs.opacityLabels,
                selected: DanmakuPrefs.opacityIndex(settings.opacity), enabled: settings.enabled) {
                model.setDanmaku(settings.copy(opacity: DanmakuPrefs.opacitySteps[$0]))
            }
            DanmakuChoiceRow(label: "文字效果", labels: DanmakuPrefs.effectLabels, selected: settings.effect, enabled: settings.enabled) {
                model.setDanmaku(settings.copy(effect: $0))
            }
            DanmakuChoiceRow(label: "移动速度", labels: DanmakuPrefs.speedLabels, selected: settings.speed, enabled: settings.enabled) {
                model.setDanmaku(settings.copy(speed: $0))
            }
            HStack {
                Spacer()
                Button {
                    // 只重置显示参数，开关状态保持用户当前的选择。
                    model.setDanmaku(DanmakuSettings(enabled: settings.enabled))
                } label: {
                    Text("恢复默认设置").font(.caption).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .accessibilityIdentifier("player.danmakuReset")
            }
        }
        .padding(20)
        .accessibilityIdentifier("player.danmakuPanel")
    }
}

/// 名称在左、候选在右的一行；候选挤在同一个圆角矩形里，靠一条细分隔线分开。
private struct DanmakuChoiceRow: View {
    let label: String
    let labels: [String]
    let selected: Int
    let enabled: Bool
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.white.opacity(enabled ? 0.9 : 0.45)).frame(width: 62, alignment: .leading).lineLimit(1)
            HStack(spacing: 0) {
                ForEach(labels.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(.white.opacity(0.16)).frame(width: 1, height: 24) }
                    let active = index == selected
                    Button { onSelect(index) } label: {
                        Text(labels[index]).font(.caption.weight(active ? .semibold : .regular))
                            .foregroundStyle(active ? .white : .white.opacity(enabled ? 0.72 : 0.32))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .background(active ? Color(hex: 0xF08058).opacity(0.92) : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .accessibilityLabel("\(label) \(labels[index])")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)
        }
    }
}

private extension DanmakuSettings {
    func copy(enabled: Bool? = nil, coverage: Int? = nil, font: Int? = nil, opacity: Int? = nil, effect: Int? = nil, speed: Int? = nil) -> DanmakuSettings {
        DanmakuSettings(enabled: enabled ?? self.enabled, coverage: coverage ?? self.coverage, font: font ?? self.font,
                        opacity: opacity ?? self.opacity, effect: effect ?? self.effect, speed: speed ?? self.speed)
    }
}

/// 弹幕开关的「弹」字形图标（带/不带设置齿轮），与 Android 的 DanmakuGlyph 同一形状语义。
struct DanmakuGlyph: View {
    let enabled: Bool
    let tint: Color
    var settings = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).strokeBorder(tint, lineWidth: enabled ? 2 : 1.4)
                .background(RoundedRectangle(cornerRadius: 5).fill(enabled ? tint.opacity(0.16) : .clear))
                .frame(width: 22, height: 20)
            Text("弹").font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            if settings {
                Image(systemName: "gearshape.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.85))
                    .offset(x: 9, y: 9)
            } else if enabled {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    .offset(x: 8, y: 9)
            }
        }
    }
}

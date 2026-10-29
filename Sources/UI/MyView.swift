import SwiftUI

struct MyView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var account = AccountService.shared
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                TabHeader(title: "我的") { NavigationLink { SettingsView() } label: { HeaderIcon(symbol: "gearshape") }.buttonStyle(.plain).accessibilityLabel("设置").accessibilityIdentifier("my.settings") }
                NavigationLink { AccountView() } label: { accountCard }.buttonStyle(.plain)
                HStack(spacing: 14) { stat("本机收藏", count: library.favorites.count, symbol: "star"); stat("本机看过", count: library.history.count, symbol: "clock") }
                VStack(spacing: 0) {
                    Button { model.tab = 2 } label: { menuRow("播放历史", subtitle: "继续上次看到的地方", symbol: "clock.arrow.circlepath") }
                    Divider().padding(.leading, 55)
                    NavigationLink { SettingsView() } label: { menuRow("设置", subtitle: "主题、播放偏好、缓存、更新与关于", symbol: "slider.horizontal.3") }
                }.background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 21)).buttonStyle(.plain)
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 20)
        }.navigationTitle("我的").appBackground(model.appearance).tabRoot(model.appearance)
    }
    private var accountCard: some View {
        let signedIn = !account.nickname.isEmpty
        return HStack(spacing: 15) {
            AccountAvatar(url: account.avatarURL, size: 62) { Image(systemName: "person.crop.circle").font(.system(size: 43, weight: .light)).foregroundStyle(model.appearance.accent).frame(width: 62, height: 62).background(model.appearance.soft, in: RoundedRectangle(cornerRadius: 20)) }
            VStack(alignment: .leading, spacing: 7) { Text(signedIn ? account.nickname : "红果账号").font(.title3.bold()).foregroundStyle(model.appearance.ink).lineLimit(1); Text(signedIn ? account.state : "登录方式、云片单与账号管理").font(.caption).foregroundStyle(model.appearance.muted) }
            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(model.appearance.muted)
        }.padding(19).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 22))
    }
    private func stat(_ title: String, count: Int, symbol: String) -> some View { Button { model.tab = 2 } label: { VStack(alignment: .leading, spacing: 14) { HStack { Text(title).font(.caption); Spacer(); Image(systemName: symbol) }.foregroundStyle(model.appearance.muted); Text("\(count)").font(.system(size: 31, weight: .bold, design: .rounded)).foregroundStyle(model.appearance.ink) }.padding(19).frame(maxWidth: .infinity).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 20)) }.buttonStyle(.plain) }
    private func menuRow(_ title: String, subtitle: String, symbol: String) -> some View { HStack(spacing: 14) { Image(systemName: symbol).font(.title3).foregroundStyle(model.appearance.accent).frame(width: 25); VStack(alignment: .leading, spacing: 5) { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(model.appearance.ink); Text(subtitle).font(.caption).foregroundStyle(model.appearance.muted) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(model.appearance.muted) }.padding(18) }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var clearing = false
    @State private var cacheMessage: String?
    @State private var confirmCache = false
    var body: some View {
        Form {
            Section("外观") { NavigationLink { ThemeSettingsView() } label: { HStack { Text("主题样式"); Spacer(); Text(model.theme.name).foregroundStyle(.secondary) } }; Toggle("深色模式时自动切换", isOn: $model.followSystemDark) }
            Section { Toggle("自动连播下一集", isOn: $model.autoNext); Toggle("下一集预加载", isOn: $model.preloadNext); Picker("默认播放速度", selection: $model.speed) { ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } } } header: { Text("播放偏好") } footer: { Text("预加载会在当前集缓存完成后完整准备下一集，可能使用较多流量和存储空间，默认关闭。切到后台后停止播放与预加载。") }
            Section { Button { confirmCache = true } label: { HStack { Text("清理播放缓存"); Spacer(); if clearing { ProgressView() } } }.disabled(clearing) } header: { Text("存储空间") } footer: { Text("播放缓存用于加速观看，不是永久离线保存。清理缓存不会删除收藏和历史。") }
            Section("通用") { NavigationLink { UpdateView() } label: { HStack { Text("检查更新与全能签源"); Spacer(); Text(appVersionText).foregroundStyle(.secondary) } }; NavigationLink("关于红果独立版") { AboutView() } }
        }.scrollContentBackground(.hidden).appBackground(model.appearance).tint(model.appearance.accent).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("清理播放缓存？", isPresented: $confirmCache, titleVisibility: .visible) { Button("清理缓存", role: .destructive) { clearCache() }; Button("取消", role: .cancel) {} }
            .alert("缓存", isPresented: Binding(get: { cacheMessage != nil }, set: { if !$0 { cacheMessage = nil } })) { Button("好") { cacheMessage = nil } } message: { Text(cacheMessage ?? "") }
    }
    private func clearCache() { clearing = true; Task { do { try await MediaPreparer.shared.clearCache(); cacheMessage = "播放缓存已清理。" } catch { cacheMessage = friendlyError(error) }; clearing = false } }
}

struct ThemeSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 17) { Text("选择喜欢的界面风格，点选后立即生效。收藏、历史与播放设置不受影响。").font(.subheadline).foregroundStyle(model.appearance.muted); ForEach(AppTheme.allCases) { theme in Button { model.theme = theme } label: { ThemePreview(theme: theme, selected: model.theme == theme) }.buttonStyle(.plain) }; Toggle("深色模式时自动切换", isOn: $model.followSystemDark).tint(model.appearance.accent).padding(18).background(model.appearance.surface, in: RoundedRectangle(cornerRadius: 17)); Text("系统深色模式会临时使用沉浸暗场，退出后恢复所选主题。").font(.caption).foregroundStyle(model.appearance.muted) }.padding(20) }.navigationTitle("主题样式").navigationBarTitleDisplayMode(.inline).appBackground(model.appearance)
    }
}

struct ThemePreview: View {
    let theme: AppTheme
    let selected: Bool
    var body: some View {
        HStack(spacing: 17) {
            HStack(alignment: .bottom, spacing: 4) { ForEach(0..<3) { index in RoundedRectangle(cornerRadius: 4).fill(theme.accent.opacity(index == 0 ? 0.65 : 0.15)).frame(width: 17, height: theme == .cards ? CGFloat(35 + index * 10) : (theme == .immersive ? 57 : 45)) } }.frame(width: 78, height: 70).background(theme.background, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 7) { Text(theme.name).font(.headline).foregroundStyle(theme.ink); Text(theme.subtitle).font(.caption).foregroundStyle(theme.muted) }; Spacer(minLength: 0); Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(selected ? theme.accent : theme.muted.opacity(0.4))
        }.padding(15).background(theme.surface, in: RoundedRectangle(cornerRadius: 19)).overlay(RoundedRectangle(cornerRadius: 19).stroke(selected ? theme.accent : theme.muted.opacity(0.1), lineWidth: selected ? 2 : 1))
    }
}

struct AboutView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Form {
            Section { HStack(spacing: 16) { Image("BrandLogo").resizable().scaledToFit().frame(width: 65, height: 65).background(Color(hex: 0xFFF9F6), in: RoundedRectangle(cornerRadius: 20)).accessibilityHidden(true); VStack(alignment: .leading, spacing: 6) { Text("红果独立版").font(.title2.bold()); Text("iOS \(appVersionText)").foregroundStyle(.secondary) } }.padding(.vertical, 8); Text("原生 iOS 短剧客户端。请求、媒体处理、缓存和播放在本机执行，无需配置服务器。") }
            Section("开源") { Link("iOS 项目与版本发布", destination: URL(string: "https://github.com/OOIUa/hongguo-ios")!); Link("Android 原项目", destination: URL(string: "https://github.com/OOIUa/hongguo-android")!); Text("GPL-3.0-only").font(.subheadline); Text("本项目基于红果独立版 Android 移植。分发版本须保留开源许可与对应源码。协议及媒体核心参考 hongguo-web 与 hongguo-drama；第三方许可随源码提供。").font(.caption).foregroundStyle(.secondary) }
            Section("使用说明") { Text("仅支持前台观看。缓存可能被清理，不提供永久离线下载。本机收藏和历史在卸载后移除。").font(.subheadline) }
        }.scrollContentBackground(.hidden).appBackground(model.appearance).navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
    }
}

private var appVersionText: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知版本"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return "\(version) (\(build))"
}

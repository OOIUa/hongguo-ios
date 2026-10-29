import SwiftUI

@main
struct HongguoApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var library = LibraryStore.shared
    var body: some Scene { WindowGroup { RootView().environmentObject(model).environmentObject(library) } }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasChosenTheme") private var hasChosenTheme = false
    @State private var welcomeVisible = false
    @State private var pendingTheme = AppTheme.warm

    var body: some View {
        tabs
        .fullScreenCover(item: $model.playback) { request in PlayerScreen(request: request, model: model).environmentObject(library) }
        .overlay { openingOverlay }
        .alert("暂时无法播放", isPresented: openErrorVisible) { Button("好") { model.openError = nil } } message: { Text(model.openError ?? "") }
        .sheet(isPresented: $welcomeVisible, onDismiss: { hasChosenTheme = true }) { themeWelcome }
        .onAppear { model.systemDark = systemScheme == .dark; if !hasChosenTheme { pendingTheme = model.theme; welcomeVisible = true } }
        .onChange(of: systemScheme) { _, scheme in model.systemDark = scheme == .dark }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.flush() }
            else { AccountService.shared.resumePendingUploads() }
        }
        .modifier(LaunchUpdatePrompt(deferred: updatePromptDeferred))
        .task { if AccountService.shared.hasCredentials { await AccountService.shared.verify() } }
    }

    // Kept out of `body`: the release runner's compiler times out type-checking long inline modifier chains.
    private var tabs: some View {
        let immersive = model.appearance == .immersive
        return TabView(selection: $model.tab) {
            stack { HomeView() }.tabItem { Label("首页", systemImage: "house") }.tag(0)
            stack { DiscoverView() }.tabItem { Label(immersive ? "剧场" : "发现", systemImage: "safari") }.tag(1)
            stack { LibraryView() }.tabItem { Label(immersive ? "追剧" : "片单", systemImage: "rectangle.stack") }.tag(2)
            stack { MyView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(3)
        }
        .tint(model.appearance.accent)
        .toolbarBackground(model.appearance.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(\.colorScheme, immersive ? .dark : .light)
    }
    @ViewBuilder private var openingOverlay: some View {
        if model.openingDramaID != nil { ZStack { Color.black.opacity(0.12).ignoresSafeArea(); ProgressView("正在获取选集…").padding(23).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19)) } }
    }
    private var openErrorVisible: Binding<Bool> { Binding(get: { model.openError != nil }, set: { if !$0 { model.openError = nil } }) }
    private var updatePromptDeferred: Bool { welcomeVisible || model.playback != nil }

    private func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack { content().navigationDestination(for: Drama.self) { DetailView(drama: $0) } }
    }

    private var themeWelcome: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 18) { Text("选择喜欢的界面风格").font(.title2.bold()).foregroundStyle(model.appearance.ink); Text("三种风格，同样精彩。之后可在「我的 › 设置 › 主题样式」随时切换。").font(.subheadline).foregroundStyle(model.appearance.muted); ForEach(AppTheme.allCases) { theme in Button { pendingTheme = theme } label: { ThemePreview(theme: theme, selected: pendingTheme == theme) }.buttonStyle(.plain) }; Button { model.theme = pendingTheme; hasChosenTheme = true; welcomeVisible = false } label: { Text("开始发现好故事").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(model.appearance.accent); Button("暂不选择，保持当前风格") { hasChosenTheme = true; welcomeVisible = false }.font(.caption).frame(maxWidth: .infinity).foregroundStyle(model.appearance.muted) }.padding(22) }.background(model.appearance.background).toolbar { ToolbarItem(placement: .confirmationAction) { Button("稍后") { hasChosenTheme = true; welcomeVisible = false } } }
        }.presentationDragIndicator(.visible)
    }
}

/// Launch-time update prompt, held while `deferred` (theme welcome or player on screen) so it never hides behind them.
private struct LaunchUpdatePrompt: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let deferred: Bool
    @State private var release: UpdateManifest?
    @State private var sheetVisible = false

    private var alertVisible: Binding<Bool> {
        Binding(get: { release != nil && !deferred }, set: { if !$0 { release = nil } })
    }
    private func summary(_ manifest: UpdateManifest) -> String {
        let heading = "\(manifest.version)（\(manifest.build)）已发布，当前为 \(UpdateService.shared.currentVersion)。"
        return ([heading] + manifest.releaseNotes.prefix(4).map { "• " + $0 }).joined(separator: "\n")
    }
    func body(content: Content) -> some View {
        content
            .alert("发现新版本", isPresented: alertVisible, presenting: release) { manifest in
                Button("查看更新") { release = nil; sheetVisible = true }
                Button("忽略此版本") { UpdateService.shared.ignore(manifest); release = nil }
                Button("稍后", role: .cancel) { release = nil }
            } message: { manifest in Text(summary(manifest)) }
            .sheet(isPresented: $sheetVisible) {
                NavigationStack { UpdateView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { sheetVisible = false } } } }
                    .environmentObject(model)
            }
            .task { release = await UpdateService.shared.checkOnLaunch() }
    }
}

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
    @State private var launchUpdate: UpdateManifest?
    @State private var updateSheetVisible = false

    var body: some View {
        TabView(selection: $model.tab) {
            stack { HomeView() }.tabItem { Label("首页", systemImage: "house") }.tag(0)
            stack { DiscoverView() }.tabItem { Label(model.appearance == .immersive ? "剧场" : "发现", systemImage: "safari") }.tag(1)
            stack { LibraryView() }.tabItem { Label(model.appearance == .immersive ? "追剧" : "片单", systemImage: "rectangle.stack") }.tag(2)
            stack { MyView() }.tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(3)
        }
        .tint(model.appearance.accent)
        .toolbarBackground(model.appearance.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(\.colorScheme, model.appearance == .immersive ? .dark : .light)
        .fullScreenCover(item: $model.playback) { request in PlayerScreen(request: request, model: model).environmentObject(library) }
        .overlay { if model.openingDramaID != nil { ZStack { Color.black.opacity(0.12).ignoresSafeArea(); ProgressView("正在获取选集…").padding(23).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19)) } } }
        .alert("暂时无法播放", isPresented: Binding(get: { model.openError != nil }, set: { if !$0 { model.openError = nil } })) { Button("好") { model.openError = nil } } message: { Text(model.openError ?? "") }
        .sheet(isPresented: $welcomeVisible, onDismiss: { hasChosenTheme = true }) { themeWelcome }
        .onAppear { model.systemDark = systemScheme == .dark; if !hasChosenTheme { pendingTheme = model.theme; welcomeVisible = true } }
        .onChange(of: systemScheme) { _, scheme in model.systemDark = scheme == .dark }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { library.flush() }
            else { AccountService.shared.resumePendingUploads() }
        }
        // Held until the theme welcome and the player are closed, so the prompt never hides behind them.
        .alert("发现新版本", isPresented: Binding(get: { launchUpdate != nil && !welcomeVisible && model.playback == nil }, set: { if !$0 { launchUpdate = nil } }), presenting: launchUpdate) { manifest in
            Button("查看更新") { launchUpdate = nil; updateSheetVisible = true }
            Button("忽略此版本") { UpdateService.shared.ignore(manifest); launchUpdate = nil }
            Button("稍后", role: .cancel) { launchUpdate = nil }
        } message: { manifest in
            Text((["\(manifest.version)（\(manifest.build)）已发布，当前为 \(UpdateService.shared.currentVersion)。"] + manifest.releaseNotes.prefix(4).map { "• " + $0 }).joined(separator: "\n"))
        }
        .sheet(isPresented: $updateSheetVisible) {
            NavigationStack { UpdateView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { updateSheetVisible = false } } } }
                .environmentObject(model)
        }
        .task { if AccountService.shared.hasCredentials { await AccountService.shared.verify() } }
        .task { launchUpdate = await UpdateService.shared.checkOnLaunch() }
    }

    private func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack { content().navigationDestination(for: Drama.self) { DetailView(drama: $0) } }
    }

    private var themeWelcome: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 18) { Text("选择喜欢的界面风格").font(.title2.bold()).foregroundStyle(model.appearance.ink); Text("三种风格，同样精彩。之后可在「我的 › 设置 › 主题样式」随时切换。").font(.subheadline).foregroundStyle(model.appearance.muted); ForEach(AppTheme.allCases) { theme in Button { pendingTheme = theme } label: { ThemePreview(theme: theme, selected: pendingTheme == theme) }.buttonStyle(.plain) }; Button { model.theme = pendingTheme; hasChosenTheme = true; welcomeVisible = false } label: { Text("开始发现好故事").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(model.appearance.accent); Button("暂不选择，保持当前风格") { hasChosenTheme = true; welcomeVisible = false }.font(.caption).frame(maxWidth: .infinity).foregroundStyle(model.appearance.muted) }.padding(22) }.background(model.appearance.background).toolbar { ToolbarItem(placement: .confirmationAction) { Button("稍后") { hasChosenTheme = true; welcomeVisible = false } } }
        }.presentationDragIndicator(.visible)
    }
}

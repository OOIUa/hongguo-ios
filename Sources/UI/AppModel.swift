import SwiftUI
import Combine
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    case warm, immersive, cards
    var id: String { rawValue }
    var name: String { switch self { case .warm: return "暖白精修"; case .immersive: return "沉浸暗场"; case .cards: return "内容卡片" } }
    var subtitle: String { switch self { case .warm: return "温暖留白，轻松发现好故事"; case .immersive: return "竖屏刷剧，一屏一部好剧"; case .cards: return "榜单与卡片，丰富而有序" } }
    /// The natural mode before the user picks one: 沉浸暗场 is dark, the others light.
    var defaultDark: Bool { self == .immersive }
    func colors(dark: Bool) -> ThemeColors { ThemeColors(style: self, dark: dark) }
}

/// Whether the interface is light or dark, chosen in 设置 and independent of the layout.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String { switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" } }
}

/// A layout in one mode. Every screen reads its colors from here.
struct ThemeColors: Equatable {
    let style: AppTheme
    let dark: Bool
    var background: Color {
        switch (style, dark) {
        case (.warm, false): return Color(hex: 0xFCF8F4)
        case (.warm, true): return Color(hex: 0x1A1512)
        case (.immersive, false): return Color(hex: 0xF6F6F8)
        case (.immersive, true): return Color(hex: 0x111113)
        case (.cards, false): return Color(hex: 0xF2F3F5)
        case (.cards, true): return Color(hex: 0x0F1012)
        }
    }
    var surface: Color {
        guard dark else { return .white }
        switch style { case .warm: return Color(hex: 0x241E1A); case .immersive: return Color(hex: 0x1E1E22); case .cards: return Color(hex: 0x1A1B1F) }
    }
    var ink: Color {
        guard dark else { return style == .immersive ? Color(hex: 0x17171B) : Color(hex: 0x292421) }
        switch style { case .warm: return Color(hex: 0xF5EEE8); case .immersive: return Color(hex: 0xF8F5F0); case .cards: return Color(hex: 0xF2F3F5) }
    }
    var muted: Color {
        guard dark else { return style == .immersive ? Color(hex: 0x62626C) : Color(hex: 0x786E67) }
        switch style { case .warm: return Color(hex: 0xB8ACA3); case .immersive: return Color(hex: 0xB3ACAA); case .cards: return Color(hex: 0xA5A9B1) }
    }
    var accent: Color {
        guard dark else { return Color(hex: 0xC94426) }
        switch style { case .warm: return Color(hex: 0xFF9B7A); case .immersive: return Color(hex: 0xFF805F); case .cards: return Color(hex: 0xFF8A80) }
    }
    var soft: Color {
        guard dark else { return style == .immersive ? Color(hex: 0xFBE9E4) : Color(hex: 0xF5EDE5) }
        switch style { case .warm: return Color(hex: 0x3A241C); case .immersive: return Color(hex: 0x332421); case .cards: return Color(hex: 0x3A1C1A) }
    }
    /// Layout checks read as before: `model.appearance == .immersive`.
    static func == (colors: ThemeColors, style: AppTheme) -> Bool { colors.style == style }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let detail: DramaDetail
    let index: Int
    let position: Double
    let recordsLocalHistory: Bool
}

@MainActor
final class AppModel: ObservableObject {
    @Published var theme: AppTheme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") } }
    /// nil until the user picks a mode, so each layout keeps its natural look.
    @Published var appearanceMode: AppearanceMode? { didSet { UserDefaults.standard.set(appearanceMode?.rawValue, forKey: "appearanceMode") } }
    /// 沉浸暗场's video feed stays dark in every mode, including its status bar and tab bar.
    @Published var feedOnScreen = false
    @Published var autoNext: Bool { didSet { UserDefaults.standard.set(autoNext, forKey: "autoNext") } }
    @Published var preloadNext: Bool { didSet { UserDefaults.standard.set(preloadNext, forKey: "preloadNext") } }
    @Published var speed: Float { didSet { UserDefaults.standard.set(speed, forKey: "speed") } }
    @Published var tab = 0
    @Published var systemDark = UITraitCollection.current.userInterfaceStyle == .dark
    @Published var playback: PlaybackRequest?
    @Published var openingDramaID: String?
    @Published var openError: String?
    private var openTask: Task<Void, Never>?
    let library = LibraryStore.shared
    var currentMode: AppearanceMode { appearanceMode ?? (theme.defaultDark ? .dark : .light) }
    private var modeDark: Bool {
        switch currentMode { case .system: return systemDark; case .light: return false; case .dark: return true }
    }
    private var feedForcesDark: Bool { feedOnScreen && theme == .immersive }
    var isDark: Bool { modeDark || feedForcesDark }
    var appearance: ThemeColors { theme.colors(dark: isDark) }
    /// Applied to the window directly: `preferredColorScheme(nil)` does not reliably return to the system after an explicit value.
    var windowStyle: UIUserInterfaceStyle { currentMode == .system && !feedForcesDark ? .unspecified : (isDark ? .dark : .light) }
    private var windowScene: UIWindowScene? { UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first }
    private var systemAppearanceRegistration: (any UITraitChangeRegistration)?

    func applyWindowStyle() {
        let style = windowStyle
        windowScene?.windows.forEach { $0.overrideUserInterfaceStyle = style }
    }
    /// The scene's traits ignore the windows' override, so this always reads the real system setting.
    func refreshSystemAppearance() {
        systemDark = (windowScene?.traitCollection ?? UITraitCollection.current).userInterfaceStyle == .dark
    }
    func startAppearanceTracking() {
        refreshSystemAppearance()
        applyWindowStyle()
        guard systemAppearanceRegistration == nil, let windowScene else { return }
        systemAppearanceRegistration = windowScene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
            self?.refreshSystemAppearance()
        }
    }

    init() {
        let defaults = UserDefaults.standard
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "warm") ?? .warm
        // The old switch 深色模式时自动切换 meant following the system.
        appearanceMode = defaults.string(forKey: "appearanceMode").flatMap(AppearanceMode.init) ?? (defaults.bool(forKey: "followSystemDark") ? .system : nil)
        autoNext = defaults.object(forKey: "autoNext") as? Bool ?? true
        preloadNext = defaults.object(forKey: "preloadNext") as? Bool ?? false
        let saved = defaults.float(forKey: "speed")
        speed = [Float(0.5), 0.75, 1, 1.25, 1.5, 2].contains(saved) ? saved : 1
    }

    func play(_ detail: DramaDetail, index: Int? = nil, resume: LibraryEntry? = nil) {
        guard !detail.episodes.isEmpty else { openError = "这部剧暂时没有可播放剧集。"; return }
        let entry = resume ?? library.progress(for: detail.drama.id)
        let selected = index ?? entry.flatMap { entry in detail.episodes.firstIndex { $0.id == entry.episodeID } ?? detail.episodes.firstIndex { $0.index == entry.episodeIndex } } ?? 0
        let bounded = min(max(selected, 0), detail.episodes.count - 1)
        let savedPosition = entry.map { ($0.episodeID == detail.episodes[bounded].id || $0.episodeIndex == detail.episodes[bounded].index) ? $0.position : 0 } ?? 0
        playback = PlaybackRequest(detail: detail, index: bounded, position: savedPosition, recordsLocalHistory: resume == nil)
    }

    func play(_ drama: Drama) {
        openTask?.cancel()
        openingDramaID = drama.id
        openTask = Task { [weak self] in
            do {
                let detail = try await DramaAPI.shared.detail(drama: drama)
                try Task.checkCancellation()
                guard let self else { return }
                self.openingDramaID = nil
                self.play(detail)
            } catch is CancellationError { }
            catch { self?.openingDramaID = nil; self?.openError = friendlyError(error) }
        }
    }
}

@MainActor
final class CatalogLoader: ObservableObject {
    @Published private(set) var dramas: [Drama] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    private var offset = 0
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var preloadedCovers = Set<String>()

    func load(reset: Bool = false, fetch: @escaping (Int) async throws -> DramaPage) {
        if isLoading && !reset { return }
        if !reset && !dramas.isEmpty && !hasMore { return }
        task?.cancel()
        let ticket = UUID(); generation = ticket
        let requestedOffset = reset ? 0 : offset
        if reset { dramas = []; offset = 0; hasMore = false; preloadedCovers = [] }
        isLoading = true; error = nil
        task = Task { [weak self] in
            do {
                let page = try await fetch(requestedOffset)
                try Task.checkCancellation()
                guard let self, self.generation == ticket else { return }
                var existing = Set(self.dramas.map(\.id))
                let fresh = page.dramas.filter { existing.insert($0.id).inserted }
                self.dramas += fresh
                self.hasMore = page.hasMore && !fresh.isEmpty && page.nextOffset > requestedOffset
                self.offset = page.nextOffset
                self.isLoading = false
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == ticket else { return }
                self.isLoading = false; self.error = friendlyError(error)
            }
        }
    }

    func cancel() { task?.cancel(); generation = UUID(); isLoading = false }

    /// Call as a row appears. Requests the next page once it is within 12 of the end, so it is in the list before the
    /// user gets there. A failed page waits for the retry button, so a dead network cannot turn scrolling into a loop.
    func itemAppeared(_ drama: Drama, load: () -> Void) {
        preloadCovers(after: drama)
        guard hasMore, error == nil, !isLoading, dramas.suffix(12).contains(where: { $0.id == drama.id }) else { return }
        load()
    }

    /// Fills URLCache, which AsyncImage reads, with the next covers (about 50 KB each, cacheable for a year).
    func preloadCovers(after drama: Drama) {
        guard let index = dramas.firstIndex(where: { $0.id == drama.id }) else { return }
        for next in dramas[(index + 1)...].prefix(9) where preloadedCovers.insert(next.coverURL).inserted {
            guard let url = URL(string: next.coverURL), url.scheme == "https" else { continue }
            URLSession.shared.dataTask(with: url).resume()
        }
    }
}

func friendlyError(_ error: Error) -> String {
    if let error = error as? URLError {
        if error.code == .notConnectedToInternet { return "网络未连接，请检查网络后重试。" }
        if error.code == .timedOut { return "请求超时，请稍后重试。" }
    }
    let value = error.localizedDescription
    return value.isEmpty ? "暂时无法加载，请稍后重试。" : value
}

func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "00:00" }
    let value = max(0, Int(seconds))
    return String(format: "%02d:%02d", value / 60, value % 60)
}

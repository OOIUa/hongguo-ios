import SwiftUI
import Combine

enum AppTheme: String, CaseIterable, Identifiable {
    case warm, immersive, cards
    var id: String { rawValue }
    var name: String { switch self { case .warm: return "暖白精修"; case .immersive: return "沉浸暗场"; case .cards: return "内容卡片" } }
    var subtitle: String { switch self { case .warm: return "温暖留白，轻松发现好故事"; case .immersive: return "深色剧场，一屏一部好剧"; case .cards: return "榜单与卡片，丰富而有序" } }
    var background: Color { switch self { case .warm: return Color(hex: 0xFCF8F4); case .immersive: return Color(hex: 0x111113); case .cards: return Color(hex: 0xF2F3F5) } }
    var surface: Color { self == .immersive ? Color(hex: 0x1E1E22) : .white }
    var ink: Color { self == .immersive ? Color(hex: 0xF8F5F0) : Color(hex: 0x292421) }
    var muted: Color { self == .immersive ? Color(hex: 0xB3ACAA) : Color(hex: 0x786E67) }
    var accent: Color { self == .immersive ? Color(hex: 0xFF805F) : Color(hex: 0xC94426) }
    var soft: Color { self == .immersive ? Color(hex: 0x332421) : Color(hex: 0xF5EDE5) }
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
    @Published var followSystemDark: Bool { didSet { UserDefaults.standard.set(followSystemDark, forKey: "followSystemDark") } }
    @Published var autoNext: Bool { didSet { UserDefaults.standard.set(autoNext, forKey: "autoNext") } }
    @Published var preloadNext: Bool { didSet { UserDefaults.standard.set(preloadNext, forKey: "preloadNext") } }
    @Published var speed: Float { didSet { UserDefaults.standard.set(speed, forKey: "speed") } }
    @Published var tab = 0
    @Published var systemDark = false
    @Published var playback: PlaybackRequest?
    @Published var openingDramaID: String?
    @Published var openError: String?
    private var openTask: Task<Void, Never>?
    let library = LibraryStore.shared
    var appearance: AppTheme { followSystemDark && systemDark ? .immersive : theme }

    init() {
        let defaults = UserDefaults.standard
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "warm") ?? .warm
        followSystemDark = defaults.bool(forKey: "followSystemDark")
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

    func load(reset: Bool = false, fetch: @escaping (Int) async throws -> DramaPage) {
        if isLoading && !reset { return }
        if !reset && !dramas.isEmpty && !hasMore { return }
        task?.cancel()
        let ticket = UUID(); generation = ticket
        let requestedOffset = reset ? 0 : offset
        if reset { dramas = []; offset = 0; hasMore = false }
        isLoading = true; error = nil
        task = Task { [weak self] in
            do {
                let page = try await fetch(requestedOffset)
                try Task.checkCancellation()
                guard let self, self.generation == ticket else { return }
                let existing = Set(self.dramas.map(\.id))
                let fresh = page.dramas.filter { !existing.contains($0.id) }
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
